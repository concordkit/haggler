--[[
	Value: the always-on module that owns item values (Engine/Value.lua): what an owned stack is
	worth to the player, the rule price after the 5% cut and the deposit risk, never below the
	vendor. Bags and the trade window read ns.values; other add-ons get the capability:

	  value v1  item(itemId, ruleId?) · stack(itemId, count, ruleId?) · bags(ruleId?)
	            -> ItemValue / Total (Engine/Value.lua), or nil and a reason

	It is a core service like Pricing (no enabled toggle): Bags and Trade each have their own.
	The deposit is estimated from the vendor price until a client deposit source is wired in.
]]
local _, ns = ...

local MODULE_KEY = 'value'

ns.host.AddModule({
	key = MODULE_KEY,
	label = 'Item value',
	category = 'core',
	canDisable = false,
	settings = {
		{
			key = 'durationHours',
			type = 'choice',
			label = 'Listing duration the deposit risk assumes',
			default = '24',
			choices = {
				{ value = '12', label = '12 hours' },
				{ value = '24', label = '24 hours' },
				{ value = '48', label = '48 hours' },
			},
		},
	},
	onEnable = function(module)
		ns.values = ns.Value.new({
			prices = ns.prices,
			store = ns.store,
			durationHours = function()
				return tonumber(module:Setting('durationHours'))
			end,
		})
		module:Provide('value', 1, {
			item = function(itemId, ruleId)
				return ns.values:Item(itemId, { ruleId = ruleId })
			end,
			stack = function(itemId, count, ruleId)
				return ns.values:Stack(itemId, count, { ruleId = ruleId })
			end,
			bags = function(ruleId)
				return ns.values:Total(ns.wow:CarriedItems(), { ruleId = ruleId })
			end,
		})
	end,
	onDisable = function()
		ns.values = nil
	end,
})
