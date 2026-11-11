local t = ...

local ns = t.loadAddon()
local Trade, Ledger = ns.Trade, ns.Ledger

-- A stand-in for Value:Stack: 100 copper a unit, priced and high unless told otherwise.
local function valueOf(itemId, qty)
	if itemId == 666 then
		error('provider broke')
	end
	if itemId == 777 then
		return {
			copper = 0,
			isPriced = false,
			confidence = { level = 'low', reasons = { { code = 'noPrice', level = 'low', text = 'no price' } } },
		}
	end
	return { copper = 100 * qty, isPriced = true, confidence = { level = 'high', reasons = {} } }
end

local function side(gold, slots)
	return Trade.side({ gold = gold, slots = slots or {}, valueOf = valueOf })
end

local function hasReason(confidence, code)
	for _, reason in ipairs(confidence.reasons) do
		if reason.code == code then
			return true
		end
	end
	return false
end

t.group('trade')

t.test('a side counts gold at face value and items at their value', function()
	local result = side(5000, { [1] = { itemId = 2589, qty = 20 }, [3] = { itemId = 2592, qty = 1 } })
	t.eq(result.gold, 5000)
	t.eq(result.itemsCopper, 2100)
	t.eq(result.total, 7100)
	t.eq(#result.items, 2)
	t.eq(result.items[2].slot, 3)
	t.eq(result.unpriced, 0)
	t.eq(result.confidence.level, 'high')
end)

t.test('the enchant slot is never counted', function()
	local result = side(0, { [6] = { itemId = 1, qty = 1 }, [Trade.ENCHANT_SLOT] = { itemId = 2, qty = 5 } })
	t.eq(result.total, 100)
	t.eq(#result.items, 1)
end)

t.test('unloaded, unpriced and broken items are counted as 0 and marked low', function()
	local result = side(0, {
		[1] = { qty = 3 },
		[2] = { itemId = 777, qty = 1 },
		[3] = { itemId = 666, qty = 1 },
		[4] = { itemId = 1, qty = 2 },
	})
	t.eq(result.total, 200)
	t.eq(result.unpriced, 3)
	t.eq(result.confidence.level, 'low')
	t.truthy(hasReason(result.confidence, 'itemUnknown'))
	t.truthy(hasReason(result.confidence, 'noPrice'))
end)

t.test('unreadable gold counts as 0 with a reason; nil gold is just 0', function()
	local junk = side(-5)
	t.eq(junk.gold, 0)
	t.truthy(hasReason(junk.confidence, 'badInput'))
	local none = side(nil)
	t.eq(none.gold, 0)
	t.eq(#none.confidence.reasons, 0)
end)

t.test('a side needs valueOf', function()
	t.raises(function()
		Trade.side({ gold = 1 })
	end, 'needs valueOf')
end)

t.test('a gap exactly at the fee is no loss; one copper over is', function()
	-- Give 10,000; fee 500 + 5% of 10,000 = 1,000.
	local policy = { mode = 'warn', feeCopper = 500, feePercent = 5 }
	local atFee = Trade.verdict(side(10000), side(9000), policy)
	t.eq(atFee.fee, 1000)
	t.eq(atFee.gap, 1000)
	t.eq(atFee.isLoss, false)
	t.eq(atFee.action, 'ok')
	local overFee = Trade.verdict(side(10000), side(8999), policy)
	t.eq(overFee.isLoss, true)
	t.eq(overFee.action, 'warn')
end)

t.test('the fee percent rounds down; a gain is never a loss', function()
	local verdict = Trade.verdict(side(999), side(0), { mode = 'confirm', feeCopper = 0, feePercent = 5 })
	t.eq(verdict.fee, 49)
	t.eq(verdict.action, 'confirm')
	local gain = Trade.verdict(side(0), side(5000), { mode = 'confirm', feeCopper = 0, feePercent = 5 })
	t.eq(gain.gap, -5000)
	t.eq(gain.action, 'ok')
end)

t.test('mode off and a values-only partner see the numbers but no warning', function()
	local off = Trade.verdict(side(10000), side(0), { mode = 'off' })
	t.eq(off.isLoss, true)
	t.eq(off.action, 'ok')
	local friend = Trade.verdict(side(10000), side(0), { mode = 'confirm', partner = 'values', exempt = 'friend' })
	t.eq(friend.isLoss, true)
	t.eq(friend.action, 'ok')
	t.eq(friend.exempt, 'friend')
end)

t.test('a low side makes the verdict uncertain, never safe', function()
	local verdict = Trade.verdict(side(0, { [1] = { qty = 1 } }), side(0), { mode = 'warn' })
	t.eq(verdict.isUncertain, true)
	t.eq(verdict.confidence.level, 'low')
end)

t.test('a verdict needs a known mode', function()
	t.raises(function()
		Trade.verdict(side(0), side(0), { mode = 'nag' })
	end, 'unknown mode')
end)

t.test('partner policy: strangers get the full feature, the most trusting group wins', function()
	local settings = { friends = 'values', guild = 'off' }
	t.eq(Trade.partnerPolicy({}, settings), 'full')
	t.eq(Trade.partnerPolicy({ isFriend = true }, settings), 'values')
	t.eq(Trade.partnerPolicy({ isBnetFriend = true }, settings), 'values')
	local policy, exempt = Trade.partnerPolicy({ isFriend = true, isGuild = true }, settings)
	t.eq(policy, 'off')
	t.eq(exempt, 'guild')
	t.eq(Trade.partnerPolicy({ isGuild = true }, { friends = 'off', guild = 'full' }), 'full')
	t.eq(Trade.partnerPolicy({ isGuild = true }, { guild = 'bogus' }), 'full', 'a junk setting reads as full')
end)

t.group('ledger')

local function newMarket()
	return { ledger = {} }
end

t.test('events are stored as compact tuples and read back', function()
	local market = newMarket()
	t.eq(Ledger.append(market, { t = 10, kind = 'tradeIn', itemId = 2589, qty = 5, copper = 500, char = 'A-R' }), 1)
	t.eq(Ledger.append(market, { t = 20, kind = 'tradeOut', copper = 900, char = 'A-R' }), 2)
	t.same(market.ledger[1], { 10, 'tradeIn', 2589, 5, 500, 'A-R' })
	t.same(market.ledger[2], { 20, 'tradeOut', 0, 0, 900, 'A-R' })
	local events = Ledger.events(market)
	t.eq(#events, 2)
	t.eq(events[2].itemId, nil, 'gold has no item')
	t.eq(#Ledger.events(market, { kind = 'tradeIn' }), 1)
	t.eq(#Ledger.events(market, { since = 15 }), 1)
end)

t.test('a malformed event is a programmer error', function()
	local market = newMarket()
	t.raises(function()
		Ledger.append(market, { t = 1, kind = 'gift', copper = 1, char = 'A' })
	end, 'unknown kind')
	t.raises(function()
		Ledger.append(market, { t = 1, kind = 'tradeIn', copper = 1.5, char = 'A' })
	end, 'copper')
	t.raises(function()
		Ledger.append(market, { t = 1, kind = 'tradeIn', copper = 1 })
	end, 'char')
	t.raises(function()
		Ledger.append({}, { t = 1, kind = 'tradeIn', copper = 1, char = 'A' })
	end, 'ledger')
end)

t.test('junk in the saved ledger is skipped on read', function()
	local market = { ledger = { 'junk', { 1, 'nope', 0, 0, 1, 'A' }, { 2, 'tradeIn', 0, 0, 5, 'A' } } }
	local events = Ledger.events(market)
	t.eq(#events, 1)
	t.eq(events[1].copper, 5)
	t.eq(#Ledger.events(nil), 0)
end)

t.test('a completed trade logs what was given as tradeOut and what was got as tradeIn', function()
	local player = side(2500, { [1] = { itemId = 2589, qty = 20 } })
	local target = side(0, { [2] = { itemId = 777, qty = 1 }, [Trade.ENCHANT_SLOT] = { itemId = 5, qty = 1 } })
	local events = Ledger.tradeEvents({ player = player, target = target }, 100, 'Me-Realm')
	t.eq(#events, 3)
	t.same(events[1], { t = 100, kind = 'tradeOut', copper = 2500, char = 'Me-Realm' })
	t.same(events[2], { t = 100, kind = 'tradeOut', itemId = 2589, qty = 20, copper = 2000, char = 'Me-Realm' })
	t.same(events[3], { t = 100, kind = 'tradeIn', itemId = 777, qty = 1, copper = 0, char = 'Me-Realm' })
	local market = newMarket()
	for _, event in ipairs(events) do
		Ledger.append(market, event)
	end
	t.eq(#Ledger.events(market, { kind = 'tradeOut' }), 2)
end)

t.test('an item the client has not loaded is never logged as gold (itemId 0)', function()
	local player = side(0, { [1] = { qty = 3 }, [2] = { itemId = 2589, qty = 1 } })
	local events = Ledger.tradeEvents({ player = player, target = side(0) }, 100, 'Me-Realm')
	t.eq(#events, 1, 'the unloaded stack is skipped')
	t.eq(events[1].itemId, 2589)
	t.raises(function()
		Ledger.append(newMarket(), { t = 1, kind = 'tradeIn', itemId = 0, qty = 1, copper = 1, char = 'A' })
	end, 'itemId')
end)

t.test('appendAll writes every event or none', function()
	local market = newMarket()
	local good = { t = 1, kind = 'tradeIn', copper = 5, char = 'A' }
	t.raises(function()
		Ledger.appendAll(market, { good, { t = 1, kind = 'tradeIn', copper = -1, char = 'A' } })
	end, 'copper')
	t.eq(#market.ledger, 0, 'nothing written when one event is malformed')
	t.eq(Ledger.appendAll(market, { good, good }), 2)
	t.eq(#market.ledger, 2)
	t.eq(Ledger.appendAll(market, {}), 0)
end)
