local t = ...

local ns = t.loadAddon()
local Flips, Guardrail, ScanStore = ns.Flips, ns.Guardrail, ns.ScanStore

local HIGH = { level = 'high', reasons = {} }

local function item(levels, extra)
	local units = 0
	for _, level in ipairs(levels) do
		units = units + level[2]
	end
	local scanItem = { itemId = 7, ageSeconds = 60, units = units, levels = {}, min = levels[1] and levels[1][1] }
	for index, level in ipairs(levels) do
		scanItem.levels[index] = { price = level[1], qty = level[2] }
	end
	for key, value in pairs(extra or {}) do
		scanItem[key] = value
	end
	return scanItem
end

local function snapshot(at, items)
	local packed = {}
	for itemId, levels in pairs(items) do
		local scanItem = item(levels)
		packed[itemId] = ScanStore.packItem({
			units = scanItem.units,
			levels = scanItem.levels,
			copperSeen = true,
			maxStackSeen = 20,
		})
	end
	return { at = at, items = packed }
end

t.test('a listing at exactly the vendor price is not a vendor flip', function()
	t.eq(Flips.vendorFlip(item({ { 100, 5 } }), 100), nil)
end)

t.test('a vendor flip buys every unit under the vendor price, and only those', function()
	local row = Flips.vendorFlip(item({ { 90, 2 }, { 99, 1 }, { 100, 3 } }), 100)
	t.eq(row.units, 3)
	t.eq(row.cost, 279)
	t.eq(row.profit, 21)
	t.eq(row.buyPrice, 90)
	t.eq(row.percent, 7)
	t.eq(row.usesPriceSource, false)
end)

t.test('a vendor flip without a vendor price is none', function()
	t.eq(Flips.vendorFlip(item({ { 90, 2 } }), nil), nil)
end)

t.test('a relist snaps the rule price down to the item step', function()
	local row = Flips.relistFlip(
		item({ { 1000, 3 }, { 1150, 1 }, { 1300, 5 } }),
		{ copper = 1234, step = 100, confidence = HIGH },
		{ vendor = 10 }
	)
	t.eq(row.sellPrice, 1200)
	-- 1150 is under 1200 but over what 1200 nets after the cut, so it is left alone.
	t.eq(row.units, 3)
	t.eq(row.cost, 3000)
	t.eq(row.profit, Guardrail.saleNet(1200, 3) - 3000)
end)

t.test('a copper-step relist keeps its copper', function()
	local row = Flips.relistFlip(item({ { 1000, 1 } }), { copper = 1234, step = 1, confidence = HIGH }, { vendor = 10 })
	t.eq(row.sellPrice, 1234)
end)

t.test('a relist with no sale chance is not a flip', function()
	-- One sale a day over 24 hours, with 5 units listed at or under the price ahead of ours.
	local row = Flips.relistFlip(
		item({ { 500, 5 }, { 1000, 1 } }),
		{ copper = 2000, step = 1, confidence = HIGH },
		{ vendor = 10, salesPerDay = 1, durationHours = 24 }
	)
	t.eq(row, nil)
end)

t.test('zero sales a day is known: no relist flip', function()
	local row = Flips.relistFlip(
		item({ { 1000, 1 } }),
		{ copper = 2000, step = 1, confidence = HIGH },
		{ salesPerDay = 0 }
	)
	t.eq(row, nil)
end)

t.test('a relist buys at most one listing period of sales', function()
	local row = Flips.relistFlip(
		item({ { 500, 6 } }),
		{ copper = 2000, step = 1, confidence = HIGH },
		{ vendor = 10, salesPerDay = 4, durationHours = 24 }
	)
	t.eq(row.units, 4)
	-- The 2 units left at 500 sell first: half a chance for ours.
	t.eq(row.sellChance, 0.5)
	t.eq(row.isCappedBySales, true)
end)

t.test('a relist without sales data says so and is medium', function()
	local row = Flips.relistFlip(item({ { 1000, 1 } }), { copper = 2000, step = 1, confidence = HIGH }, { vendor = 10 })
	t.eq(row.confidence.level, 'medium')
	t.eq(row.sellChance, nil)
	local codes = {}
	for _, reason in ipairs(row.confidence.reasons) do
		codes[reason.code] = true
	end
	t.truthy(codes.sellChanceUnknown, 'sellChanceUnknown reason')
end)

