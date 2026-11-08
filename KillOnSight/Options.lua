-- Kill on Sight: personal settings. Built into the main window's Settings
-- tab; the Blizzard AddOns options page just links to it.
-- Everything here is saved for your account and never shared.
local ADDON, ns = ...
local KOS = ns.KOS

local ROW = 24

local function range(from, to, stepBy, fmt, first)
    local out = {}
    if first then out[1] = first end
    for v = from, to, stepBy do out[#out + 1] = { v, string.format(fmt, v) } end
    return out
end
KOS.Range = range

-- [-] value [+] control. `values` = { { value, label }, ... }.
-- get/set let the Officer tab reuse this for guild rules.
function KOS:Stepper(parent, text, values, x, y, get, set, width)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", x + 4, y - 5)
    fs:SetText(text)
    local minus = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    minus:SetSize(22, 20)
    minus:SetPoint("TOPLEFT", x + (width or 150), y - 1)
    minus:SetText("-")
    local val = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    val:SetPoint("LEFT", minus, "RIGHT", 4, 0)
    val:SetWidth(90)
    local plus = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    plus:SetSize(22, 20)
    plus:SetPoint("LEFT", val, "RIGHT", 4, 0)
    plus:SetText("+")
    local ctl = {}
    local function index()
        local cur = get()
        for i, v in ipairs(values) do if v[1] == cur then return i end end
        return 1
    end
    function ctl.refresh() val:SetText(values[index()][2]) end
    function ctl.setEnabled(on)
        minus:SetEnabled(on)
        plus:SetEnabled(on)
    end
    local function step(d)
        local i = math.max(1, math.min(#values, index() + d))
        set(values[i][1])
        ctl.refresh()
    end
    minus:SetScript("OnClick", function() step(-1) end)
    plus:SetScript("OnClick", function() step(1) end)
    return ctl, y - ROW - 2
end

-- Builds the settings controls into `parent`. Returns a refresh function.
function KOS:BuildSettings(parent)
    local controls = {}
    local COL1, COL2 = 12, 392

    local function header(text, x, y)
        local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        fs:SetPoint("TOPLEFT", x, y)
        fs:SetText(text)
        return y - 20
    end

    local function check(key, text, tip, x, y)
        local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
        cb:SetSize(22, 22)
        cb:SetPoint("TOPLEFT", x, y)
        local fs = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        fs:SetText(text)
        cb:SetScript("OnClick", function(self)
            KOS.S[key] = self:GetChecked() and true or false
            KOS:SettingChanged(key)
        end)
        if tip then
            cb:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(text)
                GameTooltip:AddLine(tip, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        controls[#controls + 1] = { refresh = function() cb:SetChecked(KOS.S[key]) end }
        return y - ROW + 2
    end

    local function stepper(key, text, values, x, y, onChange)
        local ctl, ny = KOS:Stepper(parent, text, values, x, y,
            function() return KOS.S[key] end,
            function(v)
                KOS.S[key] = v
                if onChange then onChange(v) end
                KOS:SettingChanged(key)
            end)
        controls[#controls + 1] = ctl
        return ny
    end

    local sub = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    sub:SetPoint("TOPLEFT", COL1, -6)
    sub:SetText("These settings only affect you. Everything your guild does is always listed in the Activity tab.")

    -- what this client allows (hover for details)
    local client = CreateFrame("Frame", nil, parent)
    client:SetPoint("TOPRIGHT", -12, -2)
    client:SetSize(200, 18)
    client:EnableMouse(true)
    local clientText = client:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    clientText:SetPoint("RIGHT")
    clientText:SetJustifyH("RIGHT")
    client:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("What this client allows")
        for _, r in ipairs(KOS:CapsSummary()) do
            GameTooltip:AddLine((r.ok and "|cff40ff40+|r " or "|cffff6060-|r ") .. r.text, 1, 1, 1, true)
        end
        GameTooltip:AddLine("Type /kos probe near an enemy player to test more.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    client:SetScript("OnLeave", function() GameTooltip:Hide() end)
    controls[#controls + 1] = { refresh = function()
        clientText:SetText(KOS.caps.combatLog and "Client: full detection"
            or "Client: no combat log |cff888888(hover)|r")
    end }

    -- column 1: alerts
    local y = -28
    y = header("Alerts", COL1, y)
    y = check("banner", "Raid-warning banner", "Big text in the middle of the screen.", COL1, y)
    y = check("chat", "Chat message", nil, COL1, y)
    y = check("flash", "Screen flash", "Pulse the screen edges red.", COL1, y)
    y = check("escalate", "Escalate for big bounties", "Extra sound and a screen flash from the level below, even if those are off.", COL1, y)
    y = check("alwaysMine", "Always alert for players I marked", "Your own grudges never go quiet, however cold their bounty gets.", COL1, y)
    y = check("quietResting", "Quiet in cities and inns", "No banner, sound or flash while resting. Sightings are still recorded and shared.", COL1, y)
    y = check("alertsInPvP", "Alerts in battlegrounds and arenas", "Off by default: everyone there is an enemy anyway. Skulls still show.", COL1, y)
    local sounds = {}
    for _, s in ipairs(KOS.SOUNDS) do sounds[#sounds + 1] = { s.key, s.name } end
    y = stepper("sound", "Sound", sounds, COL1, y, function(v) KOS:PlayAlertSound(v) end)
    y = stepper("minLevel", "Alert from bounty level", range(1, 60, 1, "Lv %d", { 0, "Any" }), COL1, y)
    y = stepper("loudLevel", "Escalate from level", range(5, 60, 5, "Lv %d"), COL1, y)
    y = stepper("cooldown", "Alert again once gone for", range(60, 900, 60, "%ds"), COL1, y)
    y = y - 4
    y = header("Detect using", COL1, y)
    y = check("srcNameplate", "Nameplates", "The main long-range source. Turn on enemy nameplates (V).", COL1, y)
    y = check("srcCombat", "Combat log", "Anyone fighting near you. Not available on WoW: Forever.", COL1, y)
    y = check("srcTarget", "Targeting", nil, COL1, y)
    y = check("srcMouseover", "Mouseover", "Can be chatty in busy places.", COL1, y)
    y = check("guildAlerts", "Skull on members of KoS guilds", nil, COL1, y)
    y = check("guildBanners", "...and banner them too", "Off by default: a KoS guild can have a lot of members.", COL1, y)

    -- column 2
    y = -28
    y = header("On screen", COL2, y)
    y = check("nameplate", "Skull and level over nameplates", nil, COL2, y)
    y = check("targetBadge", "Skull on the target frame", nil, COL2, y)
    y = check("tooltip", "Tooltip info", "Bounty, marks and notes; hunter rank on guildies.", COL2, y)
    y = check("tracker", "\"Spotted\" tracker window", "Pops up with KoS players seen in the last 5 minutes.", COL2, y)
    y = check("zoneThreat", "Zone threat warning", "When you enter a zone with KoS sightings or ganks in the last 30 minutes. Silent when it's clear.", COL2, y)
    y = check("minimap", "Minimap button", nil, COL2, y)
    y = check("raidMark", "Raid-mark KoS targets with a skull", "In raids this needs lead or assist.", COL2, y)
    y = y - 4
    y = header("Bounty game", COL2, y)
    y = check("claimKills", "Claim bounties for my kills", "Share your kills on KoS players so they score. Without a combat log, every guildie the game credits with the kill (honour) can claim it.", COL2, y)
    y = check("autoMark", "Mark players who kill me", "Open world only. Being killed again refreshes your mark. Without a combat log you pick the killer from a short list after you die.", COL2, y)
    y = y - 4
    y = header("Guild & noise", COL2, y)
    y = stepper("chatter", "Guild activity in chat",
        { { "off", "Only mine" }, { "important", "Important" }, { "all", "Everything" } }, COL2, y)
    y = stepper("helpBanner", "Help calls",
        { { "off", "Feed only" }, { "near", "Nearby" }, { "zone", "Whole zone" }, { "any", "Anywhere" } }, COL2, y)
    y = stepper("helpRange", "\"Nearby\" means within",
        { { 200, "200 yd" }, { 400, "400 yd" }, { 800, "800 yd" }, { 1500, "1500 yd" } }, COL2, y)
    y = check("announce", "Tell guildies when I spot someone", "Hidden addon message: only guildies with Kill on Sight see it.", COL2, y)
    y = check("callForHelp", "Call for help when a KoS player attacks me", "Also anyone 5+ levels above you. Guildies nearby get a banner; killing your attacker within 3 minutes earns a rescue bonus. Call by hand with /kos sos or a key binding (Key Bindings > AddOns > Kill on Sight).", COL2, y)
    y = check("partyChat", "Post sightings in party/raid chat", "Visible to your group. Max one per player every 5 minutes.", COL2, y)
    y = check("guildChat", "Post sightings in guild chat", "Visible to everyone in the guild. Max one per player every 5 minutes.", COL2, y)

    return function()
        for _, c in ipairs(controls) do c.refresh() end
    end
end

------------------------------------------------------------------------
-- Blizzard options page: a launcher for the in-window settings
------------------------------------------------------------------------

local stub = CreateFrame("Frame", "KillOnSightOptions")
stub.name = "Kill on Sight"
local title = stub:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("Kill on Sight")
local desc = stub:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
desc:SetText("Settings live in the Kill on Sight window, next to the list.")
local open = CreateFrame("Button", nil, stub, "UIPanelButtonTemplate")
open:SetSize(160, 24)
open:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -12)
open:SetText("Open settings")
open:SetScript("OnClick", function()
    if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
    if InterfaceOptionsFrame and InterfaceOptionsFrame:IsShown() then InterfaceOptionsFrame:Hide() end
    KOS:OpenSettings()
end)

KOS:On("ADDON_LOADED", function(name)
    if name ~= ADDON then return end
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local category = Settings.RegisterCanvasLayoutCategory(stub, stub.name)
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(stub)
    end
end)

function KOS:OpenSettings()
    self:ShowUI("settings")
end
