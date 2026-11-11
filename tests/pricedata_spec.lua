local t = ...
local ns = t.loadAddon()
local PriceData = ns.PriceData

t.test('parses a full row; sold is decoded from tenths', function()
	local items, count, skipped = PriceData.parseRows('2589:1200:950:340:1180:1250:800:1900:1505')
	t.eq(count, 1)
	t.eq(skipped, 0)
	t.same(items[2589], {
		median = 1200,
		min = 950,
		qty = 340,
		m7 = 1180,
		m30 = 1250,
		lo = 800,
		hi = 1900,
		sold = 150.5,
	})
end)

t.test('empty fields are unknown and the ninth field is optional', function()
	local items = PriceData.parseRows('765:::0:::::\n2447:50:40:12:48:52:30:70')
	t.same(items[765], { qty = 0 })
	t.eq(items[2447].median, 50)
	t.eq(items[2447].sold, nil)
end)

t.test('rows split on semicolons and newlines; junk lines are skipped', function()
	local text = '1:10:9:1:10:10:9:11:5;2:20:19:2:20:20:19:21:5\n\n3:30:29:3:30:30:29:31:5\nnot a row;4:abc'
	local items, count, skipped = PriceData.parseRows(text)
	t.eq(count, 3)
	t.eq(skipped, 2)
	t.eq(items[3].median, 30)
end)

t.test('a duplicate item keeps the last row and counts once', function()
	local items, count = PriceData.parseRows('7:10:9:1:10:10:9:11:5;7:20:19:1:20:20:19:21:5')
	t.eq(count, 1)
	t.eq(items[7].median, 20)
end)

t.test('out-of-range values are dropped, not trusted', function()
	local items = PriceData.parseRows('9:99999999999999999:5:1:::::999999999999')
	t.eq(items[9].median, nil)
	t.eq(items[9].min, 5)
	t.eq(items[9].sold, nil)
	local zeroId = PriceData.parseRows('0:10:9:1:10:10:9:11:5')
	t.eq(next(zeroId), nil, 'item id 0 is not an item')
end)

t.test('parse reads the AHL1 header, also when pasted with doubled pipes', function()
	local header = 'AHL1|forever/normal/alliance/us|1762800000|2\n'
	local body = '1:10:9:1:10:10:9:11:5\n2:20:19:2:20:20:19:21:5'
	local parsed = PriceData.parse(header .. body)
	t.eq(parsed.market, 'forever/normal/alliance/us')
	t.eq(parsed.updated, 1762800000)
	t.eq(parsed.declared, 2)
	t.eq(parsed.count, 2)
	local pasted = PriceData.parse('AHL1||forever/pvp/horde/eu||1762800000||1\n1:10:9:1:10:10:9:11:5')
	t.eq(pasted.market, 'forever/pvp/horde/eu')
end)

t.test('parse works without a header', function()
	local parsed = PriceData.parse('1:10:9:1:10:10:9:11:5')
	t.eq(parsed.market, nil)
	t.eq(parsed.count, 1)
end)

t.test('parse returns a reason for empty, unknown and row-less text', function()
	local result, reason = PriceData.parse('  \n ')
	t.eq(result, nil)
	t.eq(reason, 'empty')
	result, reason = PriceData.parse('XYZ9|forever/normal/alliance/us|1|1\n1:2:3:4:5:6:7:8:9')
	t.eq(result, nil)
	t.eq(reason, 'unknown format')
	result, reason = PriceData.parse('AHL1|forever/normal/alliance/us|1|0\n')
	t.eq(reason, 'no rows')
	t.eq(result, nil)
	t.raises(function()
		PriceData.parseRows(nil)
	end, 'string')
end)

t.group('price library')

t.test('parses lazily, caches, and reports a missing market', function()
	local library = PriceData.newLibrary()
	local market = 'forever/normal/alliance/us'
	library:AddRaw(market, '1:10:9:1:10:10:9:11:5', 1000)
	t.eq(library.parsedByMarket[market], nil, 'not parsed before first use')
	local row, updated = library:Row(market, 1)
	t.eq(row.median, 10)
	t.eq(updated, 1000)
	t.truthy(library.parsedByMarket[market])
	t.eq(library:Row(market, 2), nil)
	local missing, reason = library:Table('forever/pvp/horde/us')
	t.eq(missing, nil)
	t.eq(reason, 'no table')
end)

t.test('the header time wins over the time given with the text', function()
	local library = PriceData.newLibrary()
	library:AddRaw('m', 'AHL1|forever/normal/alliance/us|500|1\n1:10:9:1:10:10:9:11:5', 1000)
	local _, updated = library:Row('m', 1)
	t.eq(updated, 500)
end)

t.test('a broken table is remembered as failed until replaced', function()
	local library = PriceData.newLibrary()
	library:AddRaw('m', 'garbage')
	local _, reason = library:Table('m')
	t.eq(reason, 'no rows')
	library:AddRaw('m', '1:10:9:1:10:10:9:11:5')
	t.truthy(library:Table('m'))
end)

t.group('review fixes')

t.test('extra fields after sold are allowed; an empty qty stays unknown', function()
	local items, count = PriceData.parseRows('1:10:9:1:10:10:9:11:5:42:x\n2:20:19::20:20:19:21:5')
	t.eq(count, 2)
	t.eq(items[1].median, 10)
	t.eq(items[1].sold, 0.5)
	t.eq(items[2].qty, nil)
	t.eq(items[2].median, 20)
	local _, tooShort = PriceData.parseRows('3:10:9:1:10:10:9')
	t.eq(tooShort, 0, 'seven fields is not a row')
end)

t.test('saved tables in the HagglerPriceTable shape load unchanged', function()
	local library = PriceData.newLibrary()
	local saved = {
		['forever/normal/alliance/us'] = { updated = 700, count = 1, text = '1:10:9:1:10:10:9:11:5' },
		broken = 'not a table',
	}
	t.eq(library:AddSavedTables(saved), 1)
	local row, updated = library:Row('forever/normal/alliance/us', 1)
	t.eq(row.median, 10)
	t.eq(updated, 700)
	t.eq(library:AddSavedTables(nil), 0)
end)
