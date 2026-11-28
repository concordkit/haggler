--[[
	Badges: what a bag button shows about its item, and the overlay that shows it. Bag hosts
	(Host/BagHosts/) find the buttons; this file decides and paints.

	  Badges.decide(value, options, item?) -> Decision     pure; value is an ItemValue or nil
	      options = { showValue, decisionBadge, typeBadge }
	      item    = { isBound?, isQuest?, isJunk? }
	      Decision = { badges = { { slot, kind, icon, color }... }, advice?, valueText?,
	                   isLowConfidence }
	  Badges.decisionLabel(kind, icons) -> string|nil   the badge glyph and its word, for a tooltip
	  Badges.valueLabel(decision, icons) -> string|nil   the value text, marked when low
	  Badges.shortMoney(copper) -> '12g' | '3s' | '45c'
	  Badges.outlineWidth(theme) -> whole pixels, at least 1
	  Badges.newPainter({ icons, theme }) -> painter
	      painter:Paint(button, decision)   creates the overlay on first use, then reuses it
	      painter:Clear(button)
	      painter:NewBadgeFrame(frame)      a frame of its own that shows one badge (Baganator)
	      painter:PaintBadgeFrame(frame, badge|nil)

	Two slots, one badge each:
	  decision  top left    what to do with the item (Advice.forItem): post (gavel), sell (store),
	                        wait (hourglass) or undecided (the low-confidence triangle, caution)
	  type      top right   quest (flag) or junk (recycle: a grey the vendor pays for); nothing
	                        for any other item. Quest wins over junk.
	Bound and quest items get no decision: they cannot go to the AH. Junk that should be sold
	shows only the junk badge, which already says so. A shown value carries the low marker inside
	its own text too, so no setting or hidden widget can show a guessed value bare.

	Both slots sit on the top edge, clear of the stack count (bottom right) and the value text
	(bottom left). Each glyph sits over four copies of itself in the outline colour, offset by
	the outline width left, right, up and down (the DS glyph outline): a dark edge that keeps it
	readable on any item icon. While the client shows its junk coin or upgrade arrow on a button
	(both top left), the decision badge stays off it; the tooltip's Decision line still names it.
	A badge is retextured only when its icon or colour changes.

	Taint: overlay textures and font strings are created on the host's button (allowed in and out
	of combat, never protected) and kept in a weak table keyed by the button. Nothing is written
	onto the button table itself, so Blizzard's code never reads an add-on value.
]]
local _, ns = ...

local Badges = {}
ns.Badges = Badges

Badges.DECISIONS = {
	post = { icon = 'gavel', color = 'color.state.success', label = 'Post' },
	sell = { icon = 'store', color = 'color.state.info', label = 'Sell' },
	wait = { icon = 'hourglass', color = 'color.text.secondary', label = 'Wait' },
	undecided = { icon = ns.IconSet.LOW_CONFIDENCE, color = ns.IconSet.LOW_CONFIDENCE_COLOR, label = 'Undecided' },
}
Badges.TYPES = {
	quest = { icon = 'flag', color = 'color.text.accent', label = 'Quest' },
	junk = { icon = 'recycle', color = 'color.text.muted', label = 'Junk' },
}
-- Off the 8px grid by design: the item icon art fills the 37px button nearly to its edge, so a
-- grid step (8) would sink the badge well into the art; 2 is the smallest whole inset that keeps
-- the outline inside the button.
Badges.INSET = 2
Badges.SLOTS = {
	decision = { point = 'TOPLEFT', x = Badges.INSET, y = -Badges.INSET },
	type = { point = 'TOPRIGHT', x = -Badges.INSET, y = -Badges.INSET },
}
Badges.SLOT_ORDER = { 'decision', 'type' }
-- size.icon.xs
Badges.ICON_SIZE = 16
Badges.OUTLINE_COLOR = 'color.text.shadow'
Badges.OUTLINE_WIDTH = 'border.hairline'
Badges.OUTLINE_OFFSETS = { { -1, 0 }, { 1, 0 }, { 0, 1 }, { 0, -1 } }
-- The client's own top-left marks on a Blizzard-style item button; the decision badge yields to them.
Badges.CLIENT_TOP_LEFT_MARKS = { 'JunkIcon', 'UpgradeIcon' }
-- Above the client's own junk coin (OVERLAY 5) and quest border (OVERLAY 2).
Badges.OUTLINE_SUBLEVEL = 6
Badges.GLYPH_SUBLEVEL = 7
-- An |T height of 0 follows the font height of the line.
Badges.TOOLTIP_ICON_SIZE = 0
Badges.VALUE_FONT = 'NumberFontNormalSmall'
Badges.VALUE_ICON_SIZE = 10
--- The marker when the icon atlas has no triangle-alert.
Badges.LOW_TEXT_MARKER = '!'
local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD = 10000

