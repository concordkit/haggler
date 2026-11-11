-- A fake game environment for Engine/Wow.lua: a clock, timers that run when the test says so,
-- an event frame, the auction house replicate list, modifier keys and item tooltips; since
-- step 3 also widgets (frames, textures, font strings), hooksecurefunc, bags, the trade window
-- and its partner.
local FakeGame = {}

-- Widgets ---------------------------------------------------------------------------------

--- A region that records what the add-on did to it: points, size, text, texture, colour,
--- shown state, scripts and children. Only methods the client really has are defined, so a
--- typo fails the test instead of passing silently.
function FakeGame.newWidget(kind, parent, template)
	local widget = {
		kind = kind,
		parent = parent,
		template = template,
		points = {},
		children = {},
		scripts = {},
		isShown = true,
		frameLevel = parent and parent.frameLevel and parent.frameLevel + 1 or 1,
	}
	-- A real region keeps its C object at [0]; adapters tell a region from a class table by it.
	widget[0] = newproxy(false)
	function widget:SetPoint(...)
		self.points[#self.points + 1] = { ... }
	end
	function widget:SetAllPoints(target)
		self.allPoints = target
	end
	function widget:ClearAllPoints()
		self.points = {}
	end
	function widget:SetSize(width, height)
		self.width, self.height = width, height
	end
	function widget:SetWidth(width)
		self.width = width
	end
	function widget:SetHeight(height)
		self.height = height
	end
	function widget:GetWidth()
		return self.width or 0
	end
	function widget:Show()
		self.isShown = true
	end
	function widget:Hide()
		self.isShown = false
	end
	function widget:IsShown()
		return self.isShown
	end
	function widget:GetParent()
		return self.parent
	end
	if kind == 'FontString' then
		function widget:SetText(text)
			self.text = text
		end
		function widget:GetText()
			return self.text
		end
		function widget:GetStringWidth()
			return self.text and #tostring(self.text) * 6 or 0
		end
		return widget
	end
	if kind == 'Texture' then
		function widget:SetTexture(path)
			self.texture = path
		end
		function widget:SetTexCoord(left, right, top, bottom)
			self.texcoords = { left, right, top, bottom }
		end
		function widget:SetVertexColor(r, g, b, a)
			self.color = { r, g, b, a }
		end
		return widget
	end
	function widget:CreateTexture(_, layer)
		local texture = FakeGame.newWidget('Texture', self)
		texture.layer = layer
		self.children[#self.children + 1] = texture
		return texture
	end
	function widget:CreateFontString(_, layer, fontTemplate)
		local text = FakeGame.newWidget('FontString', self)
		text.layer, text.fontTemplate = layer, fontTemplate
		self.children[#self.children + 1] = text
		return text
	end
	function widget:SetScript(script, handler)
		self.scripts[script] = handler
	end
	function widget:GetScript(script)
		return self.scripts[script]
	end
	function widget:EnableMouse(isEnabled)
		self.isMouseEnabled = isEnabled
	end
	function widget:SetFrameLevel(level)
		self.frameLevel = level
	end
	function widget:GetFrameLevel()
		return self.frameLevel
	end
	if kind == 'Button' then
		function widget:SetText(text)
			self.text = text
		end
		function widget:GetText()
			return self.text
		end
		--- A hardware click, as the player makes it.
		function widget:Click()
			if self.scripts.OnClick then
				self.scripts.OnClick(self, 'LeftButton')
			end
		end
	end
	return widget
end

local function newFrame()
	local frame = { events = {} }
	function frame:SetScript(_, handler)
		self.onEvent = handler
	end
	function frame:RegisterEvent(event)
		self.events[event] = true
	end
	function frame:UnregisterEvent(event)
		self.events[event] = nil
	end
	return frame
end

local function newTooltip(game, name)
	local tooltip = { name = name, lines = {}, shownCount = 0, isShown = true, scripts = {} }
	function tooltip:SetOwner(owner, anchor)
		self.owner, self.anchor = owner, anchor
	end
	function tooltip:ClearLines()
		self.lines = {}
	end
	function tooltip:Hide()
		self.isShown = false
		self.hiddenCount = (self.hiddenCount or 0) + 1
	end
	function tooltip:AddLine(text, r, g, b, wrap)
		self.lines[#self.lines + 1] = { left = text, r = r, g = g, b = b, wrap = wrap }
	end
	function tooltip:AddDoubleLine(left, right, lr, lg, lb, rr, rg, rb)
		self.lines[#self.lines + 1] =
			{ left = left, right = right, lr = lr, lg = lg, lb = lb, rr = rr, rg = rg, rb = rb }
	end
	function tooltip:Show()
		self.shownCount = self.shownCount + 1
	end
	function tooltip:IsShown()
		return self.isShown
	end
	function tooltip:IsForbidden()
		return self.isForbidden == true
	end
	function tooltip:GetItem()
		return self.itemName, self.itemLink
	end
	function tooltip:GetOwner()
		return self.owner
	end
	function tooltip:HookScript(script, handler)
		self.scripts[script] = handler
	end
	function tooltip:RefreshData()
		self.refreshed = (self.refreshed or 0) + 1
		self.lines = {}
		game:ShowItemTooltip(self.shownItemId, self)
	end
	return tooltip
end

--- A new fake game. Options: { now, listings, itemInfo, hasProcessor = true, hasClock = true }.
--- listings: { { itemId, count, buyout, bid?, timeLeft?, seller?, isLoaded? }... } served by
--- GetReplicateItemInfo and GetReplicateItemTimeLeft (0-based index). timeLeft is the raw
--- client value, 1 (short) to 4 (very long) as AHledger's saved scans show; it defaults to 4.
--- As in the client, some rows come back before their seller is loaded: every third row, and
--- any row with isLoaded = false, has no owner and hasAllInfo false.
--- game.inCombat drives InCombatLockdown; game.secretValues[value] marks a secret value;
--- RequestLoadItemDataByID calls are recorded in game.itemDataRequests.
--- Bags: game.containerItems['bag:slot'] = { itemID?, stackCount, isBound, hyperlink } (itemID
--- nil models an item the client has not loaded), game.bagSlots[bag] = slots.
--- Trade: game.trade.player / .target = { money, slots = { [slot] = { name?, count, link? } } }
--- (a slot with a name and no link is an item not loaded yet); game.partner = { name, guid,
--- isGuild }; game.friendGuids[guid] marks a friend, game.bnetFriends lists Battle.net friends'
--- character GUIDs (one game account each). AcceptTrade
--- calls are counted in game.acceptCount. Frames the add-on creates go to game.createdFrames.
function FakeGame.new(options)
	options = options or {}
	local game = {
		now = options.now or 1000000,
		clockMs = 0,
		timers = {},
		listings = options.listings or {},
		modifiers = {},
		printed = {},
		replicateRequests = 0,
		frame = newFrame(),
		postCalls = {},
		containerItems = {},
		itemInfo = options.itemInfo or {},
		itemDataRequests = {},
		inCombat = false,
		secretValues = {},
		bagSlots = {},
		createdFrames = {},
		hooks = {},
		trade = { player = { money = 0, slots = {} }, target = { money = 0, slots = {} } },
		friendGuids = {},
		bnetFriends = {},
		acceptCount = 0,
	}
	local uiParent = FakeGame.newWidget('Frame')
	local env = {
		GetServerTime = function()
			return game.now
		end,
		time = function()
			return game.now
		end,
		-- The engine's hidden event frame is the one created without a parent; every other frame
		-- is a recorded widget.
		CreateFrame = function(kind, _, parent, template)
			if parent == nil then
				return game.frame
			end
			local widget = FakeGame.newWidget(kind, parent, template)
			game.createdFrames[#game.createdFrames + 1] = widget
			return widget
		end,
		UIParent = uiParent,
		hooksecurefunc = function(object, method, hook)
			local original = object[method]
			game.hooks[#game.hooks + 1] = { object = object, method = method }
			object[method] = function(...)
				local results = { original(...) }
				hook(...)
				return unpack(results)
			end
		end,
		NUM_TOTAL_EQUIPPED_BAG_SLOTS = 5,
		LE_GAME_ERR_TRADE_COMPLETE = 226,
		ERR_TRADE_COMPLETE = 'Trade complete.',
		GetTradePlayerItemInfo = function(slot)
			local entry = game.trade.player.slots[slot]
			if entry then
				return entry.name, 'icon', entry.count, 1, true, nil
			end
		end,
		GetTradeTargetItemInfo = function(slot)
			local entry = game.trade.target.slots[slot]
			if entry then
				return entry.name, 'icon', entry.count, 1, true, nil
			end
		end,
		GetTradePlayerItemLink = function(slot)
			local entry = game.trade.player.slots[slot]
			return entry and entry.link or nil
		end,
		GetTradeTargetItemLink = function(slot)
			local entry = game.trade.target.slots[slot]
			return entry and entry.link or nil
		end,
		GetPlayerTradeMoney = function()
			return game.trade.player.money
		end,
		GetTargetTradeMoney = function()
			return game.trade.target.money
		end,
		AcceptTrade = function()
			game.acceptCount = game.acceptCount + 1
		end,
		UnitGUID = function(unit)
			return unit == 'NPC' and game.partner and game.partner.guid or nil
		end,
		UnitIsInMyGuild = function(unit)
			return unit == 'NPC' and game.partner ~= nil and game.partner.isGuild == true
		end,
		C_FriendList = {
			IsFriend = function(guid)
				return game.friendGuids[guid] == true
			end,
		},
		BNGetNumFriends = function()
			return #game.bnetFriends
		end,
		C_BattleNet = {
			GetFriendNumGameAccounts = function(friend)
				return game.bnetFriends[friend] and 1 or 0
			end,
			GetFriendGameAccountInfo = function(friend)
				local guid = game.bnetFriends[friend]
				return guid and { playerGuid = guid } or nil
			end,
		},
		DEFAULT_CHAT_FRAME = {
			AddMessage = function(_, text)
				game.printed[#game.printed + 1] = text
			end,
		},
		SlashCmdList = {},
		GetRealmName = function()
			return 'Nightslayer'
		end,
		UnitName = function(unit)
			if unit == 'NPC' then
				return game.partner and game.partner.name or nil
			end
			return 'Eilu'
		end,
		UnitFactionGroup = function()
			return 'Alliance'
		end,
		GetCurrentRegion = function()
			return 1
		end,
		C_Item = {
			GetItemInfo = function(itemId)
				local info = game.itemInfo[itemId]
				if info then
					return info.name or 'Item', 'link', 1, 1, 0, 'Type', 'Sub', info.maxStack, '', 0, info.vendorPrice
				end
			end,
			RequestLoadItemDataByID = function(itemId)
				game.itemDataRequests[#game.itemDataRequests + 1] = itemId
			end,
		},
		InCombatLockdown = function()
			return game.inCombat == true
		end,
		issecretvalue = function(value)
			return value ~= nil and game.secretValues[value] == true
		end,
		C_Timer = {
			After = function(seconds, fn)
				game.timers[#game.timers + 1] = { at = game.now + seconds, fn = fn, isNextFrame = seconds == 0 }
			end,
		},
		C_AuctionHouse = {
			ReplicateItems = function()
				game.replicateRequests = game.replicateRequests + 1
			end,
			GetNumReplicateItems = function()
				return #game.listings
			end,
			GetReplicateItemInfo = function(index)
				game.rowsRead = (game.rowsRead or 0) + 1
				game.clockMs = game.clockMs + (game.msPerRow or 0)
				local listing = game.listings[index + 1]
				if not listing then
					return nil
				end
				if listing.throws then
					error('client error')
				end
				local hasAllInfo = listing.isLoaded ~= false and index % 3 ~= 2
				local owner = hasAllInfo and (listing[6] or 'Seller') or nil
				return 'Item',
					1,
					listing[2],
					1,
					true,
					1,
					0,
					0,
					0,
					listing[3],
					listing[4] or 0,
					false,
					nil,
					owner,
					owner,
					0,
					listing[1],
					hasAllInfo
			end,
			GetReplicateItemTimeLeft = function(index)
				local listing = game.listings[index + 1]
				return listing and (listing[5] or 4) or nil
			end,
			GetReplicateItemLink = function(index)
				local listing = game.listings[index + 1]
				return listing and ('|Hitem:' .. listing[1] .. '|h') or nil
			end,
		},
		IsShiftKeyDown = function()
			return game.modifiers.shift == true
		end,
		IsControlKeyDown = function()
			return game.modifiers.ctrl == true
		end,
		IsAltKeyDown = function()
			return game.modifiers.alt == true
		end,
		C_Container = {
			GetContainerItemInfo = function(bag, slot)
				return game.containerItems[bag .. ':' .. slot]
			end,
			GetContainerNumSlots = function(bag)
				return game.bagSlots[bag] or 0
			end,
		},
	}
	if options.hasClock ~= false then
		env.debugprofilestop = function()
			return game.clockMs
		end
	end
	if options.hasProcessor ~= false then
		env.Enum = { TooltipDataType = { Item = 0 } }
		env.TooltipDataProcessor = {
			AddTooltipPostCall = function(dataType, handler)
				game.postCalls[#game.postCalls + 1] = { dataType = dataType, handler = handler }
			end,
		}
	end
	env.GameTooltip = newTooltip(game, 'GameTooltip')
	env.ItemRefTooltip = newTooltip(game, 'ItemRefTooltip')
	game.env = env

	--- Fires a game event at the event frame.
	function game:Fire(event, ...)
		if self.frame.events[event] and self.frame.onEvent then
			self.frame.onEvent(self.frame, event, ...)
		end
	end

	--- Runs the timers due now or earlier, in order (one pass; timers they add wait).
	function game:RunTimers()
		local due, waiting = {}, {}
		for _, timer in ipairs(self.timers) do
			if timer.at <= self.now then
				due[#due + 1] = timer
			else
				waiting[#waiting + 1] = timer
			end
		end
		self.timers = waiting
		for _, timer in ipairs(due) do
			timer.fn()
		end
		return #due
	end

	--- One frame: the clock moves on and next-frame timers run.
	function game:NextFrame()
		self.clockMs = self.clockMs + 16
		return self:RunTimers()
	end

	--- Runs frames until no timer is due; returns how many frames ran.
	function game:RunFrames(limit)
		local frames = 0
		while frames < (limit or 10000) and self:NextFrame() > 0 do
			frames = frames + 1
		end
		return frames
	end

	function game:Advance(seconds)
		self.now = self.now + seconds
		return self:RunTimers()
	end

	--- Builds an item tooltip: clears it and runs the post-calls (or the script hook).
	function game:ShowItemTooltip(itemId, tooltip)
		tooltip = tooltip or self.env.GameTooltip
		tooltip.lines = {}
		tooltip.shownItemId = itemId
		tooltip.itemLink = '|cffffffff|Hitem:' .. itemId .. '::::|h[Item]|h|r'
		for _, postCall in ipairs(self.postCalls) do
			postCall.handler(tooltip, { id = itemId })
		end
		if tooltip.scripts.OnTooltipSetItem then
			tooltip.scripts.OnTooltipSetItem(tooltip)
		end
		return tooltip.lines
	end

	return game
end

-- The files the TOC loads after the Engine (Init.lua aside), in its order.
FakeGame.FEATURE_FILES = {
	'Features/Pricing.lua',
	'Features/Value.lua',
	'Features/Scan.lua',
	'Features/Tooltip/Tooltip.lua',
	'Features/Bags/Bags.lua',
	'Features/Trade/Trade.lua',
}

-- AHledger --------------------------------------------------------------------------------

-- AHledgerAPI's price fields, in the order a fake row lists them.
FakeGame.AHLEDGER_FIELDS =
	{ 'median', 'minBuyout', 'quantity', 'median7d', 'median30d', 'low30d', 'high30d', 'soldPerDay' }

--- A stand-in for AHledger's AHledgerAPI v1 (AHledger's API.lua), read-only like the real one.
--- options = { market, pinnedMarket, updated, snapshot, version, credit, mode,
---             rows = { [itemId] = { median, minBuyout, quantity, median7d, median30d, low30d,
---                                   high30d, soldPerDay } } }
--- market is the player's market (and the only one priced); pinnedMarket is a market pinned in
--- AHledger's options, which GetMarket then returns. Like the real API, a key that is not
--- shaped like a market key falls back to GetMarket's. version defaults to 1. mode 'broken'
--- makes every call throw (the real API never does; Haggler must not trust that), mode
--- 'priceBroken' only GetPrice; mode 'junk' answers with strings where numbers belong. Calls
--- are counted in state.calls.
--- @return table api, table state (change state.rows, state.snapshot... between calls)
function FakeGame.newAHledgerAPI(options)
	options = options or {}
	local state = {
		market = options.market or 'forever/normal/alliance/us',
		pinnedMarket = options.pinnedMarket,
		updated = options.updated,
		snapshot = options.snapshot == true,
		rows = options.rows or {},
		mode = options.mode,
		calls = 0,
	}
	local function marketOf(market)
		if type(market) == 'string' and market:match('^[%w%-]+/[%w%-]+/[%w%-]+/[%w%-]+$') then
			return market
		end
		return state.pinnedMarket or state.market
	end
	local api = {
		VERSION = options.version or 1,
		CREDIT = options.credit or 'Prices from AHledger (ahledger.com)',
	}
	function api.GetMarket()
		return state.pinnedMarket or state.market
	end
	function api.GetTableInfo(market)
		state.calls = state.calls + 1
		if state.mode == 'broken' then
			error('AHledger broke')
		end
		local m = marketOf(market)
		if m ~= state.market then
			return nil
		end
		local count = 0
		for _ in pairs(state.rows) do
			count = count + 1
		end
		return { market = m, updated = state.updated, count = count, snapshot = state.snapshot }
	end
	function api.GetPrice(item, market)
		state.calls = state.calls + 1
		if state.mode == 'broken' or state.mode == 'priceBroken' then
			error('AHledger broke')
		end
		local m = marketOf(market)
		local row = m == state.market and state.rows[item] or nil
		if not row then
			return nil
		end
		local price = { itemID = item, market = m, updated = state.updated, snapshot = state.snapshot }
		for index, field in ipairs(FakeGame.AHLEDGER_FIELDS) do
			price[field] = row[index]
		end
		if state.mode == 'junk' then
			price.median, price.soldPerDay, price.updated = 'lots', 'many', 'yesterday'
		end
		return price
	end
	function api.GetMedian(item, market)
		local price = api.GetPrice(item, market)
		return price and price.median
	end
	local proxy = setmetatable({}, {
		__index = api,
		__newindex = function()
			error('AHledgerAPI is read-only', 2)
		end,
		__metatable = false,
	})
	return proxy, state
end

--- Starts the add-on's features on a fake game, as Init.lua and Haggler.lua do in the client.
--- @param t table the harness
--- @param game table FakeGame.new(...)
--- @param beforeStart function|nil fun(ns), run after the store opens and before the host starts
--- @return table ns
function FakeGame.startAddon(t, game, beforeStart)
	local ns = t.loadAddon()
	local errors = {}
	ns.wow = ns.Wow.create(game.env, {
		onError = function(where, err)
			errors[#errors + 1] = where .. ': ' .. tostring(err)
		end,
	})
	ns.host = ns.Host.create({
		onError = function(owner, where, err)
			errors[#errors + 1] = owner .. ' ' .. where .. ': ' .. tostring(err)
		end,
	})
	ns.theme = ns.Theme.new(ns.Tokens)
	ns.tooltips = ns.Tooltip.new({
		wow = ns.wow,
		onError = function(owner, err)
			errors[#errors + 1] = 'tooltip ' .. owner .. ': ' .. tostring(err)
		end,
	})
	for _, path in ipairs(FakeGame.FEATURE_FILES) do
		assert(loadfile(path))('Haggler', ns)
	end
	-- game.savedDb / game.savedCharDb carry saved variables across a simulated /reload.
	game.savedDb = game.savedDb or {}
	game.savedCharDb = game.savedCharDb or {}
	ns.store = assert(ns.Store.open(game.savedDb, game.savedCharDb))
	if beforeStart then
		beforeStart(ns)
	end
	ns.host.Start(ns.store:Settings())
	ns.errors = errors
	return ns
end

return FakeGame
