local t = ...

local ns = t.loadAddon()
local AuctionTracker, MailMatcher, Ledger, CostPool = ns.AuctionTracker, ns.MailMatcher, ns.Ledger, ns.CostPool

local CHAR = 'Me-Realm'
local START = 100 * 86400

local function newMarket()
	return { ledger = {}, auctions = {}, costPools = {}, ventures = {} }
end

local function newBooks(options)
	options = options or {}
	local market = newMarket()
	local clock = { now = START }
	local held = options.held or {}
	local sent = {}
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
		vendorPrice = function(itemId)
			return (options.vendor or {})[itemId]
		end,
		valueOf = function(_, qty)
			return (options.unitValue or 100) * qty
		end,
		send = function(message, ...)
			sent[#sent + 1] = { message, ... }
		end,
	})
	return books, market, clock, held, sent
end

local function post(books, itemId, qty, unitPrice, deposit, hours)
	books:OnPost({ itemId = itemId, qty = qty, unitPrice = unitPrice, hours = hours or 24, deposit = deposit })
end

local function kinds(market)
	local list = {}
	for _, event in ipairs(Ledger.events(market)) do
		list[#list + 1] = event.kind
	end
	return table.concat(list, ',')
end

t.group('auction tracker')

t.test('a post waits for its auction id, then is tracked as active', function()
	local market, pending = newMarket(), {}
	AuctionTracker.notePost(
		pending,
		{ itemId = 5, qty = 2, unitPrice = 300, hours = 12, deposit = 40, char = CHAR },
		10
	)
	local record = AuctionTracker.created(market, pending, 777, 11)
	t.eq(record.state, 'active')
	t.eq(record.remaining, 2)
	t.eq(record.deposit, 40)
	t.eq(market.auctions[777], record)
	t.eq(#pending, 0)
	t.eq(AuctionTracker.created(market, pending, 778, 12), nil, 'no pending post: not tracked')
end)

t.test('a confirm replaces the post it confirms; stale posts are dropped', function()
	local pending = {}
	local spec = { itemId = 5, qty = 2, unitPrice = 300, hours = 12, char = CHAR }
	AuctionTracker.notePost(pending, spec, 10)
	AuctionTracker.notePost(pending, {
		itemId = 5,
		qty = 2,
		unitPrice = 300,
		hours = 12,
		char = CHAR,
		isConfirm = true,
	}, 12)
	t.eq(#pending, 1)
	AuctionTracker.notePost(pending, spec, 12 + AuctionTracker.PENDING_SECONDS + 1)
	t.eq(#pending, 1, 'the old one went stale')
	t.raises(function()
		AuctionTracker.notePost(pending, { qty = 1 }, 1)
	end, 'itemId')
end)

t.test('two posts from one stack are both tracked; a declined warning is dropped', function()
	local market, pending = newMarket(), {}
	local first = { itemId = 5, qty = 5, unitPrice = 100, hours = 12, char = CHAR, slot = '0:1' }
	local second = { itemId = 5, qty = 8, unitPrice = 120, hours = 12, char = CHAR, slot = '0:1' }
	AuctionTracker.notePost(pending, first, 10)
	AuctionTracker.notePost(pending, second, 11)
	t.eq(#pending, 2)
	local one = AuctionTracker.created(market, pending, 1, 12)
	local two = AuctionTracker.created(market, pending, 2, 12)
	t.eq(one.qty, 5)
	t.eq(one.unitPrice, 100)
	t.eq(two and two.qty, 8)
	t.eq(two and two.unitPrice, 120)
	AuctionTracker.notePost(pending, first, 20)
	AuctionTracker.noteWarning(pending)
	AuctionTracker.notePost(pending, second, 21)
	t.eq(#pending, 1, 'the held post was declined')
	t.eq(pending[1].qty, 8)
end)

t.test('the owned list: sold, sold before the time ran out, expired after it, partial sales', function()
	local market, pending = newMarket(), {}
	for index, qty in ipairs({ 1, 1, 1, 20 }) do
		AuctionTracker.notePost(pending, { itemId = index, qty = qty, unitPrice = 10, hours = 12, char = CHAR }, 0)
		AuctionTracker.created(market, pending, index, 0)
	end
	AuctionTracker.notePost(pending, { itemId = 9, qty = 1, unitPrice = 10, hours = 12, char = 'Alt-Realm' }, 0)
	AuctionTracker.created(market, pending, 9, 0)
	local owned = { { auctionId = 1, qty = 1, isSold = true }, { auctionId = 4, qty = 15 } }
	local changes = AuctionTracker.reconcile(market, owned, CHAR, 3600)
	table.sort(changes, function(a, b)
		return a.auctionId < b.auctionId
	end)
	t.eq(#changes, 4, 'the alt auction is not this list')
	t.eq(market.auctions[1].state, 'sold')
	t.eq(market.auctions[2].state, 'sold', 'gone before its time: bought')
	t.eq(changes[4].soldQty, 5)
	t.eq(market.auctions[4].state, 'active')
	t.eq(market.auctions[4].listed, 15)
	t.eq(market.auctions[9].state, 'active')
	t.eq(#AuctionTracker.reconcile(market, owned, CHAR, 3601), 0, 'the same list again changes nothing')
	-- Auction 4 leaves the list after its 12 hours: expired.
	AuctionTracker.reconcile(market, {}, CHAR, 12 * 3600)
	t.eq(market.auctions[4].state, 'expired')
end)

t.test('expiry by the clock, settling and pruning', function()
	local market, pending = newMarket(), {}
	AuctionTracker.notePost(pending, { itemId = 1, qty = 3, unitPrice = 10, hours = 12, char = CHAR }, 0)
	AuctionTracker.created(market, pending, 1, 0)
	t.eq(#AuctionTracker.expireDue(market, 12 * 3600 - 1), 0)
	t.eq(#AuctionTracker.expireDue(market, 12 * 3600), 1)
	t.eq(AuctionTracker.settle(market, 1, 2, 50000), 2)
	t.eq(market.auctions[1].remaining, 1)
	t.eq(AuctionTracker.settle(market, 1, 5, 50000), 1, 'never more than remained')
	t.eq(market.auctions[1], nil)
	AuctionTracker.notePost(pending, { itemId = 1, qty = 1, unitPrice = 10, hours = 12, char = CHAR }, 0)
	AuctionTracker.created(market, pending, 2, 0)
	market.auctions[3] = 'junk'
	t.eq(AuctionTracker.prune(market, 31 * 86400), 1, 'junk goes')
	t.eq(AuctionTracker.prune(market, 31 * 86400 + 1), 1, 'a month unchanged goes')
end)

t.test('cancel marks an active auction only', function()
	local market, pending = newMarket(), {}
	AuctionTracker.notePost(pending, { itemId = 1, qty = 1, unitPrice = 10, hours = 12, char = CHAR }, 0)
	AuctionTracker.created(market, pending, 1, 0)
	t.eq(AuctionTracker.noteCancel(market, 1, 5).state, 'cancelled')
	t.eq(AuctionTracker.noteCancel(market, 1, 6), nil)
	t.eq(AuctionTracker.noteCancel(market, 99, 6), nil)
	t.eq(#AuctionTracker.list(market, { state = 'cancelled' }), 1)
end)

t.group('mail matcher')

t.test('subjects come from the client format strings, English as the fallback', function()
	local prefixes = MailMatcher.prefixes(function(name)
		return name == 'AUCTION_SOLD_MAIL_SUBJECT' and 'Auktion erfolgreich: %s' or nil
	end)
	t.eq(prefixes.sold, 'Auktion erfolgreich: ')
	t.eq(prefixes.expired, 'Auction expired: ')
	local kind, name = MailMatcher.classify('Auktion erfolgreich: Linen Cloth', prefixes)
	t.eq(kind, 'sold')
	t.eq(name, 'Linen Cloth')
	t.eq(MailMatcher.classify('Outbid on Copper Ore', prefixes), 'outbid')
	t.eq(MailMatcher.classify('Hello there', prefixes), nil)
	t.eq(MailMatcher.classify(nil, prefixes), nil)
end)

t.test('a sale matches the auction at its unit price before an older one', function()
	local market = newMarket()
	market.auctions[1] = { itemId = 5, char = CHAR, remaining = 1, unitPrice = 100, state = 'active', postedAt = 1 }
	market.auctions[2] = { itemId = 5, char = CHAR, remaining = 1, unitPrice = 120, state = 'active', postedAt = 2 }
	market.auctions[3] = { itemId = 5, char = CHAR, remaining = 1, unitPrice = 120, state = 'cancelled', postedAt = 0 }
	t.eq(MailMatcher.findSale(market, { itemId = 5, qty = 1, bid = 120 }, CHAR), 2)
	t.eq(MailMatcher.findSale(market, { itemId = 5, qty = 1, bid = 999 }, CHAR), 1, 'no price match: oldest')
	t.eq(MailMatcher.findSale(market, { itemId = 5, qty = 1, bid = 120 }, 'Alt-Realm'), nil)
	t.eq(MailMatcher.findSale(market, { itemId = 5, bid = 360 }, CHAR), 2, 'no count: a whole number of units')
	t.eq(MailMatcher.findSale(market, { itemId = 5, bid = 130 }, CHAR), 1, 'no count, no match: oldest')
	t.eq(MailMatcher.findReturn(market, { kind = 'cancelled', itemId = 5 }, CHAR, 10), 3)
end)

t.test('a sale after a cancel still settles the cancelled auction', function()
	local market = newMarket()
	market.auctions[1] = { itemId = 5, char = CHAR, remaining = 4, unitPrice = 100, state = 'cancelled', postedAt = 1 }
	t.eq(MailMatcher.findSale(market, { itemId = 5, qty = 2, bid = 200 }, CHAR), 1)
end)

t.test('a return matches a live auction only once its time ran out', function()
	local market = newMarket()
	market.auctions[1] = { itemId = 5, char = CHAR, remaining = 4, state = 'active', postedAt = 0, hours = 24 }
	t.eq(MailMatcher.findReturn(market, { kind = 'expired', itemId = 5 }, CHAR, 3600), nil, 'still up')
	t.eq(MailMatcher.findReturn(market, { kind = 'expired', itemId = 5 }, CHAR, 24 * 3600), 1, 'due')
end)

t.test('a won mail takes from pending buys across several buys', function()
	local pending = { { itemId = 1, qty = 3, ventureId = 7 }, { itemId = 2, qty = 1 }, { itemId = 1, qty = 4 } }
	t.eq(MailMatcher.takeBuy(pending, 1, 5), 7)
	t.eq(#pending, 2)
	t.eq(pending[2].qty, 2)
	t.eq(MailMatcher.takeBuy(pending, 1, 2), nil)
	t.eq(#pending, 1)
end)

t.test('the troll test: P x 0.95 at or under vendor', function()
	t.eq(MailMatcher.isTroll(105, 100), true)
	t.eq(MailMatcher.isTroll(106, 100), false)
	t.eq(MailMatcher.isTroll(1, 0), false, 'no vendor price: never troll')
end)

t.group('books: deposits and cuts')

t.test('a sale returns the deposit and takes the cut, booked as the invoice says', function()
	local books, market = newBooks({ held = { [5] = 10 } })
	post(books, 5, 10, 50, 30)
	books:OnAuctionCreated(1)
	t.eq(kinds(market), 'post,deposit')
	local auctionId = books:OnSaleMail({ itemId = 5, qty = 10, bid = 500, deposit = 30, cut = 25 })
	t.eq(auctionId, 1)
	t.eq(market.auctions[1], nil, 'settled')
	t.eq(kinds(market), 'post,deposit,sale,refund,cut')
	local profit = Ledger.profit(market)
	t.eq(profit.income, 530)
	t.eq(profit.spent, 55)
	t.eq(profit.net, 475, 'the sale less the cut: the deposit came back')
	t.eq(Ledger.events(market, { kind = 'sale' })[1].auctionId, 1)
end)

t.test('an expiry and a cancel lose the whole deposit', function()
	local books, market, clock = newBooks({ held = { [5] = 2 } })
	post(books, 5, 1, 50, 30, 12)
	books:OnAuctionCreated(1)
	post(books, 5, 1, 50, 20, 12)
	books:OnAuctionCreated(2)
	books:OnCancel(2)
	clock.now = START + 12 * 3600
	books:Maintain()
	t.eq(market.auctions[1].state, 'expired')
	t.eq(books:OnReturnMail({ kind = 'expired', itemId = 5, qty = 1 }), 1)
	t.eq(books:OnReturnMail({ kind = 'cancelled', itemId = 5, qty = 1 }), 2)
	t.eq(kinds(market), 'post,deposit,post,deposit,expire,cancel')
	t.eq(Ledger.profit(market).net, -50)
	t.eq(next(market.auctions), nil)
end)

t.test('partial stacks: several invoices settle one commodity auction', function()
	local books, market, _, _, sent = newBooks({ held = { [5] = 20 } })
	post(books, 5, 20, 100, 60)
	books:OnAuctionCreated(1)
	books:OnOwnedList({ { auctionId = 1, qty = 15 } })
	t.eq(sent[#sent][1], 'AUCTION_SOLD')
	t.eq(sent[#sent][4], 5)
	books:OnSaleMail({ itemId = 5, qty = 5, bid = 500, deposit = 15, cut = 25 })
	t.eq(market.auctions[1].remaining, 15)
	books:OnSaleMail({ itemId = 5, qty = 10, bid = 1000, deposit = 30, cut = 50 })
	books:OnSaleMail({ itemId = 5, qty = 5, bid = 500, deposit = 15, cut = 25 })
	t.eq(market.auctions[1], nil)
	t.eq(#Ledger.events(market, { kind = 'sale' }), 3)
	t.eq(Ledger.profit(market).net, 2000 - 100, 'deposit fully back, 5% cut')
end)

t.test('the owned list counts each sold unit once, and its message is provisional', function()
	local books, _, _, _, sent = newBooks({ held = { [5] = 20 } })
	post(books, 5, 20, 100, 60)
	books:OnAuctionCreated(1)
	books:OnOwnedList({ { auctionId = 1, qty = 15 } })
	books:OnOwnedList({ { auctionId = 1, qty = 15, isSold = true } })
	t.eq(sent[#sent][1], 'AUCTION_SOLD')
	t.eq(sent[#sent][4], 15, 'the 5 sold before are not sold again')
	t.eq(sent[#sent][5], true, 'provisional: the mail books the sale')
	books:OnSaleMail({ itemId = 5, qty = 20, bid = 2000, deposit = 60, cut = 100 })
	t.eq(sent[#sent - 1][1], 'AUCTION_SOLD')
	t.eq(sent[#sent - 1][5], nil, 'the mail books it for good')
end)

t.test('a sale mail with no tracked auction is still booked', function()
	local books, market = newBooks()
	t.eq(books:OnSaleMail({ itemId = 5, qty = 1, bid = 100, deposit = 0, cut = 5 }), nil)
	t.eq(kinds(market), 'sale,cut')
	t.eq(books:OnSaleMail({ itemId = 5, qty = 0, bid = 100 }), nil, 'junk is ignored')
	t.eq(kinds(market), 'sale,cut')
end)

t.test('a troll sale is flagged and left out of the realized price', function()
	local books, market = newBooks({ vendor = { [5] = 100 } })
	books:OnSaleMail({ itemId = 5, qty = 2, bid = 210, deposit = 0, cut = 10 })
	books:OnSaleMail({ itemId = 5, qty = 1, bid = 400, deposit = 0, cut = 20 })
	local sales = Ledger.sellLog(market)
	t.eq(sales[1].isTroll, nil)
	t.eq(sales[2].isTroll, true)
	t.eq(Ledger.realizedIndex(market, 0)[5].copper, 400)
end)

t.group('books: cost pools')

t.test('posted units take their pool share; an expired auction brings it back', function()
	local books, market, clock, held = newBooks({ held = { [5] = 10 } })
	CostPool.add(market, 5, 10, 1000)
	post(books, 5, 4, 300, 10, 12)
	held[5] = 6
	books:OnAuctionCreated(1)
	t.same(CostPool.get(market, 5), { units = 6, copper = 600 })
	t.eq(market.auctions[1].knownCopper, 400)
	clock.now = START + 12 * 3600
	books:OnReturnMail({ kind = 'expired', itemId = 5, qty = 3 })
	t.same(CostPool.get(market, 5), { units = 9, copper = 900 })
	books:OnReturnMail({ kind = 'expired', itemId = 5, qty = 1 })
	t.same(CostPool.get(market, 5), { units = 10, copper = 1000 })
end)

t.test('won mails add to the pool once each; purchases only tag them', function()
	local books, market = newBooks()
	books:OnPurchase({ itemId = 5, qty = 10 })
	t.eq(CostPool.get(market, 5), nil, 'a purchase call books nothing')
	books:OnWonMail({ itemId = 5, qty = 4, bid = 400 })
	books:OnWonMail({ itemId = 5, qty = 6, bid = 900 })
	t.same(CostPool.get(market, 5), { units = 10, copper = 1300 })
	t.eq(#books.pendingBuys, 0)
	t.eq(Ledger.profit(market).spent, 1300)
end)

t.test('an outbid mail drops its bid; a pending buy no mail came for expires', function()
	local books, _, clock = newBooks()
	books:OnPurchase({ itemId = 5, qty = 1, isBid = true })
	books:OnPurchase({ itemId = 5, qty = 2 })
	books:OnOutbidMail({ itemId = 5 })
	t.eq(#books.pendingBuys, 1, 'the bid is gone')
	t.eq(books.pendingBuys[1].qty, 2, 'a buyout cannot be outbid')
	books:OnOutbidMail({ itemId = 5 })
	t.eq(#books.pendingBuys, 1)
	clock.now = START + ns.Books.PENDING_BUY_SECONDS + 1
	books:OnPurchase({ itemId = 6, qty = 1 })
	t.eq(#books.pendingBuys, 1, 'the old buy expired')
	t.eq(books.pendingBuys[1].itemId, 6)
end)

t.test('vendor buys go in; vendor sells and destroys take out by held share', function()
	local books, market = newBooks({ held = { [5] = 4 } })
	books:OnVendorBuy({ itemId = 5, qty = 2, copper = 50 })
	books:OnVendorSell({ itemId = 5, qty = 2, copper = 10, held = 4 })
	t.same(CostPool.get(market, 5), { units = 1, copper = 25 })
	books:OnDestroy({ itemId = 5, qty = 1, held = 1 })
	t.eq(CostPool.get(market, 5), nil)
	local destroy = Ledger.events(market, { kind = 'destroy' })[1]
	t.eq(destroy.copper, 25, 'the known cost lost')
	t.eq(Ledger.profit(market).net, 10 - 50)
end)

t.group('ledger: summaries and profit')

t.test('optional tuple positions are left off when empty', function()
	local market = { ledger = {} }
	Ledger.append(market, { t = 1, kind = 'sale', itemId = 2, qty = 1, copper = 5, char = 'A', auctionId = 9 })
	Ledger.append(market, { t = 1, kind = 'sale', itemId = 2, qty = 1, copper = 5, char = 'A', isTroll = true })
	t.same(market.ledger[1], { 1, 'sale', 2, 1, 5, 'A', 0, 9 })
	t.same(market.ledger[2], { 1, 'sale', 2, 1, 5, 'A', 0, 0, 1 })
	t.raises(function()
		Ledger.append(market, { t = 1, kind = 'sale', copper = 5, char = 'A', ventureId = 0 })
	end, 'ventureId')
end)

t.test('old events fold into day summaries; profit and daily read both', function()
	local market = { ledger = {} }
	local day = 86400
	Ledger.append(market, { t = 1 * day + 5, kind = 'sale', itemId = 2, qty = 1, copper = 500, char = 'A' })
	Ledger.append(market, { t = 1 * day + 9, kind = 'cut', itemId = 2, qty = 1, copper = 25, char = 'A' })
	Ledger.append(market, { t = 1 * day + 9, kind = 'tradeOut', itemId = 2, qty = 1, copper = 999, char = 'A' })
	Ledger.append(market, { t = 200 * day, kind = 'buy', itemId = 3, qty = 2, copper = 100, char = 'A' })
	t.eq(Ledger.compact(market, 200 * day), 3)
	t.eq(#market.ledger, 1)
	t.same(market.ledgerDays[1].sale, { 1, 1, 500 })
	t.same(market.ledgerDays[1].tradeOutItems, { 1, 1, 999 })
	local profit = Ledger.profit(market)
	t.eq(profit.income, 500)
	t.eq(profit.spent, 125, 'traded items are not gold')
	t.eq(Ledger.profit(market, 2 * day).net, -100)
	local rows = Ledger.daily(market, 0, 200 * day)
	t.eq(#rows, 2)
	t.eq(rows[1].net, 475)
	t.eq(rows[2].day, 200)
	t.eq(Ledger.compact(market, 200 * day), 0, 'compacting twice folds nothing new')
end)

t.test('net since a start older than the ledger keeps counts the folded days', function()
	local market = { ledger = {} }
	local day = 86400
	Ledger.append(market, { t = 1 * day + 5, kind = 'sale', itemId = 2, qty = 1, copper = 500, char = 'A' })
	Ledger.append(market, { t = 1 * day + 9, kind = 'cut', itemId = 2, qty = 1, copper = 25, char = 'A' })
	Ledger.append(market, { t = 200 * day, kind = 'buy', itemId = 3, qty = 2, copper = 100, char = 'A' })
	Ledger.compact(market, 200 * day)
	t.eq(Ledger.netSince(market, 1 * day, 'A'), 375)
	t.eq(Ledger.netSince(market, 1 * day), Ledger.profit(market, 1 * day).net)
	t.eq(Ledger.netSince(market, 2 * day, 'A'), -100, 'a folded day before the start is left out')
end)

t.test('the daily view reads the ledger once, however many days it shows', function()
	local market = { ledger = {} }
	local day = 86400
	for index = 1, 30 do
		Ledger.append(market, { t = index * day + 5, kind = 'sale', itemId = 2, qty = 1, copper = index, char = 'A' })
	end
	local events, reads = Ledger.events, 0
	Ledger.events = function(...)
		reads = reads + 1
		return events(...)
	end
	local rows = Ledger.daily(market, 1 * day, 30 * day)
	Ledger.events = events
	t.eq(reads, 1)
	t.eq(#rows, 30)
	t.eq(rows[30].income, 30)
	t.eq(#Ledger.daily(market, 5 * day, 6 * day + 10), 2, 'the edges are inside')
end)

t.test('the purchase log is newest first, buys and vendor buys, with a limit', function()
	local market = { ledger = {} }
	for index = 1, 5 do
		local kind = index % 2 == 0 and 'vendorBuy' or 'buy'
		Ledger.append(market, { t = index, kind = kind, itemId = index, qty = 1, copper = 10, char = 'A' })
		Ledger.append(market, { t = index, kind = 'sale', itemId = index, qty = 1, copper = 10, char = 'A' })
	end
	local log = Ledger.purchaseLog(market, 3)
	t.eq(#log, 3)
	t.eq(log[1].itemId, 5)
	t.eq(log[2].kind, 'vendorBuy')
	t.eq(#Ledger.purchaseLog(market), 5)
end)

t.test('the sell log is newest first with unit prices and a limit', function()
	local market = { ledger = {} }
	for index = 1, 3 do
		Ledger.append(market, { t = index, kind = 'sale', itemId = index, qty = 2, copper = 100 * index, char = 'A' })
	end
	local log = Ledger.sellLog(market, { limit = 2 })
	t.eq(#log, 2)
	t.eq(log[1].itemId, 3)
	t.eq(log[1].unitPrice, 150)
	t.eq(#Ledger.sellLog(market, { itemId = 1 }), 1)
end)
