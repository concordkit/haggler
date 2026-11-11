--[[
	Pricing: the pure half of Haggler. No game API is touched here, so the test script
	runs it under plain LuaJIT.

	The margin AHledger shows sells the result at the listing median and keeps the whole sale.
	This one sells it at the competitive price (the lowest price with real volume behind it,
	undercut by a copper, never above the median), takes the house cut off, and buys reagents by
	walking up the price levels they are actually listed at.

	Price levels are { { unit = copper, qty = units }, ... }, cheapest first.
]]
local _, ns = ...
ns = ns or {} -- tests load files without the addon table

local Pricing = {}
ns.Pricing = Pricing

Pricing.AH_CUT = 0.05
-- Units at or below a price before it counts as the competitive price: at least this many...
Pricing.MIN_DEPTH_UNITS = 5
-- ...and at least this many hours of sales, so a lone cheap stack that sells in minutes is skipped.
Pricing.DEPTH_HOURS = 1
Pricing.UNDERCUT_COPPER = 1
-- Lowest mode passes over the cheapest units the market buys in this many minutes, at least one,
-- so a lone bait listing far under the rest does not set the price.
Pricing.BAIT_MINUTES = 10

-- How prices are read: "realistic" (first price with real volume, capped at the median),
-- "median" (AHledger's median for the result and every reagent), "lowest" (lowest listing past
-- the bait units).
Pricing.MODES = { "realistic", "median", "lowest" }
Pricing.DEFAULT_MODE = "realistic"

-- One listing in AHledger's scan string: item id, stack, buyout, bid, then a field we ignore.
local LISTING = "(%d+):(%d+):(%d+):(%d+):%d+"
local MAX_STACK = 100000
local MAX_COPPER = 2 ^ 40

--- Reads up to maxListings listings of a scan string from position pos into unitsByItem
--- ({ [itemID] = { [unit] = qty } }), skipping bid-only and malformed listings.
--- @param data string AHledger scan data
--- @param pos number position to start reading from
--- @param maxListings number listings to read in this step
--- @param unitsByItem table accumulator, changed in place
--- @param wantedIds table|nil set of item ids to keep; nil keeps every item
--- @return number|nil next position, or nil when the string is read to the end
--- @return number listings read in this step
function Pricing.readListingsInto(data, pos, maxListings, unitsByItem, wantedIds)
	if type(data) ~= "string" then
		error("readListingsInto: data must be a string")
	end
	local read = 0
	while read < maxListings do
		local _, finish, id, stack, buyout = data:find(LISTING, pos)
		if not finish then
			return nil, read
		end
		read = read + 1
		pos = finish + 1
		Pricing.addListing(unitsByItem, tonumber(id), tonumber(stack), tonumber(buyout), wantedIds)
	end
	return pos, read
end

--- Adds one listing to unitsByItem. Invalid listings are ignored, as a scan can hold anything.
function Pricing.addListing(unitsByItem, itemID, stack, buyout, wantedIds)
	if not itemID or itemID <= 0 or (wantedIds and not wantedIds[itemID]) then
		return
	end
	if not stack or stack <= 0 or stack > MAX_STACK or not buyout or buyout <= 0 or buyout > MAX_COPPER then
		return
	end
	local unit = math.max(1, math.floor(buyout / stack + 0.5))
	local units = unitsByItem[itemID]
	if not units then
		units = {}
		unitsByItem[itemID] = units
	end
	units[unit] = (units[unit] or 0) + stack
end

