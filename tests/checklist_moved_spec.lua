-- In-game checklist items (steps 4–6) that a spec proves, so the in-game run leaves them out.
-- The rest of the moved items were already proven elsewhere; dev/Haggler_Check/README.md maps
-- each item to its spec or its in-game check.
local t = ...
local FakeGame = require('tests.fake_game')

local DAY = 86400
local LINEN = 2589
local MARKET = 'forever/normal/alliance/us'
local NOW = 1000000
local CHAR = 'Eilu-Nightslayer'
-- 2026-03-29 00:00 UTC; at a fixed UTC+1 local midnight falls an hour earlier.
local MARCH_29 = 1774742400
local LOCAL_OFFSET = 3600
local LOCAL_MIDNIGHT = MARCH_29 - LOCAL_OFFSET

-- A local clock at a fixed UTC offset, shaped like the client's date and time.
local function fixedOffsetClock(offset)
	local clock = {}
	function clock.date(_, at)
		return os.date('!*t', at + offset)
	end
	function clock.time(fields)
		local utcFields = {
			year = fields.year,
			month = fields.month,
			day = fields.day,
			hour = fields.hour or 12,
			min = fields.min or 0,
			sec = fields.sec or 0,
		}
		-- os.time reads its table as local time; undo the machine's own offset.
		local asIfLocal = os.time(utcFields)
		local machineOffset = os.time(os.date('!*t', asIfLocal)) - asIfLocal
		return asIfLocal - machineOffset - offset
	end
	return clock
end

local function trackedLinen(unitPrice)
	return {
		itemId = LINEN,
		qty = 1,
		remaining = 1,
		listed = 1,
		unitPrice = unitPrice,
		deposit = 0,
		postedAt = NOW - 600,
		hours = 48,
		state = 'active',
		changedAt = NOW - 600,
		char = CHAR,
		knownUnits = 0,
		knownCopper = 0,
	}
end

local function linenScan(at, otherPrice)
	return {
		at = at,
		source = 'own',
		count = 1,
		items = {
			[LINEN] = {
				min = 100,
				units = 6,
				maxStackSeen = 20,
				levels = { { price = 100, qty = 1 }, { price = otherPrice, qty = 5 } },
			},
		},
	}
end

-- Item 8: "near local midnight, 'today' rolls over".
t.test('the today session rolls over at local midnight', function()
	local game = FakeGame.new({ now = LOCAL_MIDNIGHT - 60 })
	local addon = FakeGame.startAddon(t, game)
	local clock = fixedOffsetClock(LOCAL_OFFSET)
	game.env.date, game.env.time = clock.date, clock.time
	addon.sessions:SetMode('today')
	t.eq((addon.sessions:Start(LOCAL_MIDNIGHT - 60)), LOCAL_MIDNIGHT - DAY, 'a minute before midnight')
	t.eq((addon.sessions:Start(LOCAL_MIDNIGHT + 60)), LOCAL_MIDNIGHT, 'a minute after midnight')
	t.same(addon.errors, {})
end)

-- Item 15: "after a fresh scan in which someone undercut you, the advice moves".
t.test('a fresh scan with an undercut moves the open Auctions tab advice', function()
	local game = FakeGame.new({ now = NOW, itemInfo = { [LINEN] = { name = 'Linen Cloth', maxStack = 20 } } })
	local addon = FakeGame.startAddon(t, game, function(started)
		local market = started.store:Market(MARKET)
		started.ScanStore.save(market, linenScan(NOW - 60, 101))
		market.auctions = { [1] = trackedLinen(100) }
	end)
	addon.window:Open('auctions')
	local auctions = addon.window.containers.auctions
	t.eq(auctions.state.rows[1].advice.action, 'hold', 'cheapest before the undercut')

	game.now = NOW + 60
	addon.ScanStore.save(addon.store:Market(MARKET), linenScan(game.now, 80))
	addon.host.Bus:Send('SCAN_READY', MARKET, { at = game.now, source = 'own', count = 1 })
	local advice = auctions.state.rows[1].advice
	t.eq(advice.action, 'relist', 'undercut after the scan')
	t.eq(advice.price, 79)
	t.same(addon.errors, {})
end)
