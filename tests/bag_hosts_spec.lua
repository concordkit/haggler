local t = ...
local FakeGame = require('tests.fake_game')

local LINEN, SILK, UNKNOWN = 2589, 4306, 9999
local MARKET = 'forever/normal/alliance/us'
local NOW = 1000000
-- Linen sells on the AH (no badge); silk's AH price is under its vendor price (vendor badge);
-- the unknown item has no price at all (low confidence).
-- AHledger rows: median, min buyout, quantity, 7- and 30-day median, 30-day low and high, sold a day.
local AHLEDGER_ROWS = { [2589] = { 120, 95, 500, 118, 125, 90, 160, 45 }, [4306] = { 10, 9, 500, 10, 11, 8, 12, 45 } }
local COINS = 0.015625
local ALERT = 0.265625

local function newButton(bag, slot)
	local button = FakeGame.newWidget('Button')
	function button:GetBagID()
		return bag
	end
	function button:GetBag()
		return bag
	end
	function button:GetID()
		return slot
	end
	return button
end

-- A Blizzard container frame: UpdateItems (hooked by the adapter), EnumerateValidItems yielding
-- (index, button) as Mainline does, and a money frame for the total.
local function newBagFrame(buttons)
	local frame = FakeGame.newWidget('Frame')
	frame.MoneyFrame = FakeGame.newWidget('Frame', frame)
	function frame.UpdateItems() end
	function frame.EnumerateValidItems()
		local index = 0
		return function()
			index = index + 1
			local button = buttons[index]
			if button then
				return index, button
			end
		end
	end
	return frame
end

local function newGame()
	local game = FakeGame.new({
		now = NOW,
		itemInfo = {
			[LINEN] = { name = 'Linen Cloth', maxStack = 20, vendorPrice = 13 },
			[SILK] = { name = 'Silk Cloth', maxStack = 20, vendorPrice = 50 },
		},
	})
	game.env.AHledgerAPI = FakeGame.newAHledgerAPI({ market = MARKET, updated = NOW - 7200, rows = AHLEDGER_ROWS })
	game.bagSlots[0] = 4
	game.containerItems['0:1'] = { itemID = SILK, stackCount = 1, hyperlink = 'item:4306' }
	game.containerItems['0:2'] = { itemID = UNKNOWN, stackCount = 1, hyperlink = 'item:9999' }
	game.containerItems['0:3'] = { itemID = LINEN, stackCount = 20, hyperlink = 'item:2589' }
	-- Slot 4 holds an item the client has not loaded yet.
	game.containerItems['0:4'] = { stackCount = 1 }
	return game
end

local function newButtons()
	return { newButton(0, 1), newButton(0, 2), newButton(0, 3), newButton(0, 4), newButton(0, 5) }
end

