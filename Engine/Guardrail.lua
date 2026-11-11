--[[
	Guardrail: the money math of posting one listing, from the loss guardrail section of the spec.
	Step 3 builds the pieces the opportunity value needs; break-even and the posting verdict
	arrive with the Sell tab.

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
local ROUNDING_EPSILON = 1e-9

-- Helpers live at the bottom of the file; declared here so they stay local.
local isFiniteNonNegative, isFinitePositive, addReason

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

-- Helpers ---------------------------------------------------------------------------------

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
