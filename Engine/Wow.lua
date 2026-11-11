--[[
	Wow: the only door from the engine to the game's API. Everything else in Engine/ takes a wow
	object (or plain data) as an argument, so luajit tests pass a fake environment instead of _G.

	Step 1: time, item info, the player's market, printing, events and the slash command.
	Step 2: the auction house replicate list (the full scan), timers, a frame clock, modifier
	keys and item tooltips. Container and mail wrappers arrive with the steps that use them.

	Forever runs the Mainline UI, so these follow retail's C_AuctionHouse (AHledger 0.14, Auctionator
	and TSM make the same calls there). Each wrapper checks the API exists and answers nil / false
	when it does not, so a client without it degrades instead of erroring.

	GetReplicateItemInfo(index) is 0-based and returns, in order: name, texture, count, quality,
	usable, level, levelType, minBid, minIncrement, buyoutPrice, bidAmount, highBidder,
	bidderFullName, owner, ownerFullName, saleStatus, itemID, hasAllInfo. buyoutPrice is for the
	whole listing (count units), 0 on a bid-only listing.
]]
local _, ns = ...

local Wow = {}
ns.Wow = Wow

-- GetCurrentRegion() ids to AHledger's region slugs.
local REGION_SLUGS = { [1] = 'us', [2] = 'kr', [3] = 'eu', [4] = 'tw', [5] = 'cn' }
local CHAT_PREFIX = '|cffd4a017Haggler|r: '
local DEFAULT_EVENT_OWNER = 'main'
local MODIFIER_CHECKS = { shift = 'IsShiftKeyDown', ctrl = 'IsControlKeyDown', alt = 'IsAltKeyDown' }
local ITEM_TOOLTIP_NAMES = { 'GameTooltip', 'ItemRefTooltip', 'ShoppingTooltip1', 'ShoppingTooltip2' }

-- Helpers live at the bottom of the file; declared here so they stay local.
local dispatchEvent, itemIdFromLink, itemIdFromTooltip, stackCountFromOwner, timeLeftBand, isSecret
local isInCombat

local WowMethods = {}
WowMethods.__index = WowMethods

--- Wraps a game environment.
--- @param env table|nil the global table; _G in game, a fake in tests
--- @param options table|nil { onError = fun(where, err) } for errors in event handlers
--- @return table wow
function Wow.create(env, options)
	return setmetatable({
		env = env or _G,
		eventHandlers = {},
		onError = options and options.onError,
		tooltipHandlers = {},
	}, WowMethods)
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

--- The price tables the desktop app saved (Data/PriceTable.lua), or nil when none are loaded.
--- @return table|nil HagglerPriceTable
function WowMethods:SavedPriceTables()
	local saved = self.env.HagglerPriceTable
	return type(saved) == 'table' and saved or nil
end

--- Calls handler(event, ...) for a game event. Each owner has one handler per event, so the
--- scan and the bootstrap can both listen to the same event. A handler that throws is reported
--- through onError and does not stop the others. The hidden event frame is the one frame the
--- engine owns; it draws nothing.
--- @param event string
--- @param handler function
--- @param owner string|nil default 'main'
function WowMethods:OnEvent(event, handler, owner)
	if type(handler) ~= 'function' then
		error('Wow:OnEvent: handler must be a function', 2)
	end
	if not self.eventFrame then
		self.eventFrame = self.env.CreateFrame('Frame')
		self.eventFrame:SetScript('OnEvent', function(_, firedEvent, ...)
			dispatchEvent(self, firedEvent, ...)
		end)
	end
	local handlers = self.eventHandlers[event] or {}
	self.eventHandlers[event] = handlers
	handlers[owner or DEFAULT_EVENT_OWNER] = handler
	self.eventFrame:RegisterEvent(event)
end

--- Drops an owner's handler; the frame stops listening once no owner is left.
function WowMethods:OffEvent(event, owner)
	local handlers = self.eventHandlers[event]
	if not handlers then
		return
	end
	handlers[owner or DEFAULT_EVENT_OWNER] = nil
	if next(handlers) == nil then
		self.eventHandlers[event] = nil
		if self.eventFrame then
			self.eventFrame:UnregisterEvent(event)
		end
	end
end

--- Registers /hag. The handler gets the text after the command.
function WowMethods:RegisterSlash(handler)
	self.env.SLASH_HAGGLER1 = '/hag'
	self.env.SlashCmdList.HAGGLER = handler
end

-- Timers and the frame clock ---------------------------------------------------------------

--- Runs fn after a delay (0 = next frame). Returns false when the client has no C_Timer.
function WowMethods:After(seconds, fn)
	local timer = self.env.C_Timer
	if not (timer and timer.After) then
		return false
	end
	timer.After(seconds, fn)
	return true
end

--- A millisecond clock for per-frame budgets, or nil when the client has none.
function WowMethods:ClockMs()
	local clock = self.env.debugprofilestop
	return clock and clock() or nil
end

-- Auction house ---------------------------------------------------------------------------

