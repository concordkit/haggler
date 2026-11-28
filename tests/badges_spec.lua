local t = ...
local FakeGame = require('tests.fake_game')
local ns = t.loadAddon()
local Badges, IconSet, Theme = ns.Badges, ns.IconSet, ns.Theme

local theme = Theme.new(ns.Tokens)
local icons = IconSet.new({ theme = theme })
local ALL = { showValue = true, decisionBadge = true, typeBadge = true }
local ALERT_PIXELS = ':68:124:4:60:'
-- Forever's item button (Blizzard_ItemButton/Mainline/ItemButtonTemplate.xml): 37 square, the
-- stack count anchored BOTTOMRIGHT at (-5, 2) in NumberFontNormal, about 14 tall.
local BUTTON_SIZE = 37
local COUNT_BOTTOM = 2
local COUNT_HEIGHT = 14

local function value(fields)
	local result = {
		count = 1,
		copper = 500,
		isPriced = true,
		source = 'ah',
		vendorNet = 13,
		lowestListed = 520,
		typicalPrice = 520,
		confidence = { level = 'high', reasons = {} },
	}
	for key, field in pairs(fields or {}) do
		result[key] = field
	end
	return result
end

local LOW = { level = 'low', reasons = {} }

-- 'slot:kind' for every badge, in order.
local function kinds(decision)
	local result = {}
	for _, badge in ipairs(decision.badges) do
		result[#result + 1] = badge.slot .. ':' .. badge.kind
	end
	return table.concat(result, ',')
end

local function shownTextures(button, sublevel)
	local shown = {}
	for _, child in ipairs(button.children) do
		if child.kind == 'Texture' and child.isShown and (sublevel == nil or child.sublevel == sublevel) then
			shown[#shown + 1] = child
		end
	end
	return shown
end

local function shownGlyphs(button)
	return shownTextures(button, Badges.GLYPH_SUBLEVEL)
end

local function valueText(button)
	for _, child in ipairs(button.children) do
		if child.kind == 'FontString' then
			return child.isShown and child.text or nil
		end
	end
	return nil
end

t.group('icons')

t.test('Lookup returns the atlas texture and texcoords of a known icon', function()
	local icon = icons:Lookup('coins')
	t.eq(icon.texture, IconSet.BASE_PATH .. '2.png')
	t.same(icon.texcoords, { 0.015625, 0.234375, 0.265625, 0.484375 })
	t.eq(icon.size, 56)
	t.eq(icons:Lookup('coins', '2.5').texture, IconSet.BASE_PATH .. '2.5.png')
end)

t.test('unknown icons and weights look up as nil', function()
	t.eq(icons:Lookup('no-such-icon'), nil)
	t.eq(icons:Lookup('coins', '9'), nil)
	t.eq(IconSet.new({ manifest = {} }):Lookup('coins'), nil)
end)

t.test('every manifest weight names an atlas file that ships, with its .png extension', function()
	for _, weight in ipairs(ns.Icons.weights) do
		local path = icons:Lookup('coins', weight).texture
		t.truthy(path:find('%.png$'), path)
		local file = io.open(path:gsub('^Interface\\AddOns\\Haggler\\', ''):gsub('\\', '/'), 'rb')
		t.truthy(file, 'missing ' .. path)
		if file then
			file:close()
		end
	end
end)

t.test('a weight that is not a plain number never becomes a file path', function()
	for _, weight in ipairs({ '2:12', '../x', '2.png', '', '2|t' }) do
		local odd =
			IconSet.new({ manifest = { texcoords = ns.Icons.texcoords, weights = { weight } }, weight = weight })
		t.eq(odd:Lookup('coins'), nil, weight)
	end
end)

t.test('Apply sets, tints and shows a texture; an unknown icon hides it', function()
	local texture = FakeGame.newWidget('Texture')
	t.eq(icons:Apply(texture, 'alert-triangle', 'color.state.danger'), true)
	t.eq(texture.texture, IconSet.BASE_PATH .. '2.png')
	t.same(texture.texcoords, { 0.265625, 0.484375, 0.015625, 0.234375 })
	local danger = theme:Color('color.state.danger')
	t.same(texture.color, { danger.r, danger.g, danger.b, danger.a or 1 })
	t.eq(texture.isShown, true)
	t.eq(icons:Apply(texture, 'no-such-icon'), false)
	t.eq(texture.isShown, false)
end)

t.test('Inline is a tinted |T escape in atlas pixels; unknown icons are empty', function()
	local white = IconSet.new({}):Inline('coins', 12)
	t.eq(white, '|T' .. IconSet.BASE_PATH .. '2.png:12:12:0:0:256:256:4:60:68:124:255:255:255|t')
	t.truthy(icons:Inline('alert-triangle', 12, 'color.state.danger'):find(':68:124:4:60:', 1, true))
	t.eq(icons:Inline('no-such-icon', 12), '')
	t.eq(IconSet.new({ manifest = { texcoords = ns.Icons.texcoords, weights = { '2' } } }):Inline('coins', 12), '')
end)

t.test('every badge icon ships in the atlas, each a distinct shape', function()
	local seen = {}
	for _, styles in ipairs({ Badges.DECISIONS, Badges.TYPES }) do
		for kind, style in pairs(styles) do
			local icon = icons:Lookup(style.icon)
			t.truthy(icon, kind .. ': ' .. style.icon .. ' is missing')
			t.eq(seen[style.icon], nil, style.icon .. ' is used twice')
			seen[style.icon] = kind
		end
	end
end)

t.group('badges: the decision, top left')

t.test('decide: no value, no badges and no text', function()
	t.same(Badges.decide(nil, ALL), { badges = {}, isLowConfidence = false })
	t.raises(function()
		Badges.decide(value())
	end, 'needs options')
end)

t.test('decide: each state of the advice gets its own badge', function()
	t.eq(kinds(Badges.decide(value(), ALL)), 'decision:post')
	t.eq(kinds(Badges.decide(value({ source = 'vendor', copper = 13, typicalPrice = 12 }), ALL)), 'decision:sell')
	t.eq(kinds(Badges.decide(value({ lowestListed = 100 }), ALL)), 'decision:wait')
	t.eq(kinds(Badges.decide(value({ confidence = LOW }), ALL)), 'decision:undecided')
end)

t.test('decide: the icons are the DS ones; the gavel is Post and the cart never is', function()
	local function badgeOf(fields)
		return Badges.decide(value(fields), ALL).badges[1]
	end
	t.eq(badgeOf().icon, 'gavel')
	t.eq(badgeOf({ source = 'vendor', copper = 13, typicalPrice = 12 }).icon, 'store')
	t.eq(badgeOf({ lowestListed = 100 }).icon, 'hourglass')
	t.eq(badgeOf({ confidence = LOW }).icon, IconSet.LOW_CONFIDENCE)
	t.eq(badgeOf({ confidence = LOW }).color, IconSet.LOW_CONFIDENCE_COLOR)
	for _, style in pairs(Badges.DECISIONS) do
		t.truthy(style.icon ~= 'shopping-cart' and style.icon ~= 'coins', style.icon)
		t.eq(type(style.label), 'string')
		t.truthy(theme:Color(style.color), style.color .. ' is a token')
	end
end)

t.test('decide: the post/wait edge follows Advice', function()
	local threshold = ns.Advice.WAIT_UNDER_TYPICAL_PERCENT
	local typical = 10000
	local function at(percent)
		return kinds(Badges.decide(value({ typicalPrice = typical, lowestListed = typical - percent * 100 }), ALL))
	end
	t.eq(at(threshold - 1), 'decision:post')
	t.eq(at(threshold), 'decision:wait')
end)

t.test('decide: a vendor-only item is sell; a bound item gets no decision', function()
	local vendorOnly = value({ source = 'vendor', isPriced = false, lowestListed = false, typicalPrice = false })
	vendorOnly.confidence = { level = 'medium', reasons = {} }
	t.eq(kinds(Badges.decide(vendorOnly, ALL)), 'decision:sell')
	t.eq(kinds(Badges.decide(value({ source = 'vendor' }), ALL, { isBound = true })), '')
end)

t.test('decide: the decision badge setting hides it; the low marker in the value stays', function()
	local decision = Badges.decide(value({ confidence = LOW }), { showValue = true, typeBadge = true })
	t.eq(kinds(decision), '')
	t.eq(decision.isLowConfidence, true)
	t.eq(decision.advice.decision, 'undecided', 'the advice is kept for the tooltip')
end)

t.group('badges: the item type, top right')

t.test('decide: a quest item gets the quest badge and no decision', function()
	t.eq(kinds(Badges.decide(value(), ALL, { isQuest = true })), 'type:quest')
	t.eq(kinds(Badges.decide(nil, ALL, { isQuest = true })), 'type:quest', 'a quest item with no value')
	t.eq(Badges.decide(nil, ALL, { isQuest = true }).badges[1].icon, 'flag')
end)

t.test('decide: junk gets the junk badge; selling it needs no second badge', function()
	local junk = value({ source = 'vendor', isPriced = false, copper = 13, lowestListed = false, typicalPrice = false })
	junk.confidence = { level = 'medium', reasons = {} }
	t.eq(kinds(Badges.decide(junk, ALL, { isJunk = true })), 'type:junk')
	t.eq(Badges.decide(junk, ALL, { isJunk = true }).badges[1].icon, 'recycle')
	t.eq(kinds(Badges.decide(value(), ALL, { isJunk = true })), 'decision:post,type:junk', 'a grey that posts')
end)

t.test('decide: any other item gets no type badge', function()
	t.eq(kinds(Badges.decide(value(), ALL, {})), 'decision:post')
	t.eq(kinds(Badges.decide(value(), ALL)), 'decision:post')
end)

t.test('decide: quest wins over junk; the type badge setting hides both', function()
	t.eq(kinds(Badges.decide(value(), ALL, { isQuest = true, isJunk = true })), 'type:quest')
	local noType = { showValue = true, decisionBadge = true, typeBadge = false }
	t.eq(kinds(Badges.decide(value(), noType, { isQuest = true })), '')
	t.eq(kinds(Badges.decide(value(), noType, { isJunk = true })), 'decision:post')
end)

t.group('badges: value text')

t.test('decide: the value text needs the setting and a positive value', function()
	t.eq(Badges.decide(value({ copper = 123456 }), ALL).valueText, '12g')
	t.eq(Badges.decide(value({ copper = 123456 }), { showValue = false }).valueText, nil)
	t.eq(Badges.decide(value({ copper = 0 }), ALL).valueText, nil)
end)

t.test('shortMoney shows the largest whole coin', function()
	t.eq(Badges.shortMoney(0), '0c')
	t.eq(Badges.shortMoney(99), '99c')
	t.eq(Badges.shortMoney(100), '1s')
	t.eq(Badges.shortMoney(9999), '99s')
	t.eq(Badges.shortMoney(10000), '1g')
	t.eq(Badges.shortMoney('junk'), '0c')
end)

t.group('badges: placement and outline')

t.test('the decision sits top left, the type top right, both inset on whole pixels', function()
	t.eq(Badges.SLOTS.decision.point, 'TOPLEFT')
	t.eq(Badges.SLOTS.type.point, 'TOPRIGHT')
	t.eq(Badges.ICON_SIZE, theme:Number('size.icon.xs'))
	for _, slot in pairs(Badges.SLOTS) do
		t.eq(slot.x % 1, 0)
		t.eq(slot.y % 1, 0)
	end
end)

t.test('no badge reaches the stack count, outline included', function()
	local outline = Badges.outlineWidth(theme)
	local countTopFromTop = BUTTON_SIZE - COUNT_BOTTOM - COUNT_HEIGHT
	for name, slot in pairs(Badges.SLOTS) do
		local badgeBottomFromTop = math.abs(slot.y) + Badges.ICON_SIZE + outline
		t.truthy(badgeBottomFromTop < countTopFromTop, name .. ' reaches ' .. badgeBottomFromTop)
		t.truthy(slot.point:find('^TOP'), name .. ' sits on the top edge, away from the count')
	end
end)

t.test('the outline width is a token in whole pixels, at least one', function()
	t.eq(Badges.OUTLINE_COLOR, 'color.text.shadow')
	t.eq(Badges.OUTLINE_WIDTH, 'border.hairline')
	t.eq(Badges.outlineWidth(theme), theme:Number('border.hairline'))
	local odd = {
		Number = function()
			return 1.6
		end,
	}
	t.eq(Badges.outlineWidth(odd), 2, 'rounded to a whole pixel')
	t.eq(
		Badges.outlineWidth({
			Number = function()
				return 0
			end,
		}),
		1,
		'a missing token still outlines'
	)
	t.eq(Badges.outlineWidth(nil), 1)
end)

t.test('the painter draws each badge over a dark outline at its corner', function()
	local painter = Badges.newPainter({ icons = icons, theme = theme })
	local button = FakeGame.newWidget('Button')
	painter:Paint(button, Badges.decide(value(), ALL, { isJunk = true }))
	local glyphs = shownGlyphs(button)
	t.eq(#glyphs, 2)
	local shadow = theme:Color('color.text.shadow')
	local outlines = shownTextures(button, Badges.OUTLINE_SUBLEVEL)
	t.eq(#outlines, 2 * #Badges.OUTLINE_OFFSETS)
	for _, outline in ipairs(outlines) do
		t.same(outline.color, { shadow.r, shadow.g, shadow.b, shadow.a or 1 })
		t.eq(outline.layer, 'OVERLAY')
	end
	t.truthy(Badges.GLYPH_SUBLEVEL > Badges.OUTLINE_SUBLEVEL, 'the glyph draws over its outline')
	local width = Badges.outlineWidth(theme)
	for _, glyph in ipairs(glyphs) do
		local point, _, _, x, y = glyph:GetPoint(1)
		t.truthy(point == 'TOPLEFT' or point == 'TOPRIGHT', point)
		t.eq(math.abs(x), Badges.INSET)
		t.eq(y, -Badges.INSET)
	end
	local offsets = {}
	for _, outline in ipairs(outlines) do
		local point, _, _, x, y = outline:GetPoint(1)
		if point == 'TOPLEFT' then
			offsets[#offsets + 1] = (x - Badges.INSET) .. ',' .. (y + Badges.INSET)
		end
	end
	table.sort(offsets)
	local expected = {}
	for _, offset in ipairs(Badges.OUTLINE_OFFSETS) do
		expected[#expected + 1] = (offset[1] * width) .. ',' .. (offset[2] * width)
	end
	table.sort(expected)
	t.same(offsets, expected)
end)

t.test('the painter creates an overlay only when there is something to show, then reuses it', function()
	local painter = Badges.newPainter({ icons = icons, theme = theme })
	local button = FakeGame.newWidget('Button')
	painter:Paint(button, { badges = {} })
	t.eq(painter:HasOverlay(button), false)
	t.eq(#button.children, 0)
	painter:Paint(button, Badges.decide(value({ source = 'vendor', copper = 250, typicalPrice = 12 }), ALL))
	t.eq(painter:HasOverlay(button), true)
	local childCount = #button.children
	t.eq(#shownGlyphs(button), 1)
	t.eq(valueText(button), '2s')
	painter:Paint(button, Badges.decide(value({ confidence = LOW }), ALL))
	t.eq(#button.children, childCount, 'no new regions')
	local shown = shownGlyphs(button)
	t.eq(#shown, 1)
	t.same(shown[1].texcoords, { 0.265625, 0.484375, 0.015625, 0.234375 }, 'the alert-triangle')
	painter:Paint(button, Badges.decide(nil, ALL, { isQuest = true }))
	t.eq(#button.children, childCount, 'still no new regions')
	t.eq(#shownGlyphs(button), 1)
	t.eq(#shownTextures(button, Badges.OUTLINE_SUBLEVEL), #Badges.OUTLINE_OFFSETS)
	painter:Clear(button)
	t.eq(#shownTextures(button), 0)
	t.eq(valueText(button), nil)
	painter:Clear(FakeGame.newWidget('Button'))
end)

t.test('the painter writes nothing onto the button table', function()
	local painter = Badges.newPainter({ icons = icons })
	local button = FakeGame.newWidget('Button')
	local keys = {}
	for key in pairs(button) do
		keys[key] = true
	end
	painter:Paint(button, Badges.decide(value(), ALL, { isQuest = true }))
	for key in pairs(button) do
		t.truthy(keys[key], 'new field ' .. tostring(key))
	end
	t.raises(function()
		Badges.newPainter({})
	end, 'needs icons')
end)

t.group('badges: the tooltip word')

t.test('decisionLabel puts the badge glyph, at the line height, next to the word', function()
	for kind, style in pairs(Badges.DECISIONS) do
		local label = Badges.decisionLabel(kind, icons)
		local glyph = icons:Inline(style.icon, Badges.TOOLTIP_ICON_SIZE, style.color)
		t.truthy(glyph ~= '', kind)
		t.eq(label, glyph .. ' ' .. style.label, kind)
	end
	t.eq(Badges.TOOLTIP_ICON_SIZE, 0, 'an |T height of 0 follows the font height')
	t.eq(Badges.decisionLabel('post', IconSet.new({ manifest = {} })), Badges.DECISIONS.post.label, 'no atlas')
	t.eq(Badges.decisionLabel('nonsense', icons), nil)
end)

t.test('a low value carries its marker inside the value text; no setting removes it', function()
	local low = value({ copper = 250, confidence = { level = 'low', reasons = {} } })
	local decision = Badges.decide(low, { showValue = true, lowBadge = false })
	t.eq(decision.isLowConfidence, true)
	local label = Badges.valueLabel(decision, icons)
	t.truthy(label:find(ALERT_PIXELS, 1, true), label)
	t.truthy(label:find('2s', 1, true), label)
	t.eq(Badges.valueLabel(Badges.decide(value({ copper = 250 }), ALL), icons), '2s', 'high: bare')
	t.eq(Badges.valueLabel(Badges.decide(low, { showValue = false }), icons), nil, 'no value text')
	local noIcons = IconSet.new({ manifest = {} })
	t.eq(Badges.valueLabel(decision, noIcons), '! 2s', 'a text marker when the icon is missing')
	local painter = Badges.newPainter({ icons = icons, theme = theme })
	local button = FakeGame.newWidget('Button')
	painter:Paint(button, decision)
	t.truthy(valueText(button):find(ALERT_PIXELS, 1, true), valueText(button))
end)

t.test('Baganator: the value widget text carries the low marker', function()
	local lowValue = value({ copper = 250, confidence = { level = 'low', reasons = {} } })
	local view = ns.BagView.new({
		wow = {},
		icons = icons,
		painter = Badges.newPainter({ icons = icons }),
		values = function()
			return {
				Context = function()
					return {}
				end,
				Stack = function()
					return lowValue
				end,
			}
		end,
		options = function()
			return { showValue = true }
		end,
		isActive = function()
			return true
		end,
		money = tostring,
	})
	local region = FakeGame.newWidget('FontString')
	local isShown = ns.BagHostBaganator.update({ region = 'text' }, region, { itemID = 2589, itemCount = 1 }, view)
	t.eq(isShown, true)
	t.truthy(region.text:find(ALERT_PIXELS, 1, true), region.text)
end)
