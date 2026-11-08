-- Kill on Sight: what this client lets addons do, safe unit reads, and
-- diagnostics.
--
-- WoW: Forever runs on the Midnight engine, which hides some values from
-- addons ("secret values") and may withhold the combat log entirely.
-- Everything that reads a unit goes through KOS:UnitInfo, which drops
-- secret values instead of throwing on them. Features check KOS.caps and
-- fall back to other evidence when something is unavailable.
local ADDON, ns = ...
local KOS = ns.KOS

------------------------------------------------------------------------
-- Secret values
------------------------------------------------------------------------

local function isSecret(v)
    return issecretvalue ~= nil and v ~= nil and issecretvalue(v) == true
end
KOS.IsSecret = isSecret

-- v, or nil if it's a secret we can't look at.
local function safe(v)
    if isSecret(v) then return nil end
    return v
end
KOS.Safe = safe

-- Call an API that might be missing, throw, or return secrets; returns its
-- first two results with secrets dropped.
local function try(fn, ...)
    if not fn then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok then return nil end
    return safe(a), safe(b)
end
KOS.Try = try

------------------------------------------------------------------------
-- Capabilities
------------------------------------------------------------------------

-- combatLog:   COMBAT_LOG_EVENT_UNFILTERED is ours to use (kills, gankers, assists)
-- secrets:     the client has secret values at all
-- deathRecap:  C_DeathRecap exists (may name your killer)
-- position:    we can read our own map position (help-call distances)
KOS.caps = { combatLog = false, secrets = false, deathRecap = false, position = false }

function KOS:DetectCaps()
    local caps = self.caps
    caps.secrets = issecretvalue ~= nil
    -- On the Midnight engine, the combat log is withheld from addons, and
    -- registering for it can raise an error or a "blocked" popup. Only use
    -- it on clients without secret values that still expose it.
    caps.combatLog = CombatLogGetCurrentEventInfo ~= nil and not caps.secrets
    caps.deathRecap = C_DeathRecap ~= nil and C_DeathRecap.GetRecapEvents ~= nil
    caps.position = C_Map ~= nil and C_Map.GetBestMapForUnit ~= nil and C_Map.GetPlayerMapPosition ~= nil
    return caps
end
KOS:DetectCaps()

-- One line per capability for the Settings tab and /kos probe.
function KOS:CapsSummary()
    local c = self.caps
    local function row(ok, yes, no) return { ok = ok, text = ok and yes or no } end
    return {
        row(c.combatLog, "Kill credit and gank detection from the combat log",
            "No combat log on this client: kills come from honour gains, and you confirm who killed you"),
        row(c.position, "Help-call distances", "No map position: help calls use the whole zone"),
        row(c.deathRecap, "Death recap may name your killer", "No death recap"),
    }
end

------------------------------------------------------------------------
-- Unit reads
------------------------------------------------------------------------

local function factionOf(unit) return (try(UnitFactionGroup, unit)) end

-- Everything we know about a unit, with secrets left out:
-- { player, full, guid, level, class, guild, hostile }
-- Returns nil if the unit doesn't exist or isn't a player we can name.
function KOS:UnitInfo(unit)
    if not unit then return nil end
    local isPlayer = try(UnitIsPlayer, unit)
    if not isPlayer then return nil end
    local n, r = try(UnitName, unit)
    if not n or n == "" or n == UNKNOWNOBJECT then return nil end
    local full = (r and r ~= "") and (n .. "-" .. r) or n
    local info = { player = true, full = full }
    info.guid = try(UnitGUID, unit)
    local lvl = try(UnitLevel, unit)
    if type(lvl) == "number" and lvl > 0 then info.level = lvl end
    local _, class = try(UnitClass, unit)
    info.class = class
    info.guild = try(GetGuildInfo, unit)
    -- hostile = other faction. UnitIsEnemy/UnitCanAttack mean "attackable
    -- right now" and are false for unflagged enemies.
    local theirs, mine = factionOf(unit), factionOf("player")
    if theirs and mine then info.hostile = theirs ~= mine end
    return info
end

-- Is `unit` targeting me? nil if the client won't say.
function KOS:IsTargetingMe(unit)
    return (try(UnitIsUnit, unit .. "target", "player"))
end

