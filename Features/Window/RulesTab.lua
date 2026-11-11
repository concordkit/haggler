--[[
	Rules tab: pick a rule, set it as the default, edit it, copy it into a new one, or delete it
	(a built-in rule is reset instead). The editor is Engine/RuleEditor: every field is a picker,
	a stepper or an on/off picker, so a gamepad reaches all of it; the name is the only text box
	and a new rule gets a name without it. Nothing is saved until Save.

	Setting the default sends DEFAULT_RULE_CHANGED (ruleId) so tooltips, bags and the Sell tab
	follow it; saving, deleting or resetting a rule sends RULES_CHANGED (ruleId). Delete and
	Reset ask for a second click first.
]]
local _, ns = ...

local FIELD_ROWS = 9
local ROW_HEIGHT = 40
local LABEL_WIDTH = 260
local CONTROL_WIDTH = 240

-- Helpers live at the bottom of the file; declared here so they stay local.
local buildRulePicker, buildEditor, buildFieldRow, buildStepTools, refreshRulePicker, refreshEditor
local selectedRule, startEditing, saveEditor, setDefault, deleteOrReset, runEditorChange, fieldValueText

ns.window:AddTab({
	key = 'rules',
	label = 'Rules',
	order = 30,
	build = function(container, ctx)
		container.state = { ruleIndex = 1, page = 1, stepIndex = 1, addKindIndex = 1 }
		buildRulePicker(container, ctx)
		buildEditor(container, ctx)
		-- A Delete armed before leaving the tab does not stay armed when coming back.
		container:SetScript('OnShow', function()
			container.state.deleteArmedFor = nil
		end)
	end,
	refresh = function(container, ctx)
		refreshRulePicker(container, ctx)
		refreshEditor(container, ctx)
	end,
})

-- Helpers ---------------------------------------------------------------------------------

function buildRulePicker(container, ctx)
	local ui = ctx.ui
	local caption = ui:Text(container, 12, 'color.text.muted')
	caption:SetPoint('TOPLEFT', container, 'TOPLEFT')
	caption:SetText('RULE')
	container.rulePicker = ui:Stepper(container, 280, function(delta)
		local count = #(ns.prices and ns.prices:Rules() or {})
		container.state.ruleIndex = ((container.state.ruleIndex - 1 + delta) % math.max(1, count)) + 1
		container.state.deleteArmedFor = nil
		container.editor = nil
		ctx.window:Refresh()
	end)
	container.rulePicker:SetPoint('TOPLEFT', caption, 'BOTTOMLEFT', 0, -8)
	local actions = {
		{ key = 'defaultButton', label = 'Set as default', style = 'primary', run = setDefault },
		{
			key = 'editButton',
			label = 'Edit',
			run = function(_, c, x)
				startEditing(c, x, false)
			end,
		},
		{
			key = 'copyButton',
			label = 'Copy to new',
			run = function(_, c, x)
				startEditing(c, x, true)
			end,
		},
		{ key = 'deleteButton', label = 'Delete', run = deleteOrReset },
	}
	local previous = container.rulePicker
	for _, action in ipairs(actions) do
		local button = ui:Button(container, action.label, action.style or 'secondary')
		button:SetPoint('LEFT', previous, 'RIGHT', 8, 0)
		button:OnClick(function()
			action.run(nil, container, ctx)
		end)
		container[action.key] = button
		previous = button
	end
end

function buildEditor(container, ctx)
	local ui = ctx.ui
	local editor = ctx.wow:CreateFrame('Frame', container)
	editor:SetPoint('TOPLEFT', container.rulePicker, 'BOTTOMLEFT', 0, -24)
	editor:SetPoint('BOTTOMRIGHT', container, 'BOTTOMRIGHT')
	container.editorFrame = editor
	container.nameInput = ui:Input(editor, 320, function(text)
		if container.editor then
			runEditorChange(container, ctx, container.editor:Set('name', text))
		end
	end)
	container.nameInput:SetPoint('TOPLEFT', editor, 'TOPLEFT', 4, 0)
	container.fieldRows = {}
	for index = 1, FIELD_ROWS do
		container.fieldRows[index] = buildFieldRow(container, ctx, index)
	end
	container.pager = ui:Stepper(editor, 160, function(delta)
		container.state.page = container.state.page + delta
		refreshEditor(container, ctx)
	end)
	container.pager:SetPoint('TOPLEFT', container.fieldRows[FIELD_ROWS], 'BOTTOMLEFT', 0, -8)
	buildStepTools(container, ctx)
	container.saveButton = ui:Button(editor, 'Save', 'primary')
	container.saveButton:SetPoint('BOTTOMRIGHT', editor, 'BOTTOMRIGHT')
	container.saveButton:OnClick(function()
		saveEditor(container, ctx)
	end)
	container.cancelButton = ui:Button(editor, 'Cancel', 'secondary')
	container.cancelButton:SetPoint('RIGHT', container.saveButton, 'LEFT', -8, 0)
	container.cancelButton:OnClick(function()
		container.editor = nil
		ctx.setStatus('Changes dropped.')
		ctx.window:Refresh()
	end)
	container.problemText = ui:Text(editor, 13, 'color.state.danger')
	container.problemText:SetPoint('RIGHT', container.cancelButton, 'LEFT', -16, 0)
