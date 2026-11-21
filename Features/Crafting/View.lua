--[[
	CraftingView: what the profession frame shows for a recipe (Features/Crafting/Crafting.lua
	draws it). It prices recipes with Engine/CraftCost.lua and keeps each result until something
	that changes it happens (prices, a scan, the bags, the books), so scrolling the recipe list
	costs a table lookup a row.

	  CraftingView.new(deps) deps = { schematic = fun(recipeId) -> schematic|nil, prices, values,
	    market = fun() -> market|nil, held = fun(itemId) -> units, valuation = fun() -> name,
	    knownRecipes? = fun() -> recipeIds | false }
	    A reagent a known recipe makes is costed by crafting when that is cheaper (CraftCost).
	    knownRecipes defaults to the open profession's learned recipes (Wow:KnownRecipeIds);
	    false costs every missing reagent as a buy, as the venture forecast does.
	  view:Craft(recipeId, crafts?) -> Craft|nil   cached
	  view:Invalidate()                            drops the cache and the price context
	  CraftingView.rowText(craft)          -> text, level|nil   '+1g 20s · 15%' for a list row
	  CraftingView.detailLines(craft, parts) -> { { text, level? } }
	      parts = { figures, share, credit? }; low confidence and its reasons always show; the
	      credit line shows whenever an AHledger figure went into the craft, ahead of the
	      confidence lines so a full panel keeps it; figures adds one line naming the
	      reagents costed by crafting: 'Crafted: Bolt of Linen Cloth × 2, …'
	  CraftingView.ventureRecipe(schematic) -> recipe for Ventures.addCrafts
	  CraftingView.marginToken(margin)      -> token|nil   the colour of a recipe's prices, by margin band
	  CraftingView.MARGIN_BANDS             the bands, best first; tune them here
]]
local _, ns = ...

local CraftingView = {}
ns.CraftingView = CraftingView

local ViewMethods = {}
ViewMethods.__index = ViewMethods

local PERCENT = 100

-- A recipe's margin (profit / value, unrounded) takes the first band it reaches; so each edge
-- belongs to the band above it (-25% is orange, 0% green tint), and a loss too small to show
-- as -1% still reads as a loss. Best band first.
CraftingView.MARGIN_BANDS = {
	{ atLeast = 0.25, token = 'money.gainStrong' },
	{ atLeast = 0.10, token = 'money.gain' },
	{ atLeast = 0, token = 'money.gainTint' },
	{ atLeast = -0.10, token = 'money.lossTint' },
	{ atLeast = -0.25, token = 'color.state.caution' },
	{ atLeast = -math.huge, token = 'money.loss' },
}

-- Helpers live at the bottom of the file; declared here so they stay local.
local signedMoney, percentText, wholePercent, sourcesFor, colorFor, recipeFinder, craftedLine, itemName

--- @param deps table see the file header
function CraftingView.new(deps)
	if type(deps) ~= 'table' or type(deps.schematic) ~= 'function' or type(deps.held) ~= 'function' then
		error('CraftingView.new: needs schematic and held', 2)
	end
	return setmetatable({ deps = deps, cache = {}, schematics = {} }, ViewMethods)
end

--- The recipe priced under the current valuation, or nil when the client has no schematic.
--- @return table|nil Craft (Engine/CraftCost.lua)
function ViewMethods:Craft(recipeId, crafts)
	if type(recipeId) ~= 'number' then
		return nil
	end
	crafts = type(crafts) == 'number' and crafts >= 1 and math.floor(crafts) or 1
	local valuation = self.deps.valuation and self.deps.valuation() or 'opportunity'
	if not ns.Ventures.VALUATIONS[valuation] then
		valuation = 'opportunity'
	end
	local key = recipeId .. ':' .. crafts .. ':' .. valuation
	local cached = self.cache[key]
	if cached ~= nil then
		return cached or nil
	end
	local schematic = self.deps.schematic(recipeId)
	local craft = schematic and ns.CraftCost.recipe(schematic, sourcesFor(self, valuation, crafts)) or nil
	-- false caches a recipe without a schematic, so the row does not ask again on every scroll.
	self.cache[key] = craft or false
	return craft
end

function ViewMethods:Invalidate()
	self.cache = {}
	self.ctx = nil
	self.recipeByOutput = nil
end

--- The figures a recipe list row shows: profit and margin, '?' when a price is missing.
--- @return string text
--- @return string|nil level the confidence level when it is not high
function CraftingView.rowText(craft)
	if type(craft) ~= 'table' then
		return '', nil
	end
	local level = craft.confidence and craft.confidence.level
	local mark = level == 'low' and '? ' or ''
	local margin = craft.margin and (' · ' .. percentText(craft.margin)) or ''
	return mark .. colorFor(craft, signedMoney(craft.profit) .. margin), level ~= 'high' and level or nil
end

