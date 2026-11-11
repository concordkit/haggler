--[[
	Trade: the value of each side of a trade, the loss verdict against the convenience fee, and
	the trusted-partner check. UI-free; Features/Trade reads the trade window into plain data.

	  Trade.side{ gold, slots = { [slot] = { itemId?, qty }... }, valueOf, isGiven? } -> TradeSide
	      valueOf(itemId, qty) -> ItemValue|nil, reason   (Value:Stack under the chosen rule)
	      isGiven: the side the player gives. An item there with no AH price is rated low: it
	      may be worth far more than the vendor pays, so a verdict on it is uncertain, never
	      "safe". On the side the player gets, the vendor floor is a safe lower bound.
	      Slot ENCHANT_SLOT ("will not be traded") is never counted. A slot whose item the
	      client has not loaded yet (itemId nil) counts as unpriced, with a low reason.
	  Trade.verdict(player, target, policy) -> TradeVerdict
	  Trade.partnerPolicy(partner, settings) -> policy, exempt

	TradeSide    = { gold, items = { { slot, itemId?, qty, value? }... }, itemsCopper, total,
	                 unpriced, confidence }
	TradeVerdict = { give, get, gap, fee, action = 'ok'|'warn'|'confirm', isLoss, exempt?,
	                 isUncertain, confidence }

	Gold counts at face value. Items count at their opportunity value (net after the cut and
	deposit risk, never below vendor). The fee is an amount plus a percentage of the player's
	side; a gap up to and including the fee is no loss. A side's confidence follows its weakest
	item, and the verdict's follows the weaker side: a low verdict is uncertain, never "safe".
]]
local _, ns = ...

local Trade = {}
ns.Trade = Trade

Trade.ENCHANT_SLOT = 7
Trade.MAX_SLOTS = 7
Trade.MODES = { off = true, warn = true, confirm = true }
Trade.PARTNER_POLICIES = { full = true, values = true, off = true }
-- How much of the feature a policy keeps: the more trusted group wins when a partner is in both.
local POLICY_RANK = { off = 1, values = 2, full = 3 }

-- Helpers live at the bottom of the file; declared here so they stay local.
local isWholeNonNegative, isWholePositive, addReason, unloadedItemValue, givenWithoutAhPrice

