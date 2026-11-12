--[[
	Sell: what the Sell tab suggests for the items in the bags. Pure: every game read comes in
	through deps, so it runs the same against the fake game.

	  Sell.rows(carried, deps) -> SellRow[]   post first, then by expected net, highest first
	  Sell.verdictAt(row, price) -> Verdict   the same listing at another price (the stepper)
	  Sell.stepPrice(row, price, direction) -> copper   one price step up (+1) or down (-1)

	carried is Wow:CarriedItems(): { itemId, count, isBound, hasNoValue, bag, slot }. Bound and
	worthless items are left out. Stackable items group into one listing of every unit carried
	(a commodity listing takes them from many slots); unstackable items list one unit at a time,
	so a row of three swords is three listings of one.

	deps = {
	  prices        PriceService (Get, Context)
	  store         Store (Rule, DefaultRuleId)
	  ruleId?       the rule to price by; the default rule when nil
	  durationHours listing duration (12, 24 or 48)
	  deposit?      fun(itemId, units, hours) -> copper|nil; the client's deposit when it can say
	  threshold?    Guardrail threshold { copper, percent }
	  behaviour?    guardrail behaviour 'off'|'warn'|'confirm' (default Guardrail.DEFAULT_BEHAVIOUR)
	}

	SellRow = { itemId, count, units, listings, slots = { { bag, slot, count }... }, price,
	            reason?, verdict, check = 'ok'|'warn'|'confirm', input }
	  units is the units of one listing; price the rule's Price (nil with reason when unpriced);
	  input is the Guardrail input, kept so verdictAt can re-run it at another price.
]]
local _, ns = ...

local Sell = {}
ns.Sell = Sell

local ACTION_ORDER = { post = 1, vendor = 2, hold = 3 }

-- Helpers live at the bottom of the file; declared here so they stay local.
local groupCarried, buildRow, compareRows, isWholePositive, safeCall

--- The Sell tab's rows for the items carried.
--- @param carried table Wow:CarriedItems()
--- @param deps table see the file header
--- @return table SellRow[]
function Sell.rows(carried, deps)
	if type(carried) ~= 'table' then
		error('Sell.rows: carried must be a list', 2)
	end
	if type(deps) ~= 'table' or not deps.prices or not deps.store then
		error('Sell.rows: needs deps.prices and deps.store', 2)
	end
	local ruleId = deps.ruleId or deps.store:DefaultRuleId()
	local rule = deps.store:Rule(ruleId)
	if not rule then
		error('Sell.rows: unknown rule ' .. tostring(ruleId), 2)
	end
	local ctx = deps.prices:Context()
	local rows = {}
	for _, group in ipairs(groupCarried(carried, ctx)) do
		rows[#rows + 1] = buildRow(group, rule, ruleId, ctx, deps)
	end
	table.sort(rows, compareRows)
	return rows
end

--- The verdict for a row's listing at another price.
--- @param row table SellRow
--- @param price number copper per unit
--- @return table Verdict
function Sell.verdictAt(row, price)
	if type(row) ~= 'table' or type(row.input) ~= 'table' then
		error('Sell.verdictAt: needs a SellRow', 2)
	end
	local input = {}
	for key, value in pairs(row.input) do
		input[key] = value
	end
	input.price = price
	return ns.Guardrail.verdict(input)
end

--- One price step from a price, on the row's step and never under one step.
--- @param row table SellRow
--- @param price number|nil copper per unit; the rule price (or one step) when nil
--- @param direction number +1 or -1
--- @return number copper
function Sell.stepPrice(row, price, direction)
	if direction ~= 1 and direction ~= -1 then
		error('Sell.stepPrice: direction must be 1 or -1', 2)
	end
	local step = row.input and row.input.step or 1
	local current = price or (row.price and row.price.copper) or step
	local snapped = math.floor(current / step) * step
	if direction == 1 or snapped == current then
		snapped = snapped + direction * step
	end
	return math.max(step, snapped)
end

-- Helpers ---------------------------------------------------------------------------------

-- Carried entries grouped per item, in first-seen order; bound and worthless entries left out.
function groupCarried(carried, ctx)
	local groups, byItemId = {}, {}
	for _, entry in ipairs(carried) do
		local isSellable = type(entry) == 'table'
			and isWholePositive(entry.itemId)
			and isWholePositive(entry.count)
			and not entry.isBound
			and not entry.hasNoValue
		if isSellable then
			local group = byItemId[entry.itemId]
			if not group then
				group = { itemId = entry.itemId, count = 0, slots = {} }
				byItemId[entry.itemId] = group
				groups[#groups + 1] = group
			end
			group.count = group.count + entry.count
			group.slots[#group.slots + 1] = { bag = entry.bag, slot = entry.slot, count = entry.count }
		end
	end
	for _, group in ipairs(groups) do
		local facts = ns.PriceContext.facts(ctx, group.itemId)
		local isStackable = (facts.maxStack or 1) > 1
		group.facts = facts
		group.units = isStackable and group.count or 1
		group.listings = isStackable and 1 or group.count
	end
	return groups
end

function buildRow(group, rule, ruleId, ctx, deps)
	local price, reason = deps.prices:Get(group.itemId, ruleId, ctx)
	local facts = group.facts
	local hours = deps.durationHours or ns.Guardrail.DEFAULT_DURATION_HOURS
	local input = {
		price = price and price.copper,
		-- Unpriced, the step comes from the item's own market (whole silver for gear).
		step = price and price.step or ns.ItemMarket.forItem({
			maxStack = facts.maxStack,
			vendor = facts.vendor,
			copperSeen = ns.ItemMarket.hasCopper(facts.levels, facts.lowestListed),
		}).step,
		units = group.units,
		vendor = facts.vendor,
		salesPerDay = facts.salesPerDay,
		levels = facts.levels,
		antiBait = rule.antiBait,
		durationHours = hours,
		deposit = safeCall(deps.deposit, group.itemId, group.units, hours),
		threshold = deps.threshold,
		confidence = price and price.confidence,
	}
	local verdict = ns.Guardrail.verdict(input)
	return {
		itemId = group.itemId,
		count = group.count,
		units = group.units,
		listings = group.listings,
		slots = group.slots,
		price = price,
		reason = not price and reason or nil,
		verdict = verdict,
		check = ns.Guardrail.postCheck(verdict, deps.behaviour or ns.Guardrail.DEFAULT_BEHAVIOUR),
		input = input,
	}
end

-- Post first, then vendor, then hold; inside each, the higher expected net first (unpriced last).
function compareRows(a, b)
	local orderA, orderB = ACTION_ORDER[a.verdict.action] or 9, ACTION_ORDER[b.verdict.action] or 9
	if orderA ~= orderB then
		return orderA < orderB
	end
	local netA = (a.verdict.net or a.verdict.vendorNet or -math.huge) * a.listings
	local netB = (b.verdict.net or b.verdict.vendorNet or -math.huge) * b.listings
	if netA ~= netB then
		return netA > netB
	end
	return a.itemId < b.itemId
end

function isWholePositive(value)
	return type(value) == 'number' and value >= 1 and value < math.huge and value % 1 == 0
end

function safeCall(fn, ...)
	if type(fn) ~= 'function' then
		return nil
	end
	local ok, result = pcall(fn, ...)
	return ok and result or nil
end

return Sell
