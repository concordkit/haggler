--[[
	Suite: runs, verdicts and progress for an item table in the shape of "In-game test suites"
	(Projects/Concord). Pure: no client calls, so tests/haggler_check_spec.lua runs it under luajit.

	  Item = { id, title, kind, prompt, zone, place, once?, on = { signal... }, judge? }
	    kind   auto (judges itself) · action (judges itself after the player acts) · look (the
	           player confirms in the panel)
	    zone   safe · fight; every safe item comes before the first fight item
	    judge  fun(facts, scratch, signal) -> Verdict|nil   nil: nothing to say yet
	  Verdict = { state = 'pass' | 'fail' | 'look' | 'na', evidence = { line... } }
	    na     the player marked a look item as not applicable (no LDB display, say)

	  Saved table (Haggler_CheckDB):
	    runs[runKey] = Run     runKey = '<add-on version>@<client build>'
	    current               the runKey shown
	    once[itemId] = Result  answers of once probes; a rerun skips them until reset
	  Run = { key, version, build, startedAt, results = { [itemId] = Result }, scratch = { [itemId] = {} } }
	  Result = { state, evidence, at, runKey? }

	A fail sticks for the rest of the run: a later pass does not hide it, and a look does not
	replace a pass. /hc reset keeps the old
	run under '<runKey> #<n>' and starts a fresh one, once answers included.

	  Suite.validateItems(items)                 throws on a malformed table (a programmer error)
	  Suite.runKey(version, build) -> key
	  Suite.openRun(db, version, build, now) -> run
	  Suite.resetRun(db, version, build, now) -> run
	  Suite.record(db, run, item, verdict, now) -> boolean changed
	  Suite.resultOf(db, run, item) -> Result|nil
	  Suite.progress(db, run, items) -> { judged, total, pass, fail, look, na, pending }
	  Suite.nextItem(db, run, items) -> item|nil  the first unjudged item, safe zone first
]]
local _, ns = ...

local Suite = {}
ns.Suite = Suite

Suite.KINDS = { auto = true, action = true, look = true }
Suite.ZONES = { safe = true, fight = true }
Suite.VERDICT_STATES = { pass = true, fail = true, look = true, na = true }
Suite.MAX_EVIDENCE_LINES = 8
Suite.MAX_EVIDENCE_BYTES = 200
Suite.MAX_KEPT_RUNS = 12

-- Helpers live at the bottom of the file; declared here so they stay local.
local ensureDb, newRun, keepEvidence, pruneRuns, isJudgedState, validateItem

--- Checks an item table once at load.
--- @param items table list of Item
function Suite.validateItems(items)
	if type(items) ~= 'table' or #items == 0 then
		error('Suite.validateItems: items must be a non-empty list', 2)
	end
	local seen, hasFightItem = {}, false
	for index, item in ipairs(items) do
		validateItem(item, index)
		if seen[item.id] then
			error('Suite.validateItems: duplicate id ' .. item.id, 2)
		end
		seen[item.id] = true
		if item.zone == 'fight' then
			hasFightItem = true
		elseif hasFightItem then
			error('Suite.validateItems: safe item ' .. item.id .. ' after a fight item', 2)
		end
	end
end

--- The key of a run: one per add-on version and client build.
--- @param version string Haggler's version
--- @param build string the client build
function Suite.runKey(version, build)
	return tostring(version or '?') .. '@' .. tostring(build or '?')
end

--- Opens the run for this version and build, creating it on the first load of a new build.
--- @return table run
function Suite.openRun(db, version, build, now)
	ensureDb(db)
	local key = Suite.runKey(version, build)
	local run = db.runs[key]
	if type(run) ~= 'table' then
		run = newRun(key, version, build, now)
		db.runs[key] = run
		pruneRuns(db, key)
	end
	run.results = type(run.results) == 'table' and run.results or {}
	run.scratch = type(run.scratch) == 'table' and run.scratch or {}
	db.current = key
	return run
end

--- Starts a new run for this version and build; the old one stays under '<key> #<n>'.
--- Once answers are cleared, so the once probes run again.
--- @return table run
function Suite.resetRun(db, version, build, now)
	ensureDb(db)
	local key = Suite.runKey(version, build)
	local old = db.runs[key]
	if type(old) == 'table' then
		local archiveIndex = 1
		while db.runs[key .. ' #' .. archiveIndex] ~= nil do
			archiveIndex = archiveIndex + 1
		end
		db.runs[key .. ' #' .. archiveIndex] = old
	end
	db.runs[key] = newRun(key, version, build, now)
	db.once = {}
	pruneRuns(db, key)
	db.current = key
	return db.runs[key]
