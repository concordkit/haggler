local t = ...

local ns = t.loadAddon()
local Guardrail = ns.Guardrail

local function hasReason(result, code)
	for _, reason in ipairs(result.reasons) do
		if reason.code == code then
			return reason
		end
	end
	return nil
end

t.group('guardrail')

t.test('sell chance follows the queue model and is clamped to 0..1', function()
	-- 48 sales a day over 24 h with 40 units ahead leaves 8 for a listing of 4 units: certain.
	t.eq(Guardrail.sellChance({ salesPerDay = 48, durationHours = 24, unitsAhead = 40, units = 4 }), 1)
	t.eq(Guardrail.sellChance({ salesPerDay = 48, durationHours = 24, unitsAhead = 40, units = 16 }), 0.5)
	t.eq(Guardrail.sellChance({ salesPerDay = 48, durationHours = 12, unitsAhead = 40, units = 4 }), 0)
	t.eq(Guardrail.sellChance({ salesPerDay = 0, durationHours = 24, unitsAhead = 0, units = 1 }), 0)
end)

t.test('sell chance is unknown without sales data or with junk input', function()
	t.eq(Guardrail.sellChance({ durationHours = 24, unitsAhead = 0, units = 1 }), nil)
	t.eq(Guardrail.sellChance({ salesPerDay = 0 / 0, durationHours = 24, unitsAhead = 0, units = 1 }), nil)
	t.eq(Guardrail.sellChance({ salesPerDay = 5, durationHours = 24, unitsAhead = 'x', units = 1 }), nil)
	t.eq(Guardrail.sellChance({ salesPerDay = 5, durationHours = 24, unitsAhead = 0, units = 0 }), nil)
	t.raises(function()
		Guardrail.sellChance(nil)
	end, 'input must be a table')
end)

t.test('deposit loss is one deposit per expected unsold listing, rounded up', function()
	t.eq(Guardrail.depositLoss(100, 1), 0)
	t.eq(Guardrail.depositLoss(100, 0.5), 100)
	t.eq(Guardrail.depositLoss(100, 0.25), 300)
	t.eq(Guardrail.depositLoss(10, 0.3), 24, '23.33 rounds up')
	t.eq(Guardrail.depositLoss(78, 0.3), 182, 'a float just over 182 is still 182')
	t.eq(Guardrail.depositLoss(100, 0), math.huge)
	t.eq(Guardrail.depositLoss(0, 0), 0, 'no deposit, nothing to lose')
	t.raises(function()
		Guardrail.depositLoss(100, 1.5)
	end, 'p in')
end)

t.test('a sale nets the price after the 5% cut, rounded down', function()
	t.eq(Guardrail.saleNet(100, 1), 95)
	t.eq(Guardrail.saleNet(119, 1), 113, '113.05 rounds down')
	t.eq(Guardrail.saleNet(120, 20), 2280)
end)

t.test('units at or under a price skip the anti-bait units first', function()
	local levels = { { price = 120, qty = 30 }, { price = 100, qty = 10 }, { price = 200, qty = 5 } }
	t.eq(Guardrail.unitsAtOrUnder(levels, 120, nil, 45), 40)
	-- 45 a day x 10 minutes = 1 bait unit passed over.
	t.eq(Guardrail.unitsAtOrUnder(levels, 120, { enabled = true, minutes = 10 }, 45), 39)
	t.eq(Guardrail.unitsAtOrUnder(levels, 99, nil, 45), 0)
	t.eq(Guardrail.unitsAtOrUnder({}, 120), nil)
	t.eq(Guardrail.unitsAtOrUnder(nil, 120), nil)
end)

t.test('the worked example of the spec: a deep queue at 3s means vendor it', function()
	-- vendor 2s, lowest listing 3s with 2,500 units, 150 sales a day, 48 h listing.
	local result = Guardrail.opportunity({
		price = 300,
		units = 1,
		vendor = 200,
		salesPerDay = 150,
		levels = { { price = 300, qty = 2500 } },
		durationHours = 48,
	})
	t.eq(result.sellChance, 0)
	t.eq(result.source, 'vendor')
	t.eq(result.copper, 200)
	t.eq(result.ahNet, nil, 'a listing that never sells has no AH net')
	t.truthy(hasReason(result, 'wontSell'))
end)

