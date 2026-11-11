--[[
	Pricing: the always-on module that owns prices. It owns the confidence settings, loads the
	AHledger tables the desktop app saved, and provides prices to the rest of the add-on and to
	other add-ons:

	  price v1          get(itemId) -> { copper, ageSeconds, source } under the default rule
	  haggler.price v1  get(itemId, ruleId?) -> Price · rules() · defaultRule()

	ns.prices is the PriceService the add-on's own modules use. Sends PRICE_TABLE_LOADED
	(marketKeys) once the saved tables are added.
]]
local _, ns = ...

-- Helpers live at the bottom of the file; declared here so they stay local.
local newMarketKeyResolver, provideCapabilities, loadSavedTables

-- The confidence settings, then the own sales count's.
local PRICING_SETTINGS = ns.Rules.confidenceSettings()
for _, setting in ipairs(ns.Sales.settings()) do
	PRICING_SETTINGS[#PRICING_SETTINGS + 1] = setting
end

local pricing = ns.host.AddModule({
	key = 'pricing',
	label = 'Pricing',
	category = 'core',
	canDisable = false,
	settings = PRICING_SETTINGS,
	onEnable = function(module)
		local wow = ns.wow
		local library = ns.PriceData.newLibrary()
		ns.prices = ns.PriceService.new({
			now = function()
				return wow:Now()
			end,
			store = ns.store,
			library = library,
			marketKey = newMarketKeyResolver(wow),
			itemInfo = function(itemId)
				return wow:ItemInfo(itemId)
			end,
			requestItemData = function(itemId)
				wow:RequestItemData(itemId)
			end,
			nextFrame = function(fn)
				return wow:After(0, fn)
			end,
			confidence = function()
				return {
					staleMediumHours = module:Setting('staleMediumHours'),
					staleLowHours = module:Setting('staleLowHours'),
				}
			end,
			sales = function()
				return {
					minScans = module:Setting('ownSalesMinScans'),
					minHours = module:Setting('ownSalesMinHours'),
					trollSharePercent = module:Setting('trollSharePercent'),
					windowDays = module:Setting('salesWindowDays'),
				}
			end,
		})
		provideCapabilities(module, ns.prices)
		loadSavedTables(module, library, wow:SavedPriceTables())
	end,
	onDisable = function()
		ns.prices = nil
	end,
})
ns.pricing = pricing

-- Helpers ---------------------------------------------------------------------------------

-- The market key is known once the client knows the player's faction; it is kept after that.
function newMarketKeyResolver(wow)
	local marketKey
	return function()
		if marketKey then
			return marketKey
		end
		local player = wow:Player()
		if player.faction ~= 'Alliance' and player.faction ~= 'Horde' then
			return nil
		end
		marketKey = ns.Store.marketKeyFor(player)
		return marketKey
	end
end

function provideCapabilities(module, prices)
	module:Provide('price', 1, {
		get = function(itemId)
			return prices:Simple(itemId)
		end,
	})
	module:Provide('haggler.price', 1, {
		get = function(itemId, ruleId)
			return prices:Get(itemId, ruleId)
		end,
		rules = function()
			return prices:Rules()
		end,
		defaultRule = function()
			return prices:DefaultRule()
		end,
	})
end

function loadSavedTables(module, library, savedTables)
	if not savedTables or library:AddSavedTables(savedTables) == 0 then
		return
	end
	local marketKeys = {}
	-- The tables stay unparsed until a price is asked for; only their keys are announced.
	for marketKey, saved in pairs(savedTables) do
		if type(marketKey) == 'string' and type(saved) == 'table' then
			marketKeys[#marketKeys + 1] = marketKey
		end
	end
	table.sort(marketKeys)
	module:Send('PRICE_TABLE_LOADED', marketKeys)
end
