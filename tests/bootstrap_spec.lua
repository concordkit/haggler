local t = ...

-- Loads Haggler.lua with a fake game: the event frame, chat and slash table live in _G, as in
-- the client. Everything set here is removed again afterwards.
local FAKE_GLOBALS = { 'CreateFrame', 'DEFAULT_CHAT_FRAME', 'SlashCmdList', 'GetServerTime' }

local function withFakeGame(run)
	local frame = { events = {} }
	function frame:SetScript(_, handler)
		self.onEvent = handler
	end
	function frame:RegisterEvent(event)
		self.events[event] = true
	end
	function frame:UnregisterEvent(event)
		self.events[event] = nil
	end
	local printed = {}
	rawset(_G, 'CreateFrame', function()
		return frame
	end)
	rawset(_G, 'DEFAULT_CHAT_FRAME', {
		AddMessage = function(_, text)
			printed[#printed + 1] = text
		end,
	})
	rawset(_G, 'SlashCmdList', {})
	rawset(_G, 'GetServerTime', function()
		return 1
	end)
	local ok, err = pcall(run, frame, printed)
	for _, name in ipairs(FAKE_GLOBALS) do
		rawset(_G, name, nil)
	end
	rawset(_G, 'SLASH_HAGGLER1', nil)
	rawset(_G, 'HagglerDB', nil)
	rawset(_G, 'HagglerCharDB', nil)
	if not ok then
		error(err, 0)
	end
end

local function loadWithBootstrap()
	local ns = t.loadAddon()
	assert(loadfile('Haggler.lua'))('Haggler', ns)
	return ns
end

t.test('starts on ADDON_LOADED, builds saved data and answers /hag', function()
	withFakeGame(function(frame)
		local ns = loadWithBootstrap()
		t.eq(ns.host.IsStarted(), false)
		frame.onEvent(frame, 'ADDON_LOADED', 'SomeOtherAddon')
		t.eq(ns.host.IsStarted(), false)
		frame.onEvent(frame, 'ADDON_LOADED', 'Haggler')
		t.truthy(ns.host.IsStarted())
		t.eq(frame.events.ADDON_LOADED, nil)
		t.eq(rawget(_G, 'HagglerDB').version, ns.Store.SCHEMA_VERSION)
		t.eq(rawget(_G, 'SLASH_HAGGLER1'), '/hag')
		local lines = ns.host.RunCommand('list')
		t.same(lines, {
			'pricing.staleMediumHours = 24  (Prices older than this many hours are medium confidence)',
			'pricing.staleLowHours = 72  (Prices older than this many hours are low confidence)',
		})
		t.eq(ns.pricing:Setting('staleLowHours'), 72)
		rawget(_G, 'SlashCmdList').HAGGLER('help')
	end)
end)

t.test('newer saved data is left alone and reported', function()
	withFakeGame(function(frame, printed)
		rawset(_G, 'HagglerDB', { version = 999 })
		local ns = loadWithBootstrap()
		frame.onEvent(frame, 'ADDON_LOADED', 'Haggler')
		t.eq(ns.host.IsStarted(), false)
		t.truthy(printed[1]:find('newer Haggler', 1, true))
		t.same(rawget(_G, 'HagglerDB'), { version = 999 })
	end)
end)