--- True when the client can request a full scan (C_AuctionHouse.ReplicateItems).
function WowMethods:CanReplicate()
	local auctionHouse = self.env.C_AuctionHouse
	return auctionHouse ~= nil and type(auctionHouse.ReplicateItems) == 'function'
end

--- Asks the server for the full listing. The answer is REPLICATE_ITEM_LIST_UPDATE, or
--- AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED when it refuses.
--- @return boolean sent
--- @return string|nil reason when not sent
function WowMethods:RequestReplicate()
	if not self:CanReplicate() then
		return false, 'no C_AuctionHouse.ReplicateItems on this client'
	end
	local ok, err = pcall(self.env.C_AuctionHouse.ReplicateItems)
	if not ok then
		return false, tostring(err)
	end
	return true
end

--- Listings in the replicate list now (0 when none or no API).
function WowMethods:NumReplicateItems()
	local auctionHouse = self.env.C_AuctionHouse
	local count = auctionHouse and auctionHouse.GetNumReplicateItems and auctionHouse.GetNumReplicateItems()
	return type(count) == 'number' and count or 0
end

--- One listing of the replicate list, as raw values (no table, so a 150,000-row read makes no
--- garbage). Nothing is checked here; ScanStore drops junk.
--- @param index number 0-based
--- The seller is not read: during a replicate read the client often has not loaded it yet.
--- @return any itemId, any count, any buyout total for the listing, any bid
--- @return number|nil timeLeft the internal band, 1 (short) to 4 (very long), nil when unknown
function WowMethods:ReplicateItem(index)
	local auctionHouse = self.env.C_AuctionHouse
	local _, _, count, _, _, _, _, _, _, buyout, bid, _, _, _, _, _, itemId = auctionHouse.GetReplicateItemInfo(index)
	local getTimeLeft = auctionHouse.GetReplicateItemTimeLeft
	return itemId, count, buyout, bid, timeLeftBand(getTimeLeft and getTimeLeft(index))
end

--- Asks the client to load an item it has not cached; ItemInfo answers once it has.
--- @param itemId number
--- @return boolean requested
function WowMethods:RequestItemData(itemId)
	local requestLoad = self.env.C_Item and self.env.C_Item.RequestLoadItemDataByID
	if not requestLoad or type(itemId) ~= 'number' then
		return false
	end
	return (pcall(requestLoad, itemId))
end

--- The item link of one listing, or nil.
function WowMethods:ReplicateItemLink(index)
	local auctionHouse = self.env.C_AuctionHouse
	local getLink = auctionHouse and auctionHouse.GetReplicateItemLink
	return getLink and getLink(index) or nil
end

-- Input -----------------------------------------------------------------------------------

--- True while a modifier is held. A gamepad modifier counts when the client maps it to Shift,
--- Ctrl or Alt (the GamePadEmulateShift / Ctrl / Alt settings).
--- @param name string 'shift' | 'ctrl' | 'alt'
function WowMethods:IsModifierDown(name)
	local check = MODIFIER_CHECKS[name] and self.env[MODIFIER_CHECKS[name]]
	return check ~= nil and check() == true
end

-- Tooltips --------------------------------------------------------------------------------

--- Calls handler(tooltip, itemId, stackCount) after every item tooltip is built. The client
--- cannot unhook, so the hook is installed once and later calls only add handlers; a removed
--- handler is simply not called.
--- TooltipDataProcessor (Forever and Classic Era 1.15+) is preferred; OnTooltipSetItem is the
--- fallback on older clients.
--- @param owner string
--- @param handler function|nil nil removes the owner's handler
--- @return string|nil hook 'processor' | 'script', or nil when the client has neither
function WowMethods:HookItemTooltips(owner, handler)
	self.tooltipHandlers[owner] = handler
	if not self.tooltipHook then
		self.tooltipHook = self:InstallTooltipHook()
	end
	return self.tooltipHook
end

function WowMethods:InstallTooltipHook()
	local env = self.env
	-- Runs inside the client's tooltip code: nothing may escape it.
	local onTooltip = function(tooltip, data)
		local ok, err = pcall(self.HandleItemTooltip, self, tooltip, data)
		if not ok and self.onError then
			self.onError('tooltip hook', err)
		end
	end
	local processor = env.TooltipDataProcessor
	local dataTypes = env.Enum and env.Enum.TooltipDataType
	if processor and processor.AddTooltipPostCall and dataTypes and dataTypes.Item then
		processor.AddTooltipPostCall(dataTypes.Item, onTooltip)
		return 'processor'
	end
	local isHooked = false
	for _, name in ipairs(ITEM_TOOLTIP_NAMES) do
		local tooltip = env[name]
		if tooltip and tooltip.HookScript then
			tooltip:HookScript('OnTooltipSetItem', onTooltip)
			isHooked = true
		end
	end
	return isHooked and 'script' or nil
end