--- The selected recipe's lines. Low confidence and its reasons show whatever parts are off.
--- @param parts table { figures = boolean, share = boolean, credit = string|nil }
function CraftingView.detailLines(craft, parts)
	local lines = {}
	if type(craft) ~= 'table' then
		return lines
	end
	parts = parts or {}
	local money = ns.TooltipLines.money
	if parts.figures then
		local perCraft = craft.made and craft.made > 1 and (' for ' .. craft.made) or ''
		local marginText = craft.margin and (' · margin ' .. colorFor(craft, percentText(craft.margin))) or ''
		lines[#lines + 1] = { text = 'Cost ' .. colorFor(craft, money(craft.cost)) .. perCraft }
		lines[#lines + 1] = {
			text = 'Value ' .. colorFor(craft, money(craft.value)) .. ' after the cut and deposit risk',
		}
		lines[#lines + 1] = {
			text = 'Profit ' .. colorFor(craft, signedMoney(craft.profit)) .. marginText,
			-- The band colour already tells a loss; without a margin the line still reads low.
			level = not craft.margin and craft.profit < 0 and 'low' or nil,
		}
		lines[#lines + 1] = craftedLine(craft)
	end
	if parts.share and craft.knownShare then
		lines[#lines + 1] = {
			text = string.format(
				'Known %s (%s) · estimated %s',
				percentText(craft.knownShare),
				money(craft.knownCopper),
				money(craft.estimatedCopper)
			),
		}
	end
	if craft.usesPriceSource and parts.credit then
		-- 'high' draws the line muted, like the window footer's credit. It goes before the
		-- confidence lines: the panel drops what does not fit, and the credit must not be it.
		lines[#lines + 1] = { text = parts.credit, level = 'high' }
	end
	local confidence = craft.confidence or {}
	if confidence.level and confidence.level ~= 'high' then
		lines[#lines + 1] = { text = 'Confidence ' .. confidence.level, level = confidence.level }
		for _, reason in ipairs(confidence.reasons or {}) do
			lines[#lines + 1] = { text = '  ' .. (reason.text or tostring(reason)), level = confidence.level }
		end
	end
	return lines
end

--- The token a recipe's prices take, from its margin band.
--- @param margin number|nil profit / value; nil when a price is missing
--- @return string|nil token nil leaves the prices uncoloured
function CraftingView.marginToken(margin)
	if type(margin) ~= 'number' then
		return nil
	end
	for _, band in ipairs(CraftingView.MARGIN_BANDS) do
		if margin >= band.atLeast then
			return band.token
		end
	end
	return nil
end

--- A schematic as the recipe a venture plans (Ventures.addCrafts).
function CraftingView.ventureRecipe(schematic)
	if type(schematic) ~= 'table' or not schematic.outputItemId then
		return nil
	end
	return {
		recipeId = schematic.recipeId,
		itemId = schematic.outputItemId,
		perCraft = schematic.quantity or 1,
		reagents = schematic.reagents,
	}
end

-- Helpers ---------------------------------------------------------------------------------

function signedMoney(copper)
	copper = copper or 0
	return (copper < 0 and '-' or '+') .. ns.TooltipLines.money(math.abs(copper))
end

function percentText(fraction)
	return string.format('%d%%', wholePercent(fraction))
end

-- Rounds half away from zero: -20.4% is -20, not -21.
function wholePercent(fraction)
	local percent = math.floor(math.abs(fraction) * PERCENT + 0.5)
	return fraction < 0 and -percent or percent
end

-- One line for every reagent costed by crafting, so a nested recipe costs the panel one row.
function craftedLine(craft)
	local parts = {}
	for _, reagent in ipairs(type(craft.reagents) == 'table' and craft.reagents or {}) do
		if reagent.source == 'crafted' and reagent.craftedUnits then
			parts[#parts + 1] = string.format('%s × %d', itemName(reagent.itemId), reagent.craftedUnits)
		end
	end
	return #parts > 0 and { text = 'Crafted: ' .. table.concat(parts, ', ') } or nil
end

function itemName(itemId)
	local info = ns.prices and ns.prices:ItemInfo(itemId)
	return info and info.name or ('item ' .. itemId)
end

function colorFor(craft, text)
	local token = CraftingView.marginToken(craft.margin)
	return token and ns.theme:Wrap(token, text) or text
end

-- One price context a cache generation: every row shares it.
function sourcesFor(view, valuation, crafts)
	local deps = view.deps
	if not view.ctx and deps.prices then
		view.ctx = deps.prices:Context()
	end
	local ctx = view.ctx
	local function stack(itemId, qty)
		return deps.values and deps.values:Stack(itemId, qty, { ctx = ctx }) or nil
	end
	return {
		valuation = valuation,
		crafts = crafts,
		held = deps.held,
		split = function(itemId, units, held)
			return ns.CostPool.split(deps.market and deps.market(), itemId, units, held)
		end,
		opportunity = stack,
		buyPrice = function(itemId)
			return deps.prices and deps.prices:Get(itemId, nil, ctx) or nil
		end,
		value = stack,
		recipeFor = recipeFinder(view),
	}
end

-- The known recipe that makes an item, from one pass over the known recipes a cache generation;
-- when two make the same item, the first in the client's order wins. Schematics never change,
-- so they are kept across generations.
function recipeFinder(view)
	local knownRecipes = view.deps.knownRecipes
	if knownRecipes == false then
		return nil
	end
	return function(itemId)
		if not view.recipeByOutput then
			local recipeIds = knownRecipes and knownRecipes() or (ns.wow and ns.wow:KnownRecipeIds()) or {}
			view.recipeByOutput = {}
			for _, recipeId in ipairs(recipeIds) do
				local schematic = view.schematics[recipeId] or view.deps.schematic(recipeId)
				view.schematics[recipeId] = schematic
				local outputItemId = schematic and schematic.outputItemId
				if outputItemId and not view.recipeByOutput[outputItemId] then
					view.recipeByOutput[outputItemId] = schematic
				end
			end
		end
		return view.recipeByOutput[itemId]
	end
end
