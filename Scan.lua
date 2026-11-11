--[[
	Scan: price levels for an item, from the freshest source there is.

	1. A live commodity search in the auction house, kept for LIVE_MAX_AGE.
	2. The newest full scan AHledger stored for this realm and faction (AHledgerDB.scans), read a
	   few thousand listings a frame so a house of 150,000 listings never stalls the client, and
	   used while it is younger than SCAN_MAX_AGE.
	Neither: no levels, and Pricing falls back to AHledger's lowest buyout and median.

	AHledgerDB.scans is AHledger's own saved data, not its public API. If its format changes, the
	scan simply yields no listings and every price falls back to the public API.
]]
local _, ns = ...
ns = ns or {} -- tests load files without the addon table
local Pricing = ns.Pricing

local Scan = {}
ns.Scan = Scan

local LISTINGS_PER_FRAME = 4000
local LIVE_MAX_AGE_S = 15 * 60
local SCAN_MAX_AGE_S = 6 * 60 * 60

local built = nil -- { ts, unitsByItem, levelsByItem }
local building = nil -- { scan, pos, unitsByItem } while a scan is read across frames
local liveByItem = {} -- [itemID] = { at, levels }

local function latestScan()
	local db = AHledgerDB
	if type(db) ~= "table" or type(db.scans) ~= "table" then
		return nil
	end
	local realm, faction = GetRealmName(), UnitFactionGroup("player")
	local best = nil
	for _, scan in ipairs(db.scans) do
		local isOurMarket = scan.realm == realm and scan.faction == faction
		if isOurMarket and type(scan.data) == "string" and (not best or (scan.ts or 0) > (best.ts or 0)) then
			best = scan
		end
	end
	return best
end

local function finishBuild(job)
	built = { ts = job.scan.ts or 0, unitsByItem = job.unitsByItem, levelsByItem = {} }
	building = nil
	if ns.OnDepthReady then
		pcall(ns.OnDepthReady)
	end
end

local function readStep()
	local job = building
	if not job then
		return
	end
	local ok, nextPos = pcall(Pricing.readListingsInto, job.scan.data, job.pos, LISTINGS_PER_FRAME, job.unitsByItem)
	if not ok then
		building = nil
		ns.lastError = nextPos
		return
	end
	if nextPos then
		job.pos = nextPos
		C_Timer.After(0, readStep)
	else
		finishBuild(job)
	end
end

--- Starts reading the newest scan when it is not the one already read or being read.
function Scan.refresh()
	local scan = latestScan()
	if not scan then
		return
	end
	local isAlreadyRead = built and built.ts == scan.ts
	local isBeingRead = building and building.scan.ts == scan.ts
	if isAlreadyRead or isBeingRead then
		return
	end
	building = { scan = scan, pos = 1, unitsByItem = {} }
	C_Timer.After(0, readStep)
end

--- Price levels for an item, cheapest first.
--- @return table|nil levels
--- @return string|nil source "live" | "scan"
--- @return number|nil when the levels were seen (unix seconds)
function Scan.levels(itemID)
	local now = ns.now()
	local live = liveByItem[itemID]
	if live and now - live.at <= LIVE_MAX_AGE_S then
		return live.levels, "live", live.at
	end
	Scan.refresh()
	if not built or now - built.ts > SCAN_MAX_AGE_S then
		return nil
	end
	local levels = built.levelsByItem[itemID]
	if not levels then
		local units = built.unitsByItem[itemID]
		if not units then
			return nil
		end
		levels = Pricing.toLevels(units)
		built.levelsByItem[itemID] = levels
	end
	return levels, "scan", built.ts
end

--- Keeps the levels of a commodity search the auction house just answered, leaving out the
--- player's own units.
function Scan.recordLive(itemID)
	if not itemID or not C_AuctionHouse or not C_AuctionHouse.GetNumCommoditySearchResults then
		return
	end
	local units = {}
	for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0 do
		local info = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
		local qty = info and (info.quantity or 0) - (info.numOwnerItems or 0) or 0
		if qty > 0 and info.unitPrice and info.unitPrice > 0 then
			units[info.unitPrice] = (units[info.unitPrice] or 0) + qty
		end
	end
	if next(units) then
		liveByItem[itemID] = { at = ns.now(), levels = Pricing.toLevels(units) }
	end
end

--- Everything Pricing needs for one item: AHledger's public prices plus the levels.
--- @return table|nil { median, minBuyout, soldPerDay, levels, levelsSource, levelsAt }
function Scan.lookup(itemID)
	local prices = AHledgerAPI and AHledgerAPI.GetPrice(itemID)
	local levels, source, at = Scan.levels(itemID)
	if not prices and not levels then
		return nil
	end
	return {
		median = prices and prices.median,
		minBuyout = prices and prices.minBuyout,
		soldPerDay = prices and prices.soldPerDay,
		levels = levels,
		levelsSource = source,
		levelsAt = at,
	}
end

--- The newest full scan AHledger stored for this realm and faction, or nil.
function Scan.latest()
	return latestScan()
end

--- "status" text for the slash command.
function Scan.statusText()
	if building then
		return "reading your latest scan"
	end
	if not built then
		return "no scan of this realm and faction read yet; prices fall back to AHledger's table"
	end
	return string.format("depth from your scan %s ago", ns.Display.ageText(ns.now() - built.ts))
end
