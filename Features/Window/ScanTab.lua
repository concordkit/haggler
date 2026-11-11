--[[
	Scan tab: what the scanner is doing, when the last full scan was and when the next request
	is allowed (the shared 15-minute window), with a button that asks for a scan at the auction
	house.
]]
local _, ns = ...

-- Helpers live at the bottom of the file; declared here so they stay local.
local requestScan

ns.window:AddTab({
	key = 'scan',
	label = 'Scan',
	order = 10,
	build = function(container, ctx)
		local caption = ctx.ui:Text(container, 12, 'color.text.muted')
		caption:SetPoint('TOPLEFT', container, 'TOPLEFT')
		caption:SetText('AUCTION HOUSE SCAN')
		local body = ctx.wow:CreateFrame('Frame', container)
		body:SetPoint('TOPLEFT', caption, 'BOTTOMLEFT', 0, -16)
		body:SetSize(600, 140)
		container.lines = ctx.ui:Lines(body, 6, 14)
		local scanButton = ctx.ui:Button(container, 'Scan now', 'primary')
		scanButton:SetPoint('TOPLEFT', body, 'BOTTOMLEFT', 0, -16)
		scanButton:OnClick(function()
			requestScan(ctx)
		end)
		container.scanButton = scanButton
		local refreshButton = ctx.ui:Button(container, 'Refresh', 'secondary')
		refreshButton:SetPoint('LEFT', scanButton, 'RIGHT', 8, 0)
		refreshButton:OnClick(function()
			ctx.window:Refresh()
		end)
	end,
	refresh = function(container, ctx)
		local lines = {}
		for _, text in ipairs(ns.scanControl.StatusLines()) do
			lines[#lines + 1] = { text = text }
		end
		container.lines:SetLines(lines)
		container.scanButton:SetEnabled(ctx.window:IsAtAuctionHouse())
	end,
})

-- Helpers ---------------------------------------------------------------------------------

function requestScan(ctx)
	local isRequested, reason = ns.scanControl.RequestNow()
	ctx.setStatus(isRequested and 'Scan requested.' or ('No scan requested: ' .. tostring(reason) .. '.'))
	ctx.window:Refresh()
end
