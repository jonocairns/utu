-- Luacheck config: `luacheck Utu` from the repo root.
std = "lua51"
max_line_length = false
exclude_files = { "Utu/Libs/**" } -- third-party, checked upstream
-- Same exceptions as BigWigs' config: unused function arguments (WoW
-- handlers get fixed argument lists) and reusing the name `self` in
-- nested script handlers.
ignore = { "212", "432/self" }

-- Globals Utu defines (saved data, slash commands, key bindings, the
-- addon compartment, Blizzard tables it adds entries to).
globals = {
    "BINDING_HEADER_UTU", "BINDING_NAME_UTU_HELP", "BINDING_NAME_UTU_TOGGLE", "SLASH_UTU1",
    "SLASH_UTU2", "SlashCmdList", "StaticPopupDialogs", "UtuDB", "Utu_Help",
    "Utu_OnAddonCompartmentClick", "Utu_OnAddonCompartmentEnter", "Utu_OnAddonCompartmentLeave",
    "Utu_Toggle",
}

-- WoW API and Blizzard globals Utu reads.
read_globals = {
    "ACCEPT", "BackdropTemplateMixin", "CANCEL", "COMBATLOG_OBJECT_TYPE_PLAYER", "C_AddOns",
    "C_ChatInfo", "C_DeathRecap", "C_GuildInfo", "C_Map", "C_NamePlate", "C_Timer",
    "CanBeRaidTarget", "CanEditGuildInfo", "CombatLogGetCurrentEventInfo", "CreateFrame",
    "CreateVector2D", "DEFAULT_CHAT_FRAME", "Enum", "GameTooltip", "GetAddOnMetadata",
    "GetBuildInfo", "GetGuildInfo", "GetGuildInfoText", "GetGuildRosterInfo",
    "GetNormalizedRealmName", "GetNumGuildMembers", "GetRaidTargetIndex", "GetRealZoneText",
    "GetRealmName", "GetServerTime", "GetSubZoneText", "GetTime", "GuildRoster", "HideUIPanel",
    "InCombatLockdown", "InterfaceOptionsFrame", "InterfaceOptions_AddCategory", "IsInGroup",
    "IsInGuild", "IsInInstance", "IsInRaid", "IsResting", "LE_PARTY_CATEGORY_INSTANCE", "LibStub",
    "Menu", "NO", "PlaySound", "RAID_CLASS_COLORS", "RaidNotice_AddMessage", "RaidWarningFrame",
    "SendChatMessage", "SetGuildInfoText", "SetRaidTarget", "Settings", "SettingsPanel",
    "StaticPopup_Show", "TargetFrame", "TargetFramePortrait", "TooltipDataProcessor", "UIParent",
    "UISpecialFrames", "UNKNOWNOBJECT", "UnitCanAttack", "UnitClass", "UnitExists",
    "UnitFactionGroup", "UnitGUID", "UnitHealth", "UnitInParty", "UnitInRaid", "UnitIsDeadOrGhost",
    "UnitIsEnemy", "UnitIsGroupAssistant", "UnitIsGroupLeader", "UnitIsInMyGuild", "UnitIsPlayer",
    "UnitIsUnit", "UnitLevel", "UnitName", "UnitPosition", "WOW_PROJECT_CAMELOT",
    "WOW_PROJECT_CLASSIC", "WOW_PROJECT_ID", "WOW_PROJECT_MAINLINE", "YES", "bit", "debugstack",
    "geterrorhandler", "issecretvalue", "strsplit", "strtrim", "time", "tinsert", "wipe",
}