t.test('a relist carries the rule price confidence', function()
	local low = { level = 'low', reasons = { { code = 'thin', level = 'low', text = 'thin market' } } }
	local row = Flips.relistFlip(
		item({ { 1000, 1 } }),
		{ copper = 2000, step = 1, confidence = low, usesPriceSource = true },
		{ vendor = 10, salesPerDay = 10 }
	)
	t.eq(row.confidence.level, 'low')
	t.eq(row.usesPriceSource, true)
end)

t.test('scan confidence falls with the scan age', function()
	t.eq(Flips.scanConfidence(60).level, 'high')
	t.eq(Flips.scanConfidence(Flips.STALE_MEDIUM_SECONDS).level, 'medium')
	t.eq(Flips.scanConfidence(Flips.STALE_LOW_SECONDS).level, 'low')
	t.eq(Flips.scanConfidence(nil).level, 'medium')
end)

t.test('find keeps the best flip per item, best first, and leaves the scan cache alone', function()
	local snap = snapshot(1000, { [1] = { { 50, 4 } }, [2] = { { 90, 1 } } })
	local before = ScanStore.item(snap, 1)
	local rows = Flips.find(snap, {
		now = 1060,
		vendorPrice = function(itemId)
			return itemId == 1 and 100 or 100
		end,
		rulePrice = function(itemId)
			return itemId == 1 and { copper = 3000, step = 1, confidence = HIGH } or nil
		end,
		salesPerDay = function()
			return 100
		end,
	})
	t.eq(#rows, 2)
	t.eq(rows[1].itemId, 1)
	t.eq(rows[1].kind, 'relist')
	t.eq(rows[2].itemId, 2)
	t.eq(rows[2].kind, 'vendor')
	t.eq(rawget(before, 'itemId'), nil, 'cached scan item untouched')
end)

t.test('find honours the kind and margin filters', function()
	local snap = snapshot(1000, { [1] = { { 99, 1 } } })
	local deps = {
		vendorPrice = function()
			return 100
		end,
		rulePrice = function() end,
	}
	t.eq(#Flips.find(snap, deps, { kinds = { relist = true } }), 0)
	t.eq(#Flips.find(snap, deps, { minPercent = 5 }), 0)
	t.eq(#Flips.find(snap, deps), 1)
end)

t.test('find never throws on junk', function()
	t.same({ Flips.find(nil, {}) }, { {}, false })
	local rows = Flips.find(snapshot(1000, { [1] = { { 50, 1 } } }), {
		vendorPrice = function()
			error('boom')
		end,
		rulePrice = function()
			return 'junk'
		end,
	})
	t.eq(#rows, 0)
end)

t.test("find leaves the player's own listings out", function()
	local snap = snapshot(1000, { [1] = { { 50, 4 }, { 60, 2 } }, [2] = { { 80, 3 } } })
	local before = ScanStore.item(snap, 1)
	local own = { [1] = { { unitPrice = 50, listed = 3 } }, [2] = { { unitPrice = 80, listed = 3 } } }
	local rows = Flips.find(snap, {
		vendorPrice = function()
			return 100
		end,
		rulePrice = function() end,
		ownListings = function(itemId)
			return own[itemId]
		end,
	})
	t.eq(#rows, 1, 'item 2 is only our own units')
	t.eq(rows[1].itemId, 1)
	t.eq(rows[1].units, 3, 'one unit at 50 and two at 60')
	t.eq(rows[1].cost, 50 + 120)
	t.eq(rows[1].buyPrice, 50)
	t.eq(#before.levels, 2, 'cached scan item untouched')
	t.eq(before.levels[1].qty, 4)
end)

t.test('an own listing posted after the scan takes nothing out of it', function()
	local snap = snapshot(1000, { [1] = { { 50, 4 } } })
	local rows = Flips.find(snap, {
		vendorPrice = function()
			return 100
		end,
		rulePrice = function() end,
		ownListings = function()
			return { { unitPrice = 50, listed = 4, postedAt = 1001 } }
		end,
	})
	t.eq(#rows, 1)
	t.eq(rows[1].units, 4)
end)
