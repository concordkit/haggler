--[[
	RuleEditor: a draft of one rule that the Rules tab edits field by field. Every field is a
	picker (a choice of values), a slider (min, max, step) or a toggle, so the whole editor works
	with a gamepad; the name is the only text field. The editor never touches the store until
	Save, and Save validates through Store:SaveRule (Rules.validate).

	  RuleEditor.new(rule|nil) -> editor      nil starts a new rule from the Realistic shape
	  RuleEditor.copyOf(rule)  -> editor      a new rule that starts as a copy ('Copy of <name>')
	  editor:Fields()          -> { Field... } the draft as a flat list, in display order
	  editor:Set(fieldId, value) -> true | nil, reason
	  editor:Nudge(fieldId, delta) -> true | nil, reason   a picker moves one option, a slider one
	                              step (clamped), a toggle flips; what a d-pad left/right does
	  editor:AddStep(kind) · RemoveStep(index) · MoveStep(index, delta)   -> true | nil, reason
	  editor:Draft()           -> a copy of the rule as it would be saved
	  editor:Validate()        -> true | nil, reason
	  editor:IsNew() · IsDirty()
	  editor:Save(store)       -> ruleId | nil, reason   a new rule gets a free 'customN' id

	  Field = { id, label, kind = 'text'|'choice'|'slider'|'toggle', value, display,
	            options? = { { value, label }... }, min?, max?, step?, stepIndex? }

	Field ids: 'name', 'base.kind', 'base.<param>', 'step.<i>.kind', 'step.<i>.<param>',
	'step.<i>.base', 'antiBait.enabled', 'antiBait.minutes', 'antiBait.gapPercent'. A bad field id
	is a caller bug and throws; a value out of range is player input and returns nil, reason.
]]
local _, ns = ...

local RuleEditor = {}
ns.RuleEditor = RuleEditor

RuleEditor.MAX_STEPS = 8
RuleEditor.MAX_NAME_LENGTH = 40
RuleEditor.NEW_ID_PREFIX = 'custom'

-- Bases in picker order, with their parameters.
RuleEditor.BASES = {
	{
		kind = 'firstWithUnits',
		label = 'First price covering N units',
		params = {
			{ key = 'n', label = 'Units', kind = 'slider', min = 1, max = 200, step = 1, default = 5 },
			{ key = 'hours', label = 'Or hours of sales', kind = 'slider', min = 0, max = 48, step = 1, default = 1 },
		},
	},
	{ kind = 'lowest', label = 'Lowest listing' },
	{
		kind = 'afterPercent',
		label = 'Price after the cheapest %',
		params = {
			{
				key = 'percent',
				label = 'Percent of units',
				kind = 'slider',
				min = 0,
				max = 100,
				step = 5,
				default = 10,
			},
		},
	},
	{ kind = 'median', label = 'Median (AHledger)' },
	{ kind = 'median7', label = '7-day median' },
	{ kind = 'median30', label = '30-day median' },
	{ kind = 'low30', label = '30-day low' },
	{ kind = 'high30', label = '30-day high' },
	{ kind = 'vendor', label = 'Vendor price' },
	{ kind = 'craftCost', label = 'Craft cost' },
	{ kind = 'realized', label = 'What it sold for' },
}

-- Bases a step can compare against: those with no parameters.
local STEP_BASE_KINDS =
	{ 'median', 'median7', 'median30', 'low30', 'high30', 'lowest', 'vendor', 'craftCost', 'realized' }

local UNDERCUT_COPPER = { 0, 1, 5, 10, 50, 100, 500, 1000, 5000, 10000 }

RuleEditor.STEPS = {
	{
		kind = 'cap',
		label = 'Cap at % of',
		hasBase = true,
		params = {
			{ key = 'percent', label = 'Percent', kind = 'slider', min = 10, max = 500, step = 5, default = 100 },
		},
	},
	{
		kind = 'floor',
		label = 'Floor at % of',
		hasBase = true,
		params = {
			{ key = 'percent', label = 'Percent', kind = 'slider', min = 10, max = 500, step = 5, default = 100 },
		},
	},
	{ kind = 'lower', label = 'Lower of this and', hasBase = true },
	{ kind = 'higher', label = 'Higher of this and', hasBase = true },
	{
		kind = 'multiply',
		label = 'Multiply by',
		params = {
			{ key = 'factor', label = 'Factor', kind = 'slider', min = 0.05, max = 5, step = 0.05, default = 1 },
		},
	},
	{
		kind = 'undercut',
		label = 'Undercut by',
		params = {
			{ key = 'copper', label = 'Copper', kind = 'choice', values = UNDERCUT_COPPER, default = 1 },
		},
	},
}

