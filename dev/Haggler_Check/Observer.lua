--[[
	Observer: turns the client into signals for the judges. Observe only: client events, and
	hooksecurefunc post-hooks on the calls Haggler makes. No Blizzard function is replaced and no
	secure frame is touched.

	Every signal goes through one queue and is delivered half a second late, in the order it was
	seen, so Haggler has handled it first (its own books run on the same events and hooks). Every
	second the observer reads Haggler's ledgers and queues LEDGER with the new rows, then TICK:
	a row Haggler booked in its own hook of a call is read after that call's hook was queued, so a
	judge never sees a booking before the call that made it. LOGOUT is delivered at once: nothing
	runs after it.

	Haggler drops the bar focus inside PLAYER_REGEN_DISABLED, so the focus keys are read when the
	signal is seen, not when it is delivered: TICK and PLAYER_REGEN_* carry args.heldFocusKeys.

	  Observer.create(env, deliver) -> observer   env is _G in the game, a fake in the spec
	  observer:Start(eventNames)                  registers events and hooks
	  observer:Api() -> api                       the client reads the judges use (Items.lua)
]]
local _, ns = ...

local DELIVERY_DELAY = 0.5
local TICK_SECONDS = 1
local LOAD_DELAY = 1
local BAG_COUNT = 4
local SYNTHETIC_SIGNALS = { LOAD = true, LOGOUT = true, TICK = true, LEDGER = true, LUA_ERROR = true }
-- Events whose args carry the focus keys held at the moment they fired.
local FOCUS_SAMPLED_EVENTS = { PLAYER_REGEN_DISABLED = true, PLAYER_REGEN_ENABLED = true }
-- Always heard, whatever the items listen to.
local OWN_EVENTS = { 'ADDON_LOADED', 'PLAYER_ENTERING_WORLD', 'PLAYER_LOGOUT', 'CURSOR_CHANGED' }
-- 'HOOK:<name>' signal -> where the function lives ('_G' for a global).
local HOOK_OWNERS = {
	CraftRecipe = 'C_TradeSkillUI',
	BuyMerchantItem = '_G',
	DeleteCursorItem = '_G',
	TakeInboxMoney = '_G',
	TakeInboxItem = '_G',
	AutoLootMailItem = '_G',
	SendSearchQuery = 'C_AuctionHouse',
	PostItem = 'C_AuctionHouse',
	PostCommodity = 'C_AuctionHouse',
	CancelAuction = 'C_AuctionHouse',
	ConfirmCommoditiesPurchase = 'C_AuctionHouse',
}
local MAIL_HOOKS = { TakeInboxMoney = true, TakeInboxItem = true, AutoLootMailItem = true }

-- Helpers live at the bottom of the file; declared here so they stay local.
local readLedgerCursors, newLedgerRows, packArgs, describeMailTake, countFreeBagSlots, readInboxHeaders, safeCall

local Observer = {}
ns.Observer = Observer
Observer.SYNTHETIC_SIGNALS = SYNTHETIC_SIGNALS

--- Builds an observer over a client environment.
--- @param env table _G, or a fake with the same names
--- @param deliver fun(signal: table) receives { name, args, at }
--- @return table observer
function Observer.create(env, deliver)
	if type(env) ~= 'table' or type(deliver) ~= 'function' then
		error('Observer.create: env and deliver are required', 2)
	end
	local observer = {
		env = env,
		deliver = deliver,
		queue = {},
		ledgerCursors = nil,
		hasErrorHook = false,
		hasLoaded = false,
		pendingLoad = nil,
		cursorItemId = nil,
		sinceTick = 0,
	}
	return setmetatable(observer, { __index = Observer })
end

--- Registers the client events the items listen to, plus the observer's own, and the hooks.
--- @param signalNames string[] every name in the items' `on` lists
function Observer:Start(signalNames)
	local frame = self.env.CreateFrame('Frame')
	self.frame = frame
	local registered = {}
	for _, name in ipairs(OWN_EVENTS) do
		safeCall(frame.RegisterEvent, frame, name)
		registered[name] = true
	end
	for _, name in ipairs(signalNames) do
		local hookName = name:match('^HOOK:(.+)$')
		if hookName then
			self:Hook(hookName)
		elseif not SYNTHETIC_SIGNALS[name] and registered[name] == nil then
			-- An event this client lacks is skipped; its items wait for a look.
			safeCall(frame.RegisterEvent, frame, name)
			registered[name] = true
		end
	end
	self:HookErrorFrame()
	frame:SetScript('OnEvent', function(_, event, ...)
		self:OnEvent(event, ...)
	end)
	frame:SetScript('OnUpdate', function(_, elapsed)
		self:OnUpdate(elapsed)
	end)
