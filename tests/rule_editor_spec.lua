local t = ...

local ns = t.loadAddon()
local RuleEditor, Rules, Store = ns.RuleEditor, ns.Rules, ns.Store

local function fieldOf(editor, id)
	for _, field in ipairs(editor:Fields()) do
		if field.id == id then
			return field
		end
	end
	return nil
end

local function newStore()
	return assert(Store.open({}, {}))
end

t.group('rule editor: fields')

t.test('a built-in rule reads as pickers and sliders, with the name the only text', function()
	local editor = RuleEditor.new(Rules.builtIns().realistic)
	local kinds = {}
	for _, field in ipairs(editor:Fields()) do
		kinds[field.id] = field.kind
	end
	t.same(kinds, {
		name = 'text',
		['base.kind'] = 'choice',
		['base.n'] = 'slider',
		['base.hours'] = 'slider',
		['step.1.kind'] = 'choice',
		['step.1.percent'] = 'slider',
		['step.1.base'] = 'choice',
		['step.2.kind'] = 'choice',
		['step.2.copper'] = 'choice',
		['antiBait.enabled'] = 'toggle',
		['antiBait.minutes'] = 'slider',
		['antiBait.gapPercent'] = 'slider',
	})
	t.eq(fieldOf(editor, 'base.kind').display, 'First price covering N units')
	t.eq(fieldOf(editor, 'step.2.copper').display, '1c')
	t.eq(fieldOf(editor, 'antiBait.gapPercent').display, 'Off')
	t.eq(editor:IsDirty(), false)
	t.eq(editor:IsNew(), false)
end)

t.test('a step compares only with bases that take no settings', function()
	local editor = RuleEditor.new(Rules.builtIns().realistic)
	local values = {}
	for _, option in ipairs(fieldOf(editor, 'step.1.base').options) do
		values[option.value] = true
	end
	t.eq(values.firstWithUnits, nil)
	t.eq(values.afterPercent, nil)
	t.eq(values.median, true)
	local ok, reason = editor:Set('step.1.base', 'firstWithUnits')
	t.eq(ok, nil)
	t.truthy(reason:find('without settings', 1, true))
end)

t.group('rule editor: editing')

t.test('a picker cycles and wraps; a slider moves one step and stops at its ends', function()
	local editor = RuleEditor.new(Rules.builtIns().median)
	t.truthy(editor:Nudge('base.kind', -1))
	t.eq(editor:Draft().base.kind, 'afterPercent')
	t.eq(editor:Draft().base.percent, 10, 'a new base gets its defaults')
	t.truthy(editor:Nudge('base.percent', 1))
	t.eq(editor:Draft().base.percent, 15)
	editor:Set('base.percent', 100)
	t.truthy(editor:Nudge('base.percent', 1))
	t.eq(editor:Draft().base.percent, 100, 'clamped at the top')
	editor:Set('base.kind', 'realized')
	t.truthy(editor:Nudge('base.kind', 1))
	t.eq(editor:Draft().base.kind, 'firstWithUnits', 'wraps to the first')
	t.truthy(editor:Nudge('antiBait.enabled', 1))
	t.eq(editor:Draft().antiBait.enabled, false)
	t.eq(fieldOf(editor, 'antiBait.minutes'), nil, 'settings of a switched-off part are hidden')
	t.eq(editor:IsDirty(), true)
end)

t.test('out-of-range and off-grid values are player input: refused or snapped, never thrown', function()
	local editor = RuleEditor.new(Rules.builtIns().realistic)
	local ok, reason = editor:Set('base.n', 0)
	t.eq(ok, nil)
	t.truthy(reason:find('from 1 to 200', 1, true))
	t.eq(editor:Set('base.n', 'many'), nil)
	t.truthy(editor:Set('step.1.percent', 102))
	t.eq(editor:Draft().steps[1].percent, 100, 'snapped to the 5% grid')
	t.eq(editor:Set('step.2.copper', 7), nil, 'undercut is a picker of set amounts')
	t.eq(editor:Set('name', '   '), nil)
	t.truthy(editor:Set('name', '  Quick  '))
	t.eq(editor:Draft().name, 'Quick')
	t.truthy(editor:Set('antiBait.gapPercent', 50))
	t.eq(editor:Draft().antiBait.gapPercent, 50)
	t.truthy(editor:Set('antiBait.gapPercent', 0))
	t.eq(editor:Draft().antiBait.gapPercent, nil, '0 is no gap check')
end)

