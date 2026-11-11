--[[
	TooltipLines: builds Haggler's tooltip lines from a price quote (PriceService:Quote). Pure:
	no game calls, so every line is tested in luajit.

	  build(input) -> Line[]
	  input = { quote, stackCount, isUnitView, isDetail, options, theme }
	  options = { detailTrace, detailSales, detailListings, detailVendor, detailSellTime,
	              sellTimeNote }

	Compact view: a header with the data age, then one line per shown rule (default first) with
	the stack price, or the unit price in the unit view. A low-confidence price carries an
	explicit marker on its line, naming its top reason while the detail block is off; this
	cannot be switched off. The detail block adds how the default rule got its price, every
	confidence reason, sales a day, listings, vendor price and an estimated sell time with its
	note.

	Sell time = (units listed at or under the price + this stack) / units sold a day. It is an
	estimate from sales per day, not in-game time, and low confidence under one sale a day.
]]
local _, ns = ...

local TooltipLines = {}
ns.TooltipLines = TooltipLines

TooltipLines.TITLE = 'Haggler'
TooltipLines.LOW_MARKER = '(!) low'
TooltipLines.SELL_TIME_NOTE = 'estimate from sales per day, not in-game time'
local SECONDS_PER_HOUR = 3600
local SECONDS_PER_DAY = 86400
local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD = 10000
local LEVEL_COLORS = { low = 'color.state.danger', medium = 'color.state.warning', high = 'color.text.muted' }
-- A high-level reason informs and does not lower confidence (e.g. where sales a day comes from).
local LEVEL_MARKERS = { low = '(!)', medium = '(?)', high = '(i)' }

-- Helpers live at the bottom of the file; declared here so they stay local.
local headerLine, priceLine, traceLines, reasonLines, salesLine, listingsLine, vendorLine
local sellTimeLines, hasAnyData, defaultEntry, color, unitsAtOrUnder, formatSellTime, lowMarkerOf, topLowReason

