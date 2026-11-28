local t = ...
local FakeGame = require('tests.fake_game')

local MARKET = 'forever/normal/alliance/us'
local NOW = 1000000

local function start(prepare)
	local game = FakeGame.new({ now = NOW })
	game.env.AHledgerAPI = FakeGame.newAHledgerAPI({ market = MARKET, updated = NOW - 3600, rows = {} })
	if prepare then
		prepare(game)
	end
	local addon = FakeGame.startAddon(t, game)
	return game, addon
end

local function readOnly(settings)
	return setmetatable({}, {
		__index = settings,
		__newindex = function()
			error('Haggler wrote AHledger settings', 2)
		end,
	})
end

local function noticeShown(addon)
	return addon.Compat.notice ~= nil and addon.Compat.notice:IsShown()
end

-- Compat ----------------------------------------------------------------------------------

t.group('compat')

local _, ns = start()

t.test('overlapping features: a missing key is on, only false is off', function()
	local Compat = ns.Compat
	t.eq(#Compat.overlappingFeatures(nil), #Compat.AHLEDGER_FEATURES)
	t.eq(#Compat.overlappingFeatures({}), 9)
	local keys = {}
	for _, feature in ipairs(Compat.overlappingFeatures({ tooltip = false, bar = false, ledger = true, junk = false })) do
		keys[#keys + 1] = feature.key
	end
	t.same(keys, {
		'crafting',
		'craftDots',
		'bagDots',
		'postingHelper',
		'postingPlan',
		'vendorFlips',
		'ledger',
	})
	local allOff = {}
	for _, feature in ipairs(Compat.AHLEDGER_FEATURES) do
		allOff[feature.key] = false
	end
	t.same(Compat.overlappingFeatures(allOff), {})
end)

t.test('shows once at login, lists what is on, never writes AHledger', function()
	local game, addon = start(function(g)
		g.env.AHledgerDB = { settings = readOnly({ tooltip = false }) }
	end)
	t.eq(noticeShown(addon), false, 'not before login')
	game:Fire('PLAYER_LOGIN')
	t.truthy(noticeShown(addon))
	local text = addon.Compat.notice.list:GetText()
	t.truthy(text:find('Ledger bar'))
	t.eq(text:find('Prices in item tooltips'), nil, 'off in AHledger: not listed')
	t.same(addon.errors, {})
end)

t.test('the options button runs /ahl options', function()
	local opened = {}
	local game, addon = start(function(g)
		g.env.AHledgerDB = { settings = {} }
		g.env.SlashCmdList.AHLEDGER = function(args)
			opened[#opened + 1] = args
		end
	end)
	game:Fire('PLAYER_LOGIN')
	addon.Compat.notice.openButton:Click()
	t.same(opened, { 'options' })
end)

t.test('closing the notice in any way dismisses it for good; /hag compat reopens it', function()
	local game, addon = start(function(g)
		g.env.AHledgerDB = { settings = {} }
	end)
	game:Fire('PLAYER_LOGIN')
	t.eq(addon.Compat.notice.dismissButton, nil, 'one Close button only')
	addon.Compat.notice.closeButton:Click()
	t.eq(noticeShown(addon), false)
	t.eq(addon.host.Settings:Get('compat', 'noticeDismissed'), true)
	local reloaded = FakeGame.startAddon(t, game)
	game:Fire('PLAYER_LOGIN')
	t.eq(noticeShown(reloaded), false)
	t.same(reloaded.host.RunCommand('compat'), {}, '/hag compat still shows it on demand')
	t.truthy(noticeShown(reloaded))
end)

t.test('Escape closes the notice and counts as dismissing it', function()
	local game, addon = start(function(g)
		g.env.AHledgerDB = { settings = {} }
	end)
	game:Fire('PLAYER_LOGIN')
	local isListed = false
	for _, name in ipairs(game.env.UISpecialFrames) do
		isListed = isListed or name == 'HagglerCompatNotice'
	end
	t.truthy(isListed, 'listed for Escape')
	addon.Compat.notice:Hide()
	t.eq(addon.host.Settings:Get('compat', 'noticeDismissed'), true)
end)

t.test('the interface hiding for Alt+Z or a cinematic does not dismiss the notice', function()
	local game, addon = start(function(g)
		g.env.AHledgerDB = { settings = {} }
	end)
	game:Fire('PLAYER_LOGIN')
	game.env.UIParent:Hide()
	addon.Compat.notice:Hide()
	t.eq(addon.host.Settings:Get('compat', 'noticeDismissed'), false)
	game.env.UIParent:Show()
	addon.Compat.notice:Show()
	t.eq(addon.host.Settings:Get('compat', 'noticeDismissed'), false)
	addon.Compat.notice:Hide()
	t.eq(addon.host.Settings:Get('compat', 'noticeDismissed'), true)
end)

t.test('turning the module off hides the notice without dismissing it', function()
	local game, addon = start(function(g)
		g.env.AHledgerDB = { settings = {} }
	end)
	game:Fire('PLAYER_LOGIN')
	addon.host.Disable('compat')
	t.eq(noticeShown(addon), false)
	t.eq(addon.host.Settings:Get('compat', 'noticeDismissed'), false)
end)

t.test('nothing overlapping or no AHledger settings: no notice', function()
	local allOff = {}
	for _, feature in ipairs(ns.Compat.AHLEDGER_FEATURES) do
		allOff[feature.key] = false
	end
	local game, addon = start(function(g)
		g.env.AHledgerDB = { settings = allOff }
	end)
	game:Fire('PLAYER_LOGIN')
	t.eq(noticeShown(addon), false)
	t.same(addon.host.RunCommand('compat'), { 'No AHledger feature overlaps Haggler right now.' })
	local otherGame, other = start()
	otherGame:Fire('PLAYER_LOGIN')
	t.eq(noticeShown(other), true, 'no saved settings: every feature is at its default, on')
end)

t.test('enabled after login shows it at once', function()
	local _, addon = start(function(g)
		g.env.AHledgerDB = { settings = {} }
		g.isLoggedIn = true
	end)
	t.truthy(noticeShown(addon))
end)

-- Options ---------------------------------------------------------------------------------

t.group('options')

local function findSetting(game, variable)
	return game.settingsApi.settings[variable]
end

t.test('registers a Settings → AddOns category with every switch and an open button', function()
	local game, addon = start(FakeGame.addSettingsApi)
	local registered = game.settingsApi
	t.eq(registered.category.name, 'Haggler')
	t.eq(registered.addOnCategories[1], registered.category)
	t.eq(addon.Options.kind, 'settings')
	local entries = addon.Options.toggleEntries(addon.host.Settings, function(key)
		return key
	end)
	t.eq(#registered.checkboxes, #entries)
	local scanEnabled = findSetting(game, 'HAGGLER_SCAN_ENABLED')
	t.truthy(scanEnabled, 'each module has its Enabled switch')
	t.eq(scanEnabled.label, 'Auction house scan')
	t.eq(scanEnabled.GetValue(), true)
	scanEnabled.SetValue(false)
	t.eq(addon.host.IsEnabled('scan'), false, 'the checkbox turns the module off')
	t.eq(scanEnabled.GetValue(), false)
	t.eq(findSetting(game, 'HAGGLER_PRICING_ENABLED'), nil, 'an always-on module has no switch')
	t.truthy(findSetting(game, 'HAGGLER_COMPAT_NOTICEDISMISSED'))
	local button = registered.initializers[1]
	t.eq(button.buttonText, 'Open Haggler')
	button.onClick()
	t.truthy(addon.window:IsOpen())
	t.same(addon.host.RunCommand('options'), {})
	t.eq(registered.openedId, 42)
	t.same(addon.errors, {})
end)

t.test('a failing Settings API falls back to the legacy panel', function()
	local added = {}
	local game, addon = start(function(g)
		FakeGame.addSettingsApi(g)
		g.env.Settings.RegisterProxySetting = function()
			error('client changed')
		end
		g.env.InterfaceOptions_AddCategory = function(panel)
			added[#added + 1] = panel
		end
	end)
	t.eq(addon.Options.kind, 'legacy')
	t.eq(added[1], game.env.HagglerOptionsPanel)
	t.eq(added[1].name, 'Haggler')
	t.truthy(game.printed[#game.printed]:find('old options panel'))
	t.same(addon.errors, {})
end)

t.test('legacy panel switches flip settings and open the window', function()
	local added = {}
	local _, addon = start(function(g)
		g.env.InterfaceOptions_AddCategory = function(panel)
			added[#added + 1] = panel
		end
	end)
	local panel = added[1]
	t.eq(addon.Options.kind, 'legacy')
	local scanToggle
	for _, toggle in ipairs(panel.toggles) do
		if toggle.entry.moduleKey == 'scan' and toggle.entry.key == 'enabled' then
			scanToggle = toggle
		end
	end
	t.truthy(scanToggle.button.label:GetText():find(': on'))
	scanToggle.button:Click()
	t.eq(addon.host.IsEnabled('scan'), false)
	t.truthy(scanToggle.button.label:GetText():find(': off'))
	panel.openButton:Click()
	t.truthy(addon.window:IsOpen())
end)

local OWN_CREDIT = 'Prices from AHledger (ahledger.com), test feed'

local function startWithCredit(prepare)
	local game = FakeGame.new({ now = NOW })
	game.env.AHledgerAPI =
		FakeGame.newAHledgerAPI({ market = MARKET, updated = NOW - 3600, rows = {}, credit = OWN_CREDIT })
	prepare(game)
	return game, FakeGame.startAddon(t, game)
end

t.test("the Settings entry shows AHledger's own credit", function()
	local game, addon = startWithCredit(FakeGame.addSettingsApi)
	local credit
	for _, initializer in ipairs(game.settingsApi.initializers) do
		if initializer.kind == 'sectionHeader' then
			credit = initializer.name
		end
	end
	t.eq(credit, OWN_CREDIT, 'read from AHledgerAPI.CREDIT')
	t.same(addon.errors, {})
end)

t.test('the legacy panel shows the credit too', function()
	local added = {}
	local _, addon = startWithCredit(function(g)
		g.env.InterfaceOptions_AddCategory = function(panel)
			added[#added + 1] = panel
		end
	end)
	t.eq(added[1].credit:GetText(), OWN_CREDIT)
	t.same(addon.errors, {})
end)

t.test('without a usable credit the options fall back to the default line', function()
	local game = FakeGame.new({ now = NOW })
	game.env.AHledgerAPI = FakeGame.newAHledgerAPI({ market = MARKET, updated = NOW - 3600, rows = {}, credit = '' })
	FakeGame.addSettingsApi(game)
	local addon = FakeGame.startAddon(t, game)
	t.eq(addon.Options.credit(), addon.PriceData.DEFAULT_CREDIT)
	t.same(addon.errors, {})
end)

t.test('toggleEntries refuses missing arguments', function()
	t.raises(function()
		ns.Options.toggleEntries(nil, tostring)
	end, 'required')
	t.raises(function()
		ns.Options.toggleEntries(ns.host.Settings, nil)
	end, 'required')
end)
