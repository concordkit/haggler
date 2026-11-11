--[[
	RecipeList: a margin dot on every recipe in the modern profession window, from the realistic
	economics, with the exact margin and the full line on hover.

	It stands in for AHledger's own profit dots, which price at the median. Two sets of dots on one
	row would sit on top of each other, so this one draws only while AHledger's "Profit dots"
	option is off; Core switches it off once, and turning it back on hands the dots back to AHledger.
]]
local _, ns = ...
ns = ns or {} -- tests load files without the addon table
local Pricing = ns.Pricing

local RecipeList = {}
ns.RecipeList = RecipeList

local DOT_SIZE, DOT_INSET, SIGN_GAP = 12, 4, 1
local LABEL_PADDING = 10

local BAND = {
	profit = { texture = "Interface\\COMMON\\Indicator-Green", sign = "+", colour = "|cff3ddc6b", rgb = { 0.24, 0.86, 0.42 } },
	even = { texture = "Interface\\COMMON\\Indicator-Gray", sign = "", colour = "|cff9d9d9d", rgb = { 0.6, 0.6, 0.62 } },
	loss = { texture = "Interface\\COMMON\\Indicator-Yellow", sign = "-", colour = "|cffffd23f", rgb = { 1, 0.82, 0.25 } },
	heavy = { texture = "Interface\\COMMON\\Indicator-Red", sign = "-", colour = "|cffff5a4f", rgb = { 1, 0.3, 0.3 } },
	unknown = { texture = "Interface\\COMMON\\Indicator-Gray", sign = "?", colour = "|cff9d9d9d", rgb = { 0.6, 0.6, 0.62 } },
}

local isHooked = false
local registryOwner = {}

--- True while AHledger's own dots are off, so ours have the row to themselves.
function RecipeList.isActive()
	local settings = AHledgerDB and AHledgerDB.settings
	return type(settings) ~= "table" or settings.craftDots == false
end

-- The recipe id a row was filled with: the tree node's data carries recipeInfo for a recipe and
-- categoryInfo for a heading. Ranked recipes are priced at the highest rank learned, as shown.
local function recipeIdOf(node)
	local data = node
	if type(data) == "table" and type(data.GetData) == "function" then
		local ok, d = pcall(data.GetData, data)
		data = ok and d or nil
	end
	local info = type(data) == "table" and data.recipeInfo or nil
	if type(info) ~= "table" then
		return nil
	end
	if Professions and Professions.GetHighestLearnedRecipe then
		local ok, best = pcall(Professions.GetHighestLearnedRecipe, info)
		if ok and type(best) == "table" and best.recipeID then
			info = best
		end
	end
	return tonumber(info.recipeID)
end

local function isShown(region)
	return type(region) == "table" and region.IsShown and region:IsShown()
end

-- Shortens the recipe name so it stops short of the dot and sign instead of running under them.
local function fitLabel(frame)
	local label = frame.Label
	if type(label) ~= "table" or not label.GetStringWidth or not frame.AHLMSign then
		return
	end
	local count = isShown(frame.Count) and (frame.Count:GetStringWidth() or 0) or 0
	local locked = isShown(frame.LockedIcon) and (frame.LockedIcon:GetWidth() or 0) or 0
	local skillUps = (type(frame.SkillUps) == "table" and frame.SkillUps.GetWidth) and (frame.SkillUps:GetWidth() or 0) or 0
	local indicator = DOT_SIZE + DOT_INSET + SIGN_GAP + (frame.AHLMSign:GetStringWidth() or 0) + 4
	local width = frame:GetWidth() or 0
	local room = width - (locked + count + LABEL_PADDING + skillUps) - indicator
	-- Measured at full width first, so a name already cut short reports its whole length.
	if width > 0 then
		label:SetWidth(width)
	end
	label:SetWidth(math.max(1, math.min(label:GetStringWidth() or 0, room)))
end

local function ensureDot(frame)
	if frame.AHLMDot then
		return
	end
	local dot = frame:CreateTexture(nil, "OVERLAY", nil, 1)
	dot:SetSize(DOT_SIZE, DOT_SIZE)
	local sign = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	sign:SetDrawLayer("OVERLAY", 1)
	sign:SetPoint("RIGHT", dot, "LEFT", -SIGN_GAP, 0)
	sign:SetJustifyH("RIGHT")
	sign:SetWordWrap(false)
	frame.AHLMDot, frame.AHLMSign = dot, sign
end

-- Right edge of the row, or left of the lock icon, which Blizzard anchors to the same edge.
local function placeDot(frame)
	frame.AHLMDot:ClearAllPoints()
	if isShown(frame.LockedIcon) then
		frame.AHLMDot:SetPoint("RIGHT", frame.LockedIcon, "LEFT", -2, 0)
	else
		frame.AHLMDot:SetPoint("RIGHT", frame, "RIGHT", -DOT_INSET, 0)
	end
end