end

--- Stores a verdict. A fail sticks; a look never replaces a judged result.
--- @return boolean changed
function Suite.record(db, run, item, verdict, now)
	if type(verdict) ~= 'table' or not Suite.VERDICT_STATES[verdict.state] then
		error('Suite.record: verdict.state must be pass, fail, look or na', 2)
	end
	local previous = run.results[item.id]
	if previous and previous.state == 'fail' and verdict.state ~= 'fail' then
		return false
	end
	if previous and isJudgedState(previous.state) and verdict.state == 'look' then
		return false
	end
	local evidence = keepEvidence(verdict.evidence)
	if
		previous
		and previous.state == verdict.state
		and table.concat(previous.evidence or {}, '\n') == table.concat(evidence, '\n')
	then
		return false
	end
	local result = { state = verdict.state, evidence = evidence, at = now }
	run.results[item.id] = result
	if item.once then
		ensureDb(db)
		db.once[item.id] = { state = result.state, evidence = evidence, at = now, runKey = run.key }
	end
	return true
end

--- The result shown for an item: this run's, else a stored once answer.
--- @return table|nil result
function Suite.resultOf(db, run, item)
	local result = run.results[item.id]
	if result then
		return result
	end
	if item.once and type(db.once) == 'table' then
		return db.once[item.id]
	end
	return nil
end

--- Counts per state; judged counts pass, fail and na (a look still needs the player).
--- @return table progress
function Suite.progress(db, run, items)
	local progress = { judged = 0, total = #items, pass = 0, fail = 0, look = 0, na = 0, pending = 0 }
	for _, item in ipairs(items) do
		local result = Suite.resultOf(db, run, item)
		local state = result and result.state or 'pending'
		progress[state] = progress[state] + 1
		if isJudgedState(state) then
			progress.judged = progress.judged + 1
		end
	end
	return progress
end

--- The next item to work on: the first not yet judged, in table order (safe first).
--- @return table|nil item
function Suite.nextItem(db, run, items)
	for _, item in ipairs(items) do
		local result = Suite.resultOf(db, run, item)
		if not result or not isJudgedState(result.state) then
			return item
		end
	end
	return nil
end

-- Helpers ---------------------------------------------------------------------------------

function ensureDb(db)
	if type(db) ~= 'table' then
		error('Suite: db must be a table', 3)
	end
	db.runs = type(db.runs) == 'table' and db.runs or {}
	db.once = type(db.once) == 'table' and db.once or {}
end

function newRun(key, version, build, now)
	return {
		key = key,
		version = tostring(version or '?'),
		build = tostring(build or '?'),
		startedAt = now,
		results = {},
		scratch = {},
	}
end

function keepEvidence(evidence)
	local kept = {}
	if type(evidence) ~= 'table' then
		return kept
	end
	for _, line in ipairs(evidence) do
		if #kept >= Suite.MAX_EVIDENCE_LINES then
			break
		end
		kept[#kept + 1] = tostring(line):sub(1, Suite.MAX_EVIDENCE_BYTES)
	end
	return kept
end

-- Keeps the newest runs; the current key is never dropped.
function pruneRuns(db, currentKey)
	local keys = {}
	for key, run in pairs(db.runs) do
		if key ~= currentKey then
			keys[#keys + 1] = { key = key, startedAt = type(run) == 'table' and tonumber(run.startedAt) or 0 }
		end
	end
	table.sort(keys, function(left, right)
		return left.startedAt > right.startedAt
	end)
	for index = Suite.MAX_KEPT_RUNS, #keys do
		db.runs[keys[index].key] = nil
	end
end

function isJudgedState(state)
	return state == 'pass' or state == 'fail' or state == 'na'
end

function validateItem(item, index)
	local where = 'Suite.validateItems: item ' .. index
	if type(item) ~= 'table' or type(item.id) ~= 'string' or item.id == '' then
		error(where .. ' needs an id', 3)
	end
	where = where .. ' (' .. item.id .. ')'
	if type(item.title) ~= 'string' or not Suite.KINDS[item.kind] or not Suite.ZONES[item.zone] then
		error(where .. ' needs a title, a kind and a zone', 3)
	end
	if type(item.prompt) ~= 'string' or (item.kind ~= 'auto' and item.prompt == '') then
		error(where .. ' needs a prompt', 3)
	end
	if item.kind ~= 'look' and (type(item.judge) ~= 'function' or type(item.on) ~= 'table' or #item.on == 0) then
		error(where .. ' needs a judge and the signals it listens to', 3)
	end
end