--- Finds the item and stack of a built tooltip and runs every handler on it. Secret values
--- (issecretvalue, on clients that have it) are never read.
function WowMethods:HandleItemTooltip(tooltip, data)
	if not tooltip or (tooltip.IsForbidden and tooltip:IsForbidden()) then
		return
	end
	local env = self.env
	local itemId = itemIdFromTooltip(env, tooltip, data)
	if not itemId then
		return
	end
	local stackCount = stackCountFromOwner(env, tooltip, itemId)
	for handlerOwner, handler in pairs(self.tooltipHandlers) do
		local ok, err = pcall(handler, tooltip, itemId, stackCount)
		if not ok and self.onError then
			self.onError('tooltip ' .. handlerOwner, err)
		end
	end
end

--- Rebuilds the shown item tooltip so a modifier change shows at once. Uses the tooltip's own
--- RefreshData (Mainline UI), which re-runs the data and the post-calls without calling the
--- owner's OnEnter: running another frame's OnEnter from add-on code taints protected buttons.
--- Only an item tooltip is rebuilt, and never in combat.
--- @return boolean refreshed
function WowMethods:RefreshItemTooltip()
	local env = self.env
	local tooltip = env.GameTooltip
	if not tooltip or (tooltip.IsForbidden and tooltip:IsForbidden()) or isInCombat(env) then
		return false
	end
	if type(tooltip.GetItem) ~= 'function' then
		return false
	end
	local _, link = tooltip:GetItem()
	if link == nil or isSecret(env, link) then
		return false
	end
	if not (tooltip.IsShown and tooltip:IsShown()) or type(tooltip.RefreshData) ~= 'function' then
		return false
	end
	local ok = pcall(tooltip.RefreshData, tooltip)
	return ok
end

-- Helpers ---------------------------------------------------------------------------------

function dispatchEvent(wow, event, ...)
	local handlers = wow.eventHandlers[event]
	if not handlers then
		return
	end
	-- Copied first: a handler may unregister itself (ADDON_LOADED does).
	local snapshot = {}
	for owner, handler in pairs(handlers) do
		snapshot[#snapshot + 1] = { owner = owner, handler = handler }
	end
	for _, entry in ipairs(snapshot) do
		local ok, err = pcall(entry.handler, event, ...)
		if not ok then
			if not wow.onError then
				error(err, 0)
			end
			wow.onError(entry.owner .. ' ' .. event, err)
		end
	end
end

function itemIdFromLink(link)
	local id = type(link) == 'string' and link:match('item:(%d+)')
	return id and tonumber(id) or nil
end

-- The item of a tooltip: the post-call's data block first (comparison tooltips have no
-- GetItem), else the tooltip's own item link.
function itemIdFromTooltip(env, tooltip, data)
	local fromData = type(data) == 'table' and data.id
	if type(fromData) == 'number' and not isSecret(env, fromData) and fromData > 0 then
		return fromData
	end
	if tooltip.GetItem then
		local _, link = tooltip:GetItem()
		local fromLink = not isSecret(env, link) and itemIdFromLink(link) or nil
		if fromLink then
			return fromLink
		end
	end
	local guid = type(data) == 'table' and data.guid
	local getLinkByGuid = env.C_Item and env.C_Item.GetItemLinkByGUID
	if guid and getLinkByGuid and not isSecret(env, guid) then
		return itemIdFromLink(getLinkByGuid(guid))
	end
	return nil
end

-- How many units the hovered stack holds: from the bag slot the tooltip is anchored to, when
-- that slot holds the same item, else 1. Reads only (GetBagID / GetID / container info), never
-- calls the owner's scripts. The item check guards against an owner whose ids are not a bag slot.
function stackCountFromOwner(env, tooltip, itemId)
	local owner = tooltip.GetOwner and tooltip:GetOwner()
	if type(owner) ~= 'table' then
		return 1
	end
	local container = env.C_Container
	local slot = owner.GetID and owner:GetID()
	local bag = owner.GetBagID and owner:GetBagID()
	if bag == nil and owner.GetParent then
		local parent = owner:GetParent()
		bag = type(parent) == 'table' and parent.GetID and parent:GetID() or nil
	end
	if not (container and container.GetContainerItemInfo and type(bag) == 'number' and type(slot) == 'number') then
		return 1
	end
	local ok, info = pcall(container.GetContainerItemInfo, bag, slot)
	local isSameItem = ok and type(info) == 'table' and not isSecret(env, info.itemID) and info.itemID == itemId
	local count = isSameItem and info.stackCount
	return type(count) == 'number' and not isSecret(env, count) and count >= 1 and count or 1
end

-- The client's time-left value as the internal band, 1 (short) to 4 (very long). Forever's
-- GetReplicateItemTimeLeft gives 1 to 4 (AHledger's saved scans hold only 1 to 4, and
-- AuctionSellSpeed notes it is one more than Enum.AuctionHouseTimeLeftBand); anything else is
-- unknown.
function timeLeftBand(raw)
	if type(raw) == 'number' and raw >= 1 and raw <= 4 and raw % 1 == 0 then
		return raw
	end
	return nil
end

function isSecret(env, value)
	local check = env.issecretvalue
	return check ~= nil and check(value) == true
end

function isInCombat(env)
	local check = env.InCombatLockdown
	return check ~= nil and check() == true
end

return Wow
