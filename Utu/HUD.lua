-- Utu: on-screen extras. Screen flash, target-frame badge,
-- "recently spotted" tracker and minimap button.
local ADDON, ns = ...
local KOS = ns.KOS
local SKULL = KOS.SKULL

local function tierRGB(T) return KOS:BountyRGB(T) end

------------------------------------------------------------------------
-- Screen flash (red vignette pulse)
------------------------------------------------------------------------

local flash
function KOS:Flash(loud)
    if not flash then
        flash = CreateFrame("Frame", nil, UIParent)
        flash:SetAllPoints(UIParent)
        flash:SetFrameStrata("FULLSCREEN_DIALOG")
        local tex = flash:CreateTexture(nil, "BACKGROUND")
        tex:SetAllPoints()
        tex:SetTexture("Interface\\FullScreenTextures\\LowHealth")
        tex:SetBlendMode("ADD")
        flash:Hide()
        flash:SetScript("OnUpdate", function(self, dt)
            self.t = self.t + dt
            if self.t >= self.dur then self:Hide(); return end
            self:SetAlpha(math.abs(math.sin(self.t / self.dur * math.pi * self.pulses)))
        end)
    end
    flash.t, flash.dur, flash.pulses = 0, loud and 2.4 or 1.2, loud and 4 or 2
    flash:SetAlpha(0)
    flash:Show()
end

------------------------------------------------------------------------
-- Target frame badge: skull + weight on the portrait
------------------------------------------------------------------------

local badge
local function ensureBadge()
    if badge or not TargetFrame then return badge end
    local portrait = TargetFramePortrait
        or (TargetFrame.TargetFrameContainer and TargetFrame.TargetFrameContainer.Portrait)
        or TargetFrame
    badge = CreateFrame("Frame", nil, TargetFrame)
    badge:SetSize(26, 26)
    badge:SetPoint("CENTER", portrait, "TOPRIGHT", -6, -6)
    badge:SetFrameLevel(TargetFrame:GetFrameLevel() + 10)
    badge.icon = badge:CreateTexture(nil, "OVERLAY")
    badge.icon:SetAllPoints()
    badge.icon:SetTexture(SKULL)
    badge.text = badge:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    badge.text:SetPoint("BOTTOMRIGHT", 6, -2)
    badge:EnableMouse(true)
    badge:SetScript("OnEnter", function(self)
        local T = self.T
        if not T then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if T.virtual then
            GameTooltip:AddLine("Member of KoS guild <" .. T.guild .. ">")
        else
            GameTooltip:AddLine(KOS:Display(T.n) .. " - " .. KOS:BountyTag(T))
            for _, v in ipairs(KOS:ActiveVotes(T)) do
                GameTooltip:AddLine((v.note ~= "" and v.note or "marked") .. " - " .. KOS:Display(v.by), 1, 1, 1, true)
            end
            GameTooltip:AddLine("Worth " .. (KOS:ClaimValue(T)) .. " points to you", 1, 0.82, 0)
        end
        GameTooltip:Show()
    end)
    badge:SetScript("OnLeave", function() GameTooltip:Hide() end)
    badge:Hide()
    return badge
end

function KOS:RefreshTargetBadge()
    local b = ensureBadge()
    if not b then return end
    local T = self.S.targetBadge and self:ResolveUnit("target")
    b.T = T
    if T then
        b.icon:SetVertexColor(tierRGB(T))
        local lvl = T.virtual and 0 or KOS:LevelOf(T)
        b.text:SetText(lvl > 0 and lvl or "")
        b:Show()
    else
        b:Hide()
    end
end

------------------------------------------------------------------------
-- Spotted tracker: KoS players seen in the last few minutes (by you or
-- guildies). Pops up on a sighting, hides itself when the list empties.
------------------------------------------------------------------------

