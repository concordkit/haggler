--[[
	Buy: the Buy tab's search, over the last scan (away from the AH, or before a live search) or
	over a live search's listings. Pure: game reads come in through deps.

	  Buy.fromSnapshot(snapshot, filter, deps) -> BuyRow[], isCapped
	      cheapest discount first, at most limit; isCapped when more candidates passed the cheap
	      checks than were priced (the search should be narrowed)
	  Buy.fromLive(results, filter, rulePrice?) -> BuyRow[]  one row per listing, own ones and item
	      auctions without an auction id left out
	  Buy.unitsWithin(results, maxUnitPrice, wantedUnits?) -> units, totalCopper
	      what a commodity buy up to a unit price takes, cheapest first (own listings skipped)

	filter = { text?, maxPrice?, underRulePercent?, underVendor? }
	  text              a case-insensitive part of the item's name (items without a known name
	                    are left out while text is set)
	  maxPrice          copper per unit, at most
	  underRulePercent  at least this many percent under the rule price
	  underVendor       under what a vendor pays for it (a flip to the vendor)

	deps = { itemName(itemId) -> string|nil, rulePrice(itemId) -> copper|nil, confidence?, reason?, usesPriceSource?,
	         vendorPrice(itemId) -> copper|nil, limit? (default LIMIT),
	         maxCandidates? (default MAX_CANDIDATES),
	         maxFilteredCandidates? (default MAX_FILTERED_CANDIDATES) }
	  itemName and vendorPrice are called for every item of the scan: they must only read what
	  is known already (PriceService:KnownName, :KnownVendorPrice), never ask the client to load.
	  rulePrice should price from cached item info only (PriceService:Context({ isCacheOnly })).

	BuyRow = { itemId, name?, unitPrice, units, rulePrice?, confidence?, ruleReason?, usesPriceSource?, vendor?,
	           discountPercent?, auctionId?, buyout?, isCommodity? }

	Cost: a scan holds tens of thousands of items, and a rule price is a full rule evaluation
	(20,000 take about half a second in LuaJIT, seconds in the client). The cheap checks (price,
	vendor, name) run first; the items that pass are sorted cheapest first and only the first
	maxCandidates are priced. With underRulePercent, which needs each one's rule price to find
	a discount, up to maxFilteredCandidates are priced.
]]
local _, ns = ...

local Buy = {}
ns.Buy = Buy

Buy.LIMIT = 100
Buy.MAX_CANDIDATES = 500
Buy.MAX_FILTERED_CANDIDATES = 2000

-- Helpers live at the bottom of the file; declared here so they stay local.
local passesCheapChecks, discountOf, compareRows, normalizeFilter, safeCall