t.test('the AH wins when its net after cut and deposit risk beats the vendor', function()
	local result = Guardrail.opportunity({
		price = 120,
		units = 20,
		vendor = 13,
		salesPerDay = 45,
		levels = { { price = 100, qty = 10 }, { price = 120, qty = 30 } },
		antiBait = { enabled = true, minutes = 10 },
		durationHours = 24,
	})
	-- 39 ahead, 45 sales: p = 6 / 20 = 0.3. Deposit 13 x 20 x 15% x 2 = 78; loss 182.
	t.eq(result.unitsAhead, 39)
	t.eq(result.sellChance, 0.3)
	t.eq(result.deposit, 78)
	t.eq(result.depositLoss, 182)
	t.eq(result.ahNet, 2280 - 182)
	t.eq(result.copper, 2098)
	t.eq(result.perUnit, 104)
	t.eq(result.source, 'ah')
	t.truthy(hasReason(result, 'depositEstimated'))
	t.eq(hasReason(result, 'depositEstimated').level, 'high', 'an estimated deposit informs, it does not lower')
end)

t.test('never below the vendor: a tie goes to the vendor', function()
	local result = Guardrail.opportunity({ price = 100, units = 1, vendor = 95, salesPerDay = 50, levels = {} })
	t.eq(result.source, 'vendor', 'AH 95 ties the vendor 95')
	t.eq(result.copper, 95)
	local cheap = Guardrail.opportunity({ price = 20, units = 5, vendor = 30, salesPerDay = 50, deposit = 0 })
	t.eq(cheap.copper, 150)
	t.eq(cheap.source, 'vendor')
end)

t.test('a given deposit is used instead of the estimate', function()
	local result = Guardrail.opportunity({
		price = 1000,
		units = 1,
		vendor = 100,
		salesPerDay = 1,
		levels = { { price = 2000, qty = 1 } },
		durationHours = 24,
		deposit = 40,
	})
	t.eq(result.sellChance, 1)
	t.eq(result.deposit, 40)
	t.eq(result.depositLoss, 0)
	t.eq(hasReason(result, 'depositEstimated'), nil)
end)

t.test('missing data is said, never hidden', function()
	local noSales =
		Guardrail.opportunity({ price = 200, units = 1, vendor = 10, levels = { { price = 300, qty = 1 } } })
	t.eq(noSales.copper, 190, 'no sales data: the cut only')
	t.eq(hasReason(noSales, 'sellChanceUnknown').level, 'medium')
	local noScan = Guardrail.opportunity({ price = 200, units = 1, vendor = 10, salesPerDay = 10 })
	t.eq(hasReason(noScan, 'queueUnknown').level, 'medium')
	local noVendor = Guardrail.opportunity({ price = 200, units = 1, salesPerDay = 10, levels = {} })
	t.eq(hasReason(noVendor, 'vendorUnknown').level, 'medium')
	t.eq(hasReason(noVendor, 'depositEstimated').level, 'medium', 'no vendor price, no deposit estimate')
end)

t.test('an unpriced item falls back to the vendor, or to nothing with a low reason', function()
	local vendorOnly = Guardrail.opportunity({ units = 3, vendor = 25 })
	t.eq(vendorOnly.copper, 75)
	t.eq(vendorOnly.source, 'vendor')
	t.eq(hasReason(vendorOnly, 'noPrice').level, 'medium')
	local nothing = Guardrail.opportunity({ units = 1, price = 0 / 0 })
	t.eq(nothing.copper, 0)
	t.eq(nothing.source, 'none')
	t.eq(hasReason(nothing, 'noPrice').level, 'low')
end)

t.test('a bound item is worth its vendor price only', function()
	local result = Guardrail.opportunity({ price = 5000, units = 1, vendor = 120, isBound = true })
	t.eq(result.copper, 120)
	t.eq(result.source, 'vendor')
	t.eq(hasReason(result, 'bound').level, 'high')
end)

t.test('opportunity needs units', function()
	t.raises(function()
		Guardrail.opportunity({ price = 1 })
	end, 'needs units')
end)

t.group('guardrail: break-even and the posting verdict')

-- The spec's worked example: vendor 2s, 2,500 units listed at 3s, 150 sales a day, 48 h.
local WORKED = {
	units = 1,
	step = 100,
	vendor = 200,
	salesPerDay = 150,
	levels = { { price = 300, qty = 2500 } },
	durationHours = 48,
	deposit = 60,
}

local function with(base, changes)
	local merged = {}
	for key, value in pairs(base) do
		merged[key] = value
	end
	for key, value in pairs(changes) do
		merged[key] = value
	end
	return merged
end

