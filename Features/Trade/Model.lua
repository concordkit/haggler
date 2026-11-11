--[[
	TradeModel: the trade window as data. It reads both sides through ns.wow, values them with
	Engine/Trade under the chosen rule, keeps the partner's policy, describes what the frame
	shows, and notices a completed trade so it can be logged.

	  TradeModel.new({ wow, values, options, onComplete })
	    values()  -> Value|nil
	    options() -> { mode, feeCopper, feePercent, friends, guild, ruleId?, money(copper) }
	    onComplete(snapshot)   once per completed trade
	  model:OnEvent(event, ...) -> 'changed' | 'closed' | 'completed' | nil
	  model:Read() -> Snapshot|nil
	  model.isOpen                     true between TRADE_SHOW and TRADE_CLOSED
	  model:Describe() -> View|nil   (what the frame shows; nil when hidden for this partner)

	Snapshot = { player = TradeSide, target = TradeSide, verdict, partner, policy, exempt?, ruleId }

	Freezing: once both sides have accepted, the snapshot is kept as it is until an acceptance
	is withdrawn (TRADE_ACCEPT_UPDATE) or the window reopens. Item and money events in between
	are the client emptying the slots as the trade goes through, not a new offer.

	Completion: Blizzard reports a finished trade as UI_INFO_MESSAGE, with the message type
	LE_GAME_ERR_TRADE_COMPLETE (first argument) and the text ERR_TRADE_COMPLETE (second); either
	is accepted. TRADE_CLOSED can arrive before that message, so the last snapshot is kept for
	COMPLETE_GRACE_SECONDS after the window closes. A trade that was cancelled sends no message
	and is never logged.
]]
local _, ns = ...

local TradeModel = {}
ns.TradeModel = TradeModel

