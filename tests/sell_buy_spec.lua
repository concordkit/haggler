local t = ...
local FakeGame = require('tests.fake_game')

local LINEN, WOOL, SWORD, ROCK = 2589, 2592, 2488, 9999
local MARKET = 'forever/normal/alliance/us'
local NOW = 1000000
local AHLEDGER_ROWS = {
	[2589] = { 120, 95, 500, 118, 125, 90, 160, 45 },
	[2592] = { 300, 280, 80, 290, 310, 250, 400, 0.5 },
	[2488] = { 12345, 12000, 3, 12000, 12500, 11000, 13000, 3 },
}
local ITEM_INFO = {
	[LINEN] = { name = 'Linen Cloth', maxStack = 20, vendorPrice = 13 },
	[WOOL] = { name = 'Wool Cloth', maxStack = 20, vendorPrice = 33 },
	[SWORD] = { name = 'Short Sword', maxStack = 1, vendorPrice = 500 },
	[ROCK] = { name = 'Rock', maxStack = 20, vendorPrice = 0 },
}

local ns = t.loadAddon()
local Sell, Buy = ns.Sell, ns.Buy

local function newPrices()
	local store = assert(ns.Store.open({}, {}))
	local api = FakeGame.newAHledgerAPI({ market = MARKET, updated = NOW - 3600, rows = AHLEDGER_ROWS })
	local prices = ns.PriceService.new({
		now = function()
			return NOW
		end,
		store = store,
		priceSource = ns.PriceData.newAHledgerSource(function()
			return api
		end),
		marketKey = function()
			return MARKET
		end,
		itemInfo = function(itemId)
			return ITEM_INFO[itemId]
		end,
	})
	return prices, store
end

local CARRIED = {
	{ itemId = LINEN, count = 10, bag = 0, slot = 1 },
	{ itemId = SWORD, count = 1, bag = 0, slot = 2 },
	{ itemId = LINEN, count = 5, bag = 1, slot = 4 },
	{ itemId = SWORD, count = 1, bag = 1, slot = 5 },
	{ itemId = ROCK, count = 3, bag = 1, slot = 6, isBound = true },
	{ itemId = WOOL, count = 2, bag = 2, slot = 1, hasNoValue = true },
}

local function rowFor(rows, itemId)
	for _, row in ipairs(rows) do
		if row.itemId == itemId then
			return row
		end
	end
	return nil
end

t.group('sell suggestions')

