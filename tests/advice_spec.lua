local t = ...

local ns = t.loadAddon()
local Advice, Guardrail = ns.Advice, ns.Guardrail

local function auction(unitPrice, listed, deposit)
	return { itemId = 7, unitPrice = unitPrice, listed = listed or 1, deposit = deposit or 0 }
end

t.test('undercut by more than the threshold: relist one step under the cheapest', function()
	local advice = Advice.forAuction(auction(10000), { cheapestOther = 9000, step = 100, scanAgeSeconds = 60 })
	t.eq(advice.action, 'relist')
	t.eq(advice.direction, 'down')
	t.eq(advice.price, 8900)
	t.eq(advice.confidence.level, 'high')
end)

t.test('a copper-step undercut goes one copper under', function()
	local advice = Advice.forAuction(auction(10000), { cheapestOther = 9000, step = 1, scanAgeSeconds = 60 })
	t.eq(advice.price, 8999)
end)

t.test('undercut by less than the threshold: hold', function()
	local advice = Advice.forAuction(auction(10000), { cheapestOther = 9700, step = 1, scanAgeSeconds = 60 })
	t.eq(advice.action, 'hold')
	t.eq(advice.code, 'closeEnough')
end)

t.test('the threshold is an option', function()
	local facts = { cheapestOther = 9700, step = 1, scanAgeSeconds = 60 }
	t.eq(Advice.forAuction(auction(10000), facts, { thresholdPercent = 2 }).action, 'relist')
end)

t.test('the floor: never relist under break-even or the vendor price', function()
	local advice =
		Advice.forAuction(auction(10000), { cheapestOther = 5000, step = 1, breakEven = 6000, scanAgeSeconds = 60 })
	t.eq(advice.code, 'underFloor')
	advice = Advice.forAuction(auction(10000), { cheapestOther = 5000, step = 1, vendor = 7000, scanAgeSeconds = 60 })
	t.eq(advice.code, 'underFloor')
end)

t.test('a relist that nets no more than a vendor after the lost deposit: hold', function()
	-- 10 units: relisting at 4999 nets saleNet(4999, 10) less a big deposit.
	local deposit = Guardrail.saleNet(4999, 10) - 4000 * 10
	local advice = Advice.forAuction(
		auction(10000, 10, deposit),
		{ cheapestOther = 5000, step = 1, vendor = 4000, scanAgeSeconds = 60 }
	)
	t.eq(advice.code, 'costsMore')
end)

t.test('the market rose past the threshold: relist up, one step under the cheapest', function()
	local advice = Advice.forAuction(auction(10000), { cheapestOther = 12000, step = 100, scanAgeSeconds = 60 })
	t.eq(advice.action, 'relist')
	t.eq(advice.direction, 'up')
	t.eq(advice.price, 11900)
	t.eq(advice.gain, Guardrail.saleNet(11900, 1) - Guardrail.saleNet(10000, 1))
end)

t.test('a rise smaller than the deposit lost: hold', function()
	local advice = Advice.forAuction(auction(10000, 1, 2000), { cheapestOther = 12000, step = 1, scanAgeSeconds = 60 })
	t.eq(advice.code, 'costsMore')
end)

t.test('alone on the market: the rule price is the market, snapped to the step', function()
	local advice = Advice.forAuction(auction(10000), { rulePrice = 15050, step = 100, scanAgeSeconds = 60 })
	t.eq(advice.direction, 'up')
	t.eq(advice.price, 15000)
	t.eq(Advice.forAuction(auction(10000), { rulePrice = 10200, step = 1, scanAgeSeconds = 60 }).code, 'cheapest')
end)

t.test('no market at all: hold, and a bad auction is low confidence', function()
	t.eq(Advice.forAuction(auction(10000), { step = 1, scanAgeSeconds = 60 }).code, 'noMarket')
	local advice = Advice.forAuction({ unitPrice = 'x' }, { step = 1 })
	t.eq(advice.code, 'unreadable')
	t.eq(advice.confidence.level, 'low')
end)

t.test('an old scan lowers the advice confidence', function()
	local advice = Advice.forAuction(auction(10000), { cheapestOther = 9000, step = 1, scanAgeSeconds = 3 * 3600 })
	t.eq(advice.confidence.level, 'low')
end)

