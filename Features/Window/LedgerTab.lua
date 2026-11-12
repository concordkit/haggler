--[[
	Ledger tab: the market's books (Engine/Ledger.lua, kept by Features/Tracking.lua). Four
	views: the session's profit (gold in, gold out, net, by kind), profit per day, the sell log
	(newest first, troll buys marked) and purchases. The session starts where the player picks
	(Features/Sessions.lua, shared with the top bar): since login, the daily reset, today (local
	midnight), this week (the weekly reset), since leaving the auction house, or since the Reset
	button. A start the client cannot say falls back and says so. Old events are folded into day summaries, so the sell log and purchases
	reach back Ledger.KEEP_DAYS days while profit reaches back to the first event.

	  LedgerTab.sessionStart(mode, facts) -> start, note|nil   Ledger.sessionStart
	  LedgerTab.summaryLines(profit, title) · dailyLines(rows) · salesLines(events, nameOf)
	  · purchaseLines(events, nameOf) -> { { text, level? } }
	  LedgerTab.dayLabel(day) -> 'YYYY-MM-DD' for a UTC day number
]]
local _, ns = ...

local LedgerTab = {}
ns.LedgerTab = LedgerTab

LedgerTab.SESSION_MODES = ns.Ledger.SESSION_MODES
LedgerTab.sessionStart = ns.Ledger.sessionStart
LedgerTab.VIEWS = {
	{ value = 'summary', label = 'Session profit' },
	{ value = 'daily', label = 'Profit per day' },
	{ value = 'sales', label = 'Sell log' },
	{ value = 'purchases', label = 'Purchases' },
}

local KIND_LABELS = {
	sale = 'Sales',
	refund = 'Deposits back',
	vendorSell = 'Sold to vendors',
	tradeIn = 'Gold traded in',
	buy = 'Auction buys',
	vendorBuy = 'Vendor buys',
	deposit = 'Deposits',
	cut = 'Auction house cut',
	tradeOut = 'Gold traded out',
}
local SECONDS_PER_DAY = 86400
local DAYS_SHOWN = 30
local LOG_LIMIT = 300
local MAX_LINES = 22
local LINES_WIDTH = 860

-- Helpers live at the bottom of the file; declared here so they stay local.
local refresh, choiceIndex, cycle, signed, timeLabel, civilFromDays, marketNow

ns.window:AddTab({
	key = 'ledger',
	label = 'Ledger',
	order = 60,
	build = function(container, ctx)
		local ui = ctx.ui
		container.viewPicker = ui:Stepper(container, 220, function(delta)
			local uiState = ns.store:Ui()
			uiState.ledgerView = cycle(LedgerTab.VIEWS, uiState.ledgerView, delta)
			refresh(container, ctx)
		end)
		container.viewPicker:SetPoint('TOPLEFT', container, 'TOPLEFT', 0, 0)
		container.sessionPicker = ui:Stepper(container, 300, function(delta)
			if ns.sessions then
				ns.sessions:SetMode(cycle(LedgerTab.SESSION_MODES, ns.sessions:Mode(), delta))
			end
			refresh(container, ctx)
		end)
		container.sessionPicker:SetPoint('LEFT', container.viewPicker, 'RIGHT', 8, 0)
		local reset = ui:Button(container, 'Reset', 'secondary')
		reset:SetPoint('LEFT', container.sessionPicker, 'RIGHT', 8, 0)
		reset:OnClick(function()
			if ns.sessions then
				ns.sessions:Reset()
			end
			refresh(container, ctx)
		end)
		container.lines = ui:PagedLines(container, MAX_LINES, 13, LINES_WIDTH)
		container.lines.frame:SetPoint('TOPLEFT', container.viewPicker, 'BOTTOMLEFT', 0, -12)
	end,
	refresh = function(container, ctx)
		refresh(container, ctx)
	end,
})

