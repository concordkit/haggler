--[[
	PriceData: the AHledger price table. Prices from AHledger (https://ahledger.com).

	A table is text in AHledger's own format, the same one its API serves at
	/v1/pricetable/<market>:

	  AHL1|<market>|<updated unix seconds>|<rows>          optional header
	  <id>:<median>:<min>:<qty>:<m7>:<m30>:<lo>:<hi>:<sold>

	Rows are separated by newlines or ';'. Prices are copper and an empty field is unknown (nil),
	quantity included. The ninth field is units sold a day times ten; it may be missing in older
	tables, and fields after it are ignored so a newer table still reads. Parsed rows are
	PriceRow = { median, min, qty, m7, m30, lo, hi, sold }, where sold is units sold a day (already
	divided by ten) or nil.

	A library holds the raw text per market and parses a table on first use, so loading the
	add-on costs nothing until a price is asked for. The desktop app writes Data/PriceTable.lua in
	AHledger's own saved shape, HagglerPriceTable[marketKey] = { updated, count, text }, which
	AddSavedTables loads as it is.
]]
local _, ns = ...

local PriceData = {}
ns.PriceData = PriceData

PriceData.FORMAT = 'AHL1'
-- Anything dearer than this is a broken field, not a price (about 110 million gold).
PriceData.MAX_COPPER = 2 ^ 40
-- Over ten million sold a day is not a market; a pasted figure can overflow to infinity.
PriceData.MAX_SOLD_PER_DAY = 10000000

local MIN_ROW_FIELDS = 8
local KNOWN_ROW_FIELDS = 9
local HEADER_PATTERN = '^(%w+)|([%w/%-]+)|(%d+)|(%d+)'

-- Helpers live at the bottom of the file; declared here so they stay local.
local parseRow, parseHeader, copperField, splitFields

--- Parses rows only (no header).
--- @param text string
--- @return table items { [itemId] = PriceRow }
--- @return number count rows read
--- @return number skipped lines that were not rows
function PriceData.parseRows(text)
	if type(text) ~= 'string' then
		error('PriceData.parseRows: text must be a string', 2)
	end
	local items, count, skipped = {}, 0, 0
	for line in text:gmatch('[^\n;]+') do
		local itemId, row = parseRow(line)
		if itemId then
			if not items[itemId] then
				count = count + 1
			end
			items[itemId] = row
		elseif line:find('%S') then
			skipped = skipped + 1
		end
	end
	return items, count, skipped
end

--- Parses a full table, with or without the AHL1 header.
--- @param text string
--- @return table|nil table { market, updated, declared, items, count, skipped }
--- @return string|nil reason 'empty', 'unknown format' or 'no rows'
function PriceData.parse(text)
	if type(text) ~= 'string' or not text:find('%S') then
		return nil, 'empty'
	end
	local body = text:gsub('^%s+', '')
	local firstLine, rest = body:match('^([^\n]*)\n?(.*)$')
	local header, reason = parseHeader(firstLine)
	if reason then
		return nil, reason
	end
	local items, count, skipped = PriceData.parseRows(header and rest or body)
	if count == 0 then
		return nil, 'no rows'
	end
	return {
		market = header and header.market,
		updated = header and header.updated,
		declared = header and header.declared,
		items = items,
		count = count,
		skipped = skipped,
	}
end

local LibraryMethods = {}
LibraryMethods.__index = LibraryMethods

--- A set of price tables keyed by market, parsed lazily.
function PriceData.newLibrary()
	return setmetatable({ rawByMarket = {}, parsedByMarket = {}, failureByMarket = {} }, LibraryMethods)
end

--- Adds (or replaces) a market's raw table text.
--- @param marketKey string
--- @param text string
--- @param updated number|nil unix seconds; the header's value wins when present
function LibraryMethods:AddRaw(marketKey, text, updated)
	if type(marketKey) ~= 'string' or type(text) ~= 'string' then
		error('PriceData library: marketKey and text must be strings', 2)
	end
	self.rawByMarket[marketKey] = { text = text, updated = updated }
	self.parsedByMarket[marketKey] = nil
	self.failureByMarket[marketKey] = nil
end

--- The parsed table of a market.
--- @return table|nil table as PriceData.parse
--- @return string|nil reason 'no table' or a parse reason
function LibraryMethods:Table(marketKey)
	local parsed = self.parsedByMarket[marketKey]
	if parsed then
		return parsed
	end
	if self.failureByMarket[marketKey] then
		return nil, self.failureByMarket[marketKey]
	end
	local raw = self.rawByMarket[marketKey]
	if not raw then
		return nil, 'no table'
	end
	local result, reason = PriceData.parse(raw.text)
	if not result then
		self.failureByMarket[marketKey] = reason
		return nil, reason
	end
	result.market = result.market or marketKey
	result.updated = result.updated or raw.updated
	self.parsedByMarket[marketKey] = result
	return result
end

--- Adds every table of a saved HagglerPriceTable ({ [marketKey] = { updated, count, text } }).
--- Entries of any other shape are skipped.
--- @param savedTables table|nil
--- @return number tables added
function LibraryMethods:AddSavedTables(savedTables)
	if type(savedTables) ~= 'table' then
		return 0
	end
	local added = 0
	for marketKey, saved in pairs(savedTables) do
		if type(marketKey) == 'string' and type(saved) == 'table' and type(saved.text) == 'string' then
			self:AddRaw(marketKey, saved.text, tonumber(saved.updated))
			added = added + 1
		end
	end
	return added
end

--- One item's row and the table's update time.
--- @return table|nil row PriceRow
--- @return number|nil updated unix seconds, when known
function LibraryMethods:Row(marketKey, itemId)
	local priceTable = self:Table(marketKey)
	if not priceTable then
		return nil
	end
	local row = priceTable.items[itemId]
	if not row then
		return nil
	end
	return row, priceTable.updated
end

-- Helpers ---------------------------------------------------------------------------------

-- Returns itemId, PriceRow; or nil for a line that is not a valid row.
function parseRow(line)
	local fields = splitFields(line:match('^%s*(.-)%s*$'))
	if #fields < MIN_ROW_FIELDS then
		return nil
	end
	for index = 1, KNOWN_ROW_FIELDS do
		if fields[index] ~= nil and not fields[index]:find('^%d*$') then
			return nil
		end
	end
	local id, median, min, qty, m7, m30, lo, hi, sold = unpack(fields, 1, KNOWN_ROW_FIELDS)
	local itemId = tonumber(id)
	if not itemId or itemId < 1 then
		return nil
	end
	local soldTimesTen = tonumber(sold)
	local soldPerDay = soldTimesTen and soldTimesTen / 10
	if soldPerDay and soldPerDay > PriceData.MAX_SOLD_PER_DAY then
		soldPerDay = nil
	end
	local quantity = tonumber(qty)
	return itemId,
		{
			median = copperField(median),
			min = copperField(min),
			qty = (quantity and quantity <= PriceData.MAX_COPPER) and quantity or nil,
			m7 = copperField(m7),
			m30 = copperField(m30),
			lo = copperField(lo),
			hi = copperField(hi),
			sold = soldPerDay,
		}
end

-- Returns the header, nil when the line is not a header, or nil and a reason for an unknown
-- format. The client escapes a pasted pipe as '||', so the header is unescaped first.
function parseHeader(line)
	if not line:find('|', 1, true) then
		return nil
	end
	local unescaped = line:gsub('||', '|')
	local format, market, updated, declared = unescaped:match(HEADER_PATTERN)
	if format ~= PriceData.FORMAT then
		return nil, 'unknown format'
	end
	return { market = market, updated = tonumber(updated), declared = tonumber(declared) }
end

-- Splits on ':' keeping empty fields ('1::3' is three fields).
function splitFields(text)
	local fields = {}
	local start = 1
	while true do
		local colon = text:find(':', start, true)
		if not colon then
			fields[#fields + 1] = text:sub(start)
			return fields
		end
		fields[#fields + 1] = text:sub(start, colon - 1)
		start = colon + 1
	end
end

-- A copper field: nil when empty, zero or out of range.
function copperField(text)
	local copper = tonumber(text)
	if not copper or copper <= 0 or copper > PriceData.MAX_COPPER then
		return nil
	end
	return copper
end

return PriceData
