--[[
	TradeFrames: Haggler's additions to Blizzard's TradeFrame (no takeover). Everything here is a
	frame, texture or font string of Haggler's own, parented to TradeFrame; Blizzard's frames are
	only read and anchored to, never changed.

	  TradeFrames.new({ wow, icons, theme, onRuleClick, onAccept, ruleName })
	  frames:Attach() -> boolean    once TradeFrame exists; idempotent
	  frames:Render(view|nil)       a TradeModel:Describe() view; nil hides everything

	Pieces: a value under each of the six item slots per side (the enchant slot is never valued)
	with the raw rule price and the low-confidence reasons on hover; a total per side above the
	money frames; a rule button that cycles the rule; the loss warning above the Trade button.

	Confirm mode: Blizzard's Trade button is never hooked, disabled or replaced (that would taint
	the trade accept path). Instead, while the verdict is 'confirm', a button of Haggler's own
	covers it. Its first click arms it ("Confirm loss"); a change to the gap or the items disarms
	it (a redraw for the partner's accept does not); a second click within ARM_SECONDS calls
	AcceptTrade, the same call Blizzard's button makes, from that hardware click. A key binding or
	a gamepad cursor that clicks Blizzard's button directly is not covered (in-game check).

	Frame names (unverified on Forever's client, taken from the Mainline UI source):
	TradeFrame, TradePlayerItem<N>ItemButton, TradeRecipientItem<N>ItemButton,
	TradePlayerInputMoneyFrame, TradeRecipientMoneyFrame, TradeFrameTradeButton.
]]
local _, ns = ...

local TradeFrames = {}
ns.TradeFrames = TradeFrames

TradeFrames.ARM_SECONDS = 5
TradeFrames.VALUED_SLOTS = 6
TradeFrames.SLOT_BUTTONS = { player = 'TradePlayerItem%dItemButton', target = 'TradeRecipientItem%dItemButton' }
TradeFrames.MONEY_FRAMES = { player = 'TradePlayerInputMoneyFrame', target = 'TradeRecipientMoneyFrame' }
TradeFrames.TRADE_BUTTON = 'TradeFrameTradeButton'
local LABEL_WIDTH, LABEL_HEIGHT = 96, 12
local LOW_ICON_SIZE = 12
local WARNING_WIDTH = 300

-- Helpers live at the bottom of the file; declared here so they stay local.
local createSlotLabel, createConfirmButton, createRuleButton, showHover, lowIcon, setShown

local FramesMethods = {}
FramesMethods.__index = FramesMethods

--- @param deps table see the file header
--- @return table frames
function TradeFrames.new(deps)
	if type(deps) ~= 'table' or not deps.wow or not deps.icons or not deps.theme then
		error('TradeFrames.new: needs wow, icons and theme', 2)
	end
	for _, fn in ipairs({ 'onRuleClick', 'onAccept', 'ruleName' }) do
		if type(deps[fn]) ~= 'function' then
			error('TradeFrames.new: needs ' .. fn, 2)
		end
	end
	return setmetatable({ deps = deps }, FramesMethods)
end

--- Builds the pieces on TradeFrame the first time it exists.
function FramesMethods:Attach()
	if self.parts then
		return true
	end
	local wow = self.deps.wow
	local tradeFrame = wow:Global('TradeFrame')
	if type(tradeFrame) ~= 'table' then
		return false
	end
	local parts = { slots = { player = {}, target = {} }, totals = {} }
	for side, pattern in pairs(TradeFrames.SLOT_BUTTONS) do
		for slot = 1, TradeFrames.VALUED_SLOTS do
			local button = wow:Global(string.format(pattern, slot))
			if type(button) == 'table' then
				parts.slots[side][slot] = createSlotLabel(self, tradeFrame, button)
			end
		end
		local money = wow:Global(TradeFrames.MONEY_FRAMES[side])
		if type(money) == 'table' then
			local total = tradeFrame:CreateFontString(nil, 'OVERLAY', 'GameFontHighlightSmall')
			total:SetPoint('BOTTOMLEFT', money, 'TOPLEFT', 0, 2)
			total:Hide()
			parts.totals[side] = total
		end
	end
	local tradeButton = wow:Global(TradeFrames.TRADE_BUTTON)
	if type(tradeButton) == 'table' then
		local warning = tradeFrame:CreateFontString(nil, 'OVERLAY', 'GameFontNormalSmall')
		warning:SetPoint('BOTTOMRIGHT', tradeButton, 'TOPRIGHT', 0, 4)
		warning:SetWidth(WARNING_WIDTH)
		warning:Hide()
		parts.warning = warning
		parts.confirm = createConfirmButton(self, tradeFrame, tradeButton)
	end
	parts.rule = createRuleButton(self, tradeFrame)
	self.parts = parts
	return true
end

--- Shows a view (TradeModel:Describe()); nil hides every piece.
function FramesMethods:Render(view)
	local parts = self.parts
	if not parts then
		return
	end
	local theme = self.deps.theme
	for side, labels in pairs(parts.slots) do
		local sideView = view and view.sides[side]
		for slot, label in pairs(labels) do
			local slotView = sideView and sideView.slots[slot]
			label.hover = slotView and slotView.hover or nil
			if slotView then
				local token = slotView.isPriced and 'color.text.secondary' or 'color.text.muted'
				local text = theme:Wrap(token, slotView.text) .. (slotView.isLow and (' ' .. lowIcon(self)) or '')
				label.text:SetText(text)
			end
			setShown(label.frame, slotView ~= nil)
		end
		local total = parts.totals[side]
		if total then
			if sideView then
				total:SetText('Worth ' .. sideView.total .. (sideView.isLow and (' ' .. lowIcon(self)) or ''))
			end
			setShown(total, sideView ~= nil)
		end
	end
	if parts.warning then
		local warning = view and view.warning
		if warning then
			local token = warning.isLoss and 'color.state.danger' or 'color.state.caution'
			parts.warning:SetText(theme:Wrap(token, warning.text))
		end
		setShown(parts.warning, warning ~= nil)
	end
	if parts.confirm then
		local confirm = parts.confirm
		local isConfirm = view ~= nil and view.isConfirm == true
		local armKey = isConfirm and view.armKey or nil
		if armKey == nil or armKey ~= confirm.armKey then
			-- A different trade (gap or items) needs a fresh confirmation.
			confirm.armedAt = nil
			confirm.button:SetText('Trade')
		end
		confirm.armKey = armKey
		setShown(confirm.button, isConfirm)
	end
	if view then
		parts.rule:SetText('Rule: ' .. self.deps.ruleName(view.ruleId))
	end
	setShown(parts.rule, view ~= nil)
end

--- The confirm button's click: arm, or accept when armed recently.
--- @return string 'armed' | 'accepted'
function FramesMethods:ClickConfirm()
	local confirm = self.parts and self.parts.confirm
	if not confirm then
		return 'armed'
	end
	local now = self.deps.wow:Now()
	if confirm.armedAt and now - confirm.armedAt <= TradeFrames.ARM_SECONDS then
		confirm.armedAt = nil
		self.deps.onAccept()
		return 'accepted'
	end
	confirm.armedAt = now
	confirm.button:SetText('Confirm loss')
	return 'armed'
end

-- Helpers ---------------------------------------------------------------------------------

function createSlotLabel(frames, tradeFrame, slotButton)
	local wow = frames.deps.wow
	local frame = wow:CreateFrame('Frame', tradeFrame)
	frame:SetSize(LABEL_WIDTH, LABEL_HEIGHT)
	frame:SetPoint('TOPLEFT', slotButton, 'BOTTOMRIGHT', 4, LABEL_HEIGHT + 2)
	local text = frame:CreateFontString(nil, 'OVERLAY', 'GameFontHighlightSmall')
	text:SetPoint('LEFT', frame, 'LEFT', 0, 0)
	local label = { frame = frame, text = text }
	frame:EnableMouse(true)
	frame:SetScript('OnEnter', function()
		showHover(wow, frame, label.hover)
	end)
	frame:SetScript('OnLeave', function()
		local tooltip = wow:Global('GameTooltip')
		if tooltip then
			tooltip:Hide()
		end
	end)
	frame:Hide()
	return label
end

function createConfirmButton(frames, tradeFrame, tradeButton)
	local button = frames.deps.wow:CreateFrame('Button', tradeFrame, 'UIPanelButtonTemplate')
	button:SetAllPoints(tradeButton)
	button:SetFrameLevel(tradeButton:GetFrameLevel() + 5)
	button:SetText('Trade')
	button:SetScript('OnClick', function()
		frames:ClickConfirm()
	end)
	button:Hide()
	return { button = button }
end

function createRuleButton(frames, tradeFrame)
	local button = frames.deps.wow:CreateFrame('Button', tradeFrame, 'UIPanelButtonTemplate')
	button:SetSize(140, 20)
	button:SetPoint('TOPRIGHT', tradeFrame, 'TOPRIGHT', -8, -28)
	button:SetScript('OnClick', function()
		frames.deps.onRuleClick()
	end)
	button:Hide()
	return button
end

function showHover(wow, owner, lines)
	local tooltip = wow:Global('GameTooltip')
	if not tooltip or type(lines) ~= 'table' then
		return
	end
	tooltip:SetOwner(owner, 'ANCHOR_RIGHT')
	tooltip:ClearLines()
	for _, line in ipairs(lines) do
		tooltip:AddLine(line, 1, 1, 1, true)
	end
	tooltip:Show()
end

function lowIcon(frames)
	return frames.deps.icons:Inline(ns.IconSet.LOW_CONFIDENCE, LOW_ICON_SIZE, ns.IconSet.LOW_CONFIDENCE_COLOR)
end

function setShown(region, isShown)
	if isShown then
		region:Show()
	else
		region:Hide()
	end
end

return TradeFrames