local TRACK_SECONDS = 300
local snoozeUntil = 0 -- closing the tracker snoozes it
local MAX_ROWS = 8
local recent = {} -- key -> { T, at, by, zone }
local tracker

local function buildTracker()
    tracker = CreateFrame("Frame", "UtuTracker", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    tracker:SetSize(280, 40)
    local pos = KOS.S.trackerPos
    if pos then tracker:SetPoint(pos[1], UIParent, pos[1], pos[2], pos[3])
    else tracker:SetPoint("RIGHT", UIParent, "RIGHT", -220, 120) end
    if tracker.SetBackdrop then
        tracker:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        tracker:SetBackdropColor(0.05, 0, 0, 0.8)
        tracker:SetBackdropBorderColor(0.8, 0.1, 0.1)
    end
    tracker:SetMovable(true)
    tracker:EnableMouse(true)
    tracker:SetClampedToScreen(true)
    tracker:RegisterForDrag("LeftButton")
    tracker:SetScript("OnDragStart", tracker.StartMoving)
    tracker:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        KOS.S.trackerPos = { point, x, y }
    end)

    tracker.title = tracker:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tracker.title:SetPoint("TOPLEFT", 8, -7)
    tracker.title:SetText("|T" .. SKULL .. ":12|t Utu - spotted")

    local close = CreateFrame("Button", nil, tracker, "UIPanelCloseButton")
    close:SetSize(20, 20)
    close:SetPoint("TOPRIGHT", 1, 1)
    close:SetScript("OnClick", function()
        snoozeUntil = GetTime() + 900 -- closing snoozes it for 15 minutes
        tracker:Hide()
    end)

    tracker.rows = {}
    for i = 1, MAX_ROWS do
        local fs = tracker:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", 8, -8 - i * 14)
        fs:SetPoint("RIGHT", -8, 0)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        tracker.rows[i] = fs
    end

    local acc = 0
    tracker:SetScript("OnUpdate", function(_, dt)
        acc = acc + dt
        if acc >= 1 then acc = 0; KOS:RefreshTracker() end
    end)
    tracker:Hide()
end

function KOS:TrackSighting(T, by, zone)
    if not self.S.tracker then return end
    if IsInRaid() or not self:InWorld() then return end -- raids and BGs: you can see them
    recent[self:Canonical(T.n)] = { T = T, at = GetTime(), by = by, zone = zone }
    self:RefreshTracker()
end