end

--- Post-hooks one client function by its signal name.
--- @param hookName string a key of HOOK_OWNERS
function Observer:Hook(hookName)
	local ownerName = HOOK_OWNERS[hookName]
	if ownerName == nil then
		error('Observer:Hook: no owner known for ' .. tostring(hookName), 2)
	end
	local owner = ownerName == '_G' and self.env or self.env[ownerName]
	if type(owner) ~= 'table' or type(owner[hookName]) ~= 'function' then
		return
	end
	self.env.hooksecurefunc(owner, hookName, function(...)
		-- A failing observer must never break the call it watches.
		safeCall(self.OnHook, self, hookName, ...)
	end)
end

function Observer:HookErrorFrame()
	local errorFrame = self.env.ScriptErrorsFrame
	if self.hasErrorHook or type(errorFrame) ~= 'table' or type(errorFrame.DisplayMessageInternal) ~= 'function' then
		return
	end
	self.env.hooksecurefunc(errorFrame, 'DisplayMessageInternal', function(_, message)
		self:Enqueue('LUA_ERROR', { tostring(message) })
	end)
	self.hasErrorHook = true
end

function Observer:OnHook(hookName, ...)
	local args = packArgs(...)
	if hookName == 'DeleteCursorItem' then
		args.itemId = self.cursorItemId
	elseif MAIL_HOOKS[hookName] then
		describeMailTake(self.env, args)
	end
	self:Enqueue('HOOK:' .. hookName, args)
end

function Observer:OnEvent(event, ...)
	if event == 'CURSOR_CHANGED' then
		-- Read now: by the time DeleteCursorItem's hook runs the cursor is empty.
		local cursorType, itemId = safeCall(self.env.GetCursorInfo)
		if cursorType == 'item' then
			self.cursorItemId = itemId
		end
	elseif event == 'ADDON_LOADED' then
		self:HookErrorFrame()
	elseif event == 'PLAYER_ENTERING_WORLD' then
		local isInitialLogin, isReload = ...
		if not self.hasLoaded and self.pendingLoad == nil then
			local loadSignal = { name = 'LOAD', args = { isInitialLogin == true, isReload == true }, at = self:Now() }
			self.pendingLoad = { dueAt = self.env.GetTime() + LOAD_DELAY, signal = loadSignal }
		end
	elseif event == 'PLAYER_LOGOUT' then
		self.deliver({ name = 'LOGOUT', args = {}, at = self:Now() })
		return
	end
	local args = packArgs(...)
	if FOCUS_SAMPLED_EVENTS[event] then
		args.heldFocusKeys = self:HeldFocusKeys()
	end
	self:Enqueue(event, args)
end

function Observer:OnUpdate(elapsed)
	local clock = self.env.GetTime()
	if self.pendingLoad and self.pendingLoad.dueAt <= clock then
		self:DeliverDue(self.pendingLoad.dueAt)
		local loadSignal = self.pendingLoad.signal
		self.pendingLoad, self.hasLoaded = nil, true
		self.deliver(loadSignal)
	end
	self.sinceTick = self.sinceTick + elapsed
	if self.sinceTick >= TICK_SECONDS and self.hasLoaded then
		self.sinceTick = 0
		local rows = self:NewLedgerRows()
		if #rows > 0 then
			self:Enqueue('LEDGER', { rows })
		end
		self:Enqueue('TICK', { heldFocusKeys = self:HeldFocusKeys() })
	end
	self:DeliverDue(clock)
end

-- Delivers the queued signals due by `clock`, oldest first.
function Observer:DeliverDue(clock)
	while self.queue[1] and self.queue[1].dueAt <= clock do
		local entry = table.remove(self.queue, 1)
		self.deliver(entry.signal)
	end
end

