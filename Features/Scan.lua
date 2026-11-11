--[[
	Scan: the module that runs the scanner (Engine/Scan.lua) and saves its snapshots. It reads
	every full listing the client delivers, asks for one itself only when no scan is newer than
	15 minutes, and sends SCAN_READY(marketKey, { at, source, count }) once a snapshot is saved.
	Before saving, it compares the new scan with the market's last one, a slice per frame, and
	adds the units sold to the daily summaries (Engine/Sales.lua). Each save also sorts held
	units whose vendor price is now known, keeps the summaries to the sales window, and drops
	the scans of markets not scanned for keepMarketDays.
	Switching it off stops listening and drops a read in progress.

	Every C_AuctionHouse.ReplicateItems call, by any add-on, is recorded through a post-hook and
	saved per market (market.replicateRequestedAt), so the shared 15-minute window holds across
	a /reload even when Haggler never read the listing. Haggler's own request passes through
	the same hook; the window takes the newest time, so it is never counted twice. The hook is
	installed once and keeps recording while the module is off.

	  /hag scan          asks for a scan now (under the same 15-minute rule)
	  /hag scan status   what the scanner is doing
]]
local _, ns = ...

-- Helpers live at the bottom of the file; declared here so they stay local.
local newScanner, newSalesDiff, saveSnapshot, runScanCommand, statusLines, playerMarket, vendorPriceOf
local tidySavedScans, installRequestHook, recordRequest, lastRequestedAt, savedRequestAt

-- A saved request time this far ahead of the clock is a clock that ran ahead (or a hand edit),
-- not a request: it is ignored, then replaced, instead of blocking requests until that time.
local REQUEST_CLOCK_TOLERANCE = 60

local scanner
-- requestedAt: the newest request seen this session, kept while the market is not known yet.
local requests = { isHooked = false, requestedAt = nil }

ns.host.AddModule({
	key = 'scan',
	label = 'Auction house scan',
	settings = {
		{
			key = 'autoScan',
			type = 'toggle',
			label = 'Ask for a full scan when the auction house opens and no scan is newer than 15 minutes',
			default = true,
		},
		{
			key = 'graceSeconds',
			type = 'slider',
			label = 'Seconds to wait after the auction house opens, so another add-on can scan first',
			default = ns.Scan.DEFAULT_GRACE_SECONDS,
			min = 0,
			max = 60,
		},
		{
			key = 'frameBudgetMs',
			type = 'slider',
			label = 'Milliseconds a frame may spend reading a scan',
			default = ns.Scan.DEFAULT_FRAME_BUDGET_MS,
			min = 1,
			max = 30,
		},
		{
			key = 'keepMarketDays',
			type = 'slider',
			label = 'Days to keep the scan of an auction house you have not scanned since',
			default = ns.ScanStore.DEFAULT_KEEP_MARKET_DAYS,
			min = 1,
			max = 365,
		},
	},
	onEnable = function(module)
		installRequestHook()
		scanner = newScanner(module)
		scanner:Enable()
		module:AddCommand('scan', {
			usage = 'scan [status]',
			help = 'Ask for an auction house scan (at most one every 15 minutes), or show its status',
			run = function(args)
				return runScanCommand(args)
			end,
		})
	end,
	onDisable = function()
		if scanner then
			scanner:Disable()
			scanner = nil
		end
	end,
})

-- Helpers ---------------------------------------------------------------------------------

function newScanner(module)
	return ns.Scan.new({
		wow = ns.wow,
		lastSavedAt = function()
			local snapshot = ns.prices and ns.prices:Snapshot()
			return snapshot and snapshot.at
		end,
		lastRequestedAt = lastRequestedAt,
		newFollowUp = newSalesDiff,
		onSnapshot = function(snapshot, salesDiff)
			saveSnapshot(module, snapshot, salesDiff)
		end,
		settings = function()
			return {
				autoScan = module:Setting('autoScan'),
				graceSeconds = module:Setting('graceSeconds'),
				frameBudgetMs = module:Setting('frameBudgetMs'),
			}
		end,
		onError = function(where, err)
			ns.wow:Print(string.format('scan failed in %s: %s', where, tostring(err)))
		end,
	})
