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

	HagglerCharDB (per character): version, ui (window position, last tab), realm (the last realm
	name the client gave for this character, for clients that give none; see ResolveRealm).

	marketKey follows AHledger's form, forever/<ruleset>/<faction>/<region>, so the downloaded
	table and local scans line up.
]]
local _, ns = ...

local Store = {}
ns.Store = Store

Store.SCHEMA_VERSION = 3
Store.CHAR_SCHEMA_VERSION = 1
Store.SURFACES = { 'tooltip', 'crafting', 'ah', 'bar' }

local MARKET_KEY_PATTERN = '^forever/[%l%d]+/[%l%d]+/[%l%d]+$'
local TOP_LEVEL_TABLES =
	{ 'settings', 'rules', 'shownRules', 'recipes', 'markets', 'characters', 'sessions', 'vendorPrices' }
local MARKET_TABLES = { 'scanDays', 'ventures', 'auctions', 'ledger', 'costPools', 'ledgerDays' }
local RULESETS = { normal = true, pvp = true, rp = true, rppvp = true, hardcore = true }
-- Tables keyed 'Name-Realm' that tell which realm a character was on before the client stopped
-- naming it.
local CHARACTER_KEYED_TABLES = { 'sessions', 'characters' }

-- Helpers live at the bottom of the file; declared here so they stay local.
local ensureLayout, ensureCharLayout, seedBuiltInRules, hasWord, collectLegacyKeys, packSavedScan
local nonEmpty, realmFromSavedKeys, isServerRealm

--- Migration n upgrades a database from version n - 1 to n. Each changes db in place and gets
--- the context Store.migrate was given ({ now? }).
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
	-- 2 -> 3: own-only (ASK-M-005). Every value derived from a price source goes; cash parts
	-- stay. See Engine/OwnOnly.lua.
	[3] = function(db, context)
		ns.OwnOnly.migrate(db, context)
	end,
}

--- Runs the migrations a database needs, in order. Pure: only db is changed.
--- @param db table saved table (changed in place)
--- @param migrations table|nil { [version] = fun(db) }, default Store.MIGRATIONS
--- @param targetVersion number|nil default Store.SCHEMA_VERSION
--- @param context table|nil { now? } passed to each migration
--- @return table|nil db
--- @return string|nil reason 'newer schema' when the data comes from a newer Haggler
function Store.migrate(db, migrations, targetVersion, context)
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
		migration(db, context or {})
		db.version = nextVersion
	end
	return db
end

local StoreMethods = {}
StoreMethods.__index = StoreMethods

--- Opens the saved tables: migrates them, fills the layout and seeds the built-in rules.
--- @param db table|nil HagglerDB (nil on first run)
--- @param charDb table|nil HagglerCharDB
--- @param options table|nil { now? } unix seconds, for migrations that keep a time window
--- @return table|nil store
--- @return string|nil reason 'newer schema'; the tables are then left untouched
function Store.open(db, charDb, options)
	db = db or {}
	charDb = charDb or {}
	if (tonumber(charDb.version) or 0) > Store.CHAR_SCHEMA_VERSION then
		return nil, 'newer schema'
	end
	local migrated, reason = Store.migrate(db, nil, nil, options)
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
	local ruleset = RULESETS[where.ruleset] and where.ruleset or Store.rulesetFromRealm(where.realm)
	return string.format('forever/%s/%s/%s', ruleset, faction, region)
end

--- The ruleset of a market key, when that market is this faction's and region's; else nil.
--- @param marketKey string|nil e.g. 'forever/pvp/horde/eu'
--- @param where table { faction, region }
--- @return string|nil ruleset
function Store.rulesetFromMarket(marketKey, where)
	if type(marketKey) ~= 'string' or type(where) ~= 'table' then
		return nil
	end
	local ruleset, faction, region = marketKey:match('^forever/([%l%d]+)/([%l%d]+)/([%l%d]+)$')
	if not RULESETS[ruleset] or faction ~= (where.faction or ''):lower() or region ~= (where.region or ''):lower() then
		return nil
	end
	return ruleset
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

--- The player's realm name, and where it came from: 'client' (the client gave it; it is remembered
--- for this character), 'remembered' (the last one the client gave for this character), 'saved'
--- (the one realm this character's name is saved under, from before the client stopped giving
--- it; remembered from then on), or nil when nothing names it. Writes HagglerCharDB.realm.
--- @param player table Wow:Player()
--- @return string|nil realm
--- @return string|nil source
function StoreMethods:ResolveRealm(player)
	if type(player) ~= 'table' then
		error('Store:ResolveRealm: player must be a table', 2)
	end
	local given = nonEmpty(player.realm)
	if given then
		self.charDb.realm = given
		return given, 'client'
	end
	local remembered = nonEmpty(self.charDb.realm)
	if remembered then
		return remembered, 'remembered'
	end
	local saved = realmFromSavedKeys(self.db, nonEmpty(player.name))
	if saved then
		self.charDb.realm = saved
		return saved, 'saved'
	end
	return nil, nil
end

--- The player's character key, 'Name-Realm', or nil while the client does not know the name.
--- With no realm name from anywhere (ResolveRealm) the realm part is the server number,
--- 'Name-Server 6928'; nil when there is none either. Never 'Name-'.
--- @param player table|nil Wow:Player()
--- @return string|nil charKey
function StoreMethods:CharacterKey(player)
	local name = type(player) == 'table' and nonEmpty(player.name) or nil
	if not name or name:find('-', 1, true) then
		return nil
	end
	local realm = self:ResolveRealm(player)
	if not realm and type(player.server) == 'number' then
		realm = 'Server ' .. player.server
	end
	return realm and (name .. '-' .. realm) or nil
end

--- The player's market key. The ruleset is the realm name's (ResolveRealm); with no realm name it
--- is the one in AHledger's market when that is this faction's and region's, else normal.
--- @param player table Wow:Player()
--- @param sourceMarket string|nil AHledgerAPI.GetMarket()
--- @return string marketKey
function StoreMethods:MarketKeyFor(player, sourceMarket)
	if type(player) ~= 'table' then
		error('Store:MarketKeyFor: player must be a table', 2)
	end
	local realm = self:ResolveRealm(player)
	return Store.marketKeyFor({
		realm = realm,
		ruleset = not realm and Store.rulesetFromMarket(sourceMarket, player) or nil,
		faction = player.faction,
		region = player.region,
	})
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

function nonEmpty(value)
	if type(value) ~= 'string' then
		return nil
	end
	local trimmed = value:match('^%s*(.-)%s*$')
	return trimmed ~= '' and trimmed or nil
end

-- The one realm saved keys name for this character's name; nil when none do or they disagree
-- (the same name on two realms). A key whose realm is a server number names no realm.
function realmFromSavedKeys(db, name)
	if not name then
		return nil
	end
	local prefix = name .. '-'
	local found
	for _, tableName in ipairs(CHARACTER_KEYED_TABLES) do
		for key in pairs(db[tableName] or {}) do
			local realm = type(key) == 'string' and key:sub(1, #prefix) == prefix and nonEmpty(key:sub(#prefix + 1))
			if realm and not isServerRealm(realm) then
				if found and found ~= realm then
					return nil
				end
				found = realm
			end
		end
	end
	return found
end

function isServerRealm(realm)
	return realm:find('^Server %d+$') ~= nil
end

return Store
