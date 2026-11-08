-- Utu: core data model, names, bounties, permissions, slash commands.
local ADDON, ns = ...

local KOS = {}
ns.KOS = KOS
_G.Utu = KOS

KOS.PREFIX = "KOS2"
KOS.HOME_URL = "github.com/jonocairns/utu"
KOS.NOTE_MAX = 100 -- bytes; keeps one mark inside a single 255-byte addon message
KOS.DEFAULT_PARDON_RANK = 1 -- without a guild-info tag, GM (0) and rank 1 can pardon
KOS.SKULL = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8" -- marks a player as kill on sight
KOS.LOGO = "Interface\\AddOns\\Utu\\Media\\logo" -- the addon itself (pūkana face)

-- Personal settings. These live in this account's SavedVariables and are
-- never sent to anyone.
KOS.DEFAULTS = {
    -- alerts on my screen
    banner = true, sound = "raid", chat = true, flash = false,
    escalate = true, loudLevel = 20, minLevel = 3, quietResting = false,
    alwaysMine = true,       -- players I marked always alert, however cold their bounty
    callForHelp = true,      -- tell guildies when a KoS player attacks me
    -- detect using
    srcNameplate = true, srcCombat = true, srcTarget = true, srcMouseover = true,
    -- markers
    nameplate = true, targetBadge = true, tooltip = true, raidMark = false,
    -- windows
    tracker = true, minimap = true, minimapAngle = 200,
    -- guild & group
    announce = true, partyChat = false, guildChat = false,
    chatter = "important",   -- guild activity in chat: "off" | "important" | "all" (always in the Activity tab)
    helpBanner = "near",     -- help-call banner + "On my way": "off" | "near" | "zone" | "any"
    helpRange = 400,         -- yards, for "near"
    zoneThreat = true,       -- warn about recent KoS activity when entering a zone
    alertsInPvP = false,     -- banners/sounds in battlegrounds and arenas
    -- bounty game
    claimKills = true,       -- share my killing blows on KoS players (scores points)
    autoMark = true,         -- mark players who kill me
    guildAlerts = true,      -- skull on members of a KoS guild
    guildBanners = false,    -- ...and banner/sound for them too
}

-- Guild-wide tuning. Officers can override the tagged ones from the
-- Officer tab (stored as tags in the guild info text).
KOS.MARK_SCORE = 100              -- bounty score per active mark
KOS.GANK_SCORE = 100              -- per guildie they killed (a death is better evidence than an opinion)
KOS.KILL_DRAIN = 50               -- each claimed kill lowers the target's bounty (decays like a mark)
KOS.DEFAULT_HALFLIFE_DAYS = 14    -- KOS:halflife=N  (0 = no decay)
KOS.MARK_EXPIRY_HALFLIVES = 4     -- a mark stops counting after 4 half-lives unless refreshed
KOS.DEFAULT_GUILD_LEVEL = 30      -- KOS:guild=N  guild bounty level for whole-guild KoS (0 = off)
KOS.GUILD_MIN_GANKS = 10          -- ...and the guild must have ganked us this many times
KOS.GUILD_MEMBER_POINTS = 2       -- flat payout for an unmarked member of a KoS guild
KOS.DEFAULT_SEASON_WEEKS = 8      -- KOS:season=N  (0 = officers start seasons by hand)
KOS.SEASON_EPOCH = 1767225600     -- 2026-01-01 00:00 UTC; calendar seasons count from here
KOS.DEATH_HORIZON = 120 * 86400   -- ganks older than this are dropped
KOS.KILL_HORIZON = 180 * 86400    -- claims older than this are dropped (kept across seasons till then)
KOS.REVENGE_WINDOW = 3600         -- kill a guildie's killer within an hour
KOS.RESCUE_WINDOW = 180           -- kill whoever is attacking a guildie within 3 minutes
KOS.DEFENSE_POINTS = 10           -- flat payout for killing an unmarked attacker of a guildie
KOS.DEFEND_LEVELS = 5             -- call for help when any enemy this many levels above you attacks
KOS.BONUS = 0.5                   -- top bounty, revenge/rescue, first blood: each +50% of base
KOS.ASSIST_MULT = 0.5             -- grouped guildies who hit the target get half the base
KOS.MAX_CLAIM = 500               -- hard cap on one claim, enforced on send and receive
KOS.GREY_FULL = 4                 -- full points up to this many levels below you...
KOS.GREY_ZERO = 10                -- ...sliding to nothing at this many
KOS.FARM_FLAG = 5                 -- audit: > this many kills of one target by one hunter per hour
KOS.THREAT_WINDOW = 1800          -- zone threat looks at the last 30 minutes
KOS.ASSIST_DELAY = 5               -- seconds a responder assist waits for a possible honour kill
KOS.RESPOND_RANGE = 150           -- "On my way" responders this close to the call when the attacker dies get an assist

KOS.SOUNDS = {
    { key = "raid", name = "Raid warning", id = 8959 },
    { key = "ready", name = "Ready check", id = 8960 },
    { key = "pvp", name = "PvP queue", id = 8459 },
    { key = "none", name = "None" },
}

------------------------------------------------------------------------
-- Level ladders
--
-- Bounty: score -> level on an open-ended curve (score for level L is
-- 20 * L^1.5), so there's always a next level. Named bands give colour.
-- Hunters: season points -> level (10 * L^1.6), 50 named levels in bands
-- of five (Tracker I..V, Scout I..V, ...) then "Legend N".
------------------------------------------------------------------------

local EPS = 1e-9

KOS.BOUNTY_BANDS = {
    { min = 40, name = "Legendary", color = "ffff2020", rgb = { 1, 0.13, 0.13 } },
    { min = 28, name = "Public Enemy", color = "ffff8000", rgb = { 1, 0.5, 0 } },
    { min = 20, name = "Notorious", color = "ffa335ee", rgb = { 0.64, 0.21, 0.93 } },
    { min = 14, name = "Most Wanted", color = "ff0070dd", rgb = { 0, 0.44, 0.87 } },
    { min = 8, name = "Wanted", color = "ff1eff00", rgb = { 0.12, 1, 0 } },
    { min = 4, name = "Marked", color = "ffffffff", rgb = { 1, 1, 1 } },
    { min = 1, name = "Suspect", color = "ffbbbbbb", rgb = { 0.73, 0.73, 0.73 } },
    { min = 0, name = "Dormant", color = "ff777777", rgb = { 0.47, 0.47, 0.47 } },
}

-- Base points for killing a target of this bounty level.
function KOS.PayoutForLevel(level)
    if not level or level <= 0 then return 0 end
    return 5 + 3 * level
end

function KOS.BountyLevel(score)
    if not score or score < 20 then return 0 end
    return math.floor((score / 20) ^ (2 / 3) + EPS)
end

function KOS.ScoreForLevel(level) return 20 * level ^ 1.5 end

function KOS.BountyBand(level)
    for _, b in ipairs(KOS.BOUNTY_BANDS) do
        if level >= b.min then return b end
    end
end

-- Progress (0..1) from the current level to the next.
function KOS.BountyProgress(score)
    local lvl = KOS.BountyLevel(score)
    local lo, hi = (lvl == 0) and 0 or KOS.ScoreForLevel(lvl), KOS.ScoreForLevel(lvl + 1)
    return math.max(0, math.min(1, (score - lo) / (hi - lo)))
end

local HUNTER_BANDS = {
    { name = "Tracker", color = "ffffffff" }, { name = "Scout", color = "ffbbffbb" },
    { name = "Bounty Hunter", color = "ff1eff00" }, { name = "Manhunter", color = "ff00ccaa" },
    { name = "Avenger", color = "ff0070dd" }, { name = "Revenger", color = "ff6a5acd" },
    { name = "Executioner", color = "ffa335ee" }, { name = "Slayer", color = "ffff66cc" },
    { name = "Warlord", color = "ffff8000" }, { name = "Grim Reaper", color = "ffff2020" },
}
local ROMAN = { "I", "II", "III", "IV", "V" }

function KOS.HunterLevel(points)
    if not points or points < 10 then return 0 end
    return math.floor((points / 10) ^ (1 / 1.6) + EPS)
end

function KOS.PointsForHunterLevel(level) return math.ceil(10 * level ^ 1.6 - EPS) end

