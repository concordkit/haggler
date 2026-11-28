--[[
	Tooltip: the host's item-tooltip line providers. A module adds a provider that returns lines
	for an item; the host draws them under the tooltip's own lines. Haggler only adds its own
	lines: it never changes another add-on's lines or the tooltip's look.

	  Tooltip.new({ wow, theme?, onError? })                     theme defaults to ns.theme
	  tooltips:AddProvider(owner, fun(itemId, info) -> Line[])     replaces the owner's provider
	  tooltips:RemoveProvider(owner)
	  info = { stackCount, modifiers = { shift, ctrl, alt } }
	  Line = { left, right?, color?, rightColor? }                  colours { r, g, b }

	Providers run in the order they were added, each under pcall: one that fails adds no lines
	and is reported, the others still draw. The client hook is installed with the first provider
	(Wow:HookItemTooltips) and its handler removed with the last.

	Separators: the block stands between two separators, each a blank line with a 1px rule (the
	DS surface hairline: color.border.tooltip at 60%, border.hairline high). The one above is
	left out when the line before is already blank. The one below is added with the block but
	shown only while another line follows it that is not blank: Haggler cannot know whether a
	later add-on adds lines, so every Show of the tooltip settles it, and as the tooltip's last
	line it collapses to an empty line with its rule hidden.
]]
local _, ns = ...

local Tooltip = {}
ns.Tooltip = Tooltip

Tooltip.HOOK_OWNER = 'host'
local WHITE = { r = 1, g = 1, b = 1 }
local SEPARATOR_TEXT = ' '
local COLLAPSED_TEXT = ''
local SEPARATOR_COLOR_TOKEN = 'color.border.tooltip'
local SEPARATOR_HEIGHT_TOKEN = 'border.hairline'
-- The DS surface hairline is a quiet frame at 60% of its colour.
local SEPARATOR_ALPHA = 0.6
-- The client's left inset of tooltip lines, used when the edges cannot be read yet.
local LINE_INSET = 10

