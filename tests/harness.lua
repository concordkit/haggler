-- A tiny test harness for luajit: no globals, no dependencies.
local harness = { passed = 0, failed = 0, failures = {} }

local ADDON_FILES = {
	'Host/Tokens.lua',
	'Host/Bus.lua',
	'Host/Settings.lua',
	'Host/Host.lua',
	'Engine/Wow.lua',
	'Engine/ItemMarket.lua',
	'Engine/PriceData.lua',
	'Engine/Rules.lua',
	'Engine/Store.lua',
	'Engine/ScanStore.lua',
	'Engine/Sales.lua',
	'Engine/Scan.lua',
	'Engine/PriceContext.lua',
	'Engine/PriceService.lua',
	'Host/Theme.lua',
	'Host/Tooltip.lua',
	'Features/Tooltip/Lines.lua',
}

local currentGroup = ''

local function describeValue(value)
	if type(value) == 'string' then
		return string.format('%q', value)
	end
	return tostring(value)
end

local function deepEqual(a, b, path)
	if type(a) ~= type(b) then
		return false, string.format('%s: %s ~= %s', path, describeValue(a), describeValue(b))
	end
	if type(a) ~= 'table' then
		if a == b then
			return true
		end
		return false, string.format('%s: %s ~= %s', path, describeValue(a), describeValue(b))
	end
	for key, value in pairs(a) do
		local ok, why = deepEqual(value, b[key], path .. '.' .. tostring(key))
		if not ok then
			return false, why
		end
	end
	for key, value in pairs(b) do
		if a[key] == nil then
			return false, string.format('%s.%s: missing, expected %s', path, tostring(key), describeValue(value))
		end
	end
	return true
end

function harness.group(name)
	currentGroup = name
end

function harness.test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		harness.passed = harness.passed + 1
	else
		harness.failed = harness.failed + 1
		harness.failures[#harness.failures + 1] = string.format('%s > %s: %s', currentGroup, name, tostring(err))
	end
end

function harness.eq(actual, expected, what)
	if actual ~= expected then
		error(
			string.format('%s: expected %s, got %s', what or 'value', describeValue(expected), describeValue(actual)),
			2
		)
	end
end

function harness.same(actual, expected, what)
	local ok, why = deepEqual(actual, expected, what or 'value')
	if not ok then
		error(why, 2)
	end
end

function harness.truthy(value, what)
	if not value then
		error(string.format('%s: expected a truthy value, got %s', what or 'value', describeValue(value)), 2)
	end
end

function harness.raises(fn, pattern)
	local ok, err = pcall(fn)
	if ok then
		error('expected an error', 2)
	end
	if pattern and not tostring(err):find(pattern) then
		error(string.format('error %q does not match %q', tostring(err), pattern), 2)
	end
end

--- Loads the add-on's files into a fresh namespace, as the game would.
function harness.loadAddon()
	local ns = {}
	for _, path in ipairs(ADDON_FILES) do
		local chunk = assert(loadfile(path))
		chunk('Haggler', ns)
	end
	return ns
end

return harness
