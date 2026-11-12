--[[
	PriceData: where market prices come from. Prices from AHledger (https://ahledger.com).

	Prices go through one swappable source. The default reads AHledger's public, read-only
	AHledgerAPI (v1); a Haggler-owned source (a table of its own) could plug in later without
	touching Rules, PriceContext or PriceService, as long as it keeps this shape:

	  PriceSource
	    id                              short name, e.g. 'ahledger'
	    source:Status(marketKey?)    -> { isAvailable, code?, reason?, credit?, market? }
	                                    with a market key, available only when the source has
	                                    prices for that market. code says why not:
	                                    noPriceSource (missing or unusable), priceSourceFailing
	                                    (its calls fail), noMarketTable (nothing for this
	                                    market); reason says it to the player. credit is the
	                                    line to show with prices from it; market is the market
	                                    the source itself is set to, when it has one
	    source:Row(marketKey, itemId) -> PriceRow, updated  · or nil when the item has no price
	                                    (nil, nil, 'priceSourceFailing' when the call failed)
	    source:Table(marketKey)       -> { market, updated, count, isSnapshot } · or nil, reason

	  PriceRow = { median, min, qty, m7, m30, lo, hi, sold, isSnapshot }
	    copper per unit, qty units listed, sold units sold a day; nil is unknown. A present field
	    that is not a usable number is passed on as junk (Rules notes it as bad input) and an
	    out-of-range number reads as infinity, which is junk too. isSnapshot is true when the
	    figures come from the copy bundled with AHledger rather than a synced table.
	  updated: unix seconds of the data, nil when unknown (Rules then says the age is unknown).

	A source never throws: a missing add-on, an unknown API version, a missing item or a reply of
	an unexpected shape gives no row (or a Status with a reason), never an error.

	statusOf(source, marketKey) is the one safe reader of Status for the rest of the add-on: it
	never throws, whatever the source does, and always returns a well-formed status.
]]
local _, ns = ...

local PriceData = {}
ns.PriceData = PriceData

-- Anything dearer than this is a broken field, not a price (about 110 million gold).
PriceData.MAX_COPPER = 2 ^ 40
-- Over ten million sold a day is not a market.
PriceData.MAX_SOLD_PER_DAY = 10000000
-- The AHledgerAPI version Haggler reads; AHledger changes it only on an incompatible change.
PriceData.AHLEDGER_API_VERSION = 1
PriceData.DEFAULT_CREDIT = 'Prices from AHledger (ahledger.com)'
PriceData.REQUIRED_METHODS = { 'Status', 'Row', 'Table' }
-- Why a source has no prices for a market; Rules turns each into a low-confidence reason.
PriceData.PROBLEM_CODES = { noPriceSource = true, priceSourceFailing = true, noMarketTable = true }

local MAX_CREDIT_LENGTH = 120
-- AHledgerAPI fields -> PriceRow fields, with how each is checked.
local COPPER_FIELDS = {
	median = 'median',
	minBuyout = 'min',
	median7d = 'm7',
	median30d = 'm30',
	low30d = 'lo',
	high30d = 'hi',
}

-- Helpers live at the bottom of the file; declared here so they stay local.
local resolveApi, callApi, readApiField, isTableFor, toPriceRow, copperField, countField, timeOrNil
local creditOf, stringOrNil

--- Whether a value has the PriceSource shape (see the file header).
--- @param value any
--- @return boolean
function PriceData.isSource(value)
	if type(value) ~= 'table' then
		return false
	end
	for _, method in ipairs(PriceData.REQUIRED_METHODS) do
		if type(value[method]) ~= 'function' then
			return false
		end
	end
	return true
end

--- A source's status for a market, safe and well-formed whatever the source does.
--- @param source table|nil a PriceSource
--- @param marketKey string|nil
--- @return table { isAvailable = true, credit?, market? } · { isAvailable = false, code, reason, market? }
function PriceData.statusOf(source, marketKey)
	if source == nil then
		return { isAvailable = false, code = 'noPriceSource', reason = 'no price source' }
	end
	local ok, status = pcall(function()
		return source:Status(marketKey)
	end)
	if not ok or type(status) ~= 'table' then
		return { isAvailable = false, code = 'priceSourceFailing', reason = 'the price source failed' }
	end
	if status.isAvailable == true then
		return { isAvailable = true, credit = stringOrNil(status.credit), market = stringOrNil(status.market) }
	end
	return {
		isAvailable = false,
		code = PriceData.PROBLEM_CODES[status.code] and status.code or 'noPriceSource',
		reason = stringOrNil(status.reason) or 'no prices',
		market = stringOrNil(status.market),
	}
end

local AHledgerMethods = {}
AHledgerMethods.__index = AHledgerMethods

--- The AHledgerAPI source. The API is looked up on every call, so a load order surprise or a
--- reload of AHledger is picked up without restarting Haggler.
--- @param getApi function fun(): any, the AHledgerAPI global (or whatever stands in its place)
--- @return table PriceSource
function PriceData.newAHledgerSource(getApi)
	if type(getApi) ~= 'function' then
		error('PriceData.newAHledgerSource: getApi must be a function', 2)
	end
	return setmetatable({ id = 'ahledger', getApi = getApi }, AHledgerMethods)
end

--- Whether AHledger has prices (for marketKey, when given). See the file header.
--- @param marketKey string|nil
--- @return table { isAvailable, code?, reason?, credit?, market? }
function AHledgerMethods:Status(marketKey)
	local api, reason = resolveApi(self.getApi)
	if not api then
		return { isAvailable = false, code = 'noPriceSource', reason = reason }
	end
	if type(marketKey) == 'string' then
		local info, hasFailed = callApi(api, 'GetTableInfo', marketKey)
		if hasFailed then
			return { isAvailable = false, code = 'priceSourceFailing', reason = 'AHledger calls fail' }
		end
		if not isTableFor(info, marketKey) then
			return {
				isAvailable = false,
				code = 'noMarketTable',
				reason = 'AHledger has no prices for ' .. marketKey,
				market = stringOrNil((callApi(api, 'GetMarket'))),
			}
		end
	end
	return { isAvailable = true, credit = creditOf(api), market = stringOrNil((callApi(api, 'GetMarket'))) }
end

--- One item's prices on a market.
--- @param marketKey string
--- @param itemId number
--- @return table|nil row PriceRow
--- @return number|nil updated unix seconds
--- @return string|nil problem 'priceSourceFailing' when the call failed
function AHledgerMethods:Row(marketKey, itemId)
	if type(marketKey) ~= 'string' or type(itemId) ~= 'number' then
		return nil
	end
	local api = resolveApi(self.getApi)
	if not api then
		return nil
	end
	local price, hasFailed = callApi(api, 'GetPrice', itemId, marketKey)
	if hasFailed then
		return nil, nil, 'priceSourceFailing'
	end
	if type(price) ~= 'table' then
		return nil
	end
	-- AHledger answers for the player's own market when it does not know the key asked for;
	-- those prices are not this market's.
	local market = readApiField(price, 'market')
	if market ~= nil and market ~= marketKey then
		return nil
	end
	return toPriceRow(price), timeOrNil(readApiField(price, 'updated'))
end

--- The table in use for a market.
--- @param marketKey string
--- @return table|nil { market, updated, count, isSnapshot }
--- @return string|nil reason
function AHledgerMethods:Table(marketKey)
	if type(marketKey) ~= 'string' then
		return nil, 'no market'
	end
	local api, reason = resolveApi(self.getApi)
	if not api then
		return nil, reason
	end
	local info = callApi(api, 'GetTableInfo', marketKey)
	if not isTableFor(info, marketKey) then
		return nil, 'no AHledger table for this market'
	end
	local count = readApiField(info, 'count')
	return {
		market = marketKey,
		updated = timeOrNil(readApiField(info, 'updated')),
		count = (type(count) == 'number' and count >= 0 and count < math.huge) and count or nil,
		isSnapshot = readApiField(info, 'snapshot') == true,
	}
end

-- Helpers ---------------------------------------------------------------------------------

-- The API when it is usable; else nil and a reason the player can read.
function resolveApi(getApi)
	local ok, api = pcall(getApi)
	if not ok or api == nil then
		return nil, 'AHledger is not loaded'
	end
	if type(api) ~= 'table' then
		return nil, 'AHledger API is not usable'
	end
	local version = readApiField(api, 'VERSION')
	if version ~= PriceData.AHLEDGER_API_VERSION then
		return nil,
			string.format(
				'AHledger API version %s is not supported (Haggler reads %d)',
				tostring(version),
				PriceData.AHLEDGER_API_VERSION
			)
	end
	if type(readApiField(api, 'GetPrice')) ~= 'function' then
		return nil, 'AHledger API has no GetPrice'
	end
	return api
end

-- Calls api[name](...) and returns its first result and whether the call threw; a missing
-- function is no result, not a failure.
function callApi(api, name, ...)
	local fn = readApiField(api, name)
	if type(fn) ~= 'function' then
		return nil, false
	end
	local ok, result = pcall(fn, ...)
	if not ok then
		return nil, true
	end
	return result, false
end

-- A field read that cannot throw, even through a broken metatable.
function readApiField(value, key)
	local ok, field = pcall(function()
		return value[key]
	end)
	return ok and field or nil
end

-- AHledger answers for its own market when it cannot read the key asked for; such a table is
-- not this market's.
function isTableFor(info, marketKey)
	if type(info) ~= 'table' then
		return false
	end
	local market = readApiField(info, 'market')
	return market == nil or market == marketKey
end

function toPriceRow(price)
	local row = {}
	for apiField, rowField in pairs(COPPER_FIELDS) do
		row[rowField] = copperField(readApiField(price, apiField))
	end
	row.qty = countField(readApiField(price, 'quantity'), PriceData.MAX_COPPER)
	row.sold = countField(readApiField(price, 'soldPerDay'), PriceData.MAX_SOLD_PER_DAY)
	row.isSnapshot = readApiField(price, 'snapshot') == true
	return row
end

-- Copper: nil when unknown or zero (AHledger has no price); junk passes on as it is, and an
-- out-of-range number becomes infinity so it reads as junk downstream.
function copperField(value)
	if type(value) ~= 'number' or value ~= value then
		return value
	end
	if value == 0 then
		return nil
	end
	if value < 0 or value > PriceData.MAX_COPPER then
		return math.huge
	end
	return value
end

-- A count (units listed, sold a day): zero is a real figure; junk as copperField.
function countField(value, max)
	if type(value) ~= 'number' or value ~= value then
		return value
	end
	if value < 0 or value > max then
		return math.huge
	end
	return value
end

function timeOrNil(value)
	if type(value) == 'number' and value > 0 and value < math.huge then
		return value
	end
	return nil
end

function creditOf(api)
	local credit = readApiField(api, 'CREDIT')
	if type(credit) == 'string' and credit:find('%S') and #credit <= MAX_CREDIT_LENGTH then
		return credit
	end
	return PriceData.DEFAULT_CREDIT
end

function stringOrNil(value)
	return type(value) == 'string' and value ~= '' and value or nil
end

return PriceData
