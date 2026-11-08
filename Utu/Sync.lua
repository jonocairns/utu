-- Utu: guild sync over the hidden addon-message channel.
-- Nothing here is visible in guild chat; it's addon-to-addon traffic.
--
-- Wire format: tab-separated, one item per message (<=255 bytes).
--   H digest count version   hello: fingerprint of everything I have
--   S kind fields...          live change by the sender
--   B digest count            begin full dump
--   D kind fields...          one item of a dump
--   E digest                  end of dump
--   W name zone subzone       sender just spotted a KoS player
--   A attacker zone map x y   sender is being attacked (call for help), with map position
--   O attacker victim yards   sender is on the way to help
-- kinds:
--   v  target by t del guid class note   one guildie's mark
--   c  target by t                        pardon (clears marks <= t)
--   g  target guild t                     target's guild, as observed at t
--   k  target by t value zone guild who mode
--                                         bounty claim; mode r = revenge for `who`,
--                                         s = rescued `who`, a = assist
--   x  killId by t                        officer struck a claim
--   d  victim killer t zone               a guildie was ganked (victim reports it)
--   s  by t                               new season (clears kills <= t)
--
-- Convergence: on login you broadcast H. Anyone whose fingerprint differs
-- schedules a dump after a random delay, and cancels it if someone with an
-- identical set starts dumping first. After merging a dump, anyone who
-- still differs has items the dumper lacked, so they dump in turn. Every
-- merge rule is deterministic, so everyone ends up with the same data.
--
-- Live messages are permission-checked against the sender. In dumps,
-- destructive items (pardons, strikes, season resets) are checked against
-- their author's rank, so nobody can wipe data by forging a dump. Marks and
-- claims in dumps are accepted as-is: they were checked when first sent,
-- and re-checking against a roster that changes over time would make
-- clients disagree forever.
local ADDON, ns = ...
local KOS = ns.KOS

local Sync = {}
ns.Sync = Sync
KOS.Sync = Sync

local function addonVersion() return KOS:Version() end

-- Sync diagnostics, saved to UtuDB.diag.sync and shown by /utu sync.
-- Counters are for this session; guildies heard from are kept.
local function stats()
    local db = KOS.db
    if not db then return nil end
    db.diag = db.diag or {}
    local st = db.diag.sync
    if not st then st = {}; db.diag.sync = st end
    st.sent, st.recv = st.sent or 0, st.recv or 0
    st.fail, st.drop, st.peers = st.fail or {}, st.drop or {}, st.peers or {}
    return st
end
local function bump(field, key)
    local st = stats()
    if st then st[field][key] = (st[field][key] or 0) + 1 end
end
local function heardFrom(senderKey, senderFull, ver)
    local st = stats()
    if not st then return end
    local p = st.peers[senderKey] or {}
    p.name, p.t = senderFull, GetServerTime()
    if ver then p.ver = ver end
    st.peers[senderKey] = p
end
Sync.Stats = stats


local PREFIX = KOS.PREFIX
local SEP = "\t"
local MAX_MSG = 255
local SEND_INTERVAL = 0.4
local VERSION = "2"

------------------------------------------------------------------------
-- Encoding
------------------------------------------------------------------------

local function join(...) return table.concat({ ... }, SEP) end

local function encodeItem(kind, a, b)
    if kind == "vote" then -- a = target, b = vote
        return join("v", a.n, b.by, tostring(b.t), b.del and "1" or "0", a.guid or "", a.class or "", b.note or "")
    elseif kind == "clear" then
        return join("c", a.n, b.by, tostring(b.t))
    elseif kind == "guild" then -- a = target
        return join("g", a.n, a.guild or "", tostring(a.guildT))
    elseif kind == "kill" then -- a = kill
        local mode = (a.rev and "r") or (a.res and "s") or (a.assist and "a") or ""
        return join("k", a.target, a.by, tostring(a.t), tostring(a.v), a.zone or "", a.guild or "",
            a.rev or a.res or "", mode)
    elseif kind == "death" then -- a = death
        return join("d", a.victim, a.killer, tostring(a.t), a.zone or "")
    elseif kind == "strike" then -- a = id, b = strike
        return join("x", a, b.by, tostring(b.t))
    elseif kind == "season" then
        return join("s", a.by, tostring(a.t))
    end
end

-- A timestamp from another client: a whole number of seconds, not in the
-- future (server time is shared, so an hour covers any lag). Anything else
-- could make a mark or claim count forever.
local MAX_AHEAD = 3600

-- A finite number within +-limit (coordinates, distances), else nil.
local function finite(f, limit)
    local n = tonumber(f)
    if not n or n ~= n or n > limit or n < -limit then return nil end
    return n
end
local function stamp(f)
    local t = tonumber(f)
    if not t or t ~= t or t < 0 or t ~= math.floor(t) or t > GetServerTime() + MAX_AHEAD then return nil end
    return t
