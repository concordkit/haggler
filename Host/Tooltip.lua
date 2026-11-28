--[[
	Tooltip: the host's item-tooltip line providers. A module adds a provider that returns lines
	for an item; the host draws them under the tooltip's own lines. Haggler only adds its own
	lines: it never changes another add-on's lines or the tooltip's look.

	  Tooltip.new({ wow, theme?, onError? })                     theme defaults to ns.theme
	  tooltips:AddProvider(owner, fun(itemId, info) -> Line[])     replaces the owner's provider
	  tooltips:RemoveProvider(owner)
	  info = { stackCount, location? = { bag, slot }, modifiers = { shift, ctrl, alt } }
	  Line = { left, right?, color?, rightColor? }                  colours { r, g, b }

	Providers run in the order they were added, each under pcall: one that fails adds no lines
	and is reported, the others still draw. The client hook is installed with the first provider
	(Wow:HookItemTooltips) and its handler removed with the last.

	Separators: the block stands between two separators, each a 1px rule on a blank line (the
	DS strong border: color.border.strong at its own alpha, border.hairline physical pixels high). A
	line is blank when its left and right text are blank and no shown money frame sits on it.
	When the line next to the block is already blank, the rule goes on that line and its text is
	left alone; otherwise Haggler adds a ' ' line for it. Haggler cannot know whether a later
	add-on adds lines, so the closing line is added with the block, collapsed to '', and every
	Show of the tooltip settles it: no line after it, no rule; a blank line after it carries the
	rule; any other line opens it up to ' ' with its own rule. A tooltip without OnTooltipCleared
	gets the lines but no separators, since its rules could outlive their lines.
]]
local _, ns = ...

local Tooltip = {}
ns.Tooltip = Tooltip

Tooltip.HOOK_OWNER = 'host'
local WHITE = { r = 1, g = 1, b = 1 }
local SEPARATOR_TEXT = ' '
local COLLAPSED_TEXT = ''
-- The strongest DS border: a 1px rule needs 3:1 on the game's near-black tooltip, which the
-- quieter tooltip border (about 1.8:1 at 60%) did not reach.
local SEPARATOR_COLOR_TOKEN = 'color.border.strong'
local SEPARATOR_HEIGHT_TOKEN = 'border.hairline'
-- The client's left inset of tooltip lines, used when the edges cannot be read yet.
local LINE_INSET = 10
-- The UI's reference height: one physical pixel is 768 / screen height units at scale 1.
local UI_REFERENCE_HEIGHT = 768
local MONEY_FRAME_LIMIT = 20

-- Helpers live at the bottom of the file; declared here so they stay local.
local drawLine, isUsableLine, isBlankText, canDrawSeparators, releaseSeparators, ruleOffset

local TooltipMethods = {}
TooltipMethods.__index = TooltipMethods

--- @param options table { wow, theme?, onError = fun(owner, err)? }
function Tooltip.new(options)
	if type(options) ~= 'table' or not options.wow then
		error('Tooltip.new: needs wow', 2)
	end
	return setmetatable({
		wow = options.wow,
		onError = options.onError,
		theme = options.theme or ns.theme,
		providers = {},
		separatorsByTooltip = setmetatable({}, { __mode = 'k' }),
	}, TooltipMethods)
end

