--[[
	Core: events and the /hag slash command.

	Haggler reads AHledger's data (its public AHledgerAPI, plus the scans and recipes it saves) and
	leaves the scanning and uploading to AHledger and AHledger sync. AHledger's own display is
	switched off once, so the two don't show the same prices twice.
]]
local _, ns = ...

local PREFIX = "|cff4fc3f7Haggler|r"
local PROFESSION_ADDONS = { Blizzard_Professions = true, Blizzard_TradeSkillUI = true }
local FIRST_SCAN_READ_DELAY_S = 5
local FLIPS_SHOWN_BY_DEFAULT = 10

-- AHledger options that only draw things. Its scanning, contributing, ledger, and the crafting
-- option (which records recipes into AHledgerDB.recipes) stay as they are.
local AHLEDGER_DISPLAY_SETTINGS = {
	"tooltip",
	"tooltipBags",
	"tooltipPvp",
	"craftDots",
	"bagDots",
	"bar",
	"minimap",
	"pulse",
	"postingHelper",
	"postingPlan",
	"ahColumn",
	"undercutCheck",
	"vendorFlips",
	"questRewards",
	"mailSummary",
	"scanSummary",
	"scanNudge",
	"siteLinks",
	"alertSound",
}

local frame = CreateFrame("Frame")
local commands = {}

ns.OnDepthReady = function()
	ns.Profession.render()
	ns.RecipeList.refresh()
	ns.BagPadSection.refresh()
end

function ns.onPriceModeChanged()
	ns.Profession.render()
	ns.RecipeList.refresh()
	ns.BagPadSection.refresh()
end

local function print(text)
	DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. " " .. text)
end

local function ensureDb()
	HagglerDB = type(HagglerDB) == "table" and HagglerDB or {}
	return HagglerDB
end

local function hookProfessionFrames()
	ns.Profession.hook()
	ns.RecipeList.hook()
end

--- Switches AHledger's display options off. Returns how many were on.
local function quietAHledger()
	local settings = AHledgerDB and AHledgerDB.settings
	if type(settings) ~= "table" then
		return 0
	end
	local switched = 0
	for _, key in ipairs(AHLEDGER_DISPLAY_SETTINGS) do
		if settings[key] ~= false then
			settings[key] = false
			switched = switched + 1
		end
	end
	return switched
end

-- Once per install, before AHledger builds its bar and hooks at PLAYER_LOGIN.
local function quietAHledgerOnce()
	local db = ensureDb()
	if db.hasQuietedAHledger then
		return
	end
	db.hasQuietedAHledger = true
	local switched = quietAHledger()
	if switched > 0 then
		print(string.format("switched off %d of AHledger's display options; it keeps scanning and syncing.", switched))
	end
end

local function onEvent(_, event, arg)
	if event == "ADDON_LOADED" and arg == "Haggler" then
		ensureDb()
		quietAHledgerOnce()
		hookProfessionFrames()
	elseif event == "ADDON_LOADED" and PROFESSION_ADDONS[arg] then
		hookProfessionFrames()
	elseif event == "PLAYER_LOGIN" then
		hookProfessionFrames()
		ns.Tooltip.hook()
		ns.Sales.hook()
		ns.BagPadSection.register()
		ns.Sales.trim()
		C_Timer.After(FIRST_SCAN_READ_DELAY_S, ns.Scan.refresh)
	elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
		ns.Scan.recordLive(arg)
	elseif event == "MODIFIER_STATE_CHANGED" then
		ns.BagPadSection.onModifier(arg)
	elseif event == "MAIL_INBOX_UPDATE" then
		ns.Sales.readInbox()
	elseif event == "AUCTION_HOUSE_CLOSED" then
		-- AHledger stores a finished scan while the house is open; read it now.
		ns.Scan.refresh()
	end
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:RegisterEvent("MAIL_INBOX_UPDATE")
frame:RegisterEvent("MODIFIER_STATE_CHANGED")
-- Classic Era has no commodity house; registering an unknown event raises an error there.
pcall(frame.RegisterEvent, frame, "COMMODITY_SEARCH_RESULTS_UPDATED")
frame:SetScript("OnEvent", function(...)
	local ok, err = pcall(onEvent, ...)
	if not ok then
		ns.lastError = err
	end
end)

-- ---------------------------------------------------------------------------------------------
-- /hag
-- ---------------------------------------------------------------------------------------------

function commands.status()
	local credit = AHledgerAPI and AHledgerAPI.CREDIT or "AHledger is not loaded"
	local dots = ns.RecipeList.isActive() and "recipe dots on" or "recipe dots off (AHledger's Profit dots are on)"
	print(string.format("%s; price mode %s; %s. %s.", ns.Scan.statusText(), ns.priceMode(), dots, credit))
	print(ns.Sales.summaryText() .. ".")
	if ns.lastError then
		print("last error: " .. tostring(ns.lastError))
	end
end

function commands.mode(arg)
	if arg == "" then
		print("price mode: " .. ns.priceMode() .. ". Choose with /hag mode " .. table.concat(ns.Pricing.MODES, " / ") .. ".")
		return
	end
	if not ns.isPriceMode(arg) then
		print("unknown mode '" .. arg .. "'. Choose " .. table.concat(ns.Pricing.MODES, " / ") .. ".")
		return
	end
	ensureDb().priceMode = arg
	ns.onPriceModeChanged()
	print("price mode: " .. arg .. ".")
end

function commands.flips(arg)
	local shown = tonumber(arg) or FLIPS_SHOWN_BY_DEFAULT
	print("reading your latest scan...")
	ns.Flips.read(function(result)
		if not result then
			print("no scan for this realm and faction yet. Scan at the auction house first.")
			return
		end
		local rows = ns.Flips.rows(result.acc, ns.Flips.minProfit(), function(id)
			local getItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
			local name, link = getItemInfo(id)
			return name, link
		end)
		local total = 0
		for _, row in ipairs(rows) do
			total = total + row.profit
		end
		local age = ns.Display.ageText(ns.now() - (result.scan.ts or ns.now()))
		print(string.format("%d under the vendor price in your scan %s ago, %s profit in all:", #rows, age, ns.Pricing.formatMoney(total)))
		for i = 1, math.min(shown, #rows) do
			local row = rows[i]
			print(string.format("  %s x%d: buy %s, vendor pays %s, +%s", row.link, row.qty, ns.Pricing.formatMoney(row.cost), ns.Pricing.formatMoney(row.vendor * row.qty), ns.Pricing.formatMoney(row.profit)))
		end
		if result.pending > 0 then
			print(string.format("%d items were still loading; run it again for them.", result.pending))
		end
	end)
end

function commands.quiet()
	print(string.format("switched off %d of AHledger's display options.", quietAHledger()))
end

function commands.help()
	print("/hag: status · /hag mode [realistic / median / lowest] · /hag flips [count] · /hag quiet (AHledger's display off again)")
end

SLASH_HAGGLER1 = "/hag"
SLASH_HAGGLER2 = "/haggler"
SlashCmdList.HAGGLER = function(input)
	local name, arg = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
	local command = commands[name ~= "" and name:lower() or "status"]
	if not command then
		commands.help()
		return
	end
	command(arg:lower())
end
