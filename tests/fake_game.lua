-- A fake game environment for Engine/Wow.lua: a clock, timers that run when the test says so,
-- an event frame, the auction house replicate list, modifier keys and item tooltips.
local FakeGame = {}

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
	}
	local env = {
		GetServerTime = function()
			return game.now
		end,
		time = function()
			return game.now
		end,
		CreateFrame = function()
			return game.frame
		end,
		DEFAULT_CHAT_FRAME = {
			AddMessage = function(_, text)
				game.printed[#game.printed + 1] = text
			end,
		},
		SlashCmdList = {},
		GetRealmName = function()
			return 'Nightslayer'
		end,
		UnitName = function()
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
FakeGame.FEATURE_FILES = { 'Features/Pricing.lua', 'Features/Scan.lua', 'Features/Tooltip/Tooltip.lua' }

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
	ns.store = assert(ns.Store.open({}, {}))
	if beforeStart then
		beforeStart(ns)
	end
	ns.host.Start(ns.store:Settings())
	ns.errors = errors
	return ns
end

return FakeGame
