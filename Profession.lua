--[[
	Profession: the margin line and the 50-craft prognosis in the profession window, under
	AHledger's own line, priced in the mode picked on the top bar switch.

	Modern profession window: the recipe comes from C_TradeSkillUI.GetRecipeSchematic.
	Classic TradeSkill frame: from AHledgerDB.recipes, which AHledger fills as a recipe is shown.
	The line hangs off AHledger's line when it shows, so it follows wherever AHledger puts it.
]]
local _, ns = ...
ns = ns or {} -- tests load files without the addon table
local Pricing = ns.Pricing

local Profession = {}
ns.Profession = Profession

local LINE_WIDTH = 340
local PROGNOSIS_CRAFTS = 50
local BLOCK_GAP = 6
local AHLEDGER_LINE_MODERN = "AHledgerCraftLineRetail"
local AHLEDGER_LINE_CLASSIC = "AHledgerCraftLine"
local line = nil
local separator = nil
local prognosis = nil
local current = nil -- { recipe, parent, fallbackAnchor, ahledgerLineName } of the shown recipe
local isModernHooked, isClassicHooked = false, false

--- AHledger's stored recipe shape into ours: { resultID, made, reagents = { { itemID, qty } } }.
function ns.FromStoredRecipe(resultID, stored)
	if type(stored) ~= "table" or type(stored.reagents) ~= "table" then
		return nil
	end
	return { resultID = resultID, made = stored.made or 1, reagents = stored.reagents }
end

--- A modern recipe in our shape, or nil when the client has no schematic for it.
function ns.SchematicRecipe(recipeID)
	local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
	if not ok or not schematic or not schematic.outputItemID then
		return nil
	end
	local reagents = {}
	for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
		local isBasic = not slot.reagentType or (Enum.CraftingReagentType and slot.reagentType == Enum.CraftingReagentType.Basic)
		local first = slot.reagents and slot.reagents[1]
		if isBasic and first and first.itemID then
			reagents[#reagents + 1] = { first.itemID, slot.quantityRequired or 1 }
		end
	end
	local made = ((schematic.quantityMin or 1) + (schematic.quantityMax or schematic.quantityMin or 1)) / 2
	return { resultID = schematic.outputItemID, made = made, reagents = reagents }
end

local function ensureLine(parent)
	if line and line:GetParent() == parent then
		return line
	end
	line = parent:CreateFontString("HagglerMarginLine", "OVERLAY", "GameFontNormalSmall")
	line:SetJustifyH("LEFT")
	line:SetWidth(LINE_WIDTH)
	separator = parent:CreateTexture(nil, "ARTWORK")
	separator:SetColorTexture(1, 1, 1, 0.15)
	separator:SetSize(LINE_WIDTH, 1)
	separator:SetPoint("TOPLEFT", line, "BOTTOMLEFT", 0, -BLOCK_GAP)
	prognosis = parent:CreateFontString("HagglerMarginPrognosis", "OVERLAY", "GameFontNormalSmall")
	prognosis:SetJustifyH("LEFT")
	prognosis:SetWidth(LINE_WIDTH)
	prognosis:SetPoint("TOPLEFT", separator, "BOTTOMLEFT", 0, -BLOCK_GAP)
	return line
end

local function placeLine()
	local ahledgerLine = _G[current.ahledgerLineName]
	local hasAhledgerLine = ahledgerLine and ahledgerLine:GetParent() == current.parent and (ahledgerLine:GetText() or "") ~= ""
	line:ClearAllPoints()
	if hasAhledgerLine then
		line:SetPoint("TOPLEFT", ahledgerLine, "BOTTOMLEFT", 0, -4)
	else
		line:SetPoint("TOPLEFT", current.fallbackAnchor, "BOTTOMLEFT", 0, -6)
	end
end

local function renderPrognosis()
	local economics = Pricing.recipeEconomics(current.recipe, ns.Scan.lookup, PROGNOSIS_CRAFTS, ns.priceMode())
	if not economics then
		separator:Hide()
		prognosis:SetText("")
		return
	end
	separator:Show()
	prognosis:SetText(ns.Display.prognosisText(economics))
end

--- Draws the line and the prognosis for the recipe last shown; again whenever a fresher scan
--- has been read.
function Profession.render()
	if not current or not line then
		return
	end
	placeLine()
	local economics = current.recipe and Pricing.recipeEconomics(current.recipe, ns.Scan.lookup, 1, ns.priceMode())
	if not economics then
		line:SetText("")
		separator:Hide()
		prognosis:SetText("")
		return
	end
	line:SetText(ns.Display.professionText(economics, ns.Scan.lookup(current.recipe.resultID)))
	renderPrognosis()
end

-- AHledger draws and places its own line in the same hook and again a frame later, so ours is
-- placed after that.
local function show(recipe, parent, fallbackAnchor, ahledgerLineName)
	ensureLine(parent)
	current = { recipe = recipe, parent = parent, fallbackAnchor = fallbackAnchor, ahledgerLineName = ahledgerLineName }
	Profession.render()
	C_Timer.After(0, function()
		pcall(Profession.render)
	end)
end

local function onModernRecipe(form, recipeInfo)
	if not recipeInfo or not recipeInfo.recipeID then
		return
	end
	show(ns.SchematicRecipe(recipeInfo.recipeID), form, form.Reagents or form, AHLEDGER_LINE_MODERN)
end

local function onClassicRecipe(index)
	if not index or index < 1 or not GetTradeSkillItemLink then
		return
	end
	local link = GetTradeSkillItemLink(index)
	local resultID = link and tonumber(link:match("item:(%d+)"))
	local parent = TradeSkillDetailScrollChildFrame or TradeSkillFrame
	-- AHledger stores the recipe in its own hook; read it a frame later so it is there.
	C_Timer.After(0, function()
		local stored = resultID and AHledgerDB and AHledgerDB.recipes and AHledgerDB.recipes[resultID]
		show(ns.FromStoredRecipe(resultID, stored), parent, TradeSkillReagentLabel or parent, AHLEDGER_LINE_CLASSIC)
	end)
end

--- Hooks whichever profession frames exist; safe to call again as Blizzard's load on demand.
function Profession.hook()
	local form = ProfessionsFrame and ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.SchematicForm
	if form and not isModernHooked then
		isModernHooked = true
		hooksecurefunc(form, "Init", function(...)
			pcall(onModernRecipe, ...)
		end)
	end
	if TradeSkillFrame_SetSelection and not isClassicHooked then
		isClassicHooked = true
		hooksecurefunc("TradeSkillFrame_SetSelection", function(index)
			pcall(onClassicRecipe, index)
		end)
	end
end
