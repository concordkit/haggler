--[[
	Panel: the checklist window, toggled by /hc. Plain frames and colour fills, no Blizzard art.

	  progress line · next action
	  12 rows a page: [state] place · title       click a row to select it
	  selected item: what to do, then its evidence
	  Pass · Fail · N/A while the player may judge   prev / next page · close
	  (a look item, any item whose result is a look, or one the player judged: changeable)

	  Panel.create(env, model) -> panel   model: items(), resultOf(item), progress(), nextItem(),
	                                      runKey(), canSetVerdict(item), setVerdict(item, state)
	  panel:Toggle() · panel:Refresh()
]]
local _, ns = ...

local ROWS_PER_PAGE = 12
local WIDTH = 460
local PADDING = 10
local ROW_HEIGHT = 18
local DETAIL_HEIGHT = 128
local BUTTON_WIDTH = 64
local BUTTON_HEIGHT = 20
local STATE_COLORS = {
	pass = '|cff40d040',
	fail = '|cffff4040',
	look = '|cffffd040',
	na = '|cff909090',
	pending = '|cffb0b0b0',
}
local FILL =
	{ background = { 0.05, 0.05, 0.07, 0.92 }, button = { 0.2, 0.2, 0.25, 1 }, selected = { 0.3, 0.3, 0.45, 0.6 } }

-- Helpers live at the bottom of the file; declared here so they stay local.
local addFill, addText, addButton, stateOf

local Panel = {}
ns.Panel = Panel

--- Builds the panel, hidden.
--- @param env table _G
--- @param model table the run the panel shows (see the header)
--- @return table panel
function Panel.create(env, model)
	local panel = setmetatable({ env = env, model = model, page = 1, rows = {} }, { __index = Panel })
	panel:Build()
	return panel
end

function Panel:Build()
	local frame = self.env.CreateFrame('Frame', 'HagglerCheckPanel', self.env.UIParent)
	self.frame = frame
	frame:SetSize(WIDTH, 2 * PADDING + 3 * ROW_HEIGHT + ROWS_PER_PAGE * ROW_HEIGHT + DETAIL_HEIGHT + BUTTON_HEIGHT + 16)
	frame:SetPoint('TOPLEFT', self.env.UIParent, 'TOPLEFT', 40, -140)
	frame:SetFrameStrata('DIALOG')
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag('LeftButton')
	frame:SetScript('OnDragStart', frame.StartMoving)
	frame:SetScript('OnDragStop', frame.StopMovingOrSizing)
	addFill(frame, FILL.background)
	frame:Hide()

	self.titleText = addText(frame, 'GameFontNormal', WIDTH - 2 * PADDING - 30)
	self.titleText:SetPoint('TOPLEFT', PADDING, -PADDING)
	local closeButton = addButton(self.env, frame, 'x', 22, function()
		frame:Hide()
	end)
	closeButton:SetPoint('TOPRIGHT', -PADDING + 4, -PADDING + 4)
	self.nextText = addText(frame, 'GameFontHighlight', WIDTH - 2 * PADDING)
	self.nextText:SetPoint('TOPLEFT', self.titleText, 'BOTTOMLEFT', 0, -4)

	local previous = self.nextText
	for index = 1, ROWS_PER_PAGE do
		local row = self:BuildRow(index)
		row:SetPoint('TOPLEFT', previous, 'BOTTOMLEFT', 0, index == 1 and -8 or 0)
		previous = row
	end

	self.detailText = addText(frame, 'GameFontHighlightSmall', WIDTH - 2 * PADDING)
	self.detailText:SetPoint('TOPLEFT', previous, 'BOTTOMLEFT', 0, -8)
	self.detailText:SetHeight(DETAIL_HEIGHT)
	self.detailText:SetJustifyV('TOP')

	self.verdictButtons = {}
	local verdicts = { { 'Pass', 'pass' }, { 'Fail', 'fail' }, { 'N/A', 'na' } }
	for index, verdict in ipairs(verdicts) do
		local button = addButton(self.env, frame, verdict[1], BUTTON_WIDTH, function()
			self:SetVerdict(verdict[2])
		end)
		button:SetPoint('BOTTOMLEFT', PADDING + (index - 1) * (BUTTON_WIDTH + 6), PADDING)
		self.verdictButtons[index] = button
	end
	local nextPage = addButton(self.env, frame, '>', 28, function()
		self:TurnPage(1)
	end)
	nextPage:SetPoint('BOTTOMRIGHT', -PADDING, PADDING)
	local previousPage = addButton(self.env, frame, '<', 28, function()
		self:TurnPage(-1)
	end)
	previousPage:SetPoint('RIGHT', nextPage, 'LEFT', -40, 0)
	self.pageText = addText(frame, 'GameFontHighlightSmall', 40)
	self.pageText:SetPoint('LEFT', previousPage, 'RIGHT', 0, 0)
	self.pageText:SetJustifyH('CENTER')
