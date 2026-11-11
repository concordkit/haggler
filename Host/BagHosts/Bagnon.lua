--[[
	Bagnon (12.1.8): no plugin API. Item buttons get their class methods copied in (Mixin), so a
	hook on the item class only reaches buttons made later. The item group is hooked instead:
	after Bagnon.InventoryItemGroup:Layout and :ForBag the group's buttons are walked and painted
	from button:GetBag() and button:GetID(). The bag total sits above the inventory frame's money
	frame, attached the first time that frame really exists (it never does with money hidden).

	BagBrother can show another character's bags from its cache (group:IsCached()). The slots
	then read the player's own bags, so such a group is cleared, never painted.
]]
local _, ns = ...

local BagHosts = ns.BagHosts
local GROUP_METHODS = { 'Layout', 'ForBag' }
local INVENTORY_FRAME_ID = 'inventory'

-- Helpers live at the bottom of the file; declared here so they stay local.
local bagnonOf, paintGroup, attachTotal, isButton, isCachedGroup

local groups = setmetatable({}, { __mode = 'k' })
local state = { hasTotal = false }

local Bagnon = BagHosts.register({
	name = 'Bagnon',
	targets = 'Bagnon 12.1.8: Bagnon.InventoryItemGroup Layout / ForBag, Bagnon.Frames:Get(inventory)',
	detect = function(wow)
		return bagnonOf(wow) ~= nil
	end,
	attach = function(wow, view)
		local itemGroup = bagnonOf(wow).InventoryItemGroup
		local hooked = 0
		for _, method in ipairs(GROUP_METHODS) do
			local isHooked = wow:HookMethod(itemGroup, method, function(group)
				groups[group] = true
				paintGroup(group, view)
				attachTotal(wow, view)
			end)
			hooked = hooked + (isHooked and 1 or 0)
		end
		attachTotal(wow, view)
		return hooked > 0
	end,
	refresh = function(_, view)
		for group in pairs(groups) do
			paintGroup(group, view)
		end
	end,
})
ns.BagHostBagnon = Bagnon

-- Helpers ---------------------------------------------------------------------------------

function bagnonOf(wow)
	local bagnon = wow:Global('Bagnon')
	if type(bagnon) ~= 'table' or type(bagnon.InventoryItemGroup) ~= 'table' then
		return nil
	end
	return bagnon
end

-- group.buttons is a list or a bag -> slot map depending on the version: both are walked.
function paintGroup(group, view)
	local buttons = type(group) == 'table' and group.buttons or nil
	if type(buttons) ~= 'table' then
		return
	end
	local isCached = isCachedGroup(group)
	local function paint(button)
		if isCached then
			view:ClearSlot(button)
		else
			view:PaintSlot(button, button:GetBag(), button:GetID())
		end
	end
	for _, entry in pairs(buttons) do
		if isButton(entry) then
			paint(entry)
		elseif type(entry) == 'table' then
			for _, button in pairs(entry) do
				if isButton(button) then
					paint(button)
				end
			end
		end
	end
end

function attachTotal(wow, view)
	if state.hasTotal then
		return
	end
	local frames = bagnonOf(wow) and bagnonOf(wow).Frames
	if type(frames) ~= 'table' or type(frames.Get) ~= 'function' then
		return
	end
	local ok, frame = pcall(frames.Get, frames, INVENTORY_FRAME_ID)
	if ok and BagHosts.totalAboveMoney(frame, view) then
		state.hasTotal = true
	end
end

function isCachedGroup(group)
	if type(group.IsCached) ~= 'function' then
		return false
	end
	local ok, isCached = pcall(group.IsCached, group)
	-- When the owner cannot be read, painting could show the player's values on an alt: skip.
	return not ok or isCached == true
end

function isButton(value)
	return type(value) == 'table' and type(value.GetBag) == 'function' and type(value.GetID) == 'function'
end

return Bagnon