RuleEditor.ANTI_BAIT = {
	{
		key = 'minutes',
		label = 'Skip this many minutes of sales',
		kind = 'slider',
		min = 0,
		max = 120,
		step = 5,
		default = 10,
	},
	-- 0 is off: no gap check.
	{
		key = 'gapPercent',
		label = 'Skip a lowest price under % of the next',
		kind = 'slider',
		min = 0,
		max = 100,
		step = 5,
		default = 0,
	},
}

-- Helpers live at the bottom of the file; declared here so they stay local.
local specOf, paramSpec, defaultsFor, baseFields, paramField, choiceOptions, nudgeChoice, nudgeSlider
local clampToSlider, labelOf, formatValue, setBaseKind, setStepKind, stepAt, freeId, splitFieldId
local sameTable, BASE_BY_KIND, STEP_BY_KIND

local EditorMethods = {}
EditorMethods.__index = EditorMethods

--- A draft of a rule (a copy; the rule passed in is never changed).
--- @param rule table|nil Rule to edit; nil for a new one
--- @return table editor
function RuleEditor.new(rule)
	if rule ~= nil and type(rule) ~= 'table' then
		error('RuleEditor.new: rule must be a table or nil', 2)
	end
	local draft
	if rule then
		draft = ns.Rules.copy(rule)
	else
		local realistic = ns.Rules.builtIns()[ns.Rules.DEFAULT_RULE_ID]
		draft = ns.Rules.copy(realistic)
		draft.id, draft.name, draft.builtIn = nil, 'New rule', nil
	end
	draft.steps = draft.steps or {}
	draft.antiBait = draft.antiBait or { enabled = false, minutes = ns.Rules.DEFAULT_BAIT_MINUTES }
	return setmetatable({ draft = draft, original = rule and ns.Rules.copy(rule) or nil }, EditorMethods)
end

--- A new rule's draft that starts as a copy of another rule (Copy to new).
--- @param rule table Rule to copy
--- @return table editor IsNew() is true; Save gives it a free id
function RuleEditor.copyOf(rule)
	if type(rule) ~= 'table' then
		error('RuleEditor.copyOf: rule must be a table', 2)
	end
	local editor = RuleEditor.new(rule)
	local name = 'Copy of ' .. tostring(rule.name or 'rule')
	editor.draft.id, editor.draft.builtIn, editor.original = nil, nil, nil
	editor.draft.name = name:sub(1, RuleEditor.MAX_NAME_LENGTH)
	return editor
end

function EditorMethods:IsNew()
	return self.original == nil
end

function EditorMethods:IsDirty()
	return self.original == nil or not sameTable(self.original, self.draft)
end

--- A copy of the draft as it would be saved.
function EditorMethods:Draft()
	return ns.Rules.copy(self.draft)
end

--- Checks the draft (a new rule is checked under a stand-in id).
--- @return boolean|nil, string|nil reason
function EditorMethods:Validate()
	local draft = self:Draft()
	draft.id = draft.id or RuleEditor.NEW_ID_PREFIX
	return ns.Rules.validate(draft)
end

