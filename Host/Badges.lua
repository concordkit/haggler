--[[
	Badges: what a bag button shows about its item's value, and the overlay that shows it. Bag
	hosts (Host/BagHosts/) find the buttons; this file decides and paints.

	  Badges.decide(value, options) -> Decision      pure; value is an ItemValue or nil
	      options = { showValue, vendorBadge }
	      Decision = { badges = { { kind, icon, color }... }, valueText?, isLowConfidence }
	  Badges.valueLabel(decision, icons) -> string|nil   the value text, marked when low
	  Badges.shortMoney(copper) -> '12g' | '3s' | '45c'
	  Badges.newPainter({ icons, theme }) -> painter
	      painter:Paint(button, decision)   creates the overlay on first use, then reuses it
	      painter:Clear(button)

	Badge kinds:
	  vendor          the vendor pays more than the AH would net (after cut and deposit risk)
	  lowConfidence   the value is a guess; the alert-triangle icon (tooltips keep the text marker).
	                It has no setting, and a shown value carries it inside its own text too, so
	                no corner priority or hidden widget can show a guessed value bare.
	  belowVendorFlip reserved for the flip step: a listing under the vendor price

	A vendor badge needs an AH price to compare with, so an item that only has a vendor price
	(most grey and white items) shows none. Bound items show none either: they can only be sold
	to a vendor anyway.

	Taint: overlay textures and font strings are created on the host's button (allowed in and out
	of combat, never protected) and kept in a weak table keyed by the button. Nothing is written
	onto the button table itself, so Blizzard's code never reads an add-on value.
]]
local _, ns = ...

local Badges = {}
ns.Badges = Badges

Badges.KINDS = {
	vendor = { icon = 'coins', color = 'color.state.warning', point = 'TOPLEFT' },
	lowConfidence = { icon = 'alert-triangle', color = 'color.state.danger', point = 'TOPRIGHT' },
}
Badges.ORDER = { 'vendor', 'lowConfidence' }
Badges.ICON_SIZE = 14
Badges.VALUE_FONT = 'NumberFontNormalSmall'
Badges.VALUE_ICON_SIZE = 10
--- The marker when the icon atlas has no alert-triangle.
Badges.LOW_TEXT_MARKER = '!'
local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD = 10000

-- Helpers live at the bottom of the file; declared here so they stay local.
local isVendorBetter, newOverlay

local PainterMethods = {}
PainterMethods.__index = PainterMethods

--- What a button shows for a value.
--- @param value table|nil ItemValue; nil for an empty slot or an item not loaded yet
--- @param options table { showValue, vendorBadge }
--- @return table Decision
function Badges.decide(value, options)
	if type(options) ~= 'table' then
		error('Badges.decide: needs options', 2)
	end
	local decision = { badges = {}, isLowConfidence = false }
	if type(value) ~= 'table' then
		return decision
	end
	decision.isLowConfidence = type(value.confidence) == 'table' and value.confidence.level == 'low'
	local wanted = {
		vendor = options.vendorBadge and isVendorBetter(value),
		lowConfidence = decision.isLowConfidence,
	}
	for _, kind in ipairs(Badges.ORDER) do
		if wanted[kind] then
			local spec = Badges.KINDS[kind]
			decision.badges[#decision.badges + 1] = { kind = kind, icon = spec.icon, color = spec.color }
		end
	end
	if options.showValue and type(value.copper) == 'number' and value.copper > 0 then
		decision.valueText = Badges.shortMoney(value.copper)
	end
	return decision
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
		overlay = newOverlay(button)
		self.overlays[button] = overlay
	end
	local shown = {}
	for _, badge in ipairs(decision.badges) do
		shown[badge.kind] = true
		self.icons:Apply(overlay.badges[badge.kind], badge.icon, badge.color)
	end
	for kind, texture in pairs(overlay.badges) do
		if not shown[kind] then
			texture:Hide()
		end
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
	for _, texture in pairs(overlay.badges) do
		texture:Hide()
	end
	overlay.value:Hide()
end

--- True when the button has an overlay (for tests and diagnostics).
function PainterMethods:HasOverlay(button)
	return self.overlays[button] ~= nil
end

-- Helpers ---------------------------------------------------------------------------------

function isVendorBetter(value)
	return value.source == 'vendor'
		and value.isPriced == true
		and type(value.vendorNet) == 'number'
		and value.vendorNet > 0
end

function newOverlay(button)
	local overlay = { badges = {} }
	for kind, spec in pairs(Badges.KINDS) do
		local texture = button:CreateTexture(nil, 'OVERLAY')
		texture:SetSize(Badges.ICON_SIZE, Badges.ICON_SIZE)
		texture:SetPoint(spec.point, button, spec.point, 1, -1)
		texture:Hide()
		overlay.badges[kind] = texture
	end
	local value = button:CreateFontString(nil, 'OVERLAY', Badges.VALUE_FONT)
	value:SetPoint('BOTTOMLEFT', button, 'BOTTOMLEFT', 2, 2)
	value:Hide()
	overlay.value = value
	return overlay
end

return Badges
