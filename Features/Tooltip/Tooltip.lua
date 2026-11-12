--[[
	Tooltip: Haggler's lines on item tooltips (TooltipLines builds them). Compact by default:
	one line per shown rule and the data age; the unit price while Shift is held. The detail
	block shows always, on a modifier, or never. A gamepad modifier works through the client's
	GamePadEmulateShift / Ctrl / Alt mapping. Holding or letting go of a modifier redraws the
	tooltip at once. Switching the module off removes its lines and its event.
]]
local _, ns = ...

-- Helpers live at the bottom of the file; declared here so they stay local.
local buildLines, isDetailShown, detailOptions

local MODULE_KEY = 'tooltip'
local UNIT_VIEW_MODIFIER = 'shift'
local DETAIL_TOGGLES =
	{ 'detailTrace', 'detailSales', 'detailListings', 'detailVendor', 'detailSellTime', 'sellTimeNote' }

local function toggle(key, label)
	return { key = key, type = 'toggle', label = label, default = true }
end

ns.host.AddModule({
	key = MODULE_KEY,
	label = 'Item tooltips',
	settings = {
		{
			key = 'detailMode',
			type = 'choice',
			label = 'Show the detail block',
			default = 'modifier',
			choices = {
				{ value = 'modifier', label = 'While a modifier is held' },
				{ value = 'always', label = 'Always' },
				{ value = 'off', label = 'Never' },
			},
		},
		{
			key = 'detailModifier',
			type = 'choice',
			label = 'Modifier for the detail block (a gamepad modifier works when the client maps it to one of these)',
			default = 'shift',
			choices = {
				{ value = 'shift', label = 'Shift' },
				{ value = 'ctrl', label = 'Ctrl' },
				{ value = 'alt', label = 'Alt' },
			},
		},
		toggle('detailTrace', 'Detail: how the default rule got its price'),
		toggle('detailSales', 'Detail: units sold a day'),
		toggle('detailListings', 'Detail: units and prices listed in the last scan'),
		toggle('detailVendor', 'Detail: vendor price'),
		toggle('detailSellTime', 'Detail: estimated sell time'),
		toggle('sellTimeNote', 'Note under the sell time that it is an estimate from sales per day'),
	},
	onEnable = function(module)
		ns.tooltips:AddProvider(MODULE_KEY, function(itemId, info)
			return buildLines(module, itemId, info)
		end)
		ns.wow:OnEvent('MODIFIER_STATE_CHANGED', function()
			ns.wow:RefreshItemTooltip()
		end, MODULE_KEY)
	end,
	onDisable = function()
		ns.tooltips:RemoveProvider(MODULE_KEY)
		ns.wow:OffEvent('MODIFIER_STATE_CHANGED', MODULE_KEY)
	end,
})

-- Helpers ---------------------------------------------------------------------------------

function buildLines(module, itemId, info)
	local prices = ns.prices
	if not prices or not ns.store then
		return {}
	end
	local modifiers = info.modifiers or {}
	return ns.TooltipLines.build({
		quote = prices:Quote(itemId, ns.store:ShownRules('tooltip')),
		stackCount = info.stackCount,
		isUnitView = modifiers[UNIT_VIEW_MODIFIER] == true,
		isDetail = isDetailShown(module, modifiers),
		options = detailOptions(module),
		theme = ns.theme,
	})
end

function isDetailShown(module, modifiers)
	local mode = module:Setting('detailMode')
	if mode == 'always' then
		return true
	end
	if mode == 'off' then
		return false
	end
	return modifiers[module:Setting('detailModifier')] == true
end

function detailOptions(module)
	local options = {}
	for _, key in ipairs(DETAIL_TOGGLES) do
		options[key] = module:Setting(key) ~= false
	end
	return options
end
