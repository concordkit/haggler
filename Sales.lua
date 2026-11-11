--[[
	Sales: the game half of the sell-time log. Logs every post with its estimated time until sold,
	then reads auction mail in the inbox to fill in when it actually sold. Nothing in the mailbox
	is opened or taken.
]]
local _, ns = ...
ns = ns or {} -- tests load files without the addon table
local SellLog = ns.SellLog

local Sales = {}
ns.Sales = Sales

local HOURS = { [1] = 12, [2] = 24, [3] = 48 }
local SUMMARY_DAYS = 30

local isPostHooked = false
local patterns = nil

local function log()
	HagglerDB = type(HagglerDB) == "table" and HagglerDB or {}
	local sellLog = HagglerDB.sellLog
	if type(sellLog) ~= "table" or type(sellLog.posts) ~= "table" or type(sellLog.seen) ~= "table" then
		sellLog = { posts = {}, seen = {} }
		HagglerDB.sellLog = sellLog
	end
	return sellLog
end

local function recordPost(itemID, name, qty, unit, hours)
	if not itemID or not name or not qty or qty <= 0 or not unit or unit <= 0 then
		return
	end
	local posts = log().posts
	local result = ns.Scan.lookup(itemID)
	local estimate =
		SellLog.estimate(result and result.levels, unit, qty, result and result.soldPerDay, SellLog.ownUnitsAhead(posts, itemID, unit))
	posts[#posts + 1] = SellLog.newPost(ns.now(), itemID, name, qty, unit, hours, estimate)
end

local function nameAt(location)
	local ok, name = pcall(C_Item.GetItemName, location)
	return ok and name or nil
end

local function onModernPost(location, duration, quantity, unitPrice)
	local itemID = C_Item.GetItemID(location)
	recordPost(itemID, nameAt(location), quantity or 1, unitPrice, HOURS[duration] or duration)
end

--- Hooks the auction house post calls the client has, as AHledger does.
function Sales.hook()
	if isPostHooked then
		return
	end
	isPostHooked = true
	if C_AuctionHouse and C_AuctionHouse.PostItem then
		hooksecurefunc(C_AuctionHouse, "PostItem", function(location, duration, quantity, _, buyout)
			local qty = quantity or 1
			pcall(onModernPost, location, duration, qty, buyout and buyout / qty)
		end)
	end
	if C_AuctionHouse and C_AuctionHouse.PostCommodity then
		hooksecurefunc(C_AuctionHouse, "PostCommodity", function(location, duration, quantity, unitPrice)
			pcall(onModernPost, location, duration, quantity, unitPrice)
		end)
	end
	if PostAuction and GetAuctionSellItemInfo then
		hooksecurefunc("PostAuction", function(minBid, buyoutPrice, runTime, stackSize, numStacks)
			pcall(function()
				local name, _, count, _, _, _, _, _, _, itemID = GetAuctionSellItemInfo()
				local size = stackSize or count or 1
				local price = (buyoutPrice and buyoutPrice > 0) and buyoutPrice or minBid
				for _ = 1, numStacks or 1 do
					recordPost(itemID, name, size, price and price / size, HOURS[runTime] or runTime)
				end
			end)
		end)
	end
end

-- Gross sale price and units from the invoice; without one, the payment grossed up by the cut.
local function saleOf(index, money)
	local ok, _, _, _, _, buyout, _, _, _, _, _, count = pcall(GetInboxInvoiceInfo, index)
	if ok and buyout and buyout > 0 then
		return buyout, count
	end
	return math.floor((money or 0) / (1 - ns.Pricing.AH_CUT) + 0.5), nil
end

local function returnedCount(index)
	local ok, _, _, _, count = pcall(GetInboxItem, index, 1)
	return ok and count or nil
end

local function readMail(sellLog, pass, index, now)
	local _, _, _, subject, money, _, daysLeft = GetInboxHeaderInfo(index)
	local kind, name = SellLog.parseSubject(patterns, subject)
	if not kind or type(daysLeft) ~= "number" then
		return
	end
	local at = SellLog.arrivalTime(now, daysLeft)
	if kind == "sold" or kind == "pending" then
		local gross, count = saleOf(index, money)
		if not SellLog.isSeenElseMark(sellLog.seen, pass, kind, name, gross, at) then
			SellLog.applySale(sellLog.posts, name, gross, count, at)
		end
	else
		local count = returnedCount(index)
		if not SellLog.isSeenElseMark(sellLog.seen, pass, kind, name, count or 0, at) then
			SellLog.applyReturn(sellLog.posts, name, kind, count, at)
		end
	end
end

--- Reads the inbox, oldest mail first, so a sale's pending mail comes before its payment.
function Sales.readInbox()
	if not GetInboxNumItems or not GetInboxHeaderInfo then
		return
	end
	patterns = patterns or SellLog.subjectPatterns(_G)
	local sellLog, pass, now = log(), {}, ns.now()
	for index = GetInboxNumItems() or 0, 1, -1 do
		readMail(sellLog, pass, index, now)
	end
end

function Sales.trim()
	SellLog.trim(log(), ns.now())
end

--- The /ahlm line.
function Sales.summaryText()
	local since = ns.now() - SUMMARY_DAYS * 86400
	return SellLog.summaryText(SellLog.summarize(log().posts, since), SUMMARY_DAYS)
end
