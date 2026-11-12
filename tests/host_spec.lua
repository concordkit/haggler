local t = ...
local ns = t.loadAddon()

t.group('bus')

t.test('delivers to every listener in order with arguments', function()
	local bus = ns.Bus.new()
	local seen = {}
	bus:Listen('a', 'PING', function(message, value)
		seen[#seen + 1] = 'a:' .. message .. ':' .. value
	end)
	bus:Listen('b', 'PING', function(_, value)
		seen[#seen + 1] = 'b:' .. value
	end)
	t.eq(bus:Send('PING', 7), 2)
	t.same(seen, { 'a:PING:7', 'b:7' })
	t.eq(bus:Send('NOBODY'), 0)
end)

t.test('one handler per owner and message; listening again replaces it', function()
	local bus = ns.Bus.new()
	local calls = 0
	bus:Listen('a', 'PING', function() end)
	bus:Listen('a', 'PING', function()
		calls = calls + 1
	end)
	bus:Send('PING')
	t.eq(calls, 1)
	t.eq(bus:ListenerCount('PING'), 1)
end)

t.test('a failing handler is reported and does not stop the others', function()
	local errors = {}
	local bus = ns.Bus.new(function(owner, message, err)
		errors[#errors + 1] = owner .. ' ' .. message .. ' ' .. err
	end)
	local reached = false
	bus:Listen('bad', 'PING', function()
		error('boom')
	end)
	bus:Listen('good', 'PING', function()
		reached = true
	end)
	t.eq(bus:Send('PING'), 1)
	t.truthy(reached)
	t.eq(#errors, 1)
	t.truthy(errors[1]:find('^bad PING .*boom'))
end)

t.test('unlisten and unlisten-all, also during a send', function()
	local bus = ns.Bus.new()
	local seen = {}
	bus:Listen('a', 'PING', function()
		seen[#seen + 1] = 'a'
		bus:UnlistenAll('b')
	end)
	bus:Listen('b', 'PING', function()
		seen[#seen + 1] = 'b'
	end)
	bus:Listen('b', 'PONG', function() end)
	bus:Send('PING')
	t.same(seen, { 'a', 'b' }, 'removal takes effect from the next send')
	bus:Send('PING')
	t.same(seen, { 'a', 'b', 'a' })
	t.eq(bus:ListenerCount('PONG'), 0)
	bus:Unlisten('a', 'PING')
	t.eq(bus:ListenerCount('PING'), 0)
end)

t.test('rejects bad arguments', function()
	local bus = ns.Bus.new()
	t.raises(function()
		bus:Listen('', 'PING', function() end)
	end, 'owner')
	t.raises(function()
		bus:Listen('a', 'PING', 'not a function')
	end, 'handler')
end)

t.group('registry')

t.test('Get returns the highest priority provider of a capability', function()
	local host = ns.Host.create()
	host.Provide('price', 1, {
		owner = 'auctionator',
		priority = 10,
		get = function()
			return 'low'
		end,
	})
	host.Provide('price', 1, {
		owner = 'haggler',
		priority = 50,
		get = function()
			return 'high'
		end,
	})
	t.eq(host.Get('price').get(1), 'high')
	t.eq(host.Get('missing'), nil)
	local providers = host.Providers('price')
	t.eq(providers[1].owner, 'haggler')
	t.eq(providers[2].owner, 'auctionator')
end)

t.test('Get filters by version and honours a preferred owner', function()
	local host = ns.Host.create()
	host.Provide('price', 1, { owner = 'a', priority = 1, name = 'a1' })
	host.Provide('price', 2, { owner = 'b', priority = 9, name = 'b2' })
	t.eq(host.Get('price').name, 'b2')
	t.eq(host.Get('price', 1).name, 'a1')
	t.eq(host.Get('price', 3), nil)
	host.PreferProvider('price', 'a')
	t.eq(host.Get('price').name, 'b2', 'the preference applies within the newest version')
	host.Provide('price', 2, { owner = 'a', priority = 1, name = 'a2' })
	t.eq(host.Get('price').name, 'a2')
	host.PreferProvider('price', nil)
	t.eq(host.Get('price').name, 'b2')
end)

t.test('equal priorities resolve by owner, so the choice is stable', function()
	local host = ns.Host.create()
	host.Provide('value', 1, { owner = 'zeta', name = 'z' })
	host.Provide('value', 1, { owner = 'alpha', name = 'a' })
	t.eq(host.Get('value').name, 'a')
end)

t.test('providing fires capability:added; replacing fires removed then added', function()
	local host = ns.Host.create()
	local events = {}
	host.Bus:Listen('watcher', ns.Host.CAPABILITY_ADDED, function(_, name, version, owner)
		events[#events + 1] = 'added ' .. name .. ' ' .. version .. ' ' .. owner
	end)
	host.Bus:Listen('watcher', ns.Host.CAPABILITY_REMOVED, function(_, name, _, owner)
		events[#events + 1] = 'removed ' .. name .. ' ' .. owner
	end)
	host.Provide('price', 1, { owner = 'a' })
	host.Provide('price', 1, { owner = 'a' })
	t.same(events, { 'added price 1 a', 'removed price a', 'added price 1 a' })
end)

t.test('a failing provider returns nil and is switched off after repeated failures', function()
	local reported = 0
	local host = ns.Host.create({
		onError = function()
			reported = reported + 1
		end,
	})
	host.Provide('price', 1, {
		owner = 'flaky',
		priority = 9,
		get = function()
			error('broken')
		end,
	})
	host.Provide('price', 1, {
		owner = 'steady',
		priority = 1,
		get = function()
			return 42
		end,
	})
	local provider = host.Get('price')
	for _ = 1, ns.Host.MAX_PROVIDER_FAILURES do
		t.eq(provider.get(1), nil)
	end
	t.eq(reported, ns.Host.MAX_PROVIDER_FAILURES)
	t.eq(host.Diagnostics().flaky.errors, ns.Host.MAX_PROVIDER_FAILURES)
	t.eq(host.Get('price').get(1), 42)
end)

t.test('provider functions pass every return value through, nils included', function()
	local host = ns.Host.create()
	host.Provide('multi', 1, {
		get = function()
			return 1, nil, 3
		end,
	})
	local a, b, c = host.Get('multi').get()
	t.eq(a, 1)
	t.eq(b, nil)
	t.eq(c, 3)
end)

t.test('Provide rejects bad arguments', function()
	local host = ns.Host.create()
	t.raises(function()
		host.Provide('', 1, {})
	end, 'name')
	t.raises(function()
		host.Provide('price', 0, {})
	end, 'version')
	t.raises(function()
		host.Provide('price', 1.5, {})
	end, 'version')
end)

t.group('modules')

local function trackedModule(host, key, extra)
	local log = {}
	local definition = {
		key = key,
		label = key,
		onLoad = function()
			log[#log + 1] = 'load'
		end,
		onEnable = function(module)
			log[#log + 1] = 'enable'
			module:On('PING', function()
				log[#log + 1] = 'ping'
			end)
			module:Provide('thing', 1, {
				get = function()
					return key
				end,
			})
			module:AddCommand(key .. 'cmd', {
				run = function()
					return { 'ran' }
				end,
			})
		end,
		onDisable = function()
			log[#log + 1] = 'disable'
		end,
	}
	for field, value in pairs(extra or {}) do
		definition[field] = value
	end
	return host.AddModule(definition), log
end

t.test('modules wait for Start, then load and enable in order', function()
	local host = ns.Host.create()
	local _, log = trackedModule(host, 'tooltip')
	t.same(log, {})
	t.same(host.RunCommand('help'), { 'Haggler is still loading.' })
	host.Start({})
	t.same(log, { 'load', 'enable' })
	t.truthy(host.IsEnabled('tooltip'))
	t.eq(host.Get('thing').get(), 'tooltip')
	host.Send('PING')
	t.same(log, { 'load', 'enable', 'ping' })
	t.same(host.RunCommand('tooltipcmd'), { 'ran' })
end)

t.test('disabling drops listeners, providers and commands, and is saved', function()
	local host = ns.Host.create()
	local _, log = trackedModule(host, 'bags')
	local saved = {}
	host.Start(saved)
	host.Disable('bags')
	t.same(log, { 'load', 'enable', 'disable' })
	t.eq(host.IsEnabled('bags'), false)
	t.same(saved, { bags = { enabled = false } })
	host.Send('PING')
	t.eq(#log, 3, 'no ping after disable')
	t.eq(host.Get('thing'), nil)
	t.same(host.RunCommand('bagscmd'), { 'Unknown command "bagscmd". Try /hag help.' })
	host.Enable('bags')
	t.same(log, { 'load', 'enable', 'disable', 'enable' })
	t.same(saved, {})
end)

t.test('the generated enabled setting drives the lifecycle, also from /hag', function()
	local host = ns.Host.create()
	local _, log = trackedModule(host, 'flips')
	host.Start({})
	t.same(host.RunCommand('set flips.enabled off'), { 'flips.enabled = off' })
	t.eq(host.IsEnabled('flips'), false)
	t.eq(log[#log], 'disable')
end)

t.test('a saved disabled module loads but never enables', function()
	local host = ns.Host.create()
	local _, log = trackedModule(host, 'crafting')
	host.Start({ crafting = { enabled = false } })
	t.same(log, { 'load' })
end)

t.test('defaultEnabled = false starts a module off', function()
	local host = ns.Host.create()
	local _, log = trackedModule(host, 'share', { defaultEnabled = false })
	host.Start({})
	t.same(log, { 'load' })
end)

t.test('a module added after Start loads at once', function()
	local host = ns.Host.create()
	host.Start({})
	local _, log = trackedModule(host, 'late')
	t.same(log, { 'load', 'enable' })
end)

t.test('canDisable = false has no toggle and cannot be disabled', function()
	local host = ns.Host.create()
	local module = host.AddModule({ key = 'engine', label = 'Engine', canDisable = false })
	host.Start({})
	t.truthy(module:IsEnabled())
	t.eq(#host.Settings:Schema('engine'), 0)
	t.raises(function()
		host.Disable('engine')
	end, 'cannot be disabled')
end)

t.test('a module error is isolated and counted', function()
	local host = ns.Host.create()
	host.AddModule({
		key = 'broken',
		label = 'Broken',
		onEnable = function(module)
			module:On('PING', function() end)
			error('nope')
		end,
	})
	local _, log = trackedModule(host, 'fine')
	host.Start({})
	t.eq(host.IsEnabled('broken'), false)
	t.eq(host.Bus:ListenerCount('PING'), 1, 'only the healthy module listens')
	t.truthy(host.Diagnostics().broken.last:find('onEnable'))
	t.same(log, { 'load', 'enable' })
end)

t.test('module settings live beside the generated toggle', function()
	local host = ns.Host.create()
	local module = host.AddModule({
		key = 'tooltip',
		label = 'Tooltip',
		settings = { { key = 'detail', type = 'toggle', label = 'Detail', default = false } },
	})
	host.Start({})
	t.eq(module:Setting('detail'), false)
	t.truthy(module:SetSetting('detail', true))
	t.eq(host.Settings:Schema('tooltip')[1].key, 'enabled')
end)

t.test('settings changes are announced on the bus', function()
	local host = ns.Host.create()
	host.AddModule({
		key = 'tooltip',
		label = 'Tooltip',
		settings = { { key = 'detail', type = 'toggle', label = 'Detail', default = false } },
	})
	local seen
	host.Bus:Listen('watcher', ns.Host.SETTINGS_CHANGED, function(_, moduleKey, key, value)
		seen = moduleKey .. '.' .. key .. '=' .. tostring(value)
	end)
	host.Start({})
	host.Settings:Set('tooltip', 'detail', true)
	t.eq(seen, 'tooltip.detail=true')
end)

t.test('a failing command reports instead of throwing', function()
	local host = ns.Host.create()
	host.AddCommand('oops', {
		run = function()
			error('bad')
		end,
	})
	host.Start({})
	t.same(host.RunCommand('oops'), { '/hag oops failed; see diagnostics.' })
	t.eq(host.Diagnostics().host.errors, 1)
end)

t.test('AddModule rejects bad definitions and duplicate keys', function()
	local host = ns.Host.create()
	host.AddModule({ key = 'bags', label = 'Bags' })
	t.raises(function()
		host.AddModule({ key = 'bags', label = 'Bags' })
	end, 'taken')
	t.raises(function()
		host.AddModule({ key = 'host', label = 'Host' })
	end, 'taken')
	t.raises(function()
		host.AddModule({ key = 'x' })
	end, 'label')
	t.raises(function()
		host.AddModule({ key = 'y', label = 'Y', onEnable = 'no' })
	end, 'onEnable')
	t.raises(function()
		host.AddModule({
			key = 'z',
			label = 'Z',
			settings = { { key = 'enabled', type = 'toggle', label = 'E', default = true } },
		})
	end, 'own enabled')
end)

t.group('review fixes')

t.test('a module command cannot shadow a built-in, and names are lowercased at registration', function()
	local host = ns.Host.create()
	host.Start({})
	t.raises(function()
		host.AddCommand('set', { run = function() end })
	end, 'built in')
	t.raises(function()
		host.AddCommand('Help', { run = function() end })
	end, 'built in')
	host.AddCommand('Scan', {
		run = function()
			return { 'scanned' }
		end,
	})
	t.same(host.RunCommand('scan'), { 'scanned' })
	t.raises(function()
		host.AddCommand('SCAN', { run = function() end })
	end, 'taken')
	t.eq(host.RunCommand('help')[1], 'Haggler commands:')
end)

t.test('a bad schema is refused at AddModule and never blocks later modules', function()
	local host = ns.Host.create()
	t.raises(function()
		host.AddModule({
			key = 'bad',
			label = 'Bad',
			settings = { { key = 'size', type = 'slider', label = 'Size', default = 1 } },
		})
	end, 'slider needs')
	t.eq(host.Module('bad'), nil)
	local _, log = trackedModule(host, 'fine')
	host.Start({})
	t.same(log, { 'load', 'enable' })
end)

t.test('a failed onLoad marks the module failed and it never enables', function()
	local host = ns.Host.create()
	local enableCount = 0
	host.AddModule({
		key = 'broken',
		label = 'Broken',
		onLoad = function()
			error('load failed')
		end,
		onEnable = function()
			enableCount = enableCount + 1
		end,
	})
	host.Start({})
	t.eq(host.Module('broken').hasFailed, true)
	t.eq(host.Enable('broken'), false)
	host.Settings:Set('broken', 'enabled', false)
	host.Settings:Set('broken', 'enabled', true)
	t.eq(enableCount, 0)
	t.truthy(host.Diagnostics().broken.last:find('onLoad'))
end)

t.test('a listener added during a send waits for the next send', function()
	local bus = ns.Bus.new()
	local seen = {}
	bus:Listen('a', 'PING', function()
		seen[#seen + 1] = 'a'
		bus:Listen('b', 'PING', function()
			seen[#seen + 1] = 'b'
		end)
	end)
	t.eq(bus:Send('PING'), 1)
	t.same(seen, { 'a' })
end)

t.test('Get without a version only picks among the newest contract version', function()
	local host = ns.Host.create()
	host.Provide('price', 1, {
		owner = 'old',
		priority = 50,
		version = function()
			return 1
		end,
	})
	host.Provide('price', 2, {
		owner = 'new',
		priority = 0,
		version = function()
			return 2
		end,
	})
	t.eq(host.Get('price').version(), 2)
	t.eq(host.Get('price', 1).version(), 1)
end)

t.test('a provider api kept after its module is disabled stops calling it', function()
	local host = ns.Host.create()
	local calls = 0
	host.AddModule({
		key = 'pricing',
		label = 'Pricing',
		onEnable = function(module)
			module:Provide('price', 1, {
				get = function()
					calls = calls + 1
					return 5
				end,
			})
		end,
	})
	host.Start({})
	local api = host.Get('price')
	t.eq(api.get(), 5)
	host.Disable('pricing')
	t.eq(api.get(), nil)
	t.eq(calls, 1)
end)

t.test('repeated errors are counted but reported a bounded number of times', function()
	local reported = 0
	local host = ns.Host.create({
		onError = function()
			reported = reported + 1
		end,
	})
	host.Bus:Listen('noisy', 'TICK', function()
		error('again')
	end)
	for _ = 1, 20 do
		host.Send('TICK')
	end
	t.eq(host.Diagnostics().noisy.errors, 20)
	t.eq(reported, ns.Host.MAX_REPORTED_ERRORS)
end)
