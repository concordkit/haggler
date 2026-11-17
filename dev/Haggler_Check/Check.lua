--[[
	Check: wires the suite together. One run per Haggler version and client build, kept in
	Haggler_CheckDB, with the item list (db.items) for the reader; every signal goes to the items listening for it, and each verdict is
	recorded and shown.

	  /hc         toggles the checklist panel
	  /hc reset   keeps the current run aside and starts a fresh one

	With Concord_Check v1 (ConcordCheck.VERSION == 1) the items are registered with
	ConcordCheck.RegisterProbes; each Concord judge reports what this checker recorded, so the
	host shows the same verdicts. Each recorded result is also logged as an INFO evidence line,
	which makes the host re-judge at once. When the host refuses (a false return) the results
	are logged as PASS or FAIL instead. The /hc panel stays either way.

	  Check.create(env, db, identity) -> checker   identity = { version, build, charKey }
	  checker:Deliver(signal)                      judges and records
	  Check.boot(env)                              the game entry point
]]
local addonName, ns = ...

local Suite, Items = ns.Suite, ns.Items

-- Helpers live at the bottom of the file; declared here so they stay local.
local indexItemsBySignal, signalNamesOf, manifestOf, readIdentity, registerWithConcord, forwardToConcord, safeCall
local concordOf, concordVerdictOf, concordItemOf, clientEventsOf

local CONCORD_VERSION = 1
local OWNER = 'Haggler'
-- ConcordCheck.Log takes PASS, FAIL or INFO; a look or n/a is information.
local LOG_VERDICTS = { pass = 'PASS', fail = 'FAIL' }

local Check = {}
ns.Check = Check

--- Builds a checker over a saved table; opens (or continues) this version's run.
--- @param env table _G, or a fake
--- @param db table Haggler_CheckDB
--- @param identity table { version, build, charKey }
--- @return table checker
function Check.create(env, db, identity)
	if type(db) ~= 'table' or type(identity) ~= 'table' then
		error('Check.create: db and identity are required', 2)
	end
	Suite.validateItems(Items.list)
	local checker = setmetatable({
		env = env,
		db = db,
		identity = identity,
		itemsBySignal = indexItemsBySignal(Items.list),
		listeners = {},
	}, { __index = Check })
	checker.run = Suite.openRun(db, identity.version, identity.build, checker:Now())
	db.items = manifestOf(Items.list)
	return checker
end

--- Sends a signal to every item listening for it and records what they say.
--- @param signal table { name, args, at }
function Check:Deliver(signal)
	local facts = self:Facts()
	for _, item in ipairs(self.itemsBySignal[signal.name] or {}) do
		-- A once item answered with a look keeps listening: the player may still confirm it.
		local isAnsweredOnce = item.once and type(self.db.once) == 'table' and Suite.isJudged(self.db.once[item.id])
		if not isAnsweredOnce then
			self.run.scratch[item.id] = self.run.scratch[item.id] or {}
			local isJudged, verdict = pcall(item.judge, facts, self.run.scratch[item.id], signal)
			if not isJudged then
				verdict = { state = 'look', evidence = { 'judge error: ' .. tostring(verdict) } }
			end
			if verdict ~= nil then
				self:Record(item, verdict)
			end
		end
	end
end

function Check:Record(item, verdict, isByPlayer)
	if Suite.record(self.db, self.run, item, verdict, self:Now(), isByPlayer) then
		for _, listener in ipairs(self.listeners) do
			listener(item, Suite.resultOf(self.db, self.run, item))
		end
	end
end

--- Starts a fresh run (the old one is kept aside) and tells the listeners.
function Check:Reset()
	self.run = Suite.resetRun(self.db, self.identity.version, self.identity.build, self:Now())
	for _, listener in ipairs(self.listeners) do
		listener(nil, nil)
	end
end

