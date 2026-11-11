-- Run from the addon folder: luajit tests/pricing_spec.lua
local ns = dofile("Pricing.lua")
local P = ns.Pricing

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

-- The Elixir of Minor Fortitude market from the screenshot.
local ELIXIR_LEVELS = {
	{ unit = 120, qty = 19 },
	{ unit = 184, qty = 55 },
	{ unit = 185, qty = 80 },
	{ unit = 195, qty = 151 },
}
local ELIXIR = { median = 250, minBuyout = 120, soldPerDay = 800, levels = ELIXIR_LEVELS }

test("elixir: skips the lone 1s 20c stack and undercuts 1s 84c", function()
	local price = P.competitivePrice(ELIXIR_LEVELS, ELIXIR)
	eq(price.unit, 183, "unit")
	eq(price.source, "depth", "source")
end)

test("elixir: margin after the cut at a 1s 45c cost", function()
	local m = P.netMargin(183, 1, 145)
	eq(m.proceeds, 173, "proceeds")
	eq(m.margin, 28, "margin")
	eq(m.breakEven, 153, "break-even")
end)

test("thin market: a few units are enough depth", function()
	local price = P.competitivePrice({ { unit = 500, qty = 6 }, { unit = 900, qty = 50 } }, { soldPerDay = 2 })
	eq(price.unit, 499, "unit")
end)

test("depth never reached: the dearest level is the price", function()
	local price = P.competitivePrice({ { unit = 100, qty = 1 }, { unit = 110, qty = 1 } }, { soldPerDay = 2400 })
	eq(price.unit, 109, "unit")
end)

test("no depth data: lower of lowest and median", function()
	eq(P.competitivePrice(nil, { median = 250, minBuyout = 184 }).unit, 183, "lowest under median")
	local capped = P.competitivePrice({}, { median = 150, minBuyout = 184 })
	eq(capped.unit, 149, "median under lowest")
	eq(capped.source, "median", "source")
end)

test("median below the competitive price caps it", function()
	local price = P.competitivePrice(ELIXIR_LEVELS, { median = 170, soldPerDay = 800 })
	eq(price.unit, 169, "unit")
	eq(price.source, "median", "source")
end)

test("nothing prices it: nil", function()
	eq(P.competitivePrice(nil, {}), nil, "price")
	eq(P.competitivePrice(nil, nil), nil, "price without prices")
end)

test("empty scan: empty index, nothing read", function()
	local index = P.buildDepthIndex("")
	eq(next(index), nil, "index")
	local nextPos, read = P.readListingsInto("", 1, 10, {})
	eq(nextPos, nil, "next position")
	eq(read, 0, "read")
end)

