local t = ...

local ns = t.loadAddon()
local CraftCost = ns.CraftCost

local LINEN, BOLT, SHIRT = 2589, 2996, 1000
-- Recipe 200 makes 1 Bolt from 2 Linen; recipe 300 makes 1 Shirt from 2 Bolts.
local BOLT_RECIPE = { recipeId = 200, outputItemId = BOLT, quantity = 1, reagents = { { itemId = LINEN, qty = 2 } } }
local SHIRT_RECIPE = { recipeId = 300, outputItemId = SHIRT, quantity = 1, reagents = { { itemId = BOLT, qty = 2 } } }

local function priceOf(copper)
	return copper and { copper = copper, isPriced = true, confidence = { level = 'high', reasons = {} } } or nil
end

--- spec = { held = { [itemId] = units }, opportunity = { [itemId] = per unit }, buy = { [itemId] = per unit },
---          value = per output unit, recipes = { [itemId] = schematic }, valuation?, crafts? }
local function sources(spec)
	return {
		valuation = spec.valuation or 'opportunity',
		crafts = spec.crafts,
		held = function(itemId)
			return (spec.held or {})[itemId] or 0
		end,
		opportunity = function(itemId, qty)
			local perUnit = (spec.opportunity or {})[itemId]
			return perUnit and priceOf(perUnit * qty) or nil
		end,
		buyPrice = function(itemId)
			return priceOf((spec.buy or {})[itemId])
		end,
		value = function(_, qty)
			return priceOf((spec.value or 0) * qty)
		end,
		recipeFor = spec.recipes and function(itemId)
			return spec.recipes[itemId]
		end or nil,
	}
end

local function hasReason(craft, code)
	for _, reason in ipairs(craft.confidence.reasons or {}) do
		if reason.code == code then
			return true
		end
	end
	return false
end

t.group('craft cost: nested crafts')

t.test('a reagent the player can craft for less is costed as crafted', function()
	local craft = CraftCost.recipe(
		SHIRT_RECIPE,
		sources({ buy = { [LINEN] = 10, [BOLT] = 50 }, value = 300, recipes = { [BOLT] = BOLT_RECIPE } })
	)
	local bolt = craft.reagents[1]
	t.eq(bolt.source, 'crafted')
	t.eq(bolt.craftedUnits, 2)
	t.eq(bolt.copper, 40, 'two bolts at 2 linen each')
	t.eq(bolt.craft.cost, 40, 'the sub-craft makes the two missing bolts')
	t.eq(bolt.craft.made, 2)
	t.eq(craft.cost, 40)
	t.eq(craft.profit, 260)
	t.eq(craft.confidence.level, 'high')
end)

t.test('a reagent cheaper to buy is bought', function()
	local craft = CraftCost.recipe(
		SHIRT_RECIPE,
		sources({ buy = { [LINEN] = 10, [BOLT] = 15 }, value = 300, recipes = { [BOLT] = BOLT_RECIPE } })
	)
	t.eq(craft.reagents[1].source, 'buy')
	t.eq(craft.reagents[1].craft, nil)
	t.eq(craft.cost, 30)
end)

t.test('a reagent with no buy price is costed as crafted, with no missing-price reason', function()
	local craft = CraftCost.recipe(
		SHIRT_RECIPE,
		sources({ buy = { [LINEN] = 10 }, value = 300, recipes = { [BOLT] = BOLT_RECIPE } })
	)
	t.eq(craft.reagents[1].source, 'crafted')
	t.eq(craft.cost, 40)
	t.eq(craft.isComplete, true)
	t.eq(hasReason(craft, 'noPrice'), false)
end)

t.test('without recipeFor every missing unit is a buy, as before', function()
	local craft = CraftCost.recipe(SHIRT_RECIPE, sources({ buy = { [LINEN] = 10, [BOLT] = 50 }, value = 300 }))
	t.eq(craft.reagents[1].source, 'buy')
	t.eq(craft.cost, 100)
end)

