--[[
	MailMatcher: reads auction house mail and finds what it settles. Pure: Books applies the
	results to the ledger, the auctions, the cost pools and the ventures.

	Auction mail is told apart by its subject, built from the client's own format strings
	(AUCTION_SOLD_MAIL_SUBJECT "Auction successful: %s" and its siblings), so every locale works;
	the English forms are the fallback. The invoice (GetInboxInvoiceInfo) carries the figures as
	the server booked them: the buyer's bid, the deposit returned and the cut taken on a sale,
	the price paid on a win.

	  MailMatcher.prefixes(global)            -> { [kind] = subject prefix }  global = fun(name)
	  MailMatcher.classify(subject, prefixes) -> kind, itemName | nil
	      kind: sold · pending · expired · cancelled · won · outbid
	  MailMatcher.findSale(market, sale, char)      -> auctionId | nil   sale = { itemId, qty?, bid }
	  MailMatcher.findReturn(market, back, char, now) -> auctionId | nil  back = { kind, itemId }
	  MailMatcher.takeBuy(pendingBuys, itemId, qty) -> ventureId | nil   consumes pending buys
	  MailMatcher.isTroll(unitPrice, vendorPrice)   -> boolean  the spec's troll-buy test
]]
local _, ns = ...

local MailMatcher = {}
ns.MailMatcher = MailMatcher

MailMatcher.SUBJECTS = {
	sold = { global = 'AUCTION_SOLD_MAIL_SUBJECT', fallback = 'Auction successful: %s' },
	pending = { global = 'AUCTION_INVOICE_MAIL_SUBJECT', fallback = 'Sale Pending: %s' },
	expired = { global = 'AUCTION_EXPIRED_MAIL_SUBJECT', fallback = 'Auction expired: %s' },
	cancelled = { global = 'AUCTION_REMOVED_MAIL_SUBJECT', fallback = 'Auction cancelled: %s' },
	won = { global = 'AUCTION_WON_MAIL_SUBJECT', fallback = 'Auction won: %s' },
	outbid = { global = 'AUCTION_OUTBID_MAIL_SUBJECT', fallback = 'Outbid on %s' },
}

-- A sale prefers an auction at its unit price, then one already read as sold, then any live one.
local SALE_STATE_SCORE = { sold = 2, active = 1, expired = 0, cancelled = 0 }
local SECONDS_PER_HOUR = 3600
local PRICE_MATCH_SCORE = 4

-- Helpers live at the bottom of the file; declared here so they stay local.
local prefixOf, bestRecord, isPriceMatch, isWhole, isDue

--- The subject prefix of each auction mail kind, from the client's format strings.
--- @param global function|nil fun(name) -> value
--- @return table { [kind] = prefix }
function MailMatcher.prefixes(global)
	local prefixes = {}
	for kind, subject in pairs(MailMatcher.SUBJECTS) do
		local format = type(global) == 'function' and global(subject.global) or nil
		prefixes[kind] = prefixOf(type(format) == 'string' and format or subject.fallback) or prefixOf(subject.fallback)
	end
	return prefixes
end

