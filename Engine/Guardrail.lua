--[[
	Guardrail: the money math of posting one listing, from the loss guardrail section of the spec.
	Step 3 built the pieces the opportunity value needs; step 4 adds break-even and the posting
	verdict for the Sell tab.

	Deposit rules (from play on Forever): a cancelled or expired listing loses its whole deposit;
	a sale takes the 5% cut from the deposit and returns the rest with the price, so a sale nets
	P - 5% either way and the deposit only costs money on listings that do not sell.

	  sellChance{ salesPerDay, durationHours, unitsAhead, units } -> p in [0, 1], or nil
	      the queue model: buyers take the cheapest units first and a new listing goes behind
	      every unit already at or under its price, so
	      p = clamp((sales in the duration - units ahead) / units of the listing, 0, 1)
	  depositLoss(deposit, p) -> copper   one whole deposit per listing expected back unsold
	      before one sells: deposit * (1 - p) / p, rounded up; math.huge when p is 0
	  saleNet(price, units)  -> copper    price * units after the 5% cut, rounded down
	  estimateDeposit(vendor, units, durationHours) -> copper   used when the client cannot say
	  opportunity{ ... }     -> Opportunity (below)
	  listingNet{ ... }      -> copper, sellChance, depositLoss   expected net of one listing at P
	  breakEven{ ... }       -> copper|nil   lowest allowed P (on the step, never below the vendor
	                            price) with an expected net of zero or more
	  verdict{ ... }         -> Verdict = { price, netPerUnit, net, sellChance, breakEven,
	                            depositLoss, deposit, vendorNet, action = 'post'|'vendor'|'hold',
	                            isLoss, isBelowVendor, reasons, confidence }
	  postCheck(verdict, behaviour) -> 'ok'|'warn'|'confirm'   behaviour 'off'|'warn'|'confirm'

	Vendor threshold: the AH is suggested only when its expected net beats the vendor by at least
	threshold.copper per listing and threshold.percent; below that the verdict is 'vendor' (or
	'hold' when the vendor pays nothing and the AH does not clear the threshold either).

	Money is integer copper. Every result rounds against the seller (net down, loss up), so a
	value never flatters the item. The engine never throws on data: junk numbers read as unknown.
]]
local _, ns = ...

local Guardrail = {}
ns.Guardrail = Guardrail

Guardrail.CUT_PERCENT = 5
-- Retail's Mainline deposit, which Forever's AH follows until checked in game: 15% of the vendor
-- price per unit for each 12 hours listed. Used only when no deposit source is given.
Guardrail.DEPOSIT_PERCENT_PER_12H = 15
Guardrail.DEFAULT_DURATION_HOURS = 24
Guardrail.HOURS_PER_DAY = 24
Guardrail.BEHAVIOURS = { 'off', 'warn', 'confirm' }
Guardrail.DEFAULT_BEHAVIOUR = 'confirm'
Guardrail.DEFAULT_THRESHOLD = { copper = 10000, percent = 10 }
-- A break-even search that has not settled after this many steps up inside one queue interval
-- gives up on that interval (rounding alone never needs more than a couple).
local MAX_SETTLE_STEPS = 8
local ROUNDING_EPSILON = 1e-9

-- Helpers live at the bottom of the file; declared here so they stay local.
local isFiniteNonNegative, isFinitePositive, addReason, queueStarts, stepOf, snapUpTo, mergeConfidence
local actionFor

--- Chance that one listing sells within its duration, from the queue model.
--- @param input table { salesPerDay, durationHours, unitsAhead, units }
--- @return number|nil p in [0, 1]; nil when sales a day or the queue is unknown
function Guardrail.sellChance(input)
	if type(input) ~= 'table' then
		error('Guardrail.sellChance: input must be a table', 2)
	end
	local perDay, hours, ahead = input.salesPerDay, input.durationHours, input.unitsAhead
	local units = input.units
	if not (isFiniteNonNegative(perDay) and isFinitePositive(hours) and isFiniteNonNegative(ahead)) then
		return nil
	end
	if not isFinitePositive(units) then
		return nil
	end
	local salesInDuration = perDay * hours / Guardrail.HOURS_PER_DAY
	local p = (salesInDuration - ahead) / units
	return math.max(0, math.min(1, p))