test("scan string: unit prices, bid-only skipped, wanted filter", function()
	local data = "2589:5:600:0:0;2589:1:200:0:0;2589:2:0:150:0;765:1:10:0:0"
	local index = P.buildDepthIndex(data, { [2589] = true })
	eq(index[765], nil, "unwanted item")
	local levels = index[2589]
	eq(#levels, 2, "levels")
	eq(levels[1].unit, 120, "cheapest unit")
	eq(levels[1].qty, 5, "cheapest qty")
	eq(levels[2].unit, 200, "second unit")
end)

test("scan read in slices matches one read", function()
	local data = "1:1:100:0:0;1:1:100:0:0;1:2:300:0:0;1:1:90:0:0"
	local units, pos, steps = {}, 1, 0
	repeat
		pos = P.readListingsInto(data, pos, 1, units)
		steps = steps + 1
	until not pos
	eq(steps, 5, "steps")
	eq(units[1][100], 2, "qty at 100")
	eq(units[1][150], 2, "qty at 150")
	eq(units[1][90], 1, "qty at 90")
end)

test("reagent cost walks up the levels", function()
	eq(P.reagentBuyCost({ { unit = 10, qty = 1 }, { unit = 20, qty = 5 } }, 3, nil), 50, "cost")
end)

test("reagent qty past the listed depth uses the fallback", function()
	eq(P.reagentBuyCost({ { unit = 10, qty = 1 } }, 3, 30), 70, "with fallback")
	eq(P.reagentBuyCost({ { unit = 10, qty = 1 } }, 3, nil), 30, "dearest level")
	eq(P.reagentBuyCost(nil, 2, nil), nil, "unpriced")
	eq(P.reagentBuyCost(nil, 0, nil), 0, "zero qty")
end)

test("zero cost: no percent, break-even zero", function()
	local m = P.netMargin(100, 1, 0)
	eq(m.pct, nil, "pct")
	eq(m.breakEven, 0, "break-even")
	eq(m.margin, 95, "margin")
end)

test("several made per craft", function()
	local m = P.netMargin(100, 2, 100)
	eq(m.proceeds, 190, "proceeds")
	eq(m.breakEven, 53, "break-even per result")
end)

test("recipe economics: priced, unpriced reagent counted", function()
	local prices = {
		[3825] = ELIXIR,
		[2449] = { minBuyout = 40, levels = { { unit = 40, qty = 100 } } },
		[2447] = { median = 30 },
	}
	local recipe = { resultID = 3825, made = 1, reagents = { { 2449, 2 }, { 2447, 1 }, { 9999, 1 } } }
	local e = P.recipeEconomics(recipe, function(id)
		return prices[id]
	end)
	eq(e.cost, 110, "cost")
	eq(e.missing, 1, "missing")
	eq(e.sell.unit, 183, "sell")
	eq(e.margin, 63, "margin")
end)

test("recipe economics: unpriced result is nil", function()
	local e = P.recipeEconomics({ resultID = 1, reagents = {} }, function()
		return nil
	end)
	eq(e, nil, "economics")
end)

test("contract violations throw", function()
	eq(pcall(P.netMargin, nil, 1, 0), false, "netMargin")
	eq(pcall(P.reagentBuyCost, nil, -1), false, "reagentBuyCost")
	eq(pcall(P.recipeEconomics, nil, nil), false, "recipeEconomics")
end)

test("reagent shortfall is reported only past real depth", function()
	local cost, short = P.reagentBuyCost({ { unit = 10, qty = 1 } }, 3, 30)
	eq(cost, 70, "cost")
	eq(short, 2, "short")
	local _, noDepth = P.reagentBuyCost(nil, 3, 30)
	eq(noDepth, 0, "no levels is no shortfall")
end)

test("prognosis: 50 elixirs walk deeper into the reagents", function()
	local prices = {
		[3825] = ELIXIR,
		[2449] = { minBuyout = 40, levels = { { unit = 40, qty = 60 }, { unit = 50, qty = 30 } }, median = 45 },
		[2447] = { minBuyout = 30, levels = { { unit = 30, qty = 100 } } },
		[3371] = { median = 4 },
	}
	local recipe = { resultID = 3825, made = 1, reagents = { { 2449, 2 }, { 2447, 1 }, { 3371, 1 } } }
	local e = P.recipeEconomics(recipe, function(id)
		return prices[id]
	end, 50)
	-- Earthroot: 60 at 40c, 30 at 50c, 10 past the depth at 40c; Peacebloom 50 at 30c; vials 50 at 4c.
	eq(e.cost, 2400 + 1500 + 400 + 1500 + 200, "cost")
	eq(#e.shortReagents, 1, "short reagents")
	eq(e.shortReagents[1], 2449, "short reagent")
	eq(e.units, 50, "units")
	eq(e.proceeds, math.floor(183 * 50 * 0.95), "proceeds")
	eq(e.unitsAhead, 19, "units cheaper than ours")
	eq(e.isAheadKnown, true, "ahead known")
	eq(e.secondsToSell, (19 + 50) / 800 * 86400, "time until sold")
end)

test("prognosis: crafts must be a positive whole number", function()
	local lookup = function()
		return ELIXIR
	end
	eq(pcall(P.recipeEconomics, { resultID = 1 }, lookup, 0), false, "zero")
	eq(pcall(P.recipeEconomics, { resultID = 1 }, lookup, 2.5), false, "fraction")
end)

test("time until sold without depth counts only your units", function()
	local e = P.recipeEconomics({ resultID = 1, reagents = {} }, function()
		return { minBuyout = 200, soldPerDay = 24 }
	end, 6)
	eq(e.unitsAhead, 0, "units ahead")
	eq(e.isAheadKnown, false, "ahead known")
	eq(e.secondsToSell, 6 * 3600, "time until sold")
	eq(P.secondsToSellOut(10, nil), nil, "no pace")
	eq(P.unitsBelow({ { unit = 100, qty = 3 }, { unit = 150, qty = 4 } }, 150), 3, "strictly cheaper")
end)

test("bait units grow with the sales pace", function()
	eq(P.baitUnits(nil), 1, "no pace")
	eq(P.baitUnits(2), 1, "slow")
	eq(P.baitUnits(800), 6, "elixir pace")
	eq(P.baitUnits(1579), 11, "fast")
end)

test("lowest mode passes over bait listings", function()
	local bait = { { unit = 50, qty = 1 }, { unit = 120, qty = 19 }, { unit = 184, qty = 55 } }
	local price = P.lowestPrice(bait, { soldPerDay = 2 })
	eq(price.unit, 119, "skips the lone 50c")
	eq(price.skipped, 1, "skipped")
	local fast = P.lowestPrice(bait, { soldPerDay = 1579 })
	eq(fast.unit, 119, "11 bait units fall inside the 19")
	eq(P.lowestPrice({ { unit = 300, qty = 1 } }, {}).unit, 299, "only bait listed")
	eq(P.lowestPrice({ { unit = 300, qty = 1 } }, {}).skipped, 0, "nothing passed over")
	eq(P.lowestPrice(nil, { minBuyout = 200 }).unit, 199, "no depth")
	eq(P.lowestPrice(nil, {}), nil, "unpriced")
end)

test("lowest mode ignores the median cap", function()
	local price = P.sellPrice(ELIXIR_LEVELS, { median = 100, soldPerDay = 2 }, "lowest")
	eq(price.unit, 119, "unit")
end)

test("median mode: result and reagents at the median", function()
	local prices = {
		[3825] = ELIXIR,
		[2449] = { median = 45, levels = { { unit = 40, qty = 100 } } },
		[2447] = { minBuyout = 30, levels = { { unit = 30, qty = 100 } } },
	}
	local recipe = { resultID = 3825, made = 1, reagents = { { 2449, 2 }, { 2447, 1 } } }
	local e = P.recipeEconomics(recipe, function(id)
		return prices[id]
	end, 1, "median")
	eq(e.sell.unit, 250, "sells at the median")
	eq(e.cost, 90 + 30, "median reagent, else walked")
	eq(e.mode, "median", "mode")
	eq(pcall(P.recipeEconomics, recipe, function() end, 1, "cheapest"), false, "unknown mode")
	eq(P.sellPrice(nil, {}, "median"), nil, "no median")
end)

test("margin bands", function()
	eq(P.marginBand(nil), "unknown", "unpriced result")
	eq(P.marginBand({ missing = 1, pct = 50 }), "unknown", "unpriced reagent")
	eq(P.marginBand({ missing = 0, pct = nil }), "unknown", "zero cost")
	eq(P.marginBand({ missing = 0, pct = 5 }), "profit", "profit edge")
	eq(P.marginBand({ missing = 0, pct = 4.9 }), "even", "just under profit")
	eq(P.marginBand({ missing = 0, pct = -5 }), "even", "even edge")
	eq(P.marginBand({ missing = 0, pct = -30 }), "loss", "loss edge")
	eq(P.marginBand({ missing = 0, pct = -31 }), "heavy", "heavy")
end)

test("money formatting", function()
	eq(P.formatMoney(183), "1s 83c", "silver")
	eq(P.formatMoney(28), "28c", "copper")
	eq(P.formatMoney(-400), "-4s", "negative")
	eq(P.formatMoney(10500), "1g 5s", "gold")
	eq(P.formatMoney(0), "0c", "zero")
end)

test("trend needs 5% either way", function()
	eq(P.trend(105, 100), "up", "5% up")
	eq(P.trend(104, 100), nil, "under 5%")
	eq(P.trend(95, 100), "down", "5% down")
	eq(P.trend(-50, -100), "up", "negative profit shrinking")
	eq(P.trend(100, nil), nil, "no week")
	eq(P.trend(100, 0), nil, "zero week")
end)

test("craft cost per result, now and week", function()
	local prices = { [1] = { median = 100, median7d = 120 }, [2] = { median = 50 } }
	local recipe = { reagents = { { 1, 2 }, { 2, 1 } }, made = 2 }
	local cost = P.craftCost(recipe, function(id) return prices[id] end)
	eq(cost.now, 125, "now")
	eq(cost.week, 145, "week falls back to median")
	eq(P.craftCost({ reagents = { { 3, 1 } } }, function() return nil end), nil, "unpriced reagent")
	eq(P.craftCost(nil, function() end), nil, "no recipe")
end)

test("verdicts", function()
	local calm = { median7d = 1000, soldPerDay = 100, quantity = 50 }
	eq(P.verdict(nil, 30, calm), "vendor", "no auction price")
	eq(P.verdict(nil, 0, calm), nil, "sells nowhere")
	eq(P.verdict(100, 80, calm), "vendor", "net under 1.5x vendor")
	eq(P.verdict(1000, 80, calm), "auction", "auction beats vendor")
	eq(P.verdict(1000, nil, calm), "auction", "no vendor price")
	eq(P.verdict(840, 80, calm), "wait", "15% under the week")
	eq(P.verdict(1000, 80, { median7d = 1000, soldPerDay = 10, quantity = 30 }), "wait", "3 days of stock")
end)

test("item economics against craft cost and vendor", function()
	local input = {
		vendor = 100,
		prices = { median = 1000, median7d = 800, minBuyout = 900, soldPerDay = 2400, quantity = 100 },
		levels = { { unit = 900, qty = 200 } },
		craft = { now = 500, week = 500 },
	}
	local e = P.itemEconomics(input)
	eq(e.basis, "craft", "basis")
	eq(e.minimum.now, 899, "minimum")
	eq(e.realistic.now, 899, "realistic")
	eq(e.realistic.trend, "up", "realistic over week")
	eq(e.profitReal.now, math.floor(899 * 0.95) - 500, "profit")
	eq(e.profitReal.week, 760 - 500, "week profit")
	eq(e.profitPct, (math.floor(899 * 0.95) - 500) / 500 * 100, "profit percent of craft cost")
	eq(e.verdict, "auction", "verdict")
	input.craft = nil
	e = P.itemEconomics(input)
	eq(e.basis, "vendor", "vendor basis")
	eq(e.profitMin.now, math.floor(899 * 0.95) - 100, "profit over vendor")
	e = P.itemEconomics({ vendor = 25 })
	eq(e.minimum, nil, "no market")
	eq(e.verdict, "vendor", "vendor only")
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
