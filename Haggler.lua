--[[
	Haggler.lua: the bootstrap, loaded last. It opens the saved data once the game has loaded
	it, starts the host and registers /hag (plain /hag opens the Haggler window). Init.lua made
	the shared services, and the features registered their modules with ns.host before this runs.
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
		-- A plain /hag opens and closes the window; with the window off it lists the commands.
		local isPlain = (text or ''):match('^%s*$') ~= nil
		if isPlain and ns.window and ns.host.IsEnabled('window') then
			ns.window:Toggle()
			return
		end
		printLines(ns.host.RunCommand(text))
	end)
end

function printLines(lines)
	for _, line in ipairs(lines) do
		ns.wow:Print(line)
	end
end