t.test('an unknown field or step is a caller bug and throws', function()
	local editor = RuleEditor.new(Rules.builtIns().median)
	t.raises(function()
		editor:Set('colour', 1)
	end, 'unknown field')
	t.raises(function()
		editor:Set('base.n', 5)
	end, 'unknown field')
	t.raises(function()
		editor:RemoveStep(3)
	end, 'no step')
	t.raises(function()
		editor:AddStep('teleport')
	end, 'unknown step')
	t.raises(function()
		editor:Nudge('base.kind', 2)
	end, 'delta')
end)

t.test('steps: add with defaults, change kind keeping shared settings, move, remove', function()
	local editor = RuleEditor.new(Rules.builtIns().median)
	t.truthy(editor:AddStep('cap'))
	t.same(editor:Draft().steps[1], { kind = 'cap', percent = 100, base = { kind = 'median' } })
	editor:Set('step.1.percent', 150)
	t.truthy(editor:Set('step.1.kind', 'floor'))
	t.same(editor:Draft().steps[1], { kind = 'floor', percent = 150, base = { kind = 'median' } })
	t.truthy(editor:AddStep('undercut'))
	t.truthy(editor:MoveStep(2, -1))
	t.eq(editor:Draft().steps[1].kind, 'undercut')
	t.eq(editor:MoveStep(1, -1), nil)
	t.truthy(editor:RemoveStep(1))
	t.eq(#editor:Draft().steps, 1)
	for _ = 2, RuleEditor.MAX_STEPS do
		editor:AddStep('multiply')
	end
	local ok, reason = editor:AddStep('multiply')
	t.eq(ok, nil)
	t.truthy(reason:find('at most', 1, true))
end)

t.group('rule editor: save')

t.test('a new rule validates, saves under a free id and can become the default', function()
	local store = newStore()
	local editor = RuleEditor.new()
	t.eq(editor:IsNew(), true)
	t.truthy(editor:Validate())
	editor:Set('name', 'Mine')
	local ruleId = editor:Save(store)
	t.eq(ruleId, 'custom1')
	t.eq(store:Rule('custom1').name, 'Mine')
	t.eq(store:Rule('custom1').builtIn, nil)
	t.eq(editor:IsNew(), false)
	t.eq(editor:IsDirty(), false)
	t.eq(RuleEditor.new():Save(store), 'custom2')
	t.truthy(store:SetDefaultRule(ruleId))
	t.eq(store:DefaultRuleId(), 'custom1')
end)

t.test('editing a built-in keeps it built-in, so it can still be reset', function()
	local store = newStore()
	local editor = RuleEditor.new(store:Rule('minimum'))
	editor:Set('step.1.copper', 100)
	t.eq(editor:Save(store), 'minimum')
	t.eq(store:Rule('minimum').steps[1].copper, 100)
	t.eq(store:Rule('minimum').builtIn, true)
	t.truthy(store:ResetRule('minimum'))
end)

t.test('a broken draft (from saved data) is refused with the reason', function()
	local store = newStore()
	local broken = Rules.copy(store:Rule('median'))
	broken.base = { kind = 'firstWithUnits', n = -1 }
	local editor = RuleEditor.new(broken)
	local ok, reason = editor:Validate()
	t.eq(ok, nil)
	t.truthy(reason:find('firstWithUnits needs n', 1, true))
	local saved, saveReason = editor:Save(store)
	t.eq(saved, nil)
	t.truthy(saveReason:find('base:', 1, true))
	t.eq(store:Rule('median').base.kind, 'median', 'nothing written')
end)

t.test('copy to new starts a new rule from another, saved under a free id', function()
	local store = assert(ns.Store.open({}, {}))
	local editor = ns.RuleEditor.copyOf(store:Rule('median'))
	t.eq(editor:IsNew(), true)
	t.eq(editor:Draft().name, 'Copy of ' .. store:Rule('median').name)
	t.eq(editor:Draft().base.kind, store:Rule('median').base.kind)
	local ruleId = assert(editor:Save(store))
	t.truthy(ruleId ~= 'median', 'a new id')
	t.eq(store:Rule('median').builtIn, true, 'the original is untouched')
	t.raises(function()
		ns.RuleEditor.copyOf(nil)
	end, 'rule must be a table')
end)