--- The session's profit: gold in, gold out, net, then each kind, largest first.
function LedgerTab.summaryLines(profit, title)
	local money = ns.TooltipLines.money
	local lines = {
		{ text = title },
		{ text = 'Gold in  ' .. money(profit.income) },
		{ text = 'Gold out ' .. money(profit.spent) },
		{ text = 'Net      ' .. signed(profit.net), level = profit.net < 0 and 'low' or nil },
		{ text = '' },
	}
	local kinds = {}
	for kind, copper in pairs(profit.byKind or {}) do
		if copper ~= 0 then
			kinds[#kinds + 1] = { kind = kind, copper = copper }
		end
	end
	table.sort(kinds, function(a, b)
		return math.abs(a.copper) > math.abs(b.copper) or (math.abs(a.copper) == math.abs(b.copper) and a.kind < b.kind)
	end)
	for _, entry in ipairs(kinds) do
		local sign = (ns.Ledger.CASH[entry.kind] or 1) < 0 and -1 or 1
		lines[#lines + 1] = {
			text = string.format(
				'%-20s %s',
				KIND_LABELS[entry.kind] or entry.kind,
				signed(sign * math.abs(entry.copper))
			),
		}
	end
	if #kinds == 0 then
		lines[#lines + 1] = { text = 'Nothing booked in this session yet.' }
	end
	return lines
end

--- Profit per day, newest first.
function LedgerTab.dailyLines(rows)
	local money = ns.TooltipLines.money
	local lines = {}
	for index = #rows, 1, -1 do
		local row = rows[index]
		lines[#lines + 1] = {
			text = string.format(
				'%s   in %s   out %s   net %s',
				LedgerTab.dayLabel(row.day),
				money(row.income),
				money(row.spent),
				signed(row.net)
			),
			level = row.net < 0 and 'low' or nil,
		}
	end
	if #lines == 0 then
		lines[1] = { text = 'No gold moved in the last ' .. DAYS_SHOWN .. ' days.' }
	end
	return lines
end

--- The sell log: each sale with its units and unit price; a troll buy is marked.
function LedgerTab.salesLines(events, nameOf)
	local money = ns.TooltipLines.money
	local lines = {}
	for _, event in ipairs(events) do
		lines[#lines + 1] = {
			text = string.format(
				'%s  %s ×%d  %s each  %s%s',
				timeLabel(event.t),
				nameOf(event.itemId),
				event.qty,
				money(event.unitPrice or 0),
				money(event.copper),
				event.isTroll and '  troll buy: no better than vendoring' or ''
			),
			level = event.isTroll and 'medium' or nil,
		}
	end
	if #lines == 0 then
		lines[1] = { text = 'No sales booked yet.' }
	end
	return lines
end

--- Auction and vendor purchases; the events come newest first (Ledger.purchaseLog).
function LedgerTab.purchaseLines(events, nameOf)
	local money = ns.TooltipLines.money
	local lines = {}
	for _, event in ipairs(events) do
		lines[#lines + 1] = {
			text = string.format(
				'%s  %s ×%d  %s  %s',
				timeLabel(event.t),
				nameOf(event.itemId),
				event.qty,
				money(event.copper),
				event.kind == 'vendorBuy' and 'vendor' or 'auction'
			),
		}
	end
	if #lines == 0 then
		lines[1] = { text = 'No purchases booked yet.' }
	end
	return lines
end

--- 'YYYY-MM-DD' for a UTC day number (days since 1970-01-01).
function LedgerTab.dayLabel(day)
	local year, month, dayOfMonth = civilFromDays(day)
	return string.format('%04d-%02d-%02d', year, month, dayOfMonth)
end

-- Helpers ---------------------------------------------------------------------------------

function refresh(container, ctx)
	local market = marketNow()
	local uiState = ns.store:Ui()
	local view = LedgerTab.VIEWS[choiceIndex(LedgerTab.VIEWS, uiState.ledgerView)]
	local sessions = ns.sessions
	container.viewPicker:SetValue(view.label)
	container.sessionPicker:SetValue(sessions and sessions:ModeLabel() or 'Since login')
	if not market then
		container.lines:SetLines({ { text = 'The market is not known yet.', level = 'medium' } })
		return
	end
	local now = ctx.wow:Now()
	local nameOf = function(itemId)
		local info = ns.prices and ns.prices:ItemInfo(itemId)
		return info and info.name or ('Item ' .. tostring(itemId))
	end
	local lines
	if view.value == 'summary' then
		local start, note = now, 'sessions are off'
		if sessions then
			start, note = sessions:Start(now)
		end
		local title = (sessions and sessions:ModeLabel() or 'Since now') .. (note and (' (' .. note .. ')') or '')
		lines = LedgerTab.summaryLines(ns.Ledger.profit(market, start), title)
	elseif view.value == 'daily' then
		lines = LedgerTab.dailyLines(ns.Ledger.daily(market, now - (DAYS_SHOWN - 1) * SECONDS_PER_DAY, now))
	elseif view.value == 'sales' then
		lines = LedgerTab.salesLines(ns.Ledger.sellLog(market, { limit = LOG_LIMIT }), nameOf)
	else
		lines = LedgerTab.purchaseLines(ns.Ledger.purchaseLog(market, LOG_LIMIT), nameOf)
	end
	container.lines:SetLines(lines)
end

function choiceIndex(choices, value)
	for index, choice in ipairs(choices) do
		if choice.value == value then
			return index
		end
	end
	return 1
end

function cycle(choices, value, delta)
	local index = (choiceIndex(choices, value) - 1 + delta) % #choices + 1
	return choices[index].value
end

function signed(copper)
	return (copper < 0 and '-' or '+') .. ns.TooltipLines.money(math.abs(copper))
end

function timeLabel(t)
	local day = math.floor(t / SECONDS_PER_DAY)
	local seconds = t % SECONDS_PER_DAY
	return string.format(
		'%s %02d:%02d',
		LedgerTab.dayLabel(day),
		math.floor(seconds / 3600),
		math.floor(seconds % 3600 / 60)
	)
end

-- Howard Hinnant's days-to-civil algorithm (proleptic Gregorian, UTC).
function civilFromDays(days)
	local z = days + 719468
	local era = math.floor(z / 146097)
	local dayOfEra = z - era * 146097
	local yearOfEra = math.floor(
		(dayOfEra - math.floor(dayOfEra / 1460) + math.floor(dayOfEra / 36524) - math.floor(dayOfEra / 146096)) / 365
	)
	local dayOfYear = dayOfEra - (365 * yearOfEra + math.floor(yearOfEra / 4) - math.floor(yearOfEra / 100))
	local monthIndex = math.floor((5 * dayOfYear + 2) / 153)
	local dayOfMonth = dayOfYear - math.floor((153 * monthIndex + 2) / 5) + 1
	local month = monthIndex < 10 and monthIndex + 3 or monthIndex - 9
	local year = yearOfEra + era * 400 + (month <= 2 and 1 or 0)
	return year, month, dayOfMonth
end

function marketNow()
	local marketKey = ns.prices and ns.prices:MarketKey()
	return marketKey and ns.store:Market(marketKey) or nil
end
