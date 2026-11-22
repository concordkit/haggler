--[[
	WowTracking: the game reads step 5's bookkeeping needs, added to the wow object (Engine/Wow.lua).
	Like the rest of Wow, every wrapper checks the API exists, calls it under pcall and answers
	nil / {} when the client cannot say, so a missing API degrades instead of erroring.

	  ItemCount(itemId)              units in bags and bank
	  OwnedAuctions()                { { auctionId, itemId, qty, isSold } } | nil
	  AuctionItem(auctionId)         { itemId, qty } | nil   an auction seen in a search
	  ItemIdAt(location)             the item at an ItemLocation
	  SlotKey(location)              'bag:slot' of a bag ItemLocation | nil
	  PostDeposit(location, itemId, hours, qty, isCommodity)  the client's deposit | nil
	  InboxCount()                   mails shown in the inbox, nil when the client cannot say
	  InboxHeader(index)             { subject, money, hasItem, daysLeft } | nil
	  InboxInvoice(index)            { invoiceType, itemName, bid, deposit, cut, count } | nil
	  InboxItems(index, attachment?) { { itemId, count } }
	  MerchantItem(index)            { itemId, price, stack, hasExtendedCost } | nil
	  IsMerchantOpen()
	  RecipeSchematic(recipeId)      { recipeId, outputItemId, quantity, reagents = { { itemId, qty } } } | nil
	  KnownRecipeIds()               the open profession's learned recipe ids, {} when it cannot say
	  CursorItemId()                 the item on the cursor | nil
	  HookTable(name, method, fn)    post-hooks a method of a global table (C_AuctionHouse...)
	  ResetTimes(now)                { daily, weekly, localDay, localWeek } unix seconds of the last
	                                 daily and weekly reset, of local midnight and of local midnight
	                                 six days back (nil when unknown; DST-safe, Ledger.localMidnight)
	  Money()                        copper on hand, nil when the client cannot say
	  CancelAuction(auctionId)       true when sent (protected: from a click only)
	  Library(name)                  a LibStub library, nil when LibStub or it is missing
	  SetOverrideBindingClick(owner, key, buttonName) · ClearOverrideBindings(owner)
	                                 false in combat (only Host/Input.lua calls these)
]]
local _, ns = ...

local Methods = ns.Wow.Methods

local MAX_ATTACHMENTS = 16
local BASIC_REAGENT = 1
local AUCTION_STATUS_SOLD = 1
local SECONDS_PER_DAY = 86400
local SECONDS_PER_WEEK = 7 * SECONDS_PER_DAY

-- Helpers live at the bottom of the file; declared here so they stay local.
local call, isWholePositive, basicReagents

--- Copper on hand, nil when the client cannot say.
function Methods:Money()
	local money = call(self.env.GetMoney)
	return type(money) == 'number' and money >= 0 and money < math.huge and money or nil
end

--- Cancels one of the player's auctions; protected, so it runs straight from a click.
--- @return boolean sent
function Methods:CancelAuction(auctionId)
	local api = self.env.C_AuctionHouse
	if self:IsInCombat() or not isWholePositive(auctionId) or type(api) ~= 'table' or not api.CancelAuction then
		return false
	end
	return (pcall(api.CancelAuction, auctionId))
end

--- A library registered with LibStub, or nil.
function Methods:Library(name)
	local libStub = self.env.LibStub
	if libStub == nil then
		return nil
	end
	local ok, library = pcall(libStub.GetLibrary, libStub, name, true)
	return ok and library or nil
end

--- Binds a key to click a named button while owner's bindings stand; false in combat.
function Methods:SetOverrideBindingClick(owner, key, buttonName)
	local set = self.env.SetOverrideBindingClick
	if self:IsInCombat() or type(set) ~= 'function' then
		return false
	end
	return (pcall(set, owner, true, key, buttonName, 'LeftButton'))
end

--- Drops every override binding of owner; false in combat (they stay until it ends).
function Methods:ClearOverrideBindings(owner)
	local clear = self.env.ClearOverrideBindings
	if self:IsInCombat() or type(clear) ~= 'function' then
		return false
	end
	return (pcall(clear, owner))
end

--- Units of an item in the bags and the bank, 0 when the client cannot say.
function Methods:ItemCount(itemId)
	local env = self.env
	local getCount = env.C_Item and env.C_Item.GetItemCount or env.GetItemCount
	local count = call(getCount, itemId, true)
	return type(count) == 'number' and count >= 0 and count or 0
end

