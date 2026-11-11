local t = ...

local ns = t.loadAddon()
local Ventures, CraftCost, CostPool = ns.Ventures, ns.CraftCost, ns.CostPool

local CHAR = 'Me-Realm'
-- Recipe 100 makes 1 of item 900 from 2 of item 10 and 1 of item 11.
local RECIPE =
	{ recipeId = 100, itemId = 900, perCraft = 1, reagents = { { itemId = 10, qty = 2 }, { itemId = 11, qty = 1 } } }

local function newMarket()
	return { ledger = {}, auctions = {}, costPools = {}, ventures = {} }
end

local function newBooks(held)
	local market = newMarket()
	local clock = { now = 1000 }
	held = held or {}
	local books = ns.Books.new({
		market = function()
			return market
		end,
		char = function()
			return CHAR
		end,
		now = function()
			return clock.now
		end,
		held = function(itemId)
			return held[itemId] or 0
		end,
		valueOf = function(_, qty)
			return 100 * qty
		end,
	})
	return books, market, clock, held
end

t.group('ventures: lifecycle')

t.test('a venture moves planning, buying, crafting, selling and back when the plan grows', function()
	local market = newMarket()
	local venture = Ventures.create(market, { name = 'Bracers' }, 10)
	t.eq(venture.id, 1)
	t.eq(venture.status, 'planning')
	t.eq(venture.valuation, 'opportunity')
	Ventures.addCrafts(venture, RECIPE, 2)
	t.eq(venture.lines[1].planned, 2)
	t.eq(venture.materials[10].need, 4)
	Ventures.noteBuy(venture, 10, 4, 400)
	t.eq(venture.status, 'buying')
	Ventures.noteCraft(venture, 100, 1, {})
	t.eq(venture.status, 'crafting')
	Ventures.noteCraft(venture, 100, 1, {})
	t.eq(venture.status, 'selling')
	Ventures.addCrafts(venture, RECIPE, 1)
	t.eq(venture.status, 'crafting', 'more planned: back to crafting')
	Ventures.addCrafts(venture, RECIPE, -5)
	t.eq(venture.lines[1].plannedCrafts, 2, 'never planned below what was crafted')
	t.eq(venture.status, 'selling')
	t.eq(Ventures.create(market, nil, 11).id, 2)
	t.eq(Ventures.create(market, nil, 11).name, 'Venture 3')
end)

t.test('openFor finds the oldest open venture that wants an item or recipe', function()
	local market = newMarket()
	local first = Ventures.create(market, nil, 1)
	local second = Ventures.create(market, nil, 2)
	Ventures.addCrafts(first, RECIPE, 1)
	Ventures.addCrafts(second, RECIPE, 1)
	t.eq(Ventures.openFor(market, 'buy', 10), first)
	Ventures.noteBuy(first, 10, 2, 0)
	t.eq(Ventures.openFor(market, 'buy', 10), second)
	t.eq(Ventures.openFor(market, 'craft', 100), first)
	t.eq(Ventures.openFor(market, 'post', 900), nil, 'nothing crafted yet')
	Ventures.noteCraft(first, 100, 1, {})
	t.eq(Ventures.openFor(market, 'post', 900), first)
	t.raises(function()
		Ventures.openFor(market, 'loot', 1)
	end, 'unknown role')
end)

