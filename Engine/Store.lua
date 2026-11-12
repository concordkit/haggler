--[[
	Store: the SavedVariables layout, its schema version and the migrations between versions.

	HagglerDB (account-wide):
	  version                  schema version
	  settings                 values from every module's settings schema (Host/Settings.lua)
	  rules                    ruleId -> Rule; built-ins are stored too, so they can be tuned and reset
	  defaultRuleId            the rule used across the add-on
	  shownRules               surface -> { ruleId... } (tooltip, crafting, ah, bar)
	  recipes                  recipeId -> Recipe
	  markets[marketKey]       one auction house: scan, scanDays, ventures, auctions, ledger, costPools,
	                           ledgerDays
	  vendorPrices             itemId -> copper a vendor pays, kept once the client has shown it
	  characters[charKey]      inventory counts, gold, last seen, faction
	  sessions[charKey]        session start points: { resetAt?, ahLeftAt? } (one per character;
	                           login, the resets and local midnight come from the clock)
	  legacy                   anything an older layout left that no migration claimed

	HagglerCharDB (per character): version, ui (window position, last tab).

	marketKey follows AHledger's form, forever/<ruleset>/<faction>/<region>, so the downloaded
	table and local scans line up.
]]
local _, ns = ...

local Store = {}
ns.Store = Store

Store.SCHEMA_VERSION = 2
Store.CHAR_SCHEMA_VERSION = 1
Store.SURFACES = { 'tooltip', 'crafting', 'ah', 'bar' }

local MARKET_KEY_PATTERN = '^forever/[%l%d]+/[%l%d]+/[%l%d]+$'
local TOP_LEVEL_TABLES =
	{ 'settings', 'rules', 'shownRules', 'recipes', 'markets', 'characters', 'sessions', 'vendorPrices' }
local MARKET_TABLES = { 'scanDays', 'ventures', 'auctions', 'ledger', 'costPools', 'ledgerDays' }

-- Helpers live at the bottom of the file; declared here so they stay local.
local ensureLayout, ensureCharLayout, seedBuiltInRules, hasWord, collectLegacyKeys, packSavedScan

--- Migration n upgrades a database from version n - 1 to n. Each changes db in place.
Store.MIGRATIONS = {
	-- 0 -> 1: the clean-slate layout. The 0.1.0 build (a prototype that never shipped) had no
	-- version; whatever it left is parked under `legacy` rather than thrown away.
	[1] = function(db)
		local legacy = collectLegacyKeys(db)
		if next(legacy) then
			db.legacy = legacy
		end
	end,
	-- 1 -> 2: scan items saved as one string each (see Engine/ScanStore.lua); an item that
	-- cannot be packed is dropped, a scan that is not a table is left for ScanStore to ignore.
	[2] = function(db)
		if type(db.markets) ~= 'table' then
			return
		end
		for _, market in pairs(db.markets) do
			local scan = type(market) == 'table' and market.scan or nil
			if type(scan) == 'table' and type(scan.items) == 'table' then
				packSavedScan(scan)
			end
		end
	end,
}

--- Runs the migrations a database needs, in order. Pure: only db is changed.
--- @param db table saved table (changed in place)
--- @param migrations table|nil { [version] = fun(db) }, default Store.MIGRATIONS
--- @param targetVersion number|nil default Store.SCHEMA_VERSION
--- @return table|nil db
--- @return string|nil reason 'newer schema' when the data comes from a newer Haggler
function Store.migrate(db, migrations, targetVersion)
	if type(db) ~= 'table' then
		error('Store.migrate: db must be a table', 2)
	end
	migrations = migrations or Store.MIGRATIONS
	targetVersion = targetVersion or Store.SCHEMA_VERSION
	local version = tonumber(db.version) or 0
	if version > targetVersion then
		return nil, 'newer schema'
	end
	for nextVersion = version + 1, targetVersion do
		local migration = migrations[nextVersion]
		if not migration then
			error(string.format('Store.migrate: no migration to version %d', nextVersion), 2)
		end
		migration(db)
		db.version = nextVersion
	end
	return db
end

local StoreMethods = {}
StoreMethods.__index = StoreMethods

--- Opens the saved tables: migrates them, fills the layout and seeds the built-in rules.
--- @param db table|nil HagglerDB (nil on first run)
--- @param charDb table|nil HagglerCharDB
--- @return table|nil store
--- @return string|nil reason 'newer schema'; the tables are then left untouched
function Store.open(db, charDb)
	db = db or {}
	charDb = charDb or {}
	if (tonumber(charDb.version) or 0) > Store.CHAR_SCHEMA_VERSION then
		return nil, 'newer schema'
	end
	local migrated, reason = Store.migrate(db)
	if not migrated then
		return nil, reason
	end
	ensureLayout(db)
	ensureCharLayout(charDb)
	seedBuiltInRules(db, ns.Rules.builtIns())
	return setmetatable({ db = db, charDb = charDb }, StoreMethods)