function Check:OnRecord(listener)
	self.listeners[#self.listeners + 1] = listener
end

function Check:Facts()
	local env = self.env
	return {
		db = type(env.HagglerDB) == 'table' and env.HagglerDB or {},
		charDb = type(env.HagglerCharDB) == 'table' and env.HagglerCharDB or {},
		charKey = self.identity.charKey,
		now = self:Now(),
		run = self.run,
		api = self.api or {},
	}
end

function Check:Now()
	local now = safeCall(self.env.GetServerTime)
	return type(now) == 'number' and now or self.env.time()
end

--- The view the panel draws.
--- @return table model
function Check:Model()
	local checker = self
	return {
		items = function()
			return Items.list
		end,
		resultOf = function(item)
			return Suite.resultOf(checker.db, checker.run, item)
		end,
		progress = function()
			return Suite.progress(checker.db, checker.run, Items.list)
		end,
		nextItem = function()
			return Suite.nextItem(checker.db, checker.run, Items.list)
		end,
		runKey = function()
			return checker.run.key
		end,
		canSetVerdict = function(item)
			return Suite.canPlayerJudge(checker.db, checker.run, item)
		end,
		setVerdict = function(item, state)
			checker:Record(item, { state = state, evidence = { 'marked ' .. state .. ' by the player' } }, true)
		end,
	}
end

--- The game entry point: waits for this add-on's saved variables, then starts everything.
--- @param env table _G
function Check.boot(env)
	local loader = env.CreateFrame('Frame')
	loader:RegisterEvent('ADDON_LOADED')
	loader:SetScript('OnEvent', function(_, _, loadedName)
		if loadedName ~= addonName then
			return
		end
		loader:UnregisterEvent('ADDON_LOADED')
		env.Haggler_CheckDB = type(env.Haggler_CheckDB) == 'table' and env.Haggler_CheckDB or {}
		local checker = Check.create(env, env.Haggler_CheckDB, readIdentity(env))
		local observer = ns.Observer.create(env, function(signal)
			checker:Deliver(signal)
		end)
		checker.api = observer:Api()
		local panel = ns.Panel.create(env, checker:Model())
		local isRegistered = registerWithConcord(env, checker)
		checker:OnRecord(function(item, result)
			forwardToConcord(env, item, result, isRegistered)
			panel:Refresh()
		end)
		observer:Start(signalNamesOf(Items.list))
		env.SLASH_HAGGLERCHECK1 = '/hc'
		env.SlashCmdList.HAGGLERCHECK = function(message)
			if tostring(message or ''):lower():match('^%s*reset%s*$') then
				checker:Reset()
				env.print('Haggler checks: new run ' .. checker.run.key)
				panel:Refresh()
				return
			end
			panel:Toggle()
		end
	end)
end

-- Helpers ---------------------------------------------------------------------------------

function indexItemsBySignal(items)
	local index = {}
	for _, item in ipairs(items) do
		for _, signalName in ipairs(item.on or {}) do
			index[signalName] = index[signalName] or {}
			table.insert(index[signalName], item)
		end
	end
	return index
end

function signalNamesOf(items)
	local names = {}
	for signalName in pairs(indexItemsBySignal(items)) do
		names[#names + 1] = signalName
	end
	table.sort(names)
	return names
end

-- What the reader needs to list every item, judged or not: the saved results name only the judged.
function manifestOf(items)
	local manifest = {}
	for index, item in ipairs(items) do
		manifest[index] = {
			id = item.id,
			title = item.title,
			kind = item.kind,
			zone = item.zone,
			place = item.place,
			once = item.once == true,
		}
	end
	return manifest
end

-- Haggler's version and the client build key the run; the character keys sessions.
function readIdentity(env)
	local addOns = env.C_AddOns
	local version = addOns and safeCall(addOns.GetAddOnMetadata, 'Haggler', 'Version') or '?'
	local clientVersion, build = safeCall(env.GetBuildInfo)
	local name, realm = safeCall(env.UnitName, 'player'), safeCall(env.GetRealmName)
	return {
		version = version,
		build = tostring(clientVersion or '?') .. '.' .. tostring(build or '?'),
		charKey = name and realm and (name .. '-' .. realm) or nil,
	}
end

--- Registers the items with Concord_Check v1. A refusal is an expected outcome, not an error.
--- @return boolean isRegistered
--- @return string|nil reason 'no host', 'unsupported version', 'already registered', 'run in progress'
function registerWithConcord(env, checker)
	local concord = concordOf(env)
	if concord == nil or type(concord.RegisterProbes) ~= 'function' then
		return false, 'no host'
	end
	local items = {}
	for index, item in ipairs(Items.list) do
		items[index] = concordItemOf(checker, item)
	end
	local isCalled, isRegistered, reason = pcall(concord.RegisterProbes, {
		version = CONCORD_VERSION,
		owner = OWNER,
		addon = 'Haggler',
		label = 'Haggler',
		items = items,
	})
	if not isCalled then
		return false, 'host error: ' .. tostring(isRegistered)
	end
	return isRegistered == true, reason
end

-- ConcordCheck.Log(owner, verdict, text): the text names the item and its state, then its first
-- evidence line. Registered, the host judges the item, so the line is INFO evidence only.
function forwardToConcord(env, item, result, isRegistered)
	local concord = concordOf(env)
	if item == nil or type(result) ~= 'table' or concord == nil or type(concord.Log) ~= 'function' then
		return
	end
	local logVerdict = not isRegistered and LOG_VERDICTS[result.state] or 'INFO'
	local firstLine = type(result.evidence) == 'table' and result.evidence[1] or nil
	local text = item.id .. ' ' .. tostring(result.state) .. (firstLine and (': ' .. firstLine) or '')
	safeCall(concord.Log, OWNER, logVerdict, text)
end

-- The host's item: the same fields, events to re-judge on, and a judge that reports this
-- checker's recorded result (the checker already ran Haggler's judge over its facts and scratch).
function concordItemOf(checker, item)
	return {
		id = item.id,
		title = item.title,
		kind = item.kind,
		prompt = item.prompt,
		zone = item.zone,
		once = item.once == true,
		events = clientEventsOf(item),
		judge = function()
			return concordVerdictOf(Suite.resultOf(checker.db, checker.run, item))
		end,
	}
end

-- Haggler's result -> the host's verdict ('pass'|'fail'|'look'|nil) and evidence. The host has no
-- n/a: a player's N/A is a pass whose evidence says so.
function concordVerdictOf(result)
	if type(result) ~= 'table' then
		return nil, {}
	end
	local evidence = {}
	for index, line in ipairs(type(result.evidence) == 'table' and result.evidence or {}) do
		evidence[index] = line
	end
	if result.state == 'na' then
		table.insert(evidence, 1, 'n/a')
		return 'pass', evidence
	end
	return result.state, evidence
end

-- The client events in an item's `on` list (no hooks, no observer signals).
function clientEventsOf(item)
	local events = {}
	for _, name in ipairs(item.on or {}) do
		if not name:find(':', 1, true) and not ns.Observer.SYNTHETIC_SIGNALS[name] then
			events[#events + 1] = name
		end
	end
	return events
end

-- ConcordCheck when it speaks the contract this add-on was written for, else nil.
function concordOf(env)
	local concord = env.ConcordCheck
	if type(concord) == 'table' and concord.VERSION == CONCORD_VERSION then
		return concord
	end
	return nil
end

function safeCall(fn, ...)
	if type(fn) ~= 'function' then
		return nil
	end
	local results = { pcall(fn, ...) }
	if not results[1] then
		return nil
	end
	return unpack(results, 2, table.maxn(results))
end

-- Exposed for the spec.
Check.forwardToConcord = forwardToConcord
Check.registerWithConcord = registerWithConcord

if type(rawget(_G, 'CreateFrame')) == 'function' then
	Check.boot(_G)
end
