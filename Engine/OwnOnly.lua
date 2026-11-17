--[[
	OwnOnly: the store migration to schema version 3 (ASK-M-005, "own"). Haggler keeps no value
	derived from AHledger. Before version 3, Books stored rule quotes, which can read AHledger, in
	craft events, writeOff and toStock events, venture materials (estimatedCopper), venture totals
	(leftoverCopper), cost pools (crafted leftovers moved to stock at their value) and traded item
	stacks (their value at the trade). None of it can be split by source, so it goes.

	Per market, in this order:
	  1. Tainted items: crafted outputs of ventures closed to stock. Their pools could hold a
	     value, so the shares taken from them are reset to unknown: auction records, venture
	     materials and destroy events of those items.
	  2. Events: craft, writeOff and toStock keep their cash part where the venture gives it
	     (Ventures.cashCost, or the venture's known copper for its only craft); otherwise copper
	     is cleared. Traded item stacks lose their value. Every event that loses copper is
	     flagged valueDropped. Money kinds are not touched.
	  3. Ventures: estimatedCopper and totals.leftoverCopper are dropped (estimates are read
	     live from knownCopper and the venture's rule); knownUnits is restored where the old
	     split is certain, else left nil (Ventures reads that split as lost).
	  4. ledgerDays: craft, writeOff, toStock and traded item rows lose copper, keep count and qty.
	  5. Cost pools: rebuilt from the buy events of the last Ledger.KEEP_DAYS, never more units
	     than the pool held; amounts older than that become unknown origin.

	Idempotent: a second run changes nothing. Nothing is parked under legacy, since keeping a
	derived value anywhere would break the rule.

	  OwnOnly.migrate(db, context)          context = { now? } unix seconds
	  OwnOnly.migrateMarket(market, now?)   now defaults to the newest ledger event
]]
local _, ns = ...

local OwnOnly = {}
ns.OwnOnly = OwnOnly

local SUMMARY_KINDS_WITHOUT_COPPER = {
	craft = true,
	writeOff = true,
	toStock = true,
	tradeInItems = true,
	tradeOutItems = true,
}
local BUY_KINDS = { buy = true, vendorBuy = true }

-- Helpers live at the bottom of the file; declared here so they stay local.
local isWhole, isTable, ventureList, taintedItems, resetTaintedShares, rewriteEvents, cashPartOf
local craftCashOf, leftoverCashOf, craftEventsByVenture, migrateVenture, migrateSummaries, rebuildPools
local newestEventTime, dropped

--- Migrates every market of a saved database. Changes db in place.
--- @param db table HagglerDB
--- @param context table|nil { now? }
function OwnOnly.migrate(db, context)
	if type(db) ~= 'table' then
		error('OwnOnly.migrate: db must be a table', 2)
	end
	local now = type(context) == 'table' and isWhole(context.now) and context.now or nil
	for _, market in pairs(isTable(db.markets) and db.markets or {}) do
		if isTable(market) then
			OwnOnly.migrateMarket(market, now)
		end
	end
end

--- Migrates one market. Changes market in place.
--- @param market table
--- @param now number|nil unix seconds
function OwnOnly.migrateMarket(market, now)
	if type(market) ~= 'table' then
		error('OwnOnly.migrateMarket: market must be a table', 2)
	end
	local ventures = ventureList(market)
	local tainted = taintedItems(ventures)
	resetTaintedShares(market, ventures, tainted)
	if isTable(market.ledger) then
		rewriteEvents(market, ventures, tainted)
	end
	for _, venture in pairs(ventures) do
		migrateVenture(venture)
	end
	migrateSummaries(market)
	rebuildPools(market, now or newestEventTime(market))
end

-- Helpers ---------------------------------------------------------------------------------

function isWhole(value)
	return type(value) == 'number' and value >= 0 and value < math.huge and value % 1 == 0
end

function isTable(value)
	return type(value) == 'table'
end

-- Well-formed ventures by id (Ventures.get's check); junk ones are left alone.
function ventureList(market)
	local list = {}
	for id, raw in pairs(isTable(market.ventures) and market.ventures or {}) do
		local venture = ns.Ventures.get(market, id)
		if venture and venture == raw then
			list[venture.id] = venture
		end
	end
	return list
end

function taintedItems(ventures)
	local tainted = {}
	for _, venture in pairs(ventures) do
		if venture.status == 'closed' and venture.leftoverAction == 'toStock' then
			for _, line in ipairs(venture.lines) do
				if isTable(line) and isWhole(line.itemId) then
					tainted[line.itemId] = true
				end
			end
		end
	end
	return tainted
end

function resetTaintedShares(market, ventures, tainted)
	for _, record in pairs(isTable(market.auctions) and market.auctions or {}) do
		if isTable(record) and tainted[record.itemId] then
			record.knownUnits, record.knownCopper = 0, 0
		end
	end
	for _, venture in pairs(ventures) do
		for itemId, material in pairs(venture.materials) do
			if tainted[itemId] and isTable(material) then
				material.knownUnits, material.knownCopper = 0, 0
			end
		end
	end
end

function rewriteEvents(market, ventures, tainted)
	local crafts = craftEventsByVenture(market)
	ns.Ledger.rewrite(market, function(event)
		local cash = cashPartOf(event, ventures, tainted, crafts)
		if cash == nil or cash >= event.copper then
			return nil
		end
		return dropped(event, cash)
	end)
end

-- The copper an event may keep, or nil when it keeps all of it.
function cashPartOf(event, ventures, tainted, crafts)
	local kind = event.kind
	if (kind == 'tradeIn' or kind == 'tradeOut') and event.itemId then
		return 0
	end
	if kind == 'destroy' and tainted[event.itemId] then
		return 0
	end
	if not ns.Ledger.OWN_VALUE_KINDS[kind] then
		return nil
	end
	local venture = event.ventureId and ventures[event.ventureId]
	if not venture then
		return 0
	end
	if kind == 'craft' then
		return craftCashOf(event, venture, tainted, crafts[venture.id])
	end
	return leftoverCashOf(event, venture)
end

-- A craft's cash part: all of it when the venture estimated nothing and no share was reset;
-- the venture's known copper when this is its only craft; else not known.
function craftCashOf(event, venture, tainted, craftsOfVenture)
	local estimated, isReset = 0, false
	for itemId, material in pairs(venture.materials) do
		estimated = estimated
			+ (isTable(material) and isWhole(material.estimatedCopper) and material.estimatedCopper or 0)
		isReset = isReset or tainted[itemId] == true
	end
	if estimated == 0 and not isReset then
		return nil
	end
	local crafted = 0
	for _, line in ipairs(venture.lines) do
		crafted = crafted + (isTable(line) and isWhole(line.crafted) and line.crafted or 0)
	end
	local isOnlyCraft = craftsOfVenture and craftsOfVenture.count == 1 and (event.qty or 0) == crafted
	if not isOnlyCraft then
		return 0
	end
	local known = 0
	for _, material in pairs(venture.materials) do
		known = known + (isTable(material) and isWhole(material.knownCopper) and material.knownCopper or 0)
	end
	return known
end

-- A leftover's cash part: what was paid for a material; for a crafted unit, its share of the
-- known copper, which only a paid-valuation venture recorded before version 3.
function leftoverCashOf(event, venture)
	if not event.itemId then
		return 0
	end
	local isCrafted = false
	for _, line in ipairs(venture.lines) do
		isCrafted = isCrafted or (isTable(line) and line.itemId == event.itemId)
	end
	if isCrafted and venture.valuation ~= 'paid' then
		return 0
	end
	local leftover = { itemId = event.itemId, qty = event.qty or 0, kind = isCrafted and 'crafted' or 'material' }
	return ns.Ventures.cashCost(venture, leftover)
end

function craftEventsByVenture(market)
	local byVenture = {}
	for _, event in ipairs(ns.Ledger.events(market, { kind = 'craft' })) do
		if event.ventureId then
			local entry = byVenture[event.ventureId] or { count = 0 }
			entry.count = entry.count + 1
			byVenture[event.ventureId] = entry
		end
	end
	return byVenture
end

function migrateVenture(venture)
	for _, material in pairs(venture.materials) do
		if isTable(material) then
			-- A legacy material still has estimatedCopper; a migrated one with a lost split does not.
			if material.knownUnits == nil and material.estimatedCopper ~= nil then
				local estimated = isWhole(material.estimatedCopper) and material.estimatedCopper or 0
				local known = isWhole(material.knownCopper) and material.knownCopper or 0
				local used = isWhole(material.used) and material.used or 0
				-- Certain only when one side is empty: all known, or nothing known.
				if known == 0 then
					material.knownUnits = 0
				elseif estimated == 0 then
					material.knownUnits = used
				end
			end
			material.estimatedCopper = nil
		end
	end
	venture.totals.leftoverCopper = nil
end

function migrateSummaries(market)
	for _, kinds in pairs(isTable(market.ledgerDays) and market.ledgerDays or {}) do
		for kind, row in pairs(isTable(kinds) and kinds or {}) do
			if SUMMARY_KINDS_WITHOUT_COPPER[kind] and isTable(row) then
				row[3] = 0
			end
		end
	end
end

function rebuildPools(market, now)
	if not isTable(market.costPools) then
		return
	end
	local since = (now or 0) - ns.Ledger.KEEP_DAYS * ns.Ledger.SECONDS_PER_DAY
	local bought = {}
	for _, event in ipairs(ns.Ledger.events(market, { since = since })) do
		if BUY_KINDS[event.kind] and event.itemId and event.qty then
			local sum = bought[event.itemId] or { units = 0, copper = 0 }
			sum.units, sum.copper = sum.units + event.qty, sum.copper + event.copper
			bought[event.itemId] = sum
		end
	end
	local pools = {}
	for itemId in pairs(market.costPools) do
		local held = ns.CostPool.get(market, itemId)
		local sum = bought[itemId]
		if held and sum and sum.units > 0 then
			local units = math.min(held.units, sum.units)
			pools[itemId] = { units, math.floor(sum.copper * units / sum.units) }
		end
	end
	market.costPools = pools
end

function newestEventTime(market)
	local newest
	for _, event in ipairs(ns.Ledger.events(market)) do
		newest = math.max(newest or event.t, event.t)
	end
	return newest
end

function dropped(event, cash)
	local copy = {}
	for key, value in pairs(event) do
		copy[key] = value
	end
	copy.copper, copy.valueDropped = cash, true
	return copy
end

return OwnOnly
