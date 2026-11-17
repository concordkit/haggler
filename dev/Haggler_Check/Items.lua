--[[
	Items: Haggler's in-game check suite, in the order a run walks it (town, mailbox, auction
	house, then the fight items). The steps 4–6 checklist (handover, "Combined in-game checklist")
	is mapped item by item in dev/Haggler_Check/README.md; what a spec proves is not here.

	Judges read Haggler's saved tables (HagglerDB, HagglerCharDB) and what Observer.lua saw; they
	never call into Haggler. Pure: client reads go through facts.api, so the spec runs them.

	  facts  = { db, charDb, charKey, now, run, api }
	  signal = { name, args, at }   a client event, 'HOOK:<function>', or one of the observer's
	           LOAD (args: isInitialLogin, isReload), LOGOUT, TICK (every second), LEDGER (args:
	           events, the ledger rows booked since the last tick) and LUA_ERROR (args: message)
	  api    = isHagglerLoaded() · hagglerVersion() · hasErrorHook() · frameShown(name) ->
	           boolean|nil · framePoint(name) -> point, relativePoint, x, y · bindingAction(key)
	           · hasLdb() · ldbText(name) -> exists, text · freeBagSlots() · inboxCount()
	           · isInCombat()
]]
local _, ns = ...

local LEDGER_FIELDS = { 't', 'kind', 'itemId', 'qty', 'copper', 'char', 'ventureId', 'auctionId', 'flags' }
local FEED_NAMES = { 'Haggler', 'Haggler: Gold', 'Haggler: Rule', 'Haggler: Scan' }
local FOCUS_BUTTON_PATTERN = '^CLICK HagglerInputButton'
-- Keys the focus takes while the bar has it: the d-pad, the arrows, Enter and Escape.
local FOCUS_KEYS = {
	'UP',
	'DOWN',
	'LEFT',
	'RIGHT',
	'ENTER',
	'ESCAPE',
	'PADDUP',
	'PADDDOWN',
	'PADDLEFT',
	'PADDRIGHT',
	'PAD1',
	'PAD2',
}
local SETTLE_SECONDS = 3
local MISMATCH_TICKS = 3
local POSITION_TOLERANCE = 0.5

-- Helpers live at the bottom of the file; declared here so they stay local.
local pass, fail, look, setting, eachMarket, trackedAuction, sessionOf, copySession, sameSession
local ledgerTails, newestScanAt, countKinds, focusOverrides, postUnitPrice, isSamePosition, add
local snapshotLogout, isOnSameCharacter

local Items = {}
ns.Items = Items

