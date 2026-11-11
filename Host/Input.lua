--[[
	Input: the only caller of SetOverrideBinding* (through ns.wow). Frames ask it for keys
	instead of binding them themselves, so Haggler's bindings stay in one place and never fight.

	  Input.new(wow) -> input
	  input:Bind(owner, key, onPress) -> boolean   a key (a settings binding, e.g. CTRL-SHIFT-H or
	                                               PADLSHOULDER) runs onPress; '' or nil unbinds.
	                                               false when it waits for combat to end
	  input:Unbind(owner)
	  input:RequestFocus(owner, handlers) -> boolean   while focused, the pad's d-pad and the
	                                               arrow keys move (handlers.next / .previous),
	                                               A and Enter press (.activate), B and Escape
	                                               leave (.leave, then the focus is released)
	  input:ReleaseFocus(owner)
	  input:HasFocus(owner) -> boolean

	Override bindings cannot change in combat. A Bind asked for in combat is kept and applied
	when combat ends (PLAYER_REGEN_ENABLED); a focus cannot start in combat, and one held when
	combat starts is left (PLAYER_REGEN_DISABLED still allows the change). A clear the client
	refuses (an Unbind or a leave in combat) is kept and retried when combat ends, so no key
	stays overridden; until then the focus keys do nothing. A key clicks a hidden named button,
	so the binding needs no secure code of Haggler's own.
]]
local _, ns = ...

local Input = {}
ns.Input = Input

Input.FOCUS_KEYS = {
	next = { 'PADDRIGHT', 'PADDDOWN', 'RIGHT', 'DOWN' },
	previous = { 'PADDLEFT', 'PADDUP', 'LEFT', 'UP' },
	activate = { 'PAD1', 'ENTER' },
	leave = { 'PAD2', 'ESCAPE' },
}
local FOCUS_ACTIONS = { 'next', 'previous', 'activate', 'leave' }
local EVENT_OWNER = 'input'

-- Helpers live at the bottom of the file; declared here so they stay local.
local ownerFrame, pressButton, applyBinding, isKey, clearFrame, retryClears, leaveFocus

local InputMethods = {}
InputMethods.__index = InputMethods

--- @param wow table the game wrapper (Engine/Wow.lua)
--- @return table input
function Input.new(wow)
	if type(wow) ~= 'table' then
		error('Input.new: needs wow', 2)
	end
	local input = setmetatable(
		{ wow = wow, frames = {}, buttons = {}, binds = {}, focus = nil, count = 0, pendingClears = {} },
		InputMethods
	)
	wow:OnEvent('PLAYER_REGEN_DISABLED', function()
		leaveFocus(input)
	end, EVENT_OWNER)
	wow:OnEvent('PLAYER_REGEN_ENABLED', function()
		retryClears(input)
		for owner in pairs(input.binds) do
			applyBinding(input, owner)
		end
	end, EVENT_OWNER)
	return input
end

--- Binds a key for an owner; the owner's previous key is dropped.
--- @param owner string
--- @param key string|nil a key name; '' or nil unbinds
--- @param onPress function
--- @return boolean applied now (false: waits for combat to end, or nothing to bind)
function InputMethods:Bind(owner, key, onPress)
	if type(owner) ~= 'string' or owner == '' then
		error('Input:Bind: needs an owner', 2)
	end
	if not isKey(key) then
		self:Unbind(owner)
		return false
	end
	if type(onPress) ~= 'function' then
		error('Input:Bind: needs onPress', 2)
	end
	self.binds[owner] = { key = key, onPress = onPress, isApplied = false }
	return applyBinding(self, owner)
end

function InputMethods:Unbind(owner)
	self.binds[owner] = nil
	if self.frames['bind:' .. owner] then
		clearFrame(self, 'bind:' .. owner)
	end
end