TradeModel.COMPLETE_GRACE_SECONDS = 5
TradeModel.SIDES = { 'player', 'target' }
TradeModel.READ_EVENTS = {
	TRADE_SHOW = true,
	TRADE_PLAYER_ITEM_CHANGED = true,
	TRADE_TARGET_ITEM_CHANGED = true,
	TRADE_MONEY_CHANGED = true,
	TRADE_ACCEPT_UPDATE = true,
}
TradeModel.EVENTS = { 'TRADE_SHOW', 'TRADE_CLOSED', 'UI_INFO_MESSAGE' }
for event in pairs(TradeModel.READ_EVENTS) do
	if event ~= 'TRADE_SHOW' then
		TradeModel.EVENTS[#TradeModel.EVENTS + 1] = event
	end
end
table.sort(TradeModel.EVENTS)

-- Helpers live at the bottom of the file; declared here so they stay local.
local readSide, describeSide, describeWarning, isTradeComplete, topLowReason, armKeyOf, slotText
local isAccepted

local ModelMethods = {}
ModelMethods.__index = ModelMethods

--- @param deps table see the file header
--- @return table model
function TradeModel.new(deps)
	if type(deps) ~= 'table' or not deps.wow then
		error('TradeModel.new: needs wow', 2)
	end
	for _, fn in ipairs({ 'values', 'options', 'onComplete' }) do
		if type(deps[fn]) ~= 'function' then
			error('TradeModel.new: needs ' .. fn, 2)
		end
	end
	return setmetatable({ deps = deps }, ModelMethods)
end

--- Handles one game event.
function ModelMethods:OnEvent(event, ...)
	local wow = self.deps.wow
	if event == 'TRADE_SHOW' then
		self.snapshot, self.closedAt, self.isLogged, self.isFrozen = nil, nil, false, false
		self.isOpen = true
		self.partner = wow:TradePartner()
	end
	if TradeModel.READ_EVENTS[event] then
		if self.closedAt then
			return nil
		end
		if event == 'TRADE_ACCEPT_UPDATE' then
			local playerAccepted, targetAccepted = ...
			local isBothAccepted = isAccepted(playerAccepted) and isAccepted(targetAccepted)
			if isBothAccepted and self.snapshot then
				-- The client may clear the slots before it reports the trade complete.
				self.isFrozen = true
				return 'changed'
			end
			self.isFrozen = false
		elseif self.isFrozen then
			return nil
		end
		self:Read()
		return 'changed'
	end
	if event == 'TRADE_CLOSED' then
		self.closedAt = self.closedAt or wow:Now()
		self.isOpen = false
		return 'closed'
	end
	if event == 'UI_INFO_MESSAGE' and isTradeComplete(wow, ...) then
		return self:Complete() and 'completed' or nil
	end
	return nil
end

--- Reads and values both sides. Nil when there is no value service.
function ModelMethods:Read()
	local values = self.deps.values()
	if not values then
		self.snapshot = nil
		return nil
	end
	local options = self.deps.options()
	local wow = self.deps.wow
	local ctx = values:Context()
	local valueOf = function(itemId, qty)
		return values:Stack(itemId, qty, { ruleId = options.ruleId, ctx = ctx })
	end
	local partner = self.partner or wow:TradePartner()
	self.partner = partner
	local policy, exempt = ns.Trade.partnerPolicy(partner, { friends = options.friends, guild = options.guild })
	local player = readSide(wow, 'player', valueOf, true)
	local target = readSide(wow, 'target', valueOf, false)
	self.snapshot = {
		player = player,
		target = target,
		partner = partner,
		policy = policy,
		exempt = exempt,
		ruleId = values:RuleId({ ruleId = options.ruleId }),
		verdict = ns.Trade.verdict(player, target, {
			mode = options.mode,
			feeCopper = options.feeCopper,
			feePercent = options.feePercent,
			partner = policy,
			exempt = exempt,
		}),
	}
	return self.snapshot
end

--- Logs the last snapshot once, if the window is open or closed only just now.
--- @return boolean logged
function ModelMethods:Complete()
	local snapshot = self.snapshot
	if not snapshot or self.isLogged then
		return false
	end
	local now = self.deps.wow:Now()
	if self.closedAt and now - self.closedAt > TradeModel.COMPLETE_GRACE_SECONDS then
		return false
	end
	self.isLogged = true
	self.deps.onComplete(snapshot)
	return true
end

--- What the frame shows, or nil when it shows nothing (no snapshot, or a partner whose policy
--- is off).
--- @return table|nil View = { ruleId, sides = { player = SideView, target = SideView },
---   warning?, isConfirm, isUncertain, armKey }
---   armKey changes only when the gap or the items change: the confirm arm survives redraws.
---   SideView = { total, isLow, slots = { [slot] = { text, isLow, isPriced, hover = { lines } } } }
function ModelMethods:Describe()
	local snapshot = self.snapshot
	if not snapshot or snapshot.policy == 'off' then
		return nil
	end
	local money = self.deps.options().money
	local verdict = snapshot.verdict
	return {
		ruleId = snapshot.ruleId,
		sides = {
			player = describeSide(snapshot.player, money),
			target = describeSide(snapshot.target, money),
		},
		warning = describeWarning(snapshot, money),
		isConfirm = verdict.action == 'confirm',
		isUncertain = verdict.isUncertain,
		armKey = armKeyOf(snapshot),
	}
end

-- Helpers ---------------------------------------------------------------------------------

function readSide(wow, side, valueOf, isGiven)
	local slots = {}
	for slot = 1, ns.Trade.MAX_SLOTS do
		slots[slot] = wow:TradeSlot(side, slot)
	end
	return ns.Trade.side({ gold = wow:TradeMoney(side), slots = slots, valueOf = valueOf, isGiven = isGiven })
end

function describeSide(side, money)
	local view = { total = money(side.total), isLow = side.confidence.level == 'low', slots = {} }
	for _, item in ipairs(side.items) do
		local value = item.value
		local isLow = type(value.confidence) == 'table' and value.confidence.level == 'low'
		local hover = {}
		local rulePrice = value.rulePrice
		hover[#hover + 1] = rulePrice and ('Rule price: ' .. money(rulePrice.copper) .. ' each') or 'No rule price'
		hover[#hover + 1] = 'Worth '
			.. money(value.copper)
			.. ' (after the 5% cut and deposit risk, never below vendor)'
		for _, reason in ipairs(type(value.confidence) == 'table' and value.confidence.reasons or {}) do
			if reason.level ~= 'high' then
				hover[#hover + 1] = reason.level .. ': ' .. tostring(reason.text)
			end
		end
		view.slots[item.slot] = {
			text = slotText(value, money),
			isLow = isLow,
			isPriced = value.isPriced == true,
			hover = hover,
		}
	end
	return view
end

function describeWarning(snapshot, money)
	local verdict = snapshot.verdict
	if verdict.action == 'ok' then
		if verdict.isUncertain then
			local reason = topLowReason(verdict.confidence)
			return { text = 'Values uncertain' .. (reason and (': ' .. reason) or ''), isLoss = false }
		end
		return nil
	end
	local text = string.format('You give %s more than you get (fee allows %s)', money(verdict.gap), money(verdict.fee))
	if verdict.isUncertain then
		local reason = topLowReason(verdict.confidence)
		text = text .. '; values uncertain' .. (reason and (': ' .. reason) or '')
	end
	return { text = text, isLoss = true }
end

function slotText(value, money)
	if value.isPriced then
		return money(value.copper)
	end
	if value.copper > 0 then
		return 'no price (vendor ' .. money(value.copper) .. ')'
	end
	return 'no price'
end

function armKeyOf(snapshot)
	local parts = { tostring(snapshot.verdict.gap) }
	for _, sideKey in ipairs(TradeModel.SIDES) do
		for _, item in ipairs(snapshot[sideKey].items) do
			parts[#parts + 1] = sideKey .. item.slot .. ':' .. tostring(item.itemId) .. 'x' .. tostring(item.qty)
		end
	end
	return table.concat(parts, '|')
end

function topLowReason(confidence)
	for _, reason in ipairs(type(confidence) == 'table' and confidence.reasons or {}) do
		if reason.level == 'low' then
			return reason.text
		end
	end
	return nil
end

-- TRADE_ACCEPT_UPDATE's flags: 1 on the classic client, a boolean on newer ones.
function isAccepted(flag)
	return flag == 1 or flag == true
end

function isTradeComplete(wow, messageType, text)
	local completeType = wow:Global('LE_GAME_ERR_TRADE_COMPLETE')
	local completeText = wow:Global('ERR_TRADE_COMPLETE')
	return (completeType ~= nil and messageType == completeType) or (completeText ~= nil and text == completeText)
end

return TradeModel
