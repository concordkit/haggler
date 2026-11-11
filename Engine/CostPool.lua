--[[
	CostPool: what the player paid for the units of an item they hold, as a weighted average
	(markets[marketKey].costPools). Each item is one compact pair:

	  costPools[itemId] = { units, copper }

	Units come in from auction purchases (the "auction won" mail), vendor purchases and venture
	leftovers moved to stock; they go out when sold, crafted with, vendored or destroyed. The
	player can hold units the pool never saw (looted, mailed from an alt, bought before Haggler):
	held - units is the unknown-origin share. Taking units out splits them in proportion between
	known and unknown origin, so the average of the known units never changes on the way out.

	A pool that claims more units than the player holds (items left without Haggler seeing,
	e.g. mailed away) is shrunk to the held count at the same average before any split.

	  CostPool.get(market, itemId)                 -> { units, copper } | nil
	  CostPool.average(market, itemId)             -> copper per unit (rounded down) | nil
	  CostPool.add(market, itemId, units, copper)  adds units bought for copper in total
	  CostPool.split(market, itemId, units, held)  -> Split, read only
	  CostPool.remove(market, itemId, units, held) -> Split, and takes the known units out

	  Split = { units, knownUnits, knownCopper, unknownUnits }
]]
local _, ns = ...

local CostPool = {}
ns.CostPool = CostPool

-- Pair positions.
local UNITS, COPPER = 1, 2

-- Helpers live at the bottom of the file; declared here so they stay local.
local isWhole, poolsOf, readPool, clampToHeld, splitOf

--- The pool of one item, or nil when it has none.
--- @param market table|nil Store:Market(key)
--- @param itemId number
--- @return table|nil { units, copper }
function CostPool.get(market, itemId)
	local pools = poolsOf(market)
	return pools and readPool(pools[itemId]) or nil
end

--- The weighted average paid per unit, rounded down, or nil when the pool is empty.
function CostPool.average(market, itemId)
	local pool = CostPool.get(market, itemId)
	if not pool or pool.units == 0 then
		return nil
	end
	return math.floor(pool.copper / pool.units)
end

--- Adds units bought for a total of copper.
--- @param market table Store:Market(key)
--- @param itemId number
--- @param units number whole, above 0
--- @param copper number whole copper for all units, 0 or more
function CostPool.add(market, itemId, units, copper)
	local pools = poolsOf(market)
	if not pools then
		error('CostPool.add: needs a market with costPools', 2)
	end
	if not (isWhole(itemId) and itemId > 0 and isWhole(units) and units > 0 and isWhole(copper)) then
		error('CostPool.add: needs an itemId, units above 0 and whole copper', 2)
	end
	local pool = readPool(pools[itemId]) or { units = 0, copper = 0 }
	pools[itemId] = { pool.units + units, pool.copper + copper }
end

--- How taking units out of held would split between known and unknown origin. Read only.
--- @param market table|nil
--- @param itemId number
--- @param units number units taken
--- @param held number units held before taking them (bags and bank)
--- @return table Split
function CostPool.split(market, itemId, units, held)
	if not (isWhole(units) and isWhole(held)) then
		error('CostPool.split: units and held must be whole numbers', 2)
	end
	local pool = clampToHeld(CostPool.get(market, itemId), held)
	return splitOf(pool, units, held)
end

--- Takes units out: the known share leaves the pool at its average (the last known unit takes
--- whatever copper is left, so nothing is stranded by rounding).
--- @param market table Store:Market(key)
--- @param itemId number
--- @param units number units taken
--- @param held number units held before taking them
--- @return table Split
function CostPool.remove(market, itemId, units, held)
	local pools = poolsOf(market)
	if not pools then
		error('CostPool.remove: needs a market with costPools', 2)
	end
	if not (isWhole(units) and isWhole(held)) then
		error('CostPool.remove: units and held must be whole numbers', 2)
	end
	local pool = clampToHeld(readPool(pools[itemId]), held)
	local split = splitOf(pool, units, held)
	if not pool then
		pools[itemId] = nil
		return split
	end
	local left = { pool.units - split.knownUnits, pool.copper - split.knownCopper }
	pools[itemId] = left[UNITS] > 0 and left or nil
	return split
end

-- Helpers ---------------------------------------------------------------------------------

function isWhole(value)
	return type(value) == 'number' and value >= 0 and value < math.huge and value % 1 == 0
end

function poolsOf(market)
	return type(market) == 'table' and type(market.costPools) == 'table' and market.costPools or nil
end

-- A saved pair, or nil when it is junk (a hand edit) or empty.
function readPool(pair)
	if type(pair) ~= 'table' or not isWhole(pair[UNITS]) or not isWhole(pair[COPPER]) or pair[UNITS] == 0 then
		return nil
	end
	return { units = pair[UNITS], copper = pair[COPPER] }
end

function clampToHeld(pool, held)
	if not pool or pool.units <= held then
		return pool
	end
	if held == 0 then
		return nil
	end
	return { units = held, copper = math.floor(pool.copper * held / pool.units) }
end

function splitOf(pool, units, held)
	local taken = math.min(units, held)
	if not pool or held == 0 or taken == 0 then
		return { units = units, knownUnits = 0, knownCopper = 0, unknownUnits = units }
	end
	-- Proportional: of the held units, pool.units are known; take the same share.
	local knownUnits = math.min(pool.units, math.floor(taken * pool.units / held + 0.5))
	local knownCopper = knownUnits == pool.units and pool.copper or math.floor(pool.copper * knownUnits / pool.units)
	return { units = units, knownUnits = knownUnits, knownCopper = knownCopper, unknownUnits = units - knownUnits }
end

return CostPool