--- The character's owned auctions as last sent by the server (OWNED_AUCTIONS_UPDATED).
--- @return table|nil { { auctionId, itemId, qty, isSold } }
function Methods:OwnedAuctions()
	local api = self.env.C_AuctionHouse
	if type(api) ~= 'table' or not api.GetNumOwnedAuctions or not api.GetOwnedAuctionInfo then
		return nil
	end
	local count = call(api.GetNumOwnedAuctions)
	if type(count) ~= 'number' then
		return nil
	end
	local sold = self.env.Enum and self.env.Enum.AuctionStatus and self.env.Enum.AuctionStatus.Sold
		or AUCTION_STATUS_SOLD
	local owned = {}
	for index = 1, count do
		local info = call(api.GetOwnedAuctionInfo, index)
		if type(info) == 'table' and isWholePositive(info.auctionID) then
			owned[#owned + 1] = {
				auctionId = info.auctionID,
				itemId = type(info.itemKey) == 'table' and info.itemKey.itemID or nil,
				qty = info.quantity,
				isSold = info.status == sold,
			}
		end
	end
	return owned
end

--- An auction from a search result: the item and quantity, for a bid on it.
function Methods:AuctionItem(auctionId)
	local api = self.env.C_AuctionHouse
	local info = type(api) == 'table' and call(api.GetAuctionInfoByID, auctionId) or nil
	if type(info) ~= 'table' or type(info.itemKey) ~= 'table' then
		return nil
	end
	return { itemId = info.itemKey.itemID, qty = info.quantity or 1 }
end