end
Sync.stamp = stamp

-- Returns kind, item (normalised) or nil.
local function decodeItem(s)
    local kind, f1, f2, f3, f4, f5, f6, f7 = strsplit(SEP, s)
    if kind == "v" then
        local key, target = KOS:Canonical(f1)
        local _, by = KOS:Canonical(f2)
        local t = stamp(f3)
        if not key or not by or not t then return nil end
        return "vote", {
            key = key, target = target, by = by, t = t, del = (f4 == "1") or nil,
            guid = (f5 and f5 ~= "") and f5 or nil,
            class = (f6 and f6:match("^%u+$")) or nil,
            note = (f4 == "1") and "" or KOS.CleanText(f7),
        }
    elseif kind == "c" then
        local key, target = KOS:Canonical(f1)
        local _, by = KOS:Canonical(f2)
        local t = stamp(f3)
        if not key or not by or not t then return nil end
        return "clear", { key = key, target = target, by = by, t = t }
    elseif kind == "k" then
        local _, target = KOS:Canonical(f1)
        local _, by = KOS:Canonical(f2)
        local t, v = stamp(f3), tonumber(f4)
        if not target or not by or not t or not v then return nil end
        v = math.max(0, math.min(KOS.MAX_CLAIM, math.floor(v)))
        local g = KOS.CleanText(f6, 64)
        local _, who = KOS:Canonical(f7)
        local mode = select(9, strsplit(SEP, s))
        return "kill", { target = target, by = by, t = t, v = v, zone = KOS.CleanText(f5, 60),
            guild = g ~= "" and g or nil,
            rev = (mode == "r") and who or nil, res = (mode == "s") and who or nil,
            assist = (mode == "a") or nil }
    elseif kind == "g" then
        local key, target = KOS:Canonical(f1)
        local g = KOS.CleanText(f2, 64)
        local t = stamp(f3)
        if not key or g == "" or not t then return nil end
        return "guild", { key = key, target = target, guild = g, t = t }
    elseif kind == "d" then
        local _, victim = KOS:Canonical(f1)
        local _, killer = KOS:Canonical(f2)
        local t = stamp(f3)
        if not victim or not killer or not t then return nil end
        return "death", { victim = victim, killer = killer, t = t, by = victim, zone = KOS.CleanText(f4, 60) }
    elseif kind == "x" then
        local _, by = KOS:Canonical(f2)
        local t = stamp(f3)
        local kt = f1 and stamp(f1:match("|(%d+)$"))
        if not by or not t or not kt then return nil end
        return "strike", { id = f1, by = by, t = t, kt = kt }
    elseif kind == "s" then
        local _, by = KOS:Canonical(f1)
        local t = stamp(f2)
        if not by or not t then return nil end
        return "season", { by = by, t = t }
    end
end