-- Helpers live at the bottom of the file; declared here so they stay local.
local drawLine, isUsableLine, isBlankText, canDrawSeparators, releaseSeparators, sizeRules

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
		self.wow:HookItemTooltips(Tooltip.HOOK_OWNER, function(tooltip, itemId, stackCount)
			self:Render(tooltip, itemId, stackCount)
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
--- @param info table { stackCount, modifiers }
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
function TooltipMethods:Render(tooltip, itemId, stackCount)
	local wow = self.wow
	local info = {
		stackCount = stackCount or 1,
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
	if separators and not isBlankText(self:LineText(tooltip, tooltip:NumLines())) then
		self:AddSeparator(tooltip, separators)
	end
	for _, line in ipairs(lines) do
		drawLine(tooltip, line)
	end
	if separators then
		separators.closing = self:AddSeparator(tooltip, separators)
		self:SetSeparatorShown(separators.closing, false)
	end
	-- The client sizes a tooltip when it is shown; lines added after that need another Show.
	if tooltip.Show then
		tooltip:Show()
	end
	return #lines
end

--- The separator state of a tooltip that can draw them, hooked on first use; nil otherwise.
function TooltipMethods:SeparatorsOf(tooltip)
	local separators = self.separatorsByTooltip[tooltip]
	if separators then
		return separators
	end
	if not canDrawSeparators(tooltip) or not self.theme then
		return nil
	end
	separators = { rules = {}, used = {} }
	self.separatorsByTooltip[tooltip] = separators
	self.wow:HookMethod(tooltip, 'Show', function()
		self:SettleClosingSeparator(tooltip, separators)
	end)
	self.wow:HookFrameScript(tooltip, 'OnTooltipCleared', function()
		releaseSeparators(separators)
	end)
	return separators
end

--- Adds a blank line with a rule on it.
--- @return table separator { index, fontString, rule, isShown }
function TooltipMethods:AddSeparator(tooltip, separators)
	tooltip:AddLine(SEPARATOR_TEXT, WHITE.r, WHITE.g, WHITE.b, false)
	local index = tooltip:NumLines()
	local fontString = self:LineFontString(tooltip, index)
	local rule = self:AcquireRule(tooltip, separators)
	rule:ClearAllPoints()
	if fontString then
		rule:SetPoint('LEFT', fontString, 'LEFT', 0, 0)
	end
	rule:Show()
	local separator = { index = index, fontString = fontString, rule = rule, isShown = true }
	separators.used[#separators.used + 1] = separator
	return separator
end

function TooltipMethods:AcquireRule(tooltip, separators)
	local rule = separators.rules[#separators.used + 1]
	if rule then
		return rule
	end
	rule = tooltip:CreateTexture(nil, 'ARTWORK')
	local color = self.theme:Color(SEPARATOR_COLOR_TOKEN)
	rule:SetColorTexture(color.r, color.g, color.b, SEPARATOR_ALPHA)
	local height = math.max(1, math.floor(self.theme:Number(SEPARATOR_HEIGHT_TOKEN)))
	local pixelUtil = self.wow:Global('PixelUtil')
	if type(pixelUtil) == 'table' and type(pixelUtil.SetHeight) == 'function' then
		-- Whole screen pixels at any UI scale.
		pixelUtil.SetHeight(rule, height)
	else
		rule:SetHeight(height)
	end
	separators.rules[#separators.rules + 1] = rule
	return rule
end

--- Shows the closing separator only while a line that is not blank follows it; runs on every
--- Show, so lines a later add-on adds are seen. A change shows the tooltip again to resize it.
function TooltipMethods:SettleClosingSeparator(tooltip, separators)
	if separators.isSettling then
		return
	end
	local closing = separators.closing
	if closing then
		local nextIndex = closing.index + 1
		local shouldShow = nextIndex <= tooltip:NumLines() and not isBlankText(self:LineText(tooltip, nextIndex))
		if shouldShow ~= closing.isShown then
			self:SetSeparatorShown(closing, shouldShow)
			separators.isSettling = true
			tooltip:Show()
			separators.isSettling = false
		end
	end
	sizeRules(tooltip, separators)
end

function TooltipMethods:SetSeparatorShown(separator, isShown)
	separator.isShown = isShown
	if separator.fontString then
		separator.fontString:SetText(isShown and SEPARATOR_TEXT or COLLAPSED_TEXT)
	end
	separator.rule:SetShown(isShown)
end

--- The client's left font string of a line (<tooltip>TextLeft<n>), or nil.
function TooltipMethods:LineFontString(tooltip, index)
	return self.wow:Global(tooltip:GetName() .. 'TextLeft' .. index)
end

function TooltipMethods:LineText(tooltip, index)
	local fontString = index > 0 and self:LineFontString(tooltip, index)
	return fontString and fontString.GetText and fontString:GetText()
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

-- A named tooltip with the methods the separators need; another add-on's bare tooltip gets
-- Haggler's lines without them.
function canDrawSeparators(tooltip)
	return type(tooltip.GetName) == 'function'
		and type(tooltip:GetName()) == 'string'
		and type(tooltip.NumLines) == 'function'
		and type(tooltip.CreateTexture) == 'function'
end

function releaseSeparators(separators)
	for _, rule in ipairs(separators.rules) do
		rule:Hide()
	end
	separators.used = {}
	separators.closing = nil
end

-- A rule runs from the lines' left inset to the same inset from the right edge, in whole pixels.
function sizeRules(tooltip, separators)
	local width = tooltip.GetWidth and tooltip:GetWidth()
	if type(width) ~= 'number' then
		return
	end
	for _, separator in ipairs(separators.used) do
		local inset = LINE_INSET
		local lineLeft = separator.fontString and separator.fontString.GetLeft and separator.fontString:GetLeft()
		local tooltipLeft = tooltip.GetLeft and tooltip:GetLeft()
		if type(lineLeft) == 'number' and type(tooltipLeft) == 'number' then
			inset = lineLeft - tooltipLeft
		end
		separator.rule:SetWidth(math.max(0, math.floor(width - 2 * inset)))
	end
end

return Tooltip
