--[[
	BagPadSection: a market section in BagPad's detail panel for bag items, under its own divider.
	Each figure is per unit: the craft cost from the recipe AHledger remembered, the vendor price
	(BagPad then hides its own vendor row), the realistic auction price with the profit at it
	small underneath, and a verdict. Arrows compare each figure with the same one at the 7-day medians.
	Needs BagPad with BagPadAPI:RegisterDetailSection; does nothing without it.
]]
local _, ns = ...
ns = ns or {} -- tests load files without the addon table
local Pricing = ns.Pricing

local BagPadSection = {}
ns.BagPadSection = BagPadSection

local SECTION_ID = "Haggler:market"
local VERDICT_TEXT = { vendor = "Vendor", wait = "Wait", auction = "Auction" }
local VERDICT_COLOR = {
	vendor = { 1, 0.82, 0 },
	wait = { 1, 0.6, 0.2 },
	auction = { 0.25, 1, 0.25 },
}

local function isBound(bag, slot)
	local location = ItemLocation and ItemLocation:CreateFromBagAndSlot(bag, slot)
	return location and C_Item.IsBound and C_Item.DoesItemExist(location) and C_Item.IsBound(location) or false
end

local function vendorPrice(item)
	local price = select(11, C_Item.GetItemInfo(item.link or item.itemID))
	return price or 0
end

local function moneyRow(label, pair, isCost)
	if not pair then
		return { label = label, value = "No price", muted = true }
	end
	-- Up is good for a price, bad for a cost.
	local isGood = (pair.trend == "up") ~= (isCost == true)
	return { label = label, money = pair.now, trend = pair.trend, good = isGood }
end

local function economicsFor(itemID)
	local api = AHledgerAPI
	local recipe = api.GetRecipe and api.GetRecipe(itemID)
	local craft = recipe and Pricing.craftCost(recipe, api.GetPrice)
	return craft, recipe ~= nil
end

local function rows(item)
	if not (item.itemID and AHledgerAPI) or isBound(item.bag, item.slot) then
		return nil
	end
	local vendor = vendorPrice(item)
	local prices = AHledgerAPI.GetPrice(item.itemID)
	local levels = ns.Scan.levels(item.itemID)
	local craft, hasRecipe = economicsFor(item.itemID)
	if not prices and not levels and not hasRecipe and vendor == 0 then
		return nil
	end
	local e = Pricing.itemEconomics({ vendor = vendor, prices = prices, levels = levels, craft = craft })
	local list = {}
	if hasRecipe then
		list[#list + 1] = moneyRow("Cost to craft", e.craft, true)
	else
		list[#list + 1] = { label = "Cost to craft", value = "No recipe", muted = true }
	end
	if e.vendor then
		list[#list + 1] = { label = "Vendor price", money = e.vendor }
	else
		list[#list + 1] = { label = "Vendor price", value = "Can't be sold", muted = true }
	end
	local auction = moneyRow("Auction price", e.realistic, false)
	-- The profit at the realistic price, small under it: against the craft cost, else the vendor.
	-- Items with no recipe show it only while Shift is held.
	local showsProfit = e.basis == "craft" or IsShiftKeyDown()
	if showsProfit and e.realistic and e.profitReal then
		auction.sub = { money = e.profitReal.now, percent = e.profitPct, signed = true }
	end
	list[#list + 1] = auction
	if e.verdict then
		local color = VERDICT_COLOR[e.verdict]
		list[#list + 1] = { label = "Verdict", value = VERDICT_TEXT[e.verdict], r = color[1], g = color[2], b = color[3] }
	end
	return { rows = list, replaces = { "price" } }
end

function BagPadSection.register()
	local api = BagPadAPI
	if not (api and api.RegisterDetailSection) then
		return
	end
	api:RegisterDetailSection(SECTION_ID, rows)
end

--- Shift pressed or released: the profit line of items with no recipe shows or hides.
function BagPadSection.onModifier(key)
	if key == "LSHIFT" or key == "RSHIFT" then
		BagPadSection.refresh()
	end
end

--- New depth or prices: BagPad redraws the panel if it shows.
function BagPadSection.refresh()
	local api = BagPadAPI
	if api and api.RefreshDetail then
		api:RefreshDetail()
	end
end