function KOS:RefreshTracker()
    local now = GetTime()
    local list = {}
    for k, r in pairs(recent) do
        if now - r.at > TRACK_SECONDS then recent[k] = nil else list[#list + 1] = r end
    end
    if not self.S.tracker or #list == 0 or GetTime() < snoozeUntil or IsInRaid() or not self:InWorld() then
        if tracker then tracker:Hide() end
        return
    end
    if not tracker then buildTracker() end
    table.sort(list, function(a, b) return a.at > b.at end)
    for i = 1, MAX_ROWS do
        local fs, r = tracker.rows[i], list[i]
        if r then
            local cr, cg, cb = tierRGB(r.T)
            local w = r.T.virtual and "" or (" Lv " .. KOS:LevelOf(r.T))
            local ago = math.floor(now - r.at)
            local by = (r.by ~= self:MyName()) and (" |cff888888(" .. self:Display(r.by) .. ")|r") or ""
            fs:SetText(string.format("|cff%02x%02x%02x%s%s|r  |cffaaaaaa%ds|r  %s%s",
                cr * 255, cg * 255, cb * 255, self:Display(r.T.n), w, ago, r.zone or "", by))
            fs:Show()
        else
            fs:Hide()
        end
    end
    tracker:SetHeight(16 + math.min(#list, MAX_ROWS) * 14 + 10)
    tracker:Show()
end

------------------------------------------------------------------------
-- Toasts: a small framed message under the top of the screen that fades
-- out on its own. Used for zone threat and help prompts.
------------------------------------------------------------------------

local function makeToast(name, y)
    local t = CreateFrame("Frame", name, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    t:SetSize(420, 44)
    t:SetPoint("TOP", UIParent, "TOP", 0, y)
    t:SetFrameStrata("HIGH")
    if t.SetBackdrop then
        t:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1,
        })
        t:SetBackdropColor(0.05, 0.05, 0.06, 0.88)
        t:SetBackdropBorderColor(0, 0, 0, 1)
    end
    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.icon:SetTexture(SKULL)
    t.icon:SetSize(18, 18)
    t.icon:SetPoint("LEFT", 10, 0)
    t.text = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t.text:SetPoint("LEFT", t.icon, "RIGHT", 8, 0)
    t.text:SetPoint("RIGHT", -10, 0)
    t.text:SetJustifyH("LEFT")
    t:Hide()
    t:SetScript("OnUpdate", function(self, dt)
        self.left = self.left - dt
        if self.left <= 0 then self:Hide()
        elseif self.left < 1 then self:SetAlpha(self.left) end
    end)
    function t:Pop(text, seconds)
        self.text:SetText(text)
        self.left = seconds
        self:SetAlpha(1)
        self:Show()
    end
    return t
end

------------------------------------------------------------------------
-- Zone threat: a toast when you enter a zone with recent KoS activity.
-- Silent when the zone is clear; doesn't repeat for the same zone within
-- 10 minutes unless the threat got worse.
------------------------------------------------------------------------

local threatToast
local lastThreat = {} -- zone -> { at, score }

function KOS:CheckZoneThreat()
    if not self.S.zoneThreat or not self:InWorld() then return end
    local r = self:ZoneThreat()
    if r.level == 0 then return end
    local prev = lastThreat[r.zone]
    if prev and GetTime() - prev.at < 600 and r.score <= prev.score then return end
    lastThreat[r.zone] = { at = GetTime(), score = r.score }
    if not threatToast then threatToast = makeToast("UtuThreat", -120) end
    threatToast.icon:SetVertexColor(1, r.level >= 2 and 0.3 or 0.82, 0.2)
    threatToast:Pop(self:ThreatText(r), 9)
    self:Notify("nearby", self:ThreatText(r))
end

KOS:On("ZONE_CHANGED_NEW_AREA", function()
    C_Timer.After(2, function() KOS:CheckZoneThreat() end) -- zone text settles after the event
end)

------------------------------------------------------------------------
-- Help prompt: "HELP! Carol is being ganked by X - 180 yd NE" with an
-- "On my way" button. Shown only for calls that pass your help-banner
-- setting (by default: within 400 yards).
------------------------------------------------------------------------

local helpPrompt
local function buildHelpPrompt()
    helpPrompt = makeToast("UtuHelp", -170)
    helpPrompt:SetSize(440, 56)
    helpPrompt:EnableMouse(true)
    helpPrompt.text:ClearAllPoints()
    helpPrompt.text:SetPoint("TOPLEFT", helpPrompt.icon, "TOPRIGHT", 8, 6)
    helpPrompt.text:SetPoint("RIGHT", -10, 0)
    helpPrompt.sub = helpPrompt:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    helpPrompt.sub:SetPoint("BOTTOMLEFT", helpPrompt.icon, "BOTTOMRIGHT", 8, -10)
    helpPrompt.go = CreateFrame("Button", nil, helpPrompt, "UIPanelButtonTemplate")
    helpPrompt.go:SetSize(96, 22)
    helpPrompt.go:SetPoint("BOTTOMRIGHT", -36, 6)
    helpPrompt.go:SetText("On my way")
    helpPrompt.go:SetScript("OnClick", function(self)
        KOS:Respond(helpPrompt.attacker)
        self:Disable()
        self:SetText("Going")
        helpPrompt.left = math.max(helpPrompt.left, 20)
    end)
    local close = CreateFrame("Button", nil, helpPrompt, "UIPanelCloseButton")
    close:SetSize(22, 22)
    close:SetPoint("BOTTOMRIGHT", -8, 6)
    close:SetScript("OnClick", function() helpPrompt:Hide() end)
end

function KOS:ShowHelpPrompt(attackerFull, victimFull, where, T)
    if not helpPrompt then buildHelpPrompt() end
    helpPrompt.attacker, helpPrompt.victim, helpPrompt.responders = attackerFull, victimFull, 0
    helpPrompt.icon:SetVertexColor(0.25, 0.75, 1)
    helpPrompt.go:Enable()
    helpPrompt.go:SetText("On my way")
    helpPrompt.sub:SetText(T and ("Worth " .. (self:ClaimValue(T)) .. " pts, +50% rescue") or "Defend them: +" .. self.DEFENSE_POINTS .. " pts")
    helpPrompt:Pop("|cff40c0ffHELP!|r " .. self:Display(victimFull) .. " is being ganked by |cffff6060"
        .. self:Display(attackerFull) .. "|r - " .. where, 30)
end

-- Someone answered a call. For the caller: a toast. For other helpers: a
-- count on the open prompt.
function KOS:OnResponder(who, yards, forOthers)
    if forOthers then
        if helpPrompt and helpPrompt:IsShown() then
            helpPrompt.responders = (helpPrompt.responders or 0) + 1
            helpPrompt.sub:SetText(helpPrompt.responders .. (helpPrompt.responders == 1 and " guildie" or " guildies") .. " heading there")
        end
        return
    end
    if not threatToast then threatToast = makeToast("UtuThreat", -120) end
    threatToast.icon:SetVertexColor(0.25, 0.75, 1)
    threatToast:Pop("|cff40c0ff" .. who .. " is on the way|r" .. (yards and (" - " .. yards .. " yd out") or ""), 6)
end

------------------------------------------------------------------------
-- Death prompt: without a combat log we can't tell who landed the killing
-- blow, so after you die we list the enemy players who were on you and
-- you pick. Each pick records a gank for the guild and marks them; in a
-- group gank you can pick several.
------------------------------------------------------------------------

local deathPrompt
local function buildDeathPrompt()
    deathPrompt = makeToast("UtuDeath", -220)
    deathPrompt:SetSize(500, 64)
    deathPrompt:EnableMouse(true)
    deathPrompt.icon:SetVertexColor(1, 0.3, 0.2)
    deathPrompt.text:ClearAllPoints()
    deathPrompt.text:SetPoint("TOPLEFT", deathPrompt.icon, "TOPRIGHT", 8, 8)
    deathPrompt.text:SetPoint("RIGHT", -10, 0)
    deathPrompt.buttons = {}
    for i = 1, 3 do
        local b = CreateFrame("Button", nil, deathPrompt, "UIPanelButtonTemplate")
        b:SetSize(116, 22)
        b:SetPoint("BOTTOMLEFT", 36 + (i - 1) * 120, 8) -- third ends at 388; "None" starts at 422
        b:SetScript("OnClick", function(self)
            KOS:ConfirmKiller(self.cand, deathPrompt.at, deathPrompt.zone)
            self:Disable()
            self:SetText("Marked")
            deathPrompt.done:SetText("Done")
            deathPrompt.left = math.max(deathPrompt.left or 0, 30)
            -- nobody left to pick: close
            for _, other in ipairs(deathPrompt.buttons) do
                if other:IsShown() and other:IsEnabled() then return end
            end
            deathPrompt:Hide()
        end)
        b:SetScript("OnEnter", function(self)
            local c = self.cand
            if not c then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(KOS:Display(c.full))
            if c.level then GameTooltip:AddLine("Level " .. c.level, 1, 1, 1) end
            if c.T then GameTooltip:AddLine("Already on the list: " .. KOS:BountyTag(c.T), 1, 1, 1) end
            if c.why then GameTooltip:AddLine("From the " .. c.why, 0.6, 0.6, 0.6) end
            GameTooltip:AddLine("Records the gank for your guild" .. (KOS.S.autoMark and " and marks them." or "."), 0.6, 0.6, 0.6, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        deathPrompt.buttons[i] = b
    end
    local none = CreateFrame("Button", nil, deathPrompt, "UIPanelButtonTemplate")
    none:SetSize(70, 22)
    none:SetPoint("BOTTOMRIGHT", -8, 8)
    none:SetText("None")
    none:SetScript("OnClick", function() deathPrompt:Hide() end)
    deathPrompt.done = none
end

function KOS:ShowDeathPrompt(cands, at, zone)
    if not deathPrompt then buildDeathPrompt() end
    deathPrompt.at, deathPrompt.zone = at, zone
    deathPrompt.done:SetText("None")
    for i, b in ipairs(deathPrompt.buttons) do
        local c = cands[i]
        b.cand = c
        b:Enable()
        if c then
            local label = self:Display(c.full)
            if #label > 14 then label = self.Utf8Truncate(label, 13) .. "..." end
            b:SetText(label .. (c.level and (" " .. c.level) or ""))
            b:Show()
        else
            b:Hide()
        end
    end
    deathPrompt:Pop("|cffff6060Killed by enemy players?|r Pick everyone who was in on it:", 120)
end

------------------------------------------------------------------------
-- Minimap button (drag around the rim; left = list, right = settings)
------------------------------------------------------------------------

local mmButton
local function positionButton()
    local a = math.rad(KOS.S.minimapAngle or 200)
    local r = (Minimap:GetWidth() / 2) + 10
    mmButton:ClearAllPoints()
    mmButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

local function createMinimapButton()
    if mmButton or not Minimap then return end
    mmButton = CreateFrame("Button", "UtuMinimapButton", Minimap)
    mmButton:SetSize(31, 31)
    -- Pin the strata and level: modern minimaps re-layer their children,
    -- which can leave the button drawn but under a frame that eats clicks.
    mmButton:SetFrameStrata("MEDIUM")
    if mmButton.SetFixedFrameStrata then mmButton:SetFixedFrameStrata(true) end
    mmButton:SetFrameLevel(8)
    if mmButton.SetFixedFrameLevel then mmButton:SetFixedFrameLevel(true) end
    mmButton:EnableMouse(true)
    mmButton:RegisterForClicks("AnyUp")
    mmButton:RegisterForDrag("LeftButton")
    mmButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = mmButton:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("TOPLEFT", 7, -5)
    local icon = mmButton:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture(SKULL)
    icon:SetPoint("TOPLEFT", 7, -6)
    local border = mmButton:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    mmButton:SetScript("OnClick", function(_, button)
        if button == "RightButton" then KOS:OpenSettings() else KOS:ToggleUI() end
    end)
    mmButton:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local s = Minimap:GetEffectiveScale()
            KOS.S.minimapAngle = math.deg(math.atan2(cy / s - my, cx / s - mx))
            positionButton()
        end)
    end)
    mmButton:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    mmButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Utu")
        local pts = KOS:PointsOf(KOS:MyName())
        GameTooltip:AddLine("You: " .. KOS.RankTag(pts) .. " (" .. pts .. " pts)", 1, 1, 1)
        local r = KOS:ZoneThreat()
        GameTooltip:AddLine((GetRealZoneText() or "") .. ": |c" .. r.color .. r.label .. "|r", 1, 1, 1)
        GameTooltip:AddLine("Left-click: list   Right-click: settings", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    mmButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    positionButton()
end

function KOS:UpdateMinimapButton()
    if self.S.minimap then
        createMinimapButton()
        if mmButton then mmButton:Show() end
    elseif mmButton then
        mmButton:Hide()
    end
end

KOS:On("PLAYER_LOGIN", function() KOS:UpdateMinimapButton() end)
