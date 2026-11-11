-- Run from the addon folder: luajit tests/selllog_spec.lua
local ns = dofile("Pricing.lua")
loadfile("SellLog.lua")(nil, ns)
local S = ns.SellLog

local passed, failed = 0, 0

local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		print("FAIL " .. name .. ": " .. tostring(err))
	end
end

local function eq(actual, expected, what)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", what or "value", tostring(expected), tostring(actual)), 2)
	end
end

local HOUR = 3600
local ELIXIR = "Elixir of Minor Fortitude"

local function elixirPost(t, qty, unit, estSeconds)
	return S.newPost(t, 3825, ELIXIR, qty, unit, 24, { seconds = estSeconds, ahead = 19, isAheadKnown = true })
end

test("mail arrival from days left", function()
	eq(S.arrivalTime(1000000, 29.5), 1000000 - 43200, "half a day old")
	eq(S.arrivalTime(1000000, 31), 1000000, "never in the future")
	eq(pcall(S.arrivalTime, nil, 1), false, "contract")
end)

test("subjects: English fallback and the client's own strings", function()
	local english = S.subjectPatterns(nil)
	local kind, name = S.parseSubject(english, "Auction successful: " .. ELIXIR)
	eq(kind, "sold", "kind")
	eq(name, ELIXIR, "name")
	eq((S.parseSubject(english, "Sale Pending: Linen Cloth")), "pending", "pending")
	eq((S.parseSubject(english, "Auction expired: Linen Cloth")), "expired", "expired")
	eq((S.parseSubject(english, "Auction cancelled: Linen Cloth")), "cancelled", "cancelled")
	eq(S.parseSubject(english, "Hello there"), nil, "other mail")
	local german = S.subjectPatterns({ AUCTION_SOLD_MAIL_SUBJECT = "Auktion erfolgreich: %s" })
	eq((S.parseSubject(german, "Auktion erfolgreich: Leinenstoff")), "sold", "localized")
end)

test("a post sells out over several sales", function()
	local posts = { elixirPost(0, 20, 183, 2 * HOUR) }
	S.applySale(posts, ELIXIR, 183 * 5, 5, HOUR)
	eq(posts[1].status, "open", "after 5 of 20")
	eq(posts[1].sold, 5, "sold")
	S.applySale(posts, ELIXIR, 183 * 15, 15, 3 * HOUR)
	eq(posts[1].status, "sold", "sold out")
	eq(posts[1].actual, 3 * HOUR, "actual time")
end)

test("a sale goes to the post its money fits, oldest first", function()
	local posts = { elixirPost(0, 10, 200, HOUR), elixirPost(60, 10, 183, HOUR) }
	local post = S.applySale(posts, ELIXIR, 183 * 4, 4, HOUR)
	eq(post, posts[2], "cheaper post")
	local again = S.applySale(posts, ELIXIR, 999, nil, HOUR)
	eq(again, posts[1], "nothing fits: oldest")
	eq(posts[1].sold, 5, "units from money")
end)

test("without a count, units come from the money", function()
	local posts = { elixirPost(0, 10, 183, HOUR) }
	S.applySale(posts, ELIXIR, 183 * 3, nil, HOUR)
	eq(posts[1].sold, 3, "units")
end)

test("a sale before any post of that item matches nothing", function()
	local posts = { elixirPost(5000, 10, 183, HOUR) }
	eq(S.applySale(posts, ELIXIR, 183, 1, 100), nil, "earlier sale")
	eq(S.applySale(posts, "Linen Cloth", 183, 1, 6000), nil, "other item")
end)

test("returns close the post with that many unsold, else the oldest", function()
	local posts = { elixirPost(0, 20, 183, HOUR), elixirPost(10, 5, 183, HOUR) }
	eq(S.applyReturn(posts, ELIXIR, "cancelled", 5, 100), posts[2], "count fits the second")
	eq(posts[2].status, "cancelled", "status")
	S.applySale(posts, ELIXIR, 183 * 8, 8, 200)
	eq(S.applyReturn(posts, ELIXIR, "expired", nil, 300), posts[1], "oldest")
	eq(posts[1].sold, 8, "partly sold")
end)

test("one mail seen on every inbox update counts once", function()
	local seen = {}
	eq(S.isSeenElseMark(seen, {}, "sold", ELIXIR, 915, 1000), false, "first sighting")
	eq(S.isSeenElseMark(seen, {}, "sold", ELIXIR, 915, 1030), true, "next update")
end)