--- The draft as a flat list of fields, in display order.
--- @return table { Field... }
function EditorMethods:Fields()
	local draft = self.draft
	local fields = {
		{ id = 'name', label = 'Name', kind = 'text', value = draft.name, display = draft.name },
	}
	baseFields(fields, 'base', 'Base', draft.base, RuleEditor.BASES)
	for index, step in ipairs(draft.steps) do
		local spec = STEP_BY_KIND[step.kind]
		local prefix = 'step.' .. index
		fields[#fields + 1] = {
			id = prefix .. '.kind',
			label = 'Step ' .. index,
			kind = 'choice',
			value = step.kind,
			display = labelOf(RuleEditor.STEPS, step.kind),
			options = choiceOptions(RuleEditor.STEPS),
			stepIndex = index,
		}
		for _, param in ipairs(spec and spec.params or {}) do
			local field = paramField(prefix .. '.' .. param.key, param, step[param.key])
			field.stepIndex = index
			fields[#fields + 1] = field
		end
		if spec and spec.hasBase then
			local baseKind = type(step.base) == 'table' and step.base.kind or nil
			fields[#fields + 1] = {
				id = prefix .. '.base',
				label = 'Compared with',
				kind = 'choice',
				value = baseKind,
				display = labelOf(RuleEditor.BASES, baseKind),
				options = choiceOptions(RuleEditor.BASES, STEP_BASE_KINDS),
				stepIndex = index,
			}
		end
	end
	local antiBait = draft.antiBait
	fields[#fields + 1] = {
		id = 'antiBait.enabled',
		label = 'Pass over bait listings',
		kind = 'toggle',
		value = antiBait.enabled == true,
		display = antiBait.enabled and 'On' or 'Off',
	}
	if antiBait.enabled then
		for _, param in ipairs(RuleEditor.ANTI_BAIT) do
			fields[#fields + 1] = paramField('antiBait.' .. param.key, param, antiBait[param.key] or param.default)
		end
	end
	return fields
end

--- Sets one field.
--- @param fieldId string see the file header
--- @param value any
--- @return boolean|nil true when set
--- @return string|nil reason
function EditorMethods:Set(fieldId, value)
	local head, middle, tail = splitFieldId(fieldId)
	local draft = self.draft
	if head == 'name' then
		if type(value) ~= 'string' then
			return nil, 'name must be text'
		end
		local name = value:gsub('^%s+', ''):gsub('%s+$', '')
		if name == '' then
			return nil, 'the rule needs a name'
		end
		draft.name = name:sub(1, RuleEditor.MAX_NAME_LENGTH)
		return true
	end
	if head == 'base' then
		if middle == 'kind' then
			return setBaseKind(draft, 'base', value, RuleEditor.BASES)
		end
		local param = paramSpec(BASE_BY_KIND[draft.base.kind], middle)
		local clamped, reason = clampToSlider(param, value)
		if clamped == nil then
			return nil, reason
		end
		draft.base[middle] = clamped
		return true
	end
	if head == 'step' then
		local index = tonumber(middle)
		local step = stepAt(draft, index)
		if tail == 'kind' then
			return setStepKind(draft, index, value)
		end
		if tail == 'base' then
			for _, kind in ipairs(STEP_BASE_KINDS) do
				if kind == value then
					step.base = { kind = value }
					return true
				end
			end
			return nil, 'a step compares only with a base without settings'
		end
		local param = paramSpec(STEP_BY_KIND[step.kind], tail)
		local clamped, reason = clampToSlider(param, value)
		if clamped == nil then
			return nil, reason
		end
		step[tail] = clamped
		return true
	end
	if head == 'antiBait' then
		if middle == 'enabled' then
			if type(value) ~= 'boolean' then
				return nil, 'on or off'
			end
			draft.antiBait.enabled = value
			return true
		end
		local param = paramSpec({ params = RuleEditor.ANTI_BAIT }, middle)
		local clamped, reason = clampToSlider(param, value)
		if clamped == nil then
			return nil, reason
		end
		-- A gap of 0 is no gap check, which the rule says by leaving the field out.
		draft.antiBait[middle] = not (middle == 'gapPercent' and clamped == 0) and clamped or nil
		return true
	end
	error('RuleEditor: unknown field ' .. tostring(fieldId), 2)
end

--- Moves a field by one option or one step: a d-pad left (-1) or right (+1).
--- @return boolean|nil, string|nil reason
function EditorMethods:Nudge(fieldId, delta)
	if delta ~= 1 and delta ~= -1 then
		error('RuleEditor:Nudge: delta must be 1 or -1', 2)
	end
	for _, field in ipairs(self:Fields()) do
		if field.id == fieldId then
			if field.kind == 'toggle' then
				return self:Set(fieldId, not field.value)
			end
			if field.kind == 'choice' then
				return self:Set(fieldId, nudgeChoice(field, delta))
			end
			if field.kind == 'slider' then
				return self:Set(fieldId, nudgeSlider(field, delta))
			end
			return nil, 'type a name'
		end
	end
	error('RuleEditor: no field ' .. tostring(fieldId), 2)
end

--- Adds a step at the end with its defaults.
--- @return boolean|nil, string|nil reason
function EditorMethods:AddStep(kind)
	if not STEP_BY_KIND[kind] then
		error('RuleEditor:AddStep: unknown step ' .. tostring(kind), 2)
	end
	local steps = self.draft.steps
	if #steps >= RuleEditor.MAX_STEPS then
		return nil, string.format('at most %d steps', RuleEditor.MAX_STEPS)
	end
	steps[#steps + 1] = { kind = kind }
	return setStepKind(self.draft, #steps, kind)
end

function EditorMethods:RemoveStep(index)
	stepAt(self.draft, index)
	table.remove(self.draft.steps, index)
	return true
end

--- Moves a step up (-1) or down (+1); at either end it stays and says so.
function EditorMethods:MoveStep(index, delta)
	stepAt(self.draft, index)
	local steps = self.draft.steps
	local target = index + delta
	if target < 1 or target > #steps then
		return nil, 'already at the end'
	end
	steps[index], steps[target] = steps[target], steps[index]
	return true
end

--- Saves the draft through the store (which validates it).
--- @param store table Store
--- @return string|nil ruleId
--- @return string|nil reason
function EditorMethods:Save(store)
	if type(store) ~= 'table' or type(store.SaveRule) ~= 'function' then
		error('RuleEditor:Save: needs the store', 2)
	end
	local draft = self:Draft()
	draft.id = draft.id or freeId(store)
	local isSaved, reason = store:SaveRule(draft)
	if not isSaved then
		return nil, reason
	end
	self.draft.id = draft.id
	self.original = ns.Rules.copy(store:Rule(draft.id))
	self.draft.builtIn = self.original.builtIn
	return draft.id
end

-- Helpers ---------------------------------------------------------------------------------

function specOf(list)
	local byKind = {}
	for _, spec in ipairs(list) do
		byKind[spec.kind] = spec
	end
	return byKind
end

BASE_BY_KIND = specOf(RuleEditor.BASES)
STEP_BY_KIND = specOf(RuleEditor.STEPS)

function paramSpec(spec, key)
	for _, param in ipairs(spec and spec.params or {}) do
		if param.key == key then
			return param
		end
	end
	error('RuleEditor: unknown field ' .. tostring(key), 3)
end

function defaultsFor(spec, target)
	for _, param in ipairs(spec and spec.params or {}) do
		target[param.key] = param.default
	end
	return target
end

function baseFields(fields, prefix, label, base, list)
	local kind = type(base) == 'table' and base.kind or nil
	fields[#fields + 1] = {
		id = prefix .. '.kind',
		label = label,
		kind = 'choice',
		value = kind,
		display = labelOf(list, kind),
		options = choiceOptions(list),
	}
	for _, param in ipairs(BASE_BY_KIND[kind] and BASE_BY_KIND[kind].params or {}) do
		fields[#fields + 1] = paramField(prefix .. '.' .. param.key, param, base[param.key])
	end
end

function paramField(id, param, value)
	value = value == nil and param.default or value
	local field =
		{ id = id, label = param.label, kind = param.kind, value = value, display = formatValue(param, value) }
	if param.kind == 'slider' then
		field.min, field.max, field.step = param.min, param.max, param.step
	else
		field.options = {}
		for _, option in ipairs(param.values) do
			field.options[#field.options + 1] = { value = option, label = formatValue(param, option) }
		end
	end
	return field
end

function choiceOptions(list, onlyKinds)
	local allowed
	if onlyKinds then
		allowed = {}
		for _, kind in ipairs(onlyKinds) do
			allowed[kind] = true
		end
	end
	local options = {}
	for _, spec in ipairs(list) do
		if not allowed or allowed[spec.kind] then
			options[#options + 1] = { value = spec.kind, label = spec.label }
		end
	end
	return options
end

-- The next option, wrapping around (a picker cycles).
function nudgeChoice(field, delta)
	local options = field.options
	local at = 1
	for index, option in ipairs(options) do
		if option.value == field.value then
			at = index
		end
	end
	local nextIndex = (at - 1 + delta) % #options + 1
	local nextOption = options[nextIndex]
	return nextOption and nextOption.value
end

function nudgeSlider(field, delta)
	local value = (field.value or field.min) + delta * field.step
	return math.max(field.min, math.min(field.max, value))
end

-- A slider value on its grid and in range; a choice value from its list.
function clampToSlider(param, value)
	if param.kind == 'choice' then
		for _, option in ipairs(param.values) do
			if option == value then
				return value
			end
		end
		return nil, 'not one of the choices'
	end
	if type(value) ~= 'number' or value ~= value then
		return nil, param.label .. ' must be a number'
	end
	if value < param.min or value > param.max then
		return nil, string.format('%s must be from %s to %s', param.label, param.min, param.max)
	end
	local steps = math.floor((value - param.min) / param.step + 0.5)
	-- Rounded to the grid; the tostring trip drops float noise like 0.15000000000000002.
	return tonumber(string.format('%.4f', param.min + steps * param.step))
end

function labelOf(list, kind)
	for _, spec in ipairs(list) do
		if spec.kind == kind then
			return spec.label
		end
	end
	return tostring(kind)
end

function formatValue(param, value)
	if param.key == 'copper' then
		if value >= 10000 and value % 10000 == 0 then
			return (value / 10000) .. 'g'
		end
		return value >= 100 and value % 100 == 0 and ((value / 100) .. 's') or (value .. 'c')
	end
	if param.key == 'percent' or param.key == 'gapPercent' then
		return value == 0 and param.key == 'gapPercent' and 'Off' or (tostring(value) .. '%')
	end
	if param.key == 'factor' then
		return string.format('x%.2f', value)
	end
	return tostring(value)
end

function setBaseKind(draft, key, kind, list)
	local spec
	for _, candidate in ipairs(list) do
		if candidate.kind == kind then
			spec = candidate
		end
	end
	if not spec then
		return nil, 'not one of the choices'
	end
	if type(draft[key]) == 'table' and draft[key].kind == kind then
		return true
	end
	draft[key] = defaultsFor(spec, { kind = kind })
	return true
end

function setStepKind(draft, index, kind)
	local spec = STEP_BY_KIND[kind]
	if not spec then
		return nil, 'not one of the choices'
	end
	local step = stepAt(draft, index)
	local replacement = defaultsFor(spec, { kind = kind })
	if spec.hasBase then
		local keptBase = type(step.base) == 'table' and step.base or nil
		replacement.base = keptBase and { kind = keptBase.kind } or { kind = 'median' }
	end
	for key, value in pairs(step) do
		-- Keep a parameter the new kind shares (a cap turned floor keeps its percent).
		if key ~= 'kind' and key ~= 'base' and replacement[key] ~= nil then
			replacement[key] = value
		end
	end
	draft.steps[index] = replacement
	return true
end

function stepAt(draft, index)
	local step = type(index) == 'number' and draft.steps[index] or nil
	if not step then
		error('RuleEditor: no step ' .. tostring(index), 3)
	end
	return step
end

function freeId(store)
	local taken = {}
	for _, id in ipairs(store:RuleIds()) do
		taken[id] = true
	end
	local number = 1
	while taken[RuleEditor.NEW_ID_PREFIX .. number] do
		number = number + 1
	end
	return RuleEditor.NEW_ID_PREFIX .. number
end

function splitFieldId(fieldId)
	if type(fieldId) ~= 'string' then
		error('RuleEditor: field id must be a string', 3)
	end
	return fieldId:match('^([^.]+)%.?([^.]*)%.?([^.]*)$')
end

function sameTable(a, b)
	if type(a) ~= 'table' or type(b) ~= 'table' then
		return a == b
	end
	for key, value in pairs(a) do
		if not sameTable(value, b[key]) then
			return false
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end
	return true
end

return RuleEditor