end

--- Deposits expected to be lost before the listing sells: deposit * (1 - p) / p.
--- @param deposit number copper for one listing
--- @param p number sell chance in [0, 1]
--- @return number copper, rounded up; math.huge when p is 0 and the deposit is not 0
function Guardrail.depositLoss(deposit, p)
	if not (isFiniteNonNegative(deposit) and isFiniteNonNegative(p)) or p > 1 then
		error('Guardrail.depositLoss: needs a deposit of 0 or more and p in [0, 1]', 2)
	end
	if deposit == 0 or p == 1 then
		return 0
	end
	if p == 0 then
		return math.huge
	end
	-- The epsilon keeps a float like 182.00000000000003 from rounding up to 183.
	return math.ceil(deposit * (1 - p) / p - ROUNDING_EPSILON)
end

--- What a sale of `units` at `price` each pays after the cut, rounded down.
--- @param price number copper per unit
--- @param units number
--- @return number copper
function Guardrail.saleNet(price, units)
	return math.floor(price * units * (100 - Guardrail.CUT_PERCENT) / 100)
end

--- The deposit of one listing estimated from the vendor price (see DEPOSIT_PERCENT_PER_12H).
--- @return number copper, rounded up
function Guardrail.estimateDeposit(vendor, units, durationHours)
	local perTwelveHours = vendor * units * Guardrail.DEPOSIT_PERCENT_PER_12H / 100
	return math.ceil(perTwelveHours * durationHours / 12 - ROUNDING_EPSILON)
end

--- Units of a scan already at or under a price, after anti-bait (a new listing queues behind
--- them). Junk levels are skipped.
--- @param levels table|nil { { price, qty }... }
--- @param price number copper per unit
--- @param antiBait table|nil the rule's anti-bait settings
--- @param salesPerDay number|nil
--- @return number|nil units; nil when there are no levels to read
function Guardrail.unitsAtOrUnder(levels, price, antiBait, salesPerDay)
	if type(levels) ~= 'table' or #levels == 0 then
		return nil
	end
	local remaining = ns.Rules.passOverBait(levels, antiBait, salesPerDay)
	local units = 0
	for _, level in ipairs(remaining) do
		if level.price <= price then
			units = units + level.qty
		end
	end
	return units
end