end

function buildFieldRow(container, ctx, index)
	local ui = ctx.ui
	local row = ctx.wow:CreateFrame('Frame', container.editorFrame)
	row:SetSize(LABEL_WIDTH + CONTROL_WIDTH + 16, ROW_HEIGHT)
	row:SetPoint('TOPLEFT', container.nameInput, 'BOTTOMLEFT', -4, -8 - (index - 1) * ROW_HEIGHT)
	row.label = ui:Text(row, 14, 'color.text.primary')
	row.label:SetPoint('LEFT', row, 'LEFT')
	row.control = ui:Stepper(row, CONTROL_WIDTH, function(delta)
		if container.editor and row.field then
			runEditorChange(container, ctx, container.editor:Nudge(row.field.id, delta))
		end
	end)
	row.control:SetPoint('LEFT', row, 'LEFT', LABEL_WIDTH, 0)
	return row
end

function buildStepTools(container, ctx)
	local ui = ctx.ui
	local tools = ctx.wow:CreateFrame('Frame', container.editorFrame)
	tools:SetPoint('TOPLEFT', container.pager, 'BOTTOMLEFT', 0, -16)
	tools:SetSize(800, 40)
	container.stepTools = tools
	container.stepPicker = ui:Stepper(tools, 160, function(delta)
		container.state.stepIndex = container.state.stepIndex + delta
		refreshEditor(container, ctx)
	end)
	container.stepPicker:SetPoint('LEFT', tools, 'LEFT')
	local stepActions = {
		{
			label = 'Up',
			run = function(editor, index)
				return editor:MoveStep(index, -1)
			end,
		},
		{
			label = 'Down',
			run = function(editor, index)
				return editor:MoveStep(index, 1)
			end,
		},
		{
			label = 'Remove',
			run = function(editor, index)
				return editor:RemoveStep(index)
			end,
		},
	}
	local previous = container.stepPicker
	for _, action in ipairs(stepActions) do
		local button = ui:Button(tools, action.label, 'secondary')
		button:SetPoint('LEFT', previous, 'RIGHT', 8, 0)
		button:OnClick(function()
			if container.editor then
				runEditorChange(container, ctx, action.run(container.editor, container.state.stepIndex))
			end
		end)
		previous = button
	end
	container.addKindPicker = ui:Stepper(tools, 200, function(delta)
		local count = #ns.RuleEditor.STEPS
		container.state.addKindIndex = ((container.state.addKindIndex - 1 + delta) % count) + 1
		refreshEditor(container, ctx)
	end)
	container.addKindPicker:SetPoint('LEFT', previous, 'RIGHT', 24, 0)
	local addButton = ui:Button(tools, 'Add step', 'secondary')
	addButton:SetPoint('LEFT', container.addKindPicker, 'RIGHT', 8, 0)
	addButton:OnClick(function()
		local spec = ns.RuleEditor.STEPS[container.state.addKindIndex]
		if container.editor and spec then
			runEditorChange(container, ctx, container.editor:AddStep(spec.kind))
		end
	end)
end

function refreshRulePicker(container, ctx)
	local rule = selectedRule(container)
	container.rulePicker:SetValue(rule and (rule.name .. (rule.isDefault and ' (default)' or '')) or 'no rules')
	container.defaultButton:SetEnabled(rule ~= nil and not rule.isDefault)
	container.editButton:SetEnabled(rule ~= nil)
	container.copyButton:SetEnabled(rule ~= nil)
	local verb = rule and rule.builtIn and 'Reset' or 'Delete'
	local isArmed = rule ~= nil and container.state.deleteArmedFor == rule.id
	container.deleteButton:SetLabel(isArmed and string.format('%s %s? Click again', verb, rule.name) or verb)
	container.deleteButton:SetEnabled(rule ~= nil)
	return ctx