t.test('worked example: the undercut lands on the vendor price, so vendor it', function()
	local atRule = Guardrail.verdict(with(WORKED, { price = 200 }))
	t.eq(atRule.sellChance, 1)
	t.eq(atRule.net, 190, '2s less the 5% cut, no deposit lost')
	t.eq(atRule.breakEven, 200, 'never below the vendor price')
	t.eq(atRule.action, 'vendor')
	t.eq(atRule.isLoss, false)
	t.eq(atRule.isBelowVendor, true)
	local atThree = Guardrail.verdict(with(WORKED, { price = 300 }))
	t.eq(atThree.sellChance, 0)
	t.eq(atThree.isLoss, true, 'behind 17 days of sales every post burns its deposit')
	t.truthy(hasReason(atThree, 'wontSell'))
	t.eq(Guardrail.postCheck(atThree, 'confirm'), 'confirm')
	t.eq(Guardrail.postCheck(atThree, 'warn'), 'warn')
	t.eq(Guardrail.postCheck(atThree, 'off'), 'ok')
	t.eq(Guardrail.postCheck(atRule, 'confirm'), 'warn', 'under the vendor warns, never blocks')
end)

t.test('break-even rounds up to the step and counts cost and deposit risk', function()
	-- 10 sales a day, nothing listed: a 24 h listing of 20 units has p = 0.5, so one deposit of
	-- 100c is expected lost; with a cost of 50c a unit the sale must pay 1100c: 1100 / 19 = 57.9.
	local input = { units = 20, step = 1, vendor = 5, cost = 50, salesPerDay = 10, durationHours = 24, deposit = 100 }
	t.eq(Guardrail.breakEven(input), 58)
	t.eq(Guardrail.breakEven(with(input, { step = 100 })), 100)
	t.truthy(Guardrail.listingNet(with(input, { price = 58 })) >= 0)
	t.truthy(Guardrail.listingNet(with(input, { price = 57 })) < 0)
end)

t.test('break-even skips a queue that never clears and finds the next interval', function()
	-- 1,000 units at 50c block everything at 50c and up; under it nothing is ahead.
	local input = {
		units = 1,
		step = 1,
		vendor = 10,
		cost = 40,
		salesPerDay = 24,
		levels = { { price = 50, qty = 1000 } },
		durationHours = 24,
		deposit = 5,
	}
	t.eq(Guardrail.breakEven(input), 43, '43 * 0.95 = 40.85, floored to 40')
	t.eq(Guardrail.breakEven(with(input, { cost = 60 })), nil, 'nothing under 50c pays 60c; 50c up never sells')
end)

t.test('verdict: post when the AH beats the vendor by the threshold, hold with nothing to vendor', function()
	local base = { units = 10, step = 1, salesPerDay = 100, levels = { { price = 1000, qty = 5 } }, deposit = 50 }
	local post =
		Guardrail.verdict(with(base, { price = 900, vendor = 100, threshold = { copper = 1000, percent = 10 } }))
	t.eq(post.action, 'post')
	t.eq(post.netPerUnit, 855)
	local close =
		Guardrail.verdict(with(base, { price = 120, vendor = 100, threshold = { copper = 1000, percent = 10 } }))
	t.eq(close.action, 'vendor', '1140 against 1000 misses the 1000c margin')
	local noVendor = Guardrail.verdict(with(base, { price = 1, vendor = 0, threshold = { copper = 100, percent = 0 } }))
	t.eq(noVendor.action, 'hold')
	local unpriced = Guardrail.verdict(with(base, { price = nil, vendor = 100 }))
	t.eq(unpriced.action, 'vendor')
	t.truthy(hasReason(unpriced, 'noPrice'))
end)

t.test('verdict: confidence takes the price confidence and its own reasons', function()
	local verdict = Guardrail.verdict({
		price = 500,
		units = 1,
		step = 1,
		vendor = 10,
		confidence = { level = 'low', reasons = { { code = 'stale', level = 'low', text = 'old' } } },
	})
	t.eq(verdict.confidence.level, 'low')
	t.truthy(hasReason(verdict, 'sellChanceUnknown'))
	t.truthy(hasReason(verdict, 'queueUnknown'))
	t.truthy(hasReason(verdict, 'depositEstimated'))
	t.raises(function()
		Guardrail.verdict({ price = 1 })
	end, 'needs units')
	t.raises(function()
		Guardrail.postCheck(nil, 'warn')
	end, 'needs a verdict')
end)
