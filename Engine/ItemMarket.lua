--[[
	ItemMarket: the price grid an item can be listed on.

	On Forever an item that doesn't stack (max stack 1) can only be priced in whole silver, while
	stackable items may use copper (checked against two full scans: 1,785 of 1,790 unstackable
	listings had no copper). The scan overrides the item info: any copper seen in a listing of the
	item means copper is allowed. An unknown max stack (the item info is not cached yet) also gets
	whole silver unless copper was seen, and the market is marked isStepInferred so the price's
	confidence says so.

	Every price Haggler computes is snapped to the grid: a sell price rounds down (an undercut
	goes down a full step), a break-even rounds up.
]]
local _, ns = ...

local ItemMarket = {}
ns.ItemMarket = ItemMarket

-- Helpers live at the bottom of the file; declared here so they stay local.
local hasCopperIn

ItemMarket.COPPER_STEP = 1
ItemMarket.SILVER_STEP = 100

--- Builds the market of one item.
--- @param facts table { maxStack = number?, copperSeen = boolean?, vendor = number? }
--- @return table ItemMarket { step, maxStack, copperSeen, vendor, isStepInferred }
function ItemMarket.forItem(facts)
	if type(facts) ~= 'table' then
		error('ItemMarket.forItem: facts must be a table', 2)
	end
	local copperSeen = facts.copperSeen == true
	local isStackKnown = facts.maxStack ~= nil
	local isWholeSilver = not copperSeen and (facts.maxStack == 1 or not isStackKnown)
	return {
		step = isWholeSilver and ItemMarket.SILVER_STEP or ItemMarket.COPPER_STEP,
		maxStack = facts.maxStack,
		copperSeen = copperSeen,
		vendor = facts.vendor,
		isStepInferred = isWholeSilver and not isStackKnown,
	}
end

--- True when any listed price has copper in it. Junk (a level that is not a table, a price
--- that is not a finite number) is skipped, never an error.
--- @param levels table|nil { { price, qty }, ... }
--- @param lowest number|nil a lowest price seen outside the levels
function ItemMarket.hasCopper(levels, lowest)
	if hasCopperIn(lowest) then
		return true
	end
	for _, level in ipairs(type(levels) == 'table' and levels or {}) do
		if type(level) == 'table' and hasCopperIn(level.price) then
			return true
		end
	end
	return false
end

--- Rounds down to the grid (may return 0).
function ItemMarket.snapDown(market, copper)
	local step = market.step
	return math.floor(copper / step) * step
end

--- Rounds up to the grid; a break-even price uses this.
function ItemMarket.snapUp(market, copper)
	local step = market.step
	return math.ceil(copper / step) * step
end

--- A listable sell price: rounded down to the grid, never under one step.
function ItemMarket.snapPrice(market, copper)
	return math.max(market.step, ItemMarket.snapDown(market, copper))
end

--- The price amount copper below another, on the grid; one copper under 3s on a silver item
--- is 2s.
function ItemMarket.undercut(market, copper, amount)
	return ItemMarket.snapDown(market, copper - amount)
end

function ItemMarket.isOnStep(market, copper)
	return copper % market.step == 0
end

-- Helpers ---------------------------------------------------------------------------------

function hasCopperIn(price)
	local isFinitePrice = type(price) == 'number' and price > 0 and price < math.huge
	return isFinitePrice and price % ItemMarket.SILVER_STEP ~= 0
end

return ItemMarket
