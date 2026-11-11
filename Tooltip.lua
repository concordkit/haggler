--[[
	Tooltip: one line on items one of your characters can craft (AHledgerDB.recipes), with the
	realistic margin per craft. Follows AHledger's own tooltip switches: off when its tooltip is
	off, Shift-only when it is Shift-only.
]]
local _, ns = ...
ns = ns or {} -- tests load files without the addon table
local Pricing = ns.Pricing

local Tooltip = {}
ns.Tooltip = Tooltip

local isHooked = false

local function shouldShow()
	local settings = AHledgerDB and AHledgerDB.settings
	if type(settings) ~= "table" then
		return true
	end
	if settings.tooltip == false then
		return false
	end
	return not settings.tooltipShift or IsShiftKeyDown()
end

-- An item one of your characters crafts: its margin per craft.
local function addCraftedItemLine(tooltip, itemID, stored)
	local recipe = ns.FromStoredRecipe(itemID, stored)
	local economics = recipe and Pricing.recipeEconomics(recipe, ns.Scan.lookup, 1, ns.priceMode())
	if economics then
		tooltip:AddLine(ns.Display.tooltipText(economics), 1, 1, 1, true)
	end
end

local function onItemTooltip(tooltip)
	if (tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip) or not tooltip.GetItem or not shouldShow() then
		return
	end
	local _, link = tooltip:GetItem()
	local itemID = link and tonumber(link:match("item:(%d+)"))
	if not itemID then
		return
	end
	local stored = AHledgerDB and AHledgerDB.recipes and AHledgerDB.recipes[itemID]
	if stored then
		addCraftedItemLine(tooltip, itemID, stored)
	end
end

--- Hooks item tooltips once: the tooltip data processor where the client has it, else the
--- classic OnTooltipSetItem script.
function Tooltip.hook()
	if isHooked then
		return
	end
	isHooked = true
	local safeHandler = function(tooltip)
		pcall(onItemTooltip, tooltip)
	end
	if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
		TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, safeHandler)
		return
	end
	for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
		tooltip:HookScript("OnTooltipSetItem", safeHandler)
	end
end
