--[[
	Tooltip: the host's item-tooltip line providers. A module adds a provider that returns lines
	for an item; the host draws them under the tooltip's own lines. Haggler only adds its own
	lines: it never changes another add-on's lines or the tooltip's look.

	  Tooltip.new({ wow, onError? })
	  tooltips:AddProvider(owner, fun(itemId, info) -> Line[])     replaces the owner's provider
	  tooltips:RemoveProvider(owner)
	  info = { stackCount, modifiers = { shift, ctrl, alt } }
	  Line = { left, right?, color?, rightColor? }                  colours { r, g, b }

	Providers run in the order they were added, each under pcall: one that fails adds no lines
	and is reported, the others still draw. The client hook is installed with the first provider
	(Wow:HookItemTooltips) and its handler removed with the last.
]]
local _, ns = ...

local Tooltip = {}
ns.Tooltip = Tooltip

Tooltip.HOOK_OWNER = 'host'
local WHITE = { r = 1, g = 1, b = 1 }

-- Helpers live at the bottom of the file; declared here so they stay local.
local drawLine, isUsableLine

local TooltipMethods = {}
TooltipMethods.__index = TooltipMethods

--- @param options table { wow, onError = fun(owner, err)? }
function Tooltip.new(options)
	if type(options) ~= 'table' or not options.wow then
		error('Tooltip.new: needs wow', 2)
	end
	return setmetatable({ wow = options.wow, onError = options.onError, providers = {} }, TooltipMethods)
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
	for _, line in ipairs(lines) do
		drawLine(tooltip, line)
	end
	-- The client sizes a tooltip when it is shown; lines added after that need another Show.
	if #lines > 0 and tooltip.Show then
		tooltip:Show()
	end
	return #lines
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

return Tooltip