--- The kind of an auction mail and the item name in its subject, or nil for other mail.
function MailMatcher.classify(subject, prefixes)
	if type(subject) ~= 'string' or type(prefixes) ~= 'table' then
		return nil
	end
	for kind, prefix in pairs(prefixes) do
		if prefix ~= '' and subject:sub(1, #prefix) == prefix then
			return kind, subject:sub(#prefix + 1)
		end
	end
	return nil
end

--- The tracked auction a sale invoice settles: same character and item, units left to settle,
--- any state (a commodity can sell part by part before a cancel); the unit price, then the
--- state, then the oldest post decide. Without a qty (an invoice with no count) the unit price
--- matches when the bid is a whole number of units at it.
--- @return number|nil auctionId
function MailMatcher.findSale(market, sale, char)
	if type(sale) ~= 'table' or (sale.qty ~= nil and not (isWhole(sale.qty) and sale.qty > 0)) then
		return nil
	end
	local bid = isWhole(sale.bid) and sale.bid or nil
	return bestRecord(market, sale.itemId, char, function(record)
		local stateScore = SALE_STATE_SCORE[record.state]
		if not stateScore then
			return nil
		end
		return stateScore + (isPriceMatch(record.unitPrice, bid, sale.qty) and PRICE_MATCH_SCORE or 0)
	end)
end

--- The tracked auction an expired or cancelled mail returns units of: the same state first,
--- then any auction still waiting on mail, oldest first. A live auction comes back only once its
--- time ran out: units back early belong to a cancel, never to a listing still up.
--- @param now number unix seconds
--- @return number|nil auctionId
function MailMatcher.findReturn(market, back, char, now)
	if type(back) ~= 'table' then
		return nil
	end
	return bestRecord(market, back.itemId, char, function(record)
		if record.state == 'active' and not (type(now) == 'number' and isDue(record, now)) then
			return nil
		end
		return record.state == back.kind and 2 or 1
	end)
end

--- Takes qty units of an item off the pending buys (oldest first) and answers the venture the
--- first of them was bought for. A won mail can cover part of a buy or several buys.
--- @param pendingBuys table { { itemId, qty, ventureId? } } (changed in place)
--- @return number|nil ventureId
function MailMatcher.takeBuy(pendingBuys, itemId, qty)
	if type(pendingBuys) ~= 'table' or not isWhole(qty) then
		return nil
	end
	local ventureId, left = nil, qty
	local index = 1
	while index <= #pendingBuys and left > 0 do
		local buy = pendingBuys[index]
		if buy.itemId == itemId then
			ventureId = ventureId or buy.ventureId
			local taken = math.min(left, buy.qty)
			buy.qty, left = buy.qty - taken, left - taken
		end
		if buy.qty <= 0 then
			table.remove(pendingBuys, index)
		else
			index = index + 1
		end
	end
	return ventureId
end

--- A sale at which the seller nets no more than vendoring would: P × 0.95 ≤ vendor price.
function MailMatcher.isTroll(unitPrice, vendorPrice)
	return ns.Sales.isTrollPrice(unitPrice, vendorPrice or 0)
end

-- Helpers ---------------------------------------------------------------------------------

-- "Auction successful: %s" -> "Auction successful: "; nil when the format has no %s.
function prefixOf(format)
	local at = format:find('%s', 1, true)
	return at and format:sub(1, at - 1) or nil
end

function bestRecord(market, itemId, char, score)
	local auctions = type(market) == 'table' and type(market.auctions) == 'table' and market.auctions or {}
	local bestId, bestScore, bestPostedAt
	for auctionId, record in pairs(auctions) do
		local isCandidate = type(record) == 'table'
			and record.itemId == itemId
			and record.char == char
			and isWhole(record.remaining)
			and record.remaining > 0
		local points = isCandidate and score(record) or nil
		local postedAt = isCandidate and record.postedAt or 0
		local isBetter = points
			and (
				not bestScore
				or points > bestScore
				or (
					points == bestScore
					and (postedAt < bestPostedAt or (postedAt == bestPostedAt and auctionId < bestId))
				)
			)
		if isBetter then
			bestId, bestScore, bestPostedAt = auctionId, points, postedAt
		end
	end
	return bestId
end

function isPriceMatch(unitPrice, bid, qty)
	if not bid or not isWhole(unitPrice) then
		return false
	end
	if qty then
		return unitPrice == math.floor(bid / qty)
	end
	return unitPrice > 0 and bid > 0 and bid % unitPrice == 0
end

function isDue(record, now)
	return type(record.postedAt) == 'number'
		and type(record.hours) == 'number'
		and now >= record.postedAt + record.hours * SECONDS_PER_HOUR
end

function isWhole(value)
	return type(value) == 'number' and value >= 0 and value < math.huge and value % 1 == 0
end

return MailMatcher