--- 'bag:slot' of a bag ItemLocation (the client's mixin, or a plain { bagID, slotIndex }).
function Methods:SlotKey(location)
	if type(location) ~= 'table' then
		return nil
	end
	local bag, slot = location.bagID or location.bag, location.slotIndex or location.slot
	if type(location.GetBagAndSlot) == 'function' then
		local ok, readBag, readSlot = pcall(location.GetBagAndSlot, location)
		if ok then
			bag, slot = readBag, readSlot
		end
	end
	if type(bag) ~= 'number' or type(slot) ~= 'number' then
		return nil
	end
	return bag .. ':' .. slot
end

--- The item at an ItemLocation.
function Methods:ItemIdAt(location)
	local env = self.env
	local itemId = env.C_Item and call(env.C_Item.GetItemID, location)
	return isWholePositive(itemId) and itemId or nil
end

--- The deposit the client charges for a listing, or nil when it cannot say.
function Methods:PostDeposit(location, itemId, duration, qty, isCommodity)
	local api = self.env.C_AuctionHouse
	if type(api) ~= 'table' then
		return nil
	end
	local deposit
	if isCommodity then
		deposit = call(api.CalculateCommodityDeposit, itemId, duration, qty)
	else
		deposit = call(api.CalculateItemDeposit, location, duration, qty)
	end
	return type(deposit) == 'number' and deposit >= 0 and deposit % 1 == 0 and deposit or nil
end

--- A mail's header.
function Methods:InboxCount()
	local env = self.env
	if type(env.GetInboxNumItems) ~= 'function' then
		return nil
	end
	local ok, shown = pcall(env.GetInboxNumItems)
	return ok and tonumber(shown) or nil
end

function Methods:InboxHeader(index)
	local env = self.env
	if type(env.GetInboxHeaderInfo) ~= 'function' then
		return nil
	end
	local ok, _, _, _, subject, money, _, daysLeft, hasItem = pcall(env.GetInboxHeaderInfo, index)
	if not ok or type(subject) ~= 'string' then
		return nil
	end
	return {
		subject = subject,
		money = tonumber(money) or 0,
		daysLeft = daysLeft,
		hasItem = hasItem ~= nil and hasItem ~= false,
	}
end

--- A mail's auction invoice: the server's figures for a sale or a win.
function Methods:InboxInvoice(index)
	local env = self.env
	if type(env.GetInboxInvoiceInfo) ~= 'function' then
		return nil
	end
	local ok, invoiceType, itemName, _, bid, _, deposit, consignment, _, _, _, count =
		pcall(env.GetInboxInvoiceInfo, index)
	if not ok or type(invoiceType) ~= 'string' then
		return nil
	end
	return {
		invoiceType = invoiceType,
		itemName = itemName,
		bid = tonumber(bid) or 0,
		deposit = tonumber(deposit) or 0,
		cut = tonumber(consignment) or 0,
		count = tonumber(count),
	}
end

--- A mail's attachments (one when attachment is given).
--- @return table { { itemId, count, attachment } }
function Methods:InboxItems(index, attachment)
	local env = self.env
	local items = {}
	if type(env.GetInboxItem) ~= 'function' then
		return items
	end
	local first, last = attachment or 1, attachment or (env.ATTACHMENTS_MAX_RECEIVE or MAX_ATTACHMENTS)
	for slot = first, last do
		local ok, _, itemId, _, count = pcall(env.GetInboxItem, index, slot)
		if ok and isWholePositive(itemId) and isWholePositive(count) then
			items[#items + 1] = { itemId = itemId, count = count, attachment = slot }
		end
	end
	return items
end

--- A merchant's item: price is for `stack` units.
function Methods:MerchantItem(index)
	local env = self.env
	local itemId = call(env.GetMerchantItemID, index)
	if not isWholePositive(itemId) then
		return nil
	end
	local merchant = env.C_MerchantFrame
	local info = merchant and call(merchant.GetItemInfo, index)
	if type(info) == 'table' then
		return {
			itemId = itemId,
			price = tonumber(info.price) or 0,
			stack = tonumber(info.stackCount) or 1,
			hasExtendedCost = info.hasExtendedCost == true,
		}
	end
	if type(env.GetMerchantItemInfo) ~= 'function' then
		return nil
	end
	local ok, _, _, price, stack, _, _, _, hasExtendedCost = pcall(env.GetMerchantItemInfo, index)
	if not ok then
		return nil
	end
	return {
		itemId = itemId,
		price = tonumber(price) or 0,
		stack = tonumber(stack) or 1,
		hasExtendedCost = hasExtendedCost == true,
	}
end

function Methods:IsMerchantOpen()
	local frame = self.env.MerchantFrame
	return type(frame) == 'table' and frame.IsShown ~= nil and frame:IsShown() == true
end

--- A recipe's basic reagents and output (C_TradeSkillUI.GetRecipeSchematic).
--- @return table|nil { recipeId, outputItemId, quantity, reagents = { { itemId, qty } } }
function Methods:RecipeSchematic(recipeId)
	local tradeSkill = self.env.C_TradeSkillUI
	local schematic = tradeSkill and call(tradeSkill.GetRecipeSchematic, recipeId, false)
	if type(schematic) ~= 'table' then
		return nil
	end
	local basic = self.env.Enum and self.env.Enum.CraftingReagentType and self.env.Enum.CraftingReagentType.Basic
		or BASIC_REAGENT
	return {
		recipeId = recipeId,
		outputItemId = isWholePositive(schematic.outputItemID) and schematic.outputItemID or nil,
		quantity = isWholePositive(schematic.quantityMin) and schematic.quantityMin or 1,
		reagents = basicReagents(schematic.reagentSlotSchematics, basic),
	}
end

--- The open profession's learned recipes (C_TradeSkillUI.GetAllRecipeIDs and GetRecipeInfo).
--- @return number[] recipe ids, {} when no profession is open or the client cannot say
function Methods:KnownRecipeIds()
	local tradeSkill = self.env.C_TradeSkillUI
	local recipeIds = tradeSkill and call(tradeSkill.GetAllRecipeIDs)
	if type(recipeIds) ~= 'table' then
		return {}
	end
	local known = {}
	for _, recipeId in ipairs(recipeIds) do
		local info = isWholePositive(recipeId) and call(tradeSkill.GetRecipeInfo, recipeId)
		if type(info) == 'table' and info.learned == true then
			known[#known + 1] = recipeId
		end
	end
	return known
end

--- The item on the cursor, or nil.
function Methods:CursorItemId()
	local ok, kind, itemId = pcall(self.env.GetCursorInfo or error)
	return ok and kind == 'item' and isWholePositive(itemId) and itemId or nil
end

--- Post-hooks a method of a global table (C_AuctionHouse.PostItem...); never taints it.
--- @return boolean hooked
function Methods:HookTable(name, method, handler)
	local object = self.env[name]
	return type(object) == 'table' and self:HookMethod(object, method, handler)
end

--- When the current day and week began, for "profit since the reset" and "today".
function Methods:ResetTimes(now)
	local env = self.env
	local times = {}
	local untilDaily = call(env.GetQuestResetTime)
	if type(untilDaily) == 'number' and untilDaily > 0 and untilDaily <= SECONDS_PER_DAY then
		times.daily = now + untilDaily - SECONDS_PER_DAY
	end
	local untilWeekly = env.C_DateAndTime and call(env.C_DateAndTime.GetSecondsUntilWeeklyReset)
	if type(untilWeekly) == 'number' and untilWeekly > 0 and untilWeekly <= SECONDS_PER_WEEK then
		times.weekly = now + untilWeekly - SECONDS_PER_WEEK
	end
	local clock = { date = env.date, time = env.time }
	times.localDay = ns.Ledger.localMidnight(now, clock)
	times.localWeek = ns.Ledger.localMidnight(now, clock, 6)
	return times
end

-- Helpers ---------------------------------------------------------------------------------

function call(fn, ...)
	if type(fn) ~= 'function' then
		return nil
	end
	local ok, result = pcall(fn, ...)
	return ok and result or nil
end

function isWholePositive(value)
	return type(value) == 'number' and value > 0 and value < math.huge and value % 1 == 0
end

function basicReagents(slots, basic)
	local reagents = {}
	for _, slot in ipairs(type(slots) == 'table' and slots or {}) do
		local first = type(slot) == 'table' and type(slot.reagents) == 'table' and slot.reagents[1]
		local isBasic = type(slot) == 'table' and (slot.reagentType == nil or slot.reagentType == basic)
		if
			isBasic
			and type(first) == 'table'
			and isWholePositive(first.itemID)
			and isWholePositive(slot.quantityRequired)
		then
			reagents[#reagents + 1] = { itemId = first.itemID, qty = slot.quantityRequired }
		end
	end
	return reagents
end
