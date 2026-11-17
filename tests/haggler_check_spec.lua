-- The dev-only check suite (dev/Haggler_Check): runs and verdicts, the judges, the observer and
-- the checker, against fake saved tables and a fake client.
local t = ...

local DIR = 'dev/Haggler_Check/'
local MARKET = 'forever/normal/alliance/us'
local CHAR = 'Eilu-Nightslayer'
local NOW = 1000000

local function loadCheckAddon()
	local ns = {}
	for _, file in ipairs({ 'Suite.lua', 'Items.lua', 'Observer.lua', 'Panel.lua', 'Check.lua' }) do
		assert(loadfile(DIR .. file))('Haggler_Check', ns)
	end
	return ns
end

local ns = loadCheckAddon()
local Suite, Items = ns.Suite, ns.Items

local function itemById(id)
	for _, item in ipairs(Items.list) do
		if item.id == id then
			return item
		end
	end
	error('no item ' .. id)
end

local function fakeApi(overrides)
	local api = {
		isHagglerLoaded = function()
			return true
		end,
		hagglerVersion = function()
			return '0.2.0-dev'
		end,
		hasErrorHook = function()
			return true
		end,
		frameShown = function()
			return false
		end,
		framePoint = function()
			return nil
		end,
		bindingAction = function()
			return nil
		end,
		hasLdb = function()
			return true
		end,
		ldbText = function()
			return true, ''
		end,
		freeBagSlots = function()
			return 10
		end,
		inboxCount = function()
			return 0
		end,
		isInCombat = function()
			return false
		end,
	}
	for name, fn in pairs(overrides or {}) do
		api[name] = fn
	end
	return api
end

local function factsWith(db, overrides)
	return {
		db = db,
		charDb = {},
		charKey = CHAR,
		now = NOW,
		run = { startedAt = NOW - 100 },
		api = fakeApi(overrides),
	}
end

local function signal(name, at, ...)
	return { name = name, args = { ... }, at = at or NOW }
end

local function ledgerRow(kind, itemId, extra)
	local row = { t = NOW, kind = kind, itemId = itemId, qty = 1, copper = 100, char = CHAR }
	for key, value in pairs(extra or {}) do
		row[key] = value
	end
	return row
end

-- Feeds signals to one item's judge and returns the last verdict.
local function judgeAll(item, facts, signals, scratch)
	scratch = scratch or {}
	local verdict
	for _, each in ipairs(signals) do
		verdict = item.judge(facts, scratch, each) or verdict
	end
	return verdict, scratch
end

-- The item table ---------------------------------------------------------------------------

t.test('the item table is well formed: safe items first, every judge listens', function()
	Suite.validateItems(Items.list)
	local known = { LOAD = true, LOGOUT = true, TICK = true, LEDGER = true, LUA_ERROR = true }
	for _, item in ipairs(Items.list) do
		for _, name in ipairs(item.on or {}) do
			local hookName = name:match('^HOOK:(.+)$')
			t.truthy(known[name] or name:match('^[A-Z_]+$') or hookName, item.id .. ' listens to ' .. name)
		end
	end
	t.raises(function()
		Suite.validateItems({
			{ id = 'a', title = 'A', kind = 'look', prompt = 'x', zone = 'fight' },
			{ id = 'b', title = 'B', kind = 'look', prompt = 'x', zone = 'safe' },
		})
	end, 'after a fight item')
	t.raises(function()
		Suite.validateItems({ { id = 'a', title = 'A', kind = 'action', prompt = 'x', zone = 'safe' } })
	end, 'needs a judge')
end)

-- Suite ------------------------------------------------------------------------------------

t.test('a run is keyed by version and build and reused on reload', function()
	local db = {}
	local run = Suite.openRun(db, '0.2.0', '1.15.8.1234', NOW)
	t.eq(run.key, '0.2.0@1.15.8.1234')
	t.eq(Suite.openRun(db, '0.2.0', '1.15.8.1234', NOW + 5), run, 'same run after a reload')
	t.eq(db.current, run.key)
	local nextBuild = Suite.openRun(db, '0.2.0', '1.15.8.1300', NOW + 10)
	t.truthy(nextBuild ~= run, 'a new build is a new run')
end)

