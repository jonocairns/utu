-- Utu: finding listed players, alerting, bounty claims, auto-marks.
--
-- WoW has no "players near me" API, so we watch everything that reveals a
-- nearby player: nameplates (~40 yd), the combat log, target and mouseover.
--
-- Where the client withholds the combat log (WoW: Forever), kills come from
-- honour gains, gankers are confirmed by you after you die, and help calls
-- come from hostile players targeting you while you take damage.
local ADDON, ns = ...
local KOS = ns.KOS

local band = bit.band
local PLAYER_FLAG = COMBATLOG_OBJECT_TYPE_PLAYER or 0x00000400
local SKULL = KOS.SKULL

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function zoneString()
    local zone, sub = GetRealZoneText() or "", GetSubZoneText() or ""
    if sub ~= "" and sub ~= zone then return zone .. " - " .. sub end
    return zone
end
KOS.ZoneString = zoneString

-- Levels and GUIDs of players we've seen as units. The combat log and
-- honour messages carry names only.
local levelCache, nameGUID, cacheCount = {}, {}, 0
local function remember(info)
    if not info or not info.guid then return end
    local key = KOS:Canonical(info.full)
    if key and nameGUID[key] == nil then
        cacheCount = cacheCount + 1
        if cacheCount > 2000 then wipe(levelCache); wipe(nameGUID); cacheCount = 0 end
    end
    if key then nameGUID[key] = info.guid end
    if info.level then levelCache[info.guid] = info.level end
end
function KOS:LevelOfGUID(guid) return guid and levelCache[guid] end
function KOS:GUIDOfName(name)
    local key = self:Canonical(name)
    return key and nameGUID[key]
end
local plates = {} -- nameplate unit token -> nameplate frame

local function label(T) return KOS:BountyTag(T) end

------------------------------------------------------------------------
-- Alerts
------------------------------------------------------------------------

-- Encounters: a player alerts when they *arrive* (not seen for `cooldown`
-- seconds), not every minute they stay near you. Several arrivals at once
-- collapse into one summary banner.
local lastSeen = {}
local recentAlerts = {}
local burst

local function flushBurst()
    local b = burst
    burst = nil
    if not b or b.n == 0 then return end
    local S = KOS.S
    local text = b.n .. " KoS players nearby - top: " .. KOS:Display(b.top.n)
        .. (b.top.virtual and "" or (" Lv " .. KOS:LevelOf(b.top)))
    if S.banner and RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, text, { r = 1, g = 0.3, b = 0.2 })
    end
    KOS:PlayAlertSound(S.sound)
    if S.chat then KOS:Print("|cffff6060" .. text .. "|r") end
end

