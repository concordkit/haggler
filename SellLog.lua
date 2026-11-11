--[[
	SellLog: the pure half of the sell-time log. No game API is touched here, so the test script
	runs it under plain LuaJIT.

	A post is logged with the estimated time until sold at that moment. Auction mail then fills it
	in: each sale adds its units, and the post is sold out when they reach the quantity posted.
	An expiry or a cancellation closes it unsold. The summary compares actual times with the
	estimates.

	Post: { t, id, name, q, unit, hours, est, ahead, isAheadKnown, sold, lastSale, status, actual }
	status: "open" | "sold" | "expired" | "cancelled"
]]
local _, ns = ...
ns = ns or {} -- tests load files without the addon table

local SellLog = {}
ns.SellLog = SellLog

-- Auction house mail stays 30 days, so its age is 30 days less the days it has left.
SellLog.MAIL_LIFETIME_DAYS = 30
-- One mail seen again (each inbox update lists it anew) lands within this of its first sighting.
SellLog.SAME_MAIL_WINDOW_S = 10 * 60
-- A "Sale Pending" mail and the "Auction successful" mail of the same sale.
SellLog.PENDING_TO_SOLD_WINDOW_S = 2 * 60 * 60
SellLog.KEEP_POSTS_S = 60 * 86400
SellLog.KEEP_MAIL_S = 3 * 86400

--- When a mail arrived, from the days it has left.
function SellLog.arrivalTime(now, daysLeft)
	if type(now) ~= "number" or type(daysLeft) ~= "number" then
		error("arrivalTime: now and daysLeft must be numbers")
	end
	local ageDays = math.max(0, SellLog.MAIL_LIFETIME_DAYS - daysLeft)
	return now - ageDays * 86400
end

--- A new open post.
--- @param estimate table|nil { seconds, ahead, isAheadKnown } at posting time
function SellLog.newPost(t, itemID, name, qty, unit, hours, estimate)
	if type(t) ~= "number" or type(name) ~= "string" or type(qty) ~= "number" or qty <= 0 or type(unit) ~= "number" then
		error("newPost: t, name, a positive qty and unit are required")
	end
	estimate = estimate or {}
	return {
		t = t,
		id = itemID,
		name = name,
		q = qty,
		unit = unit,
		hours = hours,
		est = estimate.seconds,
		ahead = estimate.ahead,
		isAheadKnown = estimate.isAheadKnown and true or false,
		sold = 0,
		status = "open",
	}
end

-- Subject templates the auction house writes; "%s" and what follows it is the item's name.
SellLog.SUBJECTS = {
	{ "sold", "AUCTION_SOLD_MAIL_SUBJECT", "Auction successful: %s" },
	{ "pending", "AUCTION_INVOICE_MAIL_SUBJECT", "Sale Pending: %s" },
	{ "expired", "AUCTION_EXPIRED_MAIL_SUBJECT", "Auction expired: %s" },
	{ "cancelled", "AUCTION_REMOVED_MAIL_SUBJECT", "Auction cancelled: %s" },
}