t.test('cheapestOther skips the levels that are only ours', function()
	local levels = { { price = 900, qty = 2 }, { price = 1000, qty = 5 } }
	t.eq(Advice.cheapestOther(levels, { { unitPrice = 900, listed = 2 } }), 1000)
	t.eq(Advice.cheapestOther(levels, { { unitPrice = 900, listed = 1 } }), 900)
	t.eq(Advice.cheapestOther(levels, {}), 900)
	t.eq(Advice.cheapestOther(nil, nil), nil)
end)

t.test('untracked: active owned auctions with no venture', function()
	local owned = {
		{ auctionId = 1, itemId = 7 },
		{ auctionId = 2, itemId = 7 },
		{ auctionId = 3, itemId = 7, isSold = true },
		{ auctionId = 4, itemId = 7 },
		'junk',
	}
	local tracked = { [2] = { ventureId = 5 }, [4] = { ventureId = nil } }
	local list = Advice.untracked(owned, tracked)
	t.eq(#list, 2)
	t.eq(list[1].auctionId, 1)
	t.eq(list[2].auctionId, 4)
	t.same(Advice.untracked(nil, nil), {})
end)

t.test('a down relist reports a signed change and its margin over a vendor', function()
	local advice = Advice.forAuction(auction(10000), { cheapestOther = 9000, step = 100, scanAgeSeconds = 60 })
	t.eq(advice.net, Guardrail.saleNet(8900, 1))
	t.eq(advice.gain, Guardrail.saleNet(8900, 1) - Guardrail.saleNet(10000, 1))
	t.truthy(advice.gain < 0, 'a down relist gives up margin')
	t.eq(advice.overVendor, advice.net)
end)

t.test('a down relist against a deposit: the deposit comes off the net', function()
	local advice = Advice.forAuction(
		auction(10000, 2, 500),
		{ cheapestOther = 9000, step = 100, vendor = 1000, scanAgeSeconds = 60 }
	)
	t.eq(advice.action, 'relist')
	t.eq(advice.net, Guardrail.saleNet(8900, 2) - 500)
	t.eq(advice.gain, advice.net - Guardrail.saleNet(10000, 2))
	t.eq(advice.overVendor, advice.net - 2000)
end)

t.test('a tie with the cheapest other listing says so', function()
	local advice = Advice.forAuction(auction(10000), { cheapestOther = 10000, step = 1, scanAgeSeconds = 60 })
	t.eq(advice.code, 'tied')
	t.eq(advice.text:find('cheapest', 1, true), nil)
end)

t.test('the rule price confidence counts only when the rule price set the target', function()
	local low = { level = 'low', reasons = { { code = 'thin', level = 'low', text = 'thin market' } } }
	local fromScan = Advice.forAuction(
		auction(10000),
		{ cheapestOther = 9000, rulePrice = 20000, step = 1, scanAgeSeconds = 60, confidence = low }
	)
	t.eq(fromScan.confidence.level, 'high')
	t.eq(fromScan.usesRulePrice, nil)
	local fromRule =
		Advice.forAuction(auction(10000), { rulePrice = 20000, step = 1, scanAgeSeconds = 60, confidence = low })
	t.eq(fromRule.confidence.level, 'low')
	t.eq(fromRule.usesRulePrice, true)
end)

t.test('untracked: skipped ids, and an unrecorded auction a pending venture post explains', function()
	local owned = {
		{ auctionId = 1, itemId = 7, qty = 2 },
		{ auctionId = 2, itemId = 7, qty = 2 },
		{ auctionId = 3, itemId = 8, qty = 1 },
	}
	local list = Advice.untracked(owned, {}, {
		pendingVenturePosts = { { itemId = 7, qty = 2 } },
		skip = { [3] = true },
	})
	-- One pending post explains one auction only.
	t.eq(#list, 1)
	t.eq(list[1].auctionId, 2)
	local expiredVenture = { [1] = { ventureId = 5, state = 'expired' } }
	t.eq(#Advice.untracked({ owned[1] }, expiredVenture), 0)
end)