--- Takes the pad and the arrow keys for one owner until it leaves or is released.
--- @param owner string
--- @param handlers table { next, previous, activate, leave } functions
--- @return boolean focused
function InputMethods:RequestFocus(owner, handlers)
	if type(owner) ~= 'string' or type(handlers) ~= 'table' then
		error('Input:RequestFocus: needs an owner and handlers', 2)
	end
	if self.wow:IsInCombat() then
		return false
	end
	if self.focus then
		self:ReleaseFocus(self.focus.owner)
	end
	if self.focus then
		return false
	end
	local frame = ownerFrame(self, 'focus')
	for _, action in ipairs(FOCUS_ACTIONS) do
		local buttonName = pressButton(self, 'focus:' .. action, function()
			local focus = self.focus
			if not focus or focus.isReleasing then
				return
			end
			if action == 'leave' then
				self:ReleaseFocus(focus.owner)
			end
			local handler = focus.handlers[action]
			if type(handler) == 'function' then
				handler()
			end
		end)
		for _, key in ipairs(Input.FOCUS_KEYS[action]) do
			self.wow:SetOverrideBindingClick(frame, key, buttonName)
		end
	end
	self.focus = { owner = owner, handlers = handlers }
	return true
end

-- The focus is dropped only once its keys are cleared; until then (combat) it is releasing:
-- the keys do nothing and the clear is retried when combat ends.
function InputMethods:ReleaseFocus(owner)
	if not self.focus or self.focus.owner ~= owner then
		return
	end
	self.focus.isReleasing = true
	if clearFrame(self, 'focus') then
		self.focus = nil
	end
end

function InputMethods:HasFocus(owner)
	return self.focus ~= nil and not self.focus.isReleasing and self.focus.owner == owner
end

-- Helpers ---------------------------------------------------------------------------------

-- The frame that owns one set of override bindings (one per bound owner, one for the focus).
function ownerFrame(input, name)
	local frame = input.frames[name]
	if not frame then
		frame = input.wow:CreateFrame('Frame', input.wow.env.UIParent)
		input.frames[name] = frame
	end
	return frame
end

-- A hidden named button whose click runs fn (a click binding needs a button by name). The
-- button is made once per name; a later call only swaps what it runs.
function pressButton(input, name, fn)
	local entry = input.buttons[name]
	if not entry then
		input.count = input.count + 1
		local buttonName = 'HagglerInputButton' .. input.count
		local button = input.wow:CreateFrame('Button', input.wow.env.UIParent, nil, buttonName)
		button:Hide()
		entry = { button = button, name = buttonName }
		button:SetScript('OnClick', function()
			if entry.fn then
				entry.fn()
			end
		end)
		input.buttons[name] = entry
	end
	entry.fn = fn
	return entry.name
end

function applyBinding(input, owner)
	local bind = input.binds[owner]
	if not bind or bind.isApplied then
		return bind ~= nil
	end
	local frame = ownerFrame(input, 'bind:' .. owner)
	local buttonName = pressButton(input, 'bind:' .. owner, function()
		local current = input.binds[owner]
		if current then
			current.onPress()
		end
	end)
	if not input.wow:ClearOverrideBindings(frame) then
		return false
	end
	bind.isApplied = input.wow:SetOverrideBindingClick(frame, bind.key, buttonName)
	return bind.isApplied
end

-- Clears one owner frame's bindings; a refused clear (combat) is retried when combat ends.
function clearFrame(input, name)
	if input.wow:ClearOverrideBindings(ownerFrame(input, name)) then
		input.pendingClears[name] = nil
		return true
	end
	input.pendingClears[name] = true
	return false
end

function retryClears(input)
	for name in pairs(input.pendingClears) do
		local isBoundAgain = name ~= 'focus' and input.binds[name:sub(#'bind:' + 1)] ~= nil
		if isBoundAgain then
			-- A Bind asked for since: applyBinding clears the frame before binding.
			input.pendingClears[name] = nil
		else
			clearFrame(input, name)
		end
	end
	if input.focus and input.focus.isReleasing and not input.pendingClears.focus then
		input.focus = nil
	end
end

-- Combat is starting: the focus keys would be stuck for the fight, so the focus ends now and
-- its owner hears it as a leave.
function leaveFocus(input)
	local focus = input.focus
	if not focus or focus.isReleasing then
		return
	end
	input:ReleaseFocus(focus.owner)
	if type(focus.handlers.leave) == 'function' then
		focus.handlers.leave()
	end
end

function isKey(key)
	return type(key) == 'string' and key ~= ''
end
