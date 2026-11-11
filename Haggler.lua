--[[
	Haggler.lua: the bootstrap, loaded last. It opens the saved data once the game has loaded
	it, starts the host and registers /hag. Init.lua made the shared services, and the features
	registered their modules with ns.host before this runs.
]]
local addonName, ns = ...

-- Helpers live at the bottom of the file; declared here so they stay local.
local onAddonLoaded, printLines

ns.wow:OnEvent('ADDON_LOADED', function(_, loadedName)
	if loadedName ~= addonName then
		return
	end
	ns.wow:OffEvent('ADDON_LOADED')
	onAddonLoaded()
end)

-- Helpers ---------------------------------------------------------------------------------

function onAddonLoaded()
	HagglerDB = HagglerDB or {}
	HagglerCharDB = HagglerCharDB or {}
	local store, reason = ns.Store.open(HagglerDB, HagglerCharDB)
	if not store then
		ns.wow:Print('Saved data is from a newer Haggler (' .. reason .. '); update the add-on. Nothing was changed.')
		return
	end
	ns.store = store
	ns.host.Start(store:Settings())
	ns.wow:RegisterSlash(function(text)
		printLines(ns.host.RunCommand(text))
	end)
end

function printLines(lines)
	for _, line in ipairs(lines) do
		ns.wow:Print(line)
	end
end
