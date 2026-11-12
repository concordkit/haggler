--[[
	Host: Haggler's own host layer, written to Concord's API shape so the move into Concord is a
	port, not a rewrite. Inside Concord this file is dropped and the same calls go to the core.

	  Host.AddModule{ key, label, category, icon, settings, defaultEnabled, canDisable,
	                  onLoad, onEnable, onDisable }                     -> module handle
	  Host.Provide(name, version, { priority, owner?, <functions> })    capability registry
	  Host.Get(name, version?)                                          best provider or nil
	  Host.Start(savedSettings)                                         once SavedVariables load

	Lifecycle: registered -> loaded (onLoad, once) -> enabled (onEnable) <-> disabled (onDisable).
	Every module gets an `enabled` toggle in its settings unless it sets canDisable = false. A
	module registers its listeners, providers and commands in onEnable; disabling it drops them
	all, so a disabled module costs nothing.

	Failure isolation: every call into a module (lifecycle, bus handlers, provider functions)
	runs under pcall and is counted against the module. A provider that fails MAX_PROVIDER_FAILURES
	times is switched off for the session. A module whose onLoad fails is marked hasFailed and never
	enables. Each owner's first MAX_REPORTED_ERRORS errors reach onError; later ones are only
	counted in Diagnostics, so a failing handler on a frequent message cannot flood the chat.
]]
local _, ns = ...

local Host = {}
ns.Host = Host

Host.MAX_PROVIDER_FAILURES = 3
Host.MAX_REPORTED_ERRORS = 5
Host.CAPABILITY_ADDED = 'capability:added'
Host.CAPABILITY_REMOVED = 'capability:removed'
Host.SETTINGS_CHANGED = 'settings:changed'

local HOST_OWNER = 'host'
local MODULE_KEY_PATTERN = '^%a[%w_]*$'

-- Helpers live at the bottom of the file; declared here so they stay local.
local validateModuleDefinition, withEnabledToggle, wrapProvider, sortedProviders, newestVersion
local isNonEmptyString

local ModuleMethods = {}
ModuleMethods.__index = ModuleMethods

