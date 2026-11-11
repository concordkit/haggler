--[[
	AuctionTracker: the player's own auctions, from the post to the mail that settles them
	(markets[marketKey].auctions[auctionId] = Tracked).

	  Tracked = { itemId, qty, remaining, listed, unitPrice, deposit, isDepositEstimated, postedAt, hours,
	              state, changedAt, char, ventureId?, knownUnits, knownCopper }

	remaining counts units the mail has not settled yet, listed the units still on the auction
	house (a commodity sells part by part). state is active, sold, expired or cancelled. sold, expired and cancelled read from the owned
	list or the clock are provisional: the mail settles them (MailMatcher), and a record leaves once
	every unit is settled, or PRUNE_DAYS after its last change (the mail is gone by then).
	knownUnits / knownCopper are the cost-pool share the posted units took with them; a returned
	unit brings its share back.

	Posting is two steps in the client: the PostItem / PostCommodity call (hooked, a pending post)
	and AUCTION_HOUSE_AUCTION_CREATED with the new auction id. Pending posts are matched oldest
	first; a Confirm* call replaces the pending post it confirms rather than adding one. A post
	the client held for a confirm (noteWarning) that was declined never creates an auction: the
	next plain post drops it. Two posts from the same slot are both kept: a post that took part
	of a stack leaves the rest to post again. A post error drops the newest post.

	  AuctionTracker.notePost(pending, post, now)      post = { itemId, qty, unitPrice, hours,
	                                                     deposit?, isDepositEstimated?, char,
	                                                     ventureId?, held, isConfirm? }
	                                                     slot? = 'bag:slot'
	  AuctionTracker.noteWarning(pending)               the newest post waits for a confirm
	  AuctionTracker.noteError(pending)                 the newest post failed
	  AuctionTracker.created(market, pending, auctionId, now) -> Tracked, post | nil
	  AuctionTracker.noteCancel(market, auctionId, now) -> Tracked | nil
	  AuctionTracker.reconcile(market, owned, char, now) -> Change[]  owned = { { auctionId, qty,
	                                                     isSold } }  (one character's full list)
	  AuctionTracker.expireDue(market, now)             -> Change[]
	  AuctionTracker.settle(market, auctionId, qty, now) -> settled units
	  AuctionTracker.prune(market, now)                 -> count removed
	  AuctionTracker.list(market, filter?)              -> { Tracked + auctionId } newest first

	  Change = { auctionId, from, to, soldQty? }
]]
local _, ns = ...

local AuctionTracker = {}
ns.AuctionTracker = AuctionTracker

AuctionTracker.PENDING_SECONDS = 60
AuctionTracker.PRUNE_DAYS = 31
AuctionTracker.STATES = { active = true, sold = true, expired = true, cancelled = true }

local SECONDS_PER_HOUR, SECONDS_PER_DAY = 3600, 86400

-- Helpers live at the bottom of the file; declared here so they stay local.
local isWhole, auctionsOf, isSamePost, dropStalePending, readRecord, changeState

--- Remembers a post call until its auction is created.
--- @param pending table the runtime list of pending posts (changed in place)
--- @param post table see the file header
--- @param now number unix seconds
function AuctionTracker.notePost(pending, post, now)
	if type(pending) ~= 'table' or type(post) ~= 'table' then
		error('AuctionTracker.notePost: needs a pending list and a post', 2)
	end
	if not (isWhole(post.itemId) and post.itemId > 0 and isWhole(post.qty) and post.qty > 0) then
		error('AuctionTracker.notePost: needs an itemId and a quantity', 2)
	end
	dropStalePending(pending, now)
	local entry = {}
	for key, value in pairs(post) do
		entry[key] = value
	end
	entry.t = now
	if post.isConfirm then
		for index, other in ipairs(pending) do
			if isSamePost(other, entry) then
				pending[index] = entry
				return
			end
		end
	else
		for index = #pending, 1, -1 do
			local other = pending[index]
			if other.needsConfirm then
				table.remove(pending, index)
			end
		end
	end
	pending[#pending + 1] = entry
end

--- The client held the newest post for a confirm (a price warning).
function AuctionTracker.noteWarning(pending)
	local newest = type(pending) == 'table' and pending[#pending]
	if newest then
		newest.needsConfirm = true
	end
end

--- The newest post failed: no auction will come of it.
function AuctionTracker.noteError(pending)
	if type(pending) == 'table' then
		table.remove(pending)
	end
end

--- The auction a post created: takes the oldest pending post and starts tracking it.
--- @return table|nil Tracked, nil when no post was pending (posted by another add-on's path)
--- @return table|nil the pending post it came from
function AuctionTracker.created(market, pending, auctionId, now)
	local auctions = auctionsOf(market)
	if not auctions or not isWhole(auctionId) or auctionId == 0 then
		return nil
	end
	dropStalePending(pending, now)
	local post = table.remove(pending, 1)
	if not post then
		return nil
	end
	local record = {
		itemId = post.itemId,
		qty = post.qty,
		remaining = post.qty,
		listed = post.qty,
		unitPrice = isWhole(post.unitPrice) and post.unitPrice or 0,
		deposit = isWhole(post.deposit) and post.deposit or 0,
		isDepositEstimated = post.isDepositEstimated or nil,
		postedAt = now,
		hours = isWhole(post.hours) and post.hours or 48,
		state = 'active',
		changedAt = now,
		char = post.char,
		ventureId = post.ventureId,
		knownUnits = 0,
		knownCopper = 0,
	}
	auctions[auctionId] = record
	return record, post
end

--- The player cancelled an auction: its deposit is lost, its units come back by mail.
--- @return table|nil Tracked
function AuctionTracker.noteCancel(market, auctionId, now)
	local auctions = auctionsOf(market)
	local record = auctions and readRecord(auctions[auctionId])
	if not record or record.state ~= 'active' then
		return nil
	end
	changeState(record, 'cancelled', now)
	return record
end

--- Reads one character's full owned-auction list. A tracked auction the list marks sold, or
--- that left it before its time ran out, is sold; one that left after is expired. A commodity
--- whose quantity dropped sold that many units and stays active.
--- @param market table
--- @param owned table { { auctionId, qty, isSold } }
--- @param char string the character the list belongs to
--- @param now number
--- @return table Change[]
function AuctionTracker.reconcile(market, owned, char, now)
	local auctions = auctionsOf(market)
	if not auctions or type(owned) ~= 'table' then
		return {}
	end
	local byId = {}
	for _, entry in ipairs(owned) do
		if type(entry) == 'table' and isWhole(entry.auctionId) then
			byId[entry.auctionId] = entry
		end
	end
	local changes = {}
	for auctionId, raw in pairs(auctions) do
		local record = readRecord(raw)
		if record and record.char == char and record.state == 'active' then
			local entry = byId[auctionId]
			local listedQty = entry and isWhole(entry.qty) and entry.qty or nil
			local isDue = now >= record.postedAt + record.hours * SECONDS_PER_HOUR
			if entry and entry.isSold then
				-- Units an earlier list already read as sold are not sold again.
				changes[#changes + 1] =
					{ auctionId = auctionId, from = 'active', to = 'sold', soldQty = record.listed or record.remaining }
				changeState(record, 'sold', now)
			elseif entry and listedQty and listedQty < (record.listed or record.remaining) then
				local soldQty = (record.listed or record.remaining) - listedQty
				record.listed = listedQty
				changes[#changes + 1] = { auctionId = auctionId, from = 'active', to = 'active', soldQty = soldQty }
			elseif not entry then
				local to = isDue and 'expired' or 'sold'
				changes[#changes + 1] = { auctionId = auctionId, from = 'active', to = to }
				changeState(record, to, now)
			end
		end
	end
	return changes
end

--- Active auctions whose time ran out, marked expired (the owned list may never be read).
--- @return table Change[]
function AuctionTracker.expireDue(market, now)
	local changes = {}
	for auctionId, raw in pairs(auctionsOf(market) or {}) do
		local record = readRecord(raw)
		if record and record.state == 'active' and now >= record.postedAt + record.hours * SECONDS_PER_HOUR then
			changes[#changes + 1] = { auctionId = auctionId, from = 'active', to = 'expired' }
			changeState(record, 'expired', now)
		end
	end
	return changes
end

--- Mail settled qty units of an auction; the record leaves once none remain.
--- @return number units settled (never more than remained)
function AuctionTracker.settle(market, auctionId, qty, now)
	local auctions = auctionsOf(market)
	local record = auctions and readRecord(auctions[auctionId])
	if not record or not isWhole(qty) then
		return 0
	end
	local settled = math.min(qty, record.remaining)
	record.remaining = record.remaining - settled
	record.changedAt = now
	if record.remaining == 0 then
		auctions[auctionId] = nil
	end
	return settled
end

--- Drops records unchanged for PRUNE_DAYS and junk entries.
--- @return number count removed
function AuctionTracker.prune(market, now)
	local auctions = auctionsOf(market)
	local removed = 0
	for auctionId, raw in pairs(auctions or {}) do
		local record = readRecord(raw)
		if not record or now - record.changedAt > AuctionTracker.PRUNE_DAYS * SECONDS_PER_DAY then
			auctions[auctionId] = nil
			removed = removed + 1
		end
	end
	return removed
end

--- Tracked auctions, newest first.
--- @param market table|nil
--- @param filter table|nil { state?, char?, ventureId? }
--- @return table { Tracked + auctionId }
function AuctionTracker.list(market, filter)
	local list = {}
	for auctionId, raw in pairs(auctionsOf(market) or {}) do
		local record = readRecord(raw)
		local isWanted = record
			and (not filter or not filter.state or record.state == filter.state)
			and (not filter or not filter.char or record.char == filter.char)
			and (not filter or not filter.ventureId or record.ventureId == filter.ventureId)
		if isWanted then
			local copy = { auctionId = auctionId }
			for key, value in pairs(record) do
				copy[key] = value
			end
			list[#list + 1] = copy
		end
	end
	table.sort(list, function(a, b)
		if a.postedAt ~= b.postedAt then
			return a.postedAt > b.postedAt
		end
		return a.auctionId > b.auctionId
	end)
	return list
end

-- Helpers ---------------------------------------------------------------------------------

function isWhole(value)
	return type(value) == 'number' and value >= 0 and value < math.huge and value % 1 == 0
end

function auctionsOf(market)
	return type(market) == 'table' and type(market.auctions) == 'table' and market.auctions or nil
end

function isSamePost(a, b)
	return a.itemId == b.itemId and a.qty == b.qty and a.unitPrice == b.unitPrice and a.hours == b.hours
end

function dropStalePending(pending, now)
	for index = #pending, 1, -1 do
		if now - (pending[index].t or 0) > AuctionTracker.PENDING_SECONDS then
			table.remove(pending, index)
		end
	end
end

-- The saved record when it is well-formed, else nil (a hand edit, a future format).
function readRecord(record)
	local isValid = type(record) == 'table'
		and isWhole(record.itemId)
		and isWhole(record.remaining)
		and isWhole(record.postedAt)
		and isWhole(record.hours)
		and isWhole(record.changedAt)
		and AuctionTracker.STATES[record.state]
	return isValid and record or nil
end

function changeState(record, state, now)
	record.state = state
	record.changedAt = now
end

return AuctionTracker
