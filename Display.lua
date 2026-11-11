--[[
	Display: the text of the margin lines, from Pricing.recipeEconomics results.
]]
local _, ns = ...
ns = ns or {} -- tests load files without the addon table
local Pricing = ns.Pricing

local Display = {}
ns.Display = Display

-- The clock AHledger stamps its scans with.
function ns.now()
	return GetServerTime and GetServerTime() or time()
end

--- The price mode picked with /hag mode, else the default.
function ns.priceMode()
	local mode = type(HagglerDB) == "table" and HagglerDB.priceMode or nil
	return ns.isPriceMode(mode) and mode or Pricing.DEFAULT_MODE
end

--- True for one of Pricing.MODES.
function ns.isPriceMode(mode)
	for _, known in ipairs(Pricing.MODES) do
		if known == mode then
			return true
		end
	end
	return false
end

Display.MODE_LABEL = { realistic = "Realistic", median = "Median", lowest = "Lowest" }

local ACCENT = "|cff4fc3f7"
local GREY = "|cff9d9d9d"
local UP = "|cff3ddc6b"
local DOWN = "|cffff5a4f"
local RESET = "|r"

-- Margins under this percent of cost count as thin: one undercut away from a loss.
local THIN_MARGIN_PCT = 10

local SOURCE_TEXT = {
	depth = "first price with volume",
	lowest = "lowest listing, no depth known",
	median = "capped at the median",
}

--- "45 s", "12 min", "3 h", "2 d".
function Display.ageText(seconds)
	seconds = math.max(0, seconds or 0)
	if seconds < 60 then
		return string.format("%d s", seconds)
	end
	if seconds < 3600 then
		return string.format("%d min", math.floor(seconds / 60))
	end
	if seconds < 86400 then
		return string.format("%d h", math.floor(seconds / 3600))
	end
	return string.format("%d d", math.floor(seconds / 86400))
end

local function marginColour(e)
	if e.margin < 0 then
		return DOWN
	end
	if e.pct and e.pct < THIN_MARGIN_PCT then
		return GREY
	end
	return UP
end

function Display.marginText(e)
	local sign = e.margin >= 0 and "+" or "-"
	local pct = e.pct and string.format(" (%+.0f%%)", e.pct) or ""
	return marginColour(e) .. sign .. Pricing.formatMoney(math.abs(e.margin)) .. pct .. RESET
end

local function freshnessText(result)
	if not result or not result.levelsSource then
		return "AHledger table prices"
	end
	local age = Display.ageText(ns.now() - (result.levelsAt or ns.now()))
	return (result.levelsSource == "live" and "live search " or "your scan ") .. age .. " ago"
end

local function sourceText(e)
	if e.mode == "median" then
		return "AHledger's median, reagents too"
	end
	if e.sell.source == "lowest" and e.sell.skipped then
		if e.sell.skipped == 0 then
			return "lowest listing"
		end
		return string.format("lowest past %d bait unit%s", e.sell.skipped, e.sell.skipped == 1 and "" or "s")
	end
	return SOURCE_TEXT[e.sell.source] or e.sell.source
end

--- The profession window line, two rows: the numbers, then where they came from.
--- @param e table Pricing.recipeEconomics result
--- @param result table|nil Scan.lookup of the crafted item
function Display.professionText(e, result)
	local made = e.made ~= 1 and string.format(" ×%g", e.made) or ""
	local numbers = table.concat({
		ACCENT .. Display.MODE_LABEL[e.mode or "realistic"] .. RESET .. "  sells " .. Pricing.formatMoney(e.sell.unit) .. made,
		"nets " .. Pricing.formatMoney(e.proceeds),
		"margin " .. Display.marginText(e),
		"break-even " .. Pricing.formatMoney(e.breakEven),
	}, GREY .. "  ·  " .. RESET)
	local notes = { sourceText(e), freshnessText(result), "5% cut taken" }
	if e.missing > 0 then
		notes[#notes + 1] = string.format("%d reagent%s unpriced", e.missing, e.missing == 1 and "" or "s")
	end
	return numbers .. "\n" .. GREY .. table.concat(notes, " · ") .. RESET
end

--- The item tooltip line: margin per craft at the competitive price.
function Display.tooltipText(e)
	local unpriced = e.missing > 0 and (GREY .. " (reagents partly unpriced)" .. RESET) or ""
	return ACCENT
		.. Display.MODE_LABEL[e.mode or "realistic"]
		.. " craft margin "
		.. RESET
		.. Display.marginText(e)
		.. GREY
		.. " selling at "
		.. RESET
		.. Pricing.formatMoney(e.sell.unit)
		.. unpriced
end

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local function itemName(itemID)
	return (GetItemInfo and GetItemInfo(itemID)) or ("item " .. tostring(itemID))
end

local function prognosisNotes(e)
	local notes = {}
	if e.secondsToSell then
		local estimate = (e.isAheadKnown and "about " or "at least ") .. Display.ageText(e.secondsToSell)
		local basis = e.isAheadKnown and string.format(" (%d listed cheaper, if not undercut)", e.unitsAhead)
			or " (no scan: cheaper listings unknown)"
		notes[#notes + 1] = "estimated time until sold " .. estimate .. basis
	end
	if #e.shortReagents > 0 then
		local names = {}
		for i, itemID in ipairs(e.shortReagents) do
			names[i] = itemName(itemID)
		end
		notes[#notes + 1] = table.concat(names, ", ") .. ": not enough listed, the rest at the lowest price"
	end
	if e.missing > 0 then
		notes[#notes + 1] = string.format("%d reagent%s unpriced", e.missing, e.missing == 1 and "" or "s")
	end
	return notes
end

--- The prognosis block: every reagent for e.crafts crafts bought on the house, every result sold
--- at today's competitive price after the cut.
--- @param e table Pricing.recipeEconomics result for several crafts
function Display.prognosisText(e)
	local title = ACCENT
		.. "Prognosis"
		.. RESET
		.. GREY
		.. string.format("  %d crafts, every reagent bought at the auction house  ·  ", e.crafts)
		.. RESET
		.. ACCENT
		.. Display.MODE_LABEL[e.mode or "realistic"]
		.. RESET
		.. GREY
		.. ", "
		.. sourceText(e)
		.. RESET
	local numbers = table.concat({
		"buy " .. Pricing.formatMoney(e.cost),
		string.format("sell %g at %s", e.units, Pricing.formatMoney(e.sell.unit)),
		"nets " .. Pricing.formatMoney(e.proceeds),
		"profit " .. Display.marginText(e),
	}, GREY .. "  ·  " .. RESET)
	local notes = prognosisNotes(e)
	local noteText = #notes > 0 and ("\n" .. GREY .. table.concat(notes, " · ") .. RESET) or ""
	return title .. "\n" .. numbers .. noteText
end
