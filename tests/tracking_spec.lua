local t = ...
local FakeGame = require('tests.fake_game')

local LINEN, SILK, BOLT = 2589, 4306, 2996
local MARKET = 'forever/normal/alliance/us'
local NOW = 1000000
local CHAR = 'Me-Realm'
local AHLEDGER_ROWS = {
	[2589] = { 120, 95, 500, 118, 125, 90, 160, 45 },
	[4306] = { 10, 9, 500, 10, 11, 8, 12, 45 },
	[2996] = { 400, 380, 50, 400, 410, 300, 500, 10 },
}

local function start()
	local game = FakeGame.new({
		now = NOW,
		itemInfo = {
			[LINEN] = { name = 'Linen Cloth', maxStack = 20, vendorPrice = 13 },
			[SILK] = { name = 'Silk Cloth', maxStack = 20, vendorPrice = 50 },
			[BOLT] = { name = 'Bolt of Linen Cloth', maxStack = 20, vendorPrice = 40 },
		},
	})
	game.env.AHledgerAPI = FakeGame.newAHledgerAPI({ market = MARKET, updated = NOW - 7200, rows = AHLEDGER_ROWS })
	game.env.GetRealmName = function()
		return 'Realm'
	end
	game.env.UnitName = function()
		return 'Me'
	end
	local addon = FakeGame.startAddon(t, game)
	return game, addon, addon.store:Market(MARKET)
end

local function events(addon, market, kind)
	return addon.Ledger.events(market, { kind = kind })
end

local function postLinen(game, qty, unitPrice, auctionId)
	game.containerItems['0:1'] = { itemID = LINEN, stackCount = qty }
	game.itemCounts[LINEN] = qty
	game.env.C_AuctionHouse.PostCommodity({ bag = 0, slot = 1 }, 2, qty, unitPrice)
	game.itemCounts[LINEN] = 0
	game:Fire('AUCTION_HOUSE_AUCTION_CREATED', auctionId)
end

-- The server answers a take: what was taken leaves the mail, an empty mail leaves the inbox
-- (the next mail moves up), and the client reports MAIL_INBOX_UPDATE.
local function serveTake(game, index, attachments, isMoneyTaken)
	local mail = game.mail[index]
	if isMoneyTaken then
		mail.money = 0
	end
	for _, attachment in ipairs(attachments or {}) do
		mail.items[attachment] = false
	end
	local hasItems = false
	for _, item in pairs(mail.items or {}) do
		hasItems = hasItems or item ~= false
	end
	if not hasItems and (mail.money or 0) == 0 then
		table.remove(game.mail, index)
	end
	game:Fire('MAIL_INBOX_UPDATE')
end

t.group('tracking: auction house and mail')