--- Builds the lines for one item; an item Haggler knows nothing about gets none.
--- @param input table see the file header
--- @return table Line[]
function TooltipLines.build(input)
	local quote = input.quote
	if not hasAnyData(quote) then
		return {}
	end
	local stack = math.max(1, input.stackCount or 1)
	local view = {
		stack = input.isUnitView and 1 or stack,
		theme = input.theme,
		isUnitView = input.isUnitView,
		isDetail = input.isDetail,
	}
	local lines = { headerLine(quote.ages, view) }
	for _, entry in ipairs(quote.prices) do
		lines[#lines + 1] = priceLine(entry, view)
	end
	if not input.isDetail then
		return lines
	end
	local options = input.options or {}
	local main = defaultEntry(quote.prices)
	local detail = {}
	if options.detailTrace ~= false and main and main.price then
		traceLines(detail, main, view)
	end
	reasonLines(detail, quote.prices, view)
	if options.detailSales ~= false then
		detail[#detail + 1] = salesLine(quote.facts, view)
	end
	if options.detailListings ~= false then
		detail[#detail + 1] = listingsLine(quote.facts, view)
	end
	if options.detailVendor ~= false and quote.facts.vendor and quote.facts.vendor > 0 then
		detail[#detail + 1] = vendorLine(quote.facts, view)
	end
	if options.detailSellTime ~= false and main and main.price then
		sellTimeLines(detail, main.price, quote.facts, stack, options.sellTimeNote ~= false, view)
	end
	for _, line in ipairs(detail) do
		lines[#lines + 1] = line
	end
	return lines
end

--- Copper as '1g 20s 5c'; parts that are zero are left out ('0c' for nothing).
function TooltipLines.money(copper)
	copper = math.floor(copper or 0)
	local gold = math.floor(copper / COPPER_PER_GOLD)
	local silver = math.floor((copper % COPPER_PER_GOLD) / COPPER_PER_SILVER)
	local rest = copper % COPPER_PER_SILVER
	local parts = {}
	if gold > 0 then
		parts[#parts + 1] = gold .. 'g'
	end
	if silver > 0 then
		parts[#parts + 1] = silver .. 's'
	end
	if rest > 0 or #parts == 0 then
		parts[#parts + 1] = rest .. 'c'
	end
	return table.concat(parts, ' ')
end

--- An age in seconds as 'just now', '12 min', '3 h' or '4 d'.
function TooltipLines.age(seconds)
	if seconds < 60 then
		return 'just now'
	end
	if seconds < SECONDS_PER_HOUR then
		return math.floor(seconds / 60) .. ' min'
	end
	if seconds < SECONDS_PER_DAY then
		return math.floor(seconds / SECONDS_PER_HOUR) .. ' h'
	end
	return math.floor(seconds / SECONDS_PER_DAY) .. ' d'
end

--- How long ago, as 'just now', '12 min ago', '3 h ago' or '4 d ago'.
function TooltipLines.ago(seconds)
	local age = TooltipLines.age(seconds)
	return age == 'just now' and age or (age .. ' ago')
end

--- Days until a stack sells at a unit price, or nil without sales data.
--- @return number|nil days
--- @return boolean isLowConfidence
function TooltipLines.sellTimeDays(facts, unitPrice, stack)
	local salesPerDay = facts.salesPerDay
	if not salesPerDay or salesPerDay <= 0 then
		return nil, true
	end
	local days = (unitsAtOrUnder(facts.levels, unitPrice) + stack) / salesPerDay
	return days, salesPerDay < ns.Rules.CONFIDENCE.lowSalesPerDay
end

-- Helpers ---------------------------------------------------------------------------------

function headerLine(ages, view)
	local scanText = ages.scanAge and ('scan ' .. TooltipLines.age(ages.scanAge)) or 'no scan'
	local tableText = ages.tableAge and ('table ' .. TooltipLines.age(ages.tableAge)) or 'no table'
	return {
		left = TooltipLines.TITLE,
		right = scanText .. ' · ' .. tableText,
		color = color(view, 'color.text.accent'),
		rightColor = color(view, 'color.text.muted'),
	}
end

function priceLine(entry, view)
	local label = entry.name
	if view.isUnitView then
		label = label .. ' (each)'
	elseif view.stack > 1 then
		label = label .. ' ×' .. view.stack
	end
	local line = { left = label, color = color(view, 'color.text.secondary') }
	local price = entry.price
	if not price then
		line.right = 'no price'
		line.rightColor = color(view, 'color.text.muted')
		return line
	end
	line.right = TooltipLines.money(price.copper * view.stack)
	line.rightColor = color(view, 'color.text.primary')
	if price.confidence.level == 'low' then
		line.right = line.right .. ' ' .. view.theme:Wrap('color.state.danger', lowMarkerOf(price, view))
	end
	return line
end

-- The low marker; without the detail block (which lists every reason) it names the top one.
function lowMarkerOf(price, view)
	local reason = not view.isDetail and topLowReason(price.confidence.reasons) or nil
	return reason and (TooltipLines.LOW_MARKER .. ': ' .. reason.text) or TooltipLines.LOW_MARKER
end

function topLowReason(reasons)
	for _, reason in ipairs(type(reasons) == 'table' and reasons or {}) do
		if type(reason) == 'table' and reason.level == 'low' and type(reason.text) == 'string' then
			return reason
		end
	end
	return nil
end

-- How the default rule got its price, per unit. Confidence entries are left to reasonLines.
function traceLines(detail, entry, view)
	detail[#detail + 1] = { left = entry.name .. ', each:', color = color(view, 'color.text.muted') }
	for _, step in ipairs(entry.price.trace) do
		if step.kind ~= 'confidence' then
			local line = { left = '  ' .. step.label, color = color(view, 'color.text.muted') }
			if step.copper then
				line.right = TooltipLines.money(step.copper)
				line.rightColor = color(view, 'color.text.muted')
			end
			detail[#detail + 1] = line
		end
	end
end

function reasonLines(detail, entries, view)
	for _, entry in ipairs(entries) do
		local prefix = entry.isDefault and '' or (entry.name .. ': ')
		if not entry.price then
			detail[#detail + 1] = {
				left = prefix .. 'no price, ' .. tostring(entry.reason or 'no data'),
				color = color(view, 'color.text.muted'),
			}
		else
			for _, reason in ipairs(entry.price.confidence.reasons) do
				detail[#detail + 1] = {
					left = LEVEL_MARKERS[reason.level] .. ' ' .. prefix .. reason.text,
					color = color(view, LEVEL_COLORS[reason.level] or 'color.text.muted'),
				}
			end
		end
	end
end

function salesLine(facts, view)
	local right = 'unknown'
	if facts.salesPerDay then
		right = string.format('%.1f', facts.salesPerDay):gsub('%.0$', '')
		if facts.salesSource == 'own' then
			right = right .. ' · own scans'
		end
	end
	return {
		left = 'Sold a day',
		right = right,
		color = color(view, 'color.text.muted'),
		rightColor = color(view, 'color.text.secondary'),
	}
end

function listingsLine(facts, view)
	local right = 'no scan'
	if facts.listedUnits then
		right = string.format('%d units · %d prices', facts.listedUnits, facts.levelCount or 0)
	end
	return {
		left = 'Listed',
		right = right,
		color = color(view, 'color.text.muted'),
		rightColor = color(view, 'color.text.secondary'),
	}
end

function vendorLine(facts, view)
	return {
		left = 'Vendor',
		right = TooltipLines.money(facts.vendor * view.stack),
		color = color(view, 'color.text.muted'),
		rightColor = color(view, 'color.text.secondary'),
	}
end

function sellTimeLines(detail, price, facts, stack, hasNote, view)
	local days, isLow = TooltipLines.sellTimeDays(facts, price.copper, stack)
	local right = days and formatSellTime(days) or 'unknown, no sales data'
	if days and isLow then
		right = right .. ' ' .. view.theme:Wrap('color.state.danger', TooltipLines.LOW_MARKER)
	end
	detail[#detail + 1] = {
		left = 'Sell time',
		right = right,
		color = color(view, 'color.text.muted'),
		rightColor = color(view, 'color.text.secondary'),
	}
	if hasNote and days then
		detail[#detail + 1] = { left = '  ' .. TooltipLines.SELL_TIME_NOTE, color = color(view, 'color.text.muted') }
	end
end

function formatSellTime(days)
	if days < 1 then
		return string.format('~%d h', math.max(1, math.floor(days * 24 + 0.5)))
	end
	if days < 10 then
		return string.format('~%.1f days', days)
	end
	return string.format('~%d days', math.floor(days + 0.5))
end

function unitsAtOrUnder(levels, unitPrice)
	local units = 0
	for _, level in ipairs(levels or {}) do
		if type(level) == 'table' and type(level.price) == 'number' and type(level.qty) == 'number' then
			if level.price <= unitPrice then
				units = units + level.qty
			end
		end
	end
	return units
end

function hasAnyData(quote)
	if type(quote) ~= 'table' or type(quote.prices) ~= 'table' then
		return false
	end
	for _, entry in ipairs(quote.prices) do
		if entry.price then
			return true
		end
	end
	local facts = quote.facts or {}
	return facts.salesPerDay ~= nil or facts.listedUnits ~= nil or facts.lowestListed ~= nil
end

function defaultEntry(entries)
	for _, entry in ipairs(entries) do
		if entry.isDefault then
			return entry
		end
	end
	return entries[1]
end

function color(view, name)
	return view.theme:Color(name)
end

return TooltipLines