function TooltipMethods:AddProvider(owner, provider)
	if type(owner) ~= 'string' or type(provider) ~= 'function' then
		error('Tooltip:AddProvider: needs an owner and a function', 2)
	end
	self:RemoveProvider(owner)
	self.providers[#self.providers + 1] = { owner = owner, provider = provider }
	if #self.providers == 1 then
		self.wow:HookItemTooltips(Tooltip.HOOK_OWNER, function(tooltip, itemId, stackCount, location)
			self:Render(tooltip, itemId, stackCount, location)
		end)
	end
end

function TooltipMethods:RemoveProvider(owner)
	for index = #self.providers, 1, -1 do
		if self.providers[index].owner == owner then
			table.remove(self.providers, index)
		end
	end
	if #self.providers == 0 then
		self.wow:HookItemTooltips(Tooltip.HOOK_OWNER, nil)
	end
end

function TooltipMethods:HasProviders()
	return #self.providers > 0
end

--- The lines every provider gives for an item.
--- @param itemId number
--- @param info table { stackCount, location?, modifiers }
--- @return table Line[]
function TooltipMethods:Lines(itemId, info)
	local lines = {}
	for _, entry in ipairs(self.providers) do
		local ok, provided = pcall(entry.provider, itemId, info)
		if not ok then
			if self.onError then
				self.onError(entry.owner, provided)
			end
		elseif type(provided) == 'table' then
			for _, line in ipairs(provided) do
				if isUsableLine(line) then
					lines[#lines + 1] = line
				end
			end
		end
	end
	return lines
end

--- Draws the providers' lines on a tooltip; shows it again only when lines were added.
function TooltipMethods:Render(tooltip, itemId, stackCount, location)
	local wow = self.wow
	local info = {
		stackCount = stackCount or 1,
		location = location,
		modifiers = {
			shift = wow:IsModifierDown('shift'),
			ctrl = wow:IsModifierDown('ctrl'),
			alt = wow:IsModifierDown('alt'),
		},
	}
	local lines = self:Lines(itemId, info)
	local separators = self:SeparatorsOf(tooltip)
	if separators then
		releaseSeparators(separators)
	end
	if #lines == 0 then
		return 0
	end
	if separators then
		self:AddSeparatorAbove(tooltip, separators)
	end
	for _, line in ipairs(lines) do
		drawLine(tooltip, line)
	end
	if separators then
		separators.closing = self:AddClosingSeparator(tooltip, separators)
	end
	-- The client sizes a tooltip when it is shown; lines added after that need another Show.
	if tooltip.Show then
		tooltip:Show()
	end
	return #lines
end

--- The separator state of a tooltip that can draw them, hooked on first use; nil otherwise.
function TooltipMethods:SeparatorsOf(tooltip)
	local known = self.separatorsByTooltip[tooltip]
	if known ~= nil then
		return known or nil
	end
	local separators = false
	if self.theme and canDrawSeparators(tooltip) then
		local state = { rules = {}, used = {} }
		local isClearHooked = self.wow:HookFrameScript(tooltip, 'OnTooltipCleared', function()
			releaseSeparators(state)
		end)
		local isShowHooked = isClearHooked
			and self.wow:HookMethod(tooltip, 'Show', function()
				self:SettleClosingSeparator(tooltip, state)
			end)
		if isShowHooked then
			separators = state
		end
	end
	self.separatorsByTooltip[tooltip] = separators
	return separators or nil
end

--- The rule above the block: on the line before when that is blank, else on a new ' ' line.
function TooltipMethods:AddSeparatorAbove(tooltip, separators)
	local index = tooltip:NumLines()
	if index == 0 then
		return
	end
	if not self:IsBlankLine(tooltip, index) then
		tooltip:AddLine(SEPARATOR_TEXT, WHITE.r, WHITE.g, WHITE.b, false)
		index = tooltip:NumLines()
	end
	local rule = self:AcquireRule(tooltip, separators)
	self:PlaceRule(tooltip, rule, index)
	rule:Show()
end

--- The closing line, added collapsed; SettleClosingSeparator opens it when lines follow.
--- @return table closing { index, fontString, text, rule, mode = 'none' | 'borrowed' | 'own' }
function TooltipMethods:AddClosingSeparator(tooltip, separators)
	tooltip:AddLine(SEPARATOR_TEXT, WHITE.r, WHITE.g, WHITE.b, false)
	local index = tooltip:NumLines()
	local fontString = self:LineFontString(tooltip, index)
	if fontString then
		fontString:SetText(COLLAPSED_TEXT)
	end
	local rule = self:AcquireRule(tooltip, separators)
	rule:Hide()
	return { index = index, fontString = fontString, text = COLLAPSED_TEXT, rule = rule, mode = 'none' }
end

function TooltipMethods:AcquireRule(tooltip, separators)
	local rule = separators.rules[#separators.used + 1]
	if not rule then
		rule = tooltip:CreateTexture(nil, 'ARTWORK')
		local color = self.theme:Color(SEPARATOR_COLOR_TOKEN)
		rule:SetColorTexture(color.r, color.g, color.b, color.a)
		-- Older clients lack these; the snapped size and offset keep the rule whole without them.
		if rule.SetSnapToPixelGrid then
			rule:SetSnapToPixelGrid(true)
		end
		if rule.SetTexelSnappingBias then
			rule:SetTexelSnappingBias(0)
		end
		separators.rules[#separators.rules + 1] = rule
	end
	separators.used[#separators.used + 1] = rule
	local pixel = self:PixelSize(tooltip)
	rule:SetHeight(math.max(1, math.floor(self.theme:Number(SEPARATOR_HEIGHT_TOKEN))) * pixel)
	self:SizeRule(tooltip, rule, pixel)
	return rule
end

--- Anchors a rule to a line's top, halfway down it, on a whole physical pixel.
function TooltipMethods:PlaceRule(tooltip, rule, index)
	local fontString = self:LineFontString(tooltip, index)
	rule:ClearAllPoints()
	if fontString then
		rule:SetPoint('TOPLEFT', fontString, 'TOPLEFT', 0, ruleOffset(fontString, self:PixelSize(tooltip)))
	end
end

--- Settles the closing line on every Show, so lines a later add-on adds are seen: no line
--- after it, no rule; a blank line after it carries the rule; any other line opens it up. A
--- change of its text shows the tooltip again to resize it; that Show settles to no change.
function TooltipMethods:SettleClosingSeparator(tooltip, separators)
	local closing = separators.closing
	-- The client can read a line set to '' back as nil.
	if closing and not (closing.fontString and (closing.fontString:GetText() or '') == closing.text) then
		-- Cleared or reused without OnTooltipCleared: the line is no longer Haggler's.
		closing.rule:Hide()
		separators.closing = nil
		closing = nil
	end
	if closing then
		local mode = self:ClosingMode(tooltip, closing.index + 1)
		if mode ~= closing.mode and self:SetClosingMode(tooltip, closing, mode) then
			tooltip:Show()
		end
	end
	local pixel = self:PixelSize(tooltip)
	for _, rule in ipairs(separators.used) do
		self:SizeRule(tooltip, rule, pixel)
	end
end

function TooltipMethods:ClosingMode(tooltip, nextIndex)
	if nextIndex > tooltip:NumLines() then
		return 'none'
	end
	return self:IsBlankLine(tooltip, nextIndex) and 'borrowed' or 'own'
end

--- @return boolean isTextChanged
function TooltipMethods:SetClosingMode(tooltip, closing, mode)
	local text = mode == 'own' and SEPARATOR_TEXT or COLLAPSED_TEXT
	local isTextChanged = text ~= closing.text
	closing.fontString:SetText(text)
	closing.text, closing.mode = text, mode
	if mode == 'none' then
		closing.rule:Hide()
	else
		self:PlaceRule(tooltip, closing.rule, mode == 'own' and closing.index or closing.index + 1)
		closing.rule:Show()
	end
	return isTextChanged
end

--- A rule runs from the lines' left inset to the same inset from the right edge, snapped down
--- to whole physical pixels.
function TooltipMethods:SizeRule(tooltip, rule, pixel)
	local width = tooltip.GetWidth and tooltip:GetWidth()
	if type(width) ~= 'number' then
		return
	end
	local inset = LINE_INSET
	local firstLine = self:LineFontString(tooltip, 1)
	local lineLeft = firstLine and firstLine.GetLeft and firstLine:GetLeft()
	local tooltipLeft = tooltip.GetLeft and tooltip:GetLeft()
	if type(lineLeft) == 'number' and type(tooltipLeft) == 'number' then
		inset = lineLeft - tooltipLeft
	end
	rule:SetWidth(math.max(0, math.floor((width - 2 * inset) / pixel)) * pixel)
end

--- One physical pixel in the tooltip's own units.
function TooltipMethods:PixelSize(tooltip)
	local scale = tooltip.GetEffectiveScale and tooltip:GetEffectiveScale()
	if type(scale) ~= 'number' or scale <= 0 then
		scale = 1
	end
	local pixelUtil = self.wow:Global('PixelUtil')
	if type(pixelUtil) == 'table' and type(pixelUtil.GetPixelToUIUnitFactor) == 'function' then
		local factor = pixelUtil.GetPixelToUIUnitFactor()
		if type(factor) == 'number' and factor > 0 then
			return factor / scale
		end
	end
	local getScreenSize = self.wow:Global('GetPhysicalScreenSize')
	if type(getScreenSize) == 'function' then
		local _, height = getScreenSize()
		if type(height) == 'number' and height > 0 then
			return UI_REFERENCE_HEIGHT / height / scale
		end
	end
	return 1
end

--- Blank: left and right text blank, and no shown money frame (the sell price) on the line.
function TooltipMethods:IsBlankLine(tooltip, index)
	local name = tooltip:GetName()
	local left = self:LineFontString(tooltip, index)
	if not isBlankText(left and left.GetText and left:GetText()) then
		return false
	end
	local right = self.wow:Global(name .. 'TextRight' .. index)
	if right and right.GetText and (not right.IsShown or right:IsShown()) and not isBlankText(right:GetText()) then
		return false
	end
	local leftName = name .. 'TextLeft' .. index
	for moneyIndex = 1, MONEY_FRAME_LIMIT do
		local moneyFrame = self.wow:Global(name .. 'MoneyFrame' .. moneyIndex)
		if not moneyFrame then
			break
		end
		if moneyFrame.IsShown and moneyFrame:IsShown() and moneyFrame.GetPoint then
			local _, relativeTo = moneyFrame:GetPoint(1)
			if relativeTo ~= nil and (relativeTo == left or relativeTo == leftName) then
				return false
			end
		end
	end
	return true
end

--- The client's left font string of a line (<tooltip>TextLeft<n>), or nil.
function TooltipMethods:LineFontString(tooltip, index)
	return self.wow:Global(tooltip:GetName() .. 'TextLeft' .. index)
end

-- Helpers ---------------------------------------------------------------------------------

function drawLine(tooltip, line)
	local color = line.color or WHITE
	if line.right ~= nil then
		local rightColor = line.rightColor or WHITE
		tooltip:AddDoubleLine(
			line.left,
			tostring(line.right),
			color.r,
			color.g,
			color.b,
			rightColor.r,
			rightColor.g,
			rightColor.b
		)
	else
		tooltip:AddLine(line.left, color.r, color.g, color.b, line.wrap == true)
	end
end

function isUsableLine(line)
	return type(line) == 'table' and type(line.left) == 'string'
end

function isBlankText(text)
	return type(text) ~= 'string' or text:match('^%s*$') ~= nil
end

-- A named tooltip with the methods and the OnTooltipCleared script the separators need;
-- another add-on's bare tooltip gets Haggler's lines without them.
function canDrawSeparators(tooltip)
	return type(tooltip.GetName) == 'function'
		and type(tooltip:GetName()) == 'string'
		and type(tooltip.NumLines) == 'function'
		and type(tooltip.CreateTexture) == 'function'
		and type(tooltip.HasScript) == 'function'
		and tooltip:HasScript('OnTooltipCleared') == true
end

function releaseSeparators(separators)
	for _, rule in ipairs(separators.rules) do
		rule:Hide()
	end
	separators.used = {}
	separators.closing = nil
end

-- Halfway down the line, snapped to a whole physical pixel below its top.
function ruleOffset(fontString, pixel)
	local height = fontString.GetHeight and fontString:GetHeight()
	if type(height) ~= 'number' then
		return 0
	end
	return -math.floor(height / 2 / pixel) * pixel
end

return Tooltip
