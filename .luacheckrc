std = "lua51"
max_line_length = false
exclude_files = { "tests/" }
globals = { "HagglerDB", "SLASH_HAGGLER1", "SLASH_HAGGLER2", "SlashCmdList" }
read_globals = {
	"BagPadAPI", "ItemLocation", "DEFAULT_CHAT_FRAME",
	"AHledgerAPI", "AHledgerDB", "C_AuctionHouse", "C_Timer", "C_TradeSkillUI", "CreateFrame", "Enum",
	"GameTooltip", "GetItemInfo", "C_Item", "GetRealmName", "GetTradeSkillItemLink", "IsShiftKeyDown", "ItemRefTooltip",
	"ProfessionsFrame", "Professions", "ProfessionsRecipeListRecipeMixin", "ScrollBoxListMixin", "TooltipDataProcessor", "TradeSkillDetailScrollChildFrame", "TradeSkillFrame",
	"TradeSkillFrame_SetSelection", "TradeSkillReagentLabel", "UnitFactionGroup", "GetServerTime", "hooksecurefunc", "PostAuction", "GetAuctionSellItemInfo", "GetInboxNumItems", "GetInboxHeaderInfo", "GetInboxInvoiceInfo", "GetInboxItem", "time", "_G",
}
