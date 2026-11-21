--[[
	CraftCost: what one recipe costs to craft, what the result is worth and the margin, with a
	confidence, for the profession frame and the venture forecast.

	Each reagent splits into units the player holds and units they would have to buy:
	  held units, valuation 'opportunity' (default)  what they would fetch instead (Value:Stack)
	  held units, valuation 'paid'                   what was paid, from the cost pool; units of
	                                                 unknown origin fall back to opportunity
	  missing units                                  the rule's price, as a buy (estimated); or,
	                                                 when sources.recipeFor knows a recipe for the
	                                                 reagent, the cheaper of the buy and crafting
	                                                 them (a sub-craft costed the same way, at most
	                                                 MAX_CRAFT_DEPTH deep, never through an item it
	                                                 is already crafting). No buy price: crafted.
	Paid copper is known; everything else is estimated. The output is valued like any owned
	stack (after the cut and the deposit risk, never below vendor). Margin = profit / value.

	  CraftCost.recipe(schematic, sources) -> Craft
	  schematic = { recipeId, outputItemId, quantity, reagents = { { itemId, qty } } }
	  sources = { valuation, crafts?, held = fun(itemId) -> units, split = fun(itemId, units, held)
	              -> Split (CostPool.split), opportunity = fun(itemId, qty) -> ItemValue|nil,
	              buyPrice = fun(itemId) -> Price|nil, value = fun(itemId, qty) -> ItemValue|nil,
	              recipeFor? = fun(itemId) -> schematic|nil   a known recipe that makes the item }
	  Craft = { cost, value, profit, margin?, knownCopper, estimatedCopper, knownShare?,
	            isComplete, confidence, usesPriceSource (an AHledger figure went in), reagents = { { itemId, qty, held, copper, knownCopper,
	            source, craftedUnits?, craft? } } }
	  source 'crafted': craftedUnits of the missing units are costed by craft, a sub-craft with
	  cost, made, reagents and confidence but no value
]]
local _, ns = ...

local CraftCost = {}
ns.CraftCost = CraftCost

-- How many crafts deep a reagent may be costed by crafting; deeper reagents are bought.
CraftCost.MAX_CRAFT_DEPTH = 4

-- Helpers live at the bottom of the file; declared here so they stay local.
local costReagents, costReagent, ownedCost, missingCost, craftedCost, buyCost, safeCall, lowReason, isWholePositive, valueUsesSource

