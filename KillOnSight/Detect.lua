-- Kill on Sight: finding listed players, alerting, bounty claims, auto-marks.
--
-- WoW has no "players near me" API, so we watch everything that reveals a
-- nearby player: nameplates (~40 yd), the combat log, target and mouseover.
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

-- Levels of players we've seen as units (the combat log doesn't carry levels).
local levelCache, levelCacheSize = {}, 0
local function rememberLevel(unit)
    local guid = UnitGUID(unit)
    local lvl = UnitLevel(unit)
    if not guid or not lvl or lvl <= 0 then return end
    if levelCache[guid] == nil then
        levelCacheSize = levelCacheSize + 1
        if levelCacheSize > 2000 then wipe(levelCache); levelCacheSize = 0 end
    end
    levelCache[guid] = lvl
end
function KOS:LevelOfGUID(guid) return guid and levelCache[guid] end

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
    if not UnitIsPlayer(unit) then return end
    rememberLevel(unit)
    local T, key, full, unitKey = self:ResolveUnit(unit)
    if not T then return end
    if not T.virtual then
        local guid = UnitGUID(unit)
        if guid and not T.guid then T.guid = guid; self:InvalidateIndex() end
        if not T.class then T.class = select(2, UnitClass(unit)) end
        local lvl = UnitLevel(unit)
        if lvl and lvl > 0 then T.lvl = lvl end -- for the low-level payout slide
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
KOS.OnPlayerDead = onPlayerDead -- for tests

------------------------------------------------------------------------
-- Nameplates: skull, tinted by bounty tier, with the weight beside it
------------------------------------------------------------------------

local plates = {} -- unit token -> nameplate frame
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
    if not unit or not UnitIsPlayer(unit) then return end

    -- guildies: show their hunter rank
    if UnitIsInMyGuild and UnitIsInMyGuild(unit) and KOS:IsGuildList() then
        local pts, row = KOS:PointsOf(KOS:UnitFull(unit))
        if pts > 0 then
            tt:AddLine("|T" .. SKULL .. ":12|t " .. KOS.RankTag(pts) .. " |cffffd100" .. pts .. " pts|r"
                .. (row and row.revenges > 0 and (" |cffff8000" .. row.revenges .. " revenges|r") or ""))
            tt:Show()
        end
        return
    end

    local T = KOS:ResolveUnit(unit)
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

KOS:On("NAME_PLATE_UNIT_ADDED", function(unit)
    if UnitIsPlayer(unit) then rememberLevel(unit) end -- any player: needed for "bully" help calls
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if not plate then return end
    plates[unit] = plate
    if KOS:UpdatePlate(unit) then KOS:CheckUnit(unit, "nameplate", KOS.S.srcNameplate) end
end)

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

if CombatLogGetCurrentEventInfo then
    KOS:On("COMBAT_LOG_EVENT_UNFILTERED", onCombatLog)
end

KOS:On("PLAYER_DEAD", onPlayerDead)
