--[[
	CraftingView: what the profession frame shows for a recipe (Features/Crafting/Crafting.lua
	draws it). It prices recipes with Engine/CraftCost.lua and keeps each result until something
	that changes it happens (prices, a scan, the bags, the books), so scrolling the recipe list
	costs a table lookup a row.

	  CraftingView.new(deps) deps = { schematic = fun(recipeId) -> schematic|nil, prices, values,
	    market = fun() -> market|nil, held = fun(itemId) -> units, valuation = fun() -> name }
	  view:Craft(recipeId, crafts?) -> Craft|nil   cached
	  view:Invalidate()                            drops the cache and the price context
	  CraftingView.rowText(craft)          -> text, level|nil   '+1g 20s · 15%' for a list row
	  CraftingView.detailLines(craft, parts) -> { { text, level? } }
	      parts = { figures, share, credit? }; low confidence and its reasons always show; the
	      credit line shows whenever an AHledger figure went into the craft
	  CraftingView.ventureRecipe(schematic) -> recipe for Ventures.addCrafts
]]
local _, ns = ...

local CraftingView = {}
ns.CraftingView = CraftingView

local ViewMethods = {}
ViewMethods.__index = ViewMethods

local PERCENT = 100

-- Helpers live at the bottom of the file; declared here so they stay local.
local signedMoney, percentText, sourcesFor

--- @param deps table see the file header
function CraftingView.new(deps)
	if type(deps) ~= 'table' or type(deps.schematic) ~= 'function' or type(deps.held) ~= 'function' then
		error('CraftingView.new: needs schematic and held', 2)
	end
	return setmetatable({ deps = deps, cache = {} }, ViewMethods)
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
	return mark .. signedMoney(craft.profit) .. margin, level ~= 'high' and level or nil
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
		lines[#lines + 1] = { text = 'Cost ' .. money(craft.cost) .. perCraft }
		lines[#lines + 1] = { text = 'Value ' .. money(craft.value) .. ' after the cut and deposit risk' }
		lines[#lines + 1] = {
			text = 'Profit ' .. signedMoney(craft.profit) .. (craft.margin and (' · margin ' .. percentText(
				craft.margin
			)) or ''),
			level = craft.profit < 0 and 'low' or nil,
		}
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
	local confidence = craft.confidence or {}
	if confidence.level and confidence.level ~= 'high' then
		lines[#lines + 1] = { text = 'Confidence ' .. confidence.level, level = confidence.level }
		for _, reason in ipairs(confidence.reasons or {}) do
			lines[#lines + 1] = { text = '  ' .. (reason.text or tostring(reason)), level = confidence.level }
		end
	end
	if craft.usesPriceSource and parts.credit then
		-- 'high' draws the line muted, like the window footer's credit.
		lines[#lines + 1] = { text = parts.credit, level = 'high' }
	end
	return lines
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
	return string.format('%d%%', math.floor(fraction * PERCENT + (fraction < 0 and -0.5 or 0.5)))
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
	}
end