end

function installRequestHook()
	if requests.isHooked then
		return
	end
	requests.isHooked = ns.wow:HookReplicateRequests(recordRequest)
end

-- Any ReplicateItems call counts, Haggler's or another add-on's, even one the server refuses:
-- the client cannot tell, and the shared window is what the server enforces.
function recordRequest()
	local now = ns.wow:Now()
	requests.requestedAt = math.max(requests.requestedAt or now, now)
	local market = playerMarket()
	if market then
		local saved = savedRequestAt(market, now)
		market.replicateRequestedAt = saved and math.max(saved, now) or now
	end
end

function lastRequestedAt()
	local market = playerMarket()
	local saved = market and savedRequestAt(market, ns.wow:Now()) or nil
	if saved and requests.requestedAt then
		return math.max(saved, requests.requestedAt)
	end
	return saved or requests.requestedAt
end

function savedRequestAt(market, now)
	local saved = tonumber(market.replicateRequestedAt)
	if not saved or saved > now + REQUEST_CLOCK_TOLERANCE then
		return nil
	end
	return saved
end

-- The comparison with the market's last scan, or nil when there is nothing to compare.
function newSalesDiff(snapshot)
	local market = playerMarket()
	if not market then
		return nil
	end
	return ns.Sales.newDiff(ns.ScanStore.latest(market), snapshot, vendorPriceOf)
end

function saveSnapshot(module, snapshot, salesDiff)
	local market, marketKey = playerMarket()
	if not market then
		error('the market is not known yet (no faction)')
	end
	if salesDiff then
		if type(market.scanDays) ~= 'table' then
			market.scanDays = {}
		end
		ns.Sales.record(market.scanDays, salesDiff)
	end
	if not ns.ScanStore.save(market, snapshot) then
		error('the scan had no usable listings; the saved scan is kept')
	end
	tidySavedScans(module, market, snapshot.at)
	module:Send('SCAN_READY', marketKey, { at = snapshot.at, source = snapshot.source, count = snapshot.count })
end

-- Sorts held units, keeps the summaries to the window and drops stale markets' scans.
function tidySavedScans(module, market, now)
	ns.Sales.classifyPending(market.scanDays, vendorPriceOf)
	local salesSettings = ns.prices and ns.prices:SalesSettings()
	ns.Sales.prune(market.scanDays, now, salesSettings and salesSettings.windowDays)
	ns.ScanStore.pruneStaleMarkets(ns.store:Markets(), now, module:Setting('keepMarketDays'))
end

function vendorPriceOf(itemId)
	return ns.prices and ns.prices:VendorPrice(itemId)
end

function playerMarket()
	local marketKey = ns.prices and ns.prices:MarketKey()
	if not marketKey then
		return nil
	end
	return ns.store:Market(marketKey), marketKey
end

function runScanCommand(args)
	if type(args) == 'table' and args[1] == 'status' then
		return statusLines(scanner:Status())
	end
	local isRequested, reason = scanner:RequestNow()
	if isRequested then
		return { 'Scan requested; the auction house sends the whole listing in a moment.' }
	end
	return { 'No scan requested: ' .. tostring(reason) .. '.' }
end

function statusLines(status)
	local lines = { 'Scan: ' .. status.state }
	local lastFullScan = status.lastFullScanAt and ns.TooltipLines.ago(ns.wow:Now() - status.lastFullScanAt)
	lines[#lines + 1] = 'Last full scan: ' .. (lastFullScan or 'no full scan saved yet')
	if status.nextAllowedIn and status.nextAllowedIn > 0 then
		lines[#lines + 1] = 'Next request allowed in ' .. ns.TooltipLines.age(status.nextAllowedIn)
	end
	if status.rowsTotal then
		lines[#lines + 1] = string.format('Read %d of %d listings', status.rowsRead or 0, status.rowsTotal)
	end
	if status.lastError then
		lines[#lines + 1] = 'Last problem: ' .. status.lastError
	end
	return lines
end