-- { level, name, color, nextAt, progress }
function KOS.HunterRank(points)
    points = points or 0
    local lvl = KOS.HunterLevel(points)
    local r = { level = lvl }
    if lvl == 0 then
        r.name, r.color = "Recruit", "ff9d9d9d"
    elseif lvl <= #HUNTER_BANDS * 5 then
        local band = HUNTER_BANDS[math.ceil(lvl / 5)]
        r.name, r.color = band.name .. " " .. ROMAN[(lvl - 1) % 5 + 1], band.color
    else
        r.name, r.color = "Legend " .. (lvl - #HUNTER_BANDS * 5), "ffe6cc80"
    end
    local lo = (lvl == 0) and 0 or KOS.PointsForHunterLevel(lvl)
    r.nextAt = KOS.PointsForHunterLevel(lvl + 1)
    r.progress = math.max(0, math.min(1, (points - lo) / (r.nextAt - lo)))
    return r
end

function KOS.RankTag(points)
    local r = KOS.HunterRank(points)
    return "|c" .. r.color .. r.name .. "|r"
end

------------------------------------------------------------------------
-- Utilities
------------------------------------------------------------------------

function KOS:Print(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local s = tostring((select(i, ...)))
        if s ~= "" then parts[#parts + 1] = s end
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cffff3333Utu|r: " .. table.concat(parts, " "))
end

-- This addon's version ("0.7.4"), and that as a comparable number (nil if
-- it isn't plain x.y.z).
function KOS:Version()
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return get and get(ADDON, "Version") or "?"
end

function KOS.VersionNum(v)
    if type(v) ~= "string" then return nil end
    local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    a, b, c = tonumber(a), tonumber(b), tonumber(c)
    if a > 99 or b > 999 or c > 999 then return nil end
    return a * 1000000 + b * 1000 + c
end

-- Trim a string to at most `max` bytes without splitting a UTF-8 character.
function KOS.Utf8Truncate(s, max)
    if #s <= max then return s end
    local cut = max
    while cut > 0 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return s:sub(1, cut)
end

-- User text shown in chat/tooltips and sent over the wire: strip escape
-- sequences and our field separators.
function KOS.CleanText(s, max)
    s = tostring(s or "")
    s = s:gsub("|", ""):gsub("[\t\r\n]", " ")
    s = strtrim(s)
    return KOS.Utf8Truncate(s, max or KOS.NOTE_MAX)
end

-- Server time, strictly later than every timestamp passed in.
function KOS:Now(...)
    local t = GetServerTime and GetServerTime() or time()
    for i = 1, select("#", ...) do
        local x = select(i, ...)
        if x and t <= x then t = x + 1 end
    end
    return t
end

function KOS.Ago(ts)
    if not ts then return "never" end
    local d = (GetServerTime and GetServerTime() or time()) - ts
    if d < 60 then return "just now" end
    if d < 3600 then return math.floor(d / 60) .. "m ago" end
    if d < 86400 then return math.floor(d / 3600) .. "h ago" end
    return math.floor(d / 86400) .. "d ago"
end

------------------------------------------------------------------------
-- Notifications
--
-- Every guild event lands in the Activity feed (in the window). Chat only
-- gets what passes the "chatter" setting, rate-limited:
--   me      about you (your claims, you were avenged/rescued, rank-ups)
--   nearby  help calls / sightings in your zone
--   big     top bounty claimed, Most Wanted+, new KoS guild, season reset
--   info    everything else (feed only unless chatter = "all")
------------------------------------------------------------------------

local chatTimes, moreQueued = {}, false

function KOS:Feed()
    local key = self:ListKey() or "_personal"
    self.db.feeds = self.db.feeds or {}
    self.db.feeds[key] = self.db.feeds[key] or {}
    return self.db.feeds[key]
end

-- chatOnly: the event is already in the list data (a mark, gank, claim...),
-- which the Activity tab reads directly, so it isn't added to the feed.
-- by: the guildie the entry is about (sightings, marks), so muting them
-- hides it.
function KOS:Notify(priority, text, chatOnly, by)
    if not chatOnly then
        local feed = self:Feed()
        table.insert(feed, 1, { t = GetServerTime(), p = priority, text = text, by = by })
        for i = #feed, 151, -1 do feed[i] = nil end
    end
    if self.OnFeed then self:OnFeed() end
    if by and self:IsMuted(by) then return end

    local mode = self.S.chatter or "important"
    local show = priority == "me"
        or mode == "all"
        or (mode == "important" and priority ~= "info")
    if not show then return end
    if priority ~= "me" then
        local now = GetTime()
        for i = #chatTimes, 1, -1 do
            if now - chatTimes[i] > 10 then table.remove(chatTimes, i) end
        end
        if #chatTimes >= 4 then
            if not moreQueued then
                moreQueued = true
                C_Timer.After(10, function()
                    moreQueued = false
                    KOS:Print("|cff888888More guild activity in the window's Activity tab (/kos).|r")
                end)
            end
            return
        end
        chatTimes[#chatTimes + 1] = now
    end
    self:Print(text)
end

-- The Activity tab: everything in the list itself (marks, pardons, ganks,
-- claims, struck claims, season resets), however it arrived (live, or
-- synced later), plus the feed of things that only exist as events
-- (sightings, help calls, rank-ups). Newest first.
function KOS:Activity(limit)
    limit = limit or 150
    local items, me = {}, self:MyKey()
    local function add(t, p, text) if type(t) == "number" then items[#items + 1] = { t = t, p = p, text = text } end end
    local function isMe(name) return name and self:Canonical(name) == me end
    local function who(name) return isMe(name) and "You" or self:Display(name) end
    local function red(name) return "|cffff6060" .. self:Display(name) .. "|r" end
    local function where(zone) return (zone and zone ~= "") and (" in " .. zone) or "" end
    local list = self:List()
    for _, T in pairs(list.targets) do
        for _, v in pairs(T.votes or {}) do
            if not v.del and not (T.cleared and v.t <= T.cleared.t) and not self:IsMuted(v.by) then
                add(v.t, isMe(v.by) and "me" or "info", who(v.by) .. " marked " .. red(T.n)
                    .. ((v.note and v.note ~= "") and (": " .. v.note) or ""))
            end
        end
        if T.cleared then add(T.cleared.t, "info", who(T.cleared.by) .. " pardoned " .. self:Display(T.n)) end
    end
    for _, d in pairs(list.deaths) do
        add(d.t, isMe(d.victim) and "me" or "info", (isMe(d.victim) and "You were" or (self:Display(d.victim) .. " was"))
            .. " killed by " .. red(d.killer) .. where(d.zone))
    end
    for _, k in pairs(list.kills) do
        local helped = (k.rev and (", avenging " .. (isMe(k.rev) and "you" or self:Display(k.rev))))
            or (k.res and (", rescuing " .. (isMe(k.res) and "you" or self:Display(k.res)))) or ""
        local v = tonumber(k.v) or 0
        add(k.t, (isMe(k.by) or isMe(k.rev) or isMe(k.res)) and "me" or "big",
            "|cff40ff40" .. who(k.by) .. "|r" .. (k.assist and " assisted on " or " claimed the bounty on ")
            .. self:Display(k.target) .. helped .. " (+" .. v .. (v == 1 and " point)" or " points)") .. where(k.zone))
    end
    for id, x in pairs(list.struck) do
        local by, target = strsplit("|", id)
        add(x.t, "info", who(x.by) .. " struck " .. self:Display(by) .. "'s claim on " .. self:Display(target))
    end
    if list.season then add(list.season.t, "big", who(list.season.by) .. " started a new bounty season") end
    for _, e in ipairs(self:Feed()) do
        if not (e.by and self:IsMuted(e.by)) then items[#items + 1] = e end
    end
    table.sort(items, function(a, b) return a.t > b.t end)
    for i = #items, limit + 1, -1 do items[i] = nil end
    return items
end

-- Personal mute: guildies whose marks and sightings you don't want. Only
-- changes what you see and get alerted on; bounties, points and the
-- leaderboard stay the same for everyone (every client must agree on them).
function KOS:IsMuted(name)
    local muted = self.S and self.S.muted
    if not muted or not next(muted) then return false end
    local key = name and self:Canonical(name)
    return key ~= nil and muted[key] ~= nil
end

function KOS:SetMuted(name, on)
    local key, full = self:Canonical(name)
    if not key then self:Print("Not a valid character name: " .. tostring(name)); return false end
    if key == self:MyKey() then self:Print("You can't mute yourself."); return false end
    self.S.muted[key] = on and full or nil
    if on then
        self:Print("Muted " .. self:Display(full) .. ": their marks won't alert you, and their marks and sightings"
            .. " are hidden from your Activity and chat. Bounties and points don't change. /utu unmute "
            .. self:Display(full) .. " to undo.")
    else
        self:Print("Unmuted " .. self:Display(full) .. ".")
    end
    if self.RefreshUI then self:RefreshUI() end
    return true
end

function KOS:MutedList()
    local out = {}
    for _, full in pairs(self.S.muted) do out[#out + 1] = full end
    table.sort(out)
    return out
end

-- True when the only reason T is listed is marks from guildies you muted
-- (no other marks, no ganks): no alerts, skulls or badges for them.
function KOS:OnlyMutedMarks(T)
    if not T or T.virtual or not next(self.S.muted) then return false end
    local votes = self:ActiveVotes(T)
    if #votes == 0 then return false end
    for _, v in ipairs(votes) do
        if not self:IsMuted(v.by) then return false end
    end
    local key = self:Canonical(T.n)
    return not (key and #self:GanksBy(key) > 0)
end

-- Is a "Zone - Subzone" string in the zone I'm in?
function KOS:InMyZone(zone)
    local mine = GetRealZoneText() or ""
    if not zone or zone == "" or mine == "" then return false end
    return zone == mine or zone:sub(1, #mine + 3) == mine .. " - "
end

-- Banners and sounds are suppressed in battlegrounds/arenas unless enabled.
function KOS:InPvPInstance()
    local inInstance, kind = IsInInstance()
    return inInstance and (kind == "pvp" or kind == "arena")
end

------------------------------------------------------------------------
-- Location
--
-- Positions are map IDs plus normalised x/y (what the world map uses).
-- Distances are only computed within the same map, converted to yards
-- with C_Map.GetWorldPosFromMapPos when the client has it.
------------------------------------------------------------------------

function KOS:MyPosition()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return nil end
    local map = C_Map.GetBestMapForUnit("player")
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return nil end
    local x, y = pos:GetXY()
    if not x or (x == 0 and y == 0) then return nil end
    return map, x, y
end

local function toYards(map, x, y)
    if not (C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
    local _, world = C_Map.GetWorldPosFromMapPos(map, CreateVector2D(x, y))
    if not world then return nil end
    return world:GetXY()
end

local DIRS = { "E", "SE", "S", "SW", "W", "NW", "N", "NE" }

-- Yards and compass direction from me to a point on `map`, or nil if
-- we're on different maps or the position is unknown.
function KOS:DistanceTo(map, x, y)
    local myMap, mx, my = self:MyPosition()
    if not myMap or not map or myMap ~= map or not x or not y then return nil end
    local ax, ay = toYards(map, mx, my)
    local bx, by = toYards(map, x, y)
    local dist
    if ax and bx then
        dist = math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
    else
        dist = math.sqrt((mx - x) ^ 2 + (my - y) ^ 2) * 3000 -- rough: a zone is a few thousand yards across
    end
    -- map y grows southwards
    local angle = math.deg(math.atan2(y - my, x - mx))
    local dir = DIRS[(math.floor((angle + 22.5) / 45) % 8) + 1]
    if dist ~= dist or not dir then return nil end
    return dist, dir
end

------------------------------------------------------------------------
-- Zone threat: recent KoS sightings and guildie deaths in a zone.
------------------------------------------------------------------------

local function zoneOf(s) return s and (s:match("^(.-) %- ") or s) or "" end
KOS.ZoneOf = zoneOf

-- { zone, seen = { T, ... } (by bounty), ganks, level (0-3), label, color }
function KOS:ZoneThreat(zone)
    zone = zone or GetRealZoneText() or ""
    local now = GetServerTime()
    local seen, ganks = {}, 0
    for _, T in pairs(self:Targets()) do
        if T.on and T.seen and now - T.seen <= self.THREAT_WINDOW and zoneOf(T.zone) == zone then
            seen[#seen + 1] = T
        end
    end
    table.sort(seen, function(a, b) return self:ScoreOf(a) > self:ScoreOf(b) end)
    for _, d in pairs(self:Deaths()) do
        if now - d.t <= self.THREAT_WINDOW and zoneOf(d.zone) == zone then ganks = ganks + 1 end
    end
    local score = #seen + 2 * ganks
    local r = { zone = zone, seen = seen, ganks = ganks, score = score }
    if score == 0 then r.level, r.label, r.color = 0, "Clear", "ff40ff40"
    elseif score <= 2 then r.level, r.label, r.color = 1, "Low threat", "ffffd100"
    elseif score <= 5 then r.level, r.label, r.color = 2, "High threat", "ffff8000"
    else r.level, r.label, r.color = 3, "Deadly", "ffff2020" end
    return r
end

function KOS:ThreatText(r)
    local parts = {}
    if #r.seen > 0 then
        local names = {}
        for i = 1, math.min(3, #r.seen) do
            names[#names + 1] = self:Display(r.seen[i].n) .. " Lv " .. self:LevelOf(r.seen[i])
        end
        parts[#parts + 1] = #r.seen .. " KoS seen (" .. table.concat(names, ", ") .. (#r.seen > 3 and ", ..." or "") .. ")"
    end
    if r.ganks > 0 then parts[#parts + 1] = r.ganks .. (r.ganks == 1 and " guildie" or " guildies") .. " ganked" end
    return "|c" .. r.color .. r.zone .. ": " .. r.label .. "|r - " .. table.concat(parts, ", ") .. " in the last 30 min"
end

------------------------------------------------------------------------
-- Names
--
-- Players are keyed by lowercase "name-realm". Stored names are always the
-- full "Name-Realm" so they mean the same thing to every guildie.
------------------------------------------------------------------------

local myRealm
function KOS:MyRealm()
    if not myRealm or myRealm == "" then
        myRealm = (GetNormalizedRealmName and GetNormalizedRealmName())
            or (GetRealmName() or ""):gsub("[%s%-']", "")
    end
    return myRealm
end

-- WoW: Forever names can be two words, and its unit APIs hand the second
-- word back as the realm: UnitName gives "Pi", "Target" for "Pi Target",
-- which reads as "Pi-Target". Real Forever realm names have digits
-- (CAMWOWAU1Realm2PvP), so on Forever a letters-only "realm" that isn't
-- ours is the rest of the name.
local foreverNames
function KOS:ForeverNames()
    if foreverNames == nil then
        local iface = GetBuildInfo and select(4, GetBuildInfo())
        foreverNames = issecretvalue ~= nil and type(iface) == "number" and iface >= 16000 and iface < 17000
    end
    return foreverNames
end

-- (name, realm) as the game gave them -> (name, realm), with a misread
-- second word moved back into the name.
function KOS:JoinSpacedName(n, r)
    if not (n and r and r ~= "" and self:ForeverNames()) then return n, r end
    local rr = strtrim(r)
    if rr == "" or rr:find("[%d%p%c]") then return n, r end
    if rr:gsub("%s", ""):lower() == (self:MyRealm() or ""):lower() then return n, r end
    return strtrim(n) .. " " .. rr, nil
end

-- Returns key, fullName ("Name-Realm") or nil for invalid input.
function KOS:Canonical(name)
    if type(name) ~= "string" then return nil end
    name = strtrim(name)
    if name == "" then return nil end
    local n, r = strsplit("-", name, 2)
    if not n then return nil end
    n, r = self:JoinSpacedName(n, r)
    -- WoW: Forever allows names with spaces ("Mietta Grace"); classic names
    -- are one word of at most 12 letters (24 bytes in UTF-8)
    n = strtrim(n):gsub("%s+", " ")
    local multi = n:find(" ", 1, true) ~= nil
    if n == "" or #n > (multi and 36 or 24) or n:find("[%d%p%c]") then return nil end
    if r and #r > 40 then return nil end
    if r and r ~= "" then
        -- realms are letters and digits ("CAMWOWAU1Realm2PvP"); dropping
        -- everything else also keeps UI escape codes (|c, |T, |H) out of names
        r = r:gsub("[%s%p%c]", "")
        if r == "" then return nil end
    else
        r = self:MyRealm()
    end
    -- "gankdude" -> "Gankdude", "kind eyes" -> "Kind Eyes": the game
    -- capitalises each word of a name (the key is lowercase either way)
    n = n:gsub("(%S)(%S*)", function(first, rest) return first:upper() .. rest:lower() end)
    local full = n .. "-" .. r
    return full:lower(), full
end

-- "Name-MyRealm" -> "Name"; other realms keep their suffix.
function KOS:Display(full)
    if not full then return "?" end
    local n, r = strsplit("-", full, 2)
    if not r or r == self:MyRealm() then return n end
    return full
end

-- Name-Realm of a player unit, or nil (see KOS:UnitInfo in Caps.lua).
function KOS:UnitFull(unit)
    local info = self:UnitInfo(unit)
    return info and info.full
end

local myName, myKey
function KOS:MyName()
    if not myName then myKey, myName = self:Canonical(UnitName("player")) end
    return myName
end
function KOS:MyKey()
    self:MyName()
    return myKey
end

------------------------------------------------------------------------
-- Storage
--
-- list.targets[key] = {
--   n = "Name-Realm", guid, class,
--   votes = { [reporterKey] = { by = "Reporter-Realm", note, t, del } },
--   cleared = { by, t },   -- pardon: marks made at/before t no longer count
--   guild, guildT,         -- their guild as last observed, and when (synced)
--   w,                     -- derived: number of active marks (on the list if > 0)
--   seen, zone, seenBy,    -- local sighting info, not synced
-- }
-- list.kills[id] = { target = "Name-Realm", by = "Hunter-Realm", t, v, zone, guild, rev, res, assist }
--   rev = guildie avenged (the target had killed them shortly before)
--   res = guildie rescued (the target was attacking them)
--   assist = true if `by` helped a grouped guildie get the killing blow
--   id = hunterKey|targetKey|t; v = points paid out
-- list.season = { by, t }  -- leaderboard reset: kills at/before t don't count
-- list.struck[id] = { by, t, kt }  -- officer voided a claim (kt = the kill's time)
-- list.deaths[id] = { victim, killer, t, zone }  -- a guildie was ganked
--   id = victimKey|killerKey|t. Raises the killer's bounty; enables revenge.
------------------------------------------------------------------------

function KOS:InitDB()
    local upgrading = UtuDB ~= nil
    UtuDB = UtuDB or {}
    local db = UtuDB
    -- Version the "What's new" message last covered. Saved data from before
    -- 0.7.4 (which added it) gets 0.7.3, so they hear about 0.7.4.
    if db.seenVersion == nil and upgrading then db.seenVersion = "0.7.3" end
    db.lists = db.lists or {}
    db.charGuild = db.charGuild or {}
    db.settings = db.settings or {}
    for k, v in pairs(self.DEFAULTS) do
        if db.settings[k] == nil then db.settings[k] = v end
    end
    self.db = db
    self.S = db.settings
    if type(db.settings.muted) ~= "table" then db.settings.muted = {} end -- key -> Name-Realm
    -- 0.6.9: marks, ganks and claims moved out of the feed (Activity reads
    -- them from the list); drop the copies older versions stored there
    if (db.feedVersion or 1) < 2 then
        local derived = { " marked ", " was killed by ", " claimed the bounty on ", " pardoned ", " assisted on ",
            " struck a bounty claim", " started a new bounty season" }
        for _, feed in pairs(db.feeds or {}) do
            for i = #feed, 1, -1 do
                for _, pat in ipairs(derived) do
                    if type(feed[i].text) == "string" and feed[i].text:find(pat, 1, true) then table.remove(feed, i); break end
                end
            end
        end
        db.feedVersion = 2
    end

    for _, list in pairs(db.lists) do
        -- migrate 0.1.x (one record per player) to per-guildie marks
        if list.entries and not list.targets then
            list.targets = {}
            for key, e in pairs(list.entries) do
                local rkey = (not e.del) and self:Canonical(e.by)
                if rkey then
                    list.targets[key] = {
                        n = e.n, guid = e.guid, class = e.class, seen = e.seen, zone = e.zone, seenBy = e.seenBy,
                        votes = { [rkey] = { by = e.by, note = e.note or "", t = e.t } },
                    }
                end
            end
            list.entries = nil
        end
        list.targets = list.targets or {}
        list.kills = list.kills or {}
        list.struck = list.struck or {}
        list.deaths = list.deaths or {}
        self:DropDamaged(list)
        if self:ForeverNames() then self:RepairNames(list) end
        for _, T in pairs(list.targets) do
            T.votes = T.votes or {}
            self:Recalc(T)
        end
    end
end

-- Drop saved entries too damaged to use (hand-edited or corrupted saved
-- data), so one bad record can't stop the addon loading.
function KOS:DropDamaged(list)
    local function ok(x, ...)
        if type(x) ~= "table" or type(x.t) ~= "number" or x.t ~= x.t then return false end
        for i = 1, select("#", ...) do
            if type(x[select(i, ...)]) ~= "string" then return false end
        end
        return true
    end
    for key, T in pairs(list.targets) do
        if type(T) ~= "table" or type(T.n) ~= "string" then
            list.targets[key] = nil
        else
            if type(T.votes) ~= "table" then T.votes = {} end
            for vk, v in pairs(T.votes) do
                if not ok(v, "by") then T.votes[vk] = nil end
            end
            if T.cleared ~= nil and not ok(T.cleared, "by") then T.cleared = nil end
        end
    end
    for id, k in pairs(list.kills) do
        if not ok(k, "by", "target") then list.kills[id] = nil end
    end
    for id, d in pairs(list.deaths) do
        if not ok(d, "victim", "killer") then list.deaths[id] = nil end
    end
    for id, x in pairs(list.struck) do
        if type(x) ~= "table" then list.struck[id] = nil end
    end
end

-- Re-key a list's names with the current Canonical, e.g. "Pi-Target"
-- saved before two-word Forever names were read right becomes
-- "Pi Target-<realm>". Entries that land on an existing key are merged.
-- Safe to run on every load: names already right are left alone.
function KOS:RepairNames(list)
    local function fix(name)
        if type(name) ~= "string" then return name end
        local _, full = self:Canonical(name)
        return full or name
    end
    local function newer(a, b) return not a or (b and (b.t or 0) > (a.t or 0)) end

    local targets = {}
    for key, T in pairs(list.targets) do
        local nkey = self:Canonical(T.n) or key
        T.n = fix(T.n)
        local votes = {}
        for vk, v in pairs(T.votes or {}) do
            local rk = self:Canonical(v.by) or vk
            v.by = fix(v.by)
            if newer(votes[rk], v) then votes[rk] = v end
        end
        T.votes = votes
        local cur = targets[nkey]
        if not cur then
            targets[nkey] = T
        else
            for vk, v in pairs(T.votes) do
                if newer(cur.votes[vk], v) then cur.votes[vk] = v end
            end
            if T.cleared and newer(cur.cleared, T.cleared) then cur.cleared = T.cleared end
            for k, v in pairs(T) do
                if cur[k] == nil and type(v) ~= "table" then cur[k] = v end
            end
        end
    end
    list.targets = targets

    local deaths = {}
    for _, d in pairs(list.deaths) do
        d.victim, d.killer = fix(d.victim), fix(d.killer)
        local nid = self.DeathId(d)
        if not deaths[nid] then deaths[nid] = d end
    end
    list.deaths = deaths

    local kills = {}
    for _, k in pairs(list.kills) do
        k.target, k.by, k.rev, k.res = fix(k.target), fix(k.by), fix(k.rev), fix(k.res)
        local nid = self.KillId(k)
        local cur = kills[nid]
        if not cur or (tonumber(k.v) or 0) < (tonumber(cur.v) or 0) then kills[nid] = k end
    end
    list.kills = kills

    local struck = {}
    for id, x in pairs(list.struck) do
        local by, target, t = strsplit("|", id)
        local nid = (t and (self:Canonical(by) or by) .. "|" .. (self:Canonical(target) or target) .. "|" .. t) or id
        struck[nid] = struck[nid] or x
    end
    list.struck = struck
end

-- Which list is in use: one per guild, or a personal list when unguilded.
-- Cached (the combat log calls this a lot) and reset on guild events.
local listKey
function KOS:InvalidateListKey() listKey = nil end

function KOS:ListKey()
    if listKey then return listKey end
    local me = self:MyName()
    if not IsInGuild() then
        self.db.charGuild[me] = nil
        listKey = "_personal"
        return listKey
    end
    local g, _, _, realm = GetGuildInfo("player")
    if g then
        listKey = g .. "-" .. ((realm and realm ~= "") and realm or self:MyRealm())
        self.db.charGuild[me] = listKey
        return listKey
    end
    return self.db.charGuild[me] -- guild info not loaded yet; don't cache
end

function KOS:IsGuildList()
    local k = self:ListKey()
    return k ~= nil and k ~= "_personal"
end

local EMPTY_LIST = { targets = {}, kills = {}, struck = {}, deaths = {} } -- stand-in while guild info loads; never written
function KOS:List()
    local key = self:ListKey()
    if not key then return EMPTY_LIST end
    local lists = self.db.lists
    local l = lists[key]
    if not l then
        l = { targets = {}, kills = {}, struck = {}, deaths = {} }
        lists[key] = l
    end
    return l
end
function KOS:Targets() return self:List().targets end
function KOS:Kills() return self:List().kills end
function KOS:Deaths() return self:List().deaths end
local EMPTY = EMPTY_LIST.targets

-- A mark counts while it's not deleted and younger than MARK_EXPIRY_HALFLIVES
-- half-lives. Re-marking (or getting killed by them again) refreshes it.
function KOS:MarkActive(v, now)
    if v.del then return false end
    local h = self:HalfLife()
    if h <= 0 then return true end
    return (now or GetServerTime()) - v.t <= h * self.MARK_EXPIRY_HALFLIVES
end

-- T.w = active marks; T.on = on the list: any active mark, or ganks on
-- record since the last pardon (younger than the mark expiry). Ganks are
-- evidence, so removing the last mark doesn't hide an active ganker.
function KOS:Recalc(T)
    local w, now = 0, GetServerTime()
    for _, v in pairs(T.votes) do
        if self:MarkActive(v, now) then w = w + 1 end
    end
    T.w = w
    local on = w > 0
    if not on and self.GanksBy then
        local h, pardon = self:HalfLife(), T.cleared and T.cleared.t or -1
        for _, d in ipairs(self:GanksBy(self:Canonical(T.n))) do
            if d.t > pardon and (h <= 0 or now - d.t <= h * self.MARK_EXPIRY_HALFLIVES) then on = true; break end
        end
    end
    T.on = on
    self:InvalidateGuildStats(true)
end

function KOS:RecalcAll()
    for _, T in pairs(self:Targets()) do self:Recalc(T) end
    self:InvalidateIndex()
end

function KOS:GetTarget(key, full, create)
    local targets = self:Targets()
    local T = targets[key]
    if not T and create and targets ~= EMPTY then
        T = { n = full, votes = {}, w = 0, on = false }
        targets[key] = T
    end
    return T
end

local guidIndex, guidIndexFor = {}, nil
function KOS:InvalidateIndex() guidIndexFor = nil end

-- Active target (at least one mark) by key, or by GUID to catch renames.
function KOS:Lookup(key, guid)
    local targets = self:Targets()
    local T = key and targets[key]
    if T and T.on then return T, key end
    if guid then
        if guidIndexFor ~= targets then
            wipe(guidIndex)
            for k, x in pairs(targets) do
                if x.guid and x.on then guidIndex[x.guid] = k end
            end
            guidIndexFor = targets
        end
        local k = guidIndex[guid]
        T = k and targets[k]
        if T and T.on then return T, k end
    end
end

function KOS:LookupUnit(unit)
    local info = self:UnitInfo(unit)
    local key = info and self:Canonical(info.full)
    if not key then return nil end
    return self:Lookup(key, info.guid)
end

function KOS:ActiveVotes(T)
    local out = {}
    for _, v in pairs(T.votes) do
        if self:MarkActive(v) then out[#out + 1] = v end
    end
    table.sort(out, function(a, b) return a.t < b.t end)
    return out
end

-- Most recent non-empty note, and its author.
function KOS:TopNote(T)
    local best
    for _, v in pairs(T.votes) do
        if self:MarkActive(v) and v.note ~= "" and (not best or v.t > best.t) then best = v end
    end
    if best then return best.note, best.by end
    return ""
end

function KOS:MyVote(T)
    local v = T and T.votes[self:MyKey()]
    if v and self:MarkActive(v) then return v end
end

------------------------------------------------------------------------
-- Merging (shared by local edits and sync)
------------------------------------------------------------------------

-- One guildie's mark on one player. Each guildie only ever edits their own
-- mark, so the newest timestamp per (player, guildie) wins.
function KOS:MergeVote(key, full, v, guid, class)
    local T = self:GetTarget(key, full, true)
    if not T then return false end
    if guid and not T.guid then T.guid = guid; self:InvalidateIndex() end
    if class and not T.class then T.class = class end
    if T.cleared and v.t <= T.cleared.t then return false end -- made before a pardon
    local rkey = self:Canonical(v.by)
    if not rkey then return false end
    local cur = T.votes[rkey]
    if cur and cur.t >= v.t then return false end
    T.votes[rkey] = { by = v.by, note = v.note or "", t = v.t, del = v.del or nil }
    self:Recalc(T)
    self:InvalidateIndex()
    return true
end

-- A pardon voids every mark made at or before its timestamp.
function KOS:MergeClear(key, full, c)
    local T = self:GetTarget(key, full, true)
    if not T then return false end
    local cur = T.cleared
    if cur and (cur.t > c.t or (cur.t == c.t and cur.by >= c.by)) then return false end
    T.cleared = { by = c.by, t = c.t }
    for rk, v in pairs(T.votes) do
        if v.t <= c.t then T.votes[rk] = nil end
    end
    self:Recalc(T)
    self:InvalidateIndex()
    return true
end

function KOS.KillId(k)
    return (KOS:Canonical(k.by) or "?") .. "|" .. (KOS:Canonical(k.target) or "?") .. "|" .. k.t
end

-- A bounty claim. Claims are immutable, so merging is just set union.
function KOS:MergeKill(k)
    local list = self:List()
    if list == EMPTY_LIST or k.t < self:KillHorizon() then return false end
    local id = self.KillId(k)
    if list.struck[id] then return false end
    local v = math.max(0, math.min(self.MAX_CLAIM, math.floor(tonumber(k.v) or 0)))
    local cur = list.kills[id]
    if cur then
        -- same claim with a different value (forged or buggy): everyone keeps the lower one
        if v < cur.v then cur.v = v; self:InvalidateKills(); return true end
        return false
    end
    list.kills[id] = { target = k.target, by = k.by, t = k.t, v = v, zone = k.zone,
        guild = (k.guild and k.guild ~= "") and k.guild or nil,
        rev = (k.rev and k.rev ~= "") and k.rev or nil,
        res = (k.res and k.res ~= "") and k.res or nil,
        assist = k.assist or nil }
    self:InvalidateKills()
    self:InvalidateGuildStats()
    return true
end

-- Which guild a target is in. Newest observation wins.
function KOS:MergeGuild(key, full, g, t)
    local T = self:GetTarget(key, full, true)
    if not T then return false end
    if T.guildT and (T.guildT > t or (T.guildT == t and (T.guild or "") >= g)) then return false end
    T.guild, T.guildT = g, t
    self:InvalidateGuildStats()
    return true
end

-- Officer voids a claim. The tombstone stops it coming back via sync.
function KOS:MergeStrike(id, x)
    local list = self:List()
    if list == EMPTY_LIST or x.kt < self:KillHorizon() then return false end
    if list.struck[id] then return false end
    list.struck[id] = { by = x.by, t = x.t, kt = x.kt }
    list.kills[id] = nil
    self:InvalidateKills()
    self:InvalidateGuildStats()
    return true
end

-- Early season reset by an officer. Kills are kept: seasons are just a
-- time window over the claim history.
function KOS:MergeSeason(s)
    local list = self:List()
    if list == EMPTY_LIST then return false end
    local cur = list.season
    if cur and (cur.t > s.t or (cur.t == s.t and cur.by >= s.by)) then return false end
    list.season = { by = s.by, t = s.t }
    self:InvalidateKills()
    return true
end

function KOS:SeasonLength()
    local w = self:GuildTag("season")
    if w == nil then w = self.DEFAULT_SEASON_WEEKS end
    return w * 7 * 86400
end

-- Current season: start, ends (nil for manual seasons), number, and the
-- previous season's window (prevStart, prevEnd) if known.
function KOS:SeasonBounds(now)
    now = now or GetServerTime()
    local len = self:SeasonLength()
    local start, ends, num, prevStart, prevEnd = 0, nil, nil, nil, nil
    if len > 0 then
        local n = math.floor((now - self.SEASON_EPOCH) / len)
        start, ends, num = self.SEASON_EPOCH + n * len, self.SEASON_EPOCH + (n + 1) * len, n + 1
        prevStart, prevEnd = start - len, start
    end
    local manual = self:List().season
    if manual and manual.t >= start and manual.t <= now then
        prevStart, prevEnd = (len > 0) and start or nil, manual.t
        start = manual.t
    end
    return start, ends, num, prevStart, prevEnd
end

function KOS:KillHorizon()
    local now = GetServerTime()
    return now - now % 86400 - self.KILL_HORIZON
end

function KOS:PruneKills()
    local h, list = self:KillHorizon(), self:List()
    for id, k in pairs(list.kills) do
        if k.t < h then list.kills[id] = nil; self:InvalidateKills() end
    end
    for id, x in pairs(list.struck) do
        if x.kt < h then list.struck[id] = nil end
    end
end

function KOS.DeathId(d)
    return (KOS:Canonical(d.victim) or "?") .. "|" .. (KOS:Canonical(d.killer) or "?") .. "|" .. d.t
end

-- Ganks older than DEATH_HORIZON are dropped. Day-aligned so clients
-- agree on the cutoff.
function KOS:DeathHorizon()
    local now = GetServerTime()
    return now - now % 86400 - self.DEATH_HORIZON
end

function KOS:MergeDeath(d)
    local list = self:List()
    if list == EMPTY_LIST or d.t < self:DeathHorizon() then return false end
    local id = self.DeathId(d)
    if list.deaths[id] then return false end
    list.deaths[id] = { victim = d.victim, killer = d.killer, t = d.t, zone = d.zone }
    self:InvalidateGuildStats()
    local key, full = self:Canonical(d.killer)
    local T = key and self:GetTarget(key, full, true)
    if T then self:Recalc(T); self:InvalidateIndex() end
    self:ClearDistress(self:Canonical(d.killer), d.victim) -- too late to rescue; it's revenge now
    return true
end

function KOS:PruneDeaths()
    local h = self:DeathHorizon()
    local deaths = self:Deaths()
    for id, d in pairs(deaths) do
        if d.t < h then deaths[id] = nil; self:InvalidateGuildStats() end
    end
end

-- Calls fn(kind, ...) for every synced item:
--   "vote", T, v  |  "clear", T, c  |  "guild", T  |  "kill", k  |  "strike", id, x
--   "death", d  |  "season", s
function KOS:EachItem(fn)
    local list = self:List()
    for _, T in pairs(list.targets) do
        for _, v in pairs(T.votes) do fn("vote", T, v) end
        if T.cleared then fn("clear", T, T.cleared) end
        if T.guildT then fn("guild", T) end
    end
    for _, k in pairs(list.kills) do fn("kill", k) end
    self:PruneKills()
    for id, x in pairs(list.struck) do fn("strike", id, x) end
    self:PruneDeaths()
    for _, d in pairs(list.deaths) do fn("death", d) end
    if list.season then fn("season", list.season) end
end

-- Order-independent fingerprint of everything that syncs.
function KOS:Digest()
    local items = {}
    local list = self:List()
    self:PruneDeaths()
    self:PruneKills()
    for key, T in pairs(list.targets) do
        for rk, v in pairs(T.votes) do
            items[#items + 1] = key .. "|" .. rk .. ":" .. v.t .. ":" .. (v.del and 1 or 0)
        end
        if T.cleared then items[#items + 1] = key .. "|*:" .. T.cleared.t .. ":" .. T.cleared.by end
        if T.guildT then items[#items + 1] = key .. "|g:" .. T.guildT .. ":" .. T.guild end
    end
    for id, k in pairs(list.kills) do items[#items + 1] = "k|" .. id .. ":" .. k.v end
    for id in pairs(list.struck) do items[#items + 1] = "x|" .. id end
    for id in pairs(list.deaths) do items[#items + 1] = "d|" .. id end
    if list.season then items[#items + 1] = "s|" .. list.season.t .. ":" .. list.season.by end
    table.sort(items)
    local h = 5381
    for _, s in ipairs(items) do
        for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
        h = (h * 33 + 59) % 4294967296
    end
    return string.format("%08x", h), #items
end

------------------------------------------------------------------------
-- Bounty score (with decay)
--
-- score = sum over active marks of MARK_SCORE * decay(age of the mark)
--       + sum over ganks of GANK_SCORE * decay(age) * repeat factor
-- decay halves every half-life (officers set it; default 14 days).
-- Re-marking refreshes your mark. Repeat ganks of the same guildie on the
-- same day count half as much each time, so a colluding pair can't pump a
-- bounty quickly.
------------------------------------------------------------------------

function KOS:HalfLife()
    local d = self:GuildTag("halflife")
    if d == nil then d = self.DEFAULT_HALFLIFE_DAYS end
    return d * 86400
end

function KOS:Decay(age)
    local h = self:HalfLife()
    if h <= 0 or age <= 0 then return 1 end
    return 0.5 ^ (age / h)
end

local gankIndex -- killerKey -> list of deaths, oldest first
local function ganksBy(key)
    if not gankIndex then
        gankIndex = {}
        for _, d in pairs(KOS:Deaths()) do
            local k = KOS:Canonical(d.killer)
            if k then
                gankIndex[k] = gankIndex[k] or {}
                table.insert(gankIndex[k], d)
            end
        end
        for _, l in pairs(gankIndex) do table.sort(l, function(a, b) return a.t < b.t end) end
    end
    return gankIndex[key] or {}
end
function KOS:GanksBy(key) return ganksBy(key) end

local killIndex -- targetKey -> claimed kills (not assists), oldest first
-- Claims by different hunters within this many seconds on one target are
-- the same kill (several guildies credited by honour): it drains the bounty once.
KOS.KILL_CLUSTER = 30
local drainIndex
local function killsOn(key)
    if not killIndex then
        killIndex, drainIndex = {}, {}
        for _, k in pairs(KOS:Kills()) do
            if not k.assist then
                local tk = KOS:Canonical(k.target)
                if tk then
                    killIndex[tk] = killIndex[tk] or {}
                    table.insert(killIndex[tk], k)
                end
            end
        end
        for tk, l in pairs(killIndex) do
            table.sort(l, function(a, b) if a.t ~= b.t then return a.t < b.t end return a.by < b.by end)
            -- a claim joins the current kill if it's close in time and from a
            -- different hunter; the same hunter twice is two kills
            local d, start, hunters = {}, nil, nil
            for _, k in ipairs(l) do
                local hk = KOS:Canonical(k.by) or k.by
                if start and k.t - start <= KOS.KILL_CLUSTER and not hunters[hk] then
                    hunters[hk] = true
                else
                    d[#d + 1] = k
                    start, hunters = k.t, { [hk] = true }
                end
            end
            drainIndex[tk] = d
        end
    end
    return killIndex[key] or {}
end
-- One entry per distinct kill of `key` (for the bounty drain).
local function drainsOn(key)
    killsOn(key)
    return drainIndex[key] or {}
end
function KOS:KillsOn(key) return killsOn(key) end

function KOS:InvalidateKills()
    killIndex = nil
    self:InvalidateGuildStats()
end

-- excludeKey: leave out this guildie's mark and the ganks of them (so you
--   can't raise a bounty by dying to a friend and then collect it).
-- at: score as of this time (only counts what existed then).
-- forClaim: pricing a claim by excludeKey. Ignores other hunters' drains
--   from the last KILL_CLUSTER seconds, so everyone credited with one shared
--   kill is priced against the bounty as it was before that kill, whichever
--   claim arrived first.
function KOS:Score(T, excludeKey, at, upperBound, forClaim)
    local now = at or GetServerTime()
    local key = self:Canonical(T.n)
    local pardon = T.cleared and T.cleared.t or -1
    local s = 0
    for rk, v in pairs(T.votes) do
        if rk ~= excludeKey and not v.del and (upperBound or (v.t <= now and self:MarkActive(v, now))) then
            -- upperBound (audits): a mark refreshed after `at` probably existed at `at` too
            s = s + self.MARK_SCORE * self:Decay(math.max(0, now - v.t))
        end
    end
    local seen = {}
    for _, d in ipairs(ganksBy(key)) do
        if d.t > pardon and d.t <= now and self:Canonical(d.victim) ~= excludeKey then
            local pair = (self:Canonical(d.victim) or "") .. "|" .. math.floor(d.t / 604800)
            seen[pair] = (seen[pair] or 0) + 1
            s = s + self.GANK_SCORE * self:Decay(now - d.t) * 0.5 ^ (seen[pair] - 1)
        end
    end
    -- bounties get paid down by kills; they refill only if the target keeps ganking
    for _, k in ipairs(drainsOn(key)) do
        -- (a kill by the same hunter moments ago is a separate kill and does count)
        local sameKill = forClaim and now - k.t <= self.KILL_CLUSTER and self:Canonical(k.by) ~= excludeKey
        if k.t > pardon and k.t < now and not sameKill then
            s = s - self.KILL_DRAIN * self:Decay(now - k.t)
        end
    end
    return math.max(0, s)
end

-- Cached full score; recomputed when data changes or every 30s (decay).
local scoreVersion = 0
function KOS:DataVersion() return scoreVersion end
function KOS:ScoreOf(T)
    if T.virtual then return 0 end
    local now = GetTime()
    if T._sv ~= scoreVersion or not T._st or now - T._st > 30 then
        T._score, T._sv, T._st = self:Score(T), scoreVersion, now
    end
    return T._score
end

function KOS:LevelOf(T)
    if T.virtual then return 0 end
    return self.BountyLevel(self:ScoreOf(T))
end

function KOS:BountyRGB(T)
    if T.virtual then return 0.75, 0.75, 0.75 end
    local c = self.BountyBand(self:LevelOf(T)).rgb
    return c[1], c[2], c[3]
end

-- "Wanted Lv 14" in band colour (or the KoS guild for stand-ins)
function KOS:BountyTag(T)
    if T.virtual then return "|cffbbbbbbKoS guild <" .. (T.guild or "?") .. ">|r" end
    local lvl = self:LevelOf(T)
    local b = self.BountyBand(lvl)
    return "|c" .. b.color .. b.name .. " Lv " .. lvl .. "|r"
end

------------------------------------------------------------------------
-- Permissions
--
-- Officers set these in the guild information text (only GM/officers can
-- edit it, so members can't change the limits). Ranks are 0-based:
-- 0 = Guild Master.
--   KOS:rank=N      who can pardon, strike claims, reset seasons. Default 1.
--   KOS:addrank=N   who can mark players. Default: everyone.
--   KOS:guild=N     guild bounty level for whole-guild KoS. Default 25, 0 = off.
--   KOS:halflife=N  bounty half-life in days. Default 14, 0 = no decay.
-- Officers change these from the Officer tab, which edits the guild info.
-- Anyone can always remove their own mark.
------------------------------------------------------------------------

KOS.roster = {}

function KOS:RefreshRoster()
    wipe(self.roster)
    if not IsInGuild() then return end
    for i = 1, GetNumGuildMembers() do
        local name, _, rankIndex = GetGuildRosterInfo(i)
        local key = self:Canonical(name)
        if key then self.roster[key] = rankIndex end
    end
end

function KOS:RequestRoster()
    local now = GetTime()
    if self.lastRosterReq and now - self.lastRosterReq < 30 then return end
    self.lastRosterReq = now
    if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster()
    elseif GuildRoster then GuildRoster() end
end

-- The guild info text, read live out of combat and cached for combat: on
-- Forever, reading it in combat (e.g. from a tooltip) is a blocked action.
function KOS:GuildInfoText()
    if GetGuildInfoText and not (InCombatLockdown and InCombatLockdown()) then
        local ok, text = pcall(GetGuildInfoText)
        if ok and not KOS.IsSecret(text) then self.guildInfoCache = type(text) == "string" and text or "" end
    end
    return self.guildInfoCache or ""
end

function KOS:GuildTag(tag)
    if not IsInGuild() then return nil end
    local info = self:GuildInfoText():lower()
    local n = info:match("kos:%s*" .. tag .. "%s*=%s*(%d+)")
    return n and tonumber(n) or nil
end

function KOS:PardonRank() return self:GuildTag("rank") or self.DEFAULT_PARDON_RANK end
function KOS:MarkRank() return self:GuildTag("addrank") end

function KOS:RankOf(name)
    local key = self:Canonical(name)
    if key == self:MyKey() then return (select(3, GetGuildInfo("player"))) end
    return self.roster[key]
end

function KOS:CanMark(name)
    if not self:IsGuildList() then return true end
    local limit = self:MarkRank()
    if not limit then return true end
    local r = self:RankOf(name)
    return r ~= nil and r <= limit
end

function KOS:CanPardon(name)
    if not self:IsGuildList() then return true end
    local r = self:RankOf(name)
    return r ~= nil and r <= self:PardonRank()
end

function KOS:CanEditRules()
    if not IsInGuild() then return false end
    if C_GuildInfo and C_GuildInfo.CanEditOfficerNote and CanEditGuildInfo == nil then
        return C_GuildInfo.CanEditOfficerNote()
    end
    return CanEditGuildInfo and CanEditGuildInfo() or false
end

-- Write (or remove, with value nil) a KOS:tag=N in the guild info text,
-- keeping everything else in it. Returns true if it was saved.
function KOS:SetGuildRule(tag, value)
    if not self:CanEditRules() then
        self:Print("You don't have permission to edit the guild information.")
        return false
    end
    if InCombatLockdown and InCombatLockdown() then
        self:Print("Can't change guild rules in combat.")
        return false
    end
    local info = self:GuildInfoText()
    local pattern = "[Kk][Oo][Ss]:%s*" .. tag .. "%s*=%s*%d+"
    local repl = value and ("KOS:" .. tag .. "=" .. value) or ""
    local newInfo, n = info:gsub(pattern, repl, 1)
    if n == 0 and value then
        newInfo = info .. ((info ~= "" and not info:find("\n$")) and "\n" or "") .. repl
    end
    newInfo = newInfo:gsub("\n\n+$", "\n")
    if #newInfo > 500 then
        self:Print("The guild information is full; make some room and try again.")
        return false
    end
    local ok = pcall(SetGuildInfoText, newInfo)
    if not ok then self:Print("Couldn't save the guild information."); return false end
    self:Print("Guild rule saved: " .. (value and repl or ("KOS:" .. tag .. " removed (default)")))
    self:InvalidateGuildStats()
    return true
end

------------------------------------------------------------------------
-- Editing
------------------------------------------------------------------------

function KOS:Changed()
    self:InvalidateIndex()
    self:InvalidateGuildStats()
    if self.RefreshPlates then self:RefreshPlates() end
    if self.RefreshTargetBadge then self:RefreshTargetBadge() end
    if self.RefreshUI then self:RefreshUI() end
end

-- Add or update *my* mark on a player.
function KOS:Mark(name, note, guid, class)
    local key, full = self:Canonical(name)
    if not key then self:Print("Not a valid character name:", tostring(name)); return end
    if key == self:MyKey() then self:Print("You can't mark yourself."); return end
    if not self:CanMark(self:MyName()) then
        self:Print("Only guild rank " .. self:MarkRank() .. " and above can mark players (set in guild info).")
        return
    end
    local T = self:GetTarget(key, full, true)
    if not T then self:Print("Your guild hasn't loaded yet; try again in a moment."); return end
    local old = T.votes[self:MyKey()]
    local v = {
        by = self:MyName(),
        note = self.CleanText(note),
        t = self:Now(old and old.t, T.cleared and T.cleared.t),
    }
    T.votes[self:MyKey()] = v
    if guid and not T.guid then T.guid = guid end
    if class and not T.class then T.class = class end
    self:Recalc(T)
    if ns.Sync then ns.Sync:BroadcastVote(T, v) end
    if old and not old.del then
        self:Print("Updated your mark on", self:Display(full) .. " (refreshed) -", self:BountyTag(T))
    else
        self:Print("Marked", "|cffff6060" .. self:Display(full) .. "|r", "-", self:BountyTag(T))
    end
    if self.MarkedInView then self:MarkedInView(key) end
    self:Changed()
end

-- Remove *my* mark.
function KOS:Unmark(name)
    local key = self:Canonical(name)
    local T = key and self:GetTarget(key)
    local old = T and T.votes[self:MyKey()]
    if not old or old.del then self:Print("You haven't marked", tostring(name) .. "."); return end
    local v = { by = self:MyName(), note = "", t = self:Now(old.t), del = true }
    T.votes[self:MyKey()] = v
    self:Recalc(T)
    if ns.Sync then ns.Sync:BroadcastVote(T, v) end
    self:Print("Removed your mark on", self:Display(T.n) .. (T.on and (" (still " .. self:BountyTag(T) .. ")") or "."))
    self:Changed()
end

-- Clear everyone's marks on a player.
function KOS:Pardon(name)
    local key = self:Canonical(name)
    local T = key and self:GetTarget(key)
    if not T or not T.on then self:Print(tostring(name), "is not on the list."); return end
    if not self:CanPardon(self:MyName()) then
        self:Print("Only guild rank " .. self:PardonRank() .. " and above can pardon. Use /kos rm to remove your own mark.")
        return
    end
    local ts = {}
    for _, v in pairs(T.votes) do ts[#ts + 1] = v.t end
    local c = { by = self:MyName(), t = self:Now(T.cleared and T.cleared.t, unpack(ts)) }
    self:MergeClear(key, T.n, c)
    if ns.Sync then ns.Sync:BroadcastClear(T, c) end
    self:Print("Pardoned", self:Display(T.n) .. ": all marks cleared.")
    self:Changed()
end

------------------------------------------------------------------------
-- Bounty game
------------------------------------------------------------------------

-- Claims in [from, to) (default: this season), oldest first. No farming
-- cap: every kill counts, but each one drains the target's bounty.
function KOS:CountedKills(from, to)
    from = from or self:SeasonBounds()
    local all = {}
    for _, k in pairs(self:Kills()) do
        if k.t >= from and (not to or k.t < to) then all[#all + 1] = k end
    end
    table.sort(all, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        return a.by < b.by
    end)
    return all
end

-- Leaderboard: { { name, points, kills, revenges, best, bestTarget }, ... } best first.
function KOS:Scores(from, to)
    local by = {}
    for _, k in ipairs(self:CountedKills(from, to)) do
        local key = self:Canonical(k.by)
        local row = by[key]
        if not row then
            row = { name = k.by, points = 0, kills = 0, assists = 0, revenges = 0, rescues = 0, best = 0, bestTarget = nil }
            by[key] = row
        end
        row.points = row.points + k.v
        if k.assist then row.assists = row.assists + 1 else row.kills = row.kills + 1 end
        if k.rev then row.revenges = row.revenges + 1 end
        if k.res then row.rescues = row.rescues + 1 end
        if k.v > row.best then row.best, row.bestTarget = k.v, k.target end
    end
    local rows = {}
    for _, r in pairs(by) do rows[#rows + 1] = r end
    table.sort(rows, function(a, b)
        if a.points ~= b.points then return a.points > b.points end
        if a.kills ~= b.kills then return a.kills > b.kills end
        return a.name < b.name
    end)
    return rows
end

-- Kill history for one target (for tooltips): count, latest claim.
function KOS:KillsOf(full)
    local key = self:Canonical(full)
    local n, latest = 0, nil
    for _, k in ipairs(self:CountedKills()) do
        if self:Canonical(k.target) == key and not k.assist then
            n = n + 1
            latest = k
        end
    end
    return n, latest
end

-- The #1 player on the Wanted list (highest current score).
local topCache, topAt = nil, -100
function KOS:TopBountyKey()
    if GetTime() - topAt < 10 then return topCache end
    topAt = GetTime()
    local best, bestScore = nil, 0
    for key, T in pairs(self:Targets()) do
        if T.on then
            local sc = self:ScoreOf(T)
            if sc > bestScore then best, bestScore = key, sc end
        end
    end
    topCache = best
    return best
end
function KOS:IsTopBounty(T)
    return not T.virtual and T.on and self:TopBountyKey() == self:Canonical(T.n)
end

-- Base value of killing T for `hunterKey`, plus a reason when it's 0.
-- Base = 5 + 3 x bounty level, where the level leaves out the hunter's own
-- mark and their own deaths to T (no pumping a friend's bounty). Members
-- of a KoS guild pay a flat amount. Low-level targets slide to nothing.
function KOS:BountyValue(T, hunterKey, targetLevel, at, noGrey, upperBound)
    hunterKey = hunterKey or self:MyKey()
    local grey = 1
    targetLevel = targetLevel or T.lvl
    local myLevel = UnitLevel("player")
    if not noGrey and targetLevel and targetLevel > 0 and myLevel then
        local diff = myLevel - targetLevel
        if diff >= self.GREY_ZERO then return 0, "too low level" end
        if diff > self.GREY_FULL then grey = (self.GREY_ZERO - diff) / (self.GREY_ZERO - self.GREY_FULL) end
    end
    if T.virtual then return math.max(1, math.floor(self.GUILD_MEMBER_POINTS * grey + 0.5)) end
    local lvl = self.BountyLevel(self:Score(T, hunterKey, at, upperBound, true))
    if lvl == 0 then
        local others = 0
        for rk, x in pairs(T.votes) do if rk ~= hunterKey and self:MarkActive(x) then others = others + 1 end end
        if others == 0 and #ganksBy(self:Canonical(T.n)) == 0 then return 0, "only your own mark" end
        return 0, "the bounty has gone cold"
    end
    return math.max(1, math.floor(self.PayoutForLevel(lvl) * grey + 0.5))
end

-- Have I killed this target yet this season? (first blood bonus)
function KOS:HasKilledThisSeason(target, hunterKey)
    local key = self:Canonical(target)
    local start = self:SeasonBounds()
    for _, k in ipairs(killsOn(key)) do
        if k.t >= start and self:Canonical(k.by) == hunterKey then return true end
    end
    return false
end

-- Full value of a kill right now: v, base, why, bonuses ({ "top", "revenge" | "rescue", "first" }).
function KOS:ClaimValue(T, targetLevel, rev, res)
    local me = self:MyKey()
    local base, why = self:BountyValue(T, me, targetLevel)
    if base == 0 then return 0, 0, why, {} end
    if T.virtual then return base, base, nil, {} end -- KoS-guild members: flat, no bonuses
    local bonuses = {}
    if self:IsTopBounty(T) then bonuses[#bonuses + 1] = "top" end
    if rev then bonuses[#bonuses + 1] = "revenge" elseif res then bonuses[#bonuses + 1] = "rescue" end
    if not self:HasKilledThisSeason(T.n, me) then bonuses[#bonuses + 1] = "first" end
    local v = math.floor(base * (1 + self.BONUS * #bonuses) + 0.5)
    return math.min(self.MAX_CLAIM, v), base, nil, bonuses
end

local BONUS_TEXT = { top = "Top Bounty", revenge = "revenge", rescue = "rescue", first = "first blood" }
function KOS.BonusText(bonuses)
    local out = {}
    for _, b in ipairs(bonuses) do out[#out + 1] = "+50% " .. BONUS_TEXT[b] end
    return table.concat(out, ", ")
end

function KOS:PointsOf(name, from, to)
    local key = self:Canonical(name)
    for _, r in ipairs(self:Scores(from, to)) do
        if self:Canonical(r.name) == key then return r.points, r end
    end
    return 0
end

-- Revenge: the target killed a guildie within REVENGE_WINDOW and nobody
-- has avenged that death yet. Uses synced deaths and kills, so it works
-- for any guildie's death, not just yours.
function KOS:RevengeFor(key)
    local now = GetServerTime()
    local ganks = ganksBy(key)
    for i = #ganks, 1, -1 do
        local d = ganks[i]
        if now - d.t > self.REVENGE_WINDOW then break end
        local avenged = false
        for _, k in pairs(self:Kills()) do
            if k.rev == d.victim and self:Canonical(k.target) == key and k.t >= d.t then avenged = true; break end
        end
        if not avenged then return d.victim end
    end
end

-- Calls for help: attackerKey -> { victim, at }. Live-only (they matter
-- for a few minutes); used for the rescue bonus.
local distress = {}
function KOS:NoteDistress(attackerFull, victimFull, map, x, y)
    local key = self:Canonical(attackerFull)
    if key then distress[key] = { victim = victimFull, at = GetTime(), map = map, x = x, y = y } end
end
function KOS:DistressOf(key) return distress[key] end

-- "On my way": I'm heading to a guildie's call for help.
local responding = {}
function KOS:Respond(attackerFull)
    local key = self:Canonical(attackerFull)
    local d = key and distress[key]
    if not d then return end
    responding[key] = { victim = d.victim, at = GetTime(), map = d.map, x = d.x, y = d.y }
    local dist = self:DistanceTo(d.map, d.x, d.y)
    if ns.Sync then ns.Sync:SendOnMyWay(attackerFull, d.victim, dist) end
    self:Notify("me", "On your way to help " .. self:Display(d.victim) .. " against " .. self:Display(attackerFull) .. ".")
end
function KOS:IsResponding(key) return responding[key] ~= nil end

-- Someone killed an attacker I was responding to. If I actually made it
-- there, I get an assist.
function KOS:CheckResponder(targetFull, killerFull)
    local key = self:Canonical(targetFull)
    local r = key and responding[key]
    if not r then return end
    responding[key] = nil
    if GetTime() - r.at > self.RESCUE_WINDOW + 60 or self:Canonical(killerFull) == self:MyKey() then return end
    local dist = self:DistanceTo(r.map, r.x, r.y)
    if not dist or dist > self.RESPOND_RANGE then return end
    local zone = self.ZoneString and self.ZoneString() or ""
    -- wait a moment: if the game credits me with the kill (honour), that
    -- full claim replaces the assist
    C_Timer.After(self.ASSIST_DELAY, function()
        if self:ClaimedRecently(key) then return end
        local T = self:Lookup(key)
        if T then self:ClaimAssist(T, killerFull, zone, nil, "answered the call") end
    end)
end
function KOS:RescueFor(key)
    local d = distress[key]
    if d and GetTime() - d.at <= self.RESCUE_WINDOW and self:Canonical(d.victim) ~= self:MyKey() then
        return d.victim
    end
end
function KOS:ClearDistress(key, victim)
    if key and distress[key] and (not victim or distress[key].victim == victim) then distress[key] = nil end
end

-- I was just killed by an enemy player: record it for the guild.
local lastDeath = {}
function KOS:InWorld()
    local inInstance = IsInInstance()
    return not inInstance
end

-- at: server time of the death (defaults to now; set when confirmed later)
function KOS:RecordDeath(killerFull, zone, at)
    local key, full = self:Canonical(killerFull)
    if not key or self:ListKey() == nil or not self:InWorld() then return end
    if lastDeath[key] and GetTime() - lastDeath[key] < 30 then return end
    lastDeath[key] = GetTime()
    local now = self:Now()
    local t = (at and at <= now and now - at < 600) and math.floor(at) or now
    local d = { victim = self:MyName(), killer = full, t = t, zone = self.CleanText(zone or "", 60) }
    if self:MergeDeath(d) and ns.Sync then ns.Sync:BroadcastDeath(d) end
end

-- I got the killing blow on a KoS player (or a member of a KoS guild).
local lastClaim = {}
function KOS:ClaimedRecently(key)
    return lastClaim[key] ~= nil and GetTime() - lastClaim[key] < self.KILL_CLUSTER
end
function KOS:ClaimKill(T, zone, targetLevel)
    if not self.S.claimKills or not self:InWorld() then return end
    local key = self:Canonical(T.n)
    if lastClaim[key] and GetTime() - lastClaim[key] < 5 then return end -- duplicate combat-log events
    lastClaim[key] = GetTime()
    local rev = self:RevengeFor(key)
    local res = (not rev) and self:RescueFor(key) or nil
    local v, base, why, bonuses = self:ClaimValue(T, targetLevel, rev, res)
    if v == 0 then rev, res = nil, nil end
    local k = {
        target = T.n, by = self:MyName(), t = self:Now(), v = v,
        zone = self.CleanText(zone or "", 40), guild = T.guild, rev = rev, res = res,
    }
    self:RecordClaim(k, function()
        if v == 0 then
            return "Killed " .. self:Display(T.n) .. " - no points (" .. (why or "no bounty") .. "), but the kill counts."
        end
        local who = rev and (" |cffff8000Revenge for " .. (rev == self:MyName() and "yourself" or self:Display(rev)) .. "!|r")
            or (res and (" |cff40c0ffRescued " .. self:Display(res) .. "!|r")) or ""
        return "|cff40ff40Bounty claimed on " .. self:Display(T.n) .. "!|r +" .. v .. (v == 1 and " point" or " points")
            .. (#bonuses > 0 and (" |cff888888(" .. base .. " " .. self.BonusText(bonuses) .. ")|r") or "") .. who
    end)
    if rev or res then self:ClearDistress(key) end -- one bonus per incident
end

-- Merge, broadcast and announce one of my own claims; rank-ups and badges.
function KOS:RecordClaim(k, message)
    local before = self:PointsOf(self:MyName())
    local badgesBefore = self:BadgeSet(self:MyName())
    if not self:MergeKill(k) then return false end
    if ns.Sync then ns.Sync:BroadcastKill(k) end
    local after = self:PointsOf(self:MyName())
    self:Notify("me", message() .. " |cff888888(season: " .. after .. ")|r")
    self:CheckRankUp(before, after)
    for _, b in ipairs(self:Badges(self:MyName())) do
        if b.done and not badgesBefore[b.id] then
            self:Notify("me", "|cffffd100Badge earned: " .. b.name .. "|r - " .. b.desc)
        end
    end
    if self.RefreshUI then self:RefreshUI() end
    return true
end

-- I killed an unmarked player who was attacking a guildie: mark them and
-- take a flat defense bonus. Rewards protecting lowbies.
function KOS:ClaimDefense(name, guid, zone, victim)
    if not self.S.claimKills or not self:InWorld() then return end
    local key, full = self:Canonical(name)
    if not key or (lastClaim[key] and GetTime() - lastClaim[key] < 5) then return end
    lastClaim[key] = GetTime()
    self:Mark(full, "Attacked " .. self:Display(victim), guid)
    local k = {
        target = full, by = self:MyName(), t = self:Now(), v = self.DEFENSE_POINTS,
        zone = self.CleanText(zone or "", 40), res = victim,
    }
    self:RecordClaim(k, function()
        return "|cff40c0ffDefended " .. self:Display(victim) .. "!|r Killed " .. self:Display(full) .. " +" .. self.DEFENSE_POINTS .. " points"
    end)
    self:ClearDistress(key)
end

function KOS:CheckRankUp(before, after)
    local oldRank, newRank = self.HunterRank(before), self.HunterRank(after)
    if newRank.level > oldRank.level then
        self:Notify("me", "Rank up! You are now " .. self.RankTag(after) .. " (level " .. newRank.level .. ").")
        if RaidNotice_AddMessage and RaidWarningFrame then
            RaidNotice_AddMessage(RaidWarningFrame, "RANK UP: " .. newRank.name, { r = 0.25, g = 1, b = 0.25 })
        end
        PlaySound(8960, "Master")
    end
end

-- A grouped guildie got the killing blow on a target I hit recently.
local lastAssist = {}
function KOS:ClaimAssist(T, killerFull, zone, targetLevel, why)
    if not self.S.claimKills or not self:InWorld() then return end
    local key = self:Canonical(T.n)
    if lastAssist[key] and GetTime() - lastAssist[key] < 5 then return end
    lastAssist[key] = GetTime()
    local base = self:BountyValue(T, self:MyKey(), targetLevel)
    local v = (base > 0) and math.min(self.MAX_CLAIM, math.max(1, math.floor(base * self.ASSIST_MULT + 0.5))) or 0
    local k = {
        target = T.n, by = self:MyName(), t = self:Now(), v = v,
        zone = self.CleanText(zone or "", 40), guild = T.guild, assist = true,
    }
    self:RecordClaim(k, function()
        return "|cff40ff40Assist on " .. self:Display(T.n) .. "|r (" .. self:Display(killerFull) .. " got the kill"
            .. (why and (", you " .. why) or "") .. ") +" .. v
            .. (v == 1 and " point" or " points")
    end)
end

------------------------------------------------------------------------
-- Rivalries
------------------------------------------------------------------------

-- Who has killed `name` the most (within the gank horizon), and the
-- head-to-head record: { killer, theirKills, myKills } or nil.
function KOS:NemesisOf(name)
    local key = self:Canonical(name)
    local counts = {}
    for _, d in pairs(self:Deaths()) do
        if self:Canonical(d.victim) == key then
            local k = self:Canonical(d.killer)
            counts[k] = counts[k] or { killer = d.killer, theirKills = 0, myKills = 0 }
            counts[k].theirKills = counts[k].theirKills + 1
        end
    end
    local best
    for _, c in pairs(counts) do
        if not best or c.theirKills > best.theirKills then best = c end
    end
    if not best or best.theirKills < 2 then return nil end
    local bk = self:Canonical(best.killer)
    for _, k in pairs(self:Kills()) do
        if not k.assist and self:Canonical(k.by) == key and self:Canonical(k.target) == bk then
            best.myKills = best.myKills + 1
        end
    end
    return best
end

------------------------------------------------------------------------
-- Badges: computed from the synced claim history (last KILL_HORIZON days),
-- so every guildie sees the same ones without extra sync traffic.
------------------------------------------------------------------------

KOS.BADGES = {
    { id = "first", name = "First Blood", desc = "Claim your first bounty" },
    { id = "variety", name = "Big Game Hunter", desc = "Kill 10 different marked players" },
    { id = "jackpot", name = "Jackpot", desc = "A single claim worth 100+ points" },
    { id = "avenger", name = "Avenger", desc = "Avenge 10 guildies" },
    { id = "guardian", name = "Guardian", desc = "Rescue or defend 5 guildies" },
    { id = "wingman", name = "Wingman", desc = "25 assists" },
    { id = "nemesis", name = "Nemesis Slain", desc = "Kill the player who's killed you most" },
    { id = "breaker", name = "Guild Breaker", desc = "25 kills on members of one enemy guild" },
}

function KOS:Badges(name)
    local key = self:Canonical(name)
    local targets, guilds = {}, {}
    local n, distinct, best, revs, saves, assists = 0, 0, 0, 0, 0, 0
    for _, k in pairs(self:Kills()) do
        if self:Canonical(k.by) == key then
            if k.assist then
                assists = assists + 1
            else
                n = n + 1
                local tk = self:Canonical(k.target)
                if not targets[tk] then targets[tk] = true; distinct = distinct + 1 end
                if k.v > best then best = k.v end
                if k.rev then revs = revs + 1 end
                if k.res then saves = saves + 1 end
                if k.guild then guilds[k.guild] = (guilds[k.guild] or 0) + 1 end
            end
        end
    end
    local maxGuild = 0
    for _, c in pairs(guilds) do if c > maxGuild then maxGuild = c end end
    local nem = self:NemesisOf(name)
    local done = {
        first = n >= 1, variety = distinct >= 10, jackpot = best >= 100, avenger = revs >= 10,
        guardian = saves >= 5, wingman = assists >= 25, breaker = maxGuild >= 25,
        nemesis = nem ~= nil and nem.myKills > 0,
    }
    local out = {}
    for _, b in ipairs(self.BADGES) do
        out[#out + 1] = { id = b.id, name = b.name, desc = b.desc, done = done[b.id] or false }
    end
    return out
end

function KOS:BadgeSet(name)
    local set = {}
    for _, b in ipairs(self:Badges(name)) do if b.done then set[b.id] = true end end
    return set
end

------------------------------------------------------------------------
-- Enemy guilds
--
-- Guild names can only be read from a visible unit (nameplate, target,
-- mouseover), so we note them whenever we see a marked player and sync
-- the latest observation. A guild's bounty score is the sum of its marked
-- members' scores, on the same level ladder. The whole guild becomes KoS
-- at guild level KOS:guild=N (default 30, 0 = off) *and* at least
-- GUILD_MIN_GANKS ganks on record, so a big social guild doesn't get
-- swept in just by size. It cools off as its members' bounties decay.
------------------------------------------------------------------------

local guidGuild, guidGuildSize = {}, 0 -- any player GUID seen -> guild ("" = none)

function KOS:GuildThreshold()
    local n = self:GuildTag("guild")
    if n == nil then return self.DEFAULT_GUILD_LEVEL end
    return n
end

-- Called whenever a player unit is visible. Records their guild for the
-- KoS-guild check, and syncs it if they're marked and it changed.
function KOS:ObserveUnit(info, T)
    if not info then return nil end
    local g, guid = info.guild, info.guid
    if guid then
        if guidGuild[guid] == nil then
            guidGuildSize = guidGuildSize + 1
            if guidGuildSize > 2000 then wipe(guidGuild); guidGuildSize = 0 end
        end
        guidGuild[guid] = g or ""
    end
    if T and g and g ~= "" and not T.virtual then
        g = self.CleanText(g, 64)
        if g ~= T.guild then
            T.guild, T.guildT = g, self:Now(T.guildT)
            if ns.Sync then ns.Sync:BroadcastGuild(T) end
            self:InvalidateGuildStats()
        end
    end
    return g
end

function KOS:GuildOfGUID(guid) return guid and guidGuild[guid] end

local guildStats
-- keepGanks: the caller didn't change any deaths (Recalc), so the gank
-- index can stay; rebuilding it per target made RecalcAll quadratic.
function KOS:InvalidateGuildStats(keepGanks)
    guildStats = nil
    topAt = -100
    if not keepGanks then gankIndex = nil end
    scoreVersion = scoreVersion + 1
end

-- { [guildName] = { name, members, score, level, kills, points, kos } }
local guildStatsAt = 0
function KOS:GuildStats()
    if guildStats and GetTime() - guildStatsAt < 30 then return guildStats end
    guildStatsAt = GetTime()
    local stats = {}
    local function row(g)
        local r = stats[g]
        if not r then r = { name = g, members = 0, score = 0, kills = 0, points = 0 }; stats[g] = r end
        return r
    end
    for _, T in pairs(self:Targets()) do
        if T.guild and T.guild ~= "" and T.on then
            local r = row(T.guild)
            r.members = r.members + 1
            r.score = r.score + self:ScoreOf(T)
        end
    end
    for _, k in pairs(self:Kills()) do
        if k.guild and not k.assist then
            local r = row(k.guild)
            r.kills = r.kills + 1
            r.points = r.points + k.v
        end
    end
    -- war ledger: ganks on us by their members (guild as we know it)
    for _, d in pairs(self:Deaths()) do
        local T = self:GetTarget(self:Canonical(d.killer))
        if T and T.guild and T.guild ~= "" then
            local r = row(T.guild)
            r.ganks = (r.ganks or 0) + 1
        end
    end
    local threshold = self:GuildThreshold()
    for _, r in pairs(stats) do
        r.ganks = r.ganks or 0
        r.level = self.BountyLevel(r.score)
        r.kos = threshold > 0 and r.level >= threshold and r.ganks >= self.GUILD_MIN_GANKS
    end
    guildStats = stats
    return stats
end

function KOS:IsKosGuild(g)
    if not g or g == "" then return false end
    local r = self:GuildStats()[g]
    return r and r.kos or false
end

-- A stand-in target for an unmarked member of a KoS guild.
function KOS:VirtualTarget(full, guid, class, g)
    return { n = full, guid = guid, class = class, guild = g, w = 0, votes = {}, virtual = true }
end

-- Marked player, or an unmarked member of a KoS guild, for a visible unit.
-- Also returns the unit's info (see KOS:UnitInfo) as the 5th value.
-- info: the unit's info if the caller already read it.
function KOS:ResolveUnit(unit, info)
    info = info or self:UnitInfo(unit)
    if not info then return nil end
    local full = info.full
    local unitKey = self:Canonical(full)
    if not unitKey or unitKey == self:MyKey() then return nil end
    local guid = info.guid
    local T, key = self:Lookup(unitKey, guid)
    local g = self:ObserveUnit(info, T)
    if T then return T, key, full, unitKey, info end
    if self.S.guildAlerts and self:IsKosGuild(g) then
        return self:VirtualTarget(select(2, self:Canonical(full)), guid, info.class, g), unitKey, full, unitKey, info
    end
end

-- Claims for officer review, newest first, with flags:
--   farm      the hunter killed this target more than FARM_FLAG times in an hour
--   inflated  worth more than the target's bounty at the time could pay with
--             every bonus applied (claims from before a pardon can't be checked)
-- Cached until claims or bounties change.
local claimsCache, claimsCacheV = nil, nil
function KOS:Claims(hunter)
    if not claimsCache or claimsCacheV ~= self:DataVersion() then
        local all = self:CountedKills(0)
        -- farm check: per hunter+target, a sliding one-hour window
        local pairsOf, farm = {}, {}
        for _, k in ipairs(all) do
            local p = k.by .. "|" .. k.target
            pairsOf[p] = pairsOf[p] or {}
            table.insert(pairsOf[p], k)
        end
        for _, list in pairs(pairsOf) do
            local lo = 1
            for hi = 1, #list do
                while list[hi].t - list[lo].t > 3600 do lo = lo + 1 end
                if hi - lo + 1 > self.FARM_FLAG then
                    for i = lo, hi do farm[list[i]] = true end
                end
            end
        end
        local out = {}
        for _, k in ipairs(all) do
            local flags = {}
            if farm[k] then flags[#flags + 1] = "farm?" end
            local T = self:GetTarget(self:Canonical(k.target))
            local prePardon = T and T.cleared and k.t <= T.cleared.t
            if not prePardon then
                local base = 0
                if T then base = self:BountyValue(T, self:Canonical(k.by), nil, k.t, true, true) end
                if k.guild then base = math.max(base, self.GUILD_MEMBER_POINTS) end
                if k.res then base = math.max(base, self.DEFENSE_POINTS) end
                local maxV = math.ceil(base * (k.assist and self.ASSIST_MULT or (1 + 3 * self.BONUS))) + 2
                if k.v > maxV then flags[#flags + 1] = "inflated?" end
            end
            out[#out + 1] = { k = k, id = self.KillId(k), flags = flags }
        end
        table.sort(out, function(x, y) return x.k.t > y.k.t end)
        claimsCache, claimsCacheV = out, self:DataVersion()
    end
    local hk = hunter and hunter ~= "" and self:Canonical(hunter)
    if not hk then return claimsCache end
    local mine = {}
    for _, c in ipairs(claimsCache) do
        if self:Canonical(c.k.by) == hk then mine[#mine + 1] = c end
    end
    return mine
end

function KOS:Strike(id)
    if not self:CanPardon(self:MyName()) then
        self:Print("Only guild rank " .. self:PardonRank() .. " and above can strike claims.")
        return
    end
    local k = self:Kills()[id]
    if not k then self:Print("No such claim."); return end
    local x = { by = self:MyName(), t = self:Now(), kt = k.t }
    self:MergeStrike(id, x)
    if ns.Sync then ns.Sync:BroadcastStrike(id, x) end
    self:Print("Struck " .. self:Display(k.by) .. "'s claim on " .. self:Display(k.target) .. " (" .. k.v .. " pts).")
    if self.RefreshUI then self:RefreshUI() end
end

function KOS:NewSeason()
    if not self:CanPardon(self:MyName()) then
        self:Print("Only guild rank " .. self:PardonRank() .. " and above can start a new season.")
        return
    end
    local list = self:List()
    local s = { by = self:MyName(), t = self:Now(list.season and list.season.t) }
    self:MergeSeason(s)
    if ns.Sync then ns.Sync:BroadcastSeason(s) end
    self:Print("New season started early. Past claims are kept as history.")
    if self.RefreshUI then self:RefreshUI() end
end

-- An enemy player killed me (open world): add my mark, or refresh it.
function KOS:AutoMark(killerFull, guid, class, zone, levels)
    if not self.S.autoMark or not self:InWorld() then return end
    local key, full = self:Canonical(killerFull)
    if not key or key == self:MyKey() then return end
    local T = self:GetTarget(key)
    local mine = self:MyVote(T)
    local note = mine and mine.note or ("Killed me in " .. (zone ~= "" and zone or "the world") .. (levels or ""))
    self:Mark(full, note, guid, class)
    -- if we know their guild from an earlier sighting, record it
    local g = self:GuildOfGUID(guid)
    T = self:GetTarget(key)
    if T and g and g ~= "" and g ~= T.guild then
        T.guild, T.guildT = self.CleanText(g, 64), self:Now(T.guildT)
        if ns.Sync then ns.Sync:BroadcastGuild(T) end
        self:InvalidateGuildStats()
    end
end

StaticPopupDialogs["UTU_SEASON"] = {
    text = "Start a new season now?\nThe leaderboard starts fresh for the whole guild. Past claims stay in the history.",
    button1 = YES or "Yes",
    button2 = NO or "No",
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    OnAccept = function() KOS:NewSeason() end,
}

function KOS:AddTarget(note)
    local info = self:UnitInfo("target")
    if not info then self:Print("Target a player first."); return end
    if note and note ~= "" then
        self:Mark(info.full, note, info.guid, info.class)
    else
        self:PromptNote(info.full, info.guid, info.class)
    end
end

------------------------------------------------------------------------
-- Popups
------------------------------------------------------------------------

local function popupEditBox(p) return p.editBox or p.EditBox end

StaticPopupDialogs["UTU_NOTE"] = {
    text = "Mark %s as Kill on Sight\nYour note (optional):",
    button1 = ACCEPT or "Accept",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    maxLetters = KOS.NOTE_MAX,
    editBoxWidth = 260,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
    OnShow = function(self)
        local d = self.data
        local T = d and KOS:GetTarget(KOS:Canonical(d.name))
        local mine = KOS:MyVote(T)
        local eb = popupEditBox(self)
        eb:SetText(mine and mine.note or "")
        eb:SetFocus()
    end,
    OnAccept = function(self)
        local d = self.data
        KOS:Mark(d.name, popupEditBox(self):GetText(), d.guid, d.class)
    end,
    EditBoxOnEnterPressed = function(eb)
        local p = eb:GetParent()
        KOS:Mark(p.data.name, eb:GetText(), p.data.guid, p.data.class)
        p:Hide()
    end,
    EditBoxOnEscapePressed = function(eb) eb:GetParent():Hide() end,
}

StaticPopupDialogs["UTU_MUTE"] = {
    text = "Utu: mute which guildie's marks and sightings? (Just for you.)",
    button1 = ACCEPT or "Accept",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    maxLetters = 60,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
    OnShow = function(self) local eb = popupEditBox(self); eb:SetText(""); eb:SetFocus() end,
    OnAccept = function(self)
        local name = strtrim(popupEditBox(self):GetText())
        if name ~= "" then KOS:SetMuted(name, true) end
    end,
    EditBoxOnEnterPressed = function(eb)
        local name = strtrim(eb:GetText())
        eb:GetParent():Hide()
        if name ~= "" then KOS:SetMuted(name, true) end
    end,
    EditBoxOnEscapePressed = function(eb) eb:GetParent():Hide() end,
}

StaticPopupDialogs["UTU_ADDNAME"] = {
    text = "Utu: character name to mark",
    button1 = ACCEPT or "Accept",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    maxLetters = 60,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
    OnShow = function(self) local eb = popupEditBox(self); eb:SetText(""); eb:SetFocus() end,
    OnAccept = function(self)
        local name = strtrim(popupEditBox(self):GetText())
        if name ~= "" then C_Timer.After(0, function() KOS:PromptNote(name) end) end
    end,
    EditBoxOnEnterPressed = function(eb)
        local name = strtrim(eb:GetText())
        eb:GetParent():Hide()
        if name ~= "" then C_Timer.After(0, function() KOS:PromptNote(name) end) end
    end,
    EditBoxOnEscapePressed = function(eb) eb:GetParent():Hide() end,
}

StaticPopupDialogs["UTU_UNMARK"] = {
    text = "Remove your mark on %s?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    OnAccept = function(self) KOS:Unmark(self.data) end,
}

StaticPopupDialogs["UTU_PARDON"] = {
    text = "Pardon %s?\nThis clears every guildie's mark on them.",
    button1 = YES or "Yes",
    button2 = NO or "No",
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    OnAccept = function(self) KOS:Pardon(self.data) end,
}

function KOS:PromptNote(name, guid, class)
    local key, full = self:Canonical(name)
    if not key then self:Print("Not a valid character name:", tostring(name)); return end
    local T = self:GetTarget(key)
    local label = self:Display(full)
    if T and T.on then label = label .. " (" .. self:BountyTag(T) .. ")" end
    StaticPopup_Show("UTU_NOTE", label, nil, { name = full, guid = guid, class = class })
end

------------------------------------------------------------------------
-- Right-click menus (clients with the modern Menu API only)
------------------------------------------------------------------------

local function setupMenus()
    if not (Menu and Menu.ModifyMenu) then return end
    local tags = {
        "MENU_UNIT_PLAYER", "MENU_UNIT_ENEMY_PLAYER", "MENU_UNIT_TARGET", "MENU_UNIT_FOCUS",
        "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_FRIEND", "MENU_UNIT_GUILD",
        "MENU_UNIT_CHAT_ROSTER", "MENU_UNIT_COMMUNITIES_GUILD_MEMBER",
    }
    for _, tag in ipairs(tags) do
        pcall(Menu.ModifyMenu, tag, function(owner, root, ctx)
            if not ctx or KOS.IsSecret(ctx.name) or KOS.IsSecret(ctx.server) or KOS.IsSecret(ctx.unit) then return end
            if not ctx.name then return end
            local name = ctx.name
            if ctx.server and ctx.server ~= "" and not name:find("-", 1, true) then name = name .. "-" .. ctx.server end
            local key = KOS:Canonical(name)
            if not key or key == KOS:MyKey() then return end
            -- guildies: mute or unmute their marks and sightings (just for you)
            local guildie = KOS:RankOf(name) ~= nil or (ctx.unit and KOS.Try(UnitIsInMyGuild, ctx.unit))
                or tag == "MENU_UNIT_GUILD" or tag == "MENU_UNIT_COMMUNITIES_GUILD_MEMBER"
            if guildie and KOS:IsGuildList() then
                root:CreateDivider()
                root:CreateTitle("Utu")
                if KOS:IsMuted(name) then
                    root:CreateButton("Unmute their marks", function() KOS:SetMuted(name, false) end)
                else
                    root:CreateButton("Mute their marks", function() KOS:SetMuted(name, true) end)
                end
                return
            end
            local info = ctx.unit and KOS:UnitInfo(ctx.unit)
            local guid, class = info and info.guid, info and info.class
            local T = KOS:GetTarget(key)
            root:CreateDivider()
            root:CreateTitle("Utu" .. ((T and T.on) and (" - " .. KOS:BountyTag(T)) or ""))
            if KOS:MyVote(T) then
                root:CreateButton("Edit my note", function() KOS:PromptNote(name, guid, class) end)
                root:CreateButton("Remove my mark", function() KOS:Unmark(name) end)
            else
                root:CreateButton((T and T.on) and "Add my mark" or "Mark as Kill on Sight...",
                    function() KOS:PromptNote(name, guid, class) end)
            end
            if T and T.on and KOS:CanPardon(KOS:MyName()) then
                root:CreateButton("Pardon (clear all marks)", function()
                    StaticPopup_Show("UTU_PARDON", KOS:Display(T.n), nil, T.n)
                end)
            end
        end)
    end
end

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------

local HELP = {
    "/kos - open the list",
    "/kos add - mark your current target (asks for a note)",
    "/kos target [note] - mark your current target with a note",
    "/kos add Name [note] - mark a player by name (use quotes for names with spaces)",
    "/kos rm [Name] - remove your mark",
    "/kos mute Name / unmute Name - ignore a guildie's marks and sightings (just for you); /kos mute lists them",
    "/kos pardon Name - clear everyone's marks (officers)",
    "/kos list [filter] - print the list",
    "/kos top - bounty hunter leaderboard",
    "/kos guilds - enemy guild tally",
    "/kos season - reset the leaderboard (officers)",
    "/kos claims [Name] - recent bounty claims, with farm/inflation flags",
    "/kos strike N - void claim number N from the last /kos claims (officers)",
    "/kos config - open settings",
    "/kos sync - sync with online guildies now, and show who you have heard from",
    "/kos sos - call nearby guildies for help against your target or attacker",
    "/kos probe - test what this client allows (saved for troubleshooting)",
    "/kos test - show a test alert",
    "/kos news [version] - what changed in this version, or since the one given",
}

local function onSlash(msg)
    msg = strtrim(msg or "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "" or cmd == "show" then
        KOS:ToggleUI()
    elseif cmd == "add" or cmd == "mark" then
        -- names with spaces go in quotes: /kos add "kind eyes" camps the flight path
        local name, note = rest:match('^"(.-)"%s*(.-)$')
        if not name then name, note = rest:match("^(%S+)%s*(.-)$") end
        if not name then KOS:AddTarget()
        elseif note ~= "" then KOS:Mark(name, note)
        else KOS:PromptNote(name) end
    elseif cmd == "target" or cmd == "t" then
        KOS:AddTarget(rest)
    elseif cmd == "rm" or cmd == "remove" or cmd == "unmark" then
        if rest == "" then rest = KOS:UnitFull("target") or "" end
        KOS:Unmark(rest)
    elseif cmd == "mute" or cmd == "unmute" then
        local name = rest:match('^"(.-)"') or rest
        if name == "" then
            local list = KOS:MutedList()
            for i, full in ipairs(list) do list[i] = KOS:Display(full) end
            KOS:Print(#list > 0 and ("Muted: " .. table.concat(list, ", ") .. ".") or "You haven't muted anyone. /utu mute Name")
        else
            KOS:SetMuted(name, cmd == "mute")
        end
    elseif cmd == "pardon" then
        if rest == "" then rest = KOS:UnitFull("target") or "" end
        KOS:Pardon(rest)
    elseif cmd == "list" then
        local filter = rest:lower()
        local rows = {}
        for _, T in pairs(KOS:Targets()) do
            local note = KOS:TopNote(T)
            if T.on and (filter == "" or T.n:lower():find(filter, 1, true) or note:lower():find(filter, 1, true)) then
                rows[#rows + 1] = T
            end
        end
        table.sort(rows, function(a, b) return KOS:ScoreOf(a) > KOS:ScoreOf(b) end)
        KOS:Print(#rows .. " on the list:")
        for _, T in ipairs(rows) do
            DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s |cffff6060%s|r %s |cff888888(seen %s)|r",
                KOS:BountyTag(T), KOS:Display(T.n), (KOS:TopNote(T)), KOS.Ago(T.seen)))
        end
    elseif cmd == "top" or cmd == "scores" then
        local rows = KOS:Scores()
        KOS:Print("Bounty hunters" .. (#rows == 0 and ": no bounties claimed yet this season." or ":"))
        for i = 1, math.min(10, #rows) do
            local r = rows[i]
            DEFAULT_CHAT_FRAME:AddMessage(string.format("  %d. %s %s - |cffffd100%d pts|r (%d kills, %d revenges)",
                i, KOS.RankTag(r.points), KOS:Display(r.name), r.points, r.kills, r.revenges))
        end
    elseif cmd == "guilds" then
        local rows = {}
        for _, r in pairs(KOS:GuildStats()) do rows[#rows + 1] = r end
        table.sort(rows, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.name < b.name end)
        local th = KOS:GuildThreshold()
        KOS:Print("Enemy guilds" .. (th > 0 and (" (whole guild KoS at guild Lv " .. th .. ")") or " (whole-guild KoS is off)") .. ":")
        for _, r in ipairs(rows) do
            DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s<%s>|r guild Lv %d, %d marked, %d killed",
                r.kos and "|cffff2020" or "|cffffffff", r.name, r.level, r.members, r.kills))
        end
    elseif cmd == "claims" then
        local rows = KOS:Claims(rest)
        KOS.lastClaims = rows
        KOS:Print(#rows .. " claims" .. (rest ~= "" and (" by " .. rest) or "") .. " this season:")
        for i = 1, math.min(20, #rows) do
            local r = rows[i]
            DEFAULT_CHAT_FRAME:AddMessage(string.format("  %d. %s killed %s for %d %s|cff888888%s%s|r %s",
                i, KOS:Display(r.k.by), KOS:Display(r.k.target), r.k.v, r.k.v == 1 and "pt" or "pts",
                KOS.Ago(r.k.t), r.k.rev and (", avenging " .. KOS:Display(r.k.rev)) or "",
                #r.flags > 0 and ("|cffff4040" .. table.concat(r.flags, " ") .. "|r") or ""))
        end
    elseif cmd == "strike" then
        local n = tonumber(rest)
        local r = n and KOS.lastClaims and KOS.lastClaims[n]
        if not r then KOS:Print("Run /kos claims first, then /kos strike <number>."); return end
        KOS:Strike(r.id)
        KOS.lastClaims = nil
    elseif cmd == "season" then
        if KOS:CanPardon(KOS:MyName()) then StaticPopup_Show("UTU_SEASON")
        else KOS:NewSeason() end -- prints the permission message
    elseif cmd == "config" or cmd == "options" or cmd == "settings" then
        KOS:OpenSettings()
    elseif cmd == "news" or cmd == "changes" then
        KOS:ShowNews(rest ~= "" and rest or nil)
    elseif cmd == "sync" then
        if ns.Sync then ns.Sync:Status(); ns.Sync:Hello(true) end
    elseif cmd == "probe" then
        KOS:Probe()
    elseif cmd == "sos" then
        KOS:ManualHelp()
    elseif cmd == "test" then
        local me = KOS:MyName()
        KOS:Alert("test-test", {
            n = "Testplayer-" .. KOS:MyRealm(), w = 4,
            votes = { x = { by = me, note = "This is a test alert", t = 0 } },
        }, "test", true)
    elseif cmd == "set" then
        -- power-user access to any setting: /kos set <name> [value]
        local opt, val = rest:match("^(%S+)%s*(%S*)")
        local match
        for k in pairs(KOS.DEFAULTS) do if opt and k:lower() == opt:lower() then match = k end end
        if not match then KOS:OpenSettings(); return end
        local S = KOS.S
        if type(KOS.DEFAULTS[match]) == "number" then
            S[match] = tonumber(val) or S[match]
        elseif type(KOS.DEFAULTS[match]) == "string" then
            if val ~= "" then S[match] = val end
        else
            val = val:lower()
            if val == "on" or val == "1" or val == "true" then S[match] = true
            elseif val == "off" or val == "0" or val == "false" then S[match] = false
            else S[match] = not S[match] end
        end
        KOS:Print(match, "=", tostring(S[match]))
        KOS:SettingChanged(match)
    else
        for _, l in ipairs(HELP) do KOS:Print(l) end
    end
end

-- Hook for things that need to react when a setting flips.
function KOS:SettingChanged(key)
    if key == "nameplate" and self.RefreshPlates then self:RefreshPlates() end
    if key == "targetBadge" and self.RefreshTargetBadge then self:RefreshTargetBadge() end
    if key == "minimap" and self.UpdateMinimapButton then self:UpdateMinimapButton() end
    if key == "tracker" and self.RefreshTracker then self:RefreshTracker() end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

local frame = CreateFrame("Frame")
KOS.frame = frame
local handlers = {}

-- Returns false if the client refused the event.
function KOS:On(event, fn)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], fn)
    local ok = pcall(frame.RegisterEvent, frame, event) -- some events are restricted on some clients
    if not ok then
        self.blockedEvents = self.blockedEvents or {}
        self.blockedEvents[event] = true
    end
    return ok
end

-- Each handler runs protected: an error is saved to UtuDB.diag and
-- passed on to the normal error handler, and the other handlers still run.
local current, currentEvent, args, nargs = nil, nil, {}, 0
local function runCurrent() return current(unpack(args, 1, nargs)) end
local function onError(err)
    if KOS.RecordError then KOS:RecordError(currentEvent or "?", err) end
    return err
end
local depth = 0
local function dispatch(event, ...)
    local list = handlers[event]
    if not list or (not KOS.db and event ~= "ADDON_LOADED") then return end
    if KOS.CountEvent then KOS:CountEvent(event) end
    -- a handler can trigger another event synchronously: keep the outer one's state
    local saved, savedN, savedCurrent, savedEvent
    if depth > 0 then saved, savedN, savedCurrent, savedEvent = args, nargs, current, currentEvent; args = {} end
    depth = depth + 1
    currentEvent = event
    nargs = select("#", ...)
    for i = 1, nargs do args[i] = select(i, ...) end
    local failed
    for i = 1, #list do
        current = list[i]
        local ok, err = xpcall(runCurrent, onError)
        if not ok then failed = failed or {}; failed[#failed + 1] = err end
    end
    depth = depth - 1
    if saved then args, nargs, current, currentEvent = saved, savedN, savedCurrent, savedEvent
    else current, currentEvent = nil, nil end
    if failed then
        local handler = geterrorhandler and geterrorhandler()
        for _, err in ipairs(failed) do
            if handler then handler(err) else error(err, 0) end
        end
    end
end
frame:SetScript("OnEvent", function(_, event, ...) dispatch(event, ...) end)

-- Key bindings (Bindings.xml) and the addon compartment (the addons
-- dropdown by the minimap) call these globals.
BINDING_HEADER_UTU = "Utu"
BINDING_NAME_UTU_TOGGLE = "Open Utu"
BINDING_NAME_UTU_HELP = "Call guildies for help"
function Utu_Toggle() if KOS.db then KOS:ToggleUI() end end
function Utu_Help() if KOS.db then KOS:ManualHelp() end end
function Utu_OnAddonCompartmentClick(_, button)
    if not KOS.db then return end
    if button == "RightButton" then KOS:OpenSettings() else KOS:ToggleUI() end
end
function Utu_OnAddonCompartmentEnter(_, button)
    if not GameTooltip or not button then return end
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:AddLine("Utu")
    GameTooltip:AddLine("Left-click: open the list. Right-click: settings.", 1, 1, 1)
    GameTooltip:Show()
end
function Utu_OnAddonCompartmentLeave() if GameTooltip then GameTooltip:Hide() end end

KOS:On("ADDON_LOADED", function(name)
    if name ~= ADDON then return end
    KOS:InitDB()
    SLASH_UTU1, SLASH_UTU2 = "/utu", "/kos"
    SlashCmdList.UTU = onSlash
    setupMenus()
end)

KOS:On("GUILD_ROSTER_UPDATE", function()
    local before = KOS:ListKey()
    KOS:InvalidateListKey()
    KOS:RefreshRoster()
    if KOS:ListKey() ~= before then KOS:Changed() end
end)

------------------------------------------------------------------------
-- What's new: KOS.CHANGES (WhatsNew.lua, generated from CHANGELOG.md) holds
-- each version's notes, newest first. The first login on a newer version
-- prints what changed since the last one this account saw.
------------------------------------------------------------------------

KOS.NEWS_MAX = 6 -- bullets in chat; the rest point at the changelog
KOS.CHANGELOG_URL = KOS.HOME_URL .. "/blob/main/CHANGELOG.md"

-- Notes for versions newer than `since` and no newer than this one.
function KOS:ChangesSince(since)
    local from, upto = self.VersionNum(since) or 0, self.VersionNum(self:Version()) or math.huge
    local out = {}
    for _, c in ipairs(self.CHANGES or {}) do
        local n = self.VersionNum(c[1])
        if n and n > from and n <= upto then out[#out + 1] = c end
    end
    return out
end

-- `since` nil: just the current version's notes (/utu news).
function KOS:ShowNews(since)
    local changes = self:ChangesSince(since)
    if not since then
        local mine = self:Version()
        changes = {}
        for _, c in ipairs(self.CHANGES or {}) do
            if c[1] == mine then changes = { c } end
        end
        if #changes == 0 and self.CHANGES and self.CHANGES[1] then changes = { self.CHANGES[1] } end
    end
    if #changes == 0 then
        self:Print("Nothing new since " .. tostring(since) .. ". Full changelog: " .. self.CHANGELOG_URL)
        return
    end
    local newest = changes[1][1]
    if #changes == 1 then
        self:Print("What's new in " .. newest .. ":")
    else
        self:Print("Updated to " .. newest .. ". What's new since " .. since .. ":")
    end
    local shown, total = 0, 0
    for _, c in ipairs(changes) do
        for _, line in ipairs(c[2]) do
            total = total + 1
            if shown < self.NEWS_MAX then
                shown = shown + 1
                DEFAULT_CHAT_FRAME:AddMessage("  - " .. line)
            end
        end
    end
    if total > shown then
        DEFAULT_CHAT_FRAME:AddMessage("  ...and " .. (total - shown) .. " more: " .. self.CHANGELOG_URL)
    end
end

KOS:On("PLAYER_LOGIN", function()
    local mine = KOS:Version()
    local now, seen = KOS.VersionNum(mine), KOS.VersionNum(KOS.db.seenVersion)
    if not now then return end
    local since = KOS.db.seenVersion
    KOS.db.seenVersion = mine
    -- after the login chat spam, so it isn't scrolled away
    if seen and seen < now then C_Timer.After(10, function() KOS:ShowNews(since) end) end
end)

-- Marks expire with time, so recount now and then.
KOS:On("PLAYER_LOGIN", function()
    KOS:RecalcAll()
    C_Timer.NewTicker(600, function() KOS:RecalcAll() end)
end)

KOS:On("PLAYER_GUILD_UPDATE", function()
    KOS:InvalidateListKey()
    KOS:RequestRoster()
    KOS:Changed()
end)