t.test('a post books the client deposit; the sale mail books sale, refund and cut once', function()
	local game, addon, market = start()
	t.eq(addon.errors and #addon.errors or 0, 0)
	postLinen(game, 10, 100, 77)
	local record = market.auctions[77]
	t.eq(record.itemId, LINEN)
	t.eq(record.qty, 10)
	t.eq(record.hours, 24)
	t.eq(record.deposit, 100, 'the client deposit')
	t.eq(record.char, CHAR)
	t.eq(events(addon, market, 'deposit')[1].copper, 100)
	game.mail[1] = {
		subject = 'Auction successful: Linen Cloth',
		money = 1050,
		invoice = { type = 'seller', itemName = 'Linen Cloth', bid = 1000, deposit = 100, cut = 50, count = 10 },
	}
	game.mail[1].daysLeft = 29.97
	game.env.TakeInboxMoney(1)
	game.mail[1].daysLeft = 29.96
	game.env.TakeInboxMoney(1)
	game.env.AutoLootMailItem(1)
	t.eq(#events(addon, market, 'sale'), 0, 'booked when the client answers')
	serveTake(game, 1, nil, true)
	t.eq(#events(addon, market, 'sale'), 1, 'booked once')
	t.eq(events(addon, market, 'sale')[1].copper, 1000)
	t.eq(events(addon, market, 'cut')[1].copper, 50)
	t.eq(events(addon, market, 'refund')[1].copper, 100)
	t.eq(market.auctions[77], nil, 'settled')
	t.same(addon.errors, {})
end)

t.test('an expired auction comes back by mail with its items', function()
	local game, addon, market = start()
	postLinen(game, 5, 100, 78)
	game:Advance(24 * 3600)
	game.mail[1] = { subject = 'Auction expired: Linen Cloth', items = { { itemId = LINEN, count = 5 } } }
	game.env.TakeInboxItem(1, 1)
	serveTake(game, 1, { 1 })
	t.eq(market.auctions[78], nil)
	t.eq(#events(addon, market, 'expire'), 1)
	t.same(addon.errors, {})
end)

t.test('a won mail books the buy into the cost pool; other mail is ignored', function()
	local game, addon, market = start()
	game.env.C_AuctionHouse.ConfirmCommoditiesPurchase(SILK, 20)
	game.mail[1] = {
		subject = 'Auction won: Silk Cloth',
		invoice = { type = 'buyer', itemName = 'Silk Cloth', bid = 200 },
		items = { { itemId = SILK, count = 20 } },
	}
	game.mail[2] = { subject = 'Hello there', money = 5 }
	game.env.AutoLootMailItem(1)
	game.env.TakeInboxMoney(2)
	serveTake(game, 1, { 1 })
	t.eq(events(addon, market, 'buy')[1].copper, 200)
	t.same(addon.CostPool.get(market, SILK), { units = 20, copper = 200 })
	t.eq(#addon.Ledger.events(market), 1)
end)

local function wonSilk(bid)
	return {
		subject = 'Auction won: Silk Cloth',
		invoice = { type = 'buyer', itemName = 'Silk Cloth', bid = bid, count = 20 },
		items = { { itemId = SILK, count = 10 }, { itemId = SILK, count = 10 } },
	}
end

local function boughtCopper(addon, market)
	local copper = 0
	for _, event in ipairs(events(addon, market, 'buy')) do
		copper = copper + event.copper
	end
	return copper
end

t.test('a won mail over two attachments books every copper paid', function()
	local game, addon, market = start()
	game.mail[1] = wonSilk(101)
	game.env.TakeInboxItem(1, 1)
	serveTake(game, 1, { 1 })
	game.env.TakeInboxItem(1, 2)
	serveTake(game, 1, { 2 })
	t.eq(boughtCopper(addon, market), 101)
	t.same(addon.CostPool.get(market, SILK), { units = 20, copper = 101 })
end)

t.test('a half-taken won mail does not change what the next same mail books', function()
	local game, addon, market = start()
	game.mail[1] = wonSilk(101)
	game.env.TakeInboxItem(1, 1)
	serveTake(game, 1, { 1 })
	t.eq(boughtCopper(addon, market), 50)
	-- The rest of mail one stays; mail two, the same buy in one stack, is looted whole.
	game.mail[2] = wonSilk(101)
	game.mail[2].items = { { itemId = SILK, count = 20 } }
	game.env.AutoLootMailItem(2)
	serveTake(game, 2, { 1 })
	t.eq(boughtCopper(addon, market), 50 + 101)
	game.env.TakeInboxItem(1, 2)
	serveTake(game, 1, { 2 })
	t.eq(boughtCopper(addon, market), 101 + 101)
	t.same(addon.CostPool.get(market, SILK), { units = 40, copper = 202 })
end)

local function wonSilkWithoutCount(bid)
	local mail = wonSilk(bid)
	mail.invoice.count = nil
	return mail
end

t.test('a won mail without an invoice count books every copper paid over two takes', function()
	local game, addon, market = start()
	game.mail[1] = wonSilkWithoutCount(101)
	game.env.TakeInboxItem(1, 1)
	serveTake(game, 1, { 1 })
	t.eq(boughtCopper(addon, market), 50)
	game.env.TakeInboxItem(1, 2)
	serveTake(game, 1, { 2 })
	t.eq(boughtCopper(addon, market), 101)
	t.same(addon.CostPool.get(market, SILK), { units = 20, copper = 101 })
end)

t.test('a half-taken won mail without a count leaves a same whole mail its full price', function()
	local game, addon, market = start()
	game.mail[1] = wonSilkWithoutCount(101)
	game.env.TakeInboxItem(1, 1)
	serveTake(game, 1, { 1 })
	game.mail[2] = wonSilkWithoutCount(101)
	game.env.TakeInboxItem(2, 1)
	serveTake(game, 2, { 1 })
	game.env.TakeInboxItem(2, 2)
	serveTake(game, 2, { 2 })
	t.eq(boughtCopper(addon, market), 50 + 101)
	game.env.TakeInboxItem(1, 2)
	serveTake(game, 1, { 2 })
	t.eq(boughtCopper(addon, market), 101 + 101)
end)

for _, case in ipairs({ { label = 'with', mail = wonSilk }, { label = 'without', mail = wonSilkWithoutCount } }) do
	t.test('two takes before the server answers book every copper paid, ' .. case.label .. ' a count', function()
		local game, addon, market = start()
		game.mail[1] = case.mail(101)
		game.env.TakeInboxItem(1, 1)
		game.env.TakeInboxItem(1, 2)
		serveTake(game, 1, { 1, 2 })
		t.eq(boughtCopper(addon, market), 101)
	end)

	t.test('looting a won mail of two attachments books every copper paid, ' .. case.label .. ' a count', function()
		local game, addon, market = start()
		game.mail[1] = case.mail(101)
		game.env.AutoLootMailItem(1)
		serveTake(game, 1, { 1, 2 })
		t.eq(boughtCopper(addon, market), 101)
		t.same(addon.CostPool.get(market, SILK), { units = 20, copper = 101 })
	end)
end

t.test('a take from the lower of two same won mails books when new mail lands on top', function()
	local game, addon, market = start()
	game.mail = { wonSilk(101), wonSilk(101) }
	game.env.TakeInboxItem(2, 1)
	game.mail[2].items[1] = false
	table.insert(game.mail, 1, { subject = 'Hello there', money = 5 })
	game:Fire('MAIL_INBOX_UPDATE')
	t.eq(boughtCopper(addon, market), 50)
	t.same(addon.CostPool.get(market, SILK), { units = 10, copper = 50 })
end)

t.test('closing the mailbox drops the takes it has not answered', function()
	local game, addon, market = start()
	game.mail[1] = {
		subject = 'Auction won: Silk Cloth',
		invoice = { type = 'buyer', itemName = 'Silk Cloth', bid = 200 },
		items = { { itemId = SILK, count = 20 } },
	}
	game.env.TakeInboxItem(1, 1)
	-- Bags full: the take fails, and the closed mailbox reads no mail.
	local mail = game.mail[1]
	game.mail[1] = nil
	game:Fire('MAIL_CLOSED')
	game.mail[1] = mail
	t.eq(#events(addon, market, 'buy'), 0, 'not booked on a guess')
	game.env.TakeInboxItem(1, 1)
	serveTake(game, 1, { 1 })
	t.eq(#events(addon, market, 'buy'), 1, 'the real take books once')
end)

t.test('new mail arriving mid-take neither books a failed take nor hides a real one', function()
	local game, addon, market = start()
	postLinen(game, 10, 100, 81)
	postLinen(game, 10, 100, 82)
	local function saleMail(bid)
		return {
			subject = 'Auction successful: Linen Cloth',
			money = bid + 50,
			invoice = { type = 'seller', itemName = 'Linen Cloth', bid = bid, deposit = 100, cut = 50, count = 10 },
		}
	end
	game.mail[1] = saleMail(1000)
	game.env.TakeInboxMoney(1)
	-- The take fails (gold cap) while a letter arrives at the top of the inbox.
	table.insert(game.mail, 1, { subject = 'Hello there', money = 5 })
	game:Fire('MAIL_INBOX_UPDATE')
	t.eq(#events(addon, market, 'sale'), 0, 'failed take not booked')
	game.mail = { saleMail(1000) }
	game.env.TakeInboxMoney(1)
	-- The take goes through; another sale of the same item arrives as this mail leaves.
	game.mail = { saleMail(990) }
	game:Fire('MAIL_INBOX_UPDATE')
	t.eq(#events(addon, market, 'sale'), 1, 'real take booked')
end)

local function linenSaleMail(bid)
	return {
		subject = 'Auction successful: Linen Cloth',
		money = bid + 50,
		invoice = { type = 'seller', itemName = 'Linen Cloth', bid = bid, deposit = 100, cut = 50, count = 10 },
	}
end

t.test('new mail mid-take: a same-subject mail of another invoice where it moved is not the taken one', function()
	local game, addon, market = start()
	postLinen(game, 10, 100, 83)
	postLinen(game, 10, 100, 84)
	game.mail = { linenSaleMail(1000), linenSaleMail(2000) }
	game.env.TakeInboxMoney(1)
	-- The take goes through and mail one leaves; two letters arrive, one on top, one below.
	game.mail = { { subject = 'Hello there', money = 5 }, linenSaleMail(2000), { subject = 'Hi', money = 5 } }
	game:Fire('MAIL_INBOX_UPDATE')
	t.eq(#events(addon, market, 'sale'), 1, 'real take booked')
end)

t.test('new mail mid-take: a same-subject mail of another invoice in place is not the taken one', function()
	local game, addon, market = start()
	postLinen(game, 10, 100, 85)
	postLinen(game, 10, 100, 86)
	game.mail = { linenSaleMail(1000), linenSaleMail(2000) }
	game.env.TakeInboxMoney(1)
	-- The take goes through and mail one leaves; two letters arrive below the other sale.
	game.mail = { linenSaleMail(2000), { subject = 'Hello there', money = 5 }, { subject = 'Hi', money = 5 } }
	game:Fire('MAIL_INBOX_UPDATE')
	t.eq(#events(addon, market, 'sale'), 1, 'real take booked')
end)

t.test('a won mail of another invoice taking the place of the taken one does not hide the take', function()
	local game, addon, market = start()
	game.mail[1] = wonSilk(101)
	game.mail[1].items = { { itemId = SILK, count = 20 } }
	game.env.TakeInboxItem(1, 1)
	-- The take goes through and the mail leaves as another buy of the same item arrives.
	game.mail[1] = wonSilk(150)
	game.mail[1].items = { { itemId = SILK, count = 20 } }
	game:Fire('MAIL_INBOX_UPDATE')
	t.eq(boughtCopper(addon, market), 101)
end)

t.test('new mail sorted below the taken one does not book a failed take', function()
	local game, addon, market = start()
	postLinen(game, 10, 100, 81)
	game.mail[1] = {
		subject = 'Auction successful: Linen Cloth',
		money = 1050,
		invoice = { type = 'seller', itemName = 'Linen Cloth', bid = 1000, deposit = 100, cut = 50, count = 10 },
	}
	game.env.TakeInboxMoney(1)
	-- The take fails (gold cap); a letter arrives below it, so the index still names the mail.
	game.mail[2] = { subject = 'Hello there', money = 5 }
	game:Fire('MAIL_INBOX_UPDATE')
	t.eq(#events(addon, market, 'sale'), 0)
end)

t.test('a two-stack return mail books each attachment once; a live auction is left alone', function()
	local game, addon, market = start()
	postLinen(game, 40, 100, 78)
	game:Advance(25 * 3600)
	postLinen(game, 20, 100, 79)
	game.mail[1] = {
		subject = 'Auction expired: Linen Cloth',
		daysLeft = 29.99,
		items = { { itemId = LINEN, count = 20 }, { itemId = LINEN, count = 20 } },
	}
	game.env.AutoLootMailItem(1)
	game.mail[1].daysLeft = 29.98
	game:Fire('MAIL_INBOX_UPDATE')
	t.eq(#events(addon, market, 'expire'), 0, 'bags full: nothing left the mail')
	game.env.TakeInboxItem(1, 1)
	game.mail[1].daysLeft = 29.97
	game.env.TakeInboxItem(1, 1)
	serveTake(game, 1, { 1 })
	game.mail[1].daysLeft = 29.96
	game.env.TakeInboxItem(1, 2)
	serveTake(game, 1, { 2 })
	local units = 0
	for _, event in ipairs(events(addon, market, 'expire')) do
		units = units + event.qty
	end
	t.eq(units, 40, 'two attachments, 40 units')
	t.eq(market.auctions[78], nil, 'settled')
	t.eq(market.auctions[79].remaining, 20, 'the live auction is untouched')
	t.eq(market.auctions[79].state, 'active')
	t.same(addon.errors, {})
end)

t.test('two same sale mails book twice; a double take books once', function()
	local game, addon, market = start()
	postLinen(game, 10, 100, 81)
	postLinen(game, 10, 100, 82)
	local function saleMail()
		return {
			subject = 'Auction successful: Linen Cloth',
			money = 1050,
			invoice = { type = 'seller', itemName = 'Linen Cloth', bid = 1000, deposit = 100, cut = 50, count = 10 },
		}
	end
	game.mail[1], game.mail[2] = saleMail(), saleMail()
	game.env.TakeInboxMoney(1)
	game.env.TakeInboxMoney(1)
	serveTake(game, 1, nil, true)
	game.env.TakeInboxMoney(1)
	serveTake(game, 1, nil, true)
	t.eq(#events(addon, market, 'sale'), 2)
	t.eq(#events(addon, market, 'cut'), 2)
	t.eq(market.auctions[81], nil)
	t.eq(market.auctions[82], nil)
end)

t.test('a sale mail without a count is counted at the price of the auction it settles', function()
	local game, addon, market = start()
	postLinen(game, 10, 100, 1)
	postLinen(game, 10, 50, 2)
	game.mail[1] = {
		subject = 'Auction successful: Linen Cloth',
		money = 145,
		invoice = { type = 'seller', itemName = 'Linen Cloth', bid = 150, deposit = 0, cut = 5 },
	}
	game.env.TakeInboxMoney(1)
	serveTake(game, 1, nil, true)
	t.eq(events(addon, market, 'sale')[1].qty, 3, '150 buys 3 at 50, not 2 at 100')
	t.eq(market.auctions[2].remaining, 7)
	t.eq(market.auctions[1].remaining, 10)
end)

t.test('an outbid mail drops the bid it answers', function()
	local game, addon = start()
	game.auctionHouse.byId = { [500] = { itemKey = { itemID = SILK }, quantity = 1 } }
	game.env.C_AuctionHouse.PlaceBid(500, 100)
	t.eq(#addon.books.pendingBuys, 1)
	t.eq(addon.books.pendingBuys[1].isBid, true)
	game.mail[1] = { subject = 'Outbid on Silk Cloth', money = 100 }
	game.env.TakeInboxMoney(1)
	serveTake(game, 1, nil, true)
	t.eq(#addon.books.pendingBuys, 0)
	t.same(addon.errors, {})
end)

t.test('a declined post is dropped: the next post books its own price', function()
	local game, addon, market = start()
	game.containerItems['0:1'] = { itemID = LINEN, stackCount = 10 }
	game.itemCounts[LINEN] = 10
	game.env.C_AuctionHouse.PostCommodity({ bag = 0, slot = 1 }, 2, 10, 50)
	game:Fire('AUCTION_HOUSE_POST_WARNING')
	-- The player declines the warning and posts again at 90.
	game.env.C_AuctionHouse.PostCommodity({ bag = 0, slot = 1 }, 2, 10, 90)
	game:Fire('AUCTION_HOUSE_AUCTION_CREATED', 90)
	t.eq(market.auctions[90].unitPrice, 90)
	t.eq(#events(addon, market, 'deposit'), 1)
	t.eq(#addon.books.pendingPosts, 0, 'nothing left to spill onto the next post')
	game.containerItems['0:2'] = { itemID = SILK, stackCount = 5 }
	game.env.C_AuctionHouse.PostCommodity({ bag = 0, slot = 2 }, 2, 5, 10)
	game:Fire('AUCTION_HOUSE_AUCTION_CREATED', 91)
	t.eq(market.auctions[91].itemId, SILK)
end)

t.test('a warned post that is not confirmed is dropped by the next post of another item', function()
	local game, _, market = start()
	game.containerItems['0:1'] = { itemID = LINEN, stackCount = 10 }
	game.containerItems['0:2'] = { itemID = SILK, stackCount = 5 }
	game.env.C_AuctionHouse.PostCommodity({ bag = 0, slot = 1 }, 2, 10, 50)
	game:Fire('AUCTION_HOUSE_POST_WARNING')
	game.env.C_AuctionHouse.PostCommodity({ bag = 0, slot = 2 }, 2, 5, 10)
	game:Fire('AUCTION_HOUSE_AUCTION_CREATED', 92)
	t.eq(market.auctions[92].itemId, SILK)
end)

t.test('a post error drops the post', function()
	local game, addon = start()
	game.containerItems['0:1'] = { itemID = LINEN, stackCount = 10 }
	game.env.C_AuctionHouse.PostCommodity({ bag = 0, slot = 1 }, 2, 10, 50)
	game:Fire('AUCTION_HOUSE_POST_ERROR')
	t.eq(#addon.books.pendingPosts, 0)
end)

t.test('owned auctions mark a sold auction before the mail', function()
	local game, _, market = start()
	postLinen(game, 4, 100, 79)
	game.owned = { { auctionID = 79, itemKey = { itemID = LINEN }, quantity = 4, status = 1 } }
	game:Fire('OWNED_AUCTIONS_UPDATED')
	t.eq(market.auctions[79].state, 'sold')
end)

t.test('a cancel marks the auction; the deposit stays lost', function()
	local game, _, market = start()
	postLinen(game, 4, 100, 80)
	game.env.C_AuctionHouse.CancelAuction(80)
	t.eq(market.auctions[80].state, 'cancelled')
end)

t.group('tracking: merchant, bags and crafting')

t.test('vendor buys enter the pool; vendor sells and destroys leave it', function()
	local game, addon, market = start()
	game.merchant[1] = { itemId = SILK, price = 100, stack = 5 }
	game.env.BuyMerchantItem(1, 10)
	t.same(addon.CostPool.get(market, SILK), { units = 10, copper = 200 })
	game.itemCounts[SILK] = 10
	game.containerItems['0:2'] = { itemID = SILK, stackCount = 4 }
	game.env.C_Container.UseContainerItem(0, 2)
	t.eq(#events(addon, market, 'vendorSell'), 0, 'merchant closed: a click uses the item')
	game.env.MerchantFrame:Show()
	game.env.C_Container.UseContainerItem(0, 2)
	t.eq(events(addon, market, 'vendorSell')[1].copper, 200)
	t.same(addon.CostPool.get(market, SILK), { units = 6, copper = 120 })
	game.itemCounts[SILK] = 6
	game.containerItems['0:3'] = { itemID = SILK, stackCount = 3 }
	game.env.C_Container.PickupContainerItem(0, 3)
	game.itemCounts[SILK] = 3
	game.env.DeleteCursorItem()
	t.eq(events(addon, market, 'destroy')[1].qty, 3)
	t.same(addon.CostPool.get(market, SILK), { units = 3, copper = 60 })
end)

t.test('a delete books the pickup only while the cursor still holds it', function()
	local game, addon, market = start()
	game.containerItems['0:3'] = { itemID = SILK, stackCount = 3 }
	game.itemCounts[SILK] = 3
	game.env.C_Container.PickupContainerItem(0, 3)
	game.cursorItem = LINEN
	game.env.DeleteCursorItem()
	t.eq(#events(addon, market, 'destroy'), 0, 'another item was on the cursor')
	game.cursorItem = SILK
	game.env.C_Container.PickupContainerItem(0, 3)
	game:Fire('CURSOR_CHANGED')
	game.cursorItem = nil
	game:Fire('CURSOR_CHANGED')
	game.env.DeleteCursorItem()
	t.eq(#events(addon, market, 'destroy'), 0, 'the stack was put back first')
	game.cursorItem = SILK
	game.env.C_Container.PickupContainerItem(0, 3)
	game:Fire('CURSOR_CHANGED')
	game.env.DeleteCursorItem()
	t.eq(#events(addon, market, 'destroy'), 1)
end)

t.test('a craft is booked when the cast succeeds, once a cast', function()
	local game, addon, market = start()
	game.schematics[3275] = {
		outputItemID = BOLT,
		quantityMin = 1,
		reagentSlotSchematics = { { reagentType = 1, quantityRequired = 2, reagents = { { itemID = LINEN } } } },
	}
	game.env.C_TradeSkillUI.CraftRecipe(3275, 2)
	game:Fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'guid', 3275)
	game:Fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'guid', 3275)
	game:Fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'guid', 3275)
	local crafts = events(addon, market, 'craft')
	t.eq(#crafts, 2, 'two casts noted, two booked')
	t.eq(crafts[1].itemId, BOLT)
	t.same(addon.errors, {})
end)

t.test('switched off: hooks stay quiet', function()
	local game, addon, market = start()
	addon.host.Disable('tracking')
	game.merchant[1] = { itemId = SILK, price = 100, stack = 5 }
	game.env.BuyMerchantItem(1, 5)
	t.eq(#addon.Ledger.events(market), 0)
	t.eq(addon.books, nil)
end)