t.test('stackables group into one listing, unstackables list one at a time, bound items are left out', function()
	local prices, store = newPrices()
	local rows = Sell.rows(CARRIED, { prices = prices, store = store, durationHours = 24 })
	t.eq(#rows, 2)
	local linen = assert(rowFor(rows, LINEN))
	t.eq(linen.count, 15)
	t.eq(linen.units, 15)
	t.eq(linen.listings, 1)
	t.eq(#linen.slots, 2)
	t.same(linen.slots[2], { bag = 1, slot = 4, count = 5 })
	local sword = assert(rowFor(rows, SWORD))
	t.eq(sword.units, 1)
	t.eq(sword.listings, 2)
	t.eq(rowFor(rows, ROCK), nil, 'bound')
	t.eq(rowFor(rows, WOOL), nil, 'worthless')
end)

t.test('each row carries the default rule price, the deposit and a guardrail verdict', function()
	local prices, store = newPrices()
	local asked = {}
	local rows = Sell.rows(CARRIED, {
		prices = prices,
		store = store,
		durationHours = 12,
		deposit = function(itemId, units, hours)
			asked[#asked + 1] = { itemId, units, hours }
			return 7
		end,
	})
	local linen = assert(rowFor(rows, LINEN))
	t.eq(linen.price.copper, assert(prices:Get(LINEN)).copper)
	t.eq(linen.verdict.deposit, 7)
	t.eq(linen.input.durationHours, 12)
	t.truthy(linen.verdict.action == 'post' or linen.verdict.action == 'vendor', 'linen has an action')
	t.eq(linen.check, ns.Guardrail.postCheck(linen.verdict, 'confirm'))
	t.same(asked[1], { LINEN, 15, 12 })
end)

t.test('rows sort post first, then by expected net', function()
	local prices, store = newPrices()
	local rows = Sell.rows(CARRIED, { prices = prices, store = store })
	for index = 2, #rows do
		local previous, current = rows[index - 1].verdict, rows[index].verdict
		if previous.action == current.action and previous.net and current.net then
			t.truthy(previous.net * rows[index - 1].listings >= current.net * rows[index].listings, 'net order')
		else
			t.truthy(previous.action == 'post' or current.action ~= 'post', 'post first')
		end
	end
end)

t.test('a row prices by another rule when asked, and an unknown rule is a programmer error', function()
	local prices, store = newPrices()
	local rows = Sell.rows(CARRIED, { prices = prices, store = store, ruleId = 'median' })
	t.eq(assert(rowFor(rows, LINEN)).price.copper, 120)
	t.raises(function()
		Sell.rows(CARRIED, { prices = prices, store = store, ruleId = 'nope' })
	end, 'unknown rule')
	t.raises(function()
		Sell.rows(nil, { prices = prices, store = store })
	end, 'carried')
end)

t.test('the stepper re-runs the guardrail: under the vendor price warns, a loss asks to confirm', function()
	local prices, store = newPrices()
	local linen = assert(rowFor(
		Sell.rows(CARRIED, {
			prices = prices,
			store = store,
			deposit = function()
				return 5000
			end,
		}),
		LINEN
	))
	local cheap = Sell.verdictAt(linen, 13)
	t.eq(cheap.price, 13)
	t.truthy(cheap.isBelowVendor, 'net under the vendor')
	t.eq(ns.Guardrail.postCheck(cheap, 'warn'), 'warn')
	local wool = Sell.rows({ { itemId = WOOL, count = 20, bag = 0, slot = 1 } }, {
		prices = prices,
		store = store,
		deposit = function()
			return 5000
		end,
	})[1]
	local ruinous = Sell.verdictAt(wool, 40)
	t.truthy(ruinous.isLoss, 'a slow seller with a 50s deposit loses money')
	t.eq(ns.Guardrail.postCheck(ruinous, 'confirm'), 'confirm')
	t.eq(ns.Guardrail.postCheck(ruinous, 'off'), 'ok')
	t.eq(linen.input.price, linen.price.copper, 'the row keeps its own input')
end)

t.test('price steps follow the item step and never go under one step', function()
	local row = { input = { step = 1 }, price = { copper = 120 } }
	t.eq(Sell.stepPrice(row, nil, 1), 121)
	t.eq(Sell.stepPrice(row, 120, -1), 119)
	t.eq(Sell.stepPrice(row, 1, -1), 1)
	local silver = { input = { step = 100 }, price = { copper = 250 } }
	t.eq(Sell.stepPrice(silver, 250, -1), 200, 'snaps down onto the step')
	t.eq(Sell.stepPrice(silver, 250, 1), 300)
	t.eq(Sell.stepPrice(silver, 100, -1), 100)
	t.raises(function()
		Sell.stepPrice(row, 1, 0)
	end, 'direction')
end)

t.test('an unpriced row says why and steps like its market: whole silver for gear', function()
	local HELM, BOLT = 7001, 7002
	ITEM_INFO[HELM] = { name = 'Old Helm', maxStack = 1, vendorPrice = 250 }
	ITEM_INFO[BOLT] = { name = 'Odd Bolt', maxStack = 20, vendorPrice = 5 }
	local prices, store = newPrices()
	local rows = Sell.rows({
		{ itemId = HELM, count = 1, bag = 0, slot = 1 },
		{ itemId = BOLT, count = 4, bag = 0, slot = 2 },
	}, { prices = prices, store = store, durationHours = 24 })
	ITEM_INFO[HELM], ITEM_INFO[BOLT] = nil, nil
	local helm, bolt = assert(rowFor(rows, HELM)), assert(rowFor(rows, BOLT))
	t.eq(helm.price, nil)
	t.truthy(helm.reason, 'the reason it has no price')
	t.eq(helm.input.step, ns.ItemMarket.SILVER_STEP)
	t.eq(bolt.input.step, ns.ItemMarket.COPPER_STEP)
end)

t.group('buy filtering')

local SNAPSHOT = {
	at = NOW - 60,
	items = {
		[LINEN] = { min = 60, units = 400, levels = { { price = 60, qty = 400 } } },
		[WOOL] = { min = 290, units = 80, levels = { { price = 290, qty = 80 } } },
		[SWORD] = { min = 400, units = 1, levels = { { price = 400, qty = 1 } } },
	},
}

local function buyDeps(overrides)
	local rulePrices = { [LINEN] = 120, [WOOL] = 300, [SWORD] = 12345 }
	local deps = {
		itemName = function(itemId)
			return ITEM_INFO[itemId] and ITEM_INFO[itemId].name
		end,
		rulePrice = function(itemId)
			return rulePrices[itemId]
		end,
		vendorPrice = function(itemId)
			return ITEM_INFO[itemId] and ITEM_INFO[itemId].vendorPrice
		end,
	}
	for key, value in pairs(overrides or {}) do
		deps[key] = value
	end
	return deps
end

local function ids(rows)
	local list = {}
	for _, row in ipairs(rows) do
		list[#list + 1] = row.itemId
	end
	return list
end

t.test('scan search sorts the deepest discount first', function()
	local rows = Buy.fromSnapshot(SNAPSHOT, {}, buyDeps())
	t.same(ids(rows), { SWORD, LINEN, WOOL })
	t.eq(rows[1].discountPercent, 96)
	t.eq(rows[2].discountPercent, 50)
	t.eq(rows[3].discountPercent, 3)
end)

t.test('scan search filters by name, max price, discount and vendor', function()
	t.same(ids(Buy.fromSnapshot(SNAPSHOT, { text = '  CLOTH ' }, buyDeps())), { LINEN, WOOL })
	t.same(ids(Buy.fromSnapshot(SNAPSHOT, { maxPrice = 300 }, buyDeps())), { LINEN, WOOL })
	t.same(ids(Buy.fromSnapshot(SNAPSHOT, { underRulePercent = 40 }, buyDeps())), { SWORD, LINEN })
	t.same(ids(Buy.fromSnapshot(SNAPSHOT, { underVendor = true }, buyDeps())), { SWORD })
	t.same(ids(Buy.fromSnapshot(SNAPSHOT, { text = 'cloth', maxPrice = 100 }, buyDeps())), { LINEN })
end)

t.test('scan search treats blank and junk filters as unset and copes with no scan', function()
	t.eq(#Buy.fromSnapshot(SNAPSHOT, { text = '   ', maxPrice = 0 / 0, underRulePercent = -5 }, buyDeps()), 3)
	t.same(Buy.fromSnapshot(nil, {}, buyDeps()), {})
	t.same(Buy.fromSnapshot({ at = 1 }, nil, buyDeps()), {})
	t.raises(function()
		Buy.fromSnapshot(SNAPSHOT, {}, nil)
	end, 'deps')
end)

t.test('scan search asks a rule price only for items past the cheap checks, and stops at the limit', function()
	local asked = 0
	local deps = buyDeps({
		rulePrice = function()
			asked = asked + 1
			return 1000
		end,
		limit = 1,
	})
	local rows = Buy.fromSnapshot(SNAPSHOT, { maxPrice = 100 }, deps)
	t.eq(asked, 1)
	t.eq(#rows, 1)
	t.eq(#Buy.fromSnapshot(SNAPSHOT, {}, deps), 1, 'limit')
end)

t.test('an item without a known name is left out while a text filter is set', function()
	local deps = buyDeps({
		itemName = function()
			return nil
		end,
	})
	t.eq(#Buy.fromSnapshot(SNAPSHOT, { text = 'cloth' }, deps), 0)
	t.eq(#Buy.fromSnapshot(SNAPSHOT, {}, deps), 3)
end)

t.test('without a discount filter only the cheapest candidates are priced', function()
	local items = {}
	for itemId = 1, 30 do
		items[itemId] = { min = 1000 - itemId, units = 1, levels = { { price = 1000 - itemId, qty = 1 } } }
	end
	local asked = {}
	local deps = buyDeps({
		itemName = function()
			return 'thing'
		end,
		vendorPrice = function()
			return nil
		end,
		rulePrice = function(itemId)
			asked[#asked + 1] = itemId
			return 2000
		end,
		maxCandidates = 5,
		limit = 100,
	})
	local rows = Buy.fromSnapshot({ at = NOW, items = items }, {}, deps)
	t.eq(#asked, 5, 'five priced, not thirty')
	t.same(ids(rows), { 30, 29, 28, 27, 26 }, 'the cheapest five, deepest discount first')
	asked = {}
	Buy.fromSnapshot({ at = NOW, items = items }, { underRulePercent = 10 }, deps)
	t.eq(#asked, 30, 'a discount filter prices every candidate up to its own cap')
	t.eq(Buy.MAX_CANDIDATES, 500)
end)

t.test('a discount filter prices at most its cap and says it was capped', function()
	local items = {}
	for itemId = 1, 30 do
		items[itemId] = { min = 1000 - itemId, units = 1, levels = { { price = 1000 - itemId, qty = 1 } } }
	end
	local asked = 0
	local deps = buyDeps({
		itemName = function()
			return 'thing'
		end,
		vendorPrice = function()
			return nil
		end,
		rulePrice = function()
			asked = asked + 1
			return 2000
		end,
		maxFilteredCandidates = 10,
		limit = 100,
	})
	local rows, isCapped = Buy.fromSnapshot({ at = NOW, items = items }, { underRulePercent = 10 }, deps)
	t.eq(asked, 10)
	t.eq(#rows, 10)
	t.eq(isCapped, true)
	t.eq(select(2, Buy.fromSnapshot(SNAPSHOT, { underRulePercent = 10 }, buyDeps())), false)
	t.eq(Buy.MAX_FILTERED_CANDIDATES, 2000)
end)

t.test('a scan row carries the rule price confidence, or why there is no rule price', function()
	local confidence = { level = 'medium', reasons = { { text = 'Old', level = 'medium' } } }
	local deps = buyDeps({
		rulePrice = function(itemId)
			if itemId == LINEN then
				return 120, confidence, nil, true
			end
			return nil, nil, 'no market price'
		end,
	})
	local rows = Buy.fromSnapshot(SNAPSHOT, {}, deps)
	local linen, wool
	for _, row in ipairs(rows) do
		linen = row.itemId == LINEN and row or linen
		wool = row.itemId == WOOL and row or wool
	end
	t.same(linen.confidence, confidence)
	t.eq(linen.usesPriceSource, true)
	t.eq(wool.rulePrice, nil)
	t.eq(wool.ruleReason, 'no market price')
end)

local LIVE = {
	{ auctionId = 3, unitPrice = 90, quantity = 5, isCommodity = true },
	{ auctionId = 1, unitPrice = 60, quantity = 10, isCommodity = true, isOwn = true },
	{ auctionId = 2, unitPrice = 70, quantity = 4, isCommodity = true },
	{ auctionId = 4, unitPrice = 150, quantity = 20, isCommodity = true },
}

t.test('live listings skip own ones, sort cheapest first and carry the discount', function()
	local rows = Buy.fromLive(LIVE, { maxPrice = 100 }, 120)
	t.eq(#rows, 2)
	t.eq(rows[1].auctionId, 2)
	t.eq(rows[1].discountPercent, 41)
	t.eq(rows[2].auctionId, 3)
	t.eq(#Buy.fromLive(nil), 0)
	local withoutId = Buy.fromLive(
		{ { unitPrice = 50, quantity = 1 }, { auctionId = 9, unitPrice = 60, quantity = 1 } },
		{}
	)
	t.eq(#withoutId, 1, 'an item listing without an auction id cannot be bought')
	t.eq(withoutId[1].auctionId, 9)
end)

t.test('a commodity buy up to a unit price counts units and cost cheapest first', function()
	local units, total = Buy.unitsWithin(LIVE, 100)
	t.eq(units, 9)
	t.eq(total, 4 * 70 + 5 * 90)
	units, total = Buy.unitsWithin(LIVE, 100, 6)
	t.eq(units, 6)
	t.eq(total, 4 * 70 + 2 * 90)
	t.eq(Buy.unitsWithin(LIVE, 10), 0)
	t.raises(function()
		Buy.unitsWithin(LIVE, nil)
	end, 'maxUnitPrice')
end)

t.group('known item names')

t.test('names come only from items seen: no item data is requested by a name search', function()
	local requested = {}
	local store = assert(ns.Store.open({}, {}))
	local prices = ns.PriceService.new({
		now = function()
			return NOW
		end,
		store = store,
		marketKey = function()
			return MARKET
		end,
		itemInfo = function(itemId)
			return ITEM_INFO[itemId]
		end,
		requestItemData = function(itemId)
			requested[#requested + 1] = itemId
		end,
	})
	t.same(prices:ItemIdsByName('linen'), {}, 'nothing seen yet')
	t.eq(prices:KnownName(LINEN), nil)
	prices:ItemInfo(LINEN)
	prices:ItemInfo(WOOL)
	t.eq(prices:KnownName(LINEN), 'Linen Cloth')
	t.same(prices:ItemIdsByName('linen cloth'), { LINEN }, 'an exact name')
	t.same(prices:ItemIdsByName('cloth'), { LINEN, WOOL }, 'partial names, sorted')
	t.same(prices:ItemIdsByName('cloth', 1), { LINEN }, 'up to the limit')
	t.eq(prices:KnownVendorPrice(SWORD), nil, 'not seen: no lookup')
	t.same(requested, {}, 'never asks the client to load items')
end)