-- The badges a button shows, by the icon's texcoords: 'vendor', 'low'.
local function badgesOf(button)
	local result = {}
	for _, child in ipairs(button.children) do
		if child.kind == 'Texture' and child.isShown then
			result[#result + 1] = child.texcoords[1] == COINS and 'vendor'
				or child.texcoords[1] == ALERT and 'low'
				or '?'
		end
	end
	table.sort(result)
	return table.concat(result, ',')
end

local function valueTextOf(button)
	for _, child in ipairs(button.children) do
		if child.kind == 'FontString' and child.isShown then
			return child.text
		end
	end
	return nil
end

-- Hooks on bag hosts (the scan module also hooks ReplicateItems).
local function bagHookCount(game)
	local count = 0
	for _, hook in ipairs(game.hooks) do
		if hook.method ~= 'ReplicateItems' and not FakeGame.TRACKING_HOOKS[hook.method] then
			count = count + 1
		end
	end
	return count
end

local function badgeRow(buttons)
	local row = {}
	for index, button in ipairs(buttons) do
		row[index] = badgesOf(button)
	end
	return row
end

local function startWithBlizzard(game)
	local buttons = newButtons()
	local frame = newBagFrame(buttons)
	game.env.ContainerFrameCombinedBags = frame
	local addon = FakeGame.startAddon(t, game)
	return addon, frame, buttons
end

t.group('bag hosts: Blizzard')

t.test('buttons get the vendor and low badges at start; empty and unloaded slots get none', function()
	local game = newGame()
	local addon, _, buttons = startWithBlizzard(game)
	t.same(badgeRow(buttons), { 'vendor', 'low', '', '', '' })
	t.eq(valueTextOf(buttons[3]), nil, 'values are off by default')
	t.eq(bagHookCount(game), 1, 'UpdateItems is post-hooked once')
	t.same(addon.errors, {})
end)

t.test('UpdateItems repaints: a slot that changed item changes badge', function()
	local game = newGame()
	local _, frame, buttons = startWithBlizzard(game)
	game.containerItems['0:1'] = { itemID = LINEN, stackCount = 5, hyperlink = 'item:2589' }
	game.containerItems['0:3'] = { itemID = SILK, stackCount = 2, hyperlink = 'item:4306' }
	frame:UpdateItems()
	t.same(badgeRow(buttons), { '', 'low', 'vendor', '', '' })
end)

t.test('the bag total sits above the money frame, flagged low when a stack is a guess', function()
	local game = newGame()
	local _, frame = startWithBlizzard(game)
	local total = frame.children[#frame.children]
	t.eq(total.kind, 'FontString')
	t.eq(total.points[1][2], frame.MoneyFrame)
	t.truthy(total.isShown)
	t.truthy(total.text:find('^Bags: '), total.text)
	t.truthy(total.text:find('|T', 1, true), 'low confidence icon')
	game.containerItems['0:2'] = nil
	game:Fire('BAG_UPDATE_DELAYED')
	game:RunTimers()
	t.eq(total.text:find('|T', 1, true), nil, 'no guess left')
end)

t.test('the value setting adds a short value; the total setting hides the total', function()
	local game = newGame()
	local addon, frame, buttons = startWithBlizzard(game)
	addon.bags:SetSetting('showValue', true)
	addon.bags:SetSetting('showTotal', false)
	game:RunTimers()
	t.eq(valueTextOf(buttons[1]), '50c')
	t.eq(valueTextOf(buttons[2]), nil, 'nothing for a 0 value')
	t.eq(frame.children[#frame.children].isShown, false)
end)

t.test('switching the module off clears every overlay and the total; hooks stay quiet', function()
	local game = newGame()
	local addon, frame, buttons = startWithBlizzard(game)
	addon.host.Disable('bags')
	t.same(badgeRow(buttons), { '', '', '', '', '' })
	t.eq(frame.children[#frame.children].isShown, false)
	frame:UpdateItems()
	t.same(badgeRow(buttons), { '', '', '', '', '' })
	addon.host.Enable('bags')
	t.same(badgeRow(buttons), { 'vendor', 'low', '', '', '' })
	t.eq(bagHookCount(game), 1, 'not hooked twice')
end)

t.test('painting waits for the end of combat', function()
	local game = newGame()
	local _, frame, buttons = startWithBlizzard(game)
	game.inCombat = true
	game.containerItems['0:3'] = { itemID = SILK, stackCount = 2, hyperlink = 'item:4306' }
	frame:UpdateItems()
	t.eq(badgesOf(buttons[3]), '')
	game.inCombat = false
	game:Fire('PLAYER_REGEN_ENABLED')
	game:RunTimers()
	t.eq(badgesOf(buttons[3]), 'vendor')
end)

t.test('a hidden bag frame is not repainted by a refresh', function()
	local game = newGame()
	local _, frame, buttons = startWithBlizzard(game)
	frame:Hide()
	game.containerItems['0:3'] = { itemID = SILK, stackCount = 2, hyperlink = 'item:4306' }
	game:Fire('BAG_UPDATE_DELAYED')
	game:RunTimers()
	t.eq(badgesOf(buttons[3]), '')
end)

t.group('bag hosts: BagPad')

t.test('BagPad: its NATIVE_UPDATE message repaints the native frame', function()
	local game = newGame()
	local buttons = newButtons()
	local listeners = {}
	game.env.BagPad = {
		Events = {
			Listen = function(_, message, owner, fn)
				listeners[#listeners + 1] = { message = message, owner = owner, fn = fn }
			end,
		},
		Native = { frame = newBagFrame(buttons) },
	}
	local addon = FakeGame.startAddon(t, game)
	t.eq(#listeners, 1)
	t.eq(listeners[1].message, 'NATIVE_UPDATE')
	t.eq(listeners[1].owner, 'Haggler')
	t.same(badgeRow(buttons), { 'vendor', 'low', '', '', '' }, 'painted by the first refresh')
	game.containerItems['0:3'] = { itemID = SILK, stackCount = 2, hyperlink = 'item:4306' }
	listeners[1].fn()
	t.eq(badgesOf(buttons[3]), 'vendor')
	t.same(addon.errors, {})
end)

t.group('bag hosts: Bagnon')

local function newBagnon(inventoryFrame)
	local itemGroup = { Layout = function() end, ForBag = function() end }
	return {
		InventoryItemGroup = itemGroup,
		Frames = {
			Get = function(_, id)
				return id == 'inventory' and inventoryFrame or nil
			end,
		},
	}
end

t.test('Bagnon loaded later: attached on ADDON_LOADED, groups painted after Layout and ForBag', function()
	local game = newGame()
	local addon = FakeGame.startAddon(t, game)
	local inventory = newBagFrame({})
	game.env.Bagnon = newBagnon(inventory)
	game:Fire('ADDON_LOADED', 'Bagnon')
	game:RunTimers()
	t.eq(bagHookCount(game), 2)
	local list = newButtons()
	-- Kept in a local to the end, as Bagnon keeps its live groups.
	local group = { buttons = list }
	game.env.Bagnon.InventoryItemGroup.Layout(group)
	t.same(badgeRow(list), { 'vendor', 'low', '', '', '' })
	-- Some versions keep buttons as a bag -> slot map.
	local mapped = { newButton(0, 1), newButton(0, 2) }
	game.env.Bagnon.InventoryItemGroup.ForBag({ buttons = { [0] = { [1] = mapped[1], [2] = mapped[2] } } })
	t.same(badgeRow(mapped), { 'vendor', 'low' })
	local total = inventory.children[#inventory.children]
	t.truthy(total.text:find('^Bags: '))
	game.containerItems['0:3'] = { itemID = SILK, stackCount = 2, hyperlink = 'item:4306' }
	-- Bagnon's adapter holds groups weakly, as Bagnon holds them; collect now so the test
	-- does not depend on when the collector runs.
	collectgarbage()
	game:Fire('BAG_UPDATE_DELAYED')
	game:RunTimers()
	t.eq(badgesOf(list[3]), 'vendor', 'known groups repaint on bag updates')
	t.eq(group.buttons, list)
	t.same(addon.errors, {})
end)

local function fontStringCount(frame)
	local count = 0
	for _, child in ipairs(frame.children) do
		count = count + (child.kind == 'FontString' and 1 or 0)
	end
	return count
end

t.test('Bagnon: the money frame class table is never used; the total attaches once to the real one', function()
	local game = newGame()
	local inventory = FakeGame.newWidget('Frame')
	-- Before PlaceMoney (or with money hidden) MoneyFrame is only the PlayerMoney class.
	local playerMoneyClass = {
		SetPoint = function()
			error('SetPoint on a class table')
		end,
	}
	setmetatable(inventory, { __index = { MoneyFrame = playerMoneyClass } })
	game.env.Bagnon = newBagnon(inventory)
	local addon = FakeGame.startAddon(t, game)
	for _ = 1, 3 do
		game.env.Bagnon.InventoryItemGroup.Layout({ buttons = newButtons() })
	end
	t.eq(fontStringCount(inventory), 0, 'nothing created before the money frame exists')
	rawset(inventory, 'MoneyFrame', FakeGame.newWidget('Frame', inventory))
	game.env.Bagnon.InventoryItemGroup.Layout({ buttons = newButtons() })
	game.env.Bagnon.InventoryItemGroup.Layout({ buttons = newButtons() })
	t.eq(fontStringCount(inventory), 1, 'one total, created once')
	t.same(addon.errors, {})
	t.eq(#game.printed, 0, table.concat(game.printed, '\n'))
end)

t.test("Bagnon: another character's cached bags are not painted, and old paint is cleared", function()
	local game = newGame()
	game.env.Bagnon = newBagnon(newBagFrame({}))
	local addon = FakeGame.startAddon(t, game)
	local list = newButtons()
	local group = { buttons = list, isCached = false }
	function group:IsCached()
		return self.isCached
	end
	game.env.Bagnon.InventoryItemGroup.Layout(group)
	t.same(badgeRow(list), { 'vendor', 'low', '', '', '' })
	group.isCached = true
	game.env.Bagnon.InventoryItemGroup.Layout(group)
	t.same(badgeRow(list), { '', '', '', '', '' }, 'an alt is shown from the cache')
	game:Fire('BAG_UPDATE_DELAYED')
	game:RunTimers()
	t.same(badgeRow(list), { '', '', '', '', '' }, 'a repaint skips it too')
	t.same(addon.errors, {})
end)

t.group('bag hosts: Baganator')

local function newBaganator()
	local api = { widgets = {}, regions = {}, refreshes = 0, layouts = 0 }
	api.RegisterCornerWidget = function(label, id, onUpdate, onInit, defaults, isFast)
		api.widgets[id] = { label = label, onUpdate = onUpdate, onInit = onInit, defaults = defaults, isFast = isFast }
	end
	api.RegisterRegion = function(label, id, view, position, frame)
		api.regions[id] = { label = label, view = view, position = position, frame = frame }
	end
	api.RequestItemButtonsRefresh = function()
		api.refreshes = api.refreshes + 1
	end
	api.RequestLayoutUpdate = function()
		api.layouts = api.layouts + 1
	end
	return { API = api }
end

local function widgetRegion(api, id)
	return api.widgets[id].onInit(FakeGame.newWidget('Button'))
end

t.test('Baganator: three corner widgets answer show, hide or not ready', function()
	local game = newGame()
	game.env.Baganator = newBaganator()
	local addon = FakeGame.startAddon(t, game)
	local api = game.env.Baganator.API
	t.eq(api.widgets.haggler_vendor.defaults.corner, 'top_left')
	t.eq(api.widgets.haggler_low.defaults.corner, 'top_right')
	t.eq(api.widgets.haggler_value.defaults.corner, 'bottom_left')
	for _, widget in pairs(api.widgets) do
		t.truthy(widget.defaults.priority >= 100, 'appended after the user widgets, never inserted ahead')
	end
	local vendor, low = widgetRegion(api, 'haggler_vendor'), widgetRegion(api, 'haggler_low')
	t.eq(vendor.kind, 'Texture')
	t.eq(api.widgets.haggler_vendor.onUpdate(vendor, { itemID = SILK, itemCount = 3 }), true)
	t.eq(vendor.texcoords[1], COINS)
	t.eq(api.widgets.haggler_vendor.onUpdate(vendor, { itemID = LINEN, itemCount = 3 }), false)
	t.eq(api.widgets.haggler_low.onUpdate(low, { itemID = UNKNOWN }), true)
	t.eq(api.widgets.haggler_low.onUpdate(low, {}), nil, 'item data not ready')
	t.eq(api.widgets.haggler_vendor.onUpdate(vendor, { itemID = SILK, isBound = true }), false, 'bound')
	local value = widgetRegion(api, 'haggler_value')
	t.eq(value.kind, 'FontString')
	t.eq(api.widgets.haggler_value.onUpdate(value, { itemID = LINEN, itemCount = 20 }), false, 'values off')
	addon.bags:SetSetting('showValue', true)
	t.eq(api.widgets.haggler_value.onUpdate(value, { itemID = LINEN, itemCount = 20 }), true)
	t.eq(value.text, '17s')
	addon.host.Disable('bags')
	t.eq(api.widgets.haggler_vendor.onUpdate(vendor, { itemID = SILK }), false, 'module off')
	t.same(addon.errors, {})
end)

t.test('Baganator: the total region follows its text width; repaints ask for a refresh', function()
	local game = newGame()
	game.env.Baganator = newBaganator()
	FakeGame.startAddon(t, game)
	local api = game.env.Baganator.API
	local region = api.regions.haggler_total
	t.eq(region.view, 'backpack')
	t.eq(region.position, 'bottom_left')
	local text = region.frame.children[1]
	t.truthy(text.text:find('^Bags: '))
	t.eq(region.frame.width, text:GetStringWidth() + 4)
	t.truthy(api.layouts >= 1)
	local refreshes = api.refreshes
	game:Fire('BAG_UPDATE_DELAYED')
	game:RunTimers()
	t.eq(api.refreshes, refreshes + 1)
end)

t.test('a saved scan repaints the bags (SCAN_READY)', function()
	local game = newGame()
	game.env.Baganator = newBaganator()
	local addon = FakeGame.startAddon(t, game)
	local api = game.env.Baganator.API
	local refreshes = api.refreshes
	addon.host.Bus:Send('SCAN_READY', MARKET, { at = NOW, source = 'scan', count = 2 })
	game:RunTimers()
	t.eq(api.refreshes, refreshes + 1)
	addon.host.Disable('bags')
	refreshes = api.refreshes
	addon.host.Bus:Send('SCAN_READY', MARKET, { at = NOW, source = 'scan', count = 2 })
	game:RunTimers()
	t.eq(api.refreshes, refreshes, 'no repaint while the module is off')
end)

t.test('a host that throws is reported and skipped, never fatal', function()
	local game = newGame()
	game.env.Baganator = { API = {
		RegisterCornerWidget = function()
			error('API changed')
		end,
	} }
	local addon, _, buttons = startWithBlizzard(game)
	t.same(badgeRow(buttons), { 'vendor', 'low', '', '', '' }, 'Blizzard still painted')
	local printed = table.concat(game.printed, '\n')
	t.truthy(printed:find('bag host Baganator failed', 1, true), printed)
	t.same(addon.errors, {})
end)

t.test('no bag host at all is a no-op', function()
	local game = newGame()
	local addon = FakeGame.startAddon(t, game)
	game:Fire('BAG_UPDATE_DELAYED')
	game:RunTimers()
	t.same(addon.errors, {})
	t.eq(bagHookCount(game), 0)
end)