--- Subject patterns from the client's own strings (so other languages work), English otherwise.
--- @param strings table|nil global name -> template, e.g. _G
--- @return table { { kind, pattern } } a pattern captures the item's name
function SellLog.subjectPatterns(strings)
	local out = {}
	for _, subject in ipairs(SellLog.SUBJECTS) do
		local template = strings and type(strings[subject[2]]) == "string" and strings[subject[2]] or subject[3]
		local prefix = template:gsub("%%s.*$", ""):gsub("%p", "%%%0")
		out[#out + 1] = { kind = subject[1], pattern = "^" .. prefix .. "(.+)$" }
	end
	return out
end

--- The kind of auction mail a subject is and the item's name, or nil for any other mail.
function SellLog.parseSubject(patterns, subject)
	if type(subject) ~= "string" then
		return nil
	end
	for _, p in ipairs(patterns) do
		local name = subject:match(p.pattern)
		if name then
			return p.kind, name
		end
	end
	return nil
end

local function isSaleKind(kind)
	return kind == "sold" or kind == "pending"
end

--- True when this mail was already counted, else records it as counted.
--- Each inbox update lists every mail again, so a sighting matches a recorded mail of the same
--- kind at about the same arrival time; two such mails in one inbox are two mails, so a record
--- matches once per pass. A "Sale Pending" mail and the later "Auction successful" mail of one
--- sale pair up once.
--- @param seen table recorded mails, changed in place
--- @param pass table records matched during this inbox pass, changed in place
function SellLog.isSeenElseMark(seen, pass, kind, name, money, at)
	for _, mail in ipairs(seen) do
		if not pass[mail] and mail.kind == kind and mail.name == name and mail.money == money then
			if math.abs(mail.at - at) <= SellLog.SAME_MAIL_WINDOW_S then
				pass[mail] = true
				return true
			end
		end
	end
	for _, mail in ipairs(seen) do
		local isOtherHalf = isSaleKind(kind) and isSaleKind(mail.kind) and mail.kind ~= kind
		if isOtherHalf and not mail.isPaired and mail.name == name and mail.money == money then
			local pendingAt, soldAt = mail.at, at
			if kind == "pending" then
				pendingAt, soldAt = at, mail.at
			end
			local gap = soldAt - pendingAt
			if gap >= -SellLog.SAME_MAIL_WINDOW_S and gap <= SellLog.PENDING_TO_SOLD_WINDOW_S then
				mail.isPaired = true
				local record = { kind = kind, name = name, money = money, at = at, isPaired = true }
				seen[#seen + 1] = record
				pass[record] = true
				return true
			end
		end
	end
	local record = { kind = kind, name = name, money = money, at = at }
	seen[#seen + 1] = record
	pass[record] = true
	return false
end

local function openPostsFor(posts, name, at)
	local out = {}
	for _, post in ipairs(posts) do
		if post.status == "open" and post.name == name and post.t <= at then
			out[#out + 1] = post
		end
	end
	return out
end

-- The post a sale belongs to: the oldest whose unit price explains the money exactly, else the
-- oldest open one of that item.
local function postForSale(candidates, money, count)
	for _, post in ipairs(candidates) do
		local remaining = post.q - post.sold
		local units = count or (post.unit > 0 and money / post.unit)
		local isWhole = units and units == math.floor(units)
		if isWhole and units > 0 and units <= remaining and math.abs(post.unit * units - money) < 1 then
			return post, units
		end
	end
	local oldest = candidates[1]
	if not oldest then
		return nil
	end
	return oldest, count or math.max(1, math.floor(money / math.max(1, oldest.unit) + 0.5))
end

--- Adds a sale to its post; the post is sold out once its units are all sold.
--- @return table|nil the post, nil when no open post of that item matches
function SellLog.applySale(posts, name, money, count, at)
	local post, units = postForSale(openPostsFor(posts, name, at), money, count)
	if not post then
		return nil
	end
	post.sold = math.min(post.q, post.sold + units)
	post.lastSale = math.max(post.lastSale or at, at)
	if post.sold >= post.q then
		post.status = "sold"
		post.actual = post.lastSale - post.t
	end
	return post
end

--- Closes the open post of an item that came back expired or cancelled: the oldest with the
--- returned count still unsold, else the oldest.
--- @param kind string "expired" | "cancelled"
--- @param count number|nil units returned
--- @return table|nil the post
function SellLog.applyReturn(posts, name, kind, count, at)
	local candidates = openPostsFor(posts, name, at)
	local post = candidates[1]
	for _, candidate in ipairs(candidates) do
		if count and candidate.q - candidate.sold == count then
			post = candidate
			break
		end
	end
	if post then
		post.status = kind
	end
	return post
end

--- Unsold units of the player's own open posts of an item at or below a unit price; the live
--- listings leave the player's units out, so these are added back as ahead in the queue.
function SellLog.ownUnitsAhead(posts, itemID, unit)
	local units = 0
	for _, post in ipairs(posts) do
		if post.status == "open" and post.id == itemID and post.unit <= unit then
			units = units + post.q - post.sold
		end
	end
	return units
end

--- The estimate logged with a post: the time to sell everything cheaper plus the post itself.
--- @param levels table|nil price levels without the player's own units
--- @return table|nil { seconds, ahead, isAheadKnown }, nil without a sales pace
function SellLog.estimate(levels, unit, qty, soldPerDay, ownAhead)
	local Pricing = ns.Pricing
	local isAheadKnown = type(levels) == "table" and #levels > 0
	local ahead = (isAheadKnown and Pricing.unitsBelow(levels, unit) or 0) + (ownAhead or 0)
	local seconds = Pricing.secondsToSellOut(ahead + qty, soldPerDay)
	if not seconds then
		return nil
	end
	return { seconds = seconds, ahead = ahead, isAheadKnown = isAheadKnown }
end

local function median(values)
	if #values == 0 then
		return nil
	end
	table.sort(values)
	local mid = math.floor(#values / 2)
	if #values % 2 == 1 then
		return values[mid + 1]
	end
	return (values[mid] + values[mid + 1]) / 2
end

--- How the estimates did over posts made since `since`.
--- @return table { soldOut, returned, partly, open, withEstimate, withinEstimate, medianRatio }
---   withEstimate: closed posts that had an estimate; withinEstimate: of those, sold out in time.
---   medianRatio: actual over estimated time for sold-out posts, nil with none.
function SellLog.summarize(posts, since)
	local s = { soldOut = 0, returned = 0, partly = 0, open = 0, withEstimate = 0, withinEstimate = 0 }
	local ratios = {}
	for _, post in ipairs(posts or {}) do
		if post.t >= (since or 0) then
			local hasEstimate = type(post.est) == "number" and post.est > 0
			if post.status == "open" then
				s.open = s.open + 1
			elseif post.status == "sold" then
				s.soldOut = s.soldOut + 1
				if hasEstimate then
					ratios[#ratios + 1] = post.actual / post.est
					s.withinEstimate = s.withinEstimate + (post.actual <= post.est and 1 or 0)
				end
			else
				s.returned = s.returned + 1
				s.partly = s.partly + (post.sold > 0 and 1 or 0)
			end
			if hasEstimate and post.status ~= "open" then
				s.withEstimate = s.withEstimate + 1
			end
		end
	end
	s.medianRatio = median(ratios)
	return s
end

--- One chat line for a summary over `days` days.
function SellLog.summaryText(s, days)
	local head = string.format("sell log, last %d days: ", days)
	if s.soldOut + s.returned == 0 then
		return head .. string.format("nothing closed yet, %d open", s.open)
	end
	local parts = { string.format("%d sold out", s.soldOut) }
	if s.medianRatio then
		parts[#parts + 1] = string.format(
			"typically %.1fx the estimate, %d of %d closed with an estimate sold within it",
			s.medianRatio,
			s.withinEstimate,
			s.withEstimate
		)
	end
	if s.returned > 0 then
		parts[#parts + 1] = string.format("%d came back (%d partly sold)", s.returned, s.partly)
	end
	parts[#parts + 1] = string.format("%d open", s.open)
	return head .. table.concat(parts, ", ")
end

--- Drops posts and mail sightings past keeping, in place.
function SellLog.trim(log, now)
	local function keep(list, field, maxAge)
		for i = #list, 1, -1 do
			if now - (list[i][field] or 0) > maxAge then
				table.remove(list, i)
			end
		end
	end
	keep(log.posts, "t", SellLog.KEEP_POSTS_S)
	keep(log.seen, "at", SellLog.KEEP_MAIL_S)
end

return ns