t.test('a sold-out venture closes by itself; unused materials go to stock', function()
	local books, market = newBooks({ [900] = 1 })
	local venture = books:PlanCrafts(nil, RECIPE, 1)
	books:OnVendorBuy({ itemId = 11, qty = 3, copper = 30 })
	books:OnCraft({ recipeId = 100, outputItemId = 900, made = 1, reagents = RECIPE.reagents })
	books:OnPost({ itemId = 900, qty = 1, unitPrice = 1000, hours = 12, deposit = 10 })
	books:OnAuctionCreated(5)
	t.eq(market.auctions[5].ventureId, venture.id)
	t.eq(books:CheckVentures(), 0, 'still live')
	books:OnSaleMail({ itemId = 900, qty = 1, bid = 1000, deposit = 10, cut = 50 })
	t.eq(venture.lines[1].sold, 1)
	t.eq(venture.status, 'closed', 'the last sale mail closes it, no login needed')
	t.eq(books:CheckVentures(), 0)
	t.eq(venture.closeReason, 'sold')
	t.eq(venture.leftoverAction, 'toStock')
	t.eq(#ns.Ledger.events(market, { kind = 'toStock' }), 1, 'two unused reagents moved to stock')
	t.eq(Ventures.get(market, venture.id), venture, 'never deleted')
	t.eq(#Ventures.list(market, { isOpen = false }), 1)
end)

t.test('planning a recipe again adds to its open venture', function()
	local books, market = newBooks()
	local venture = books:PlanCrafts(nil, RECIPE, 1)
	t.eq(books:PlanCrafts(nil, RECIPE, 2), venture)
	t.eq(#Ventures.list(market), 1)
	t.eq(venture.lines[1].plannedCrafts, 3)
	books:OnCraft({ recipeId = 100, outputItemId = 900, made = 3, reagents = RECIPE.reagents })
	t.truthy(books:PlanCrafts(nil, RECIPE, 1) ~= venture, 'every planned craft done: a new venture')
end)

t.test('closing by hand asks what happens to leftovers; to stock fills the pool', function()
	local books, market = newBooks()
	local venture = books:PlanCrafts(nil, RECIPE, 3)
	books:OnCraft({ recipeId = 100, outputItemId = 900, made = 2, reagents = RECIPE.reagents })
	local leftovers, reason = books:CloseVenture(venture.id)
	t.eq(leftovers, nil)
	t.eq(reason, 'choose what happens to the leftovers')
	leftovers = books:CloseVenture(venture.id, 'toStock')
	t.eq(#leftovers, 1)
	t.same(CostPool.get(market, 900), { units = 2, copper = 200 })
	t.eq(venture.totals.leftoverCopper, 200)
	t.eq(Ventures.profit(venture).net, 200)
	t.eq(Ventures.profit(venture).cash, 0, 'stock is not gold')
	t.eq(select(2, books:CloseVenture(venture.id, 'writeOff')), 'already closed')
	t.eq(select(2, Ventures.addCrafts(venture, RECIPE, 1)), 'venture is closed')
end)

t.test('a write-off books the leftovers but credits nothing', function()
	local books, market = newBooks()
	local venture = books:PlanCrafts(nil, RECIPE, 1)
	books:OnCraft({ recipeId = 100, outputItemId = 900, made = 1, reagents = RECIPE.reagents })
	books:CloseVenture(venture.id, 'writeOff')
	t.eq(CostPool.get(market, 900), nil)
	t.eq(venture.totals.leftoverCopper, 0)
	t.eq(ns.Ledger.events(market, { kind = 'writeOff' })[1].copper, 100)
end)

t.test('profit both ways: cash and over materials, with the known share', function()
	local books, market, _, held = newBooks({ [10] = 2, [11] = 1 })
	local venture = books:PlanCrafts(nil, RECIPE, 1, { valuation = 'paid' })
	t.eq(venture.valuation, 'paid')
	-- Item 10: 2 bought for 300 at the vendor; item 11 held of unknown origin (value 100).
	books:OnVendorBuy({ itemId = 10, qty = 2, copper = 300 })
	held[10], held[11] = 0, 0
	local costs = books:OnCraft({ recipeId = 100, outputItemId = 900, made = 1, reagents = RECIPE.reagents })
	t.same(costs[10], { qty = 2, knownCopper = 300, estimatedCopper = 0 })
	t.same(costs[11], { qty = 1, knownCopper = 0, estimatedCopper = 100 })
	books:OnPost({ itemId = 900, qty = 1, unitPrice = 1000, hours = 12, deposit = 20 })
	books:OnAuctionCreated(1)
	books:OnSaleMail({ itemId = 900, qty = 1, bid = 1000, deposit = 20, cut = 50 })
	local profit = Ventures.profit(venture)
	t.eq(profit.net, 950)
	t.eq(profit.cash, 650)
	t.eq(profit.overMaterials, 550)
	t.eq(profit.knownShare, 0.75)
	t.eq(market.ventures[1], venture)
end)

t.test('the forecast sells the plan at today value and estimates days from sales', function()
	local market = newMarket()
	local venture = Ventures.create(market, nil, 1)
	Ventures.addCrafts(venture, RECIPE, 4)
	local forecast = Ventures.forecast(venture, {
		valueOf = function(_, qty)
			return 500 * qty
		end,
		costOf = function(_, crafts)
			return 300 * crafts
		end,
		salesPerDay = function()
			return 10
		end,
	})
	t.eq(forecast.income, 2000)
	t.eq(forecast.cost, 1200)
	t.eq(forecast.profit, 800)
	t.eq(forecast.margin, 0.4)
	t.eq(forecast.days, 2, '4 units at 20% of 10 a day')
	t.truthy(forecast.note:find('20%%'))
	local unknown = Ventures.forecast(venture, {
		valueOf = function()
			return nil
		end,
		costOf = function()
			return 0
		end,
		salesPerDay = function()
			return nil
		end,
		sharePercent = 50,
	})
	t.eq(unknown.days, nil)
	t.eq(unknown.isComplete, false)
	t.eq(unknown.confidence.level, 'low', 'a missing price is low confidence')
end)

t.test('the forecast carries the confidence and the source of its values and costs', function()
	local market = newMarket()
	local venture = Ventures.create(market, nil, 1)
	Ventures.addCrafts(venture, RECIPE, 1)
	local medium = { level = 'medium', reasons = { { code = 'thin', level = 'medium', text = 'thin market' } } }
	local forecast = Ventures.forecast(venture, {
		valueOf = function(_, qty)
			return 500 * qty, { level = 'high', reasons = {} }, false
		end,
		costOf = function()
			return 300, medium, true
		end,
		salesPerDay = function()
			return 10
		end,
	})
	t.eq(forecast.confidence.level, 'medium')
	t.eq(forecast.confidence.reasons[1].text, 'thin market')
	t.eq(forecast.usesPriceSource, true)
end)

t.group('craft cost')

local function price(copper, level)
	return { copper = copper, confidence = { level = level or 'high', reasons = {} } }
end

local function sources(options)
	return {
		valuation = options.valuation or 'opportunity',
		crafts = options.crafts,
		held = function(itemId)
			return (options.held or {})[itemId] or 0
		end,
		split = function(itemId, units, held)
			return CostPool.split(options.market, itemId, units, held)
		end,
		opportunity = function(itemId, qty)
			local unit = (options.opportunity or {})[itemId]
			return unit and { copper = unit * qty, isPriced = true, confidence = { level = 'high', reasons = {} } }
		end,
		buyPrice = function(itemId)
			local unit = (options.buy or {})[itemId]
			return unit and price(unit, options.buyLevel)
		end,
		value = function(_, qty)
			return options.value
				and {
					copper = options.value * qty,
					isPriced = true,
					confidence = { level = 'high', reasons = {} },
				}
		end,
	}
end

local SCHEMATIC = { recipeId = 100, outputItemId = 900, quantity = 1, reagents = RECIPE.reagents }

t.test('opportunity: held units at their value, missing units at the buy price', function()
	local craft = CraftCost.recipe(
		SCHEMATIC,
		sources({
			held = { [10] = 1 },
			opportunity = { [10] = 40, [11] = 70 },
			buy = { [10] = 50, [11] = 80 },
			value = 300,
		})
	)
	t.eq(craft.cost, 40 + 50 + 80)
	t.eq(craft.value, 300)
	t.eq(craft.profit, 130)
	t.eq(craft.knownCopper, 0)
	t.eq(craft.knownShare, 0)
	t.eq(craft.confidence.level, 'high')
	t.eq(craft.usesPriceSource, false, 'no AHledger figure went in')
	t.eq(craft.reagents[1].source, 'value')
	t.eq(craft.reagents[2].source, 'buy')
end)

t.test('a craft uses the price source when a reagent price or the output value did', function()
	local withSource = sources({ buy = { [10] = 50, [11] = 80 }, value = 300 })
	local buyPrice = withSource.buyPrice
	withSource.buyPrice = function(itemId)
		local found = buyPrice(itemId)
		found.usesPriceSource = itemId == 11
		return found
	end
	t.eq(CraftCost.recipe(SCHEMATIC, withSource).usesPriceSource, true, 'a bought reagent')
	local valued = sources({ buy = { [10] = 50, [11] = 80 } })
	valued.value = function(_, qty)
		return { copper = 300 * qty, isPriced = true, rulePrice = { usesPriceSource = true } }
	end
	t.eq(CraftCost.recipe(SCHEMATIC, valued).usesPriceSource, true, 'the output value')
end)

t.test('paid: the pool share is known, unknown origin falls back to opportunity', function()
	local market = newMarket()
	CostPool.add(market, 10, 2, 60)
	-- 4 held of item 10, 2 known at 30 each: crafting twice takes 4 = 2 known + 2 unknown (40 each).
	local craft = CraftCost.recipe(
		SCHEMATIC,
		sources({
			valuation = 'paid',
			market = market,
			crafts = 2,
			held = { [10] = 4, [11] = 2 },
			opportunity = { [10] = 40, [11] = 70 },
			value = 300,
		})
	)
	t.eq(craft.made, 2)
	t.eq(craft.knownCopper, 60)
	t.eq(craft.estimatedCopper, 80 + 140)
	t.eq(craft.cost, 280)
	t.eq(craft.reagents[1].source, 'paid and value')
	t.eq(craft.margin, (600 - 280) / 600)
	t.same(CostPool.get(market, 10), { units = 2, copper = 60 }, 'pricing never changes the pool')
end)

t.test('a missing price is 0, low confidence and a reason; never an error', function()
	local craft = CraftCost.recipe(SCHEMATIC, sources({ buy = { [10] = 50 } }))
	t.eq(craft.isComplete, false)
	t.eq(craft.value, 0)
	t.eq(craft.margin, nil)
	t.eq(craft.confidence.level, 'low')
	t.truthy(#craft.confidence.reasons > 0)
	local broken = sources({ value = 1 })
	broken.held = function()
		error('boom')
	end
	t.eq(CraftCost.recipe(SCHEMATIC, broken).reagents[1].held, 0)
	t.raises(function()
		CraftCost.recipe(SCHEMATIC, { valuation = 'guess' })
	end, 'unknown valuation')
end)

t.test('the merged confidence carries the weakest reagent level', function()
	local craft =
		CraftCost.recipe(SCHEMATIC, sources({ buy = { [10] = 50, [11] = 1 }, buyLevel = 'medium', value = 300 }))
	t.eq(craft.confidence.level, 'medium')
end)
