--[[
	Bus: the message bus. It says "something happened" (SCAN_READY, capability:added); the
	capability registry in Host.lua answers "what is the value now".

	Every listener belongs to an owner (a module key), so a disabled module's listeners can be
	dropped in one call. Handlers run under pcall: one failing handler never stops the others,
	and its error is reported to the bus's onError callback against its owner.
]]
local _, ns = ...

local Bus = {}
ns.Bus = Bus

-- Helpers live at the bottom of the file; declared here so they stay local.
local withoutOwner, assertName

local BusMethods = {}
BusMethods.__index = BusMethods

--- Creates a bus.
--- @param onError fun(owner: string, message: string, err: string)|nil called when a handler fails
--- @return table bus
function Bus.new(onError)
	if onError ~= nil and type(onError) ~= 'function' then
		error('Bus.new: onError must be a function or nil', 2)
	end
	return setmetatable({ listenersByMessage = {}, onError = onError }, BusMethods)
end

--- Adds or replaces the owner's handler for a message (one handler per owner and message).
--- @param owner string module key
--- @param message string
--- @param handler fun(message: string, ...)
function BusMethods:Listen(owner, message, handler)
	assertName(owner, 'owner')
	assertName(message, 'message')
	if type(handler) ~= 'function' then
		error('Bus:Listen: handler must be a function', 2)
	end
	local listeners = self.listenersByMessage[message]
	if not listeners then
		listeners = {}
		self.listenersByMessage[message] = listeners
	end
	for _, listener in ipairs(listeners) do
		if listener.owner == owner then
			listener.handler = handler
			return
		end
	end
	listeners[#listeners + 1] = { owner = owner, handler = handler }
end

--- Removes the owner's handler for a message; a no-op when there is none.
function BusMethods:Unlisten(owner, message)
	local listeners = self.listenersByMessage[message]
	if not listeners then
		return
	end
	self.listenersByMessage[message] = withoutOwner(listeners, owner)
end

--- Removes every handler the owner has.
function BusMethods:UnlistenAll(owner)
	for message, listeners in pairs(self.listenersByMessage) do
		self.listenersByMessage[message] = withoutOwner(listeners, owner)
	end
end

--- Sends a message to every listener, in the order they subscribed. Listeners added, replaced or
--- removed while it is being sent take effect from the next send.
--- @return number handlers that ran without error
function BusMethods:Send(message, ...)
	assertName(message, 'message')
	local listeners = self.listenersByMessage[message]
	if not listeners then
		return 0
	end
	local snapshot = {}
	for index, listener in ipairs(listeners) do
		snapshot[index] = { owner = listener.owner, handler = listener.handler }
	end
	local delivered = 0
	for _, listener in ipairs(snapshot) do
		local ok, err = pcall(listener.handler, message, ...)
		if ok then
			delivered = delivered + 1
		elseif self.onError then
			self.onError(listener.owner, message, tostring(err))
		end
	end
	return delivered
end

--- Number of listeners for a message (diagnostics and tests).
function BusMethods:ListenerCount(message)
	local listeners = self.listenersByMessage[message]
	return listeners and #listeners or 0
end

-- Helpers ---------------------------------------------------------------------------------

-- Returns a new list, so a Send already iterating the old one is not disturbed.
function withoutOwner(listeners, owner)
	local kept = {}
	for _, listener in ipairs(listeners) do
		if listener.owner ~= owner then
			kept[#kept + 1] = listener
		end
	end
	return kept
end

function assertName(value, what)
	if type(value) ~= 'string' or value == '' then
		error(string.format('Bus: %s must be a non-empty string', what), 3)
	end
end

return Bus