end

--- The market key for a realm, faction and region, in AHledger's form.
--- Forever is realmless: the realm name carries the ruleset, and each ruleset has its own AH.
--- @param where table { realm, faction, region }
--- @return string marketKey e.g. 'forever/normal/alliance/us'
function Store.marketKeyFor(where)
	if type(where) ~= 'table' then
		error('Store.marketKeyFor: where must be a table', 2)
	end
	local faction = (where.faction or 'unknown'):lower()
	local region = (where.region or 'us'):lower()
	return string.format('forever/%s/%s/%s', Store.rulesetFromRealm(where.realm), faction, region)
end

--- The ruleset a realm name carries: hardcore, rppvp, pvp, rp or normal. European clients use
--- their own words (JcJ, JxJ for PvP; JdR, GdR, Rol for RP).
function Store.rulesetFromRealm(realm)
	local name = (realm or ''):lower()
	if name:find('hardcore', 1, true) then
		return 'hardcore'
	end
	local isPvp = name:find('pvp', 1, true) ~= nil or hasWord(name, 'jcj') or hasWord(name, 'jxj')
	local isRp = hasWord(name, 'rp') or hasWord(name, 'jdr') or hasWord(name, 'gdr') or hasWord(name, 'rol')
	if isRp and isPvp then
		return 'rppvp'
	end
	if isPvp then
		return 'pvp'
	end
	return isRp and 'rp' or 'normal'
end

function Store.isMarketKey(key)
	return type(key) == 'string' and key:find(MARKET_KEY_PATTERN) ~= nil
end

--- The saved settings table, for Host.Start.
function StoreMethods:Settings()
	return self.db.settings
end

--- One market's data, created on first use.
--- @param marketKey string
function StoreMethods:Market(marketKey)
	if not Store.isMarketKey(marketKey) then
		error(string.format('Store:Market: bad market key %q', tostring(marketKey)), 2)
	end
	local market = self.db.markets[marketKey]
	if not market then
		market = {}
		self.db.markets[marketKey] = market
	end
	for _, name in ipairs(MARKET_TABLES) do
		market[name] = market[name] or {}
	end
	return market
end

--- One character's data, created on first use. charKey is 'Name-Realm'.
function StoreMethods:Character(charKey)
	if type(charKey) ~= 'string' or not charKey:find('^[^%-]+%-.+$') then
		error(string.format('Store:Character: bad character key %q', tostring(charKey)), 2)
	end
	local character = self.db.characters[charKey]
	if not character then
		character = {}
		self.db.characters[charKey] = character
	end
	return character
end

--- One character's session start points, created on first use. charKey is 'Name-Realm'.
--- @return table { loginAt?, resetAt?, ahLeftAt? }
function StoreMethods:Session(charKey)
	if type(charKey) ~= 'string' or not charKey:find('^[^%-]+%-.+$') then
		error(string.format('Store:Session: bad character key %q', tostring(charKey)), 2)
	end
	local session = self.db.sessions[charKey]
	if type(session) ~= 'table' then
		session = {}
		self.db.sessions[charKey] = session
	end
	return session
end

--- @return table|nil Rule
function StoreMethods:Rule(ruleId)
	return self.db.rules[ruleId]
end

