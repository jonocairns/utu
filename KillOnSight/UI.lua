-- Kill on Sight: main window. Everything is doable from here; slash
-- commands are just shortcuts.
--   Wanted    the list, with an add form and a detail pane per player
--   Hunters   your rank card + the season leaderboard
--   Guilds    enemy guilds, their bounty level and the war ledger
--   Activity  every guild event (chat only gets the important ones)
--   Settings  personal settings
--   Officer   guild rules, seasons and claim review (officers only)
local ADDON, ns = ...
local KOS = ns.KOS

local W, H = 820, 560
local LIST_W = 450
local TOP = -62           -- content starts below title + tabs
local DETAIL_X = LIST_W + 22
local DETAIL_W = W - DETAIL_X - 14

local f
local tabs, pages, order = {}, {}, {}
local current = "wanted"
local sel = {}            -- selected item key per page

------------------------------------------------------------------------
-- Small widget helpers
------------------------------------------------------------------------

local function Text(parent, font, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetJustifyH(justify or "LEFT")
    return fs
end

local function Button(parent, text, w, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function Edit(parent, w, placeholder)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(w, 20)
    e:SetAutoFocus(false)
    e.ph = Text(e, "GameFontDisableSmall")
    e.ph:SetPoint("LEFT", 2, 0)
    e.ph:SetText(placeholder or "")
    e:HookScript("OnTextChanged", function(self) self.ph:SetShown(self:GetText() == "") end)
    e:SetScript("OnEscapePressed", e.ClearFocus)
    return e
end

local function Bar(parent, w, h)
    local b = CreateFrame("StatusBar", nil, parent)
    b:SetSize(w, h)
    b:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    b:SetMinMaxValues(0, 1)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 0.08)
    b.text = Text(b, "GameFontHighlightSmall", "CENTER")
    b.text:SetPoint("CENTER")
    return b
end

-- Coloured square with a number in it (bounty / guild level).
local function Badge(parent, size)
    local b = CreateFrame("Frame", nil, parent)
    b:SetSize(size, size)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.text = Text(b, "GameFontNormalSmall", "CENTER")
    b.text:SetPoint("CENTER")
    function b:Set(text, r, g, bl)
        self.text:SetText(text)
        self.text:SetTextColor(r, g, bl)
        self.bg:SetColorTexture(r, g, bl, 0.2)
    end
    return b
end

local function Divider(parent, x, y, w)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(1, 1, 1, 0.08)
    t:SetSize(w, 1)
    t:SetPoint("TOPLEFT", x, y)
    return t
end

local function classColor(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) end
    return "|cffff6060"
end

local function fmtNum(n)
    n = math.floor(n + 0.5)
    local s = tostring(n)
    while true do
        local k
        s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then return s end
    end
end

-- Scrolling list of clickable rows.
local function List(parent, x, y, w, h, rowH, build, fill, onClick)
    local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", x, y)
    scroll:SetSize(w - 26, h)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(w - 26, 1)
    scroll:SetScrollChild(content)
    local L = { rows = {} }
    L.empty = Text(parent, "GameFontDisable", "CENTER")
    L.empty:SetPoint("CENTER", scroll, "CENTER")
    function L:Update(items, isSelected)
        for i, item in ipairs(items) do
            local r = self.rows[i]
            if not r then
                r = CreateFrame("Button", nil, content)
                r:SetSize(w - 26, rowH)
                r:SetPoint("TOPLEFT", 0, -(i - 1) * rowH)
                local bg = r:CreateTexture(nil, "BACKGROUND")
                bg:SetAllPoints()
                bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.03 or 0)
                local hl = r:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(1, 1, 1, 0.06)
                r.sel = r:CreateTexture(nil, "ARTWORK")
                r.sel:SetAllPoints()
                r.sel:SetColorTexture(1, 0.82, 0, 0.1)
                r.selBar = r:CreateTexture(nil, "OVERLAY")
                r.selBar:SetPoint("TOPLEFT")
                r.selBar:SetPoint("BOTTOMLEFT")
                r.selBar:SetWidth(2)
                r.selBar:SetColorTexture(1, 0.82, 0, 0.9)
                build(r)
                r:SetScript("OnClick", function(self) if onClick then onClick(self.item) end end)
                self.rows[i] = r
            end
            r.item = item
            fill(r, item, i)
            local s = isSelected and isSelected(item) or false
            r.sel:SetShown(s)
            r.selBar:SetShown(s)
            r:Show()
        end
        for i = #items + 1, #self.rows do self.rows[i]:Hide() end
        content:SetHeight(math.max(1, #items * rowH))
        self.empty:SetShown(#items == 0)
    end
    return L
end

-- Standard row: badge, title, subtitle, right-aligned info.
local function buildRow(r)
    r.badge = Badge(r, 28)
    r.badge:SetPoint("LEFT", 4, 0)
    r.title = Text(r, "GameFontNormal")
    r.title:SetPoint("TOPLEFT", 40, -4)
    r.right = Text(r, "GameFontDisableSmall", "RIGHT")
    r.right:SetPoint("TOPRIGHT", -6, -6)
    r.sub = Text(r, "GameFontHighlightSmall")
    r.sub:SetPoint("BOTTOMLEFT", 40, 5)
    r.sub:SetPoint("RIGHT", r, "RIGHT", -6, 0)
    r.sub:SetWordWrap(false)
end

local function newPage(key)
    local p = CreateFrame("Frame", nil, f)
    p:SetPoint("TOPLEFT", 0, TOP)
    p:SetPoint("BOTTOMRIGHT", 0, 28)
    p:Hide()
    pages[key] = p
    return p
end

-- Right-hand detail pane with a multi-line body.
local function DetailPane(p)
    local d = CreateFrame("Frame", nil, p, BackdropTemplateMixin and "BackdropTemplate" or nil)
    d:SetPoint("TOPLEFT", DETAIL_X, -4)
    d:SetPoint("BOTTOMRIGHT", -12, 4)
    if d.SetBackdrop then
        d:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
        d:SetBackdropColor(1, 1, 1, 0.03)
    end
    d.title = Text(d, "GameFontNormalLarge")
    d.title:SetPoint("TOPLEFT", 12, -12)
    d.title:SetWidth(DETAIL_W - 24)
    d.subtitle = Text(d, "GameFontDisableSmall")
    d.subtitle:SetPoint("TOPLEFT", d.title, "BOTTOMLEFT", 0, -3)
    d.placeholder = Text(d, "GameFontDisable", "CENTER")
    d.placeholder:SetPoint("CENTER")
    return d
end

------------------------------------------------------------------------
-- Wanted
------------------------------------------------------------------------

local wanted = {}

local function selectedTarget()
    local T = sel.wanted and KOS:GetTarget(sel.wanted)
    if T and T.on then return T end
end

local function markFromForm()
    local name = strtrim(wanted.name:GetText() or "")
    local note = wanted.note:GetText() or ""
    if name == "" then
        if not UnitIsPlayer("target") then KOS:Print("Type a name, or target a player."); return end
        local _, class = UnitClass("target")
        KOS:Mark(KOS:UnitFull("target"), note, UnitGUID("target"), class)
        sel.wanted = KOS:Canonical(KOS:UnitFull("target"))
    else
        KOS:Mark(name, note)
        sel.wanted = KOS:Canonical(name)
    end
    wanted.name:SetText("")
    wanted.note:SetText("")
    wanted.name:ClearFocus()
    wanted.note:ClearFocus()
    KOS:RefreshUI()
end

local function buildWanted()
    local p = newPage("wanted")

    wanted.name = Edit(p, 140, "Name (blank = target)")
    wanted.name:SetMaxLetters(40)
    wanted.name:SetPoint("TOPLEFT", 20, -6)
    wanted.note = Edit(p, 200, "Why? (optional)")
    wanted.note:SetPoint("LEFT", wanted.name, "RIGHT", 10, 0)
    wanted.note:SetMaxLetters(KOS.NOTE_MAX)
    wanted.name:SetScript("OnEnterPressed", function() wanted.note:SetFocus() end)
    wanted.note:SetScript("OnEnterPressed", markFromForm)
    local mark = Button(p, "Mark", 64, markFromForm)
    mark:SetPoint("LEFT", wanted.note, "RIGHT", 8, 0)

    wanted.search = Edit(p, 180, "Search names, notes, guilds")
    wanted.search:SetPoint("TOPLEFT", 20, -32)
    wanted.search:SetScript("OnTextChanged", function(self)
        self.ph:SetShown(self:GetText() == "")
        KOS:RefreshUI()
    end)
    wanted.count = Text(p, "GameFontDisableSmall", "RIGHT")
    wanted.count:SetPoint("TOPRIGHT", p, "TOPLEFT", LIST_W, -36)

    wanted.list = List(p, 10, -56, LIST_W, H + TOP - 28 - 64, 38, buildRow, function(r, T)
        r.badge:Set(KOS:LevelOf(T), KOS:BountyRGB(T))
        r.title:SetText(classColor(T.class) .. KOS:Display(T.n) .. "|r"
            .. (KOS:IsTopBounty(T) and " |cffffd100* Top Bounty|r" or "")
            .. (T.guild and (" |cff888888<" .. T.guild .. ">|r") or "")
            .. (KOS:MyVote(T) and " |cff40ff40(you)|r" or ""))
        r.right:SetText(T.seen and ("seen " .. KOS.Ago(T.seen)) or "")
        local note, by = KOS:TopNote(T)
        r.sub:SetText(KOS:BountyTag(T) .. "  " .. (note ~= "" and ("|cffcccccc" .. note .. "|r |cff777777- " .. KOS:Display(by) .. "|r") or ""))
    end, function(T)
        sel.wanted = KOS:Canonical(T.n)
        wanted.noteSynced = nil
        KOS:RefreshUI()
    end)
    wanted.list.empty:SetText("Nobody on the list yet.\nType a name above, or target a player and click Mark.")

    -- detail pane
    local d = DetailPane(p)
    wanted.d = d
    d.bar = Bar(d, DETAIL_W - 24, 14)
    d.bar:SetPoint("TOPLEFT", d.subtitle, "BOTTOMLEFT", 0, -10)
    d.value = Text(d, "GameFontNormal")
    d.value:SetPoint("TOPLEFT", d.bar, "BOTTOMLEFT", 0, -8)
    d.body = Text(d, "GameFontHighlightSmall")
    d.body:SetPoint("TOPLEFT", d.value, "BOTTOMLEFT", 0, -10)
    d.body:SetWidth(DETAIL_W - 24)
    d.body:SetJustifyV("TOP")
    d.body:SetSpacing(2)

    d.myNoteLabel = Text(d, "GameFontNormalSmall")
    d.myNoteLabel:SetPoint("BOTTOMLEFT", 12, 84)
    d.myNoteLabel:SetText("Your mark")
    d.myNote = Edit(d, DETAIL_W - 32, "Why? (optional)")
    d.myNote:SetPoint("BOTTOMLEFT", 18, 58)
    d.myNote:SetMaxLetters(KOS.NOTE_MAX)
    local function saveMine()
        local T = selectedTarget()
        if T then KOS:Mark(T.n, d.myNote:GetText(), T.guid, T.class); d.myNote:ClearFocus() end
    end
    d.myNote:SetScript("OnEnterPressed", saveMine)
    d.save = Button(d, "Mark", 120, saveMine)
    d.save:SetPoint("BOTTOMLEFT", 12, 30)
    d.unmark = Button(d, "Remove my mark", 130, function()
        local T = selectedTarget()
        if T then KOS:Unmark(T.n) end
    end)
    d.unmark:SetPoint("LEFT", d.save, "RIGHT", 6, 0)
    d.pardon = Button(d, "Pardon (clear all marks)", DETAIL_W - 24, function()
        local T = selectedTarget()
        if T then StaticPopup_Show("KILLONSIGHT_PARDON", KOS:Display(T.n), nil, T.n) end
    end)
    d.pardon:SetPoint("BOTTOMLEFT", 12, 6)
    d.placeholder:SetText("Select a player to see their bounty,\nmarks and history.")
end

local function refreshWanted()
    local filter = (wanted.search:GetText() or ""):lower()
    local items = {}
    for _, T in pairs(KOS:Targets()) do
        if T.on then
            local note = KOS:TopNote(T)
            if filter == "" or T.n:lower():find(filter, 1, true) or note:lower():find(filter, 1, true)
                or (T.guild and T.guild:lower():find(filter, 1, true)) then
                items[#items + 1] = T
            end
        end
    end
    table.sort(items, function(a, b)
        local sa, sb = KOS:ScoreOf(a), KOS:ScoreOf(b)
        if sa ~= sb then return sa > sb end
        return a.n < b.n
    end)
    wanted.list:Update(items, function(T) return KOS:Canonical(T.n) == sel.wanted end)
    wanted.count:SetText(#items .. (#items == 1 and " player" or " players"))

    local d, T = wanted.d, selectedTarget()
    local show = T ~= nil
    for _, w in ipairs({ d.title, d.subtitle, d.bar, d.value, d.body, d.myNoteLabel, d.myNote, d.save, d.unmark }) do
        w:SetShown(show)
    end
    d.placeholder:SetShown(not show)
    d.pardon:SetShown(show and KOS:CanPardon(KOS:MyName()))
    if not T then return end

    local score, lvl = KOS:ScoreOf(T), KOS:LevelOf(T)
    local r, g, b = KOS:BountyRGB(T)
    d.title:SetText(classColor(T.class) .. KOS:Display(T.n) .. "|r")
    d.subtitle:SetText((T.guild and ("<" .. T.guild .. ">  ") or "") .. KOS:BountyTag(T)
        .. (KOS:IsTopBounty(T) and "  |cffffd100* Top Bounty|r" or ""))
    d.bar:SetStatusBarColor(r, g, b)
    d.bar:SetValue(KOS.BountyProgress(score))
    d.bar.text:SetText(fmtNum(score) .. " / " .. fmtNum(KOS.ScoreForLevel(lvl + 1)) .. " to Lv " .. (lvl + 1))
    local v, base, why, bonuses = KOS:ClaimValue(T)
    d.value:SetText(v > 0 and ("|cffffd100Worth " .. v .. " points to you|r"
        .. (#bonuses > 0 and (" |cff888888(" .. base .. ", " .. KOS.BonusText(bonuses) .. ")|r") or ""))
        or ("|cff888888Worth nothing to you (" .. (why or "") .. ")|r"))

    local lines = {}
    local hl = KOS:HalfLife()
    lines[#lines + 1] = "|cff888888" .. (hl > 0 and ("Halves every " .. math.floor(hl / 86400 + 0.5) .. " days without new marks or ganks; each kill pays it down.") or "Bounties don't decay; each kill pays them down.") .. "|r"
    if T.seen then
        lines[#lines + 1] = "Last seen " .. KOS.Ago(T.seen) .. (T.zone and T.zone ~= "" and (" in " .. T.zone) or "")
            .. (T.seenBy and (" by " .. KOS:Display(T.seenBy)) or "")
    end
    lines[#lines + 1] = " "
    local votes = KOS:ActiveVotes(T)
    lines[#lines + 1] = "|cffffd100Marks (" .. #votes .. ")|r"
    for i = #votes, math.max(1, #votes - 4), -1 do
        local x = votes[i]
        lines[#lines + 1] = "  " .. KOS:Display(x.by) .. ": " .. (x.note ~= "" and x.note or "|cff777777marked|r")
            .. " |cff777777" .. KOS.Ago(x.t) .. "|r"
    end
    if #votes > 5 then lines[#lines + 1] = "  |cff777777+" .. (#votes - 5) .. " more|r" end
    local ganks = KOS:GanksBy(KOS:Canonical(T.n))
    local kills, latest = KOS:KillsOf(T.n)
    lines[#lines + 1] = " "
    lines[#lines + 1] = "|cffffd100Record|r"
    lines[#lines + 1] = #ganks == 0 and "  |cff888888No ganks on record - marks only|r"
        or ("  Ganked " .. #ganks .. (#ganks == 1 and " guildie" or " guildies")
            .. " (last: " .. KOS:Display(ganks[#ganks].victim) .. ", " .. KOS.Ago(ganks[#ganks].t) .. ")")
    lines[#lines + 1] = "  Killed by us " .. kills .. "x this season"
        .. (latest and (" (last: " .. KOS:Display(latest.by) .. ", " .. KOS.Ago(latest.t) .. ")") or "")
    local nem = KOS:NemesisOf(KOS:MyName())
    if nem and KOS:Canonical(nem.killer) == KOS:Canonical(T.n) then
        lines[#lines + 1] = "  |cffff4040Your nemesis|r: they've killed you " .. nem.theirKills .. "x, you've killed them " .. nem.myKills .. "x"
    end
    d.body:SetText(table.concat(lines, "\n"))

    local mine = KOS:MyVote(T)
    d.save:SetText(mine and "Save & refresh" or "Add my mark")
    d.unmark:SetEnabled(mine ~= nil)
    if wanted.noteSynced ~= sel.wanted and not d.myNote:HasFocus() then
        d.myNote:SetText(mine and mine.note or "")
        wanted.noteSynced = sel.wanted
    end
end

------------------------------------------------------------------------
-- Hunters
------------------------------------------------------------------------

local hunters = {}

local function buildHunters()
    local p = newPage("hunters")

    -- "you" card
    local card = CreateFrame("Frame", nil, p)
    card:SetPoint("TOPLEFT", 14, -4)
    card:SetSize(LIST_W - 10, 64)
    hunters.rank = Text(card, "GameFontNormalLarge")
    hunters.rank:SetPoint("TOPLEFT", 4, -2)
    hunters.points = Text(card, "GameFontNormal", "RIGHT")
    hunters.points:SetPoint("TOPRIGHT", -4, -4)
    hunters.bar = Bar(card, LIST_W - 18, 12)
    hunters.bar:SetPoint("TOPLEFT", 4, -24)
    hunters.stats = Text(card, "GameFontHighlightSmall")
    hunters.stats:SetPoint("TOPLEFT", 4, -42)
    hunters.stats:SetWidth(LIST_W - 18)
    Divider(p, 14, -72, LIST_W - 10)

    hunters.season = Text(p, "GameFontDisableSmall")
    hunters.season:SetPoint("TOPLEFT", 18, -80)
    hunters.season:SetWidth(LIST_W - 120)
    hunters.mode = "season"
    hunters.toggle = Button(p, "This week", 90, function()
        hunters.mode = (hunters.mode == "season") and "week" or "season"
        KOS:RefreshUI()
    end)
    hunters.toggle:SetPoint("TOPRIGHT", p, "TOPLEFT", LIST_W, -76)

    hunters.list = List(p, 10, -102, LIST_W, H + TOP - 28 - 110, 38, buildRow, function(r, h, i)
        local rank = KOS.HunterRank(h.points)
        local medal = (i == 1 and { 1, 0.84, 0 }) or (i == 2 and { 0.75, 0.75, 0.75 }) or (i == 3 and { 0.8, 0.5, 0.2 }) or { 0.6, 0.6, 0.6 }
        r.badge:Set(i, medal[1], medal[2], medal[3])
        r.title:SetText(KOS:Display(h.name) .. "  " .. KOS.RankTag(h.points)
            .. (KOS:Canonical(h.name) == KOS:MyKey() and " |cff40ff40(you)|r" or ""))
        r.right:SetText("|cffffd100" .. fmtNum(h.points) .. " pts|r")
        r.sub:SetText(h.kills .. " kills, " .. h.assists .. " assists, " .. h.revenges .. " revenges, " .. h.rescues .. " rescues")
    end, function(h)
        sel.hunters = KOS:Canonical(h.name)
        KOS:RefreshUI()
    end)
    hunters.list.empty:SetText("No bounties claimed this season yet.\nKill a marked player to get on the board.")

    local d = DetailPane(p)
    hunters.d = d
    d.bar = Bar(d, DETAIL_W - 24, 12)
    d.bar:SetPoint("TOPLEFT", d.subtitle, "BOTTOMLEFT", 0, -10)
    d.body = Text(d, "GameFontHighlightSmall")
    d.body:SetPoint("TOPLEFT", d.bar, "BOTTOMLEFT", 0, -10)
    d.body:SetWidth(DETAIL_W - 24)
    d.body:SetJustifyV("TOP")
    d.body:SetSpacing(2)
    d.placeholder:SetText("Select a hunter to see their claims.")
end

local function refreshHunters()
    local pts, me = KOS:PointsOf(KOS:MyName())
    local rank = KOS.HunterRank(pts)
    hunters.rank:SetText("|c" .. rank.color .. rank.name .. "|r  |cff888888Level " .. rank.level .. "|r")
    hunters.points:SetText("|cffffd100" .. fmtNum(pts) .. " pts|r")
    hunters.bar:SetStatusBarColor(1, 0.82, 0)
    hunters.bar:SetValue(rank.progress)
    hunters.bar.text:SetText((rank.nextAt - pts) .. " to level " .. (rank.level + 1))
    local nem = KOS:NemesisOf(KOS:MyName())
    local badgeCount = 0
    for _ in pairs(KOS:BadgeSet(KOS:MyName())) do badgeCount = badgeCount + 1 end
    hunters.stats:SetText((me and (me.kills .. " kills, " .. me.assists .. " assists, " .. me.revenges .. " revenges, " .. me.rescues .. " rescues") or "No claims yet this season")
        .. "  ·  " .. badgeCount .. "/" .. #KOS.BADGES .. " badges"
        .. (nem and ("   |cffff4040Nemesis:|r " .. KOS:Display(nem.killer) .. " (" .. nem.theirKills .. "-" .. nem.myKills .. ")") or ""))

    local start, ends, num, prevStart, prevEnd = KOS:SeasonBounds()
    local from = start
    if hunters.mode == "week" then from = math.max(start, GetServerTime() - 7 * 86400) end
    hunters.toggle:SetText(hunters.mode == "week" and "Whole season" or "This week")
    local seasonText = (num and ("Season " .. num) or "This season")
        .. (ends and (" - ends in " .. math.max(1, math.ceil((ends - GetServerTime()) / 86400)) .. " days") or "")
    if prevStart and prevEnd then
        local prev = KOS:Scores(prevStart, prevEnd)
        if #prev > 0 then
            local top = {}
            for i = 1, math.min(3, #prev) do top[#top + 1] = KOS:Display(prev[i].name) end
            seasonText = seasonText .. "  ·  Last season: " .. table.concat(top, ", ")
        end
    end
    hunters.season:SetText(seasonText .. (hunters.mode == "week" and "  ·  |cffffd100showing the last 7 days|r" or ""))
    local rows = KOS:Scores(from)
    hunters.list:Update(rows, function(h) return KOS:Canonical(h.name) == sel.hunters end)

    local d, h = hunters.d, nil
    for _, r in ipairs(rows) do if KOS:Canonical(r.name) == sel.hunters then h = r end end
    for _, w in ipairs({ d.title, d.subtitle, d.bar, d.body }) do w:SetShown(h ~= nil) end
    d.placeholder:SetShown(h == nil)
    if not h then return end
    local hr = KOS.HunterRank(h.points)
    d.title:SetText(KOS:Display(h.name))
    d.subtitle:SetText(KOS.RankTag(h.points) .. "  |cff888888Level " .. hr.level .. "  ·  " .. fmtNum(h.points) .. " pts|r")
    d.bar:SetStatusBarColor(1, 0.82, 0)
    d.bar:SetValue(hr.progress)
    d.bar.text:SetText((hr.nextAt - h.points) .. " to level " .. (hr.level + 1))
    local lines = {
        h.kills .. " kills, " .. h.assists .. " assists, " .. h.revenges .. " revenges, " .. h.rescues .. " rescues",
        h.bestTarget and ("Best: " .. KOS:Display(h.bestTarget) .. " for " .. h.best .. " pts") or "",
        " ", "|cffffd100Badges|r",
    }
    local got, missing = {}, {}
    for _, b in ipairs(KOS:Badges(h.name)) do
        if b.done then got[#got + 1] = "|cffffd100" .. b.name .. "|r" else missing[#missing + 1] = b.name end
    end
    lines[#lines + 1] = "  " .. (#got > 0 and table.concat(got, ", ") or "|cff777777none yet|r")
    if #missing > 0 and KOS:Canonical(h.name) == KOS:MyKey() then
        lines[#lines + 1] = "  |cff777777Next: " .. table.concat(missing, ", ", 1, math.min(3, #missing)) .. "|r"
    end
    lines[#lines + 1] = " "
    lines[#lines + 1] = "|cffffd100Recent claims|r"
    local claims = KOS:Claims(h.name)
    for i = 1, math.min(12, #claims) do
        local c = claims[i]
        local k = c.k
        local tag = (k.assist and " |cff888888assist|r") or (k.rev and " |cffff8000revenge|r") or (k.res and " |cff40c0ffrescue|r") or ""
        lines[#lines + 1] = "  " .. KOS:Display(k.target) .. " +" .. k.v .. tag .. " |cff777777" .. KOS.Ago(k.t) .. "|r"
            .. (#c.flags > 0 and (" |cffff4040" .. table.concat(c.flags, " ") .. "|r") or "")
    end
    d.body:SetText(table.concat(lines, "\n"))
end

------------------------------------------------------------------------
-- Guilds
------------------------------------------------------------------------

local guilds = {}

local function buildGuilds()
    local p = newPage("guilds")
    guilds.info = Text(p, "GameFontDisableSmall")
    guilds.info:SetPoint("TOPLEFT", 20, -10)
    guilds.info:SetWidth(LIST_W - 20)
    guilds.list = List(p, 10, -32, LIST_W, H + TOP - 28 - 40, 38, buildRow, function(r, g)
        local band = KOS.BountyBand(g.level)
        r.badge:Set(g.level, band.rgb[1], band.rgb[2], band.rgb[3])
        r.title:SetText("<" .. g.name .. ">" .. (g.kos and "  |cffff2020KOS GUILD|r" or ""))
        r.right:SetText("War " .. g.kills .. " - " .. g.ganks)
        r.sub:SetText(g.members .. " marked " .. (g.members == 1 and "member" or "members") .. "  ·  " .. fmtNum(g.points) .. " pts claimed")
    end, function(g)
        sel.guilds = g.name
        KOS:RefreshUI()
    end)
    guilds.list.empty:SetText("No enemy guilds known yet.\nGuilds are recorded when you see a marked player.")

    local d = DetailPane(p)
    guilds.d = d
    d.bar = Bar(d, DETAIL_W - 24, 14)
    d.bar:SetPoint("TOPLEFT", d.subtitle, "BOTTOMLEFT", 0, -10)
    d.body = Text(d, "GameFontHighlightSmall")
    d.body:SetPoint("TOPLEFT", d.bar, "BOTTOMLEFT", 0, -10)
    d.body:SetWidth(DETAIL_W - 24)
    d.body:SetJustifyV("TOP")
    d.body:SetSpacing(2)
    d.show = Button(d, "Show members on Wanted", DETAIL_W - 24, function()
        if not sel.guilds then return end
        KOS:SetTab("wanted")
        wanted.search:SetText(sel.guilds)
    end)
    d.show:SetPoint("BOTTOMLEFT", 12, 8)
    d.placeholder:SetText("Select a guild to see its members\nand your war record.")
end

local function refreshGuilds()
    local th = KOS:GuildThreshold()
    guilds.info:SetText(th > 0 and ("A whole guild becomes Kill on Sight at guild bounty Lv " .. th .. " with " .. KOS.GUILD_MIN_GANKS .. "+ ganks on us.")
        or "Whole-guild Kill on Sight is turned off by your officers.")
    local items = {}
    for _, g in pairs(KOS:GuildStats()) do items[#items + 1] = g end
    table.sort(items, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.name < b.name
    end)
    guilds.list:Update(items, function(g) return g.name == sel.guilds end)

    local d, g = guilds.d, sel.guilds and KOS:GuildStats()[sel.guilds]
    for _, w in ipairs({ d.title, d.subtitle, d.bar, d.body, d.show }) do w:SetShown(g ~= nil) end
    d.placeholder:SetShown(not g)
    if not g then return end
    local band = KOS.BountyBand(g.level)
    d.title:SetText("<" .. g.name .. ">")
    d.subtitle:SetText("|c" .. band.color .. "Guild bounty Lv " .. g.level .. "|r" .. (g.kos and "  |cffff2020KOS GUILD|r" or ""))
    d.bar:SetStatusBarColor(band.rgb[1], band.rgb[2], band.rgb[3])
    if th > 0 then
        d.bar:SetValue(math.min(1, g.score / KOS.ScoreForLevel(th)))
        d.bar.text:SetText(g.kos and "Whole guild is Kill on Sight"
            or ("Lv " .. g.level .. "/" .. th .. ", ganks " .. g.ganks .. "/" .. KOS.GUILD_MIN_GANKS .. " for whole-guild KoS"))
    else
        d.bar:SetValue(KOS.BountyProgress(g.score))
        d.bar.text:SetText(fmtNum(g.score) .. " bounty")
    end
    local lines = {
        "|cffffd100War ledger|r",
        "  Us " .. g.kills .. " - " .. g.ganks .. " them  (" .. fmtNum(g.points) .. " pts claimed)",
        " ", "|cffffd100Marked members (" .. g.members .. ")|r",
    }
    local members = {}
    for _, T in pairs(KOS:Targets()) do
        if T.on and T.guild == g.name then members[#members + 1] = T end
    end
    table.sort(members, function(a, b) return KOS:ScoreOf(a) > KOS:ScoreOf(b) end)
    for i = 1, math.min(12, #members) do
        local T = members[i]
        lines[#lines + 1] = "  " .. classColor(T.class) .. KOS:Display(T.n) .. "|r  " .. KOS:BountyTag(T)
    end
    d.body:SetText(table.concat(lines, "\n"))
end

------------------------------------------------------------------------
-- Activity
------------------------------------------------------------------------

local activity = {}
local PRIO_COLOR = { me = { 0.25, 1, 0.25 }, nearby = { 0.25, 0.75, 1 }, big = { 1, 0.82, 0 }, info = { 0.5, 0.5, 0.5 } }

local function buildActivity()
    local p = newPage("activity")
    activity.info = Text(p, "GameFontDisableSmall")
    activity.info:SetPoint("TOPLEFT", 20, -10)
    activity.info:SetText("Everything your guild does. Chat only shows what your Guild activity setting allows.")
    activity.list = List(p, 10, -30, W - 20, H + TOP - 28 - 38, 22, function(r)
        r.dot = r:CreateTexture(nil, "ARTWORK")
        r.dot:SetSize(4, 14)
        r.dot:SetPoint("LEFT", 4, 0)
        r.time = Text(r, "GameFontDisableSmall", "RIGHT")
        r.time:SetPoint("LEFT", 12, 0)
        r.time:SetWidth(56)
        r.text = Text(r, "GameFontHighlightSmall")
        r.text:SetPoint("LEFT", 76, 0)
        r.text:SetPoint("RIGHT", -6, 0)
        r.text:SetWordWrap(false)
    end, function(r, e)
        local c = PRIO_COLOR[e.p] or PRIO_COLOR.info
        r.dot:SetColorTexture(c[1], c[2], c[3], 0.9)
        r.time:SetText(KOS.Ago(e.t))
        r.text:SetText(e.text)
    end)
    activity.list.empty:SetText("Nothing yet. Marks, ganks, sightings and claims from your guild show up here.")
end

local function refreshActivity()
    activity.list:Update(KOS:Feed())
end

function KOS:OnFeed()
    if f and f:IsShown() and current == "activity" then refreshActivity() end
end

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------

local settingsRefresh
local function buildSettings()
    local p = newPage("settings")
    settingsRefresh = KOS:BuildSettings(p)
end

------------------------------------------------------------------------
-- Officer
------------------------------------------------------------------------

local officer = { pending = {} }

local function ruleGetter(tag, default)
    return function()
        local pend = officer.pending[tag]
        if pend and GetTime() - pend.at < 15 then return pend.v end
        local v = KOS:GuildTag(tag)
        if v == nil then return default end
        return v
    end
end
local function ruleSetter(tag, removeValue)
    return function(v)
        officer.pending[tag] = { v = v, at = GetTime() }
        KOS:SetGuildRule(tag, (v ~= removeValue) and v or nil)
    end
end

local function canOfficer()
    return KOS:IsGuildList() and (KOS:CanPardon(KOS:MyName()) or KOS:CanEditRules())
end

local function buildOfficer()
    local p = newPage("officer")
    local x, y = 16, -8
    local h = Text(p, "GameFontNormal")
    h:SetPoint("TOPLEFT", x, y)
    h:SetText("Guild rules")
    officer.rulesNote = Text(p, "GameFontDisableSmall")
    officer.rulesNote:SetPoint("TOPLEFT", x, y - 18)
    officer.rulesNote:SetWidth(360)
    y = y - 50
    local ranks = { { 0, "Guild Master" } }
    for i = 1, 9 do ranks[#ranks + 1] = { i, "Rank " .. i .. " and up" } end
    local markRanks = { { -1, "Everyone" } }
    for i = 0, 9 do markRanks[#markRanks + 1] = { i, i == 0 and "Guild Master" or ("Rank " .. i .. " and up") } end
    officer.steppers = {}
    local function add(tag, label, values, default, removeValue)
        local ctl, ny = KOS:Stepper(p, label, values, x, y, ruleGetter(tag, default), ruleSetter(tag, removeValue), 170)
        officer.steppers[#officer.steppers + 1] = ctl
        y = ny
    end
    add("rank", "Pardon, strike, new season", ranks, KOS.DEFAULT_PARDON_RANK, nil)
    add("addrank", "Who can mark players", markRanks, -1, -1)
    add("guild", "Whole guild KoS at", KOS.Range(5, 60, 5, "guild Lv %d", { 0, "Off" }), KOS.DEFAULT_GUILD_LEVEL, nil)
    local hl = { { 0, "No decay" } }
    for _, d in ipairs({ 3, 7, 14, 21, 30, 45, 60, 90 }) do hl[#hl + 1] = { d, d .. " days" } end
    add("halflife", "Bounty half-life", hl, KOS.DEFAULT_HALFLIFE_DAYS, nil)
    add("season", "Season length", { { 0, "Manual only" }, { 2, "2 weeks" }, { 4, "4 weeks" }, { 6, "6 weeks" },
        { 8, "8 weeks" }, { 12, "12 weeks" } }, KOS.DEFAULT_SEASON_WEEKS, nil)

    y = y - 14
    Divider(p, x, y, 370)
    y = y - 12
    local sh = Text(p, "GameFontNormal")
    sh:SetPoint("TOPLEFT", x, y)
    sh:SetText("Season")
    officer.season = Text(p, "GameFontHighlightSmall")
    officer.season:SetPoint("TOPLEFT", x, y - 20)
    officer.season:SetWidth(360)
    officer.newSeason = Button(p, "Start next season now", 170, function() StaticPopup_Show("KILLONSIGHT_SEASON") end)
    officer.newSeason:SetPoint("TOPLEFT", x, y - 40)

    y = y - 76
    Divider(p, x, y, 370)
    y = y - 12
    local bh = Text(p, "GameFontNormal")
    bh:SetPoint("TOPLEFT", x, y)
    bh:SetText("Check for brigading")
    officer.brigade = Text(p, "GameFontHighlightSmall")
    officer.brigade:SetPoint("TOPLEFT", x, y - 18)
    officer.brigade:SetWidth(370)
    officer.brigade:SetJustifyV("TOP")

    -- claims review
    local cx = 410
    local ch = Text(p, "GameFontNormal")
    ch:SetPoint("TOPLEFT", cx, -8)
    ch:SetText("Claims review")
    officer.flaggedOnly = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
    officer.flaggedOnly:SetSize(22, 22)
    officer.flaggedOnly:SetPoint("TOPLEFT", cx + 120, -4)
    officer.flaggedOnly:SetChecked(true)
    officer.flaggedOnly:SetScript("OnClick", function() KOS:RefreshUI() end)
    local fl = Text(p, "GameFontHighlightSmall")
    fl:SetPoint("LEFT", officer.flaggedOnly, "RIGHT", 2, 0)
    fl:SetText("Flagged only")
    officer.claims = List(p, cx - 6, -30, W - cx - 4, H + TOP - 28 - 38, 34, function(r)
        r.title = Text(r, "GameFontHighlightSmall")
        r.title:SetPoint("TOPLEFT", 6, -4)
        r.title:SetPoint("RIGHT", -70, 0)
        r.title:SetWordWrap(false)
        r.sub = Text(r, "GameFontDisableSmall")
        r.sub:SetPoint("BOTTOMLEFT", 6, 4)
        r.strike = Button(r, "Strike", 60, function(b)
            local c = b:GetParent().item
            StaticPopup_Show("KILLONSIGHT_STRIKE", KOS:Display(c.k.by) .. " on " .. KOS:Display(c.k.target), nil, c.id)
        end)
        r.strike:SetPoint("RIGHT", -4, 0)
    end, function(r, c)
        r.title:SetText(KOS:Display(c.k.by) .. " killed " .. KOS:Display(c.k.target) .. " for |cffffd100" .. c.k.v .. "|r"
            .. (c.k.assist and " (assist)" or ""))
        r.sub:SetText(KOS.Ago(c.k.t) .. (#c.flags > 0 and ("  |cffff4040" .. table.concat(c.flags, " ") .. "|r") or ""))
        r.strike:SetEnabled(KOS:CanPardon(KOS:MyName()))
    end)
    officer.claims.empty:SetText("No claims to review.")
end

StaticPopupDialogs["KILLONSIGHT_STRIKE"] = {
    text = "Strike %s's claim?\nIt's removed from the leaderboard for everyone.",
    button1 = YES or "Yes",
    button2 = NO or "No",
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    OnAccept = function(self) KOS:Strike(self.data) end,
}

local function refreshOfficer()
    local canEdit = KOS:CanEditRules()
    officer.rulesNote:SetText(canEdit and "Saved in your guild information text, so every member's addon uses the same rules."
        or "Only members who can edit the guild information can change these.")
    for _, s in ipairs(officer.steppers) do
        s.refresh()
        s.setEnabled(canEdit)
    end
    local start, ends, num = KOS:SeasonBounds()
    local manual = KOS:List().season
    officer.season:SetText((num and ("Season " .. num .. ", ") or "") .. "started " .. KOS.Ago(start)
        .. ((manual and manual.t == start) and (" (early, by " .. KOS:Display(manual.by) .. ")") or "")
        .. (ends and (", ends in " .. math.max(1, math.ceil((ends - GetServerTime()) / 86400)) .. " days.") or ".")
        .. " Past claims are kept as history.")
    -- lots of marks but no ganks: maybe a pile-on rather than a real ganker
    local sus = {}
    for _, T in pairs(KOS:Targets()) do
        if T.w >= 5 and #KOS:GanksBy(KOS:Canonical(T.n)) == 0 then sus[#sus + 1] = T end
    end
    table.sort(sus, function(a, b) return a.w > b.w end)
    local bl = {}
    for i = 1, math.min(6, #sus) do
        bl[#bl + 1] = KOS:Display(sus[i].n) .. " - " .. sus[i].w .. " marks, no ganks on record"
    end
    officer.brigade:SetText(#bl > 0 and table.concat(bl, "\n") or "|cff888888Nobody with 5+ marks and no ganks. Looks healthy.|r")
    officer.newSeason:SetEnabled(KOS:CanPardon(KOS:MyName()))
    local claims = KOS:Claims()
    if officer.flaggedOnly:GetChecked() then
        local flagged = {}
        for _, c in ipairs(claims) do if #c.flags > 0 then flagged[#flagged + 1] = c end end
        claims = flagged
    end
    officer.claims:Update(claims)
end

------------------------------------------------------------------------
-- Window, tabs
------------------------------------------------------------------------

local REFRESH = {
    wanted = refreshWanted, hunters = refreshHunters, guilds = refreshGuilds,
    activity = refreshActivity, settings = function() settingsRefresh() end, officer = refreshOfficer,
}

local function addTab(key, label)
    local b = CreateFrame("Button", nil, f)
    b:SetHeight(24)
    b.label = Text(b, "GameFontNormal", "CENTER")
    b.label:SetPoint("CENTER", 0, 1)
    b.label:SetText(label)
    b:SetWidth(math.max(70, (b.label:GetStringWidth() or 60) + 24))
    b.line = b:CreateTexture(nil, "OVERLAY")
    b.line:SetHeight(2)
    b.line:SetPoint("BOTTOMLEFT", 6, 0)
    b.line:SetPoint("BOTTOMRIGHT", -6, 0)
    b.line:SetColorTexture(1, 0.82, 0, 1)
    b:SetScript("OnClick", function() KOS:SetTab(key) end)
    tabs[key] = b
    order[#order + 1] = key
end

local function layoutTabs()
    local x = 12
    for _, key in ipairs(order) do
        local b = tabs[key]
        local visible = key ~= "officer" or canOfficer()
        b:SetShown(visible)
        if visible then
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", x, -32)
            x = x + b:GetWidth()
        end
    end
end

local function build()
    f = CreateFrame("Frame", "KillOnSightFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(W, H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1,
        })
        f:SetBackdropColor(0.06, 0.06, 0.07, 0.96)
        f:SetBackdropBorderColor(0, 0, 0, 1)
    end
    f:Hide()
    tinsert(UISpecialFrames, "KillOnSightFrame")

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(KOS.SKULL)
    icon:SetSize(16, 16)
    icon:SetPoint("TOPLEFT", 12, -9)
    f.title = Text(f, "GameFontNormal")
    f.title:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    Divider(f, 0, -57, W)

    f.footer = Text(f, "GameFontDisableSmall")
    f.footer:SetPoint("BOTTOMLEFT", 14, 9)
    local sync = Button(f, "Sync now", 80, function() if KOS.Sync then KOS.Sync:Hello(true) end end)
    sync:SetPoint("BOTTOMRIGHT", -10, 4)

    addTab("wanted", "Wanted")
    addTab("hunters", "Hunters")
    addTab("guilds", "Guilds")
    addTab("activity", "Activity")
    addTab("settings", "Settings")
    addTab("officer", "Officer")

    buildWanted()
    buildHunters()
    buildGuilds()
    buildActivity()
    buildSettings()
    buildOfficer()

    local acc = 0
    f:SetScript("OnUpdate", function(_, dt)
        acc = acc + dt
        if acc >= 5 then acc = 0; KOS:RefreshUI() end -- "seen 3m ago", decay, sync progress
    end)
    f:SetScript("OnShow", function() KOS:RefreshUI() end)
end

function KOS:SetTab(key)
    if not f then build() end
    if key == "officer" and not canOfficer() then key = "wanted" end
    current = key
    for k, p in pairs(pages) do p:SetShown(k == key) end
    self:RefreshUI()
end

function KOS:RefreshUI()
    if not f or not f:IsShown() then return end
    layoutTabs()
    for k, b in pairs(tabs) do
        b.line:SetShown(k == current)
        b.label:SetFontObject(k == current and "GameFontHighlight" or "GameFontNormal")
        if k ~= current then b.label:SetTextColor(0.6, 0.6, 0.6) else b.label:SetTextColor(1, 1, 1) end
    end
    local g = IsInGuild() and GetGuildInfo("player")
    f.title:SetText("Kill on Sight  |cff888888" .. (g and ("<" .. g .. ">") or "personal list") .. "|r")
    local q = self.Sync and self.Sync:QueueSize() or 0
    f.footer:SetText(q > 0 and ("|cffffd100Syncing with guildies (" .. q .. " left)|r")
        or (self:IsGuildList() and "Synced with online guildies" or "Not in a guild: this list is just yours"))
    REFRESH[current]()
end

function KOS:ShowUI(tab)
    if not f then build() end
    f:Show()
    self:SetTab(tab or current)
end

function KOS:ToggleUI()
    if f and f:IsShown() then f:Hide() else self:ShowUI() end
end

-- Open the window on a specific player (e.g. from the minimap tracker).
function KOS:ShowTarget(name)
    sel.wanted = self:Canonical(name)
    self:ShowUI("wanted")
end