-- Helpers live at the bottom of the file; declared here so they stay local.
local decisionBadge, typeBadge, newBadge, newOverlay, newGroup, paintGroup, hideGroup, isClientMarkingTopLeft

local PainterMethods = {}
PainterMethods.__index = PainterMethods

--- What a button shows for an item.
--- @param value table|nil ItemValue; nil for an empty slot or an item not loaded yet
--- @param options table { showValue, decisionBadge, typeBadge }
--- @param item table|nil { isBound?, isQuest?, isJunk? }
--- @return table Decision
function Badges.decide(value, options, item)
	if type(options) ~= 'table' then
		error('Badges.decide: needs options', 2)
	end
	item = type(item) == 'table' and item or {}
	local decision = { badges = {}, isLowConfidence = false }
	if type(value) == 'table' then
		decision.isLowConfidence = type(value.confidence) == 'table' and value.confidence.level == 'low'
		decision.advice = ns.Advice.forItem(value, item)
		if options.showValue and type(value.copper) == 'number' and value.copper > 0 then
			decision.valueText = Badges.shortMoney(value.copper)
		end
	end
	local typeKind = options.typeBadge and typeBadge(item) or nil
	local adviceKind = decision.advice and decision.advice.decision
	local isSaidByType = typeKind == 'junk' and adviceKind == 'sell'
	if options.decisionBadge and adviceKind and not isSaidByType then
		decision.badges[#decision.badges + 1] = decisionBadge(adviceKind)
	end
	if typeKind then
		decision.badges[#decision.badges + 1] = newBadge('type', typeKind, Badges.TYPES[typeKind])
	end
	return decision
end

--- The decision's badge glyph at the line height, then its word, for a tooltip line.
--- @param kind string 'post'|'sell'|'wait'|'undecided'
--- @param icons table IconSet
--- @return string|nil nil for an unknown kind; the word alone when the atlas lacks the icon
function Badges.decisionLabel(kind, icons)
	local style = Badges.DECISIONS[kind]
	if not style then
		return nil
	end
	local glyph = icons:Inline(style.icon, Badges.TOOLTIP_ICON_SIZE, style.color)
	return glyph ~= '' and (glyph .. ' ' .. style.label) or style.label
end

--- The value text a button shows, with the low-confidence marker in front when the value is a
--- guess (an inline icon, or LOW_TEXT_MARKER when the atlas lacks it).
--- @param decision table Decision
--- @param icons table IconSet
--- @return string|nil nil when the decision has no value text
function Badges.valueLabel(decision, icons)
	local text = decision.valueText
	if not text or not decision.isLowConfidence then
		return text
	end
	local marker = icons:Inline(ns.IconSet.LOW_CONFIDENCE, Badges.VALUE_ICON_SIZE, ns.IconSet.LOW_CONFIDENCE_COLOR)
	return (marker ~= '' and marker or Badges.LOW_TEXT_MARKER) .. ' ' .. text
end

--- Copper in the largest whole coin, for a small button label.
function Badges.shortMoney(copper)
	copper = math.floor(tonumber(copper) or 0)
	if copper >= COPPER_PER_GOLD then
		return math.floor(copper / COPPER_PER_GOLD) .. 'g'
	end
	if copper >= COPPER_PER_SILVER then
		return math.floor(copper / COPPER_PER_SILVER) .. 's'
	end
	return copper .. 'c'
end

--- The outline width from its token, rounded to whole pixels; never under one.
--- @param theme table|nil Theme
--- @return number
function Badges.outlineWidth(theme)
	local width = theme and type(theme.Number) == 'function' and tonumber(theme:Number(Badges.OUTLINE_WIDTH)) or 0
	return math.max(1, math.floor(width + 0.5))
end

--- @param options table { icons = IconSet, theme = Theme }
--- @return table painter
function Badges.newPainter(options)
	if type(options) ~= 'table' or not options.icons then
		error('Badges.newPainter: needs icons', 2)
	end
	return setmetatable({
		icons = options.icons,
		theme = options.theme,
		overlays = setmetatable({}, { __mode = 'k' }),
		badgeFrames = setmetatable({}, { __mode = 'k' }),
	}, PainterMethods)
end

--- Shows a decision on a button. A button that never had a badge or value gets no overlay.
function PainterMethods:Paint(button, decision)
	local overlay = self.overlays[button]
	local hasContent = #decision.badges > 0 or decision.valueText ~= nil
	if not overlay then
		if not hasContent then
			return
		end
		overlay = newOverlay(button, Badges.outlineWidth(self.theme))
		self.overlays[button] = overlay
	end
	local bySlot = {}
	for _, badge in ipairs(decision.badges) do
		bySlot[badge.slot] = badge
	end
	if isClientMarkingTopLeft(button) then
		bySlot.decision = nil
	end
	for _, slot in ipairs(Badges.SLOT_ORDER) do
		paintGroup(overlay.groups[slot], bySlot[slot], self.icons)
	end
	if decision.valueText then
		overlay.value:SetText(Badges.valueLabel(decision, self.icons))
		overlay.value:Show()
	else
		overlay.value:Hide()
	end
end

function PainterMethods:Clear(button)
	local overlay = self.overlays[button]
	if not overlay then
		return
	end
	for _, group in pairs(overlay.groups) do
		hideGroup(group)
	end
	overlay.value:Hide()
end

--- True when the button has an overlay (for tests and diagnostics).
function PainterMethods:HasOverlay(button)
	return self.overlays[button] ~= nil
end

--- Fills a frame of Haggler's own with one badge's glyph and outline, centred in it; the frame
--- is sized to hold the outline. For hosts that place and hide a region themselves.
--- @param frame table
--- @return table frame
function PainterMethods:NewBadgeFrame(frame)
	local width = Badges.outlineWidth(self.theme)
	local side = Badges.ICON_SIZE + 2 * width
	frame:SetSize(side, side)
	self.badgeFrames[frame] = newGroup(frame, 'CENTER', 0, 0, width)
	return frame
end

--- Shows a badge in a frame from NewBadgeFrame; nil hides it.
--- @return boolean shown
function PainterMethods:PaintBadgeFrame(frame, badge)
	local group = self.badgeFrames[frame]
	if not group then
		return false
	end
	return paintGroup(group, badge, self.icons)
end

-- Helpers ---------------------------------------------------------------------------------

function decisionBadge(kind)
	return newBadge('decision', kind, Badges.DECISIONS[kind])
end

function typeBadge(item)
	if item.isQuest == true then
		return 'quest'
	end
	if item.isJunk == true then
		return 'junk'
	end
	return nil
end

function newBadge(slot, kind, style)
	return { slot = slot, kind = kind, icon = style.icon, color = style.color }
end

function newOverlay(button, outlineWidth)
	local overlay = { groups = {} }
	for name, slot in pairs(Badges.SLOTS) do
		overlay.groups[name] = newGroup(button, slot.point, slot.x, slot.y, outlineWidth)
	end
	local value = button:CreateFontString(nil, 'OVERLAY', Badges.VALUE_FONT)
	value:SetPoint('BOTTOMLEFT', button, 'BOTTOMLEFT', 2, 2)
	value:Hide()
	overlay.value = value
	return overlay
end

-- One badge: its outline copies first (drawn under), then the glyph.
function newGroup(parent, point, x, y, outlineWidth)
	local function newTexture(sublevel, dx, dy)
		local texture = parent:CreateTexture(nil, 'OVERLAY', nil, sublevel)
		texture:SetSize(Badges.ICON_SIZE, Badges.ICON_SIZE)
		texture:SetPoint(point, parent, point, x + dx, y + dy)
		texture:Hide()
		return texture
	end
	local group = { outlines = {} }
	for _, offset in ipairs(Badges.OUTLINE_OFFSETS) do
		group.outlines[#group.outlines + 1] =
			newTexture(Badges.OUTLINE_SUBLEVEL, offset[1] * outlineWidth, offset[2] * outlineWidth)
	end
	group.glyph = newTexture(Badges.GLYPH_SUBLEVEL, 0, 0)
	return group
end

-- The textures keep what they were last given, so the same icon and colour only need showing.
function paintGroup(group, badge, icons)
	if not badge then
		hideGroup(group)
		return false
	end
	local paintedKey = badge.icon .. '|' .. badge.color
	if group.paintedKey == paintedKey then
		group.glyph:Show()
		for _, outline in ipairs(group.outlines) do
			outline:Show()
		end
		return true
	end
	group.paintedKey = nil
	if not icons:Apply(group.glyph, badge.icon, badge.color) then
		hideGroup(group)
		return false
	end
	for _, outline in ipairs(group.outlines) do
		icons:Apply(outline, badge.icon, Badges.OUTLINE_COLOR)
	end
	group.paintedKey = paintedKey
	return true
end

function hideGroup(group)
	group.glyph:Hide()
	for _, outline in ipairs(group.outlines) do
		outline:Hide()
	end
end

-- Reads the button's own regions only (never writes): reading a Blizzard field taints nothing.
function isClientMarkingTopLeft(button)
	for _, key in ipairs(Badges.CLIENT_TOP_LEFT_MARKS) do
		local mark = rawget(button, key)
		if type(mark) == 'table' and type(mark.IsShown) == 'function' and mark:IsShown() then
			return true
		end
	end
	return false
end

return Badges