t.test('a cycle stops at the item already being crafted and buys it', function()
	-- Recipe 500 makes item 50 from item 51; recipe 510 makes item 51 from item 50.
	local makesFifty = { recipeId = 500, outputItemId = 50, quantity = 1, reagents = { { itemId = 51, qty = 1 } } }
	local makesFiftyOne = { recipeId = 510, outputItemId = 51, quantity = 1, reagents = { { itemId = 50, qty = 1 } } }
	local craft = CraftCost.recipe(
		makesFifty,
		sources({ buy = { [50] = 10, [51] = 100 }, value = 300, recipes = { [50] = makesFifty, [51] = makesFiftyOne } })
	)
	local fiftyOne = craft.reagents[1]
	t.eq(fiftyOne.source, 'crafted')
	t.eq(fiftyOne.craft.reagents[1].source, 'buy', 'item 50 is not crafted again')
	t.eq(craft.cost, 10)
end)

t.test('past four nested crafts a reagent falls back to its buy price, with a low reason', function()
	-- Item 60 is made from 61, 61 from 62 ... 65 from 66; intermediates cost 1000 to buy.
	local recipes, buy = {}, { [65] = 100, [66] = 1 }
	for itemId = 60, 65 do
		recipes[itemId] = {
			recipeId = itemId * 10,
			outputItemId = itemId,
			quantity = 1,
			reagents = { { itemId = itemId + 1, qty = 1 } },
		}
		buy[itemId] = buy[itemId] or 1000
	end
	local craft = CraftCost.recipe(recipes[60], sources({ buy = buy, value = 3000, recipes = recipes }))
	t.eq(craft.cost, 100, 'item 65 is bought, not crafted from item 66')
	t.eq(craft.confidence.level, 'low')
	t.truthy(hasReason(craft, 'craftDepth'))
	local line = craft.reagents[1]
	for _ = 1, 3 do
		t.eq(line.source, 'crafted')
		line = line.craft.reagents[1]
	end
	t.eq(line.source, 'crafted', 'the fourth nested craft still happens')
	t.eq(line.craft.reagents[1].source, 'buy')
end)

t.test('held units keep their valuation; only missing units are crafted', function()
	-- 1 of 2 bolts held (worth 70), and 2 linen held (worth 5 each) for the one bolt crafted.
	local craft = CraftCost.recipe(
		SHIRT_RECIPE,
		sources({
			held = { [BOLT] = 1, [LINEN] = 2 },
			opportunity = { [BOLT] = 70, [LINEN] = 5 },
			buy = { [LINEN] = 10, [BOLT] = 50 },
			value = 300,
			recipes = { [BOLT] = BOLT_RECIPE },
		})
	)
	local bolt = craft.reagents[1]
	t.eq(bolt.held, 1)
	t.eq(bolt.craftedUnits, 1)
	t.eq(bolt.craft.reagents[1].source, 'value', 'the held linen at what it would fetch')
	t.eq(bolt.copper, 70 + 10)
	t.eq(craft.cost, 80)
end)

t.test('paid valuation reaches into the sub-craft', function()
	local market = { ledger = {}, auctions = {}, costPools = {}, ventures = {} }
	ns.CostPool.add(market, LINEN, 2, 6)
	local spec = sources({
		valuation = 'paid',
		held = { [LINEN] = 2 },
		opportunity = { [LINEN] = 5 },
		buy = { [LINEN] = 10, [BOLT] = 50 },
		value = 300,
		recipes = { [BOLT] = BOLT_RECIPE },
	})
	spec.split = function(itemId, units, held)
		return ns.CostPool.split(market, itemId, units, held)
	end
	local craft = CraftCost.recipe(SHIRT_RECIPE, spec)
	-- One bolt from the 2 paid linen (6c), one from 2 bought linen (20c).
	t.eq(craft.cost, 26)
	t.eq(craft.knownCopper, 6, 'the paid linen stays known')
end)
