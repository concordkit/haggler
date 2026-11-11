--[[
	Blizzard bags (Mainline UI, interface 16001): the combined backpack and the separate bag
	frames ContainerFrame1..N. Each frame's UpdateItems is post-hooked; the hook walks the frame's
	EnumerateValidItems and paints each button from its bag and slot (GetBagID / GetID). The bag
	total sits above the combined bags' money frame and the backpack's.

	BagPad (1.4.0) restyles ContainerFrameCombinedBags in place, so this adapter covers it too;
	Host/BagHosts/BagPad.lua only adds BagPad's own update message.
]]
local _, ns = ...

local BagHosts = ns.BagHosts

-- Mainline has 13 container frames (bags, reagent bag, bank bags); missing ones are skipped.
local CONTAINER_FRAME_COUNT = 13
local COMBINED = 'ContainerFrameCombinedBags'
local TOTAL_FRAMES = { 'ContainerFrameCombinedBags', 'ContainerFrame1' }

-- Helpers live at the bottom of the file; declared here so they stay local.
local bagFrames

local Blizzard = BagHosts.register({
	name = 'Blizzard',
	targets = 'Mainline 16001: ContainerFrameCombinedBags, ContainerFrame1..13',
	detect = function(wow)
		return #bagFrames(wow) > 0
	end,
	attach = function(wow, view)
		local hooked = 0
		for _, frame in ipairs(bagFrames(wow)) do
			local isHooked = wow:HookMethod(frame, 'UpdateItems', function(updated)
				ns.BagHostBlizzard.paintFrame(updated, view)
			end)
			hooked = hooked + (isHooked and 1 or 0)
		end
		for _, name in ipairs(TOTAL_FRAMES) do
			BagHosts.totalAboveMoney(wow:Global(name), view)
		end
		return hooked > 0
	end,
	refresh = function(wow, view)
		for _, frame in ipairs(bagFrames(wow)) do
			if type(frame.IsShown) ~= 'function' or frame:IsShown() then
				ns.BagHostBlizzard.paintFrame(frame, view)
			end
		end
	end,
})
ns.BagHostBlizzard = Blizzard

--- Paints every item button of one bag frame.
function Blizzard.paintFrame(frame, view)
	return BagHosts.eachValidItem(frame, function(button)
		local bag = type(button.GetBagID) == 'function' and button:GetBagID() or nil
		local slot = type(button.GetID) == 'function' and button:GetID() or nil
		view:PaintSlot(button, bag, slot)
	end)
end

-- Helpers ---------------------------------------------------------------------------------

function bagFrames(wow)
	local frames = {}
	local combined = wow:Global(COMBINED)
	if type(combined) == 'table' then
		frames[#frames + 1] = combined
	end
	for index = 1, CONTAINER_FRAME_COUNT do
		local frame = wow:Global('ContainerFrame' .. index)
		if type(frame) == 'table' then
			frames[#frames + 1] = frame
		end
	end
	return frames
end

return Blizzard