end

function refreshEditor(container, ctx)
	local editor = container.editor
	if not editor then
		container.editorFrame:Hide()
		return
	end
	container.editorFrame:Show()
	local fields = {}
	for _, field in ipairs(editor:Fields()) do
		if field.id == 'name' then
			container.nameInput:SetText(field.value or '')
		else
			fields[#fields + 1] = field
		end
	end
	local page = ns.WindowModel.page(fields, container.state.page, FIELD_ROWS)
	container.state.page = page.page
	for index, row in ipairs(container.fieldRows) do
		local field = page.items[index]
		row.field = field
		if field then
			row:Show()
			row.label:SetText((field.stepIndex and (field.stepIndex .. '. ') or '') .. field.label)
			row.control:SetValue(fieldValueText(field))
		else
			row:Hide()
		end
	end
	container.pager:SetValue(string.format('Page %d of %d', page.page, page.pageCount))
	local stepCount = #(editor:Draft().steps or {})
	container.state.stepIndex = math.max(1, math.min(stepCount, container.state.stepIndex))
	container.stepPicker:SetValue(stepCount > 0 and ('Step ' .. container.state.stepIndex) or 'No steps')
	container.addKindPicker:SetValue(ns.RuleEditor.STEPS[container.state.addKindIndex].label)
	local isValid, reason = editor:Validate()
	container.problemText:SetText(isValid and '' or tostring(reason))
	container.saveButton:SetEnabled(isValid == true and (editor:IsNew() or editor:IsDirty()))
	return ctx
end

function selectedRule(container)
	local rules = ns.prices and ns.prices:Rules() or {}
	container.state.ruleIndex = math.max(1, math.min(#rules, container.state.ruleIndex))
	return rules[container.state.ruleIndex]
end

function startEditing(container, ctx, isCopy)
	local entry = selectedRule(container)
	local rule = entry and ns.store:Rule(entry.id)
	if not rule then
		return
	end
	container.editor = isCopy and ns.RuleEditor.copyOf(rule) or ns.RuleEditor.new(rule)
	container.state.page = 1
	container.state.deleteArmedFor = nil
	ctx.window:Refresh()
end

function saveEditor(container, ctx)
	local editor = container.editor
	if not editor then
		return
	end
	local ruleId, reason = editor:Save(ns.store)
	if not ruleId then
		ctx.setStatus('Not saved: ' .. tostring(reason))
		return
	end
	container.editor = nil
	container.state.deleteArmedFor = nil
	for index, rule in ipairs(ns.prices:Rules()) do
		if rule.id == ruleId then
			container.state.ruleIndex = index
		end
	end
	ctx.window.module:Send('RULES_CHANGED', ruleId)
	ctx.setStatus('Rule saved.')
	ctx.window:Refresh()
end

function setDefault(_, container, ctx)
	local rule = selectedRule(container)
	if not rule then
		return
	end
	local isSet, reason = ns.store:SetDefaultRule(rule.id)
	if not isSet then
		ctx.setStatus('Not changed: ' .. tostring(reason))
		return
	end
	ctx.window.module:Send('DEFAULT_RULE_CHANGED', rule.id)
	container.state.ruleIndex = 1
	container.state.deleteArmedFor = nil
	ctx.setStatus(rule.name .. ' is now the default rule.')
	ctx.window:Refresh()
end

function deleteOrReset(_, container, ctx)
	local rule = selectedRule(container)
	if not rule then
		return
	end
	if container.state.deleteArmedFor ~= rule.id then
		container.state.deleteArmedFor = rule.id
		ctx.window:Refresh()
		return
	end
	container.state.deleteArmedFor = nil
	local isDone, reason
	if rule.builtIn then
		isDone, reason = ns.store:ResetRule(rule.id)
	else
		isDone, reason = ns.store:DeleteRule(rule.id)
	end
	ctx.setStatus(isDone and (rule.name .. (rule.builtIn and ' reset.' or ' deleted.')) or tostring(reason))
	if isDone then
		ctx.window.module:Send('RULES_CHANGED', rule.id)
	end
	container.editor = nil
	ctx.window:Refresh()
end

-- A refused change (a value out of range) is said in the footer; the editor keeps its draft.
function runEditorChange(container, ctx, isDone, reason)
	if not isDone and reason then
		ctx.setStatus(tostring(reason))
	end
	refreshEditor(container, ctx)
end

function fieldValueText(field)
	if field.kind == 'toggle' then
		return field.value and 'On' or 'Off'
	end
	return tostring(field.display or field.value or '')
end
