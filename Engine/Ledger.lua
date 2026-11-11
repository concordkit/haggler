--[[
	Ledger: the append-only event log of one market (markets[marketKey].ledger). Events are never
	changed or deleted; totals are derived from them. Step 3 writes trade events; ventures, auction
	tracking and mail matching add their kinds in later steps.

	The log grows forever, so each event is stored as a compact tuple, not a keyed table:
	  { t, kind, itemId, qty, copper, char }        itemId and qty are 0 for gold
	and read back as Event = { t, kind, itemId?, qty?, copper, char }.

	  Ledger.append(market, event)  -> index    throws on a malformed event (a programmer error)
  Ledger.appendAll(market, events) -> count  validates every event first: all are written or none
	  Ledger.events(market, filter?) -> Event[] filter = { kind?, since? }
	  Ledger.tradeEvents(snapshot, t, char) -> Event[]   the events of one completed trade
]]
local _, ns = ...

local Ledger = {}
ns.Ledger = Ledger

Ledger.KINDS = {
	buy = true,
	vendorBuy = true,
	vendorSell = true,
	post = true,
	deposit = true,
	sale = true,
	cut = true,
	expire = true,
	cancel = true,
	craft = true,
	mailIn = true,
	writeOff = true,
	tradeIn = true,
	tradeOut = true,
}

-- Tuple positions.
local T, KIND, ITEM, QTY, COPPER, CHAR = 1, 2, 3, 4, 5, 6

-- Helpers live at the bottom of the file; declared here so they stay local.
local isWholeNonNegative, validateEvent, decode, appendSide, appendItem

--- Appends one event to a market's ledger.
--- @param market table Store:Market(key)
--- @param event table { t, kind, itemId?, qty?, copper, char }
--- @return number index of the new entry
function Ledger.append(market, event)
	if type(market) ~= 'table' or type(market.ledger) ~= 'table' then
		error('Ledger.append: needs a market with a ledger', 2)
	end
	local problem = validateEvent(event)
	if problem then
		error('Ledger.append: ' .. problem, 2)
	end
	local ledger = market.ledger
	ledger[#ledger + 1] = { event.t, event.kind, event.itemId or 0, event.qty or 0, event.copper, event.char }
	return #ledger
end

--- Appends several events as one step: every event is checked before any is written, so a
--- malformed one cannot leave half a trade in the log.
--- @param market table Store:Market(key)
--- @param events table Event[]
--- @return number count of events written
function Ledger.appendAll(market, events)
	if type(market) ~= 'table' or type(market.ledger) ~= 'table' then
		error('Ledger.appendAll: needs a market with a ledger', 2)
	end
	if type(events) ~= 'table' then
		error('Ledger.appendAll: events must be a list', 2)
	end
	for index, event in ipairs(events) do
		local problem = validateEvent(event)
		if problem then
			error('Ledger.appendAll: event ' .. index .. ': ' .. problem, 2)
		end
	end
	for _, event in ipairs(events) do
		Ledger.append(market, event)
	end
	return #events
end

--- The market's events, oldest first, decoded. Entries that are not well-formed tuples (a hand
--- edit, a future format) are skipped, never an error.
--- @param market table|nil
--- @param filter table|nil { kind?, since? }
--- @return table Event[]
function Ledger.events(market, filter)
	local ledger = type(market) == 'table' and market.ledger or nil
	local events = {}
	for _, tuple in ipairs(type(ledger) == 'table' and ledger or {}) do
		local event = decode(tuple)
		local isWanted = event
			and (not filter or not filter.kind or event.kind == filter.kind)
			and (not filter or not filter.since or event.t >= filter.since)
		if isWanted then
			events[#events + 1] = event
		end
	end
	return events
end

--- The events of a completed trade: tradeOut for what the player gave, tradeIn for what they
--- got. Gold is one event with itemId 0; each item stack is one event whose copper is its value
--- at the time (0 when unpriced), so cost pools can take them in later. A stack the client had
--- not loaded (no itemId) is skipped: stored as itemId 0 it would read back as gold.
--- @param snapshot table { player = TradeSide, target = TradeSide } (Trade.side results)
--- @param t number unix seconds
--- @param char string 'Name-Realm'
--- @return table Event[]
function Ledger.tradeEvents(snapshot, t, char)
	if type(snapshot) ~= 'table' or type(t) ~= 'number' or type(char) ~= 'string' then
		error('Ledger.tradeEvents: needs a snapshot, a time and a character', 2)
	end
	local events = {}
	appendSide(events, snapshot.player, 'tradeOut', t, char)
	appendSide(events, snapshot.target, 'tradeIn', t, char)
	return events
end

-- Helpers ---------------------------------------------------------------------------------

function isWholeNonNegative(value)
	return type(value) == 'number' and value >= 0 and value < math.huge and value % 1 == 0
end

function validateEvent(event)
	if type(event) ~= 'table' then
		return 'event must be a table'
	end
	if not isWholeNonNegative(event.t) then
		return 't must be unix seconds'
	end
	if not Ledger.KINDS[event.kind] then
		return 'unknown kind ' .. tostring(event.kind)
	end
	-- itemId 0 is how gold is stored, so a given itemId must be a real one.
	if event.itemId ~= nil and not (isWholeNonNegative(event.itemId) and event.itemId > 0) then
		return 'itemId must be a whole number above 0'
	end
	if event.qty ~= nil and not isWholeNonNegative(event.qty) then
		return 'qty must be a whole number'
	end
	if not isWholeNonNegative(event.copper) then
		return 'copper must be whole copper, 0 or more'
	end
	if type(event.char) ~= 'string' or event.char == '' then
		return 'char is required'
	end
	return nil
end

function decode(tuple)
	if type(tuple) ~= 'table' then
		return nil
	end
	local event = {
		t = tuple[T],
		kind = tuple[KIND],
		itemId = tuple[ITEM] ~= 0 and tuple[ITEM] or nil,
		qty = tuple[QTY] ~= 0 and tuple[QTY] or nil,
		copper = tuple[COPPER],
		char = tuple[CHAR],
	}
	if validateEvent(event) then
		return nil
	end
	return event
end

function appendSide(events, side, kind, t, char)
	if type(side) ~= 'table' then
		return
	end
	if isWholeNonNegative(side.gold) and side.gold > 0 then
		events[#events + 1] = { t = t, kind = kind, copper = side.gold, char = char }
	end
	for _, item in ipairs(type(side.items) == 'table' and side.items or {}) do
		if isWholeNonNegative(item.itemId) and item.itemId > 0 then
			appendItem(events, item, kind, t, char)
		end
	end
end

function appendItem(events, item, kind, t, char)
	local copper = item.value and item.value.copper or 0
	events[#events + 1] = {
		t = t,
		kind = kind,
		itemId = item.itemId,
		qty = item.qty,
		copper = isWholeNonNegative(copper) and copper or 0,
		char = char,
	}
end

return Ledger