--- Creates a host. The add-on makes one (ns.host); tests make as many as they like.
--- @param options table|nil { onError = fun(owner, where, err) } for reporting failures
--- @return table host with dot-call functions, as Concord's API
function Host.create(options)
	options = options or {}
	local host = {}
	local modulesByKey = {}
	local moduleOrder = {}
	local providersByName = {}
	local preferredOwnerByName = {}
	local commandsByName = {}
	local diagnostics = {}
	local settings
	local isStarted = false

	local function recordError(owner, where, err)
		local entry = diagnostics[owner] or { errors = 0 }
		entry.errors = entry.errors + 1
		entry.last = string.format('%s: %s', where, tostring(err))
		diagnostics[owner] = entry
		if options.onError and entry.errors <= Host.MAX_REPORTED_ERRORS then
			local suffix = entry.errors == Host.MAX_REPORTED_ERRORS and ' (further errors are only counted)' or ''
			options.onError(owner, where, tostring(err) .. suffix)
		end
	end

	local bus = ns.Bus.new(function(owner, message, err)
		recordError(owner, 'message ' .. message, err)
	end)
	host.Bus = bus

	local function callModule(module, hookName)
		local hook = module.definition[hookName]
		if not hook then
			return true
		end
		local ok, err = pcall(hook, module)
		if not ok then
			recordError(module.key, hookName, err)
		end
		return ok
	end

	local function removeProvider(name, owner)
		local providers = providersByName[name]
		local provider = providers and providers[owner]
		if not provider then
			return
		end
		providers[owner] = nil
		provider.isRemoved = true
		bus:Send(Host.CAPABILITY_REMOVED, name, provider.version, owner)
	end

	local function dropModuleRegistrations(module)
		bus:UnlistenAll(module.key)
		for name, providers in pairs(providersByName) do
			if providers[module.key] then
				removeProvider(name, module.key)
			end
		end
		for name, command in pairs(commandsByName) do
			if command.owner == module.key then
				commandsByName[name] = nil
			end
		end
	end

	local function enableModule(module)
		if module.hasFailed then
			return false
		end
		if module.isEnabled then
			return true
		end
		module.isEnabled = true
		if callModule(module, 'onEnable') then
			return true
		end
		module.isEnabled = false
		dropModuleRegistrations(module)
		return false
	end

	local function disableModule(module)
		if not module.isEnabled then
			return
		end
		callModule(module, 'onDisable')
		module.isEnabled = false
		dropModuleRegistrations(module)
	end

	local function shouldBeEnabled(module)
		if module.definition.canDisable == false then
			return true
		end
		return settings:Get(module.key, 'enabled')
	end

	-- Each module loads on its own: a failure marks only that module and Start carries on.
	local function loadModule(module)
		local isRegistered, err = pcall(settings.Register, settings, module.key, module.schema)
		if not isRegistered then
			recordError(module.key, 'settings', err)
			module.hasFailed = true
			return
		end
		module.isLoaded = true
		if not callModule(module, 'onLoad') then
			module.hasFailed = true
			return
		end
		if shouldBeEnabled(module) then
			enableModule(module)
		end
	end

	local function onSettingChanged(moduleKey, key, value, oldValue)
		local module = modulesByKey[moduleKey]
		if module and module.isLoaded and key == 'enabled' then
			if value then
				enableModule(module)
			else
				disableModule(module)
			end
		end
		bus:Send(Host.SETTINGS_CHANGED, moduleKey, key, value, oldValue)
	end

	--- Registers a module. Before Start it waits; after Start it loads at once.
	--- Throws for a bad definition or settings schema, so no broken module is ever queued.
	--- @param definition table see the file header
	--- @return table module handle
	function host.AddModule(definition)
		validateModuleDefinition(definition)
		if modulesByKey[definition.key] or definition.key == HOST_OWNER then
			error(string.format('Host.AddModule: key %q is taken', definition.key), 2)
		end
		local schema = withEnabledToggle(definition)
		ns.Settings.validateSchema(definition.key, schema)
		local module = setmetatable({
			key = definition.key,
			label = definition.label,
			category = definition.category or 'feature',
			icon = definition.icon,
			definition = definition,
			schema = schema,
			host = host,
			isLoaded = false,
			isEnabled = false,
			hasFailed = false,
		}, ModuleMethods)
		modulesByKey[module.key] = module
		moduleOrder[#moduleOrder + 1] = module
		if isStarted then
			loadModule(module)
		end
		return module
	end

	--- Loads every registered module against the saved settings. Call once.
	--- @param savedSettings table|nil the settings table of HagglerDB (changed in place)
	function host.Start(savedSettings)
		if isStarted then
			error('Host.Start: already started', 2)
		end
		settings = ns.Settings.new(savedSettings, onSettingChanged)
		host.Settings = settings
		isStarted = true
		for _, module in ipairs(moduleOrder) do
			loadModule(module)
		end
	end

	function host.IsStarted()
		return isStarted
	end

	--- @return table|nil module handle
	function host.Module(key)
		return modulesByKey[key]
	end

	--- Turns a module on through its setting, so the choice is saved.
	function host.Enable(key)
		local module = host.Module(key) or error(string.format('Host.Enable: unknown module %q', key), 2)
		if module.definition.canDisable == false then
			return enableModule(module)
		end
		settings:Set(key, 'enabled', true)
		return module.isEnabled
	end

	--- Turns a module off through its setting, so the choice is saved.
	function host.Disable(key)
		local module = host.Module(key) or error(string.format('Host.Disable: unknown module %q', key), 2)
		if module.definition.canDisable == false then
			error(string.format('Host.Disable: %q cannot be disabled', key), 2)
		end
		settings:Set(key, 'enabled', false)
	end

	function host.IsEnabled(key)
		local module = modulesByKey[key]
		return module ~= nil and module.isEnabled
	end

	--- Provides a versioned capability. One provider per owner and name; providing again
	--- replaces it. Fires capability:added.
	--- @param name string contract name, e.g. 'price'
	--- @param version number contract version
	--- @param provider table { priority = number?, owner = string?, <functions> }
	function host.Provide(name, version, provider)
		if not isNonEmptyString(name) then
			error('Host.Provide: name must be a non-empty string', 2)
		end
		if type(version) ~= 'number' or version < 1 or version % 1 ~= 0 then
			error('Host.Provide: version must be a positive integer', 2)
		end
		if type(provider) ~= 'table' then
			error('Host.Provide: provider must be a table', 2)
		end
		local owner = provider.owner or HOST_OWNER
		local providers = providersByName[name] or {}
		providersByName[name] = providers
		if providers[owner] then
			removeProvider(name, owner)
		end
		local record
		record = wrapProvider(provider, owner, version, function(err)
			recordError(owner, 'provider ' .. name, err)
			record.failures = record.failures + 1
			if record.failures >= Host.MAX_PROVIDER_FAILURES and providers[owner] == record then
				removeProvider(name, owner)
			end
		end)
		providers[owner] = record
		bus:Send(Host.CAPABILITY_ADDED, name, version, owner)
	end

	--- The best provider of a capability: the preferred owner when set and present, else the
	--- highest priority (ties go to the owner key, alphabetically, so the choice is stable).
	--- Without a version, Get returns a provider of the newest contract version present, so a
	--- caller never gets a mix of contracts; a preferred owner that offers only an older version
	--- is skipped. Pass a version to reach an older contract.
	--- @param name string
	--- @param version number|nil only providers of this contract version
	--- @return table|nil provider, whose functions never throw (they return nil on failure, and
	--- once the provider is withdrawn)
	function host.Get(name, version)
		local candidates = sortedProviders(providersByName[name], version or newestVersion(providersByName[name]))
		local preferred = preferredOwnerByName[name]
		for _, provider in ipairs(candidates) do
			if provider.owner == preferred then
				return provider.api
			end
		end
		local best = candidates[1]
		return best and best.api or nil
	end

	--- Every live provider of a capability, best first: { owner, version, priority }.
	function host.Providers(name)
		local list = {}
		for _, provider in ipairs(sortedProviders(providersByName[name])) do
			list[#list + 1] = { owner = provider.owner, version = provider.version, priority = provider.priority }
		end
		return list
	end

	--- Overrides the priority choice for a capability (the settings choice); nil clears it.
	function host.PreferProvider(name, owner)
		preferredOwnerByName[name] = owner
	end

	--- Sends a bus message as the host.
	function host.Send(message, ...)
		return bus:Send(message, ...)
	end

	--- Adds a /hag subcommand owned by a module, or by the host when owner is nil. Names are
	--- stored lowercased, as /hag looks them up.
	--- @param name string
	--- @param command table { usage, help, run = fun(args: string[]): string[] }
	--- @param owner string|nil
	function host.AddCommand(rawName, command, owner)
		if not isNonEmptyString(rawName) or rawName:find('%s') then
			error('Host.AddCommand: name must be one word', 2)
		end
		if type(command) ~= 'table' or type(command.run) ~= 'function' then
			error('Host.AddCommand: command needs a run function', 2)
		end
		local name = rawName:lower()
		if ns.Settings.BUILT_IN_COMMANDS[name] then
			error(string.format('Host.AddCommand: %q is built in', name), 2)
		end
		if commandsByName[name] then
			error(string.format('Host.AddCommand: %q is taken', name), 2)
		end
		local commandOwner = owner or HOST_OWNER
		commandsByName[name] = {
			owner = commandOwner,
			usage = command.usage,
			help = command.help,
			run = function(args)
				local ok, lines = pcall(command.run, args)
				if not ok then
					recordError(commandOwner, 'command ' .. name, lines)
					return { string.format('/hag %s failed; see diagnostics.', name) }
				end
				return lines or {}
			end,
		}
	end

	--- Runs the text after /hag and returns the lines to print.
	function host.RunCommand(line)
		if not isStarted then
			return { 'Haggler is still loading.' }
		end
		return settings:RunCommand(line, commandsByName)
	end

	--- Error counts per owner: { [owner] = { errors, last } }.
	function host.Diagnostics()
		return diagnostics
	end

	return host
end

-- Module handle ---------------------------------------------------------------------------

--- Subscribes the module to a bus message (replacing its earlier handler for it).
function ModuleMethods:On(message, handler)
	self.host.Bus:Listen(self.key, message, handler)
end

function ModuleMethods:Off(message)
	self.host.Bus:Unlisten(self.key, message)
end

function ModuleMethods:Send(message, ...)
	return self.host.Bus:Send(message, ...)
end

--- Provides a capability owned by this module; it is withdrawn when the module is disabled.
function ModuleMethods:Provide(name, version, provider)
	local owned = {}
	for field, value in pairs(provider) do
		owned[field] = value
	end
	owned.owner = self.key
	self.host.Provide(name, version, owned)
end

function ModuleMethods:Get(name, version)
	return self.host.Get(name, version)
end

function ModuleMethods:Setting(key)
	return self.host.Settings:Get(self.key, key)
end

--- @return boolean|nil, string|nil as Settings:Set
function ModuleMethods:SetSetting(key, value)
	return self.host.Settings:Set(self.key, key, value)
end

--- @return boolean whether the setting holds a stored (non-default) value
function ModuleMethods:IsSettingSet(key)
	return self.host.Settings:IsSet(self.key, key)
end

function ModuleMethods:AddCommand(name, command)
	self.host.AddCommand(name, command, self.key)
end

function ModuleMethods:IsEnabled()
	return self.isEnabled
end

-- Helpers ---------------------------------------------------------------------------------

function validateModuleDefinition(definition)
	if type(definition) ~= 'table' then
		error('Host.AddModule: definition must be a table', 3)
	end
	if type(definition.key) ~= 'string' or not definition.key:find(MODULE_KEY_PATTERN) then
		error('Host.AddModule: key must be an identifier', 3)
	end
	if not isNonEmptyString(definition.label) then
		error('Host.AddModule: label is required', 3)
	end
	for _, hookName in ipairs({ 'onLoad', 'onEnable', 'onDisable' }) do
		local hook = definition[hookName]
		if hook ~= nil and type(hook) ~= 'function' then
			error(string.format('Host.AddModule: %s must be a function', hookName), 3)
		end
	end
	if definition.settings ~= nil and type(definition.settings) ~= 'table' then
		error('Host.AddModule: settings must be a schema list', 3)
	end
end

-- The module's schema with the `enabled` toggle first, unless the module is always on.
function withEnabledToggle(definition)
	local schema = {}
	if definition.canDisable ~= false then
		schema[1] = {
			key = 'enabled',
			type = 'toggle',
			label = 'Enabled',
			default = definition.defaultEnabled ~= false,
		}
	end
	for _, entry in ipairs(definition.settings or {}) do
		if entry.key == 'enabled' then
			error(string.format('Host.AddModule: %s declares its own enabled setting', definition.key), 4)
		end
		schema[#schema + 1] = entry
	end
	return schema
end

-- Wraps every function of a provider in pcall; a failure calls onFailure and returns nil. Once
-- the provider is removed (record.isRemoved) its functions return nil without calling it.
function wrapProvider(provider, owner, version, onFailure)
	local api = {}
	local record = {
		api = api,
		owner = owner,
		version = version,
		priority = tonumber(provider.priority) or 0,
		failures = 0,
		isRemoved = false,
	}
	for field, value in pairs(provider) do
		if type(value) == 'function' then
			api[field] = function(...)
				if record.isRemoved then
					return nil
				end
				local results = { pcall(value, ...) }
				if not results[1] then
					onFailure(results[2])
					return nil
				end
				return unpack(results, 2, table.maxn(results))
			end
		elseif field ~= 'owner' and field ~= 'priority' then
			api[field] = value
		end
	end
	return record
end

function sortedProviders(providers, version)
	local list = {}
	for _, provider in pairs(providers or {}) do
		if version == nil or provider.version == version then
			list[#list + 1] = provider
		end
	end
	table.sort(list, function(a, b)
		if a.priority ~= b.priority then
			return a.priority > b.priority
		end
		return a.owner < b.owner
	end)
	return list
end

function newestVersion(providers)
	local newest = nil
	for _, provider in pairs(providers or {}) do
		newest = math.max(newest or provider.version, provider.version)
	end
	return newest
end

function isNonEmptyString(value)
	return type(value) == 'string' and value ~= ''
end

return Host