--- Turns a saved ledger tuple into a keyed event (Engine/Ledger.lua's layout).
--- @param tuple table { t, kind, itemId, qty, copper, char, ventureId, auctionId, flags }
--- @return table event
function Items.decodeLedgerRow(tuple)
	local event = {}
	for index, field in ipairs(LEDGER_FIELDS) do
		event[field] = tuple[index]
	end
	return event
end

Items.list = {
	-- Town -------------------------------------------------------------------------------------
	{
		id = 'load.clean',
		title = 'Haggler loads clean',
		kind = 'auto',
		prompt = '',
		zone = 'safe',
		place = 'town',
		on = { 'LOAD', 'ADDON_ACTION_BLOCKED', 'ADDON_ACTION_FORBIDDEN', 'LUA_ERROR' },
		judge = function(facts, _, signal)
			if signal.name == 'LOAD' then
				if not facts.api.isHagglerLoaded() then
					return fail({ 'Haggler is not loaded' })
				end
				if type(facts.db.version) ~= 'number' then
					return fail({ 'HagglerDB has no schema version: the store did not open' })
				end
				return pass({
					'Haggler ' .. tostring(facts.api.hagglerVersion()) .. ', HagglerDB schema ' .. facts.db.version,
					'errors raised before Haggler_Check loaded show only in the client error frame',
				})
			end
			if signal.name == 'LUA_ERROR' then
				local message = tostring(signal.args[1] or '')
				if message:find('Haggler', 1, true) and not message:find('Haggler_Check', 1, true) then
					return fail({ 'Lua error: ' .. message })
				end
				return nil
			end
			if signal.args[1] == 'Haggler' then
				return fail({ signal.name .. ': ' .. tostring(signal.args[2]) })
			end
			return nil
		end,
	},
	{
		id = 'client.error-hook',
		title = 'Lua errors can be heard',
		kind = 'auto',
		prompt = '',
		zone = 'safe',
		place = 'town',
		once = true,
		on = { 'LOAD' },
		judge = function(facts)
			if facts.api.hasErrorHook() then
				return pass({ 'ScriptErrorsFrame is hooked; Haggler errors fail load.clean' })
			end
			return look({ 'ScriptErrorsFrame is not loaded: turn on Lua errors and watch for Haggler ones' })
		end,
	},
	{
		id = 'window.tabs',
		title = 'Window tabs',
		kind = 'look',
		prompt = '/hag: the window shows Scan, Lookup, Rules, Sell, Auctions, Flips, Buy, Ledger and Ventures.',
		zone = 'safe',
		place = 'town',
	},
	{
		id = 'bar.look',
		title = 'Top bar widgets',
		kind = 'look',
		prompt = 'The bar shows gold and session profit (tooltip: mode and any fallback note), the rule, the scan status and the shortcuts.',
		zone = 'safe',
		place = 'town',
	},
	{
		id = 'bar.position',
		title = 'Top bar keeps its place',
		kind = 'action',
		prompt = 'Drag the top bar to a new place, then /reload.',
		zone = 'safe',
		place = 'town',
		on = { 'LOAD', 'LOGOUT' },
		judge = function(facts, scratch, signal)
			local saved = type(facts.charDb.ui) == 'table' and facts.charDb.ui.topBar or nil
			if signal.name == 'LOGOUT' then
				scratch.isMoved = not isSamePosition(scratch.loadPosition, saved)
				scratch.logoutPosition = saved and { saved.point, saved.relativePoint, saved.x, saved.y } or nil
				return nil
			end
			local wasMoved, expected = scratch.isMoved, scratch.logoutPosition
			scratch.loadPosition = saved
					and { point = saved.point, relativePoint = saved.relativePoint, x = saved.x, y = saved.y }
				or nil
			scratch.isMoved = nil
			if not wasMoved or not expected then
				return nil
			end
			local point, relativePoint, x, y = facts.api.framePoint('HagglerTopBar')
			if not point then
				return look({ 'HagglerTopBar is not built (visibility hidden or market away from one)' })
			end
			local shown = string.format('%s %s %.1f %.1f', point, tostring(relativePoint), x, y)
			local wanted =
				string.format('%s %s %.1f %.1f', expected[1], tostring(expected[2]), expected[3], expected[4])
			if
				point == expected[1]
				and math.abs(x - expected[3]) <= POSITION_TOLERANCE
				and math.abs(y - expected[4]) <= POSITION_TOLERANCE
			then
				return pass({ 'after the reload the bar sits where it was dragged: ' .. shown })
			end
			return fail({ 'saved at logout: ' .. wanted, 'placed after the reload: ' .. shown })
		end,
	},
	{
		id = 'bar.visibility',
		title = 'Top bar visibility',
		kind = 'action',
		prompt = "Options: bar visibility 'market'; open a vendor or mailbox and close it; then set 'hidden'.",
		zone = 'safe',
		place = 'town',
		on = {
			'MERCHANT_SHOW',
			'MERCHANT_CLOSED',
			'MAIL_SHOW',
			'MAIL_CLOSED',
			'AUCTION_HOUSE_SHOW',
			'AUCTION_HOUSE_CLOSED',
			'TICK',
		},
		judge = function(facts, scratch, signal)
			local visibility = setting(facts.db, 'topbar', 'visibility', 'always')
			local isShown = facts.api.frameShown('HagglerTopBar') == true
			if signal.name == 'TICK' then
				if visibility ~= 'hidden' then
					scratch.hiddenShownTicks = 0
					return nil
				end
				if not isShown then
					scratch.sawHidden = true
				else
					scratch.hiddenShownTicks = (scratch.hiddenShownTicks or 0) + 1
					if scratch.hiddenShownTicks >= MISMATCH_TICKS then
						return fail({ "visibility 'hidden' but the bar shows" })
					end
				end
			elseif visibility == 'market' then
				local isArrival = signal.name:find('_SHOW$') ~= nil
				if isArrival and not isShown then
					return fail({ "visibility 'market': the bar is not shown after " .. signal.name })
				end
				if not isArrival and isShown then
					return fail({ "visibility 'market': the bar still shows after " .. signal.name })
				end
				scratch.sawArrival = scratch.sawArrival or isArrival
				scratch.sawLeaving = scratch.sawLeaving or not isArrival
			end
			if scratch.sawArrival and scratch.sawLeaving and scratch.sawHidden then
				return pass({ "'market': shown at a vendor, mailbox or AH, gone after", "'hidden': not shown" })
			end
			return nil
		end,
	},
	{
		id = 'bar.rule',
		title = 'Rule widget cycles the default rule',
		kind = 'action',
		prompt = 'Click the rule on the top bar twice.',
		zone = 'safe',
		place = 'town',
		on = { 'TICK' },
		judge = function(facts, scratch)
			local current = facts.db.defaultRuleId
			if scratch.lastRuleId == nil then
				scratch.lastRuleId = current
				return nil
			end
			if current == scratch.lastRuleId then
				return nil
			end
			scratch.changes = scratch.changes or {}
			scratch.changes[#scratch.changes + 1] = tostring(scratch.lastRuleId) .. ' -> ' .. tostring(current)
			scratch.lastRuleId = current
			if #scratch.changes >= 2 then
				return pass(scratch.changes)
			end
			return nil
		end,
	},
	{
		id = 'bar.rule-prices',
		title = 'Prices follow the rule',
		kind = 'look',
		prompt = 'After a rule click, the Sell and Lookup prices follow the new rule.',
		zone = 'safe',
		place = 'town',
	},
	{
		id = 'bar.shortcuts',
		title = 'Shortcuts open their places',
		kind = 'action',
		prompt = 'Use the bar shortcuts: Sell, Flips and settings.',
		zone = 'safe',
		place = 'town',
		on = { 'TICK' },
		judge = function(facts, scratch)
			scratch.tabs = scratch.tabs or {}
			if facts.api.frameShown('HagglerFrame') then
				scratch.tabs[tostring(setting(facts.db, 'window', 'lastTab', '?'))] = true
			end
			if facts.api.frameShown('HagglerOptionsPanel') then
				scratch.isSettingsSeen = true
			end
			if scratch.tabs.sell and scratch.tabs.flips and scratch.isSettingsSeen then
				return pass({ 'window seen on Sell and Flips; the Haggler options panel shown' })
			end
			return nil
		end,
	},
	{
		id = 'focus.bind',
		title = 'Focus key is bound',
		kind = 'action',
		prompt = "Options: set 'Focus the top bar' to a key (a pad shoulder or CTRL-SHIFT-H).",
		zone = 'safe',
		place = 'town',
		on = { 'TICK' },
		judge = function(facts, scratch)
			local key = setting(facts.db, 'topbar', 'focusKey', '')
			if key == '' or facts.api.isInCombat() then
				scratch.mismatchTicks = 0
				return nil
			end
			local action = facts.api.bindingAction(key) or ''
			if action:find(FOCUS_BUTTON_PATTERN) then
				return pass({ key .. ' -> ' .. action })
			end
			scratch.mismatchTicks = (scratch.mismatchTicks or 0) + 1
			if scratch.mismatchTicks >= MISMATCH_TICKS then
				return fail({ key .. ' is bound to ' .. (action == '' and 'nothing' or action) })
			end
			return nil
		end,
	},
	{
		id = 'client.override-query',
		title = 'Override bindings are readable',
		kind = 'auto',
		prompt = '',
		zone = 'safe',
		place = 'town',
		once = true,
		on = { 'TICK' },
		judge = function(facts, scratch)
			local key = setting(facts.db, 'topbar', 'focusKey', '')
			if key == '' or facts.api.isInCombat() then
				return nil
			end
			local action = facts.api.bindingAction(key)
			if action and action:find(FOCUS_BUTTON_PATTERN) then
				return pass({ 'GetBindingAction(key, true) reports override bindings' })
			end
			scratch.ticks = (scratch.ticks or 0) + 1
			if scratch.ticks >= 10 then
				return look({ 'GetBindingAction(key, true) does not show the focus override; focus checks need a look' })
			end
			return nil
		end,
	},
	{
		id = 'focus.pad',
		title = 'Pad focus moves and leaves',
		kind = 'look',
		prompt = 'Press the focus key: the d-pad moves between widgets, A presses one, B leaves; the d-pad then works as before.',
		zone = 'safe',
		place = 'town',
	},
	{
		id = 'feed.objects',
		title = 'Broker feed objects',
		kind = 'auto',
		prompt = '',
		zone = 'safe',
		place = 'town',
		on = { 'LOAD', 'TICK' },
		judge = function(facts, scratch)
			if not facts.api.hasLdb() then
				return look({ 'LibDataBroker is not loaded' })
			end
			local texts, missing = {}, {}
			for _, name in ipairs(FEED_NAMES) do
				local exists, text = facts.api.ldbText(name)
				if not exists then
					missing[#missing + 1] = name
				end
				texts[name] = text
			end
			if #missing > 0 then
				return fail({ 'missing LDB objects: ' .. table.concat(missing, ', ') })
			end
			local isFeedOn = setting(facts.db, 'topbar', 'feed', true) ~= false
			local goldText = texts['Haggler: Gold'] or ''
			if isFeedOn then
				scratch.offTicks = 0
				return goldText ~= '' and pass({ 'feed on; gold reads ' .. goldText }) or nil
			end
			local isBlank = goldText == ''
				and (texts['Haggler: Rule'] or '') == ''
				and (texts['Haggler: Scan'] or '') == ''
			scratch.offTicks = isBlank and 0 or (scratch.offTicks or 0) + 1
			if scratch.offTicks >= MISMATCH_TICKS then
				return fail({ 'feed off but the texts still read: ' .. goldText })
			end
			return nil
		end,
	},
	{
		id = 'feed.display',
		title = 'Broker display',
		kind = 'look',
		prompt = 'In an LDB display (Titan Panel or similar): gold, rule and scan show; the launcher opens the window; feed off blanks them. None installed: N/A.',
		zone = 'safe',
		place = 'town',
	},
	{
		id = 'session.reload',
		title = 'Session survives /reload',
		kind = 'action',
		prompt = '/reload.',
		zone = 'safe',
		place = 'town',
		on = { 'LOAD', 'LOGOUT' },
		judge = function(facts, scratch, signal)
			if signal.name == 'LOGOUT' then
				snapshotLogout(facts, scratch)
				return nil
			end
			local saved = scratch.saved
			scratch.saved = nil
			if not signal.args[2] or not isOnSameCharacter(facts, saved) then
				return nil
			end
			local now = copySession(facts)
			if sameSession(saved, now) then
				return pass({ 'mode ' .. tostring(now.mode) .. ', login, reset and AH-visit starts kept' })
			end
			return fail({ 'before: ' .. tostring(saved.text), 'after: ' .. tostring(now.text) })
		end,
	},
	{
		id = 'persist.data',
		title = 'Ledger, ventures and pools persist',
		kind = 'auto',
		prompt = '',
		zone = 'safe',
		place = 'town',
		on = { 'LOAD', 'LOGOUT' },
		judge = function(facts, scratch, signal)
			if signal.name == 'LOGOUT' then
				scratch.tails = ledgerTails(facts.db)
				return nil
			end
			local before = scratch.tails
			scratch.tails = nil
			if type(before) ~= 'table' then
				return nil
			end
			local after, lost = ledgerTails(facts.db), {}
			for marketKey, tail in pairs(before) do
				local now = after[marketKey]
				if
					not now
					or now.ledgerTail ~= tail.ledgerTail
					or now.ventures < tail.ventures
					or now.pools < tail.pools
				then
					lost[#lost + 1] = marketKey
				end
			end
			if #lost > 0 then
				return fail({ 'changed across the reload: ' .. table.concat(lost, ', ') })
			end
			return pass({ 'the last ledger row, venture and pool counts are unchanged after the reload' })
		end,
	},
	{
		id = 'session.relog',
		title = 'Since login restarts on a relog',
		kind = 'action',
		prompt = 'Log out to the character list, then log back in.',
		zone = 'safe',
		place = 'town',
		on = { 'LOAD', 'LOGOUT' },
		judge = function(facts, scratch, signal)
			if signal.name == 'LOGOUT' then
				snapshotLogout(facts, scratch)
				return nil
			end
			local saved = scratch.saved
			scratch.saved = nil
			if not signal.args[1] or not isOnSameCharacter(facts, saved) then
				return nil
			end
			local now = copySession(facts)
			if now.mode ~= saved.mode then
				return fail({
					'mode changed across the relog: ' .. tostring(saved.mode) .. ' -> ' .. tostring(now.mode),
				})
			end
			if type(now.loginAt) == 'number' and now.loginAt >= (saved.at or 0) then
				return pass({ 'login start moved from ' .. tostring(saved.loginAt) .. ' to ' .. now.loginAt })
			end
			return fail({ 'login start did not move: ' .. tostring(now.loginAt) })
		end,
	},
	{
		id = 'craft.look',
		title = 'Profession window figures',
		kind = 'look',
		prompt = 'Profession window: rows show +x · y% (? when low); a recipe shows Cost, Value, Profit, Known share and the AHledger credit; paid valuation changes them.',
		zone = 'safe',
		place = 'town',
	},
	{
		id = 'venture.plan',
		title = 'Planning twice makes one venture',
		kind = 'action',
		prompt = 'Profession window: plan a venture twice on one recipe.',
		zone = 'safe',
		place = 'town',
		on = { 'TICK' },
		judge = function(facts)
			local startedAt = facts.run.startedAt or 0
			local byRecipe = {}
			for _, market in eachMarket(facts.db) do
				for id, venture in pairs(type(market.ventures) == 'table' and market.ventures or {}) do
					if type(venture) == 'table' and (venture.createdAt or 0) >= startedAt then
						for _, line in ipairs(type(venture.lines) == 'table' and venture.lines or {}) do
							if (line.plannedCrafts or 0) >= 2 then
								return pass({
									'venture '
										.. tostring(id)
										.. ' plans '
										.. line.plannedCrafts
										.. ' crafts of recipe '
										.. tostring(line.recipeId),
								})
							end
							byRecipe[line.recipeId] = (byRecipe[line.recipeId] or 0) + 1
						end
					end
				end
			end
			for recipeId, count in pairs(byRecipe) do
				if count >= 2 then
					return fail({
						count .. ' new ventures for recipe ' .. tostring(recipeId) .. ' instead of one with 2 crafts',
					})
				end
			end
			return nil
		end,
	},
	{
		id = 'venture.look',
		title = 'Ventures tab',
		kind = 'look',
		prompt = 'Ventures tab: the forecast confidence shows; ± crafts works; close one to stock or write off.',
		zone = 'safe',
		place = 'town',
	},
	{
		id = 'craft.book',
		title = 'A craft is booked once',
		kind = 'action',
		prompt = 'Craft once (a venture recipe if you have one).',
		zone = 'safe',
		place = 'town',
		on = { 'HOOK:CraftRecipe', 'UNIT_SPELLCAST_SUCCEEDED', 'LEDGER', 'TICK' },
		judge = function(_, scratch, signal)
			if signal.name == 'HOOK:CraftRecipe' then
				scratch.spellId, scratch.expected = signal.args[1], tonumber(signal.args[2]) or 1
			elseif signal.name == 'UNIT_SPELLCAST_SUCCEEDED' then
				if signal.args[1] == 'player' and (scratch.expected or 0) > 0 and signal.args[3] == scratch.spellId then
					scratch.expected = scratch.expected - 1
					scratch.casts, scratch.lastCastAt = (scratch.casts or 0) + 1, signal.at
				end
			elseif signal.name == 'LEDGER' then
				scratch.crafts = (scratch.crafts or 0) + countKinds(signal.args[1], { craft = true })
			elseif (scratch.casts or 0) > 0 and signal.at - (scratch.lastCastAt or 0) >= SETTLE_SECONDS then
				local casts, crafts = scratch.casts, scratch.crafts or 0
				scratch.casts, scratch.crafts = 0, 0
				local evidence = { casts .. ' cast(s), ' .. crafts .. ' craft row(s) booked' }
				return crafts == casts and pass(evidence) or fail(evidence)
			end
			return nil
		end,
	},
	{
		id = 'vendor.book',
		title = 'Vendor buy and sell are booked',
		kind = 'action',
		prompt = 'At a vendor: buy one item, sell one, close the vendor.',
		zone = 'safe',
		place = 'town',
		on = { 'MERCHANT_SHOW', 'HOOK:BuyMerchantItem', 'LEDGER', 'MERCHANT_CLOSED' },
		judge = function(_, scratch, signal)
			if signal.name == 'MERCHANT_SHOW' then
				scratch.buys, scratch.vendorBuys, scratch.vendorSells = 0, 0, 0
				return nil
			end
			scratch.buys = scratch.buys or 0
			if signal.name == 'HOOK:BuyMerchantItem' then
				scratch.buys = scratch.buys + 1
				return nil
			end
			if signal.name == 'LEDGER' then
				scratch.vendorBuys = (scratch.vendorBuys or 0) + countKinds(signal.args[1], { vendorBuy = true })
				scratch.vendorSells = (scratch.vendorSells or 0) + countKinds(signal.args[1], { vendorSell = true })
				if scratch.vendorBuys > scratch.buys then
					return fail({ scratch.vendorBuys .. ' vendor buys booked for ' .. scratch.buys .. ' buy call(s)' })
				end
				return nil
			end
			local evidence = {
				(scratch.buys or 0)
					.. ' buy call(s), '
					.. (scratch.vendorBuys or 0)
					.. ' vendorBuy, '
					.. (scratch.vendorSells or 0)
					.. ' vendorSell',
			}
			if (scratch.vendorBuys or 0) >= 1 and (scratch.vendorSells or 0) >= 1 then
				return pass(evidence)
			end
			return nil
		end,
	},
	{
		id = 'bags.destroy',
		title = 'A destroy is booked for the deleted item only',
		kind = 'action',
		prompt = 'Pick an item up and put it back; then destroy another item.',
		zone = 'safe',
		place = 'town',
		on = { 'HOOK:DeleteCursorItem', 'LEDGER', 'TICK' },
		judge = function(_, scratch, signal)
			scratch.deletes, scratch.destroys = scratch.deletes or {}, scratch.destroys or {}
			if signal.name == 'HOOK:DeleteCursorItem' then
				scratch.deletes[#scratch.deletes + 1] = { itemId = signal.args.itemId, at = signal.at }
				return nil
			end
			if signal.name == 'LEDGER' then
				for _, event in ipairs(signal.args[1]) do
					if event.kind == 'destroy' then
						scratch.destroys[#scratch.destroys + 1] = { itemId = event.itemId, at = signal.at }
					end
				end
				return nil
			end
			local newest = math.max(
				(scratch.deletes[#scratch.deletes] or { at = 0 }).at,
				(scratch.destroys[#scratch.destroys] or { at = 0 }).at
			)
			if (#scratch.deletes == 0 and #scratch.destroys == 0) or signal.at - newest < SETTLE_SECONDS then
				return nil
			end
			local deletes, destroys = scratch.deletes, scratch.destroys
			scratch.deletes, scratch.destroys = {}, {}
			local evidence = {}
			for index = 1, math.max(#deletes, #destroys) do
				local deleted, destroyed = deletes[index], destroys[index]
				evidence[#evidence + 1] = 'deleted '
					.. tostring(deleted and deleted.itemId)
					.. ', booked '
					.. tostring(destroyed and destroyed.itemId)
				if not deleted or not destroyed or deleted.itemId ~= destroyed.itemId then
					return fail(evidence)
				end
			end
			return pass(evidence)
		end,
	},
	-- Mailbox ----------------------------------------------------------------------------------
	{
		id = 'mail.take',
		title = 'Sold, expired and won mail are booked once',
		kind = 'action',
		prompt = 'Mailbox: take a sold, an expired and a won auction mail.',
		zone = 'safe',
		place = 'mailbox',
		on = { 'MAIL_SHOW', 'HOOK:TakeInboxMoney', 'LEDGER', 'MAIL_CLOSED' },
		judge = function(_, scratch, signal)
			if signal.name == 'MAIL_SHOW' then
				scratch.isOpen, scratch.sellerTakes = true, 0
				return nil
			end
			if signal.name == 'MAIL_CLOSED' then
				scratch.isOpen = false
				return nil
			end
			if signal.name == 'HOOK:TakeInboxMoney' then
				if signal.args.invoiceType == 'seller' then
					scratch.sellerTakes = (scratch.sellerTakes or 0) + 1
				end
				return nil
			end
			if not scratch.isOpen then
				return nil
			end
			scratch.sales = (scratch.sales or 0) + countKinds(signal.args[1], { sale = true })
			scratch.expires = (scratch.expires or 0) + countKinds(signal.args[1], { expire = true, cancel = true })
			scratch.wins = (scratch.wins or 0) + countKinds(signal.args[1], { buy = true })
			local evidence = {
				scratch.sales .. ' sale row(s) for ' .. (scratch.sellerTakes or 0) .. ' sale-gold take(s)',
				scratch.expires .. ' return row(s), ' .. scratch.wins .. ' won row(s)',
			}
			if scratch.sales > (scratch.sellerTakes or 0) then
				return fail(evidence)
			end
			if scratch.sales >= 1 and scratch.expires >= 1 and scratch.wins >= 1 then
				return pass(evidence)
			end
			return nil
		end,
	},
	{
		id = 'mail.fullbags',
		title = 'A failed take is not booked',
		kind = 'action',
		prompt = 'Bags full: take a won item and close the mailbox at once; free a slot, reopen and take it.',
		zone = 'safe',
		place = 'mailbox',
		on = { 'HOOK:TakeInboxItem', 'HOOK:AutoLootMailItem', 'LEDGER', 'MAIL_CLOSED' },
		judge = function(_, scratch, signal)
			if signal.name == 'HOOK:TakeInboxItem' or signal.name == 'HOOK:AutoLootMailItem' then
				if signal.args.invoiceType ~= 'buyer' then
					return nil
				end
				if (signal.args.freeSlots or 1) == 0 then
					scratch.fullTakeAt, scratch.booksAfterFullTake = signal.at, 0
				elseif scratch.isCleanClose then
					scratch.retakes = (scratch.retakes or 0) + 1
				end
				return nil
			end
			if signal.name == 'MAIL_CLOSED' then
				if scratch.fullTakeAt and not scratch.isCleanClose then
					if (scratch.booksAfterFullTake or 0) > 0 then
						return fail({ 'a won take that failed on full bags was booked' })
					end
					scratch.isCleanClose = true
				end
				return nil
			end
			local wins = countKinds(signal.args[1], { buy = true })
			if scratch.fullTakeAt and not scratch.isCleanClose then
				scratch.booksAfterFullTake = (scratch.booksAfterFullTake or 0) + wins
			elseif scratch.isCleanClose and (scratch.retakes or 0) > 0 then
				scratch.retakeBooks = (scratch.retakeBooks or 0) + wins
				local evidence = { scratch.retakes .. ' retake(s), ' .. scratch.retakeBooks .. ' won row(s) booked' }
				if scratch.retakeBooks > scratch.retakes then
					return fail(evidence)
				end
				if scratch.retakeBooks == scratch.retakes then
					return pass(evidence)
				end
			end
			return nil
		end,
	},
	{
		id = 'mail.newmail',
		title = 'New mail mid-take books the sale once',
		kind = 'action',
		prompt = "Have an alt send you a letter; take a sale's gold just as it lands.",
		zone = 'safe',
		place = 'mailbox',
		on = { 'HOOK:TakeInboxMoney', 'MAIL_INBOX_UPDATE', 'LEDGER', 'TICK' },
		judge = function(facts, scratch, signal)
			if signal.name == 'HOOK:TakeInboxMoney' then
				if signal.args.invoiceType == 'seller' then
					scratch.take =
						{ at = signal.at, inboxCount = signal.args.inboxCount or 0, sales = 0, isRaced = false }
				end
				return nil
			end
			local take = scratch.take
			if not take then
				return nil
			end
			if signal.name == 'MAIL_INBOX_UPDATE' then
				take.isRaced = take.isRaced or facts.api.inboxCount() > take.inboxCount
				return nil
			end
			if signal.name == 'LEDGER' then
				take.sales = take.sales + countKinds(signal.args[1], { sale = true })
				return nil
			end
			if signal.at - take.at < SETTLE_SECONDS then
				return nil
			end
			scratch.take = nil
			local evidence = { take.sales .. ' sale row(s) for one take; new mail arrived: ' .. tostring(take.isRaced) }
			if take.sales > 1 then
				return fail(evidence)
			end
			if take.isRaced then
				return take.sales == 1 and pass(evidence) or fail(evidence)
			end
			return nil
		end,
	},
	-- Auction house ----------------------------------------------------------------------------
	{
		id = 'ah.scan',
		title = 'A scan completes and is saved',
		kind = 'action',
		prompt = 'Auction house: run a scan.',
		zone = 'safe',
		place = 'auction house',
		on = { 'TICK' },
		judge = function(facts, scratch)
			local at, marketKey, scan = newestScanAt(facts.db)
			if scratch.firstAt == nil then
				scratch.firstAt = at or 0
				return nil
			end
			if at and at > scratch.firstAt then
				return pass({
					marketKey
						.. ': '
						.. tostring(scan.count)
						.. ' items from '
						.. tostring(scan.source)
						.. ' at '
						.. at,
				})
			end
			return nil
		end,
	},
	{
		id = 'ah.flows',
		title = 'Lookup, Sell and Buy',
		kind = 'look',
		prompt = 'Lookup, Sell and Buy work as before; the bar scan status updated after the scan.',
		zone = 'safe',
		place = 'auction house',
	},
	{
		id = 'flips.look',
		title = 'Flips tab',
		kind = 'look',
		prompt = 'Flips: Find lists vendor and relist flips; the AHledger credit shows on relist rows priced from AHledger.',
		zone = 'safe',
		place = 'auction house',
	},
	{
		id = 'flips.buy',
		title = 'Flips Buy hands over to Buy',
		kind = 'action',
		prompt = 'Flips: press Buy on a row.',
		zone = 'safe',
		place = 'auction house',
		on = { 'HOOK:SendSearchQuery', 'TICK' },
		judge = function(facts, scratch, signal)
			local tab = setting(facts.db, 'window', 'lastTab', '?')
			if signal.name == 'HOOK:SendSearchQuery' then
				if scratch.lastTab == 'flips' or tab == 'flips' or tab == 'buy' then
					scratch.searchAt = signal.at
				end
				return nil
			end
			local previous = scratch.lastTab
			scratch.lastTab = tab
			if scratch.searchAt and tab == 'buy' and (previous == 'flips' or scratch.wasOnFlips) then
				return pass({ 'Flips -> Buy with a live search at ' .. scratch.searchAt })
			end
			scratch.wasOnFlips = tab == 'flips' or (scratch.wasOnFlips and tab == 'buy')
			return nil
		end,
	},
	{
		id = 'auctions.look',
		title = 'Auctions tab',
		kind = 'look',
		prompt = "Auctions tab: this character's auctions, each with 'relist at X' or 'hold'.",
		zone = 'safe',
		place = 'auction house',
	},
	{
		id = 'ah.post',
		title = 'A post is tracked with its deposit',
		kind = 'action',
		prompt = 'Post an item.',
		zone = 'safe',
		place = 'auction house',
		on = { 'AUCTION_HOUSE_AUCTION_CREATED', 'LEDGER' },
		judge = function(facts, scratch, signal)
			if signal.name == 'AUCTION_HOUSE_AUCTION_CREATED' then
				scratch.auctionId = signal.args[1]
			elseif signal.name == 'LEDGER' and scratch.auctionId then
				for _, event in ipairs(signal.args[1]) do
					if event.auctionId == scratch.auctionId and event.kind == 'deposit' then
						scratch.depositCopper = event.copper
					end
				end
			end
			local record = scratch.auctionId and trackedAuction(facts.db, scratch.auctionId)
			if record and scratch.depositCopper then
				return pass({
					'auction ' .. scratch.auctionId .. ' tracked; deposit ' .. scratch.depositCopper .. 'c booked',
				})
			end
			return nil
		end,
	},
	{
		id = 'ah.twoposts',
		title = 'Two posts from one stack',
		kind = 'action',
		prompt = 'Post 5 from one stack, then 8 from the same stack at another price.',
		zone = 'safe',
		place = 'auction house',
		on = { 'AUCTION_HOUSE_AUCTION_CREATED' },
		judge = function(facts, scratch, signal)
			local record = trackedAuction(facts.db, signal.args[1])
			if not record then
				return nil
			end
			scratch.posts = scratch.posts or {}
			for _, earlier in ipairs(scratch.posts) do
				if
					earlier.itemId == record.itemId
					and earlier.unitPrice ~= record.unitPrice
					and signal.at - earlier.at <= 120
				then
					return pass({
						string.format('%d x %s at %dc', earlier.qty, tostring(earlier.itemId), earlier.unitPrice),
						string.format(
							'%d x %s at %dc',
							record.qty or 0,
							tostring(record.itemId),
							record.unitPrice or 0
						),
					})
				end
			end
			add(
				scratch.posts,
				{ itemId = record.itemId, unitPrice = record.unitPrice, qty = record.qty or 0, at = signal.at },
				6
			)
			return nil
		end,
	},
	{
		id = 'ah.undercut',
		title = 'A declined undercut books the second price',
		kind = 'action',
		prompt = 'Post under the market so the warning shows; decline; post again at another price.',
		zone = 'safe',
		place = 'auction house',
		on = { 'AUCTION_HOUSE_POST_WARNING', 'HOOK:PostItem', 'HOOK:PostCommodity', 'AUCTION_HOUSE_AUCTION_CREATED' },
		judge = function(facts, scratch, signal)
			if signal.name == 'AUCTION_HOUSE_POST_WARNING' then
				scratch.isWarned, scratch.postsAfterWarning = true, 0
				return nil
			end
			if signal.name == 'HOOK:PostItem' or signal.name == 'HOOK:PostCommodity' then
				scratch.lastUnitPrice = postUnitPrice(signal)
				if scratch.isWarned then
					scratch.postsAfterWarning = scratch.postsAfterWarning + 1
				end
				return nil
			end
			if not scratch.isWarned or (scratch.postsAfterWarning or 0) < 1 then
				return nil
			end
			local record = trackedAuction(facts.db, signal.args[1])
			if not record or not scratch.lastUnitPrice then
				return nil
			end
			scratch.isWarned = false
			local evidence =
				{ 'posted at ' .. scratch.lastUnitPrice .. 'c, tracked at ' .. tostring(record.unitPrice) .. 'c' }
			if math.abs((record.unitPrice or 0) - scratch.lastUnitPrice) <= 1 then
				return pass(evidence)
			end
			return fail(evidence)
		end,
	},
	{
		id = 'ah.cancel',
		title = 'Cancel to relist marks the auction',
		kind = 'action',
		prompt = 'Auctions tab: cancel one auction to relist (two clicks).',
		zone = 'safe',
		place = 'auction house',
		on = { 'HOOK:CancelAuction', 'TICK' },
		judge = function(facts, scratch, signal)
			if signal.name == 'HOOK:CancelAuction' then
				scratch.auctionId, scratch.at = signal.args[1], signal.at
				return nil
			end
			if not scratch.auctionId or signal.at - scratch.at < SETTLE_SECONDS then
				return nil
			end
			local auctionId = scratch.auctionId
			scratch.auctionId = nil
			local record = trackedAuction(facts.db, auctionId)
			if not record then
				return look({ 'auction ' .. tostring(auctionId) .. ' was not tracked (posted before Haggler?)' })
			end
			local evidence = {
				'auction ' .. tostring(auctionId) .. ' is ' .. tostring(record.state) .. '; deposit ' .. tostring(
					record.deposit
				) .. 'c stays lost',
			}
			return record.state == 'cancelled' and pass(evidence) or fail(evidence)
		end,
	},
	{
		id = 'ah.untracked',
		title = 'Cancel untracked waits for the server',
		kind = 'action',
		prompt = 'Post an item outside a venture; Auctions tab: arm Cancel untracked, then click until done.',
		zone = 'safe',
		place = 'auction house',
		on = { 'HOOK:CancelAuction', 'OWNED_AUCTIONS_UPDATED', 'AUCTION_CANCELED', 'TICK' },
		judge = function(facts, scratch, signal)
			if signal.name == 'OWNED_AUCTIONS_UPDATED' or signal.name == 'AUCTION_CANCELED' then
				scratch.isAwaiting = false
				return nil
			end
			if signal.name == 'HOOK:CancelAuction' then
				if scratch.isAwaiting then
					return fail({
						'cancel of ' .. tostring(signal.args[1]) .. ' sent before the server answered the last',
					})
				end
				local record = trackedAuction(facts.db, signal.args[1])
				if record and record.ventureId then
					return look({
						'venture auction '
							.. tostring(signal.args[1])
							.. ' cancelled: a relist by hand, or Cancel untracked?',
					})
				end
				scratch.isAwaiting, scratch.cancels, scratch.lastAt = true, (scratch.cancels or 0) + 1, signal.at
				return nil
			end
			if
				(scratch.cancels or 0) >= 2
				and not scratch.isAwaiting
				and signal.at - (scratch.lastAt or 0) >= SETTLE_SECONDS
			then
				return pass({
					scratch.cancels .. ' cancels, each after the server answered; no venture auction touched',
				})
			end
			return nil
		end,
	},
	{
		id = 'ah.commodity',
		title = 'A commodity buy is booked',
		kind = 'action',
		prompt = 'Buy a commodity, then take its mail.',
		zone = 'safe',
		place = 'auction house',
		on = { 'HOOK:ConfirmCommoditiesPurchase', 'LEDGER' },
		judge = function(_, scratch, signal)
			if signal.name == 'HOOK:ConfirmCommoditiesPurchase' then
				scratch.itemId = signal.args[1]
				return nil
			end
			if not scratch.itemId then
				return nil
			end
			for _, event in ipairs(signal.args[1]) do
				if event.kind == 'buy' and event.itemId == scratch.itemId then
					return pass({
						'buy of ' .. tostring(event.qty) .. ' x ' .. tostring(event.itemId) .. ' for ' .. tostring(
							event.copper
						) .. 'c',
					})
				end
			end
			return nil
		end,
	},
	{
		id = 'session.ahvisit',
		title = 'Closing the AH starts an AH-visit session',
		kind = 'action',
		prompt = 'Close the auction house.',
		zone = 'safe',
		place = 'auction house',
		on = { 'AUCTION_HOUSE_CLOSED' },
		judge = function(facts, _, signal)
			local session = sessionOf(facts)
			local ahLeftAt = session and session.ahLeftAt
			if type(ahLeftAt) == 'number' and math.abs(ahLeftAt - signal.at) <= SETTLE_SECONDS then
				return pass({ 'ahLeftAt ' .. ahLeftAt })
			end
			return fail({ 'ahLeftAt ' .. tostring(ahLeftAt) .. ', closed at ' .. signal.at })
		end,
	},
	-- Fight ------------------------------------------------------------------------------------
	{
		id = 'focus.combat',
		title = 'Combat ends the focus and frees the keys',
		kind = 'action',
		prompt = 'Focus the bar, then pull a training dummy; leave combat.',
		zone = 'fight',
		place = 'combat',
		on = { 'PLAYER_REGEN_DISABLED', 'PLAYER_REGEN_ENABLED' },
		judge = function(facts, scratch, signal)
			local overrides = focusOverrides(facts.api)
			if signal.name == 'PLAYER_REGEN_DISABLED' then
				scratch.wasFocused = scratch.wasFocused or #overrides > 0
				return nil
			end
			if not scratch.wasFocused then
				return nil
			end
			if #overrides > 0 then
				return fail({ 'still overridden after combat: ' .. table.concat(overrides, ', ') })
			end
			return pass({ 'the focus held keys at the pull; none overridden after combat' })
		end,
	},
	{
		id = 'focus.combat-bind',
		title = 'A focus key changed in combat applies after',
		kind = 'action',
		prompt = 'In combat, clear the focus key in options; leave combat.',
		zone = 'fight',
		place = 'combat',
		on = { 'PLAYER_REGEN_DISABLED', 'PLAYER_REGEN_ENABLED' },
		judge = function(facts, scratch, signal)
			local key = setting(facts.db, 'topbar', 'focusKey', '')
			if signal.name == 'PLAYER_REGEN_DISABLED' then
				scratch.keyAtPull = key
				return nil
			end
			local before = scratch.keyAtPull
			scratch.keyAtPull = nil
			if before == nil or before == key then
				return nil
			end
			local oldAction = before ~= '' and facts.api.bindingAction(before) or ''
			if (oldAction or ''):find(FOCUS_BUTTON_PATTERN) then
				return fail({ before .. ' still focuses the bar after combat' })
			end
			if key ~= '' and not (facts.api.bindingAction(key) or ''):find(FOCUS_BUTTON_PATTERN) then
				return fail({ 'the new key ' .. key .. ' does not focus the bar after combat' })
			end
			return pass({ "focus key '" .. before .. "' -> '" .. key .. "' applied after combat" })
		end,
	},
}

-- Helpers ---------------------------------------------------------------------------------

function pass(evidence)
	return { state = 'pass', evidence = evidence }
end

function fail(evidence)
	return { state = 'fail', evidence = evidence }
end

function look(evidence)
	return { state = 'look', evidence = evidence }
end

-- A stored setting (HagglerDB.settings[module][key]); unset reads as the schema default.
function setting(db, moduleKey, key, default)
	local values = type(db.settings) == 'table' and db.settings[moduleKey] or nil
	if type(values) ~= 'table' or values[key] == nil then
		return default
	end
	return values[key]
end

function eachMarket(db)
	return pairs(type(db.markets) == 'table' and db.markets or {})
end

function trackedAuction(db, auctionId)
	if auctionId == nil then
		return nil
	end
	for _, market in eachMarket(db) do
		local record = type(market) == 'table' and type(market.auctions) == 'table' and market.auctions[auctionId]
			or nil
		if type(record) == 'table' then
			return record
		end
	end
	return nil
end

function sessionOf(facts)
	local sessions = type(facts.db.sessions) == 'table' and facts.db.sessions or {}
	local session = facts.charKey and sessions[facts.charKey]
	return type(session) == 'table' and session or nil
end

function copySession(facts)
	local session = sessionOf(facts) or {}
	local copy = {
		charKey = facts.charKey,
		mode = setting(facts.db, 'sessions', 'mode', 'login'),
		loginAt = session.loginAt,
		resetAt = session.resetAt,
		ahLeftAt = session.ahLeftAt,
		at = facts.now,
	}
	copy.text = string.format(
		'mode %s, login %s, reset %s, AH %s',
		tostring(copy.mode),
		tostring(copy.loginAt),
		tostring(copy.resetAt),
		tostring(copy.ahLeftAt)
	)
	return copy
end

function sameSession(left, right)
	return left.mode == right.mode
		and left.loginAt == right.loginAt
		and left.resetAt == right.resetAt
		and left.ahLeftAt == right.ahLeftAt
end

function snapshotLogout(facts, scratch)
	scratch.saved = copySession(facts)
end

function isOnSameCharacter(facts, saved)
	return type(saved) == 'table' and saved.charKey ~= nil and saved.charKey == facts.charKey
end

-- Per market: the last ledger row as text, and the venture and cost-pool counts.
function ledgerTails(db)
	local tails = {}
	for marketKey, market in eachMarket(db) do
		if type(market) == 'table' then
			local ledger = type(market.ledger) == 'table' and market.ledger or {}
			local last = ledger[#ledger]
			local ventures, pools = 0, 0
			for _ in pairs(type(market.ventures) == 'table' and market.ventures or {}) do
				ventures = ventures + 1
			end
			for _ in pairs(type(market.costPools) == 'table' and market.costPools or {}) do
				pools = pools + 1
			end
			tails[marketKey] = {
				ledgerTail = type(last) == 'table'
						and table.concat({ tostring(last[1]), tostring(last[2]), tostring(last[5]) }, '/')
					or '',
				ventures = ventures,
				pools = pools,
			}
		end
	end
	return tails
end

function newestScanAt(db)
	local newestAt, newestKey, newestScan
	for marketKey, market in eachMarket(db) do
		local scan = type(market) == 'table' and market.scan or nil
		local at = type(scan) == 'table' and tonumber(scan.at) or nil
		if at and (not newestAt or at > newestAt) then
			newestAt, newestKey, newestScan = at, marketKey, scan
		end
	end
	return newestAt, newestKey, newestScan
end

function countKinds(events, kinds)
	local count = 0
	for _, event in ipairs(events or {}) do
		if kinds[event.kind] then
			count = count + 1
		end
	end
	return count
end

function focusOverrides(api)
	local held = {}
	for _, key in ipairs(FOCUS_KEYS) do
		local action = api.bindingAction(key)
		if action and action:find(FOCUS_BUTTON_PATTERN) then
			held[#held + 1] = key
		end
	end
	return held
end

-- PostCommodity(item, duration, quantity, unitPrice) · PostItem(item, duration, quantity, bid, buyout)
function postUnitPrice(signal)
	local quantity = tonumber(signal.args[3]) or 1
	if signal.name == 'HOOK:PostCommodity' then
		return tonumber(signal.args[4])
	end
	local buyout = tonumber(signal.args[5])
	return buyout and math.floor(buyout / math.max(quantity, 1)) or nil
end

function isSamePosition(left, right)
	if type(left) ~= 'table' or type(right) ~= 'table' then
		return left == right
	end
	return left.point == right.point
		and math.abs((left.x or 0) - (right.x or 0)) <= POSITION_TOLERANCE
		and math.abs((left.y or 0) - (right.y or 0)) <= POSITION_TOLERANCE
end

-- Appends and keeps the newest `limit` entries.
function add(list, entry, limit)
	list[#list + 1] = entry
	while #list > limit do
		table.remove(list, 1)
	end
end
