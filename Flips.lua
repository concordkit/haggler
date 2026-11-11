--[[
	Flips: auction house listings whose buyout is under what a vendor pays for the item. Buy them
	and sell them to any merchant; the vendor takes no cut.

	Reads every listing of the newest full scan AHledger stored for this realm and faction, a few
	thousand a frame. A listing's vendor price comes from GetItemInfo; items the client hasn't
	cached are asked for and the scan is read again once (they are counted as still loading).

	Setting: HagglerDB.flipMinProfit (copper; leaves out items whose whole flip earns less).
]]
local _, ns = ...
ns = ns or {} -- tests load files without the addon table

local Flips = {}
ns.Flips = Flips

local LISTING = "(%d+):(%d+):(%d+):%d+:%d+"
local LISTINGS_PER_FRAME = 4000
local REREAD_DELAY_S = 3
Flips.DEFAULT_MIN_PROFIT = 100

local job = nil -- { scan, next, acc, cache, pending, onDone, hasReread }

-- Helpers, defined at the bottom of the file; declared here so they stay local.
local startPass, readStep, finishPass, vendorPrice

-- ---------------------------------------------------------------------------------------------
-- The pure part: tested in tests/flips_spec.lua
-- ---------------------------------------------------------------------------------------------

--- Adds one listing to `acc` ({ [itemID] = { vendor, qty, cost, lowest } }) when its unit price is
--- under the vendor price.
--- @param vendor number|nil copper a vendor pays for one; 0 or nil skips the listing
function Flips.add(acc, itemID, stack, buyout, vendor)
	itemID, stack, buyout = tonumber(itemID), tonumber(stack), tonumber(buyout)
	if not (itemID and stack and buyout and vendor) or stack <= 0 or buyout <= 0 or vendor <= 0 then
		return
	end
	if buyout >= vendor * stack then
		return
	end
	local entry = acc[itemID]
	if not entry then
		entry = { vendor = vendor, qty = 0, cost = 0, lowest = buyout / stack }
		acc[itemID] = entry
	end
	entry.qty = entry.qty + stack
	entry.cost = entry.cost + buyout
	entry.lowest = math.min(entry.lowest, buyout / stack)
end

--- The flips in `acc`, biggest profit first, without those earning under minProfit.
--- @param nameOf function itemID -> name, link (either may be nil)
--- @return table[] { itemID, name, link, lowest, vendor, qty, cost, profit, pct }
function Flips.rows(acc, minProfit, nameOf)
	local rows = {}
	for id, entry in pairs(acc) do
		local profit = entry.vendor * entry.qty - entry.cost
		if profit >= (minProfit or 0) then
			local name, link = nameOf(id)
			rows[#rows + 1] = {
				itemID = id,
				name = name or ("item " .. id),
				link = link or name or ("item " .. id),
				lowest = math.floor(entry.lowest),
				vendor = entry.vendor,
				qty = entry.qty,
				cost = entry.cost,
				profit = profit,
				pct = entry.cost > 0 and profit / entry.cost * 100 or 0,
			}
		end
	end
	table.sort(rows, function(a, b)
		return a.profit > b.profit
	end)
	return rows
end

-- ---------------------------------------------------------------------------------------------
-- Reading a scan across frames
-- ---------------------------------------------------------------------------------------------

--- Starts reading the newest scan. onDone(result) gets { acc, pending, scan } or nil without a scan.
function Flips.read(onDone)
	local scan = ns.Scan.latest()
	if not scan then
		onDone(nil)
		return
	end
	job = { scan = scan, onDone = onDone }
	startPass(job)
end

--- Minimum profit a flip must earn, from HagglerDB.
function Flips.minProfit()
	local value = type(HagglerDB) == "table" and tonumber(HagglerDB.flipMinProfit) or nil
	return value or Flips.DEFAULT_MIN_PROFIT
end

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------

function startPass(j)
	j.next, j.acc, j.cache, j.pending = j.scan.data:gmatch(LISTING), {}, {}, {}
	C_Timer.After(0, function()
		readStep(j)
	end)
end

function readStep(j)
	if job ~= j then
		return
	end
	local ok, err = pcall(function()
		for _ = 1, LISTINGS_PER_FRAME do
			local id, stack, buyout = j.next()
			if not id then
				finishPass(j)
				return
			end
			id = tonumber(id)
			Flips.add(j.acc, id, stack, buyout, vendorPrice(id, j.cache, j.pending))
		end
		C_Timer.After(0, function()
			readStep(j)
		end)
	end)
	if not ok then
		job = nil
		ns.lastError = err
	end
end

function finishPass(j)
	local pendingCount = 0
	for _ in pairs(j.pending) do
		pendingCount = pendingCount + 1
	end
	if pendingCount > 0 and not j.hasReread then
		j.hasReread = true
		C_Timer.After(REREAD_DELAY_S, function()
			if job == j then
				startPass(j)
			end
		end)
		return
	end
	job = nil
	j.onDone({ acc = j.acc, pending = pendingCount, scan = j.scan })
end

-- Vendor price for an item: a number (0 = can't be sold), or nil while the client loads it.
function vendorPrice(id, cache, pending)
	local cached = cache[id]
	if cached ~= nil then
		return cached
	end
	local getItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	local name, _, _, _, _, _, _, _, _, _, price = getItemInfo(id)
	if not name then
		if not pending[id] then
			pending[id] = true
			if C_Item and C_Item.RequestLoadItemDataByID then
				pcall(C_Item.RequestLoadItemDataByID, id)
			end
		end
		return nil
	end
	cached = tonumber(price) or 0
	cache[id] = cached
	return cached
end