--- The opportunity value of a stack: what selling it would net, never below the vendor.
--- @param input table
---   price          copper per unit, the rule price (already on the item's step); nil when unpriced
---   units          units in the stack (a listing of this size)
---   vendor         copper per unit from a vendor, 0 when unsellable, nil when unknown
---   salesPerDay    nil when unknown
---   levels         latest scan levels { { price, qty }... }, nil without a scan
---   antiBait       the rule's anti-bait settings
---   durationHours  listing duration (default 24)
---   deposit        copper for this listing, or nil to estimate it from the vendor price
---   isBound        a bound item can only be vendored
--- @return table Opportunity { copper, perUnit, source = 'ah'|'vendor'|'none', ahNet?, vendorNet?,
---   sellChance?, depositLoss?, deposit?, unitsAhead?, reasons = { { code, level, text }... } }
function Guardrail.opportunity(input)
	if type(input) ~= 'table' or not isFinitePositive(input.units) then
		error('Guardrail.opportunity: needs units above 0', 2)
	end
	local units = input.units
	local reasons = {}
	local vendor = isFiniteNonNegative(input.vendor) and math.floor(input.vendor) or nil
	local vendorNet = vendor and vendor * units or nil
	if vendor == nil then
		addReason(reasons, 'vendorUnknown', 'medium', 'vendor price not known yet; no vendor floor')
	end
	if input.isBound then
		addReason(reasons, 'bound', 'high', 'bound; vendor price only')
		return Guardrail.pickBest(nil, vendorNet, units, reasons, {})
	end
	local price = input.price
	if not isFinitePositive(price) then
		local level = vendorNet and 'medium' or 'low'
		addReason(reasons, 'noPrice', level, vendorNet and 'no AH price; vendor price only' or 'no price')
		return Guardrail.pickBest(nil, vendorNet, units, reasons, {})
	end
	local hours = isFinitePositive(input.durationHours) and input.durationHours or Guardrail.DEFAULT_DURATION_HOURS
	local detail = {}
	local deposit = input.deposit
	if not isFiniteNonNegative(deposit) then
		deposit = vendor and Guardrail.estimateDeposit(vendor, units, hours) or 0
		local text = vendor and 'deposit estimated from the vendor price' or 'deposit unknown; not counted'
		addReason(reasons, 'depositEstimated', vendor and 'high' or 'medium', text)
	end
	detail.deposit = deposit
	local ahead = Guardrail.unitsAtOrUnder(input.levels, price, input.antiBait, input.salesPerDay)
	if ahead == nil then
		ahead = 0
		addReason(reasons, 'queueUnknown', 'medium', 'no scan depth; units ahead in the queue not counted')
	end
	detail.unitsAhead = ahead
	local p = Guardrail.sellChance({
		salesPerDay = input.salesPerDay,
		durationHours = hours,
		unitsAhead = ahead,
		units = units,
	})
	local saleNet = Guardrail.saleNet(price, units)
	local ahNet
	if p == nil then
		addReason(reasons, 'sellChanceUnknown', 'medium', 'no sales data; deposit risk not counted')
		ahNet = saleNet
	else
		detail.sellChance = p
		detail.depositLoss = Guardrail.depositLoss(deposit, p)
		ahNet = saleNet - detail.depositLoss
		if p == 0 then
			addReason(reasons, 'wontSell', 'high', 'the queue ahead outlasts the listing; it is not expected to sell')
		end
	end
	return Guardrail.pickBest(ahNet, vendorNet, units, reasons, detail)
end

--- The better of the AH and the vendor; a tie goes to the vendor (no deposit, no risk).
--- @return table Opportunity
function Guardrail.pickBest(ahNet, vendorNet, units, reasons, detail)
	local isAh = ahNet ~= nil and ahNet > -math.huge and (vendorNet == nil or ahNet > vendorNet)
	local copper
	local source
	if isAh then
		copper, source = math.max(0, ahNet), 'ah'
	elseif vendorNet ~= nil then
		copper, source = vendorNet, 'vendor'
	else
		copper, source = 0, 'none'
	end
	local result = {
		copper = copper,
		perUnit = math.floor(copper / units),
		source = source,
		ahNet = ahNet ~= nil and ahNet > -math.huge and ahNet or nil,
		vendorNet = vendorNet,
		reasons = reasons,
	}
	for key, value in pairs(detail) do
		result[key] = value
	end
	return result
end

--- Expected net of one listing of `units` at `price` each: the sale after the cut, less the
--- material cost and the deposits expected lost before it sells.
--- @param input table { price, units, cost?, deposit, salesPerDay?, levels?, antiBait?, durationHours }
--- @return number copper (-math.huge when the listing is not expected to sell and has a deposit)
--- @return number|nil sellChance nil when sales a day or the queue is unknown
--- @return number depositLoss 0 when the sell chance is unknown
function Guardrail.listingNet(input)
	if type(input) ~= 'table' or not isFinitePositive(input.price) or not isFinitePositive(input.units) then
		error('Guardrail.listingNet: needs price and units above 0', 2)
	end
	local units = input.units
	local cost = isFiniteNonNegative(input.cost) and input.cost * units or 0
	local deposit = isFiniteNonNegative(input.deposit) and input.deposit or 0
	local ahead = Guardrail.unitsAtOrUnder(input.levels, input.price, input.antiBait, input.salesPerDay) or 0
	local p = Guardrail.sellChance({
		salesPerDay = input.salesPerDay,
		durationHours = input.durationHours or Guardrail.DEFAULT_DURATION_HOURS,
		unitsAhead = ahead,
		units = units,
	})
	local loss = p and Guardrail.depositLoss(deposit, p) or 0
	return Guardrail.saleNet(input.price, units) - cost - loss, p, loss
end

--- The lowest allowed price with an expected net of zero or more. Prices are walked one queue
--- interval at a time: inside an interval the units ahead (so the sell chance and the deposit
--- loss) stay the same and the net only grows with the price, so the lowest price that clears
--- is solved, rounded up to the step and checked.
--- @param input table listingNet's input without price, plus step (1 or 100) and vendor?
--- @return number|nil copper; nil when no price clears (the listing is not expected to sell)
function Guardrail.breakEven(input)
	if type(input) ~= 'table' or not isFinitePositive(input.units) then
		error('Guardrail.breakEven: needs units above 0', 2)
	end
	local step = stepOf(input.step)
	local floor = snapUpTo(step, math.max(1, isFiniteNonNegative(input.vendor) and input.vendor or 0))
	local starts = queueStarts(input, floor, step)
	local cost = isFiniteNonNegative(input.cost) and input.cost * input.units or 0
	local cutShare = (100 - Guardrail.CUT_PERCENT) / 100
	for index, start in ipairs(starts) do
		local nextStart = starts[index + 1]
		local probe = setmetatable({ price = start }, { __index = input })
		local _, p, loss = Guardrail.listingNet(probe)
		if p ~= 0 then
			local needed = (cost + loss) / (input.units * cutShare)
			local candidate = math.max(start, snapUpTo(step, needed))
			for _ = 1, MAX_SETTLE_STEPS do
				if nextStart and candidate >= nextStart then
					break
				end
				probe.price = candidate
				if Guardrail.listingNet(probe) >= 0 then
					return candidate
				end
				candidate = candidate + step
			end
		end
	end
	return nil
end

--- The posting verdict for one listing at the rule price.
--- @param input table
---   price          copper per unit (the rule price, on its step); nil when unpriced
---   step           the item's price step (Price.step)
---   units, vendor, cost?, salesPerDay, levels, antiBait, durationHours, deposit
---   threshold      { copper, percent } (default DEFAULT_THRESHOLD)
---   confidence     the rule price's Confidence
--- @return table Verdict (see the file header)
function Guardrail.verdict(input)
	if type(input) ~= 'table' or not isFinitePositive(input.units) then
		error('Guardrail.verdict: needs units above 0', 2)
	end
	local units = input.units
	local reasons = {}
	local vendor = isFiniteNonNegative(input.vendor) and math.floor(input.vendor) or nil
	local vendorNet = vendor and vendor * units or nil
	local hours = isFinitePositive(input.durationHours) and input.durationHours or Guardrail.DEFAULT_DURATION_HOURS
	local deposit = input.deposit
	if not isFiniteNonNegative(deposit) then
		deposit = vendor and Guardrail.estimateDeposit(vendor, units, hours) or 0
		local text = vendor and 'deposit estimated from the vendor price' or 'deposit unknown; not counted'
		addReason(reasons, 'depositEstimated', vendor and 'high' or 'medium', text)
	end
	local base = {
		units = units,
		cost = input.cost,
		deposit = deposit,
		salesPerDay = input.salesPerDay,
		levels = input.levels,
		antiBait = input.antiBait,
		durationHours = hours,
		step = input.step,
		vendor = vendor,
	}
	local verdict = { price = input.price, deposit = deposit, vendorNet = vendorNet, reasons = reasons }
	verdict.breakEven = Guardrail.breakEven(base)
	if not isFinitePositive(input.price) then
		addReason(reasons, 'noPrice', vendorNet and 'medium' or 'low', 'no AH price')
		verdict.action = (vendorNet or 0) > 0 and 'vendor' or 'hold'
		verdict.confidence = mergeConfidence(input.confidence, reasons)
		return verdict
	end
	if type(input.levels) ~= 'table' or #input.levels == 0 then
		addReason(reasons, 'queueUnknown', 'medium', 'no scan depth; units ahead in the queue not counted')
	end
	local probe = setmetatable({ price = input.price }, { __index = base })
	local net, p, loss = Guardrail.listingNet(probe)
	verdict.net, verdict.sellChance, verdict.depositLoss = net, p, loss
	verdict.netPerUnit = net > -math.huge and math.floor(net / units) or nil
	if p == nil then
		addReason(reasons, 'sellChanceUnknown', 'medium', 'no sales data; deposit risk not counted')
	elseif p == 0 then
		addReason(reasons, 'wontSell', 'high', 'the queue ahead outlasts the listing; it is not expected to sell')
	end
	verdict.isLoss = net < 0
	verdict.isBelowVendor = vendorNet ~= nil and net < vendorNet
	verdict.action = actionFor(net, vendorNet, input.threshold or Guardrail.DEFAULT_THRESHOLD)
	verdict.confidence = mergeConfidence(input.confidence, reasons)
	return verdict
end

--- What posting at a verdict's price asks of the player under a guardrail behaviour: a loss
--- (expected net under zero) is confirmed under 'confirm'; a loss under 'warn', or a net under
--- what the vendor pays, is a warning.
--- @param verdict table Verdict
--- @param behaviour string 'off'|'warn'|'confirm'
--- @return string 'ok'|'warn'|'confirm'
function Guardrail.postCheck(verdict, behaviour)
	if type(verdict) ~= 'table' then
		error('Guardrail.postCheck: needs a verdict', 2)
	end
	if behaviour == 'off' or not (verdict.isLoss or verdict.isBelowVendor) then
		return 'ok'
	end
	if behaviour == 'confirm' and verdict.isLoss then
		return 'confirm'
	end
	return 'warn'
end

-- Helpers ---------------------------------------------------------------------------------

-- 'post' when the AH beats the vendor by the threshold; else 'vendor' when the vendor pays,
-- else 'hold'.
function actionFor(net, vendorNet, threshold)
	local vendorPays = vendorNet or 0
	local margin = isFiniteNonNegative(threshold.copper) and threshold.copper or 0
	local percent = isFiniteNonNegative(threshold.percent) and threshold.percent or 0
	local clears = net - vendorPays >= margin and net >= vendorPays * (1 + percent / 100)
	if clears and net > 0 then
		return 'post'
	end
	return vendorPays > 0 and 'vendor' or 'hold'
end

-- Where the units ahead change: the floor, then every (anti-bait) level price above it, on
-- the step, cheapest first.
function queueStarts(input, floor, step)
	local starts, seen = { floor }, { [floor] = true }
	if type(input.levels) ~= 'table' or #input.levels == 0 then
		return starts
	end
	for _, level in ipairs(ns.Rules.passOverBait(input.levels, input.antiBait, input.salesPerDay)) do
		local start = snapUpTo(step, level.price)
		if start > floor and not seen[start] then
			seen[start] = true
			starts[#starts + 1] = start
		end
	end
	table.sort(starts)
	return starts
end

function stepOf(step)
	return (step == 1 or step == 100) and step or 1
end

function snapUpTo(step, copper)
	return math.ceil(copper / step - ROUNDING_EPSILON) * step
end

function mergeConfidence(confidence, reasons)
	return ns.Value.mergeConfidence({ confidence, { reasons = reasons } })
end

function isFiniteNonNegative(value)
	return type(value) == 'number' and value >= 0 and value < math.huge
end

function isFinitePositive(value)
	return type(value) == 'number' and value > 0 and value < math.huge
end

function addReason(reasons, code, level, text)
	reasons[#reasons + 1] = { code = code, level = level, text = text }
end

return Guardrail
