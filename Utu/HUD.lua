-- Utu: on-screen extras. Screen flash, target-frame badge,
-- "recently spotted" tracker and minimap button.
local _, ns = ...
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
    if T and self:OnlyMutedMarks(T) then T = nil end
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
    if t.text.SetMaxLines then t.text:SetMaxLines(2) end -- the box fits two lines
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
    helpPrompt:SetSize(440, 64)
    helpPrompt:EnableMouse(true)
    -- headline (up to two lines) on top, worth line and buttons below it
    helpPrompt.icon:ClearAllPoints()
    helpPrompt.icon:SetPoint("TOPLEFT", 10, -9)
    helpPrompt.text:ClearAllPoints()
    helpPrompt.text:SetPoint("TOPLEFT", 36, -9)
    helpPrompt.text:SetPoint("RIGHT", -10, 0)
    helpPrompt.go = CreateFrame("Button", nil, helpPrompt, "UIPanelButtonTemplate")
    helpPrompt.go:SetSize(96, 22)
    helpPrompt.go:SetPoint("BOTTOMRIGHT", -36, 6)
    helpPrompt.sub = helpPrompt:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    helpPrompt.sub:SetPoint("BOTTOMLEFT", 36, 11)
    helpPrompt.sub:SetPoint("RIGHT", helpPrompt.go, "LEFT", -8, 0)
    helpPrompt.sub:SetJustifyH("LEFT")
    helpPrompt.sub:SetWordWrap(false)
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