local function itemMsg(tag, kind, a, b)
    local msg = tag .. SEP .. encodeItem(kind, a, b)
    if #msg > MAX_MSG and kind == "vote" then
        local note = b.note or ""
        local trimmed = { by = b.by, t = b.t, del = b.del,
            note = KOS.Utf8Truncate(note, math.max(0, #note - (#msg - MAX_MSG))) }
        msg = tag .. SEP .. encodeItem(kind, a, trimmed)
    elseif #msg > MAX_MSG and kind == "kill" then
        local copy = {}
        for k, v in pairs(a) do copy[k] = v end
        copy.zone = KOS.Utf8Truncate(copy.zone or "", math.max(0, #(copy.zone or "") - (#msg - MAX_MSG)))
        msg = tag .. SEP .. encodeItem(kind, copy)
    end
    if #msg > MAX_MSG then return nil end -- still too big (shouldn't happen with valid names): skip it
    return msg
end

Sync.encodeItem, Sync.decodeItem, Sync.itemMsg = encodeItem, decodeItem, itemMsg -- for tests

------------------------------------------------------------------------
-- Throttled send queue (live messages jump ahead of dumps)
------------------------------------------------------------------------

local hi, lo = {}, {}
local ticker

-- Enum.SendAddonMessageResult: 0 Success, 3 AddonMessageThrottle,
-- 8 ChannelThrottle are worth retrying; anything else won't ever succeed.
local THROTTLED = { [3] = true, [8] = true }
if Enum and Enum.SendAddonMessageResult then
    THROTTLED = {}
    for name, v in pairs(Enum.SendAddonMessageResult) do
        if tostring(name):find("Throttle") then THROTTLED[v] = true end
    end
end

-- ChatThrottleLib reports back whether each message went out.
local function onSent(_, didSend, result)
    if didSend then
        local st = stats()
        if st then st.sent = st.sent + 1 end
    else
        bump("fail", "code " .. tostring(result))
    end
end

-- true = done with this message (sent, handed on, or permanently failed),
-- false = retry. Messages go through ChatThrottleLib when it's loaded (it's
-- embedded), which shares the addon-message bandwidth with every other
-- addon using it and retries throttled sends itself.
local function sendRaw(msg, prio)
    if #msg > MAX_MSG then return true end -- can't ever send; itemMsg should have prevented this
    local ctl = _G.ChatThrottleLib
    if ctl and ctl.SendAddonMessage then
        local ok = pcall(ctl.SendAddonMessage, ctl, prio or "NORMAL", PREFIX, msg, "GUILD", nil, nil, onSent)
        if not ok then bump("fail", "error") end
        return true
    end
    local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, "GUILD")
    if not ok then bump("fail", "error"); return true end
    if res == false then return false end -- older clients: false = throttled
    if type(res) == "number" and res ~= 0 then
        if THROTTLED[res] then return false end
        bump("fail", "code " .. res)
        return true
    end
    local st = stats()
    if st then st.sent = st.sent + 1 end
    return true
end

local function pump()
    if not IsInGuild() then wipe(hi); wipe(lo) end
    -- addons may not message other players from inside instances (Midnight
    -- engine): hold everything until we're back in the world
    if not KOS:InWorld() then return end
    -- bulk sync waits until you're out of combat; live messages still go
    local q = (#hi > 0) and hi or ((InCombatLockdown and InCombatLockdown()) and {} or lo)
    if #q == 0 then
        if #hi == 0 and #lo == 0 and ticker then ticker:Cancel(); ticker = nil end
        return
    end
    if sendRaw(q[1], q == hi and "NORMAL" or "BULK") then table.remove(q, 1) end -- else throttled: retry next tick
    if KOS.UpdateFooter then KOS:UpdateFooter() end
end

local function enqueue(q, msg)
    if not msg or not IsInGuild() then return end
    q[#q + 1] = msg
    if not ticker then
        ticker = C_Timer.NewTicker(SEND_INTERVAL, pump)
        pump()
    end
end

function Sync:QueueSize() return #hi + #lo end

------------------------------------------------------------------------
-- New-version notice. Addons can't reach the internet, so versions travel
-- with guild sync: hellos carry the sender's version, and a newer client
-- answers an older client's hello with a "V" message (old clients ignore it).
------------------------------------------------------------------------

-- "0.6.3" -> a comparable number, or nil
local versionNum = KOS.VersionNum
Sync.versionNum = versionNum

local newestSeen
local function noteVersion(v)
    local n, mine = versionNum(v), versionNum(addonVersion())
    if not n or not mine or n <= mine then return end
    if newestSeen and versionNum(newestSeen) >= n then return end
    newestSeen = v
    KOS:Print("A newer Utu (" .. v .. ") is out; you have " .. addonVersion()
        .. ". Update it in WowUp, or download it from " .. KOS.HOME_URL .. ".")
end
function Sync:NewerVersion() return newestSeen end

local versionReply
local function maybeReplyVersion(theirVer)
    local mine, theirs = versionNum(addonVersion()), versionNum(theirVer)
    if not mine or not theirs or theirs >= mine or versionReply then return end
    -- one guildie answering is enough: wait a moment, and stand down if
    -- someone else answers first (see the "V" handler)
    versionReply = C_Timer.NewTimer(1 + math.random() * 6, function()
        versionReply = nil
        enqueue(hi, join("V", addonVersion()))
    end)
end

------------------------------------------------------------------------
-- Outgoing
------------------------------------------------------------------------

local function live(kind, a, b)
    if KOS:IsGuildList() then enqueue(hi, itemMsg("S", kind, a, b)) end
end

function Sync:BroadcastVote(T, v) live("vote", T, v) end
function Sync:BroadcastClear(T, c) live("clear", T, c) end
function Sync:BroadcastKill(k) live("kill", k) end
function Sync:BroadcastGuild(T) live("guild", T) end

function Sync:BroadcastDeath(d) live("death", d) end

local lastHelp = {}
local function coords()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return "" end
    local map = C_Map.GetBestMapForUnit("player")
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return "" end
    local x, y = pos:GetXY()
    if not x or x == 0 then return "" end
    return string.format(" (%d, %d)", x * 100, y * 100)
end

-- Returns true if the call went out.
-- how: nil = they hit me (combat log), "t" = they're targeting me while I
-- take damage (no combat log: probably them), "m" = I called by hand.
function Sync:CallForHelp(attackerFull, how)
    if not KOS:IsGuildList() or not KOS:InWorld() or IsInRaid() then return false end
    local key = KOS:Canonical(attackerFull)
    if not key or (lastHelp[key] and GetTime() - lastHelp[key] < 60) then return false end
    lastHelp[key] = GetTime()
    local map, x, y = KOS:MyPosition()
    enqueue(hi, join("A", attackerFull, (KOS.ZoneString and KOS.ZoneString() or (GetRealZoneText() or "")) .. coords(),
        tostring(map or ""), x and string.format("%.4f", x) or "", y and string.format("%.4f", y) or "", how or ""))
    return true
end

function Sync:SendOnMyWay(attackerFull, victimFull, dist)
    if not KOS:IsGuildList() then return end
    enqueue(hi, join("O", attackerFull, victimFull, dist and tostring(math.floor(dist)) or ""))
end
function Sync:BroadcastSeason(s) live("season", s) end
function Sync:BroadcastStrike(id, x) live("strike", id, x) end

function Sync:Hello(manual)
    if not KOS:IsGuildList() then
        if manual then KOS:Print("Not in a guild, so there's nothing to sync.") end
        return
    end
    local digest, count = KOS:Digest()
    enqueue(hi, join("H", digest, count, VERSION, addonVersion()))
    self.helloSent = true
    if manual then
        KOS:Print(string.format("Asked online guildies to compare lists (%d items, fingerprint %s).", count, digest))
    end
end

local dumpTimer
local lastDumpAt = -1000
-- digest -> { at, officer }: someone began dumping that exact set. Only an
-- officer's dump carries pardons/strikes/seasons, so officers ignore
-- dumps from non-officers when deciding whether theirs is still needed.
local dumpSeen = {}
local function recentDump(digest)
    local d = dumpSeen[digest]
    if not d or GetTime() - d.at >= 60 then return nil end
    if KOS:CanPardon(KOS:MyName()) and not d.officer then return nil end
    return d
end

function Sync:ScheduleDump()
    if dumpTimer then return end
    local delay = 2 + math.random() * 6
    local wait = lastDumpAt + 30 - GetTime()
    if wait > delay then delay = wait end
    dumpTimer = C_Timer.NewTimer(delay, function()
        dumpTimer = nil
        Sync:Dump()
    end)
end

-- Loop breaker: if the same pair of fingerprints keeps disagreeing (an
-- item one side refuses), stop answering it for an hour instead of
-- re-sending everything forever.
local answered = {}
function Sync:ShouldAnswer(theirDigest)
    local pair = theirDigest .. ">" .. (KOS:Digest())
    local now = GetTime()
    local a = answered[pair]
    if a and now - a.first < 3600 and a.count >= 2 then return false end
    if not a or now - a.first >= 3600 then a = { first = now, count = 0 }; answered[pair] = a end
    a.count = a.count + 1
    return true
end

function Sync:CancelDump()
    if dumpTimer then dumpTimer:Cancel(); dumpTimer = nil end
end

function Sync:Dump()
    if not KOS:IsGuildList() then return end
    local digest, count = KOS:Digest()
    local seen = recentDump(digest)
    if seen then
        -- someone sent this exact set recently; a late newcomer may have missed it, so try once more later
        if not self.retryScheduled then
            self.retryScheduled = true
            C_Timer.After(60 - (GetTime() - seen.at) + math.random() * 5, function()
                Sync.retryScheduled = false
                if Sync.pendingAsk then Sync.pendingAsk = false; Sync:Dump() end
            end)
        end
        return
    end
    self.pendingAsk = false
    lastDumpAt = GetTime()
    dumpSeen[digest] = { at = GetTime(), officer = KOS:CanPardon(KOS:MyName()) }
    enqueue(lo, join("B", digest, count))
    local officer = KOS:CanPardon(KOS:MyName())
    KOS:EachItem(function(kind, a, b)
        local destructive = kind == "clear" or kind == "season" or kind == "strike"
        if officer or not destructive then enqueue(lo, itemMsg("D", kind, a, b)) end
    end)
    enqueue(lo, join("E", digest))
end

local lastSighting = {}
function Sync:SendSighting(T)
    if not KOS:IsGuildList() then return end
    local key = KOS:Canonical(T.n)
    local now = GetTime()
    if lastSighting[key] and now - lastSighting[key] < 120 then return end
    lastSighting[key] = now
    enqueue(hi, join("W", T.n, GetRealZoneText() or "", GetSubZoneText() or ""))
end

------------------------------------------------------------------------
-- Incoming
------------------------------------------------------------------------

local refreshPending
local function refreshSoon()
    if refreshPending then return end
    refreshPending = true
    C_Timer.After(0.5, function()
        refreshPending = false
        KOS:Changed()
    end)
end

local function applyItem(kind, it)
    if kind == "vote" then
        return KOS:MergeVote(it.key, it.target, it, it.guid, it.class)
    elseif kind == "clear" then
        return KOS:MergeClear(it.key, it.target, it)
    elseif kind == "guild" then
        return KOS:MergeGuild(it.key, it.target, it.guild, it.t)
    elseif kind == "kill" then
        return KOS:MergeKill(it)
    elseif kind == "death" then
        return KOS:MergeDeath(it)
    elseif kind == "strike" then
        return KOS:MergeStrike(it.id, it)
    elseif kind == "season" then
        return KOS:MergeSeason(it)
    end
end

-- Live messages: the sender must be the author and have permission.
local function allowedLive(kind, it, senderKey, senderFull)
    if kind == "guild" then return true end -- anyone can report what guild they saw
    if KOS:Canonical(it.by) ~= senderKey then return false end
    if kind == "vote" then return it.del or KOS:CanMark(senderFull) end
    if kind == "clear" or kind == "season" or kind == "strike" then return KOS:CanPardon(senderFull) end
    return true -- kills and deaths: players report their own
end

-- Bounty band of the player an item affects, for milestone shouts.
local function bandOf(kind, it)
    local key = (kind == "vote" or kind == "clear") and it.key or (kind == "death" and KOS:Canonical(it.killer))
    local T = key and KOS:GetTarget(key)
    if not T or not T.on then return nil, T end
    return KOS.BountyBand(KOS:LevelOf(T)), T
end

local function milestone(kind, it, bandBefore, pointsBefore)
    if kind == "vote" or kind == "death" then
        KOS:InvalidateGuildStats()
        local band, T = bandOf(kind, it)
        if band and T and (not bandBefore or band.min > bandBefore.min) and band.min >= 10 then
            KOS:Notify(band.min >= 20 and "big" or "info",
                "|c" .. band.color .. KOS:Display(T.n) .. " is now " .. band.name:upper() .. "|r (Lv " .. KOS:LevelOf(T) .. ")")
        end
    elseif kind == "kill" then
        local after = KOS:PointsOf(it.by)
        local a, b = KOS.HunterRank(pointsBefore or 0), KOS.HunterRank(after)
        if b.level > a.level and math.ceil(b.level / 5) > math.ceil(math.max(a.level, 0) / 5) then
            KOS:Notify("info", KOS:Display(it.by) .. " reached " .. KOS.RankTag(after) .. "!")
        end
    end
end

local function aboutMe(name) return name and KOS:Canonical(name) == KOS:MyKey() end

local function announceLive(kind, it, who)
    if kind == "kill" and not it.assist then KOS:CheckResponder(it.target, it.by) end
    if kind == "vote" then
        local T = KOS:GetTarget(it.key)
        if it.del then
            KOS:Notify("info", who .. " removed their mark on " .. KOS:Display(it.target)
                .. ((T and T.on) and (" (now " .. KOS:BountyTag(T) .. ")") or ""), nil, it.by)
        else
            KOS:Notify("info", who .. " marked |cffff6060" .. KOS:Display(it.target) .. "|r - " .. KOS:BountyTag(T)
                .. (it.note ~= "" and (": " .. it.note) or ""), true, it.by)
        end
    elseif kind == "death" then
        local T = KOS:Lookup(KOS:Canonical(it.killer))
        KOS:Notify(KOS:InMyZone(it.zone) and "nearby" or "info",
            who .. " was killed by |cffff6060" .. KOS:Display(it.killer) .. "|r"
            .. (it.zone ~= "" and (" in " .. it.zone) or "")
            .. (T and (" - now " .. KOS:BountyTag(T)) or "") .. " |cffff8000(revenge bonus for an hour)|r", true)
    elseif kind == "clear" then
        KOS:Notify("info", who .. " pardoned " .. KOS:Display(it.target) .. ".", true)
    elseif kind == "kill" then
        if it.assist then
            if it.v > 0 then KOS:Notify("info", who .. " assisted on " .. KOS:Display(it.target) .. " (+" .. it.v .. ")", true) end
            return
        end
        local pts = KOS:PointsOf(it.by)
        local helped = it.rev or it.res
        local rev = (it.rev and (", avenging " .. (aboutMe(it.rev) and "you" or KOS:Display(it.rev))))
            or (it.res and (", rescuing " .. (aboutMe(it.res) and "you" or KOS:Display(it.res)))) or ""
        local T = KOS:GetTarget(KOS:Canonical(it.target))
        local prio = (aboutMe(helped) and "me") or ((T and KOS:IsTopBounty(T)) and "big") or "info"
        KOS:Notify(prio, "|cff40ff40" .. who .. "|r (" .. KOS.RankTag(pts) .. ") claimed the bounty on "
            .. KOS:Display(it.target) .. rev .. " - +" .. it.v .. (it.v == 1 and " point" or " points")
            .. (it.zone ~= "" and (" in " .. it.zone) or ""), true)
    elseif kind == "strike" then
        KOS:Notify("info", who .. " struck a bounty claim (" .. it.id:gsub("|%d+$", ""):gsub("|", " on ") .. ").", true)
    elseif kind == "season" then
        KOS:Notify("big", who .. " started a new bounty season. The leaderboard has been reset.", true)
    end
end

-- Messages whose permission check needs a rank we don't know yet (roster
-- not loaded, or the sender just joined). Retried on the next roster update.
local pending = {}
local function needsRank(kind)
    if kind == "clear" or kind == "season" or kind == "strike" then return true end
    return kind == "vote" and KOS:MarkRank() ~= nil
end
local function deferIfUnknown(kind, who, text, sender)
    if KOS:IsGuildList() and needsRank(kind) and KOS:RankOf(who) == nil then
        if #pending < 100 then pending[#pending + 1] = { text, sender } end
        KOS:RequestRoster()
        return true
    end
end

function Sync:RetryPending()
    if #pending == 0 then return end
    local list = pending
    pending = {}
    for _, p in ipairs(list) do self:OnMessage(p[1], p[2], true) end
end

function Sync:OnMessage(text, sender, isRetry)
    local senderKey, senderFull = KOS:Canonical(sender)
    if not senderKey then bump("drop", "bad sender name"); return end
    if senderKey == KOS:MyKey() then return end
    local tag, payload = text:match("^(%u)\t(.*)$")
    if not isRetry then
        local st = stats()
        if st then st.recv = st.recv + 1 end
        local ver
        if tag == "H" then ver = select(4, strsplit(SEP, payload)) or "older than 0.6.3"
        elseif tag == "V" then ver = (strsplit(SEP, payload)) end
        if ver and ver ~= "older than 0.6.3" and not KOS.VersionNum(ver) then ver = "?" end
        heardFrom(senderKey, senderFull, ver)
    end
    if not KOS:IsGuildList() then bump("drop", "not in a guild yet"); return end
    if not tag then bump("drop", "unreadable"); return end

    if tag == "H" then
        local digest, _, _, ver = strsplit(SEP, payload)
        noteVersion(ver)
        maybeReplyVersion(ver)
        if digest ~= (KOS:Digest()) and self:ShouldAnswer(digest) then
            self.pendingAsk = true
            self:ScheduleDump()
        end

    elseif tag == "V" then
        local ver = strsplit(SEP, payload)
        noteVersion(ver)
        local n, mine = versionNum(ver), versionNum(addonVersion())
        if versionReply and n and mine and n >= mine then versionReply:Cancel(); versionReply = nil end

    elseif tag == "S" then
        local kind, it = decodeItem(payload)
        if not kind then bump("drop", "couldn't read item"); return end
        if not isRetry and deferIfUnknown(kind, senderFull, text, sender) then bump("drop", "waiting for guild roster"); return end
        if not allowedLive(kind, it, senderKey, senderFull) then bump("drop", "sender's rank can't do that"); return end
        local bandBefore = bandOf(kind, it)
        local pointsBefore = (kind == "kill") and KOS:PointsOf(it.by) or nil
        if applyItem(kind, it) then
            announceLive(kind, it, KOS:Display(senderFull))
            milestone(kind, it, bandBefore, pointsBefore)
            KOS:Changed()
        end

    elseif tag == "D" then
        local kind, it = decodeItem(payload)
        if not kind then bump("drop", "couldn't read item"); return end
        local destructive = kind == "clear" or kind == "season" or kind == "strike"
        -- Destructive items only count when a current officer relays them. The
        -- author named inside can't be trusted (anyone could write the GM's
        -- name), but the sender can. This also keeps a demoted officer's old
        -- pardon valid, since current officers still relay it.
        if destructive and not isRetry and deferIfUnknown(kind, senderFull, text, sender) then return end
        if destructive and not KOS:CanPardon(senderFull) then return end
        -- relayed items in my name: check them against what I actually did
        if (kind == "vote" or kind == "kill") and KOS:Canonical(it.by) == KOS:MyKey() then
            if kind == "vote" then KOS:AuditVote(it, senderFull) else KOS:AuditKill(it, senderFull) end
        end
        if applyItem(kind, it) then
            Sync:CountAway(kind, it)
            refreshSoon()
        end

    elseif tag == "B" then
        local digest = strsplit(SEP, payload)
        local fromOfficer = KOS:CanPardon(senderFull)
        dumpSeen[digest] = { at = GetTime(), officer = fromOfficer }
        -- someone with the same data is already sending it; an officer only
        -- stands down for another officer (only officers relay pardons)
        if digest == (KOS:Digest()) and (fromOfficer or not KOS:CanPardon(KOS:MyName())) then self:CancelDump() end

    elseif tag == "E" then
        local digest = strsplit(SEP, payload)
        if digest == (KOS:Digest()) then self:CancelDump()
        elseif self:ShouldAnswer(digest) then self.pendingAsk = true; self:ScheduleDump() end

    elseif tag == "A" then
        local attacker, zone, map, x, y, how = strsplit(SEP, payload)
        local key, full = KOS:Canonical(attacker)
        if not key then return end
        zone = KOS.CleanText(zone, 70)
        map, x, y = finite(map, 1e7), finite(x, 1e7), finite(y, 1e7)
        local firstCall = not KOS:RescueFor(key)
        KOS:NoteDistress(full, senderFull, map, x, y)
        if not firstCall then return end -- someone already called this one in
        local T = KOS:Lookup(key)
        local dist, dir = KOS:DistanceTo(map, x, y)
        local sameZone = KOS:InMyZone(zone)
        -- "near": within helpRange yards on the same map (or same zone if positions are unknown)
        local near
        if dist then near = dist <= (KOS.S.helpRange or 400) else near = sameZone end
        local grouped = (UnitInParty and UnitInParty(KOS:Display(senderFull))) or (UnitInRaid and UnitInRaid(KOS:Display(senderFull)))
        local where = dist and string.format("%d yd %s", dist, dir) or zone
        local verb = (how == "t" and " is under attack, likely by ") or (how == "m" and " needs help against ")
            or " is being ganked by "
        local helpText = "HELP! " .. KOS:Display(senderFull) .. verb .. KOS:Display(full) .. " - " .. where
        local mode = KOS.S.helpBanner
        local show = (mode == "any") or (mode == "zone" and sameZone) or (mode == "near" and near)
        local now = GetTime()
        if show and not grouped and KOS:InWorld() and now - (Sync.lastHelpBanner or -100) >= 15 then
            Sync.lastHelpBanner = now
            if RaidNotice_AddMessage and RaidWarningFrame then
                RaidNotice_AddMessage(RaidWarningFrame, helpText, { r = 0.25, g = 0.75, b = 1 })
            end
            PlaySound(8959, "Master")
            if KOS.ShowHelpPrompt then KOS:ShowHelpPrompt(full, senderFull, where, T, verb) end
        end
        KOS:Notify((near and not grouped) and "nearby" or "info", "|cff40c0ff" .. helpText .. "|r"
            .. (T and (" (" .. KOS:BountyTag(T) .. ")") or "") .. " - kill them within 3 minutes for a rescue bonus.")
        if T and KOS.TrackSighting then KOS:TrackSighting(T, senderFull, zone) end

    elseif tag == "O" then
        local attacker, victim, yards = strsplit(SEP, payload)
        local _, victimFull = KOS:Canonical(victim)
        local _, attackerFull = KOS:Canonical(attacker)
        if not victimFull or not attackerFull then return end
        yards = finite(yards, 1e5)
        yards = yards and math.floor(yards)
        local who = KOS:Display(senderFull)
        if KOS:Canonical(victimFull) == KOS:MyKey() then
            KOS:Notify("me", "|cff40c0ff" .. who .. " is on the way|r" .. (yards and (" (" .. yards .. " yd out)") or "") .. ".")
            if KOS.OnResponder then KOS:OnResponder(who, yards) end
        else
            if KOS.OnResponder and KOS:RescueFor(KOS:Canonical(attackerFull)) then KOS:OnResponder(who, yards, true) end
            KOS:Notify("info", who .. " is heading to help " .. KOS:Display(victimFull) .. " against " .. KOS:Display(attackerFull) .. ".")
        end

    elseif tag == "W" then
        local name, zone, sub = strsplit(SEP, payload)
        local key = KOS:Canonical(name)
        local T = key and KOS:Lookup(key)
        if not T then return end
        lastSighting[key] = GetTime() -- don't re-announce right after a guildie did
        zone, sub = KOS.CleanText(zone, 60), KOS.CleanText(sub, 60)
        T.seen = GetServerTime()
        T.zone = (sub ~= "" and sub ~= zone) and (zone .. " - " .. sub) or zone
        T.seenBy = senderFull
        KOS:Notify(KOS:InMyZone(T.zone) and "nearby" or "info", KOS:Display(senderFull) .. " spotted |cffff6060"
            .. KOS:Display(T.n) .. "|r (" .. KOS:BountyTag(T) .. ") in " .. T.zone, nil, senderFull)
        if KOS.TrackSighting and not KOS:IsMuted(senderFull) and not KOS:OnlyMutedMarks(T) then
            KOS:TrackSighting(T, senderFull, T.zone)
        end
        if KOS.RefreshUI then KOS:RefreshUI() end
    end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

KOS:On("ADDON_LOADED", function(name)
    if name ~= ADDON then return end
    local ok, res = pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
    local st = stats()
    if st then
        -- new session: reset the counters, keep the guildies heard from
        st.sent, st.recv, st.fail, st.drop = 0, 0, {}, {}
        st.prefix = ok and tostring(res) or ("error: " .. tostring(res))
    end
end)

KOS:On("GUILD_ROSTER_UPDATE", function() Sync:RetryPending() end)

KOS:On("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
    -- inside instances chat can arrive as secret values; we only sync in the world
    if KOS.IsSecret(prefix) or KOS.IsSecret(text) or KOS.IsSecret(channel) or KOS.IsSecret(sender) then
        bump("drop", "secret (any addon)")
        return
    end
    if prefix ~= PREFIX then return end
    if channel ~= "GUILD" then bump("drop", "not guild channel"); return end
    Sync:OnMessage(text, sender)
end)

-- "While you were away": count what the first syncs after login bring in.
local away
local function startAwayTracking()
    away = { marks = 0, kills = 0, deaths = 0, points = KOS:PointsOf(KOS:MyName()) }
    C_Timer.After(120, function()
        local a = away
        away = nil
        if not a or (a.marks + a.kills + a.deaths) == 0 then return end
        local parts = {}
        if a.marks > 0 then parts[#parts + 1] = a.marks .. " new marks" end
        if a.deaths > 0 then parts[#parts + 1] = a.deaths .. " guildies ganked" end
        if a.kills > 0 then parts[#parts + 1] = a.kills .. " bounties claimed" end
        local top = KOS:TopBountyKey()
        local T = top and KOS:GetTarget(top)
        local now = KOS:PointsOf(KOS:MyName())
        KOS:Notify("me", "While you were away: " .. table.concat(parts, ", ") .. "."
            .. (T and (" Top bounty: " .. KOS:Display(T.n) .. " (" .. KOS:BountyTag(T) .. ").") or "")
            .. (now ~= a.points and (" Your season points: " .. a.points .. " -> " .. now .. ".") or ""))
    end)
end
function Sync:CountAway(kind, it)
    if not away then return end
    if kind == "vote" and not it.del then away.marks = away.marks + 1
    elseif kind == "kill" and not it.assist then away.kills = away.kills + 1
    elseif kind == "death" then away.deaths = away.deaths + 1 end
end

local loggedIn
KOS:On("PLAYER_ENTERING_WORLD", function()
    if loggedIn then return end
    loggedIn = true
    startAwayTracking()
    C_Timer.After(5, function() KOS:RequestRoster() end)
    C_Timer.After(15, function() Sync:Hello() end)
    C_Timer.NewTicker(900, function() Sync:Hello() end) -- quiet repair: one message every 15 minutes
end)

KOS:On("PLAYER_GUILD_UPDATE", function()
    if loggedIn and not Sync.helloSent and IsInGuild() then
        C_Timer.After(10, function() if not Sync.helloSent then Sync:Hello() end end)
    end
end)

------------------------------------------------------------------------
-- /utu sync: what sync has done this session, then ask guildies to compare.
------------------------------------------------------------------------

local function countsText(t)
    local parts = {}
    for k, n in pairs(t) do parts[#parts + 1] = k .. " x" .. n end
    table.sort(parts)
    return table.concat(parts, ", ")
end

function Sync:Status()
    local st = stats()
    if not st then return end
    local g = KOS:IsGuildList() and KOS:ListKey()
    KOS:Print(g and ("Syncing with guild " .. KOS:Display(g) .. ".") or "Not in a guild: nothing syncs.")
    local fails = countsText(st.fail)
    KOS:Print(string.format("This session: sent %d message%s%s, received %d. Waiting to send: %d.",
        st.sent, st.sent == 1 and "" or "s", fails ~= "" and (" (failed: " .. fails .. ")") or "",
        st.recv, self:QueueSize()))
    local drops = countsText(st.drop)
    if drops ~= "" then KOS:Print("Ignored: " .. drops .. ".") end
    if st.prefix and st.prefix ~= "true" and st.prefix ~= "0" and st.prefix ~= "nil" then
        KOS:Print("Registering the message channel returned " .. st.prefix .. ".")
    end
    local peers = {}
    for _, p in pairs(st.peers) do peers[#peers + 1] = p end
    table.sort(peers, function(a, b) return (a.t or 0) > (b.t or 0) end)
    if #peers == 0 then
        KOS:Print("Not heard from any guildie with the addon yet. They need Utu (or Kill on Sight 0.5.0 or later) and to be online at the same time as you.")
    else
        local parts = {}
        for i = 1, math.min(#peers, 10) do
            local p = peers[i]
            parts[#parts + 1] = string.format("%s (%s, %s)", KOS:Display(p.name), p.ver or "version not seen yet", KOS.Ago(p.t))
        end
        KOS:Print("Heard from: " .. table.concat(parts, "; ") .. ".")
        KOS:Print("Versions before 0.5.0 can't receive names with spaces.")
    end
    local flags = KOS:FlagLines()
    if #flags > 0 then
        KOS:Print("Possible forgeries in your name (newest first):")
        for i = 1, math.min(#flags, 10) do DEFAULT_CHAT_FRAME:AddMessage("  - " .. flags[i]) end
    end
end
