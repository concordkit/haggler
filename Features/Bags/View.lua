--[[
	BagView: what bag hosts paint with. It reads a bag slot, values its stack (ns.Value through
	the getter it is given), decides the badges and paints them, and keeps the bag total spots
	current. UI-light: it only touches the buttons and font strings hosts hand it.

	  BagView.new({ wow, values, painter, icons, options, isActive, money })
	    values()   -> Value|nil      the value service (nil while it is off)
	    options()  -> { showValue, vendorBadge, showTotal }
	    isActive() -> boolean        the Bags module is on
	    money(copper) -> string
	  view:PaintSlot(button, bag, slot)
	  view:DecideItem(itemId, count, isBound) -> Decision
	  view:ClearSlot(button)
	  view:ApplyIcon(texture, badge)
	  view:ValueLabel(decision) -> string|nil   the value text with its low marker
	  view:TrackTotal(fontString, onResize?)
	  view:BagTotal() -> Total|nil
	  view:UpdateTotals()
	  view:StartPass()   a fresh price context for the next paints (prices or bags changed)

	Combat: painting is skipped while in combat lockdown and the view is marked dirty; the Bags
	module repaints when combat ends. Textures are allowed in combat, but bag updates (looting)
	are frequent there and nothing on a bag button needs to change mid-fight.
]]
local _, ns = ...

local BagView = {}
ns.BagView = BagView

BagView.TOTAL_LABEL = 'Bags'
BagView.LOW_ICON_SIZE = 12

-- Helpers live at the bottom of the file; declared here so they stay local.
local totalText

local ViewMethods = {}
ViewMethods.__index = ViewMethods

--- @param options table see the file header
--- @return table view
function BagView.new(options)
	if type(options) ~= 'table' or not options.wow or not options.painter or not options.icons then
		error('BagView.new: needs wow, painter and icons', 2)
	end
	for _, fn in ipairs({ 'values', 'options', 'isActive', 'money' }) do
		if type(options[fn]) ~= 'function' then
			error('BagView.new: needs ' .. fn, 2)
		end
	end
	return setmetatable({ deps = options, totals = {}, isDirty = false }, ViewMethods)
end

function ViewMethods:IsActive()
	return self.deps.isActive() == true and self.deps.values() ~= nil
end

--- Drops the cached price context so the next paint reads fresh prices.
function ViewMethods:StartPass()
	self.ctx = nil
end

--- The value of a stack under the default rule, or nil (no value service, a bad id).
function ViewMethods:ItemValue(itemId, count, isBound)
	local values = self.deps.values()
	if not values or type(itemId) ~= 'number' then
		return nil
	end
	self.ctx = self.ctx or values:Context()
	local stack = tonumber(count) or 1
	return values:Stack(itemId, stack >= 1 and math.floor(stack) or 1, { ctx = self.ctx, isBound = isBound })
end

--- The badges and value text for a stack.
function ViewMethods:DecideItem(itemId, count, isBound)
	return ns.Badges.decide(self:ItemValue(itemId, count, isBound), self.deps.options())
end

--- Paints one Blizzard-style item button from its bag slot. Clears it when the module is off,
--- the slot is empty or its item is not loaded yet.
function ViewMethods:PaintSlot(button, bag, slot)
	if type(button) ~= 'table' then
		return
	end
	local painter = self.deps.painter
	if not self:IsActive() then
		painter:Clear(button)
		return
	end
	if self.deps.wow:IsInCombat() then
		self.isDirty = true
		return
	end
	local item = type(bag) == 'number' and type(slot) == 'number' and self.deps.wow:ContainerItem(bag, slot) or nil
	if not item or not item.itemId then
		painter:Clear(button)
		return
	end
	painter:Paint(button, self:DecideItem(item.itemId, item.count, item.isBound))
end

--- Removes the badges and value from a button (a host showing a slot that is not the player's).
function ViewMethods:ClearSlot(button)
	if type(button) == 'table' then
		self.deps.painter:Clear(button)
	end
end

function ViewMethods:ApplyIcon(texture, badge)
	return self.deps.icons:Apply(texture, badge.icon, badge.color)
end

function ViewMethods:ValueLabel(decision)
	return ns.Badges.valueLabel(decision, self.deps.icons)
end

--- Registers a spot for the bag total; it is filled at once and on every UpdateTotals.
--- @param fontString table
--- @param onResize function|nil fun(width) for hosts that lay the spot out by its width
function ViewMethods:TrackTotal(fontString, onResize)
	self.totals[#self.totals + 1] = { text = fontString, onResize = onResize }
	self:UpdateTotals()
end

--- The value of everything in the carried bags, or nil when there is no value service.
function ViewMethods:BagTotal()
	local values = self.deps.values()
	if not values then
		return nil
	end
	self.ctx = self.ctx or values:Context()
	return values:Total(self.deps.wow:CarriedItems(), { ctx = self.ctx })
end

--- Refills every total spot (hidden when the module or the setting is off).
function ViewMethods:UpdateTotals()
	if #self.totals == 0 then
		return
	end
	local isShown = self:IsActive() and self.deps.options().showTotal == true
	if isShown and self.deps.wow:IsInCombat() then
		self.isDirty = true
		return
	end
	local text = isShown and totalText(self, self:BagTotal()) or nil
	for _, spot in ipairs(self.totals) do
		if text then
			spot.text:SetText(text)
			spot.text:Show()
		else
			spot.text:Hide()
		end
		if spot.onResize then
			spot.onResize(text and spot.text:GetStringWidth() or 0)
		end
	end
end

-- Helpers ---------------------------------------------------------------------------------

function totalText(view, total)
	if not total then
		return nil
	end
	local text = BagView.TOTAL_LABEL .. ': ' .. view.deps.money(total.copper)
	if total.confidence.level == 'low' then
		local icons = view.deps.icons
		text = text
			.. ' '
			.. icons:Inline(ns.IconSet.LOW_CONFIDENCE, BagView.LOW_ICON_SIZE, ns.IconSet.LOW_CONFIDENCE_COLOR)
	end
	return text
end

return BagView