local function showSign(frame)
	local band = BAND[frame.AHLMBand] or BAND.unknown
	frame.AHLMSign:SetText(band.colour .. band.sign .. "|r")
end

local function clearRow(frame)
	frame.AHLMRecipe, frame.AHLMEconomics, frame.AHLMBand = nil, nil, nil
	if frame.AHLMDot then
		frame.AHLMDot:Hide()
		frame.AHLMSign:SetText("")
	end
end

--- Sets or clears one row's dot.
function RecipeList.decorate(frame, node)
	if type(frame) ~= "table" or not frame.CreateTexture then
		return
	end
	local recipeID = RecipeList.isActive() and recipeIdOf(node) or nil
	local recipe = recipeID and ns.SchematicRecipe(recipeID)
	if not recipe or #recipe.reagents == 0 then
		clearRow(frame)
		return
	end
	ensureDot(frame)
	local economics = Pricing.recipeEconomics(recipe, ns.Scan.lookup, 1, ns.priceMode())
	frame.AHLMRecipe, frame.AHLMEconomics = recipe, economics
	frame.AHLMBand = Pricing.marginBand(economics)
	local band = BAND[frame.AHLMBand]
	-- SetTexture answers false when the file is missing; then a plain square in the band colour.
	if frame.AHLMDot:SetTexture(band.texture) == false then
		frame.AHLMDot:SetColorTexture(band.rgb[1], band.rgb[2], band.rgb[3])
	end
	placeDot(frame)
	frame.AHLMDot:Show()
	showSign(frame)
	fitLabel(frame)
end

-- Hover: the sign gives way to the exact margin, and the tooltip carries the full line. When the
-- row already shows Blizzard's tooltip for a cut-short name, the line joins it.
local function onRowEnter(frame)
	local economics = frame.AHLMEconomics
	if not frame.AHLMBand then
		return
	end
	if economics then
		local pct = economics.pct and string.format(" (%+.0f%%)", economics.pct) or ""
		local sign = economics.margin < 0 and "-" or "+"
		frame.AHLMSign:SetText(BAND[frame.AHLMBand].colour .. sign .. Pricing.formatMoney(math.abs(economics.margin)) .. pct .. "|r")
		fitLabel(frame)
	end
	local tip = GameTooltip
	if tip:IsShown() and tip:GetOwner() == frame.Label then
		tip:AddLine(" ")
	else
		tip:SetOwner(frame, "ANCHOR_RIGHT")
		tip:SetText(frame.Label and frame.Label:GetText() or "", 1, 1, 1)
	end
	if economics then
		tip:AddLine(ns.Display.professionText(economics, ns.Scan.lookup(frame.AHLMRecipe.resultID)), nil, nil, nil, true)
	else
		tip:AddLine("|cff9d9d9dNo margin: the crafted item has no price|r", nil, nil, nil, true)
	end
	tip:Show()
end

local function onRowLeave(frame)
	if not frame.AHLMSign or not frame.AHLMBand then
		return
	end
	showSign(frame)
	fitLabel(frame)
end

local function recipeScrollBox()
	local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
	local list = page and page.RecipeList
	return list and list.ScrollBox or nil
end

--- Every visible row again: after a fresher scan is read or the dots change hands.
function RecipeList.refresh()
	local box = recipeScrollBox()
	if not box or not box.ForEachFrame then
		return
	end
	pcall(box.ForEachFrame, box, function(frame, node)
		RecipeList.decorate(frame, node)
	end)
end

--- Hooks the recipe rows the way AHledger does: the row mixin for every row and its hover, and
--- the list's OnInitializedFrame callback for clients that fill rows another way.
function RecipeList.hook()
	if isHooked or not ProfessionsRecipeListRecipeMixin or not ProfessionsRecipeListRecipeMixin.Init then
		return
	end
	isHooked = true
	hooksecurefunc(ProfessionsRecipeListRecipeMixin, "Init", function(frame, node)
		pcall(RecipeList.decorate, frame, node)
	end)
	if ProfessionsRecipeListRecipeMixin.OnEnter then
		hooksecurefunc(ProfessionsRecipeListRecipeMixin, "OnEnter", function(frame)
			pcall(onRowEnter, frame)
		end)
	end
	if ProfessionsRecipeListRecipeMixin.OnLeave then
		hooksecurefunc(ProfessionsRecipeListRecipeMixin, "OnLeave", function(frame)
			pcall(onRowLeave, frame)
		end)
	end
	local box = recipeScrollBox()
	local event = ScrollBoxListMixin and ScrollBoxListMixin.Event and ScrollBoxListMixin.Event.OnInitializedFrame
	if box and box.RegisterCallback and event then
		pcall(box.RegisterCallback, box, event, function(owner, frame, node)
			-- The registry passes the owner first; a client that leaves it out passes the frame first.
			if owner ~= registryOwner then
				frame, node = owner, frame
			end
			pcall(RecipeList.decorate, frame, node)
		end, registryOwner)
	end
end