--- The value of one side of a trade.
--- @param input table { gold, slots, valueOf }
--- @return table TradeSide
function Trade.side(input)
	if type(input) ~= 'table' or type(input.valueOf) ~= 'function' then
		error('Trade.side: needs valueOf', 2)
	end
	local reasons = {}
	local gold = input.gold
	if not isWholeNonNegative(gold) then
		if gold ~= nil then
			addReason(reasons, 'badInput', 'medium', 'trade gold was not readable; counted as 0')
		end
		gold = 0
	end
	local side = { gold = gold, items = {}, itemsCopper = 0, unpriced = 0 }
	local confidences = { { reasons = reasons } }
	for slot = 1, Trade.MAX_SLOTS do
		local entry = type(input.slots) == 'table' and input.slots[slot] or nil
		if slot ~= Trade.ENCHANT_SLOT and type(entry) == 'table' then
			local qty = isWholePositive(entry.qty) and entry.qty or 1
			local value
			if isWholePositive(entry.itemId) then
				local ok, result = pcall(input.valueOf, entry.itemId, qty)
				value = ok and result or nil
			else
				value = unloadedItemValue()
			end
			if type(value) ~= 'table' or type(value.copper) ~= 'number' then
				value = unloadedItemValue('no value')
			end
			if input.isGiven and value.isPriced ~= true then
				value = givenWithoutAhPrice(value)
			end
			side.items[#side.items + 1] = { slot = slot, itemId = entry.itemId, qty = qty, value = value }
			side.itemsCopper = side.itemsCopper + value.copper
			side.unpriced = side.unpriced + (value.isPriced and 0 or 1)
			confidences[#confidences + 1] = value.confidence
		end
	end
	side.total = side.gold + side.itemsCopper
	side.confidence = ns.Value.mergeConfidence(confidences, ns.Value.MAX_TOTAL_REASONS)
	return side
end

--- The loss verdict of a trade.
--- @param player table TradeSide the player gives
--- @param target table TradeSide the player gets
--- @param policy table { mode, feeCopper, feePercent, partner = 'full'|'values'|'off', exempt? }
--- @return table TradeVerdict
function Trade.verdict(player, target, policy)
	if type(player) ~= 'table' or type(target) ~= 'table' or type(policy) ~= 'table' then
		error('Trade.verdict: needs two sides and a policy', 2)
	end
	if not Trade.MODES[policy.mode] then
		error('Trade.verdict: unknown mode ' .. tostring(policy.mode), 2)
	end
	local feeCopper = isWholeNonNegative(policy.feeCopper) and policy.feeCopper or 0
	local feePercent = type(policy.feePercent) == 'number' and policy.feePercent >= 0 and policy.feePercent or 0
	local give, get = player.total, target.total
	local fee = feeCopper + math.floor(give * feePercent / 100)
	local gap = give - get
	local isLoss = gap > fee
	local confidence = ns.Value.mergeConfidence({ player.confidence, target.confidence }, ns.Value.MAX_TOTAL_REASONS)
	local isWarned = policy.mode ~= 'off' and (policy.partner or 'full') == 'full'
	return {
		give = give,
		get = get,
		gap = gap,
		fee = fee,
		isLoss = isLoss,
		action = (isLoss and isWarned) and policy.mode or 'ok',
		exempt = (policy.partner == 'values') and policy.exempt or nil,
		isUncertain = confidence.level == 'low',
		confidence = confidence,
	}
end

--- What a trusted partner gets: the most trusting policy of the groups the partner is in.
--- @param partner table { isFriend?, isBnetFriend?, isGuild? }
--- @param settings table { friends = policy, guild = policy }
--- @return string policy 'full' | 'values' | 'off'
--- @return string|nil exempt 'friend' | 'guild', the group that set a lighter policy
function Trade.partnerPolicy(partner, settings)
	if type(partner) ~= 'table' or type(settings) ~= 'table' then
		error('Trade.partnerPolicy: needs a partner and settings', 2)
	end
	local policy, exempt = 'full', nil
	local groups = {
		{ name = 'friend', isMember = partner.isFriend or partner.isBnetFriend, policy = settings.friends },
		{ name = 'guild', isMember = partner.isGuild, policy = settings.guild },
	}
	for _, group in ipairs(groups) do
		local groupPolicy = Trade.PARTNER_POLICIES[group.policy] and group.policy or 'full'
		if group.isMember and POLICY_RANK[groupPolicy] < POLICY_RANK[policy] then
			policy, exempt = groupPolicy, group.name
		end
	end
	return policy, exempt
end

-- Helpers ---------------------------------------------------------------------------------

function isWholeNonNegative(value)
	return type(value) == 'number' and value >= 0 and value < math.huge and value % 1 == 0
end

function isWholePositive(value)
	return isWholeNonNegative(value) and value > 0
end

function addReason(reasons, code, level, text)
	reasons[#reasons + 1] = { code = code, level = level, text = text }
end

-- A slot whose item has no value: counted as 0 and low, so the side never looks surer than it is.
-- A copy of the value rated low; the caller's value (possibly cached) is never changed.
function givenWithoutAhPrice(value)
	local copy = {}
	for key, field in pairs(value) do
		copy[key] = field
	end
	copy.confidence = ns.Value.mergeConfidence({
		value.confidence,
		{
			reasons = {
				{
					code = 'givenNoAhPrice',
					level = 'low',
					text = 'no AH price; may be worth more than the vendor pays',
				},
			},
		},
	})
	return copy
end

function unloadedItemValue(text)
	return {
		copper = 0,
		perUnit = 0,
		source = 'none',
		isPriced = false,
		confidence = {
			level = 'low',
			reasons = { { code = 'itemUnknown', level = 'low', text = text or 'item not loaded yet' } },
		},
	}
end

return Trade