t.test('a fail sticks, a look never replaces a judged result, evidence is capped', function()
	local db = {}
	local run = Suite.openRun(db, 'v', 'b', NOW)
	local item = { id = 'x', once = false }
	t.eq(Suite.record(db, run, item, { state = 'pass', evidence = { 'ok' } }, NOW), true)
	t.eq(Suite.record(db, run, item, { state = 'look', evidence = { 'hm' } }, NOW), false, 'look after pass')
	t.eq(Suite.record(db, run, item, { state = 'fail', evidence = { 'bad' } }, NOW), true)
	t.eq(Suite.record(db, run, item, { state = 'pass', evidence = { 'ok again' } }, NOW), false, 'pass after fail')
	t.eq(run.results.x.state, 'fail')
	local long = {}
	for index = 1, 20 do
		long[index] = string.rep('z', 500)
	end
	Suite.record(db, run, { id = 'y' }, { state = 'look', evidence = long }, NOW)
	t.eq(#run.results.y.evidence, Suite.MAX_EVIDENCE_LINES)
	t.eq(#run.results.y.evidence[1], Suite.MAX_EVIDENCE_BYTES)
	t.raises(function()
		Suite.record(db, run, item, { state = 'maybe' }, NOW)
	end, 'must be pass, fail')
end)

t.test('once answers carry over runs until a reset, which keeps the old run aside', function()
	local db = {}
	local run = Suite.openRun(db, 'v', 'b', NOW)
	local onceItem = { id = 'o', once = true }
	Suite.record(db, run, onceItem, { state = 'pass', evidence = {} }, NOW)
	local laterRun = Suite.openRun(db, 'v', 'b2', NOW + 1)
	t.eq(Suite.resultOf(db, laterRun, onceItem).state, 'pass', 'once answer shown in the next build')
	local fresh = Suite.resetRun(db, 'v', 'b2', NOW + 2)
	t.eq(Suite.resultOf(db, fresh, onceItem), nil, 'reset clears once answers')
	t.truthy(db.runs['v@b2 #1'], 'old run kept aside')
	t.eq(db.runs['v@b2'], fresh)
end)

t.test('progress counts states and the next item is the first unjudged one', function()
	local db = {}
	local run = Suite.openRun(db, 'v', 'b', NOW)
	local items = { { id = 'a' }, { id = 'b' }, { id = 'c' }, { id = 'd' } }
	Suite.record(db, run, items[1], { state = 'pass' }, NOW)
	Suite.record(db, run, items[2], { state = 'look' }, NOW)
	Suite.record(db, run, items[3], { state = 'na' }, NOW)
	t.same(Suite.progress(db, run, items), { judged = 2, total = 4, pass = 1, fail = 0, look = 1, na = 1, pending = 1 })
	t.eq(Suite.nextItem(db, run, items), items[2])
end)

t.test('old runs are pruned, the current one never', function()
	local db = {}
	for index = 1, Suite.MAX_KEPT_RUNS + 5 do
		Suite.openRun(db, 'v', 'b' .. index, NOW + index)
	end
	local count = 0
	for _ in pairs(db.runs) do
		count = count + 1
	end
	t.eq(count, Suite.MAX_KEPT_RUNS)
	t.truthy(db.runs['v@b' .. (Suite.MAX_KEPT_RUNS + 5)], 'current kept')
end)

-- Judges -----------------------------------------------------------------------------------

t.test('load.clean: passes at load, fails on a Haggler error or blocked action only', function()
	local item = itemById('load.clean')
	local facts = factsWith({ version = 2 })
	t.eq(item.judge(facts, {}, signal('LOAD', NOW, false, true)).state, 'pass')
	t.eq(item.judge(facts, {}, signal('LUA_ERROR', NOW, 'Interface/AddOns/Other/x.lua:1: boom')), nil)
	t.eq(item.judge(facts, {}, signal('LUA_ERROR', NOW, 'Interface/AddOns/Haggler_Check/x.lua:1')), nil, 'own errors')
	t.eq(item.judge(facts, {}, signal('LUA_ERROR', NOW, 'Interface/AddOns/Haggler/UI/Bar.lua:1: boom')).state, 'fail')
	t.eq(item.judge(facts, {}, signal('ADDON_ACTION_BLOCKED', NOW, 'Haggler', 'UseAction()')).state, 'fail')
	t.eq(item.judge(facts, {}, signal('ADDON_ACTION_BLOCKED', NOW, 'Other', 'UseAction()')), nil)
	t.eq(item.judge(factsWith({}), {}, signal('LOAD')).state, 'fail', 'no store')
end)

t.test('bar.rule: passes after two changes of the default rule', function()
	local item = itemById('bar.rule')
	local db = { defaultRuleId = 'r1' }
	local facts = factsWith(db)
	local scratch = {}
	t.eq(item.judge(facts, scratch, signal('TICK')), nil)
	db.defaultRuleId = 'r2'
	t.eq(item.judge(facts, scratch, signal('TICK')), nil)
	db.defaultRuleId = 'r1'
	t.same(item.judge(facts, scratch, signal('TICK')), { state = 'pass', evidence = { 'r1 -> r2', 'r2 -> r1' } })
end)

t.test('bar.position: the bar is placed after a reload where it was dragged', function()
	local item = itemById('bar.position')
	local charDb = { ui = { topBar = { point = 'TOP', relativePoint = 'TOP', x = 0, y = 0 } } }
	local placed = { 'TOP', 'TOP', 120, -40 }
	local facts = factsWith({}, {
		framePoint = function()
			return placed[1], placed[2], placed[3], placed[4]
		end,
	})
	facts.charDb = charDb
	local scratch = {}
	t.eq(item.judge(facts, scratch, signal('LOAD', NOW, true, false)), nil, 'first load sets the baseline')
	charDb.ui.topBar = { point = 'TOP', relativePoint = 'TOP', x = 120, y = -40 }
	item.judge(facts, scratch, signal('LOGOUT'))
	t.eq(item.judge(facts, scratch, signal('LOAD', NOW, false, true)).state, 'pass')
	charDb.ui.topBar = { point = 'TOP', relativePoint = 'TOP', x = 300, y = -40 }
	item.judge(facts, scratch, signal('LOGOUT'))
	t.eq(item.judge(facts, scratch, signal('LOAD', NOW, false, true)).state, 'fail', 'placed elsewhere')
end)

t.test('session.reload: the session survives a reload, a moved start fails', function()
	local item = itemById('session.reload')
	local db = { sessions = { [CHAR] = { loginAt = NOW - 900, resetAt = 5, ahLeftAt = 7 } } }
	local facts = factsWith(db)
	local scratch = {}
	item.judge(facts, scratch, signal('LOGOUT'))
	t.eq(item.judge(facts, scratch, signal('LOAD', NOW, false, true)).state, 'pass')
	item.judge(facts, scratch, signal('LOGOUT'))
	db.sessions[CHAR].loginAt = NOW
	t.eq(item.judge(facts, scratch, signal('LOAD', NOW, false, true)).state, 'fail')
	item.judge(facts, scratch, signal('LOGOUT'))
	t.eq(item.judge(facts, scratch, signal('LOAD', NOW, true, false)), nil, 'a login is not a reload')
end)

t.test('session.relog: the login start moves on a relog of the same character', function()
	local item = itemById('session.relog')
	local db = { sessions = { [CHAR] = { loginAt = NOW - 900 } } }
	local scratch = {}
	item.judge(factsWith(db), scratch, signal('LOGOUT'))
	db.sessions[CHAR].loginAt = NOW + 60
	local later = factsWith(db)
	later.now = NOW + 60
	t.eq(item.judge(later, scratch, signal('LOAD', NOW + 60, true, false)).state, 'pass')
	item.judge(later, scratch, signal('LOGOUT'))
	local alt = factsWith(db)
	alt.charKey = 'Alt-Nightslayer'
	t.eq(item.judge(alt, scratch, signal('LOAD', NOW + 120, true, false)), nil, 'another character')
end)

t.test('persist.data: fails when the last ledger row changes across a reload', function()
	local item = itemById('persist.data')
	local market = { ledger = { { NOW, 'sale', 1, 1, 100 } }, ventures = { v1 = {} }, costPools = {} }
	local db = { markets = { [MARKET] = market } }
	local scratch = {}
	item.judge(factsWith(db), scratch, signal('LOGOUT'))
	t.eq(item.judge(factsWith(db), scratch, signal('LOAD')).state, 'pass')
	item.judge(factsWith(db), scratch, signal('LOGOUT'))
	market.ledger = {}
	t.eq(item.judge(factsWith(db), scratch, signal('LOAD')).state, 'fail')
end)

t.test('venture.plan: one venture planning two crafts passes, two one-craft ventures fail', function()
	local item = itemById('venture.plan')
	local market = { ventures = { a = { createdAt = NOW, lines = { { recipeId = 9, plannedCrafts = 2 } } } } }
	t.eq(item.judge(factsWith({ markets = { [MARKET] = market } }), {}, signal('TICK')).state, 'pass')
	market.ventures = {
		a = { createdAt = NOW, lines = { { recipeId = 9, plannedCrafts = 1 } } },
		b = { createdAt = NOW, lines = { { recipeId = 9, plannedCrafts = 1 } } },
	}
	t.eq(item.judge(factsWith({ markets = { [MARKET] = market } }), {}, signal('TICK')).state, 'fail')
	market.ventures.b.createdAt = NOW - 1000
	t.eq(item.judge(factsWith({ markets = { [MARKET] = market } }), {}, signal('TICK')), nil, 'older venture ignored')
end)

t.test('craft.book: one craft row per cast, judged after the casts settle', function()
	local item = itemById('craft.book')
	local facts = factsWith({})
	local verdict = judgeAll(item, facts, {
		signal('HOOK:CraftRecipe', NOW, 2001, 2),
		signal('UNIT_SPELLCAST_SUCCEEDED', NOW, 'player', 'cast-guid', 2001),
		signal('LEDGER', NOW, { ledgerRow('craft', 5) }),
		signal('UNIT_SPELLCAST_SUCCEEDED', NOW + 1, 'player', 'cast-guid', 2001),
		signal('LEDGER', NOW + 1, { ledgerRow('craft', 5) }),
		signal('TICK', NOW + 2),
	})
	t.eq(verdict, nil, 'not settled')
	verdict = judgeAll(item, facts, {
		signal('HOOK:CraftRecipe', NOW, 2001, 1),
		signal('UNIT_SPELLCAST_SUCCEEDED', NOW, 'player', 'cast-guid', 2001),
		signal('LEDGER', NOW, { ledgerRow('craft', 5), ledgerRow('craft', 5) }),
		signal('TICK', NOW + 4),
	})
	t.eq(verdict.state, 'fail', 'booked twice')
	verdict = judgeAll(item, facts, {
		signal('HOOK:CraftRecipe', NOW, 2001, 1),
		signal('UNIT_SPELLCAST_SUCCEEDED', NOW, 'player', 'cast-guid', 2001),
		signal('LEDGER', NOW, { ledgerRow('craft', 5) }),
		signal('TICK', NOW + 4),
	})
	t.eq(verdict.state, 'pass')
end)

t.test('vendor.book: a vendor buy and sell pass, more vendor buys than buy calls fail', function()
	local item = itemById('vendor.book')
	local facts = factsWith({})
	t.eq(
		judgeAll(item, facts, {
			signal('MERCHANT_SHOW'),
			signal('HOOK:BuyMerchantItem', NOW, 3, 1),
			signal('LEDGER', NOW, { ledgerRow('vendorBuy', 5), ledgerRow('vendorSell', 6) }),
			signal('MERCHANT_CLOSED'),
		}).state,
		'pass'
	)
	t.eq(
		judgeAll(item, facts, {
			signal('MERCHANT_SHOW'),
			signal('LEDGER', NOW, { ledgerRow('vendorBuy', 5) }),
		}).state,
		'fail'
	)
end)

t.test('bags.destroy: a destroy row must match the deleted item', function()
	local item = itemById('bags.destroy')
	local facts = factsWith({})
	local function deleted(itemId, at)
		local each = signal('HOOK:DeleteCursorItem', at)
		each.args.itemId = itemId
		return each
	end
	t.eq(
		judgeAll(
			item,
			facts,
			{ deleted(5, NOW), signal('LEDGER', NOW, { ledgerRow('destroy', 5) }), signal('TICK', NOW + 4) }
		).state,
		'pass'
	)
	t.eq(
		judgeAll(item, facts, { signal('LEDGER', NOW, { ledgerRow('destroy', 5) }), signal('TICK', NOW + 4) }).state,
		'fail',
		'destroy without a delete'
	)
	t.eq(judgeAll(item, facts, { deleted(5, NOW), signal('TICK', NOW + 4) }).state, 'fail', 'delete not booked')
end)

t.test('mail.take: sale, return and won rows pass; more sales than sale takes fail', function()
	local item = itemById('mail.take')
	local facts = factsWith({})
	local function take(invoiceType)
		local each = signal('HOOK:TakeInboxMoney', NOW, 1)
		each.args.invoiceType = invoiceType
		return each
	end
	t.eq(
		judgeAll(item, facts, {
			signal('MAIL_SHOW'),
			take('seller'),
			signal(
				'LEDGER',
				NOW,
				{ ledgerRow('sale', 5), ledgerRow('cut', 5), ledgerRow('expire', 6), ledgerRow('buy', 7) }
			),
		}).state,
		'pass'
	)
	t.eq(judgeAll(item, facts, { signal('MAIL_SHOW'), signal('LEDGER', NOW, { ledgerRow('sale', 5) }) }).state, 'fail')
end)

t.test('mail.fullbags: a won take that failed on full bags is not booked, the retake is', function()
	local item = itemById('mail.fullbags')
	local facts = factsWith({})
	local function take(freeSlots, at)
		local each = signal('HOOK:TakeInboxItem', at or NOW, 1, 1)
		each.args.invoiceType, each.args.freeSlots = 'buyer', freeSlots
		return each
	end
	t.eq(
		judgeAll(
			item,
			facts,
			{ take(0), signal('MAIL_CLOSED'), take(3), signal('LEDGER', NOW, { ledgerRow('buy', 5) }) }
		).state,
		'pass'
	)
	t.eq(
		judgeAll(item, facts, { take(0), signal('LEDGER', NOW, { ledgerRow('buy', 5) }), signal('MAIL_CLOSED') }).state,
		'fail'
	)
end)

t.test('mail.newmail: new mail during a sale take still books one sale', function()
	local item = itemById('mail.newmail')
	local inbox = 1
	local facts = factsWith({}, {
		inboxCount = function()
			return inbox
		end,
	})
	local take = signal('HOOK:TakeInboxMoney', NOW, 1)
	take.args.invoiceType, take.args.inboxCount = 'seller', 1
	inbox = 2
	t.eq(
		judgeAll(item, facts, {
			take,
			signal('MAIL_INBOX_UPDATE'),
			signal('LEDGER', NOW, { ledgerRow('sale', 5) }),
			signal('TICK', NOW + 4),
		}).state,
		'pass'
	)
	t.eq(
		judgeAll(item, facts, {
			take,
			signal('MAIL_INBOX_UPDATE'),
			signal('LEDGER', NOW, { ledgerRow('sale', 5), ledgerRow('sale', 5) }),
			signal('TICK', NOW + 4),
		}).state,
		'fail'
	)
end)

t.test('ah.post and ah.undercut: the tracked auction carries the price actually posted', function()
	local db =
		{ markets = { [MARKET] = { auctions = { [77] = { itemId = 5, unitPrice = 90, qty = 2, state = 'active' } } } } }
	local facts = factsWith(db)
	local post = itemById('ah.post')
	t.eq(
		judgeAll(post, facts, {
			signal('AUCTION_HOUSE_AUCTION_CREATED', NOW, 77),
			signal('LEDGER', NOW, { ledgerRow('deposit', 5, { auctionId = 77 }) }),
		}).state,
		'pass'
	)
	local undercut = itemById('ah.undercut')
	local warned = {
		signal('AUCTION_HOUSE_POST_WARNING'),
		signal('HOOK:PostItem', NOW, {}, 1, 2, 0, 180),
		signal('AUCTION_HOUSE_AUCTION_CREATED', NOW, 77),
	}
	t.eq(judgeAll(undercut, facts, warned).state, 'pass', '180 for 2 is 90 each')
	db.markets[MARKET].auctions[77].unitPrice = 60
	t.eq(judgeAll(undercut, facts, warned).state, 'fail', 'the declined price was booked')
end)

t.test('ah.cancel and ah.untracked: cancel marks the record; a second cancel waits for the server', function()
	local db = {
		markets = {
			[MARKET] = {
				auctions = {
					[1] = { state = 'cancelled', deposit = 10 },
					[2] = { state = 'active' },
					[3] = { state = 'active', ventureId = 'v' },
				},
			},
		},
	}
	local facts = factsWith(db)
	local cancel = itemById('ah.cancel')
	t.eq(judgeAll(cancel, facts, { signal('HOOK:CancelAuction', NOW, 1), signal('TICK', NOW + 4) }).state, 'pass')
	t.eq(judgeAll(cancel, facts, { signal('HOOK:CancelAuction', NOW, 2), signal('TICK', NOW + 4) }).state, 'fail')
	local untracked = itemById('ah.untracked')
	t.eq(
		judgeAll(untracked, facts, { signal('HOOK:CancelAuction', NOW, 2), signal('HOOK:CancelAuction', NOW, 4) }).state,
		'fail',
		'no server answer between'
	)
	t.eq(judgeAll(untracked, facts, { signal('HOOK:CancelAuction', NOW, 3) }).state, 'look', 'a venture auction')
	t.eq(
		judgeAll(untracked, facts, {
			signal('HOOK:CancelAuction', NOW, 2),
			signal('OWNED_AUCTIONS_UPDATED'),
			signal('HOOK:CancelAuction', NOW + 1, 4),
			signal('AUCTION_CANCELED'),
			signal('TICK', NOW + 5),
		}).state,
		'pass'
	)
end)

t.test('flips.buy: a live search from Flips that lands on Buy passes', function()
	local item = itemById('flips.buy')
	local db = { settings = { window = { lastTab = 'flips' } } }
	local facts = factsWith(db)
	local scratch = {}
	item.judge(facts, scratch, signal('TICK'))
	item.judge(facts, scratch, signal('HOOK:SendSearchQuery', NOW))
	db.settings.window.lastTab = 'buy'
	t.eq(item.judge(facts, scratch, signal('TICK')).state, 'pass')
end)

t.test('session.ahvisit: closing the AH sets the AH-visit start', function()
	local item = itemById('session.ahvisit')
	t.eq(
		item.judge(factsWith({ sessions = { [CHAR] = { ahLeftAt = NOW } } }), {}, signal('AUCTION_HOUSE_CLOSED', NOW)).state,
		'pass'
	)
	t.eq(
		item.judge(
			factsWith({ sessions = { [CHAR] = { ahLeftAt = NOW - 999 } } }),
			{},
			signal('AUCTION_HOUSE_CLOSED', NOW)
		).state,
		'fail'
	)
end)

t.test('focus.combat: no key stays overridden to Haggler after combat', function()
	local item = itemById('focus.combat')
	local held = { UP = true }
	local facts = factsWith({}, {
		bindingAction = function(key)
			return held[key] and 'CLICK HagglerInputButton1:LeftButton' or nil
		end,
	})
	local scratch = {}
	item.judge(facts, scratch, signal('PLAYER_REGEN_DISABLED'))
	t.eq(item.judge(facts, scratch, signal('PLAYER_REGEN_ENABLED')).state, 'fail', 'still held')
	held = {}
	t.eq(item.judge(facts, scratch, signal('PLAYER_REGEN_ENABLED')).state, 'pass')
end)

t.test('focus.bind and feed.objects: the bound key and the feed texts', function()
	local db = { settings = { topbar = { focusKey = 'CTRL-SHIFT-H' } } }
	local bound = itemById('focus.bind')
	local facts = factsWith(db, {
		bindingAction = function()
			return 'CLICK HagglerInputButton1:LeftButton'
		end,
	})
	t.eq(bound.judge(facts, {}, signal('TICK')).state, 'pass')
	local feed = itemById('feed.objects')
	local texts = { ['Haggler: Gold'] = '12g', ['Haggler: Rule'] = 'Fast', ['Haggler: Scan'] = '2m' }
	local feedFacts = factsWith(db, {
		ldbText = function(name)
			return true, texts[name] or ''
		end,
	})
	t.eq(feed.judge(feedFacts, {}, signal('TICK')).state, 'pass')
	db.settings.topbar.feed = false
	local scratch = {}
	t.eq(
		judgeAll(feed, feedFacts, { signal('TICK'), signal('TICK'), signal('TICK') }, scratch).state,
		'fail',
		'still filled with the feed off'
	)
end)

-- Observer and checker ---------------------------------------------------------------------

local function fakeClient()
	local client = { clock = 0, frames = {}, hooks = {}, HagglerDB = { markets = {} } }
	function client.GetTime()
		return client.clock
	end
	function client.GetServerTime()
		return NOW + math.floor(client.clock)
	end
	client.time = client.GetServerTime
	function client.CreateFrame()
		local frame = { events = {}, scripts = {} }
		function frame.RegisterEvent(self, name)
			self.events[name] = true
		end
		function frame.SetScript(self, name, fn)
			self.scripts[name] = fn
		end
		client.frames[#client.frames + 1] = frame
		return frame
	end
	function client.hooksecurefunc(owner, name, hook)
		local original = owner[name]
		owner[name] = function(...)
			local results = { original(...) }
			hook(...)
			return unpack(results)
		end
	end
	function client.GetInboxInvoiceInfo(index)
		return index == 1 and 'seller' or 'buyer'
	end
	function client.GetInboxNumItems()
		return 3
	end
	client.TakeInboxMoney = function() end
	client.C_AuctionHouse = { CancelAuction = function() end }
	function client.advance(seconds)
		client.clock = client.clock + seconds
		client.frames[1].scripts.OnUpdate(client.frames[1], seconds)
	end
	function client.fire(event, ...)
		client.frames[1].scripts.OnEvent(client.frames[1], event, ...)
	end
	return client
end

t.test('the observer delivers events and hooks late and in order, ledger rows before the tick', function()
	local client = fakeClient()
	local heard = {}
	local observer = ns.Observer.create(client, function(each)
		heard[#heard + 1] = each
	end)
	client.HagglerDB.markets[MARKET] = { ledger = { { NOW, 'sale', 5, 1, 100 } } }
	observer:Start({ 'HOOK:TakeInboxMoney', 'HOOK:CancelAuction', 'MAIL_SHOW', 'LEDGER', 'TICK' })
	t.truthy(client.frames[1].events.MAIL_SHOW, 'item event registered')
	client.fire('PLAYER_ENTERING_WORLD', false, true)
	client.fire('MAIL_SHOW')
	client.TakeInboxMoney(1)
	client.C_AuctionHouse.CancelAuction(42)
	t.eq(#heard, 0, 'nothing before the delay')
	client.advance(0.6)
	t.same(
		{ heard[1].name, heard[2].name, heard[3].name },
		{ 'PLAYER_ENTERING_WORLD', 'MAIL_SHOW', 'HOOK:TakeInboxMoney' }
	)
	t.eq(heard[3].args.invoiceType, 'seller', 'invoice read at the take')
	t.eq(heard[4].args[1], 42)
	client.advance(0.6)
	t.eq(heard[5].name, 'LOAD')
	t.same(heard[5].args, { false, true })
	t.eq(heard[6].name, 'TICK', 'the first read sets the cursors: rows from before are not new')

	client.HagglerDB.markets[MARKET].ledger[2] = { NOW, 'cut', 5, 1, 5 }
	heard = {}
	client.advance(1)
	t.eq(heard[1].name, 'LEDGER')
	t.eq(heard[1].args[1][1].kind, 'cut')
	t.eq(heard[2].name, 'TICK')
	client.HagglerDB.markets[MARKET].ledger = { { NOW, 'fold', 0, 0, 0 } }
	heard = {}
	client.advance(1)
	t.eq(heard[1].name, 'TICK', 'a compacted ledger restarts at its end')

	heard = {}
	client.fire('PLAYER_LOGOUT')
	t.eq(heard[1].name, 'LOGOUT', 'logout is delivered at once')
end)

t.test('the checker records verdicts, skips answered once items and survives a judge error', function()
	local client = fakeClient()
	local db = {}
	local checker = ns.Check.create(client, db, { version = '0.2.0', build = '1.15.8.1', charKey = CHAR })
	checker.api = fakeApi()
	client.HagglerDB = { version = 2, defaultRuleId = 'r1' }
	checker:Deliver(signal('LOAD', NOW, true, false))
	t.eq(Suite.resultOf(db, checker.run, itemById('load.clean')).state, 'pass')
	t.eq(Suite.resultOf(db, checker.run, itemById('client.error-hook')).state, 'pass')
	t.truthy(db.once['client.error-hook'], 'once answer stored')

	checker.api = fakeApi({
		hasLdb = function()
			error('boom')
		end,
	})
	checker:Deliver(signal('TICK'))
	local feed = Suite.resultOf(db, checker.run, itemById('feed.objects'))
	t.eq(feed.state, 'look')
	t.truthy(feed.evidence[1]:find('judge error', 1, true), 'judge error shown')

	local heard = {}
	checker:OnRecord(function(item)
		heard[#heard + 1] = item and item.id or 'reset'
	end)
	checker:Model().setVerdict(itemById('window.tabs'), 'pass')
	t.same(heard, { 'window.tabs' })
	checker:Reset()
	t.eq(Suite.resultOf(db, checker.run, itemById('window.tabs')), nil, 'fresh run')
	t.eq(db.once['client.error-hook'], nil, 'once answers cleared')
end)