--- Prices one recipe crafted `sources.crafts` times (default 1). Never throws on data: a
--- reagent or output without a price counts as 0 and leaves a low-confidence reason.
--- @param schematic table see the file header
--- @param sources table see the file header
--- @return table Craft
function CraftCost.recipe(schematic, sources)
	if type(schematic) ~= 'table' or type(sources) ~= 'table' then
		error('CraftCost.recipe: needs a schematic and sources', 2)
	end
	if not ns.Ventures.VALUATIONS[sources.valuation] then
		error('CraftCost.recipe: unknown valuation ' .. tostring(sources.valuation), 2)
	end
	local crafts = isWholePositive(sources.crafts) and sources.crafts or 1
	local crafting = isWholePositive(schematic.outputItemId) and { [schematic.outputItemId] = true } or {}
	local craft, confidences = costReagents(schematic, crafts, sources, { crafting = crafting, depth = 0 })
	local made = craft.made
	local value = isWholePositive(schematic.outputItemId) and safeCall(sources.value, schematic.outputItemId, made)
		or nil
	if value and value.isPriced ~= false and type(value.copper) == 'number' then
		craft.value = value.copper
		craft.usesPriceSource = craft.usesPriceSource or valueUsesSource(value)
		confidences[#confidences + 1] = value.confidence
	else
		craft.value = 0
		craft.isComplete = false
		confidences[#confidences + 1] = lowReason('noValue', 'the crafted item has no price')
	end
	craft.profit = craft.value - craft.cost
	craft.margin = craft.value > 0 and craft.profit / craft.value or nil
	craft.knownShare = craft.cost > 0 and craft.knownCopper / craft.cost or nil
	craft.confidence = ns.Value.mergeConfidence(confidences, 3)
	return craft
end

-- Helpers ---------------------------------------------------------------------------------

-- The reagents of `crafts` crafts: a Craft without value. chain = { crafting = { [itemId] = true }, depth }.
function costReagents(schematic, crafts, sources, chain)
	local craft =
		{ cost = 0, knownCopper = 0, estimatedCopper = 0, isComplete = true, usesPriceSource = false, reagents = {} }
	local confidences = {}
	for _, reagent in ipairs(type(schematic.reagents) == 'table' and schematic.reagents or {}) do
		if isWholePositive(reagent.itemId) and isWholePositive(reagent.qty) then
			local line = costReagent(reagent.itemId, reagent.qty * crafts, sources, chain)
			craft.reagents[#craft.reagents + 1] = line
			craft.knownCopper = craft.knownCopper + line.knownCopper
			craft.estimatedCopper = craft.estimatedCopper + line.copper - line.knownCopper
			craft.isComplete = craft.isComplete and line.isPriced
			craft.usesPriceSource = craft.usesPriceSource or line.usesPriceSource
			confidences[#confidences + 1] = line.confidence
		end
	end
	craft.cost = craft.knownCopper + craft.estimatedCopper
	craft.made = (isWholePositive(schematic.quantity) and schematic.quantity or 1) * crafts
	return craft, confidences
end

function costReagent(itemId, qty, sources, chain)
	local held = math.max(0, math.floor(tonumber(safeCall(sources.held, itemId)) or 0))
	local ownedUnits = math.min(held, qty)
	local owned = ownedCost(itemId, ownedUnits, held, sources)
	local missing = missingCost(itemId, qty - ownedUnits, sources, chain)
	return {
		itemId = itemId,
		qty = qty,
		held = held,
		copper = owned.copper + missing.copper,
		knownCopper = owned.knownCopper + (missing.knownCopper or 0),
		-- A crafted part names the line, so the craft window can say so.
		source = missing.source == 'crafted' and 'crafted' or (owned.source or missing.source),
		craftedUnits = missing.craft and (qty - ownedUnits) or nil,
		craft = missing.craft,
		isPriced = owned.isPriced and missing.isPriced,
		usesPriceSource = owned.usesPriceSource == true or missing.usesPriceSource == true,
		confidence = ns.Value.mergeConfidence({ owned.confidence, missing.confidence }),
	}
end

-- Missing units: bought, or crafted when a known recipe makes them for less (or there is no buy).
function missingCost(itemId, units, sources, chain)
	local bought = buyCost(itemId, units, sources)
	if units == 0 or chain.crafting[itemId] then
		return bought
	end
	local schematic = safeCall(sources.recipeFor, itemId)
	if type(schematic) ~= 'table' then
		return bought
	end
	if chain.depth >= CraftCost.MAX_CRAFT_DEPTH then
		bought.confidence = ns.Value.mergeConfidence({
			bought.confidence,
			lowReason('craftDepth', 'a reagent nested too deep to cost by crafting is bought'),
		})
		return bought
	end
	local crafted = craftedCost(itemId, units, schematic, sources, chain)
	-- A recipe with no reagents the engine can read would cost nothing and always win.
	local isCraftable = #crafted.craft.reagents > 0
	local isCraftCheaper = isCraftable and crafted.isPriced and (not bought.isPriced or crafted.copper < bought.copper)
	return isCraftCheaper and crafted or bought
end

-- Enough whole crafts for `units`, charged per unit made.
function craftedCost(itemId, units, schematic, sources, chain)
	local perCraft = isWholePositive(schematic.quantity) and schematic.quantity or 1
	local crafting = setmetatable({ [itemId] = true }, { __index = chain.crafting })
	local craft, confidences =
		costReagents(schematic, math.ceil(units / perCraft), sources, { crafting = crafting, depth = chain.depth + 1 })
	craft.confidence = ns.Value.mergeConfidence(confidences, 3)
	local share = units / craft.made
	return {
		copper = math.floor(craft.cost * share + 0.5),
		knownCopper = math.floor(craft.knownCopper * share + 0.5),
		isPriced = craft.isComplete,
		source = 'crafted',
		craft = craft,
		confidence = craft.confidence,
		usesPriceSource = craft.usesPriceSource,
	}
end

-- Held units: paid from the pool where known, the opportunity value for the rest.
function ownedCost(itemId, units, held, sources)
	if units == 0 then
		return { copper = 0, knownCopper = 0, isPriced = true }
	end
	local knownUnits, knownCopper = 0, 0
	if sources.valuation == 'paid' then
		local split = safeCall(sources.split, itemId, units, held)
		if type(split) == 'table' and isWholePositive(split.knownUnits) then
			knownUnits, knownCopper = split.knownUnits, split.knownCopper or 0
		end
	end
	local otherUnits = units - knownUnits
	local source = knownUnits == units and 'paid' or (knownUnits > 0 and 'paid and value' or 'value')
	if otherUnits == 0 then
		return { copper = knownCopper, knownCopper = knownCopper, isPriced = true, source = source }
	end
	local value = safeCall(sources.opportunity, itemId, otherUnits)
	if not value or value.isPriced == false or type(value.copper) ~= 'number' then
		return {
			copper = knownCopper,
			knownCopper = knownCopper,
			isPriced = false,
			source = source,
			confidence = lowReason('noPrice', 'a reagent you hold has no value'),
		}
	end
	return {
		copper = knownCopper + value.copper,
		knownCopper = knownCopper,
		isPriced = true,
		source = source,
		confidence = value.confidence,
		usesPriceSource = valueUsesSource(value),
	}
end

-- Missing units at the rule price, as a buy.
function buyCost(itemId, units, sources)
	if units == 0 then
		return { copper = 0, isPriced = true }
	end
	local price = safeCall(sources.buyPrice, itemId)
	if type(price) ~= 'table' or type(price.copper) ~= 'number' then
		return {
			copper = 0,
			isPriced = false,
			source = 'buy',
			confidence = lowReason('noPrice', 'a reagent to buy has no price'),
		}
	end
	return {
		copper = price.copper * units,
		isPriced = true,
		source = 'buy',
		confidence = price.confidence,
		usesPriceSource = price.usesPriceSource == true,
	}
end

-- An ItemValue whose rule price used an AHledger figure.
function valueUsesSource(value)
	return type(value.rulePrice) == 'table' and value.rulePrice.usesPriceSource == true
end

function safeCall(fn, ...)
	if type(fn) ~= 'function' then
		return nil
	end
	local ok, result = pcall(fn, ...)
	return ok and result or nil
end

function lowReason(code, text)
	return { level = 'low', reasons = { { code = code, level = 'low', text = text } } }
end

function isWholePositive(value)
	return type(value) == 'number' and value > 0 and value < math.huge and value % 1 == 0
end

return CraftCost
