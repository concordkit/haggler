local t = ...
local FakeGame = require('tests.fake_game')
local ns = t.loadAddon()
local Badges, IconSet, Theme = ns.Badges, ns.IconSet, ns.Theme

local theme = Theme.new(ns.Tokens)
local icons = IconSet.new({ theme = theme })
local ALL = { showValue = true, vendorBadge = true }
local ALERT_PIXELS = ':68:124:4:60:'

local function value(fields)
	local result = {
		copper = 500,
		isPriced = true,
		source = 'ah',
		vendorNet = 13,
		confidence = { level = 'high', reasons = {} },
	}
	for key, field in pairs(fields or {}) do
		result[key] = field
	end
	return result
end

local function kinds(decision)
	local result = {}
	for _, badge in ipairs(decision.badges) do
		result[#result + 1] = badge.kind
	end
	return result
end

local function shownTextures(button)
	local shown = {}
	for _, child in ipairs(button.children) do
		if child.kind == 'Texture' and child.isShown then
			shown[#shown + 1] = child
		end
	end
	return shown
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

t.group('badges')

t.test('decide: no value, no badges and no text', function()
	t.same(Badges.decide(nil, ALL), { badges = {}, isLowConfidence = false })
	t.raises(function()
		Badges.decide(value())
	end, 'needs options')
end)

t.test('decide: the vendor badge needs an AH price that the vendor beats', function()
	t.same(kinds(Badges.decide(value({ source = 'vendor' }), ALL)), { 'vendor' })
	t.same(kinds(Badges.decide(value({ source = 'ah' }), ALL)), {}, 'AH wins')
	t.same(kinds(Badges.decide(value({ source = 'vendor', isPriced = false }), ALL)), {}, 'vendor-only item')
	t.same(kinds(Badges.decide(value({ source = 'vendor', vendorNet = 0 }), ALL)), {}, 'no vendor price')
	t.same(kinds(Badges.decide(value({ source = 'vendor' }), { vendorBadge = false })), {}, 'setting off')
end)

t.test('decide: low confidence gets its badge, after the vendor badge', function()
	local low = value({ source = 'vendor', confidence = { level = 'low', reasons = {} } })
	local decision = Badges.decide(low, ALL)
	t.same(kinds(decision), { 'vendor', 'lowConfidence' })
	t.eq(decision.badges[2].icon, 'alert-triangle')
	t.eq(decision.badges[2].color, 'color.state.danger')
	t.same(kinds(Badges.decide(low, { vendorBadge = true, lowBadge = false })), { 'vendor', 'lowConfidence' })
	t.same(kinds(Badges.decide(value({ confidence = { level = 'medium', reasons = {} } }), ALL)), {})
end)

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

t.test('the painter creates an overlay only when there is something to show, then reuses it', function()
	local painter = Badges.newPainter({ icons = icons, theme = theme })
	local button = FakeGame.newWidget('Button')
	painter:Paint(button, { badges = {} })
	t.eq(painter:HasOverlay(button), false)
	t.eq(#button.children, 0)
	painter:Paint(button, Badges.decide(value({ source = 'vendor', copper = 250 }), ALL))
	t.eq(painter:HasOverlay(button), true)
	local childCount = #button.children
	t.eq(#shownTextures(button), 1)
	t.eq(valueText(button), '2s')
	painter:Paint(button, Badges.decide(value({ confidence = { level = 'low', reasons = {} } }), ALL))
	t.eq(#button.children, childCount, 'no new regions')
	local shown = shownTextures(button)
	t.eq(#shown, 1)
	t.same(shown[1].texcoords, { 0.265625, 0.484375, 0.015625, 0.234375 }, 'the alert-triangle')
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
	painter:Paint(button, Badges.decide(value({ source = 'vendor' }), ALL))
	for key in pairs(button) do
		t.truthy(keys[key], 'new field ' .. tostring(key))
	end
	t.raises(function()
		Badges.newPainter({})
	end, 'needs icons')
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