--- Listings from the last scan that pass the filter.
--- @param snapshot table|nil ScanStore.latest(market)
--- @param filter table|nil see the file header
--- @param deps table see the file header
--- @return table BuyRow[]
--- @return boolean isCapped more candidates passed the cheap checks than were priced
function Buy.fromSnapshot(snapshot, filter, deps)
	if type(deps) ~= 'table' then
		error('Buy.fromSnapshot: needs deps', 2)
	end
	if type(snapshot) ~= 'table' or type(snapshot.items) ~= 'table' then
		return {}, false
	end
	filter = normalizeFilter(filter)
	local candidates = {}
	for itemId in pairs(snapshot.items) do
		local item = type(itemId) == 'number' and ns.ScanStore.item(snapshot, itemId) or nil
		local unitPrice = item and item.min
		if type(unitPrice) == 'number' and unitPrice > 0 then
			local row = { itemId = itemId, unitPrice = unitPrice, units = item.units or 0 }
			if passesCheapChecks(row, filter, deps) then
				candidates[#candidates + 1] = row
			end
		end
	end
	table.sort(candidates, function(a, b)
		if a.unitPrice ~= b.unitPrice then
			return a.unitPrice < b.unitPrice
		end
		return a.itemId < b.itemId
	end)
	local maxPriced = filter.underRulePercent and (deps.maxFilteredCandidates or Buy.MAX_FILTERED_CANDIDATES)
		or (deps.maxCandidates or Buy.MAX_CANDIDATES)
	local isCapped = #candidates > maxPriced
	for index = #candidates, maxPriced + 1, -1 do
		candidates[index] = nil
	end
	local rows = {}
	for _, row in ipairs(candidates) do
		local rulePrice, confidence, reason, usesPriceSource = safeCall(deps.rulePrice, row.itemId)
		row.rulePrice = type(rulePrice) == 'number' and rulePrice or nil
		row.confidence = row.rulePrice and confidence or nil
		row.usesPriceSource = row.rulePrice ~= nil and usesPriceSource == true
		row.ruleReason = not row.rulePrice and reason or nil
		row.discountPercent = discountOf(row.unitPrice, row.rulePrice)
		local isUnderRule = not filter.underRulePercent
			or (row.discountPercent ~= nil and row.discountPercent >= filter.underRulePercent)
		if isUnderRule then
			rows[#rows + 1] = row
		end
	end
	table.sort(rows, compareRows)
	local limit = deps.limit or Buy.LIMIT
	for index = #rows, limit + 1, -1 do
		rows[index] = nil
	end
	return rows, isCapped
end

--- A live search's listings (Wow:SearchResults) as rows, own listings left out.
--- @param results table { { auctionId, unitPrice, quantity, isOwn, isCommodity, buyout? }... }
--- @param filter table|nil only maxPrice applies (the search was for one item)
--- @param rulePrice number|nil the item's rule price, for the discount
--- @return table BuyRow[] cheapest first
function Buy.fromLive(results, filter, rulePrice)
	filter = normalizeFilter(filter)
	local rows = {}
	for _, result in ipairs(type(results) == 'table' and results or {}) do
		-- An item auction is bought by its id: one without an id cannot be bought.
		local isWanted = not result.isOwn
			and (result.isCommodity == true or type(result.auctionId) == 'number')
			and type(result.unitPrice) == 'number'
			and (not filter.maxPrice or result.unitPrice <= filter.maxPrice)
		if isWanted then
			rows[#rows + 1] = {
				auctionId = result.auctionId,
				unitPrice = result.unitPrice,
				units = result.quantity or 1,
				buyout = result.buyout,
				isCommodity = result.isCommodity == true,
				rulePrice = rulePrice,
				discountPercent = discountOf(result.unitPrice, rulePrice),
			}
		end
	end
	table.sort(rows, function(a, b)
		return a.unitPrice < b.unitPrice
	end)
	return rows
end

--- Units a commodity buy takes up to a unit price, cheapest first, own listings skipped.
--- @param results table live results (Wow:SearchResults)
--- @param maxUnitPrice number copper
--- @param wantedUnits number|nil stop at this many
--- @return number units
--- @return number totalCopper
function Buy.unitsWithin(results, maxUnitPrice, wantedUnits)
	if type(maxUnitPrice) ~= 'number' then
		error('Buy.unitsWithin: maxUnitPrice must be a number', 2)
	end
	local units, total = 0, 0
	for _, row in ipairs(Buy.fromLive(results, { maxPrice = maxUnitPrice })) do
		local take = row.units
		if wantedUnits then
			take = math.min(take, wantedUnits - units)
		end
		if take <= 0 then
			break
		end
		units, total = units + take, total + take * row.unitPrice
	end
	return units, total
end

-- Helpers ---------------------------------------------------------------------------------

-- Price, vendor and name checks; fills row.vendor and row.name on the way.
function passesCheapChecks(row, filter, deps)
	if filter.maxPrice and row.unitPrice > filter.maxPrice then
		return false
	end
	if filter.underVendor then
		row.vendor = safeCall(deps.vendorPrice, row.itemId)
		if not (type(row.vendor) == 'number' and row.unitPrice < row.vendor) then
			return false
		end
	end
	if filter.text then
		row.name = safeCall(deps.itemName, row.itemId)
		if type(row.name) ~= 'string' or not row.name:lower():find(filter.text, 1, true) then
			return false
		end
	end
	return true
end

-- Percent under the rule price, rounded down; nil when there is no rule price.
function discountOf(unitPrice, rulePrice)
	if type(rulePrice) ~= 'number' or rulePrice <= 0 then
		return nil
	end
	return math.floor((rulePrice - unitPrice) * 100 / rulePrice)
end

-- The deepest discount first; rows without a rule price after, cheapest first.
function compareRows(a, b)
	local discountA, discountB = a.discountPercent or -math.huge, b.discountPercent or -math.huge
	if discountA ~= discountB then
		return discountA > discountB
	end
	if a.unitPrice ~= b.unitPrice then
		return a.unitPrice < b.unitPrice
	end
	return a.itemId < b.itemId
end

-- A filter with blank or junk fields read as not set.
function normalizeFilter(filter)
	filter = type(filter) == 'table' and filter or {}
	local text = type(filter.text) == 'string' and filter.text:match('^%s*(.-)%s*$') or ''
	local function positiveOrNil(value)
		return type(value) == 'number' and value > 0 and value < math.huge and value or nil
	end
	return {
		text = text ~= '' and text:lower() or nil,
		maxPrice = positiveOrNil(filter.maxPrice),
		underRulePercent = positiveOrNil(filter.underRulePercent),
		underVendor = filter.underVendor == true,
	}
end

-- Every result of fn, or nothing when it is missing or throws.
function safeCall(fn, ...)
	if type(fn) ~= 'function' then
		return nil
	end
	local results = { pcall(fn, ...) }
	if not results[1] then
		return nil
	end
	return unpack(results, 2, 5)
end

return Buy
