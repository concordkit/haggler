--[[
	BagPad (1.4.0): restyles Blizzard's combined bags in place (the Blizzard adapter already
	paints its buttons) and relays its own NATIVE_UPDATE message after it lays the frame out again.
	This adapter repaints on that message so badges follow BagPad's layout. BagPad stands down
	when Bagnon or Baganator is loaded, and then so does this adapter.

	Per BagPad's rules for other add-ons: no frames created inside the native bag frame while it is
	open (textures and font strings only), post-hooks only, no fields written onto its frames.
]]
local _, ns = ...

local OWNER = 'Haggler'
local UPDATE_MESSAGE = 'NATIVE_UPDATE'

-- Helpers live at the bottom of the file; declared here so they stay local.
local bagPadOf

ns.BagHosts.register({
	name = 'BagPad',
	targets = 'BagPad 1.4.0: BagPad.Native.frame, BagPad.Events NATIVE_UPDATE',
	detect = function(wow)
		local bagPad = bagPadOf(wow)
		return bagPad ~= nil and type(bagPad.Events.Listen) == 'function'
	end,
	attach = function(wow, view)
		local bagPad = bagPadOf(wow)
		bagPad.Events:Listen(UPDATE_MESSAGE, OWNER, function()
			ns.BagHostBlizzard.paintFrame(bagPad.Native.frame, view)
		end)
		return true
	end,
	refresh = function(wow, view)
		local bagPad = bagPadOf(wow)
		if bagPad then
			ns.BagHostBlizzard.paintFrame(bagPad.Native.frame, view)
		end
	end,
})

-- Helpers ---------------------------------------------------------------------------------

function bagPadOf(wow)
	local bagPad = wow:Global('BagPad')
	local isUsable = type(bagPad) == 'table'
		and type(bagPad.Events) == 'table'
		and type(bagPad.Native) == 'table'
		and type(bagPad.Native.frame) == 'table'
	return isUsable and bagPad or nil
end
