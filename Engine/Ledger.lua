--[[
	Ledger: the append-only event log of one market (markets[marketKey].ledger). Events are never
	changed or deleted; totals are derived from them. Step 3 writes trade events; ventures, auction
	tracking and mail matching add their kinds in later steps.

	The log grows forever, so each event is stored as a compact tuple, not a keyed table:
	  { t, kind, itemId, qty, copper, char, ventureId, auctionId, flags }
	itemId and qty are 0 for gold; the last three are left off when 0. Read back as
	Event = { t, kind, itemId?, qty?, copper, char, ventureId?, auctionId?, isTroll? }.
	Events older than KEEP_DAYS are folded into per-day summaries (markets[key].ledgerDays):
	  ledgerDays[day] = { [kind] = { count, qty, copper } }   day = floor(t / 86400)

	Cash: sale (the buyer's bid), refund (the deposit back on a sale), vendorSell and gold traded in
	are income; buy, vendorBuy, deposit, cut and gold traded out are spending. Every other kind
	moves items, not gold. A sale whose unit price nets no more than the vendor pays is flagged
	troll (the spec's troll-buy filter) and left out of the realized price.

	  Ledger.append(market, event)  -> index    throws on a malformed event (a programmer error)
  Ledger.appendAll(market, events) -> count  validates every event first: all are written or none
	  Ledger.events(market, filter?) -> Event[] filter = { kind?, since? }
	  Ledger.tradeEvents(snapshot, t, char) -> Event[]   the events of one completed trade
	  Ledger.compact(market, now, keepDays?) -> count  folds old events into ledgerDays
	  Ledger.profit(market, since?, untilT?) -> Profit { income, spent, net, byKind }
	  Ledger.netSince(market, since, char?)  -> copper   one character's (or every) net gold since
	                                           a time, read from the raw tuples without decoding
	                                           them (the top bar's session profit). A start older
	                                           than KEEP_DAYS also counts the whole days folded
	                                           into summaries, which keep no character: those
	                                           days count every character's gold.
	  Ledger.daily(market, fromT, toT)      -> { { day, income, spent, net } } oldest first
	  Ledger.sellLog(market, filter?)       -> Event[] sales, newest first, with unitPrice
	  Ledger.purchaseLog(market, limit?)    -> Event[] auction and vendor buys, newest first
	  Ledger.realizedIndex(market, since)   -> { [itemId] = { copper, at } } troll sales left out

	Sessions: where "this session" starts, for session profit (the Ledger tab and the top bar).
	  Ledger.SESSION_MODES                  { { value, label } } login, daily, today, week, ahVisit, manual
	  Ledger.sessionStart(mode, facts)      -> start, note|nil   a start the client cannot give
	                                           falls back and says so in the note
	      facts = { now, loginAt?, resets = { daily?, weekly?, localDay?, localWeek? }, ahLeftAt?, resetAt? }
	  Ledger.localMidnight(now, clock, daysBack?) -> unix seconds|nil   local midnight daysBack days
	      before now's local day; clock = { date, time } (the client's date and time functions).
	      Built from the calendar date, not by subtracting hours, so a day with a daylight saving
	      change (23 or 25 hours) still starts at its midnight.
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
	refund = true,
	destroy = true,
	toStock = true,
}

-- Kinds that move gold: +1 income, -1 spending. Trades count only their gold (no itemId).
Ledger.CASH = {
	sale = 1,
	refund = 1,
	vendorSell = 1,
	tradeIn = 1,
	buy = -1,
	vendorBuy = -1,
	deposit = -1,
	cut = -1,
	tradeOut = -1,
}
Ledger.KEEP_DAYS = 90
Ledger.SECONDS_PER_DAY = 86400
Ledger.SESSION_MODES = {
	{ value = 'login', label = 'Since login' },
	{ value = 'daily', label = 'Since the daily reset' },
	{ value = 'today', label = 'Today' },
	{ value = 'week', label = 'This week' },
	{ value = 'ahVisit', label = 'Since leaving the auction house' },
	{ value = 'manual', label = 'Since Reset' },
}
-- A daylight saving change moves local midnight by at most this much against plain arithmetic.
local MAX_CLOCK_SHIFT_SECONDS = 3600

-- Tuple positions.
local T, KIND, ITEM, QTY, COPPER, CHAR, VENTURE, AUCTION, FLAGS = 1, 2, 3, 4, 5, 6, 7, 8, 9
local FLAG_TROLL = 1

-- Helpers live at the bottom of the file; declared here so they stay local.
local isWholeNonNegative, validateEvent, decode, appendSide, appendItem, encode, cashOf, addSummary
local summaryCash, dayOf, clockFields

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
	ledger[#ledger + 1] = encode(event)
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

--- Folds events older than keepDays into per-day summaries and drops them from the log.
--- Changes market.ledger and market.ledgerDays in place.
--- @param market table Store:Market(key)
--- @param now number unix seconds
--- @param keepDays number|nil default KEEP_DAYS
--- @return number count of events folded
function Ledger.compact(market, now, keepDays)
	if type(market) ~= 'table' or type(market.ledger) ~= 'table' or type(now) ~= 'number' then
		error('Ledger.compact: needs a market with a ledger and a time', 2)
	end
	market.ledgerDays = type(market.ledgerDays) == 'table' and market.ledgerDays or {}
	-- Whole days only, so a day is never half summary, half events.
	local cutoffDay = dayOf(now) - (keepDays or Ledger.KEEP_DAYS)
	local kept, folded = {}, 0
	for _, tuple in ipairs(market.ledger) do
		local event = decode(tuple)
		if event and dayOf(event.t) < cutoffDay then
			addSummary(market.ledgerDays, event)
			folded = folded + 1
		elseif event then
			kept[#kept + 1] = tuple
		end
	end
	market.ledger = kept
	return folded
end

--- Gold in and out over a period, from raw events and the day summaries.
--- @param market table|nil
--- @param since number|nil unix seconds, inclusive (nil: everything)
--- @param untilT number|nil unix seconds, exclusive (nil: now and on)
--- @return table Profit { income, spent, net, byKind = { [kind] = copper } }
function Ledger.profit(market, since, untilT)
	local profit = { income = 0, spent = 0, net = 0, byKind = {} }
	local function add(kind, copper)
		local sign = Ledger.CASH[kind]
		profit.byKind[kind] = (profit.byKind[kind] or 0) + copper
		if sign > 0 then
			profit.income = profit.income + copper
		else
			profit.spent = profit.spent + copper
		end
	end
	for _, event in ipairs(Ledger.events(market, { since = since })) do
		local copper = cashOf(event)
		if copper and (not untilT or event.t < untilT) then
			add(event.kind, copper)
		end
	end
	local days = type(market) == 'table' and type(market.ledgerDays) == 'table' and market.ledgerDays or {}
	for day, kinds in pairs(days) do
		local dayStart = type(day) == 'number' and day * Ledger.SECONDS_PER_DAY
		local isInside = dayStart
			and (not since or dayStart >= since)
			and (not untilT or dayStart + Ledger.SECONDS_PER_DAY <= untilT)
		for kind, copper in pairs(isInside and summaryCash(kinds) or {}) do
			add(kind, copper)
		end
	end
	profit.net = profit.income - profit.spent
	return profit
end

--- Net gold since a time, from the raw tuples: no event table is built, so it is cheap
--- enough to run on every money change. Junk tuples are skipped, as Ledger.events skips them.
--- @param market table|nil
--- @param since number unix seconds, inclusive
--- @param char string|nil 'Name-Realm'; nil counts every character
--- @return number copper
function Ledger.netSince(market, since, char)
	local ledger = type(market) == 'table' and type(market.ledger) == 'table' and market.ledger or {}
	local net = 0
	for _, tuple in ipairs(ledger) do
		local sign = type(tuple) == 'table' and Ledger.CASH[tuple[KIND]]
		local isCounted = sign
			and type(tuple[T]) == 'number'
			and tuple[T] >= since
			and (char == nil or tuple[CHAR] == char)
			and isWholeNonNegative(tuple[COPPER])
			-- A traded item stack moves no gold (cashOf).
			and not ((tuple[KIND] == 'tradeIn' or tuple[KIND] == 'tradeOut') and tuple[ITEM] ~= 0)
		if isCounted then
			net = net + sign * tuple[COPPER]
		end
	end
	local days = type(market) == 'table' and type(market.ledgerDays) == 'table' and market.ledgerDays or {}
	for day, kinds in pairs(days) do
		local isInside = type(day) == 'number' and day * Ledger.SECONDS_PER_DAY >= since
		for kind, copper in pairs(isInside and summaryCash(kinds) or {}) do
			net = net + Ledger.CASH[kind] * copper
		end
	end
	return net
end

--- Income, spending and net per day (UTC days), raw events and summaries alike.
--- @param market table|nil
--- @param fromT number unix seconds
--- @param toT number unix seconds
--- @return table { { day, income, spent, net } } oldest first, one row per day with any cash
function Ledger.daily(market, fromT, toT)
	local firstDay, lastDay = dayOf(fromT), dayOf(toT)
	local byDay = {}
	local function add(day, kind, copper)
		if day < firstDay or day > lastDay then
			return
		end
		local row = byDay[day] or { day = day, income = 0, spent = 0 }
		byDay[day] = row
		if Ledger.CASH[kind] > 0 then
			row.income = row.income + copper
		else
			row.spent = row.spent + copper
		end
	end
	-- One pass over the ledger and the summaries, bucketed by day.
	for _, event in ipairs(Ledger.events(market, { since = firstDay * Ledger.SECONDS_PER_DAY })) do
		local copper = cashOf(event)
		if copper then
			add(dayOf(event.t), event.kind, copper)
		end
	end
	local days = type(market) == 'table' and type(market.ledgerDays) == 'table' and market.ledgerDays or {}
	for day, kinds in pairs(days) do
		for kind, copper in pairs(type(day) == 'number' and summaryCash(kinds) or {}) do
			add(day, kind, copper)
		end
	end
	local rows = {}
	for day = firstDay, lastDay do
		local row = byDay[day]
		if row and (row.income > 0 or row.spent > 0) then
			row.net = row.income - row.spent
			rows[#rows + 1] = row
		end
	end
	return rows
end

--- Purchases (auction and vendor buys), newest first.
--- @param market table|nil
--- @param limit number|nil the most to return
--- @return table Event[]
function Ledger.purchaseLog(market, limit)
	local events = Ledger.events(market)
	local log = {}
	for index = #events, 1, -1 do
		local event = events[index]
		if event.kind == 'buy' or event.kind == 'vendorBuy' then
			log[#log + 1] = event
			if limit and #log >= limit then
				break
			end
		end
	end
	return log
end

--- Sales, newest first, each with its unit price (rounded down).
--- @param market table|nil
--- @param filter table|nil { itemId?, since?, limit? }
--- @return table Event[] with unitPrice
function Ledger.sellLog(market, filter)
	local sales = Ledger.events(market, { kind = 'sale', since = filter and filter.since })
	local log = {}
	for index = #sales, 1, -1 do
		local sale = sales[index]
		if (not filter or not filter.itemId or sale.itemId == filter.itemId) and sale.itemId and sale.qty then
			sale.unitPrice = math.floor(sale.copper / sale.qty)
			log[#log + 1] = sale
			if filter and filter.limit and #log >= filter.limit then
				break
			end
		end
	end
	return log
end

--- The price actually got per item since a time: units-weighted average of the gross sale price,
--- troll sales left out, with the time of the last sale. Built once, read per item.
--- @param market table|nil
--- @param since number unix seconds
--- @return table { [itemId] = { copper, at } }
function Ledger.realizedIndex(market, since)
	local sums = {}
	for _, sale in ipairs(Ledger.events(market, { kind = 'sale', since = since })) do
		if sale.itemId and sale.qty and not sale.isTroll then
			local sum = sums[sale.itemId] or { copper = 0, qty = 0, at = 0 }
			sum.copper, sum.qty, sum.at = sum.copper + sale.copper, sum.qty + sale.qty, math.max(sum.at, sale.t)
			sums[sale.itemId] = sum
		end
	end
	local index = {}
	for itemId, sum in pairs(sums) do
		index[itemId] = { copper = math.floor(sum.copper / sum.qty), at = sum.at }
	end
	return index
end

--- When the session starts in a mode; a start the client cannot give falls back with a note.
--- @param mode string one of SESSION_MODES' values (an unknown one reads as login)
--- @param facts table see the file header
--- @return number start unix seconds
--- @return string|nil note why the start is a fallback
function Ledger.sessionStart(mode, facts)
	if type(facts) ~= 'table' or type(facts.now) ~= 'number' then
		error('Ledger.sessionStart: needs facts.now', 2)
	end
	local now = facts.now
	local resets = type(facts.resets) == 'table' and facts.resets or {}
	local loginAt = facts.loginAt or now
	local utcDay = now - now % Ledger.SECONDS_PER_DAY
	if mode == 'daily' then
		return resets.daily or utcDay, not resets.daily and 'daily reset unknown: since UTC midnight' or nil
	elseif mode == 'today' then
		return resets.localDay or utcDay, not resets.localDay and 'local time unknown: since UTC midnight' or nil
	elseif mode == 'week' then
		local fallback = resets.localWeek or (resets.localDay or utcDay) - 6 * Ledger.SECONDS_PER_DAY
		return resets.weekly or fallback, not resets.weekly and 'weekly reset unknown: the last 7 days' or nil
	elseif mode == 'ahVisit' then
		return facts.ahLeftAt or loginAt, not facts.ahLeftAt and 'no auction house visit yet: since login' or nil
	elseif mode == 'manual' then
		return facts.resetAt or loginAt, not facts.resetAt and 'not reset yet: since login' or nil
	end
	return loginAt, nil
end

--- Local midnight, daysBack days before now's local day; nil when the client cannot say.
--- @param now number unix seconds
--- @param clock table { date = fn(format, t), time = fn(fields)? }
--- @param daysBack number|nil 0 (today) by default
--- @return number|nil unix seconds
function Ledger.localMidnight(now, clock, daysBack)
	daysBack = daysBack or 0
	local fields = clockFields(clock, now)
	if not fields then
		return nil
	end
	local sinceMidnight = fields.hour * 3600 + fields.min * 60 + fields.sec
	local plain = now - sinceMidnight - daysBack * Ledger.SECONDS_PER_DAY
	local ok, midnight = pcall(type(clock.time) == 'function' and clock.time or error, {
		year = fields.year,
		month = fields.month,
		day = fields.day - daysBack,
		hour = 0,
		min = 0,
		sec = 0,
	})
	-- Trust the calendar's answer only when it reads back as (about) midnight near the plain one:
	-- a clock that ignores its argument, or answers junk, falls back to the arithmetic.
	local back = ok and type(midnight) == 'number' and clockFields(clock, midnight) or nil
	local isMidnight = back ~= nil and back.hour <= 1 and back.min == 0 and back.sec == 0
	if isMidnight and midnight <= now and math.abs(midnight - plain) <= MAX_CLOCK_SHIFT_SECONDS then
		return midnight
	end
	return plain
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
	if event.ventureId ~= nil and not (isWholeNonNegative(event.ventureId) and event.ventureId > 0) then
		return 'ventureId must be a whole number above 0'
	end
	if event.auctionId ~= nil and not (isWholeNonNegative(event.auctionId) and event.auctionId > 0) then
		return 'auctionId must be a whole number above 0'
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
		ventureId = tuple[VENTURE] ~= 0 and tuple[VENTURE] or nil,
		auctionId = tuple[AUCTION] ~= 0 and tuple[AUCTION] or nil,
		isTroll = type(tuple[FLAGS]) == 'number' and tuple[FLAGS] % 2 == FLAG_TROLL or nil,
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

-- The tuple, its optional tail left off while it is all zeros.
function encode(event)
	local tuple = { event.t, event.kind, event.itemId or 0, event.qty or 0, event.copper, event.char }
	local tail = { event.ventureId or 0, event.auctionId or 0, event.isTroll and FLAG_TROLL or 0 }
	local last = 0
	for index, value in ipairs(tail) do
		if value ~= 0 then
			last = index
		end
	end
	for index = 1, last do
		tuple[CHAR + index] = tail[index]
	end
	return tuple
end

-- The gold an event moves, or nil when it moves none.
function cashOf(event)
	if not Ledger.CASH[event.kind] then
		return nil
	end
	if (event.kind == 'tradeIn' or event.kind == 'tradeOut') and event.itemId then
		return nil
	end
	return event.copper
end

-- Summaries keep only gold for trades: an item traded is filed under its own kind name.
function addSummary(days, event)
	local day = dayOf(event.t)
	local kinds = days[day] or {}
	days[day] = kinds
	local key = event.kind
	if (key == 'tradeIn' or key == 'tradeOut') and event.itemId then
		key = key .. 'Items'
	end
	local row = kinds[key] or { 0, 0, 0 }
	kinds[key] = { row[1] + 1, row[2] + (event.qty or 0), row[3] + event.copper }
end

function summaryCash(kinds)
	local cash = {}
	if type(kinds) ~= 'table' then
		return cash
	end
	for kind, row in pairs(kinds) do
		if Ledger.CASH[kind] and type(row) == 'table' and isWholeNonNegative(row[3]) then
			cash[kind] = row[3]
		end
	end
	return cash
end

function dayOf(t)
	return math.floor(t / Ledger.SECONDS_PER_DAY)
end

-- The local calendar fields of t, or nil when the clock cannot give them.
function clockFields(clock, t)
	if type(clock) ~= 'table' or type(clock.date) ~= 'function' then
		return nil
	end
	local ok, fields = pcall(clock.date, '*t', t)
	if not ok or type(fields) ~= 'table' then
		return nil
	end
	for _, key in ipairs({ 'year', 'month', 'day', 'hour', 'min', 'sec' }) do
		if type(fields[key]) ~= 'number' then
			return nil
		end
	end
	return fields
end

return Ledger