-- key: list key; T: target (may be virtual); how: detection source
-- seenAs: current name if it differs from the listed one (renamed character)
function KOS:Alert(key, T, how, isTest, seenAs)
    local S = self.S
    local lvl = T.virtual and 0 or self:LevelOf(T)
    local mine = not T.virtual and self:MyVote(T) ~= nil
    if not isTest then
        local now = GetTime()
        local arrived = not lastSeen[key] or now - lastSeen[key] > (S.cooldown or 180)
        lastSeen[key] = now
        if not arrived then return end
        -- cold bounties go quiet, except players you marked yourself (if set)
        if not T.virtual and lvl < (S.minLevel or 1) and not (mine and S.alwaysMine) then return end
        -- KoS-guild members only get a skull unless you asked for banners
        if T.virtual and not S.guildBanners then return end
        local quietNow = (S.quietResting and IsResting and IsResting()) or (not S.alertsInPvP and self:InPvPInstance())
        for i = #recentAlerts, 1, -1 do
            if now - recentAlerts[i] > 15 then table.remove(recentAlerts, i) end
        end
        if #recentAlerts >= 3 and not quietNow then
            -- a crowd: one summary banner instead of one each
            if not burst then
                burst = { n = 0 }
                C_Timer.After(2, flushBurst)
            end
            burst.n = burst.n + 1
            if not burst.top or (not T.virtual and (burst.top.virtual or lvl > self:LevelOf(burst.top))) then burst.top = T end
            if not T.virtual then T.seen, T.zone, T.seenBy = GetServerTime(), zoneString(), self:MyName() end
            return
        end
        recentAlerts[#recentAlerts + 1] = now
    end

    local name = self:Display(T.n)
    if seenAs then name = name .. " (now " .. self:Display(seenAs) .. ")" end
    local note = self:TopNote(T)
    local loud = S.escalate and not T.virtual and lvl >= (S.loudLevel or 20)
    local quiet = not isTest and ((S.quietResting and IsResting and IsResting())
        or (not S.alertsInPvP and self:InPvPInstance()))

    if not quiet then
        if S.banner and RaidNotice_AddMessage and RaidWarningFrame then
            local tier = T.virtual and "KOS GUILD" or (KOS.BountyBand(lvl).name:upper() .. " LV " .. lvl)
            local r, g, b = self:BountyRGB(T)
            RaidNotice_AddMessage(RaidWarningFrame, tier .. ": " .. name .. (note ~= "" and (" - " .. note) or ""),
                { r = r, g = g, b = b })
        end
        self:PlayAlertSound(S.sound)
        if loud and S.sound ~= "raid" then PlaySound(8959, "Master") end
        if S.chat then
            self:Print("|cffff6060" .. name .. "|r is nearby -", label(T), note ~= "" and (": " .. note) or "",
                T.virtual and "" or ("|cff888888(worth " .. (self:ClaimValue(T)) .. " pts)|r"))
        end
        if (S.flash or loud) and self.Flash then self:Flash(loud) end
    end
    if isTest then return end

    if not T.virtual then
        T.seen = GetServerTime()
        T.zone = zoneString()
        T.seenBy = self:MyName()
    end
    if self.TrackSighting then self:TrackSighting(T, self:MyName(), zoneString()) end
    self:ShareSighting(T)
    if self.RefreshUI then self:RefreshUI() end
end

function KOS:PlayAlertSound(key)
    for _, s in ipairs(self.SOUNDS) do
        if s.key == key and s.id then PlaySound(s.id, "Master") end
    end
end

-- Tell others: hidden addon message to guildies, and optionally a visible
-- line in party/raid or guild chat (rate-limited so it can't spam).
local lastVisible, lastVisibleAny = {}, -1000
function KOS:ShareSighting(T)
    local S = self.S
    if T.virtual then return end -- don't broadcast every member of a KoS guild
    if IsInRaid() or not self:InWorld() then return end -- raids and BGs: everyone can see them anyway
    if S.announce and ns.Sync then ns.Sync:SendSighting(T) end
    if not (S.partyChat or S.guildChat) then return end
    local key = self:Canonical(T.n)
    local now = GetTime()
    if (lastVisible[key] and now - lastVisible[key] < 300) or now - lastVisibleAny < 20 then return end
    local note = self:TopNote(T)
    local lvl = self:LevelOf(T)
    local msg = "[KoS] " .. self:Display(T.n) .. " (" .. KOS.BountyBand(lvl).name .. " Lv " .. lvl .. ") spotted at "
        .. zoneString() .. (note ~= "" and (": " .. note) or "")
    local sent = false
    if S.partyChat and IsInGroup() then
        local ch = IsInRaid() and "RAID" or "PARTY"
        if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then ch = "INSTANCE_CHAT" end
        sent = pcall(SendChatMessage, msg, ch) or sent
    end
    if S.guildChat and IsInGuild() then
        sent = pcall(SendChatMessage, msg, "GUILD") or sent
    end
    if sent then
        lastVisible[key] = now
        lastVisibleAny = now
    end
end

------------------------------------------------------------------------
-- Matching visible units
------------------------------------------------------------------------

local function markTarget()
    if CanBeRaidTarget and not CanBeRaidTarget("target") then return end
    if GetRaidTargetIndex("target") == 8 then return end
    if IsInRaid() and not (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")) then return end
    SetRaidTarget("target", 8)
end

-- Resolve a unit, learn what we can, and alert if this source is enabled.
function KOS:CheckUnit(unit, how, alertEnabled)
    local info = self:UnitInfo(unit)
    if not info then return end
    remember(info)
    local T, key, full, unitKey = self:ResolveUnit(unit, info)
    if not T then return end
    if not T.virtual then
        if info.guid and not T.guid then T.guid = info.guid; self:InvalidateIndex() end
        if not T.class then T.class = info.class end
        if info.level then T.lvl = info.level end -- for the low-level payout slide
        -- the game's spelling beats a typed one ("kind eyes" -> "Kind Eyes")
        if key == unitKey then
            local _, seen = self:Canonical(full)
            if seen and T.n ~= seen then T.n = seen end
        end
    end
    if alertEnabled then
        self:Alert(key, T, how, false, (not T.virtual and key ~= unitKey) and full or nil)
    end
    if how == "target" and self.S.raidMark then markTarget() end
    return T
end

------------------------------------------------------------------------
-- Combat log: detection, kill claims, who killed me
------------------------------------------------------------------------

local keyCache, cacheSize = {}, 0
local function keyFor(raw)
    local k = keyCache[raw]
    if k == nil then
        k = KOS:Canonical(raw) or false
        keyCache[raw] = k
        cacheSize = cacheSize + 1
        if cacheSize > 5000 then wipe(keyCache); cacheSize = 0 end
    end
    return k
end

function KOS:CheckName(raw, guid, how)
    local key = keyFor(raw)
    if not key then return end
    local T, k = self:Lookup(key, guid)
    if not T then
        local g = self:GuildOfGUID(guid)
        if self.S.guildAlerts and self:IsKosGuild(g) then
            T, k = self:VirtualTarget(select(2, self:Canonical(raw)), guid, nil, g), key
        else
            return
        end
    elseif guid and not T.guid then
        T.guid = guid
        self:InvalidateIndex()
    end
    self:Alert(k, T, how, false, (not T.virtual and k ~= key) and select(2, self:Canonical(raw)) or nil)
end

-- Target for a kill claim: marked player, or a member of a KoS guild.
-- Guild-KoS scoring doesn't depend on the personal guildAlerts setting.
local function claimTarget(name, guid)
    local key = keyFor(name)
    if not key then return nil end
    local T = KOS:Lookup(key, guid)
    if T then return T end
    local g = KOS:GuildOfGUID(guid)
    if KOS:IsKosGuild(g) then return KOS:VirtualTarget(select(2, KOS:Canonical(name)), guid, nil, g) end
end

local lastHit      -- last damage to me from anything: { player, name, guid, at }
local killingBlow  -- the hit that actually killed me (overkill >= 0), if the log says so
local myHits, myHitsSize = {}, 0 -- player GUID -> GetTime() I last damaged them (for assists)

-- Is this combat-log name a guildie in my group?
local function groupedGuildie(name)
    if not name then return false end
    if not ((UnitInParty and UnitInParty(name)) or (UnitInRaid and UnitInRaid(name))) then return false end
    return KOS:RankOf(name) ~= nil
end

local function onCombatLog()
    local _, sub, _, sGUID, sName, sFlags, _, dGUID, dName, dFlags, _, p12, p13, p14, p15, p16 = CombatLogGetCurrentEventInfo()
    local me = UnitGUID("player")
    local destIsPlayer = dName and dFlags and band(dFlags, PLAYER_FLAG) ~= 0
    local srcIsPlayer = sName and sFlags and band(sFlags, PLAYER_FLAG) ~= 0

    if sub == "PARTY_KILL" and destIsPlayer then
        if sGUID == me then
            local T = claimTarget(dName, dGUID)
            local key = keyFor(dName)
            if T then
                KOS:ClaimKill(T, zoneString(), KOS:LevelOfGUID(dGUID))
            elseif key and KOS:RescueFor(key) then
                KOS:ClaimDefense(dName, dGUID, zoneString(), KOS:RescueFor(key))
            end
        elseif myHits[dGUID] and GetTime() - myHits[dGUID] <= 20 and groupedGuildie(sName) then
            local T = claimTarget(dName, dGUID)
            if T then KOS:ClaimAssist(T, sName, zoneString(), KOS:LevelOfGUID(dGUID)) end
        end
    end

    local isDamage = sub and sub:find("_DAMAGE$")
    if isDamage and sGUID == me and destIsPlayer then
        if not myHits[dGUID] then
            myHitsSize = myHitsSize + 1
            if myHitsSize > 500 then wipe(myHits); myHitsSize = 0 end
        end
        myHits[dGUID] = GetTime()
    end

    if isDamage and dGUID == me then
        -- overkill position depends on the event: SWING 13, ENVIRONMENTAL 14, spells/ranged 16
        local overkill
        if sub == "SWING_DAMAGE" then overkill = p13
        elseif sub == "ENVIRONMENTAL_DAMAGE" then overkill = p14
        else overkill = p16 end
        local hitInfo = { player = (srcIsPlayer and sGUID ~= me) or false, name = sName, guid = sGUID, at = GetTime() }
        lastHit = hitInfo
        if type(overkill) == "number" and overkill >= 0 then killingBlow = hitInfo end
    end

    if isDamage and dGUID == me and srcIsPlayer and sGUID ~= me then
        -- a KoS player, or anyone much higher level, is on me: shout for help
        if KOS.S.callForHelp and ns.Sync then
            local lvl = KOS:LevelOfGUID(sGUID)
            local bully = lvl and lvl - UnitLevel("player") >= KOS.DEFEND_LEVELS
            if bully or claimTarget(sName, sGUID) then
                local _, full = KOS:Canonical(sName)
                if full then ns.Sync:CallForHelp(full) end
            end
        end
    end

    if not KOS.S.srcCombat or next(KOS:Targets()) == nil then return end
    if sName and sFlags and band(sFlags, PLAYER_FLAG) ~= 0 and sGUID ~= me then KOS:CheckName(sName, sGUID, "combat") end
    if dName and dFlags and band(dFlags, PLAYER_FLAG) ~= 0 and dGUID ~= me then KOS:CheckName(dName, dGUID, "combat") end
end

-- I died: if an enemy player landed the last hit, report it (for revenge)
-- and auto-mark them.
local function onPlayerDead()
    -- prefer the logged killing blow; otherwise the very last thing that hit
    -- me. Either way it has to be a player: a fall or a mob finishing you
    -- off after someone poked you doesn't count as a gank.
    local hit = (killingBlow and GetTime() - killingBlow.at <= 3) and killingBlow or lastHit
    lastHit, killingBlow = nil, nil
    if not hit or not hit.player or GetTime() - hit.at > 3 then return end
    if (UnitInParty and UnitInParty(hit.name)) or (UnitInRaid and UnitInRaid(hit.name)) then return end
    local _, full = KOS:Canonical(hit.name)
    if not full then return end
    KOS:RecordDeath(full, zoneString())
    local lvl = KOS:LevelOfGUID(hit.guid)
    local levels = lvl and string.format(" (lvl %d vs my %d)", lvl, UnitLevel("player")) or ""
    KOS:AutoMark(full, hit.guid, nil, zoneString(), levels)
end

------------------------------------------------------------------------
-- Without a combat log: attackers, honour kills, confirming who killed you
------------------------------------------------------------------------

-- Hostile players seen targeting me: key -> { full, guid, level, class, at }
local attackers = {}
local lastDamaged = -100 -- GetTime() I last lost health
local lastHealth
local SCAN_UNITS = { "target", "focus", "mouseover" }

local function noteAttacker(u)
    if not KOS:IsTargetingMe(u) then return nil end -- cheap check first
    local info = KOS:UnitInfo(u)
    if not info or info.hostile == false then return nil end
    local key = KOS:Canonical(info.full)
    if not key or key == KOS:MyKey() then return nil end
    remember(info)
    local a = attackers[key] or {}
    a.full, a.guid, a.level, a.class, a.hostile, a.at = info.full, info.guid, info.level, info.class, info.hostile, GetTime()
    attackers[key] = a
    return key, a
end

-- Who's targeting me right now? If I'm also taking damage, a KoS player
-- (or anyone much higher level) among them triggers a call for help.
local function scanAttackers()
    if not KOS:InWorld() then return end
    local found = {}
    for _, u in ipairs(SCAN_UNITS) do
        local key, a = noteAttacker(u)
        if key then found[key] = a end
    end
    for u in pairs(plates) do
        local key, a = noteAttacker(u)
        if key then found[key] = a end
    end
    if KOS.caps.combatLog or not KOS.S.callForHelp or not ns.Sync then return end
    if GetTime() - lastDamaged > 2 then return end
    -- fighting a mob of my own: the damage is probably from it, not them
    local try = KOS.Try
    if try(UnitExists, "target") and not try(UnitIsPlayer, "target") and try(UnitCanAttack, "player", "target") then return end
    local myLevel = UnitLevel("player")
    for _, a in pairs(found) do
        if a.hostile then -- known to be the other faction
            local bully = a.level and myLevel and a.level - myLevel >= KOS.DEFEND_LEVELS
            if bully or claimTarget(a.full, a.guid) then ns.Sync:CallForHelp(a.full, "t") end
        end
    end
end
KOS.ScanAttackers = scanAttackers -- for tests

local function onDamaged()
    lastDamaged = GetTime()
    scanAttackers()
end

-- Recent attackers, newest first, seen within `window` seconds.
function KOS:RecentAttackers(window)
    local out, now = {}, GetTime()
    for _, a in pairs(attackers) do
        if now - a.at <= window then out[#out + 1] = a end
    end
    table.sort(out, function(x, y) return x.at > y.at end)
    return out
end

local scanTicker
local function startScanning()
    if scanTicker or KOS.caps.combatLog then return end
    scanTicker = C_Timer.NewTicker(0.5, scanAttackers)
end
local function stopScanning()
    if scanTicker then scanTicker:Cancel(); scanTicker = nil end
end

-- The death recap, if the client has one, may name the killing blow
-- (entry 1, as in Blizzard's recap window). Only offered if it's from
-- another player and wasn't already there before this death.
local lastRecapSig
local function readRecap()
    if not KOS.caps.deathRecap then return nil end
    local ok, events = pcall(C_DeathRecap.GetRecapEvents)
    if not ok or KOS.IsSecret(events) or type(events) ~= "table" then return nil end
    local first = events[1]
    if type(first) ~= "table" then return nil end
    local ts = KOS.Safe(first.timestamp)
    return first, tostring(type(ts) == "number" and ts or "?") .. "/" .. #events
end
local function primeRecap() -- whatever recap exists at login belongs to an earlier death
    local _, sig = readRecap()
    lastRecapSig = sig
end
local function recapKiller()
    local first, sig = readRecap()
    if not first or sig == lastRecapSig then return nil end
    lastRecapSig = sig
    local guid, name = KOS.Safe(first.sourceGUID), KOS.Safe(first.sourceName)
    if type(guid) ~= "string" or type(name) ~= "string" or not guid:find("^Player%-") then return nil end
    if guid == KOS.Safe(UnitGUID("player")) then return nil end
    return name, guid
end

local function inMyGroup(name)
    return (UnitInParty and UnitInParty(name)) or (UnitInRaid and UnitInRaid(name)) or false
end

-- I died. Offer the players who were on me (and the death recap's killer)
-- so I can confirm who it was; that records the gank and marks them.
local function offerKillers(at, zone, recent)
    local cands, seen = {}, {}
    local function add(full, guid, level, class, why)
        local key = KOS:Canonical(full)
        if not key or seen[key] or key == KOS:MyKey() or inMyGroup(KOS:Display(full)) then return end
        seen[key] = true
        cands[#cands + 1] = { full = select(2, KOS:Canonical(full)), guid = guid, level = level or KOS:LevelOfGUID(guid),
            class = class, why = why, T = KOS:Lookup(key, guid) }
    end
    local rName, rGUID = recapKiller()
    if rName then add(rName, rGUID, nil, nil, "death recap") end
    for _, a in ipairs(recent) do add(a.full, a.guid, a.level, a.class) end
    if #cands == 0 or not KOS:InWorld() or KOS:ListKey() == nil then return end
    while #cands > 3 do table.remove(cands) end
    if KOS.ShowDeathPrompt then KOS:ShowDeathPrompt(cands, at, zone) end
end

-- the recap may fill in a moment after the death event
local function onPlayerDeadNoLog()
    local at, zone = GetServerTime(), zoneString()
    local recent = KOS:RecentAttackers(10)
    wipe(attackers)
    C_Timer.After(1, function() offerKillers(at, zone, recent) end)
end

-- I confirmed who killed me (from the death prompt).
function KOS:ConfirmKiller(c, at, zone)
    zone = zone or zoneString()
    self:RecordDeath(c.full, zone, at)
    local myLevel = UnitLevel("player")
    local levels = (c.level and myLevel) and string.format(" (lvl %d vs my %d)", c.level, myLevel) or ""
    self:AutoMark(c.full, c.guid, c.class, zone, levels)
    if not self.S.autoMark then
        self:Notify("me", "Reported " .. self:Display(c.full) .. " for ganking you.")
    end
end

-- Honour gains name the victim: "Gankdude dies, honorable kill Rank: ..."
-- Every guildie credited with the kill can claim it; the bounty drains once.
-- Turn a format string ("%s dies, honorable kill Rank: %s ...", or a
-- localised "%2$s ... %1$s") into a pattern; returns it and which capture
-- holds argument 1 (the victim).
local function escape(s) return (s:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0")) end
local function patternFrom(fmt)
    local parts, caps, argi, victimCap, i = {}, 0, 0, nil, 1
    while true do
        local s, e, num, conv = fmt:find("%%(%d?)%$?([sd])", i)
        if not s then parts[#parts + 1] = escape(fmt:sub(i)); break end
        parts[#parts + 1] = escape(fmt:sub(i, s - 1))
        argi = argi + 1
        local arg = tonumber(num) or argi
        if conv == "s" then
            caps = caps + 1
            parts[#parts + 1] = "(.-)"
            if arg == 1 then victimCap = caps end
        else
            parts[#parts + 1] = "%d+"
        end
        i = e + 1
    end
    if not victimCap then return nil end
    return "^" .. table.concat(parts) .. "$", victimCap
end

local HONOR_STRINGS = { "COMBATLOG_HONORGAIN", "COMBATLOG_HONORGAIN_NO_RANK", "COMBATLOG_HONORGAIN_EXHAUSTION1",
    "COMBATLOG_HONORGAIN_NO_RANK_EXHAUSTION1" }
local honorPatterns
local function buildHonorPatterns()
    honorPatterns = {}
    for _, gs in ipairs(HONOR_STRINGS) do
        local fmt = _G[gs]
        if type(fmt) == "string" then
            local pat, cap = patternFrom(fmt)
            if pat then honorPatterns[#honorPatterns + 1] = { pat, cap } end
        end
    end
    honorPatterns[#honorPatterns + 1] = { "^(.-) dies, honorable kill", 1 }
end

local function honorVictim(msg)
    if not honorPatterns then buildHonorPatterns() end
    msg = msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h%[?(.-)%]?|h", "%1")
    for _, p in ipairs(honorPatterns) do
        local caps = { msg:match(p[1]) }
        local name = caps[p[2]]
        if name and name ~= "" then return name end
    end
end
KOS.HonorPatternFrom = patternFrom -- for tests
KOS.HonorVictim = honorVictim -- for tests

local function onHonorGain(msg)
    if KOS.IsSecret(msg) or type(msg) ~= "string" then return end
    KOS:Sample("honor", msg)
    if KOS.caps.combatLog then return end -- the combat log already gives us killing blows
    local name = honorVictim(msg)
    local key, full = KOS:Canonical(name)
    if not key or key == KOS:MyKey() then return end
    local guid = KOS:GUIDOfName(full)
    local T = claimTarget(full, guid)
    if T then
        KOS:ClaimKill(T, zoneString(), KOS:LevelOfGUID(guid))
    elseif KOS:RescueFor(key) then
        KOS:ClaimDefense(full, guid, zoneString(), KOS:RescueFor(key))
    end
end

-- /kos sos and the key binding: call for help against my target, or
-- whoever was on me most recently.
function KOS:ManualHelp()
    if not ns.Sync then return end
    if not self:InWorld() then self:Print("Help calls only work in the open world."); return end
    local info = self:UnitInfo("target")
    local full = info and info.hostile ~= false and self:Canonical(info.full) ~= self:MyKey() and info.full
    if not full then
        local recent = self:RecentAttackers(20)[1]
        full = recent and recent.full
    end
    if not full then self:Print("Target the player attacking you, then call for help."); return end
    if ns.Sync:CallForHelp(full, "m") then
        self:Notify("me", "Called nearby guildies for help against " .. self:Display(full) .. ".")
    else
        self:Print("Can't call for help against " .. self:Display(full) .. " right now (one call a minute, not in raids).")
    end
end

KOS.OnPlayerDead = function()
    if KOS.caps.combatLog then onPlayerDead() else onPlayerDeadNoLog() end
end -- for tests

------------------------------------------------------------------------
-- Nameplates: skull, tinted by bounty tier, with the weight beside it
------------------------------------------------------------------------

local marks = {}  -- nameplate frame -> { icon, text }

local function markFor(plate)
    local m = marks[plate]
    if not m then
        local parent = plate.UnitFrame or plate
        m = {}
        m.icon = parent:CreateTexture(nil, "OVERLAY", nil, 7)
        m.icon:SetTexture(SKULL)
        m.icon:SetSize(22, 22)
        m.icon:SetPoint("BOTTOM", parent, "TOP", 0, 2)
        m.text = parent:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        m.text:SetPoint("LEFT", m.icon, "RIGHT", 1, 0)
        marks[plate] = m
    end
    return m
end

function KOS:UpdatePlate(unit)
    local plate = plates[unit]
    if not plate then return end
    local T = self.S.nameplate and self:ResolveUnit(unit)
    if T then
        local ok, m = pcall(markFor, plate) -- protected plates (friendly in instances) refuse children
        if ok and m then
            local r, g, b = KOS:BountyRGB(T)
            m.icon:SetVertexColor(r, g, b)
            local lvl = T.virtual and 0 or KOS:LevelOf(T)
            m.text:SetText(lvl > 0 and lvl or "")
            m.text:SetTextColor(r, g, b)
            m.icon:Show()
            m.text:Show()
        end
    elseif marks[plate] then
        marks[plate].icon:Hide()
        marks[plate].text:Hide()
    end
    return T
end

function KOS:RefreshPlates()
    for unit in pairs(plates) do self:UpdatePlate(unit) end
end

------------------------------------------------------------------------
-- Tooltip
------------------------------------------------------------------------

local function onTooltipUnit(tt)
    if not KOS.S or not KOS.S.tooltip then return end
    local _, unit = tt:GetUnit()
    if KOS.IsSecret(unit) or not unit then return end
    local info = KOS:UnitInfo(unit)
    if not info then return end

    -- guildies: show their hunter rank
    if KOS.Try(UnitIsInMyGuild, unit) and KOS:IsGuildList() then
        local pts, row = KOS:PointsOf(info.full)
        if pts > 0 then
            tt:AddLine("|T" .. SKULL .. ":12|t " .. KOS.RankTag(pts) .. " |cffffd100" .. pts .. " pts|r"
                .. (row and row.revenges > 0 and (" |cffff8000" .. row.revenges .. " revenges|r") or ""))
            tt:Show()
        end
        return
    end

    local T = KOS:ResolveUnit(unit, info)
    if not T then return end
    if T.virtual then
        local r = KOS:GuildStats()[T.guild]
        tt:AddLine("|T" .. SKULL .. ":14|t |cffbbbbbbMember of KoS guild <" .. T.guild .. ">|r")
        if r then tt:AddLine(r.members .. " members marked, worth " .. KOS.GUILD_MEMBER_POINTS .. " points", 0.6, 0.6, 0.6) end
        tt:Show()
        return
    end
    tt:AddLine("|T" .. SKULL .. ":14|t |cffff2020Kill on Sight|r - " .. KOS:BountyTag(T)
        .. " |cffffd100(" .. (KOS:ClaimValue(T)) .. " pts to you)|r")
    local votes = KOS:ActiveVotes(T)
    for i = #votes, math.max(1, #votes - 2), -1 do
        local v = votes[i]
        tt:AddLine((v.note ~= "" and v.note or "marked") .. " - " .. KOS:Display(v.by), 1, 1, 1, true)
    end
    if #votes > 3 then tt:AddLine("+" .. (#votes - 3) .. " more", 0.6, 0.6, 0.6) end
    local n = KOS:KillsOf(T.n)
    if n > 0 then tt:AddLine("Killed " .. n .. (n == 1 and " time" or " times") .. " this season", 0.6, 0.6, 0.6) end
    tt:Show()
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tt)
        if tt == GameTooltip then onTooltipUnit(tt) end
    end)
else
    GameTooltip:HookScript("OnTooltipSetUnit", onTooltipUnit)
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

local function plateAdded(unit, retry)
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if not plate then return end
    plates[unit] = plate
    local info = KOS:UnitInfo(unit)
    if not info then
        -- the unit may not be filled in yet when the plate appears
        if not retry and KOS.Try(UnitIsPlayer, unit) then
            C_Timer.After(0.2, function() if plates[unit] == plate then plateAdded(unit, true) end end)
        end
        return
    end
    remember(info) -- any player: needed for "bully" help calls
    if KOS:UpdatePlate(unit) then KOS:CheckUnit(unit, "nameplate", KOS.S.srcNameplate) end
end

KOS:On("NAME_PLATE_UNIT_ADDED", function(unit) plateAdded(unit) end)

KOS:On("NAME_PLATE_UNIT_REMOVED", function(unit)
    local plate = plates[unit]
    plates[unit] = nil
    local m = plate and marks[plate]
    if m then m.icon:Hide(); m.text:Hide() end
end)

KOS:On("PLAYER_TARGET_CHANGED", function()
    KOS:CheckUnit("target", "target", KOS.S.srcTarget)
    if KOS.RefreshTargetBadge then KOS:RefreshTargetBadge() end
end)

KOS:On("UPDATE_MOUSEOVER_UNIT", function() KOS:CheckUnit("mouseover", "mouseover", KOS.S.srcMouseover) end)

if KOS.caps.combatLog then
    if not KOS:On("COMBAT_LOG_EVENT_UNFILTERED", onCombatLog) then KOS.caps.combatLog = false end
end

KOS:On("PLAYER_DEAD", function() KOS.OnPlayerDead() end)
KOS:On("CHAT_MSG_COMBAT_HONOR_GAIN", onHonorGain)

-- taking damage: UNIT_COMBAT where available, else watch my health drop
KOS:On("UNIT_COMBAT", function(unit, action)
    if KOS.IsSecret(unit) or KOS.IsSecret(action) then return end
    if unit == "player" and action == "WOUND" then onDamaged() end
end)
KOS:On("UNIT_HEALTH", function(unit)
    if KOS.IsSecret(unit) or unit ~= "player" then return end
    local h = KOS.Try(UnitHealth, "player")
    if type(h) ~= "number" then return end
    if lastHealth and h < lastHealth then onDamaged() end
    lastHealth = h
end)
KOS:On("PLAYER_REGEN_DISABLED", startScanning)
KOS:On("PLAYER_REGEN_ENABLED", stopScanning)
KOS:On("PLAYER_ALIVE", function() lastHealth = nil end)
KOS:On("PLAYER_LOGIN", primeRecap)
