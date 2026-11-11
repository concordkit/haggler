--[[
	Wow: the only door from the engine to the game's API. Everything else in Engine/ takes a wow
	object (or plain data) as an argument, so luajit tests pass a fake environment instead of _G.

	Step 1 covers what the core needs: time, item info, the player's market, printing, events
	and the slash command. Scan, container and mail wrappers arrive with the steps that use them.
]]
local _, ns = ...

local Wow = {}
ns.Wow = Wow

-- GetCurrentRegion() ids to AHledger's region slugs.
local REGION_SLUGS = { [1] = 'us', [2] = 'kr', [3] = 'eu', [4] = 'tw', [5] = 'cn' }
local CHAT_PREFIX = '|cffd4a017Haggler|r: '

local WowMethods = {}
WowMethods.__index = WowMethods

--- Wraps a game environment.
--- @param env table|nil the global table; _G in game, a fake in tests
--- @return table wow
function Wow.create(env)
	return setmetatable({ env = env or _G, eventHandlers = {} }, WowMethods)
end

--- Server time in whole seconds.
function WowMethods:Now()
	local env = self.env
	if env.GetServerTime then
		return env.GetServerTime()
	end
	return env.time()
end

--- Static item info, or nil while the client has not cached the item yet.
--- @param itemId number
--- @return table|nil { name, maxStack, vendorPrice }
function WowMethods:ItemInfo(itemId)
	if type(itemId) ~= 'number' then
		error('Wow:ItemInfo: itemId must be a number', 2)
	end
	local env = self.env
	local getItemInfo = (env.C_Item and env.C_Item.GetItemInfo) or env.GetItemInfo
	if not getItemInfo then
		return nil
	end
	local name, _, _, _, _, _, _, maxStack, _, _, vendorPrice = getItemInfo(itemId)
	if not name then
		return nil
	end
	return { name = name, maxStack = tonumber(maxStack), vendorPrice = tonumber(vendorPrice) or 0 }
end

--- The player's realm, faction and region, as the market key needs them.
--- @return table { name, realm, faction, region }
function WowMethods:Player()
	local env = self.env
	return {
		name = env.UnitName('player'),
		-- GetRealmName keeps the spaces the ruleset words need ("Wild Growth RP PvP"); the
		-- normalized name drops them, as AHledger's realm parsing does not.
		realm = env.GetRealmName(),
		faction = env.UnitFactionGroup('player'),
		region = REGION_SLUGS[env.GetCurrentRegion and env.GetCurrentRegion() or 1] or 'us',
	}
end

function WowMethods:Print(text)
	self.env.DEFAULT_CHAT_FRAME:AddMessage(CHAT_PREFIX .. tostring(text))
end

--- Calls handler(event, ...) for a game event. The hidden event frame is the one frame the
--- engine owns; it draws nothing.
function WowMethods:OnEvent(event, handler)
	if type(handler) ~= 'function' then
		error('Wow:OnEvent: handler must be a function', 2)
	end
	if not self.eventFrame then
		local handlers = self.eventHandlers
		self.eventFrame = self.env.CreateFrame('Frame')
		self.eventFrame:SetScript('OnEvent', function(_, firedEvent, ...)
			local handlerForEvent = handlers[firedEvent]
			if handlerForEvent then
				handlerForEvent(firedEvent, ...)
			end
		end)
	end
	self.eventHandlers[event] = handler
	self.eventFrame:RegisterEvent(event)
end

function WowMethods:OffEvent(event)
	self.eventHandlers[event] = nil
	if self.eventFrame then
		self.eventFrame:UnregisterEvent(event)
	end
end

--- Registers /hag. The handler gets the text after the command.
function WowMethods:RegisterSlash(handler)
	self.env.SLASH_HAGGLER1 = '/hag'
	self.env.SlashCmdList.HAGGLER = handler
end

return Wow