--- Rule ids, built-ins first, then by name.
function StoreMethods:RuleIds()
	local ids = {}
	for id in pairs(self.db.rules) do
		ids[#ids + 1] = id
	end
	local rules = self.db.rules
	table.sort(ids, function(a, b)
		local ruleA, ruleB = rules[a], rules[b]
		if (ruleA.builtIn == true) ~= (ruleB.builtIn == true) then
			return ruleA.builtIn == true
		end
		return tostring(ruleA.name or a) < tostring(ruleB.name or b)
	end)
	return ids
end

--- Saves a rule (new or changed) after validating it.
--- @return boolean|nil true when saved
--- @return string|nil reason
function StoreMethods:SaveRule(rule)
	local isValid, reason = ns.Rules.validate(rule)
	if not isValid then
		return nil, reason
	end
	local existing = self.db.rules[rule.id]
	local copy = ns.Rules.copy(rule)
	copy.builtIn = existing ~= nil and existing.builtIn == true or nil
	self.db.rules[rule.id] = copy
	return true
end

--- Deletes a custom rule. Built-ins can only be reset; the default rule moves to Realistic.
--- @return boolean|nil, string|nil reason
function StoreMethods:DeleteRule(ruleId)
	local rule = self.db.rules[ruleId]
	if not rule then
		return nil, 'unknown rule'
	end
	if rule.builtIn then
		return nil, 'built-in rules can be reset, not deleted'
	end
	self.db.rules[ruleId] = nil
	if self.db.defaultRuleId == ruleId then
		self.db.defaultRuleId = ns.Rules.DEFAULT_RULE_ID
	end
	for _, surface in ipairs(Store.SURFACES) do
		local kept = {}
		for _, shownId in ipairs(self.db.shownRules[surface]) do
			if shownId ~= ruleId then
				kept[#kept + 1] = shownId
			end
		end
		self.db.shownRules[surface] = kept
	end
	return true
end

--- Puts a built-in rule back to how it ships.
--- @return boolean|nil, string|nil reason
function StoreMethods:ResetRule(ruleId)
	local shipped = ns.Rules.builtIns()[ruleId]
	if not shipped then
		return nil, 'not a built-in rule'
	end
	self.db.rules[ruleId] = shipped
	return true
end

function StoreMethods:DefaultRuleId()
	return self.db.defaultRuleId
end

--- @return boolean|nil, string|nil reason
function StoreMethods:SetDefaultRule(ruleId)
	if not self.db.rules[ruleId] then
		return nil, 'unknown rule'
	end
	self.db.defaultRuleId = ruleId
	return true
end

--- The rules shown on a surface; the default rule always comes first.
function StoreMethods:ShownRules(surface)
	local shown = { self.db.defaultRuleId }
	for _, ruleId in ipairs(self.db.shownRules[surface] or {}) do
		if ruleId ~= self.db.defaultRuleId and self.db.rules[ruleId] then
			shown[#shown + 1] = ruleId
		end
	end
	return shown
end

--- Every market, keyed by market key (for pruning across markets).
function StoreMethods:Markets()
	return self.db.markets
end

--- The vendor price last seen for an item, or nil when it was never seen (or the saved value
--- is broken).
--- @param itemId number
--- @return number|nil copper
function StoreMethods:VendorPrice(itemId)
	local copper = self.db.vendorPrices[itemId]
	local isUsable = type(copper) == 'number' and copper >= 0 and copper < math.huge
	return isUsable and copper or nil
end

--- Keeps an item's vendor price, so it is known before the client caches the item again.
--- @param itemId number
--- @param copper number
function StoreMethods:RememberVendorPrice(itemId, copper)
	if type(itemId) ~= 'number' or type(copper) ~= 'number' or copper < 0 or copper >= math.huge then
		error('Store:RememberVendorPrice: itemId and copper must be numbers', 2)
	end
	self.db.vendorPrices[itemId] = copper
end

--- Per-character UI state.
function StoreMethods:Ui()
	return self.charDb.ui
end

-- Helpers ---------------------------------------------------------------------------------

-- Idempotent: fills every missing part of the layout, never changes what is there.
function ensureLayout(db)
	for _, name in ipairs(TOP_LEVEL_TABLES) do
		if type(db[name]) ~= 'table' then
			db[name] = {}
		end
	end
	for _, surface in ipairs(Store.SURFACES) do
		if type(db.shownRules[surface]) ~= 'table' then
			db.shownRules[surface] = {}
		end
	end
	if type(db.defaultRuleId) ~= 'string' then
		db.defaultRuleId = ns.Rules.DEFAULT_RULE_ID
	end
end

function ensureCharLayout(charDb)
	charDb.version = Store.CHAR_SCHEMA_VERSION
	if type(charDb.ui) ~= 'table' then
		charDb.ui = {}
	end
end

-- Adds any missing built-in rule; tuned built-ins are kept as they are.
function seedBuiltInRules(db, builtIns)
	for ruleId, rule in pairs(builtIns) do
		if not db.rules[ruleId] then
			db.rules[ruleId] = rule
		end
	end
	if not db.rules[db.defaultRuleId] then
		db.defaultRuleId = ns.Rules.DEFAULT_RULE_ID
	end
end

function hasWord(text, word)
	return text:find('%f[%a]' .. word .. '%f[%A]') ~= nil
end

-- Removes every key of an unversioned table and returns them.
function collectLegacyKeys(db)
	local legacy = {}
	for key, value in pairs(db) do
		if key ~= 'version' then
			legacy[key] = value
		end
	end
	for key in pairs(legacy) do
		db[key] = nil
	end
	return legacy
end

function packSavedScan(scan)
	-- Store.lua loads before ScanStore.lua; migrations run later, at ADDON_LOADED.
	local ScanStore = ns.ScanStore
	local packedItems = {}
	for itemId, item in pairs(scan.items) do
		local packed = type(item) == 'string' and item or ScanStore.packItem(item)
		if packed and not ScanStore.unpackItem(packed).isMalformed then
			packedItems[itemId] = packed
		end
	end
	scan.items = packedItems
	scan.isPacked = true
end

return Store
