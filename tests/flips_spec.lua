-- Run from the addon folder: luajit tests/flips_spec.lua
local ns = {}
loadfile("Flips.lua")(nil, ns)
local F = ns.Flips

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

local function noName()
	return nil, nil
end

test("only listings under the vendor price count", function()
	local acc = {}
	F.add(acc, 2589, 5, 40, 10) -- 8c each, vendor pays 10c
	F.add(acc, 2589, 1, 10, 10) -- at the vendor price: no flip
	F.add(acc, 2589, 2, 30, 10) -- over it
	eq(acc[2589].qty, 5, "qty")
	eq(acc[2589].cost, 40, "cost")
	eq(acc[2589].lowest, 8, "lowest")
end)

test("unsellable, unknown and broken listings are skipped", function()
	local acc = {}
	F.add(acc, 1, 1, 5, 0)
	F.add(acc, 2, 1, 5, nil)
	F.add(acc, 3, 0, 5, 10)
	F.add(acc, "x", 1, 5, 10)
	eq(next(acc), nil, "nothing added")
end)

test("rows: biggest profit first, under the minimum left out", function()
	local acc = {}
	F.add(acc, 10, 1, 50, 100) -- +50
	F.add(acc, 20, 10, 100, 100) -- +900
	F.add(acc, 30, 1, 99, 100) -- +1
	local rows = F.rows(acc, 10, noName)
	eq(#rows, 2, "rows")
	eq(rows[1].itemID, 20, "first")
	eq(rows[1].profit, 900, "profit")
	eq(rows[1].pct, 900, "return")
	eq(rows[2].name, "item 10", "fallback name")
end)

test("minimum profit falls back to the default", function()
	HagglerDB = nil
	eq(F.minProfit(), F.DEFAULT_MIN_PROFIT, "no db")
	HagglerDB = { flipMinProfit = 500 }
	eq(F.minProfit(), 500, "saved")
	HagglerDB = nil
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