test("two identical mails in one inbox are two sales", function()
	local seen = {}
	local pass = {}
	eq(S.isSeenElseMark(seen, pass, "sold", ELIXIR, 915, 1000), false, "first")
	eq(S.isSeenElseMark(seen, pass, "sold", ELIXIR, 915, 1010), false, "second")
	local nextPass = {}
	eq(S.isSeenElseMark(seen, nextPass, "sold", ELIXIR, 915, 1000), true, "first again")
	eq(S.isSeenElseMark(seen, nextPass, "sold", ELIXIR, 915, 1010), true, "second again")
end)

test("a pending mail and its later payment are one sale", function()
	local seen = {}
	eq(S.isSeenElseMark(seen, {}, "pending", ELIXIR, 915, 1000), false, "pending")
	eq(S.isSeenElseMark(seen, {}, "sold", ELIXIR, 915, 1000 + HOUR), true, "payment an hour later")
	eq(S.isSeenElseMark(seen, {}, "sold", ELIXIR, 915, 1000 + HOUR + 60), true, "payment seen again")
	eq(S.isSeenElseMark(seen, {}, "sold", ELIXIR, 915, 1000 + 1.5 * HOUR), false, "a different sale")
end)

test("estimate counts cheaper listings and the player's own posts", function()
	local levels = { { unit = 120, qty = 19 }, { unit = 184, qty = 55 } }
	local posts = { elixirPost(0, 10, 150, HOUR), elixirPost(0, 10, 190, HOUR) }
	local own = S.ownUnitsAhead(posts, 3825, 183)
	eq(own, 10, "own units at or below")
	local e = S.estimate(levels, 183, 50, 800, own)
	eq(e.ahead, 29, "ahead")
	eq(e.isAheadKnown, true, "known")
	eq(e.seconds, (29 + 50) / 800 * 86400, "seconds")
	eq(S.estimate(nil, 183, 50, nil, 0), nil, "no pace")
	eq(S.estimate(nil, 183, 50, 800, 0).isAheadKnown, false, "no levels")
end)

test("summary: sold within estimate, ratio, returns", function()
	local posts = {
		elixirPost(0, 1, 183, 2 * HOUR),
		elixirPost(0, 1, 183, 2 * HOUR),
		elixirPost(0, 2, 183, 2 * HOUR),
		elixirPost(0, 1, 183, 2 * HOUR),
		elixirPost(0, 1, 183, nil),
	}
	posts[1].status, posts[1].actual = "sold", HOUR
	posts[2].status, posts[2].actual = "sold", 4 * HOUR
	posts[3].status, posts[3].sold = "expired", 1
	posts[5].status, posts[5].actual = "sold", HOUR
	local s = S.summarize(posts, 0)
	eq(s.soldOut, 3, "sold out")
	eq(s.returned, 1, "returned")
	eq(s.partly, 1, "partly")
	eq(s.open, 1, "open")
	eq(s.withEstimate, 3, "closed with estimate")
	eq(s.withinEstimate, 1, "within")
	eq(s.medianRatio, (0.5 + 2) / 2, "median ratio")
	eq(S.summarize({}, 0).medianRatio, nil, "empty")
end)

test("summary text", function()
	local empty = S.summaryText(S.summarize({ elixirPost(0, 1, 1, 1) }, 0), 30)
	eq(empty, "sell log, last 30 days: nothing closed yet, 1 open", "nothing closed")
	local posts = { elixirPost(0, 1, 183, 2 * HOUR) }
	posts[1].status, posts[1].actual = "sold", 3 * HOUR
	local text = S.summaryText(S.summarize(posts, 0), 30)
	eq(
		text,
		"sell log, last 30 days: 1 sold out, typically 1.5x the estimate, 0 of 1 closed with an estimate sold within it, 0 open",
		"text"
	)
end)

test("trim drops old posts and mail", function()
	local log = { posts = { elixirPost(0, 1, 1, 1), elixirPost(100 * 86400, 1, 1, 1) }, seen = { { at = 0 } } }
	S.trim(log, 100 * 86400)
	eq(#log.posts, 1, "posts")
	eq(#log.seen, 0, "seen")
end)

test("new post contract", function()
	eq(pcall(S.newPost, 0, 1, ELIXIR, 0, 100), false, "zero qty")
	eq(pcall(S.newPost, 0, 1, nil, 1, 100), false, "no name")
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
