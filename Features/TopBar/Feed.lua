--[[
	TopBarFeed: the top bar's widgets as LibDataBroker-1.1 objects, for any broker display
	(Titan Panel, ChocolateBar, Bazooka...). The libraries are bundled in Libs/ and reached
	through ns.wow:Library; without LibDataBroker the feed does nothing.

	  TopBarFeed.new(ldb, handlers) -> feed
	      handlers = { onLauncher(button), onRule(direction), onScan(), tooltipLines(name) -> { line } }
	  feed:Update(texts)   texts = { gold, rule, scan } strings
	  feed:SetActive(isActive)   an inactive feed shows '', ignores clicks and its tooltips
	                             offer none (LDB objects cannot be removed once made)

	Objects: 'Haggler' (launcher: left click opens the window, right click the settings) and the
	data sources 'Haggler: Gold', 'Haggler: Rule', 'Haggler: Scan'. A display that cannot click
	still shows the text.
]]
local _, ns = ...

local TopBarFeed = {}
ns.TopBarFeed = TopBarFeed

TopBarFeed.ICON = 'Interface\\AddOns\\Haggler\\media\\icon.png'
TopBarFeed.NAMES = {
	launcher = 'Haggler',
	gold = 'Haggler: Gold',
	rule = 'Haggler: Rule',
	scan = 'Haggler: Scan',
}
TopBarFeed.LAUNCHER_LINES = { 'Haggler', 'Click: open the window', 'Right click: settings' }
TopBarFeed.OFF_LINES = { 'Haggler', 'The top bar is off (Haggler settings)' }

-- Helpers live at the bottom of the file; declared here so they stay local.
local dataObject, addTooltipLines

local FeedMethods = {}
FeedMethods.__index = FeedMethods

--- @param ldb table|nil LibDataBroker-1.1 (nil: the feed does nothing)
--- @param handlers table see the file header
--- @return table feed
function TopBarFeed.new(ldb, handlers)
	if type(handlers) ~= 'table' then
		error('TopBarFeed.new: needs handlers', 2)
	end
	local feed = setmetatable({ handlers = handlers, objects = {}, isActive = true }, FeedMethods)
	if type(ldb) ~= 'table' or type(ldb.NewDataObject) ~= 'function' then
		return feed
	end
	local names = TopBarFeed.NAMES
	feed.objects.launcher = dataObject(ldb, names.launcher, {
		type = 'launcher',
		icon = TopBarFeed.ICON,
		label = 'Haggler',
		OnClick = function(_, button)
			if feed.isActive then
				handlers.onLauncher(button)
			end
		end,
		OnTooltipShow = function(tooltip)
			addTooltipLines(tooltip, feed.isActive and TopBarFeed.LAUNCHER_LINES or TopBarFeed.OFF_LINES)
		end,
	})
	for _, key in ipairs({ 'gold', 'rule', 'scan' }) do
		feed.objects[key] = dataObject(ldb, names[key], {
			type = 'data source',
			icon = TopBarFeed.ICON,
			label = names[key],
			text = '',
			OnClick = function(_, button)
				if not feed.isActive then
					return
				end
				if key == 'rule' then
					handlers.onRule(button == 'RightButton' and -1 or 1)
				elseif key == 'scan' then
					handlers.onScan()
				else
					handlers.onLauncher('LeftButton')
				end
			end,
			OnTooltipShow = function(tooltip)
				if feed.isActive then
					addTooltipLines(tooltip, handlers.tooltipLines(key))
				end
			end,
		})
	end
	return feed
end

--- Sets each data source's text (an LDB object tells its displays on assignment).
function FeedMethods:Update(texts)
	if not self.isActive or type(texts) ~= 'table' then
		return
	end
	for _, key in ipairs({ 'gold', 'rule', 'scan' }) do
		local object = self.objects[key]
		if object and type(texts[key]) == 'string' and object.text ~= texts[key] then
			object.text = texts[key]
		end
	end
end

function FeedMethods:SetActive(isActive)
	self.isActive = isActive == true
	if not self.isActive then
		for _, key in ipairs({ 'gold', 'rule', 'scan' }) do
			if self.objects[key] then
				self.objects[key].text = ''
			end
		end
	end
end

-- Helpers ---------------------------------------------------------------------------------

-- A /reload clears every add-on's Lua state, LibDataBroker's registry with it. An object of
-- that name exists already when the top bar is turned off and on again in one session (LDB
-- objects cannot be removed) or another add-on took the name: reuse it and take over its
-- handlers.
function dataObject(ldb, name, fields)
	local object = ldb:NewDataObject(name, fields)
	if object then
		return object
	end
	object = ldb:GetDataObjectByName(name)
	if type(object) == 'table' then
		for key, value in pairs(fields) do
			object[key] = value
		end
	end
	return object
end

function addTooltipLines(tooltip, lines)
	if type(tooltip) ~= 'table' or type(tooltip.AddLine) ~= 'function' or type(lines) ~= 'table' then
		return
	end
	for _, line in ipairs(lines) do
		tooltip:AddLine(line)
	end
end