-- verb: " is being ganked by " (default), " is under attack, likely by "
-- (a guess from who was targeting them) or " needs help against " (manual).
function KOS:ShowHelpPrompt(attackerFull, victimFull, where, T, verb)
    if not helpPrompt then buildHelpPrompt() end
    helpPrompt.attacker, helpPrompt.victim, helpPrompt.responders = attackerFull, victimFull, 0
    helpPrompt.icon:SetVertexColor(0.25, 0.75, 1)
    helpPrompt.go:Enable()
    helpPrompt.go:SetText("On my way")
    helpPrompt.sub:SetText(T and ("Worth " .. (self:ClaimValue(T)) .. " pts, +50% rescue") or "Defend them: +" .. self.DEFENSE_POINTS .. " pts")
    helpPrompt:Pop("|cff40c0ffHELP!|r " .. self:Display(victimFull) .. (verb or " is being ganked by ") .. "|cffff6060"
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
-- Death recap actions are staged locally for five seconds before any writes.
local deathPrompt, deathReceipt
local queuedDeaths = {}
local redrawDeath
local DEATH_UNDO = 5
local receiptError

local function deathText(parent, width, font)
    local label = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    label:SetWidth(width)
    label:SetWordWrap(false)
    label:SetJustifyH("LEFT")
    return label
end

local function deathButton(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 25)
    b:SetText(text)
    local label = b:GetFontString()
    if label then label:SetWidth(width - 8); label:SetWordWrap(false) end
    b:SetScript("OnClick", onClick)
    return b
end

local function deathChoiceButton(parent, text, primary, onClick)
    local b = CreateFrame("Button", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    b:SetSize(254, 25)
    if b.SetBackdrop then
        b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        if primary then b:SetBackdropColor(0.43, 0.16, 0.19, 1)
        else b:SetBackdropColor(0.18, 0.14, 0.13, 1) end
        b:SetBackdropBorderColor(0.61, 0.44, 0.32, 1)
    end
    local hover = b:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(1, 0.80, 0.65, 0.14)
    b:SetNormalFontObject("GameFontHighlight")
    b:SetDisabledFontObject("GameFontDisable")
    b:SetText(text)
    local label = b:GetFontString()
    if label then label:SetWidth(246); label:SetWordWrap(false) end
    b:SetScript("OnClick", onClick)
    return b
end

local function pendingDeaths()
    local count, deadline, guild, private = 0, nil, false, false
    for _, batch in ipairs(queuedDeaths) do
        for _, action in ipairs(batch.actions) do
            if action.c.pending == action then
                count = count + 1
                deadline = not deadline and batch.deadline or math.min(deadline, batch.deadline)
                if action.share and batch.session.guild then guild = true else private = true end
            end
        end
    end
    return count, deadline, guild, private
end

local function closeDeathPrompt()
    local session = deathPrompt.session
    if session then KOS:SettleMyDeath(session.at) end
    deathPrompt.session = false
    deathPrompt.note:ClearFocus()
    deathPrompt:Hide()
end

local function updateDeathReceipt()
    local count, deadline, guild, private = pendingDeaths()
    if count == 0 then
        if not receiptError or GetTime() >= receiptError.untilAt then
            receiptError = nil
            deathReceipt:Hide()
            return
        end
        deathReceipt.text:SetText(receiptError.text)
        deathReceipt.undo:SetText("Dismiss")
        deathReceipt:Show()
        return
    end
    deathReceipt.undo:SetText("Undo pending")
    local action = guild and (private and "Next action" or "Shares with guild") or "Applies privately"
    local message = string.format("%d pending · %s in %ds", count, action,
        math.max(0, math.ceil(deadline - GetTime())))
    deathReceipt.text:SetText(message)
    if not deathReceipt:IsShown() then deathReceipt:Show() end
end

local function undoDeath(action)
    if action.c.pending ~= action or GetTime() - action.queuedAt < 0.3 then return end
    action.c.pending = nil
    action.c.status = nil
    action.c.readyAt = GetTime() + 0.3
end

local function undoDeaths()
    receiptError = nil
    for _, batch in ipairs(queuedDeaths) do
        for _, action in ipairs(batch.actions) do undoDeath(action) end
    end
    redrawDeath()
end

local function checkDeathWrites(session)
    return session.listKey and session.listKey == KOS:ListKey() and KOS:InWorld()
end

local function commitDeaths(batch)
    local session, note = batch.session, batch.note
    for _, action in ipairs(batch.actions) do
        local c = action.c
        if c.pending == action then
            c.pending = nil
            local marked, reported, failed
            if action.share then
                if not checkDeathWrites(session) then
                    failed = "Guild list unavailable"
                elseif action.mark and not KOS:CanMark(KOS:MyName()) then
                    failed = "Guild rank cannot mark"
                elseif action.mark then
                    if action.manual then
                        local vote = KOS:MyVote(KOS:GetTarget(KOS:Canonical(c.full)))
                        marked = KOS:Mark(c.full, vote and vote.note or "", c.guid, c.class)
                    else
                        marked = KOS:AutoMark(c.full, c.guid, c.class, session.zone, nil, true)
                    end
                    if not marked then failed = "Mark could not be saved" end
                end
                if not failed and not action.manual then
                    reported = KOS:RecordDeath(c.full, session.zone, session.at, note)
                    KOS:NoteMyDeath(c.full, session.at)
                    if reported then note = nil end
                end
            end
            if not failed and action.hate then KOS:SetHated(c.full, true, c.guid) end
            c.applied = not failed
            local status = marked and (action.refresh and "Mark refreshed" or "Marked") or
                (reported and "Death reported" or (action.share and "Recent report skipped"))
            if action.hate then status = status and (status .. " · Hated") or "Hated privately" end
            c.status = failed or status
            if failed then
                receiptError = { text = "Could not save · " .. failed, untilAt = GetTime() + 12 }
                KOS:Print("Could not apply choices for " .. KOS:Display(c.full) .. ". " .. failed .. ".")
            end
        end
    end
    for i, queued in ipairs(queuedDeaths) do
        if queued == batch then table.remove(queuedDeaths, i); break end
    end
    redrawDeath()
end

local function deathQueued(c)
    local key = KOS:Canonical(c.full)
    for _, batch in ipairs(queuedDeaths) do
        for _, action in ipairs(batch.actions) do
            if action.c.pending == action and KOS:Canonical(action.c.full) == key then return true end
        end
    end
end

local function deathChoice(c, session, manual)
    if c.applied or deathQueued(c) or (c.readyAt and GetTime() < c.readyAt) then return end
    local share = manual or (c.why == "death recap" and c.marked)
    if not share and not c.hated then return end
    return { c = c, share = share, manual = manual, mark = manual or (share and session.canMark),
        hate = c.hated or false, refresh = c.ownMark }
end

local function stageDeaths(session, manual)
    if deathPrompt.session ~= session then return end
    local actions = {}
    for _, c in ipairs(session.cands) do
        if not manual or manual == c then
            local action = deathChoice(c, session, manual ~= nil)
            if action then actions[#actions + 1] = action end
        end
    end
    if #actions == 0 then return end
    local now = GetTime()
    for _, action in ipairs(actions) do
        action.queuedAt = now
        action.c.pending = action
        action.c.status = action.share and "Guild action pending" or "Private Hate pending"
    end
    local batch = { actions = actions, session = session, deadline = now + DEATH_UNDO,
        note = session.guild and not manual and KOS.CleanText(deathPrompt.note:GetText(), KOS.ENCOUNTER_NOTE_MAX) or nil }
    queuedDeaths[#queuedDeaths + 1] = batch
    C_Timer.After(DEATH_UNDO, function() commitDeaths(batch) end)
    if not manual then closeDeathPrompt() else deathPrompt.note:ClearFocus() end
    redrawDeath()
end

local function deathCheck(parent, text, x, changed)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetSize(22, 22)
    check:SetPoint("LEFT", x, 0)
    local label = deathText(parent, 42)
    label:SetText(text)
    label:SetPoint("LEFT", check, "RIGHT", 1, 0)
    check.label = label
    check:SetScript("OnClick", function(self)
        changed(self:GetChecked() and true or false)
        redrawDeath()
    end)
    return check
end

local function buildDeathRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(478, 38)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * 38)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.04 or 0.015)
    row:EnableMouse(true)
    row.name = deathText(row, 150, "GameFontHighlight")
    row.name:SetPoint("LEFT", 5, 0)
    row.details = deathText(row, 142)
    row.details:SetPoint("LEFT", 159, 0)
    row.details:SetJustifyH("RIGHT")
    row.mark = deathCheck(row, "Mark", 312, function(on) row.c.marked = on end)
    row.hate = deathCheck(row, "Hate", 370, function(on) row.c.hated = on end)
    row.manual = deathButton(row, "Mark anyway", 84, function() stageDeaths(deathPrompt.session, row.c) end)
    row.manual:SetPoint("RIGHT", -1, 0)
    row.undo = deathButton(row, "Undo", 59, function()
        if row.c.pending then undoDeath(row.c.pending); redrawDeath() end
    end)
    row.undo:SetPoint("RIGHT", -3, 0)
    row.status = deathText(row, 108)
    row.status:SetPoint("LEFT", 307, 0)
    row:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(KOS:Display(self.c.full))
        if self.c.status then GameTooltip:AddLine(self.c.status, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function paintDeathRow(row, c, session, canShare, queued)
    row.c = c
    row.name:SetText(KOS:Display(c.full))
    local class = c.class or (c.T and c.T.class)
    local role = c.kb and "Killing blow" or c.why == "death recap" and "Damaged you"
        or (c.seenAgo and ("Seen " .. c.seenAgo .. "s ago") or "Seen nearby")
    local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    local tag = class and (class:sub(1, 1) .. class:sub(2):lower()) or nil
    if tag and color then
        tag = string.format("|cff%02x%02x%02x%s|r", color.r * 255, color.g * 255, color.b * 255, tag)
    end
    if c.ownMark then row.name:SetText(KOS:Display(c.full) .. " (marked)") end
    row.details:SetText(tag and (tag .. " · " .. role) or role)
    local open = not queued and not c.applied
    local verified = c.why == "death recap"
    row.mark:SetShown(open and verified and canShare)
    row.mark.label:SetShown(open and verified and canShare)
    row.mark.label:SetText(session.canMark and "Mark" or "Report")
    row.mark:SetChecked(c.marked)
    row.hate:ClearAllPoints()
    row.hate:SetPoint("LEFT", verified and 370 or 307, 0)
    row.hate:SetShown(open)
    row.hate.label:SetShown(open)
    row.hate:SetChecked(c.hated)
    row.manual:SetShown(open and not verified and canShare and session.canMark)
    row.manual:SetText(c.hated and "Mark + Hate" or "Mark anyway")
    row.undo:SetShown(c.pending ~= nil)
    row.status:SetText(c.status or (queued and "Earlier choice pending" or ""))
    row.status:SetShown(not open)
    row:Show()
end

redrawDeath = function()
    updateDeathReceipt()
    local p, session = deathPrompt, deathPrompt.session
    if not session then return end
    local marks, refreshes, hates, verified, remaining, pending = 0, 0, 0, 0, 0, 0
    local canShare = checkDeathWrites(session)
    for i, c in ipairs(session.cands) do
        local queued = deathQueued(c)
        if queued then pending = pending + 1 end
        if not c.applied and not queued then
            remaining = remaining + 1
            if c.why == "death recap" then
                verified = verified + 1
                if c.marked and canShare then
                    marks = marks + 1
                    if c.ownMark and session.canMark then refreshes = refreshes + 1 end
                end
            end
            if c.hated then hates = hates + 1 end
        end
        if session.expanded then
            local row = p.rows[i] or buildDeathRow(p.content, i)
            p.rows[i] = row
            paintDeathRow(row, c, session, canShare, queued)
        end
    end
    for i = #session.cands + 1, #p.rows do p.rows[i]:Hide() end
    local n = #session.cands
    local title = session.nearby and "Nearby players" or (n == 1 and session.cands[1].kb and
        ("Killed by " .. KOS:Display(session.cands[1].full)) or "Death recap")
    p.text:SetText(title)
    p.hint:SetText(session.nearby and "Involvement unverified. Hate stays private." or
        (not session.guild and "Marks, death history and Hate stay on your personal list."
            or (session.canMark and "Marks and death reports go to your guild. Hate stays private."
                or "Death reports go to your guild. Hate stays private.")))
    p.review:SetText((session.expanded and "Hide " or "Review ") .. n .. (n == 1 and " player" or " players"))
    p.scroll:SetShown(session.expanded)
    local drawerHeight = math.min(n, 4) * 38
    p.content:SetHeight(n * 38)
    p.scroll:SetHeight(drawerHeight)
    local noteShown = session.guild and session.expanded and marks > 0
    p.note:SetShown(noteShown)
    p.noteLabel:SetShown(noteShown)
    local summary = {}
    local new = marks - refreshes
    if new > 0 then
        local noun = session.canMark and " new mark" or " death report"
        summary[#summary + 1] = new .. noun .. (new == 1 and "" or "s")
    end
    if refreshes > 0 then summary[#summary + 1] = refreshes .. (refreshes == 1 and " refresh" or " refreshes") end
    if hates > 0 then summary[#summary + 1] = hates .. " Hate · Only you will see this" end
    if marks > 0 and hates > 0 then summary[#summary] = hates .. " private Hate" end
    p.scope:SetText(#summary > 0 and table.concat(summary, " · ") or
        (pending > 0 and "Actions pending. Undo is available below." or
            (remaining == 0 and "Choices applied." or
                (canShare and "Expand the list to choose actions." or "Guild list unavailable. Hate stays private."))))
    local normal = pending == 0 and marks == verified and verified == remaining and marks > 0 and hates == 0
    local actionLabel = session.canMark and "Mark" or "Report"
    p.apply:SetText(normal and (actionLabel .. (n > 1 and " all" or "")) or "Apply choices")
    p.apply:SetEnabled(marks + hates > 0 and pending == 0)
    local actionY = session.expanded and (111 + drawerHeight + (noteShown and 59 or 0)) or 68
    p.scope:ClearAllPoints()
    p.scope:SetPoint("TOPLEFT", 12, -actionY)
    p.review:ClearAllPoints()
    p.review:SetPoint("TOPLEFT", 12, session.expanded and -69 or -(actionY + 50))
    p:SetHeight(session.expanded and (actionY + 53) or (actionY + 87))
end

local function buildDeathPrompt()
    local p = makeToast("UtuDeath", -165)
    deathPrompt = p
    p.session = false
    p:ClearAllPoints()
    p:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -48, -165)
    p:SetWidth(540)
    p:SetClampedToScreen(true)
    p:EnableMouse(true)
    if p.SetBackdropBorderColor then p:SetBackdropBorderColor(0.53, 0.35, 0.25, 1) end
    p.icon:SetTexture(KOS.LOGO)
    p.icon:SetSize(36, 36)
    p.icon:ClearAllPoints()
    p.icon:SetPoint("TOPLEFT", 12, -10)
    p.text:ClearAllPoints()
    p.text:SetPoint("TOPLEFT", 58, -12)
    p.text:SetWidth(430)
    p.text:SetWordWrap(false)
    p.text:SetFontObject("GameFontNormalLarge")
    p.hint = deathText(p, 460)
    p.hint:SetPoint("TOPLEFT", 58, -35)
    p.review = deathButton(p, "Review", 516, function()
        local session = p.session
        if not session then return end
        session.expanded = not session.expanded
        if not session.expanded then p.note:ClearFocus() end
        redrawDeath()
    end)
    p.close = deathButton(p, "×", 26, closeDeathPrompt)
    p.close:SetPoint("TOPRIGHT", -8, -7)
    p.scope = deathText(p, 516)
    p.skip = deathChoiceButton(p, "Skip", false, closeDeathPrompt)
    p.skip:SetPoint("TOPLEFT", p.scope, "BOTTOMLEFT", 0, -7)
    p.apply = deathChoiceButton(p, "Mark", true, function()
        if p.session then stageDeaths(p.session) end
    end)
    p.apply:SetPoint("LEFT", p.skip, "RIGHT", 8, 0)
    p.scroll = CreateFrame("ScrollFrame", nil, p, "UIPanelScrollFrameTemplate")
    p.scroll:SetPoint("TOPLEFT", 12, -101)
    p.scroll:SetWidth(480)
    p.content = CreateFrame("Frame", nil, p.scroll)
    p.content:SetSize(478, 1)
    p.scroll:SetScrollChild(p.content)
    p.rows = {}
    p.noteLabel = deathText(p, 516)
    p.noteLabel:SetText("What happened? · Optional, shared with your guild")
    p.noteLabel:SetPoint("TOPLEFT", p.scroll, "BOTTOMLEFT", 0, -7)
    p.note = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
    p.note:SetPoint("TOPLEFT", p.noteLabel, "BOTTOMLEFT", 5, -5)
    p.note:SetSize(502, 24)
    p.note:SetAutoFocus(false)
    p.note:SetMaxBytes(KOS.ENCOUNTER_NOTE_MAX)
    p.note:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    p.note:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    p:SetScript("OnUpdate", function(self, dt)
        self.left = self.left - dt
        if self.left <= 0 and not self.note:HasFocus() then closeDeathPrompt() end
    end)
    deathReceipt = makeToast("UtuDeathPending", -104)
    deathReceipt:ClearAllPoints()
    deathReceipt:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -48, -110)
    deathReceipt:SetSize(540, 42)
    deathReceipt.icon:SetTexture(KOS.LOGO)
    deathReceipt.text:ClearAllPoints()
    deathReceipt.text:SetPoint("LEFT", 35, 0)
    deathReceipt.text:SetWidth(357)
    deathReceipt.undo = deathButton(deathReceipt, "Undo pending", 120, undoDeaths)
    deathReceipt.undo:SetPoint("RIGHT", -8, 0)
    deathReceipt:SetScript("OnUpdate", updateDeathReceipt)
end

function KOS:ShowDeathPrompt(cands, at, zone)
    if not deathPrompt then buildDeathPrompt() end
    local p = deathPrompt
    if p.session then closeDeathPrompt() end
    local verified = false
    for _, c in ipairs(cands) do
        c.marked = c.why == "death recap"
        c.ownMark = self:MyVote(self:GetTarget(self:Canonical(c.full))) ~= nil
        if c.marked then verified = true end
    end
    p.session = { cands = cands, at = at, zone = zone, listKey = self:ListKey(),
        guild = self:IsGuildList(), canMark = self:CanMark(self:MyName()), nearby = not verified, expanded = false }
    p.note:SetText("")
    p.scroll:SetVerticalScroll(0)
    p.left = 120
    redrawDeath()
    p:Show()
end

function KOS.DeathPromptWidgets() return deathPrompt, deathReceipt end -- for tests

------------------------------------------------------------------------
-- Minimap button (drag around the rim; left = list, right = settings)
------------------------------------------------------------------------

-- The standard LibDataBroker launcher + LibDBIcon button, like most
-- addons: UI packs that gather minimap buttons (EllesmereUI, OneForAll,
-- etc.) recognise it, and it remembers where you dragged it.
local launcher
local function iconDB()
    local S = KOS.S
    if not S.minimapIcon then
        -- carry over the position of the pre-0.7 button (same angle convention)
        S.minimapIcon = { minimapPos = S.minimapAngle or 200 }
    end
    S.minimapIcon.hide = not S.minimap
    return S.minimapIcon
end

local function onTooltip(tt)
    tt:AddLine("Utu")
    local pts = KOS:PointsOf(KOS:MyName())
    tt:AddLine("You: " .. KOS.RankTag(pts) .. " (" .. pts .. " pts)", 1, 1, 1)
    local r = KOS:ZoneThreat()
    tt:AddLine((GetRealZoneText() or "") .. ": |c" .. r.color .. r.label .. "|r", 1, 1, 1)
    tt:AddLine("Left-click: list   Right-click: settings", 0.6, 0.6, 0.6)
end

function KOS:UpdateMinimapButton()
    local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
    local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not (LDB and DBIcon) then return end
    local db = iconDB()
    if not launcher then
        launcher = LDB:NewDataObject("Utu", {
            type = "launcher",
            text = "Utu",
            icon = KOS.LOGO,
            OnClick = function(_, button)
                if button == "RightButton" then KOS:OpenSettings() else KOS:ToggleUI() end
            end,
            OnTooltipShow = onTooltip,
        })
        DBIcon:Register("Utu", launcher, db)
    end
    if db.hide then DBIcon:Hide("Utu") else DBIcon:Show("Utu") end
end

KOS:On("PLAYER_LOGIN", function() KOS:UpdateMinimapButton() end)