function Observer:Enqueue(name, args)
	local signal = { name = name, args = args, at = self:Now() }
	self.queue[#self.queue + 1] = { dueAt = self.env.GetTime() + DELIVERY_DELAY, signal = signal }
end

--- The ledger rows booked since the last call, decoded, across markets. The first call only sets
--- the cursors. A ledger that got shorter (compaction folded old rows) restarts at its new end.
--- @return table[] rows
function Observer:NewLedgerRows()
	local db = self.env.HagglerDB
	if type(db) ~= 'table' then
		return {}
	end
	if self.ledgerCursors == nil then
		self.ledgerCursors = readLedgerCursors(db)
		return {}
	end
	return newLedgerRows(db, self.ledgerCursors)
end

--- The focus keys bound to Haggler's input buttons right now.
--- @return string[] keys
function Observer:HeldFocusKeys()
	self.api = self.api or self:Api()
	return ns.Items.heldFocusKeys(self.api)
end

function Observer:Now()
	local now = safeCall(self.env.GetServerTime)
	return type(now) == 'number' and now or self.env.time()
end

--- The client reads the judges use; each one is safe to call at any time.
--- @return table api
function Observer:Api()
	local env, observer = self.env, self
	local api = {}
	function api.isHagglerLoaded()
		local addOns = env.C_AddOns
		local isLoaded = addOns and safeCall(addOns.IsAddOnLoaded, 'Haggler')
		return isLoaded == true
	end
	function api.hagglerVersion()
		local addOns = env.C_AddOns
		return addOns and safeCall(addOns.GetAddOnMetadata, 'Haggler', 'Version') or nil
	end
	function api.hasErrorHook()
		return observer.hasErrorHook
	end
	function api.frameShown(name)
		local frame = env[name]
		if type(frame) ~= 'table' or type(frame.IsShown) ~= 'function' then
			return nil
		end
		return frame:IsShown() == true
	end
	function api.framePoint(name)
		local frame = env[name]
		if type(frame) ~= 'table' or type(frame.GetPoint) ~= 'function' then
			return nil
		end
		local point, _, relativePoint, x, y = frame:GetPoint(1)
		return point, relativePoint, x, y
	end
	function api.bindingAction(key)
		return safeCall(env.GetBindingAction, key, true)
	end
	function api.hasLdb()
		return type(env.LibStub) == 'table'
			and safeCall(env.LibStub.GetLibrary, env.LibStub, 'LibDataBroker-1.1', true) ~= nil
	end
	function api.ldbText(name)
		local broker = api.hasLdb() and env.LibStub:GetLibrary('LibDataBroker-1.1', true)
		local object = broker and broker:GetDataObjectByName(name)
		if object == nil then
			return false, nil
		end
		return true, object.text and tostring(object.text) or ''
	end
	function api.freeBagSlots()
		return countFreeBagSlots(env)
	end
	function api.inboxCount()
		return safeCall(env.GetInboxNumItems) or 0
	end
	function api.inboxHeaders()
		return readInboxHeaders(env)
	end
	function api.isInCombat()
		return safeCall(env.InCombatLockdown) == true
	end
	return api
end

-- Helpers ---------------------------------------------------------------------------------

function readLedgerCursors(db)
	local cursors = {}
	for marketKey, market in pairs(type(db.markets) == 'table' and db.markets or {}) do
		if type(market) == 'table' and type(market.ledger) == 'table' then
			cursors[marketKey] = #market.ledger
		end
	end
	return cursors
end

-- Advances the cursors (owned by the observer) and returns the rows past them.
function newLedgerRows(db, cursors)
	local rows = {}
	for marketKey, market in pairs(type(db.markets) == 'table' and db.markets or {}) do
		local ledger = type(market) == 'table' and market.ledger or nil
		if type(ledger) == 'table' then
			local cursor = cursors[marketKey] or 0
			if #ledger < cursor then
				cursor = #ledger
			end
			for index = cursor + 1, #ledger do
				if type(ledger[index]) == 'table' then
					rows[#rows + 1] = ns.Items.decodeLedgerRow(ledger[index])
				end
			end
			cursors[marketKey] = #ledger
		end
	end
	return rows
end

function packArgs(...)
	return { n = select('#', ...), ... }
end

-- Read at the take, while the mail is still there: its invoice type, bag room and the inbox.
function describeMailTake(env, args)
	local mailIndex = args[1]
	args.invoiceType = mailIndex and safeCall(env.GetInboxInvoiceInfo, mailIndex) or nil
	args.freeSlots = countFreeBagSlots(env)
	args.inboxCount = safeCall(env.GetInboxNumItems) or 0
	args.inboxHeaders = readInboxHeaders(env)
end

-- One 'sender: subject' per mail. Money is left out: a taken sale mail can stay, emptied.
function readInboxHeaders(env)
	local headers = {}
	for index = 1, safeCall(env.GetInboxNumItems) or 0 do
		local _, _, sender, subject = safeCall(env.GetInboxHeaderInfo, index)
		headers[#headers + 1] = tostring(sender) .. ': ' .. tostring(subject)
	end
	return headers
end

function countFreeBagSlots(env)
	local container = env.C_Container
	if type(container) ~= 'table' or type(container.GetContainerNumFreeSlots) ~= 'function' then
		return nil
	end
	local free = 0
	for bag = 0, BAG_COUNT do
		free = free + (safeCall(container.GetContainerNumFreeSlots, bag) or 0)
	end
	return free
end

-- Calls fn, or returns nil when it is missing or raises.
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