--- Price levels, cheapest first, from a { [unit] = qty } map.
--- @return table levels, empty when units is nil or empty
function Pricing.toLevels(units)
	local levels = {}
	for unit, qty in pairs(units or {}) do
		if qty > 0 then
			levels[#levels + 1] = { unit = unit, qty = qty }
		end
	end
	table.sort(levels, function(a, b)
		return a.unit < b.unit
	end)
	return levels
end

--- Price levels for every wanted item of a whole scan string, read at once.
--- @return table { [itemID] = levels }
function Pricing.buildDepthIndex(data, wantedIds)
	local unitsByItem = {}
	Pricing.readListingsInto(data, 1, math.huge, unitsByItem, wantedIds)
	local index = {}
	for itemID, units in pairs(unitsByItem) do
		index[itemID] = Pricing.toLevels(units)
	end
	return index
end

--- The units that must sit at or below a price before it is the one to beat.
function Pricing.depthThreshold(soldPerDay)
	local hourly = (tonumber(soldPerDay) or 0) * Pricing.DEPTH_HOURS / 24
	return math.max(Pricing.MIN_DEPTH_UNITS, math.ceil(hourly))
end

--- The price to list the item at so it sells soon.
--- With levels: the first level whose cumulative units reach the depth threshold, undercut by a
--- copper. Without: the lower of the lowest buyout and the median, undercut by a copper. Never
--- above the median when the median is known.
--- @param levels table|nil price levels, cheapest first
--- @param prices table { median, minBuyout, soldPerDay } (copper; any may be nil)
--- @return table|nil { unit, source = "depth" | "lowest" | "median" }, nil when nothing prices it
function Pricing.competitivePrice(levels, prices)
	prices = prices or {}
	local median = prices.median
	local unit, source = nil, nil
	if levels and #levels > 0 then
		local threshold, cumulative = Pricing.depthThreshold(prices.soldPerDay), 0
		for _, level in ipairs(levels) do
			cumulative = cumulative + level.qty
			unit = level.unit
			if cumulative >= threshold then
				break
			end
		end
		source = "depth"
	elseif prices.minBuyout then
		unit, source = prices.minBuyout, "lowest"
	end
	if median and median > 0 and (not unit or median < unit) then
		unit, source = median, "median"
	end
	if not unit then
		return nil
	end
	return { unit = math.max(1, unit - Pricing.UNDERCUT_COPPER), source = source }
end

--- What buying qty units costs, walking up the price levels; anything past the listed depth is
--- priced at fallbackUnit (or the dearest level).
--- @return number|nil copper, nil when neither levels nor a fallback price it
--- @return number units bought past the listed depth, priced at the fallback
--- Units at the bottom of the listings that lowest mode passes over.
function Pricing.baitUnits(soldPerDay)
	local perDay = tonumber(soldPerDay) or 0
	return math.max(1, math.ceil(perDay * Pricing.BAIT_MINUTES / 1440))
end

--- The lowest listing once the bait units are passed over; the dearest level when every listed
--- unit counts as bait.
--- @return table|nil { unit, source = "lowest", skipped } skipped: units passed over, nil without depth
function Pricing.lowestPrice(levels, prices)
	prices = prices or {}
	local function lowest(unit, skipped)
		return { unit = math.max(1, unit - Pricing.UNDERCUT_COPPER), source = "lowest", skipped = skipped }
	end
	if levels and #levels > 0 then
		local bait, below = Pricing.baitUnits(prices.soldPerDay), 0
		for _, level in ipairs(levels) do
			if below + level.qty > bait then
				return lowest(level.unit, below)
			end
			below = below + level.qty
		end
		-- Every listed unit counts as bait, so the dearest level is the only price there is.
		local dearest = levels[#levels]
		return lowest(dearest.unit, below - dearest.qty)
	end
	if prices.minBuyout then
		return lowest(prices.minBuyout, nil)
	end
	return nil
end

--- The sell price for a mode.
function Pricing.sellPrice(levels, prices, mode)
	if mode == "median" then
		local median = prices and prices.median
		return (median and median > 0) and { unit = median, source = "median" } or nil
	end
	if mode == "lowest" then
		return Pricing.lowestPrice(levels, prices)
	end
	return Pricing.competitivePrice(levels, prices)
end

local function isMode(mode)
	for _, known in ipairs(Pricing.MODES) do
		if known == mode then
			return true
		end
	end
	return false
end

function Pricing.reagentBuyCost(levels, qty, fallbackUnit)
	if type(qty) ~= "number" or qty < 0 then
		error("reagentBuyCost: qty must be a non-negative number")
	end
	local remaining, total, dearest = qty, 0, nil
	for _, level in ipairs(levels or {}) do
		if remaining <= 0 then
			break
		end
		local take = math.min(remaining, level.qty)
		total = total + take * level.unit
		remaining = remaining - take
		dearest = level.unit
	end
	if remaining <= 0 then
		return total, 0
	end
	local unit = fallbackUnit or dearest
	if not unit then
		return nil, remaining
	end
	-- Only past real depth counts as a shortfall; with no levels at all the fallback is the price.
	local shortfall = (levels and #levels > 0) and remaining or 0
	return total + remaining * unit, shortfall
end

--- Margin of one craft after the house cut.
--- @param sellUnit number copper each result is listed at
--- @param made number results per craft
--- @param cost number copper the reagents of one craft cost
--- @return table { proceeds, margin, pct (nil at zero cost), breakEven (copper per result) }
function Pricing.netMargin(sellUnit, made, cost)
	if type(sellUnit) ~= "number" or type(cost) ~= "number" then
		error("netMargin: sellUnit and cost must be numbers")
	end
	made = (type(made) == "number" and made > 0) and made or 1
	local keep = 1 - Pricing.AH_CUT
	local proceeds = math.floor(sellUnit * made * keep)
	local margin = proceeds - cost
	return {
		proceeds = proceeds,
		margin = margin,
		pct = cost > 0 and (margin / cost * 100) or nil,
		breakEven = math.ceil(cost / made / keep),
	}
end

--- The realistic economics of crafting a recipe some number of times, buying every reagent.
--- @param recipe table { resultID, made, reagents = { { itemID, qty } } }
--- @param lookup function itemID -> { median, minBuyout, soldPerDay, levels } or nil
--- @param crafts number|nil crafts to price, a positive whole number; 1 when nil
--- @return table|nil { sell, cost, missing, shortReagents, crafts, made, units, unitsAhead,
---   isAheadKnown, secondsToSell, proceeds, margin, pct, breakEven }, nil when the result has no
---   price. secondsToSell: until the cheaper units and all of yours have sold, if not undercut.
function Pricing.recipeEconomics(recipe, lookup, crafts, mode)
	if type(recipe) ~= "table" or type(lookup) ~= "function" then
		error("recipeEconomics: recipe table and lookup function required")
	end
	crafts = crafts or 1
	if type(crafts) ~= "number" or crafts < 1 or crafts ~= math.floor(crafts) then
		error("recipeEconomics: crafts must be a positive whole number")
	end
	mode = mode or Pricing.DEFAULT_MODE
	if not isMode(mode) then
		error("recipeEconomics: unknown price mode " .. tostring(mode))
	end
	local result = recipe.resultID and lookup(recipe.resultID)
	local sell = result and Pricing.sellPrice(result.levels, result, mode)
	if not sell then
		return nil
	end
	local cost, missing, shortReagents = 0, 0, {}
	for _, reagent in ipairs(recipe.reagents or {}) do
		local itemID, qty = reagent[1], (reagent[2] or 1) * crafts
		local prices = lookup(itemID)
		local fallback = prices and (prices.minBuyout or prices.median)
		local spent, shortfall = nil, 0
		local median = prices and prices.median
		if mode == "median" and median and median > 0 then
			spent = median * qty
		elseif prices then
			spent, shortfall = Pricing.reagentBuyCost(prices.levels, qty, fallback)
		end
		if spent then
			cost = cost + spent
		else
			missing = missing + 1
		end
		if spent and shortfall > 0 then
			shortReagents[#shortReagents + 1] = itemID
		end
	end
	local made = (tonumber(recipe.made) or 1) > 0 and tonumber(recipe.made) or 1
	local units = made * crafts
	local out = Pricing.netMargin(sell.unit, units, cost)
	out.sell, out.cost, out.missing, out.shortReagents = sell, cost, missing, shortReagents
	out.crafts, out.made, out.units, out.mode = crafts, made, units, mode
	out.unitsAhead = Pricing.unitsBelow(result.levels, sell.unit)
	out.isAheadKnown = result.levels ~= nil and #result.levels > 0
	out.secondsToSell = Pricing.secondsToSellOut(out.unitsAhead + units, result.soldPerDay)
	return out
end

--- Units listed strictly cheaper than unit: the ones buyers take before yours.
function Pricing.unitsBelow(levels, unit)
	local total = 0
	for _, level in ipairs(levels or {}) do
		if level.unit >= unit then
			break
		end
		total = total + level.qty
	end
	return total
end

--- Seconds until the market has bought units, at soldPerDay; nil without a sales pace.
function Pricing.secondsToSellOut(units, soldPerDay)
	soldPerDay = tonumber(soldPerDay)
	if not soldPerDay or soldPerDay <= 0 then
		return nil
	end
	return units / soldPerDay * 86400
end

-- Margin bands in percent of reagent cost. The cut is already taken off, so a profit needs only a
-- small cushion against the next undercut, not AHledger's 10%.
Pricing.BAND_PROFIT_PCT = 5
Pricing.BAND_EVEN_PCT = -5
Pricing.BAND_LOSS_PCT = -30

--- "profit" | "even" | "loss" | "heavy" | "unknown" for a recipeEconomics result (nil = unpriced
--- result). unknown also when a reagent is unpriced or the cost is zero, since no percent holds.
function Pricing.marginBand(economics)
	if type(economics) ~= "table" or economics.missing > 0 or not economics.pct then
		return "unknown"
	end
	if economics.pct >= Pricing.BAND_PROFIT_PCT then
		return "profit"
	end
	if economics.pct >= Pricing.BAND_EVEN_PCT then
		return "even"
	end
	if economics.pct >= Pricing.BAND_LOSS_PCT then
		return "loss"
	end
	return "heavy"
end

-- Item economics for one unit (BagPad's detail panel). Selling at auction must beat the vendor by
-- AHledger's own factor; Wait when it would, but the price sits well under its week or the stock
-- on the house takes days to sell.
Pricing.AUCTION_OVER_VENDOR = 1.5
Pricing.WAIT_BELOW_WEEK = 0.15
Pricing.WAIT_DAYS_OF_STOCK = 3
Pricing.TREND_MIN_PCT = 5

--- "up" | "down" | nil: now against the week's value, nil under TREND_MIN_PCT or without both.
function Pricing.trend(now, week)
	if type(now) ~= "number" or type(week) ~= "number" or week == 0 then
		return nil
	end
	local pct = (now - week) / math.abs(week) * 100
	if pct >= Pricing.TREND_MIN_PCT then
		return "up"
	end
	if pct <= -Pricing.TREND_MIN_PCT then
		return "down"
	end
	return nil
end

--- Reagent cost of one result at the medians now and at the 7-day medians.
--- @param recipe table { reagents = { { itemID, qty } }, made }
--- @param priceOf function itemID -> { median, median7d } or nil
--- @return table|nil { now, week }, nil when a reagent has no median (the cost would be understated)
function Pricing.craftCost(recipe, priceOf)
	if type(recipe) ~= "table" or type(recipe.reagents) ~= "table" or #recipe.reagents == 0 then
		return nil
	end
	local now, week = 0, 0
	for _, reagent in ipairs(recipe.reagents) do
		local prices = priceOf(reagent[1])
		local median = prices and prices.median
		if not median or median <= 0 then
			return nil
		end
		local qty = reagent[2] or 1
		now = now + median * qty
		week = week + (prices.median7d or median) * qty
	end
	local made = (tonumber(recipe.made) or 1) > 0 and tonumber(recipe.made) or 1
	return { now = math.floor(now / made + 0.5), week = math.floor(week / made + 0.5) }
end

local function netOf(unit)
	return math.floor(unit * (1 - Pricing.AH_CUT))
end

--- "vendor" | "wait" | "auction" | nil (nothing sells it).
--- @param realistic number|nil realistic sell price, copper each
--- @param vendor number|nil vendor price, copper each
--- @param prices table { median7d, soldPerDay, quantity }
function Pricing.verdict(realistic, vendor, prices)
	local hasVendor = vendor ~= nil and vendor > 0
	if not realistic then
		return hasVendor and "vendor" or nil
	end
	if hasVendor and netOf(realistic) < vendor * Pricing.AUCTION_OVER_VENDOR then
		return "vendor"
	end
	local week = prices.median7d
	local isDepressed = week ~= nil and week > 0 and realistic < week * (1 - Pricing.WAIT_BELOW_WEEK)
	local perDay, stock = tonumber(prices.soldPerDay), tonumber(prices.quantity)
	local isSlow = perDay ~= nil and perDay > 0 and stock ~= nil and stock / perDay >= Pricing.WAIT_DAYS_OF_STOCK
	if isDepressed or isSlow then
		return "wait"
	end
	return "auction"
end

--- What one unit of an item is worth each way, each figure now and at the 7-day medians.
--- Profit is the auction net (house cut off) minus the craft cost, or minus the vendor price
--- without a recipe, or the whole net with neither.
--- @param input table { vendor, prices = { median, median7d, minBuyout, soldPerDay, quantity } | nil,
---   levels, craft = Pricing.craftCost result | nil }
--- @return table { vendor, craft, minimum, realistic, profitMin, profitReal, basis = "craft" |
---   "vendor" | "none", verdict }; craft, minimum, realistic, profitMin and profitReal are
---   { now, week, trend } or nil
function Pricing.itemEconomics(input)
	if type(input) ~= "table" then
		error("itemEconomics: input table required")
	end
	local prices = input.prices or {}
	local vendor = (input.vendor and input.vendor > 0) and input.vendor or nil
	local week = (prices.median7d and prices.median7d > 0) and prices.median7d or nil
	local hasMarket = input.prices ~= nil or (input.levels ~= nil and #input.levels > 0)
	local minimum = hasMarket and Pricing.sellPrice(input.levels, prices, "lowest") or nil
	local realistic = hasMarket and Pricing.sellPrice(input.levels, prices, "realistic") or nil
	local craft = input.craft
	local basisNow = craft and craft.now or vendor or 0
	local basisWeek = craft and craft.week or vendor or 0
	local function pair(now, weekValue)
		if not now then
			return nil
		end
		return { now = now, week = weekValue, trend = Pricing.trend(now, weekValue) }
	end
	local function profit(unit, basis)
		return unit and (netOf(unit) - basis) or nil
	end
	local minUnit, realUnit = minimum and minimum.unit, realistic and realistic.unit
	local weekProfit = profit(week, basisWeek)
	local realProfit = profit(realUnit, basisNow)
	return {
		profitPct = (realProfit and basisNow > 0) and (realProfit / basisNow * 100) or nil,
		vendor = vendor,
		craft = craft and pair(craft.now, craft.week),
		minimum = pair(minUnit, week),
		realistic = pair(realUnit, week),
		profitMin = pair(profit(minUnit, basisNow), weekProfit),
		profitReal = pair(realProfit, weekProfit),
		basis = craft and "craft" or (vendor and "vendor" or "none"),
		verdict = Pricing.verdict(realUnit, vendor, prices),
	}
end

--- "1g 5s 3c", "29c", "-4s": copper as plain text, zero parts left out.
function Pricing.formatMoney(copper)
	if type(copper) ~= "number" then
		return "?"
	end
	local sign = copper < 0 and "-" or ""
	copper = math.floor(math.abs(copper) + 0.5)
	local gold, silver, rest = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	local parts = {}
	if gold > 0 then
		parts[#parts + 1] = gold .. "g"
	end
	if silver > 0 then
		parts[#parts + 1] = silver .. "s"
	end
	if rest > 0 or #parts == 0 then
		parts[#parts + 1] = rest .. "c"
	end
	return sign .. table.concat(parts, " ")
end

return ns
