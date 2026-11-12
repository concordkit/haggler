local t = ...
local ns = t.loadAddon()
local Store = ns.Store

t.group('migrations')

t.test('runs each migration in order and stamps the version', function()
	local order = {}
	local migrations = {
		[1] = function(db)
			order[#order + 1] = 1
			db.a = true
		end,
		[2] = function(db)
			order[#order + 1] = 2
			db.b = db.a
		end,
		[3] = function()
			order[#order + 1] = 3
		end,
	}
	local db = Store.migrate({}, migrations, 3)
	t.same(order, { 1, 2, 3 })
	t.eq(db.version, 3)
	t.eq(db.b, true)
end)

t.test('starts from the stored version', function()
	local order = {}
	local migrations = {
		[1] = function()
			order[#order + 1] = 1
		end,
		[2] = function()
			order[#order + 1] = 2
		end,
	}
	Store.migrate({ version = 1 }, migrations, 2)
	t.same(order, { 2 })
end)

t.test('refuses data from a newer schema and leaves it alone', function()
	local db = { version = 99, keep = 'me' }
	local result, reason = Store.migrate(db)
	t.eq(result, nil)
	t.eq(reason, 'newer schema')
	t.same(db, { version = 99, keep = 'me' })
end)

t.test('a missing migration step is a bug', function()
	t.raises(function()
		Store.migrate({}, {}, 1)
	end, 'no migration to version 1')
end)

t.test('0 -> 1 parks an unversioned layout under legacy', function()
	local db = { sellLog = { 1, 2 }, mode = 'realistic' }
	Store.migrate(db, nil, 1)
	t.eq(db.version, 1)
	t.same(db.legacy, { sellLog = { 1, 2 }, mode = 'realistic' })
	t.eq(db.sellLog, nil)
end)

t.test('1 -> 2 packs saved scan items; broken ones are dropped', function()
	local db = {
		version = 1,
		markets = {
			['forever/normal/alliance/us'] = {
				scan = {
					at = 10,
					hasBands = true,
					items = {
						[2589] = {
							min = 91,
							units = 37,
							copperSeen = true,
							maxStackSeen = 20,
							levels = { { price = 91, qty = 5 }, { price = 100, qty = 32, short = 12 } },
						},
						[2592] = { min = 1, units = 1, levels = { { price = 'x', qty = 1 } } },
						[2488] = 'junk',
					},
				},
			},
			['forever/normal/horde/us'] = { scan = 'junk' },
		},
	}
	Store.migrate(db, nil, 2)
	t.eq(db.version, 2)
	local scan = db.markets['forever/normal/alliance/us'].scan
	t.eq(scan.isPacked, true)
	t.same(scan.items, { [2589] = '37,1,20;91:5,100:32:12' })
	t.eq(db.markets['forever/normal/horde/us'].scan, 'junk', 'left for ScanStore.latest to ignore')
end)

t.group('store')

t.test('a first run builds the whole layout and seeds the built-in rules', function()
	local db, charDb = {}, {}
	local store = Store.open(db, charDb)
	t.eq(db.version, Store.SCHEMA_VERSION)
	for _, name in ipairs({ 'settings', 'rules', 'shownRules', 'recipes', 'markets', 'characters', 'sessions' }) do
		t.eq(type(db[name]), 'table', name)
	end
	t.eq(db.legacy, nil, 'nothing to park on a first run')
	t.eq(db.defaultRuleId, 'realistic')
	t.truthy(db.rules.realistic.builtIn)
	t.truthy(db.rules.minimum)
	t.truthy(db.rules.median)
	t.same(db.shownRules, { tooltip = {}, crafting = {}, ah = {}, bar = {} })
	t.same(charDb, { version = 1, ui = {} })
	t.eq(store:Settings(), db.settings)
end)

t.test('opening again keeps tuned built-ins and adds missing ones', function()
	local db = {}
	Store.open(db, {})
	db.rules.realistic.antiBait.minutes = 30
	db.rules.median = nil
	Store.open(db, {})
	t.eq(db.rules.realistic.antiBait.minutes, 30)
	t.truthy(db.rules.median)
end)

t.test('open refuses newer data, account or character', function()
	local store, reason = Store.open({ version = Store.SCHEMA_VERSION + 1 }, {})
	t.eq(store, nil)
	t.eq(reason, 'newer schema')
	local db = {}
	store, reason = Store.open(db, { version = 9 })
	t.eq(store, nil)
	t.eq(reason, 'newer schema')
	t.eq(db.version, nil, 'account data untouched when the character data is newer')
end)

t.test('markets are grouped by market key and created on first use', function()
	local store = Store.open({}, {})
	local market = store:Market('forever/normal/alliance/us')
	t.same(market, { scanDays = {}, ventures = {}, auctions = {}, ledger = {}, costPools = {}, ledgerDays = {} })
	market.ledger[1] = 'event'
	t.eq(store:Market('forever/normal/alliance/us').ledger[1], 'event')
	t.raises(function()
		store:Market('normal/alliance')
	end, 'bad market key')
end)

t.test('market keys follow AHledger, rulesets read from the realm name', function()
	t.eq(
		Store.marketKeyFor({ realm = 'Nightslayer', faction = 'Alliance', region = 'us' }),
		'forever/normal/alliance/us'
	)
	t.eq(
		Store.marketKeyFor({ realm = 'Doomhowl Hardcore', faction = 'Horde', region = 'us' }),
		'forever/hardcore/horde/us'
	)
	t.eq(Store.rulesetFromRealm('Crusader Strike PvP'), 'pvp')
	t.eq(Store.rulesetFromRealm('Living Flame RP'), 'rp')
	t.eq(Store.rulesetFromRealm('Wild Growth RP PvP'), 'rppvp')
	t.eq(Store.rulesetFromRealm('Sulfuron JcJ'), 'pvp')
	t.eq(Store.rulesetFromRealm('Les Ombres JdR'), 'rp')
	t.eq(Store.rulesetFromRealm('Grumpy'), 'normal', 'rp inside a word is not RP')
	t.eq(Store.rulesetFromRealm(nil), 'normal')
	t.truthy(Store.isMarketKey('forever/rppvp/horde/eu'))
	t.eq(Store.isMarketKey('forever/normal/alliance'), false)
end)

t.test('characters by Name-Realm', function()
	local store = Store.open({}, {})
	store:Character('Eilu-Nightslayer').gold = 5
	t.eq(store:Character('Eilu-Nightslayer').gold, 5)
	t.raises(function()
		store:Character('Eilu')
	end, 'bad character key')
end)

t.group('store rules')

local function customRule(id)
	return { id = id, name = 'Quick sale', base = { kind = 'lowest' }, steps = {}, antiBait = { enabled = false } }
end

t.test('saves a valid custom rule as a copy; refuses an invalid one', function()
	local store = Store.open({}, {})
	local rule = customRule('quick')
	t.truthy(store:SaveRule(rule))
	rule.name = 'changed after save'
	t.eq(store:Rule('quick').name, 'Quick sale')
	t.eq(store:Rule('quick').builtIn, nil)
	local ok, reason = store:SaveRule({ id = 'bad', name = 'Bad', base = { kind = 'guess' }, steps = {} })
	t.eq(ok, nil)
	t.truthy(reason:find('unknown kind'))
end)

t.test('saving a tuned built-in keeps it built-in', function()
	local store = Store.open({}, {})
	local tuned = ns.Rules.copy(store:Rule('median'))
	tuned.builtIn = nil
	tuned.steps = { { kind = 'multiply', factor = 0.9 } }
	t.truthy(store:SaveRule(tuned))
	t.eq(store:Rule('median').builtIn, true)
end)

t.test('rule ids list built-ins first, then by name', function()
	local store = Store.open({}, {})
	store:SaveRule(customRule('quick'))
	local ids = store:RuleIds()
	t.eq(#ids, 4)
	t.eq(ids[4], 'quick')
	t.eq(store:Rule(ids[1]).builtIn, true)
end)

t.test('delete removes a custom rule everywhere; built-ins only reset', function()
	local store = Store.open({}, {})
	store:SaveRule(customRule('quick'))
	store:SetDefaultRule('quick')
	store.db.shownRules.tooltip = { 'median', 'quick' }
	t.truthy(store:DeleteRule('quick'))
	t.eq(store:DefaultRuleId(), 'realistic')
	t.same(store.db.shownRules.tooltip, { 'median' })
	local ok, reason = store:DeleteRule('median')
	t.eq(ok, nil)
	t.eq(reason, 'built-in rules can be reset, not deleted')
	ok, reason = store:DeleteRule('nope')
	t.eq(ok, nil)
	t.eq(reason, 'unknown rule')
end)

t.test('reset puts a built-in back as shipped', function()
	local store = Store.open({}, {})
	store:Rule('minimum').steps = {}
	t.truthy(store:ResetRule('minimum'))
	t.same(store:Rule('minimum'), ns.Rules.builtIns().minimum)
	local _, reason = store:ResetRule('quick')
	t.eq(reason, 'not a built-in rule')
end)

t.test('the default rule must exist and always heads the shown rules', function()
	local store = Store.open({}, {})
	local _, reason = store:SetDefaultRule('nope')
	t.eq(reason, 'unknown rule')
	t.truthy(store:SetDefaultRule('median'))
	store.db.shownRules.crafting = { 'minimum', 'median', 'gone' }
	t.same(store:ShownRules('crafting'), { 'median', 'minimum' })
	t.same(store:ShownRules('bar'), { 'median' })
end)

t.test('a default rule that vanished falls back to Realistic on open', function()
	local db = {}
	Store.open(db, {})
	db.defaultRuleId = 'deleted'
	Store.open(db, {})
	t.eq(db.defaultRuleId, 'realistic')
end)

t.test('rule ids sort without throwing when a saved rule lost its name', function()
	local store = Store.open({}, {})
	store:SaveRule(customRule('quick'))
	store.db.rules.nameless = { id = 'nameless', base = { kind = 'median' }, steps = {} }
	local ids = store:RuleIds()
	t.eq(#ids, 5)
	t.eq(ids[5], 'nameless', 'a nameless rule sorts by its id')
end)