------------------------------------------------------------------------
-- Diagnostics: event counts, samples and errors, saved to
-- KillOnSightDB.diag so they can be read from the SavedVariables file.
------------------------------------------------------------------------

KOS.eventCounts = {}
local MAX_ERRORS, MAX_SAMPLES = 20, 5

local function diag()
    local db = KOS.db
    if not db then return nil end
    db.diag = db.diag or {}
    local d = db.diag
    d.errors = d.errors or {}
    d.samples = d.samples or {}
    return d
end

function KOS:CountEvent(event)
    self.eventCounts[event] = (self.eventCounts[event] or 0) + 1
end

-- Keep the last few examples of something (e.g. honour messages).
function KOS:Sample(kind, text)
    local d = diag()
    if not d or isSecret(text) then return end
    d.samples[kind] = d.samples[kind] or {}
    local l = d.samples[kind]
    l[#l + 1] = { t = GetServerTime(), text = tostring(text):sub(1, 200) }
    while #l > MAX_SAMPLES do table.remove(l, 1) end
end

-- Record an error from one of our handlers, then pass it to the normal
-- error handler (BugSack etc.). Repeats of the same message are counted.
function KOS:RecordError(where, err)
    local d = diag()
    local msg = tostring(err)
    if d then
        local last = d.errors[#d.errors]
        if last and last.msg == msg then
            last.n = (last.n or 1) + 1
            last.t = GetServerTime()
        else
            d.errors[#d.errors + 1] = {
                t = GetServerTime(), where = where, msg = msg:sub(1, 400),
                stack = debugstack and debugstack(3, 6, 0) or nil,
            }
            while #d.errors > MAX_ERRORS do table.remove(d.errors, 1) end
        end
    end
end

------------------------------------------------------------------------
-- /kos probe: test what this client allows and save the results to
-- KillOnSightDB.probe.
------------------------------------------------------------------------

local function describe(v)
    if isSecret(v) then return "SECRET" end
    if v == nil then return "nil" end
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then return tostring(v) end
    return t
end

local function probeCall(fn, ...)
    if not fn then return "missing" end
    local res = { pcall(fn, ...) }
    if not res[1] then return "error: " .. tostring(res[2]):sub(1, 120) end
    local out = {}
    for i = 2, math.min(#res, 5) do out[#out + 1] = describe(res[i]) end
    return table.concat(out, ", ")
end

local function probeUnit(unit)
    local exists = probeCall(UnitExists, unit)
    if exists ~= "true" then return { exists = exists } end
    return {
        exists = exists,
        name = probeCall(UnitName, unit),
        guid = probeCall(UnitGUID, unit),
        isPlayer = probeCall(UnitIsPlayer, unit),
        level = probeCall(UnitLevel, unit),
        class = probeCall(UnitClass, unit),
        guild = probeCall(GetGuildInfo, unit),
        faction = probeCall(UnitFactionGroup, unit),
        isEnemy = probeCall(UnitIsEnemy, "player", unit),
        canAttack = probeCall(UnitCanAttack, "player", unit),
        targetingMe = probeCall(UnitIsUnit, unit .. "target", "player"),
        health = probeCall(UnitHealth, unit),
        dead = probeCall(UnitIsDeadOrGhost, unit),
    }
end

local function has(path)
    local v = _G
    for part in path:gmatch("[^%.]+") do
        if type(v) ~= "table" then return false end
        v = v[part]
    end
    return v ~= nil
end

local APIS = {
    "issecretvalue", "CombatLogGetCurrentEventInfo", "C_DeathRecap", "C_DeathRecap.GetRecapEvents",
    "C_DeathRecap.HasRecapEvents", "C_DeathRecap.GetRecapLink", "DeathRecap_HasEvents",
    "C_Map.GetBestMapForUnit", "C_Map.GetPlayerMapPosition", "C_Map.GetWorldPosFromMapPos", "UnitPosition",
    "C_ChatInfo.SendAddonMessage", "C_NamePlate.GetNamePlateForUnit", "C_NamePlate.GetNamePlates",
    "Settings.RegisterCanvasLayoutCategory", "Settings.RegisterAddOnCategory", "Settings.OpenToCategory",
    "InterfaceOptions_AddCategory", "Menu.ModifyMenu", "MenuUtil", "UnitPopup_ShowMenu",
    "AddonCompartmentFrame", "TooltipDataProcessor.AddTooltipPostCall", "BackdropTemplateMixin",
    "C_GameRules", "C_DamageMeter", "GetDeathRecapLink",
}

local PROBE_EVENTS = { "COMBAT_LOG_EVENT_UNFILTERED", "UNIT_COMBAT", "CHAT_MSG_COMBAT_HONOR_GAIN" }

function KOS:Probe()
    local db = self.db
    local p = { t = GetServerTime() }
    local version, build, date, toc = GetBuildInfo()
    p.client = { version = version, build = build, date = date, toc = toc }
    p.project = { id = WOW_PROJECT_ID, camelot = WOW_PROJECT_CAMELOT, classic = WOW_PROJECT_CLASSIC,
        mainline = WOW_PROJECT_MAINLINE }
    p.caps = {}
    for k, v in pairs(self.caps) do p.caps[k] = v end
    p.apis = {}
    for _, name in ipairs(APIS) do p.apis[name] = has(name) end

    -- Can we register the events we care about? Uses a throwaway frame.
    -- (May show a "blocked" message once on clients that forbid the combat log.)
    p.register = {}
    local f = CreateFrame("Frame")
    for _, e in ipairs(PROBE_EVENTS) do
        local ok, err = pcall(f.RegisterEvent, f, e)
        local reg = ok and f.IsEventRegistered and f:IsEventRegistered(e)
        p.register[e] = ok and (reg and "ok" or "not registered") or ("error: " .. tostring(err):sub(1, 120))
    end
    pcall(f.UnregisterAllEvents, f)

    p.player = probeUnit("player")
    p.target = probeUnit("target")
    p.mouseover = probeUnit("mouseover")
    p.nameplates = {}
    local n = 0
    for i = 1, 40 do
        local u = "nameplate" .. i
        if try(UnitExists, u) then
            n = n + 1
            if n <= 3 then p.nameplates[#p.nameplates + 1] = probeUnit(u) end
        end
    end
    p.nameplateCount = n

    local map = try(C_Map and C_Map.GetBestMapForUnit, "player")
    p.position = { map = describe(map) }
    if map and C_Map.GetPlayerMapPosition then
        local ok, pos = pcall(C_Map.GetPlayerMapPosition, map, "player")
        if ok and pos and pos.GetXY then
            local x, y = pos:GetXY()
            p.position.x, p.position.y = describe(x), describe(y)
        else
            p.position.err = ok and "no position" or tostring(pos)
        end
    end
    p.unitPosition = probeCall(UnitPosition, "player")

    -- death recap: what does the most recent one look like?
    if C_DeathRecap and C_DeathRecap.GetRecapEvents then
        local ok, events = pcall(C_DeathRecap.GetRecapEvents)
        if not ok then
            p.recap = "error: " .. tostring(events):sub(1, 120)
        elseif type(events) ~= "table" then
            p.recap = describe(events)
        else
            p.recap = { count = #events }
            local e = events[#events] or events[1]
            if type(e) == "table" then
                for k, v in pairs(e) do p.recap[tostring(k)] = describe(v) end
            end
        end
    end

    p.events = {}
    for k, v in pairs(self.eventCounts) do p.events[k] = v end
    p.addonVersion = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")
        or (GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version"))
    db.probe = p

    -- short summary in chat
    local t = p.target
    self:Print("Probe saved. Client " .. tostring(version) .. " (" .. tostring(toc) .. ").")
    self:Print("Combat log: " .. tostring(p.register.COMBAT_LOG_EVENT_UNFILTERED)
        .. ". Honour messages seen: " .. (self.eventCounts.CHAT_MSG_COMBAT_HONOR_GAIN or 0)
        .. ". Death recap: " .. (p.recap and (type(p.recap) == "table" and "yes" or p.recap) or "missing") .. ".")
    if t.exists == "true" then
        self:Print("Target name: " .. t.name .. "; guild: " .. t.guild .. "; level: " .. t.level
            .. "; targeting you: " .. t.targetingMe .. ".")
    else
        self:Print("Tip: target an enemy player and run /kos probe again to test name reading.")
    end
    self:Print(n .. " nameplates visible. Log out or /reload to write the results to disk.")
    return p
end