end

function Panel:BuildRow(index)
	local row = self.env.CreateFrame('Button', nil, self.frame)
	row:SetSize(WIDTH - 2 * PADDING, ROW_HEIGHT)
	row.selectedFill = addFill(row, FILL.selected)
	row.text = addText(row, 'GameFontHighlightSmall', WIDTH - 2 * PADDING)
	row.text:SetPoint('LEFT')
	row.text:SetWordWrap(false)
	row:SetScript('OnClick', function()
		self.selected = row.item
		self:Refresh()
	end)
	self.rows[index] = row
	return row
end

function Panel:Toggle()
	self.frame:SetShown(not self.frame:IsShown())
	if self.frame:IsShown() then
		self:Refresh()
	end
end

function Panel:TurnPage(step)
	local pageCount = math.max(1, math.ceil(#self.model.items() / ROWS_PER_PAGE))
	self.page = math.min(pageCount, math.max(1, self.page + step))
	self:Refresh()
end

function Panel:SetVerdict(state)
	local item = self.selected
	if item == nil or not self.model.canSetVerdict(item) then
		return
	end
	self.model.setVerdict(item, state)
	self.selected = self.model.nextItem() or item
	self:Refresh()
end

--- Redraws from the model; cheap enough to call on every recorded verdict.
function Panel:Refresh()
	if not self.frame:IsShown() then
		return
	end
	local model, items = self.model, self.model.items()
	local progress = model.progress()
	local nextItem = model.nextItem()
	self.selected = self.selected or nextItem
	self.titleText:SetText(
		string.format(
			'Haggler checks %s   %d/%d judged · %d fail · %d to look at',
			model.runKey(),
			progress.judged,
			progress.total,
			progress.fail,
			progress.look
		)
	)
	self.nextText:SetText(
		nextItem
				and ('Next (' .. nextItem.place .. '): ' .. (nextItem.prompt ~= '' and nextItem.prompt or nextItem.title))
			or 'All judged. /reload or log out, then run the reader.'
	)
	local firstIndex = (self.page - 1) * ROWS_PER_PAGE
	for index, row in ipairs(self.rows) do
		local item = items[firstIndex + index]
		row.item = item
		row:SetShown(item ~= nil)
		if item then
			local state = stateOf(model.resultOf(item))
			row.text:SetText(
				string.format(
					'%s[%s]|r %s · %s%s',
					STATE_COLORS[state],
					state,
					item.place,
					item.title,
					item.zone == 'fight' and ' (fight)' or ''
				)
			)
			row.selectedFill:SetShown(item == self.selected)
		end
	end
	self.pageText:SetText(self.page .. '/' .. math.max(1, math.ceil(#items / ROWS_PER_PAGE)))
	self:RefreshDetail()
end

function Panel:RefreshDetail()
	local item = self.selected
	local lines = {}
	if item then
		local result = self.model.resultOf(item)
		lines[1] = item.title .. ' (' .. item.kind .. ')'
		lines[2] = item.prompt ~= '' and item.prompt or 'Judged on its own.'
		for _, line in ipairs(result and result.evidence or {}) do
			lines[#lines + 1] = '· ' .. line
		end
	end
	self.detailText:SetText(table.concat(lines, '\n'))
	local canJudge = item ~= nil and self.model.canSetVerdict(item)
	for _, button in ipairs(self.verdictButtons) do
		button:SetShown(canJudge)
	end
end

-- Helpers ---------------------------------------------------------------------------------

function addFill(frame, color)
	local texture = frame:CreateTexture(nil, 'BACKGROUND')
	texture:SetAllPoints()
	texture:SetColorTexture(color[1], color[2], color[3], color[4])
	return texture
end

function addText(frame, fontObject, width)
	local text = frame:CreateFontString(nil, 'OVERLAY', fontObject)
	text:SetWidth(width)
	text:SetJustifyH('LEFT')
	return text
end

function addButton(env, parent, label, width, onClick)
	local button = env.CreateFrame('Button', nil, parent)
	button:SetSize(width, BUTTON_HEIGHT)
	addFill(button, FILL.button)
	local text = button:CreateFontString(nil, 'OVERLAY', 'GameFontHighlightSmall')
	text:SetAllPoints()
	text:SetText(label)
	button:SetScript('OnClick', onClick)
	return button
end

function stateOf(result)
	return result and result.state or 'pending'
end
