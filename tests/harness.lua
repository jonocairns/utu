-- Offline test harness: stubs enough of the WoW API to run several
-- Utu clients side by side on a shared guild message bus.
-- Run: lua5.1 tests/run.lua   (from the repo root)

local H = {}
local ADDON_DIR = (arg and arg[0] and arg[0]:match("^(.*)/tests/") or ".") .. "/Utu/"
-- load order comes from the .toc, like the game
local FILES = {}
for line in io.lines(ADDON_DIR .. "Utu.toc") do
    local f = line:match("^([%w_]+%.lua)%s*$")
    if f then FILES[#FILES + 1] = f end
end

-- Forever mode (H.forever = true before newClient): no combat log, secret
-- values exist, and units can hide fields behind H.SECRET.
H.SECRET = setmetatable({ __secret = true }, { __tostring = function() return "SECRET" end })

------------------------------------------------------------------------
-- Virtual clock & timers
------------------------------------------------------------------------

H.now = 1000
H.serverTime = 1794096000 + 12 * 3600 -- 2026-11-08 12:00 UTC
local timers = {}
local deliveries = {}

local function addTimer(delay, fn, rep)
    local t = { at = H.now + delay, fn = fn, rep = rep, cancelled = false }
    function t:Cancel() self.cancelled = true end
    function t:IsCancelled() return self.cancelled end
    timers[#timers + 1] = t
    return t
end

local function flushDeliveries()
    while #deliveries > 0 do
        local d = table.remove(deliveries, 1)
        d()
    end
end

function H.advance(seconds, step)
    step = step or 0.1
    local target = H.now + seconds
    while H.now < target - 1e-9 do
        H.now = H.now + step
        H.serverTime = H.serverTime + step
        local i = 1
        while i <= #timers do
            local t = timers[i]
            if t.cancelled then
                table.remove(timers, i)
            elseif t.at <= H.now + 1e-9 then
                if t.rep then t.at = t.at + t.rep else table.remove(timers, i); i = i - 1 end
                t.fn(t)
                flushDeliveries()
            end
            i = i + 1
        end
        flushDeliveries()
    end
end

------------------------------------------------------------------------
-- Generic frame mock
------------------------------------------------------------------------

-- Any unknown field is itself a callable mock, so both `f.text:SetText()`
-- and `f:Whatever()` work.
local mockObject
local mockMT = {}
mockMT.__index = function(t, k)
    local m = mockObject()
    rawset(t, k, m)
    return m
end
mockMT.__call = function() return mockObject() end
mockObject = function()
    local o = { scripts = {}, shown = true, text = "", events = {} }
    setmetatable(o, mockMT)
    o.SetScript = function(self, name, fn) self.scripts[name] = fn end
    o.GetScript = function(self, name) return self.scripts[name] end
    o.HookScript = function(self, name, fn) self.scripts[name] = fn end
    o.RegisterEvent = function(self, e) self.events[e] = true end
    o.Show = function(self) local was = self.shown; self.shown = true; if not was and self.scripts.OnShow then self.scripts.OnShow(self) end end
    o.Hide = function(self) self.shown = false end
    o.IsShown = function(self) return self.shown end
    o.SetShown = function(self, v) if v then self:Show() else self:Hide() end end
    o.SetText = function(self, t) self.text = t end
    o.GetText = function(self) return self.text end
    o.CreateTexture = function() return mockObject() end
    o.CreateFontString = function() return mockObject() end
    o.StartMoving = function() end
    o.StopMovingOrSizing = function() end
    o.ClearFocus = function() end
    o.GetFrameLevel = function() return 1 end
    o.GetWidth = function() return 140 end
    o.GetHeight = function() return 140 end
    o.GetEffectiveScale = function() return 1 end
    o.GetCenter = function() return 0, 0 end
    o.GetChecked = function(self) return self.checked end
    o.SetChecked = function(self, v) self.checked = v end
    o.GetPoint = function() return "CENTER", nil, "CENTER", 0, 0 end
    o.GetStringWidth = function() return 50 end
    o.HasFocus = function() return false end
    o.GetVerticalScroll = function(self) return rawget(self, "vscroll") or 0 end
    o.SetVerticalScroll = function(self, v) self.vscroll = v end
    return o
end
H.mockObject = mockObject

------------------------------------------------------------------------
-- Shared (client-independent) API stubs
------------------------------------------------------------------------

local function strsplit(sep, s, limit)
    local out, start = {}, 1
    while true do
        if limit and #out == limit - 1 then out[#out + 1] = s:sub(start); break end
        local i = s:find(sep, start, true)
        if not i then out[#out + 1] = s:sub(start); break end
        out[#out + 1] = s:sub(start, i - 1)
        start = i + #sep
    end
    return unpack(out)
end

local function band(a, b)
    local r, bitv = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + bitv end
        a, b, bitv = math.floor(a / 2), math.floor(b / 2), bitv * 2
    end
    return r
end

local base = {
    strsplit = strsplit,
    strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
    wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
    tinsert = table.insert,
    bit = { band = band },
    GetTime = function() return H.now end,
    GetServerTime = function() return math.floor(H.serverTime) end,
    time = function() return math.floor(H.serverTime) end,
    date = function(fmt, t) return os.date(fmt, t or math.floor(H.serverTime)) end,
    C_Timer = {
        After = function(d, fn) addTimer(d, fn) end,
        NewTimer = function(d, fn) return addTimer(d, fn) end,
        NewTicker = function(d, fn) return addTimer(d, fn, d) end,
    },
    UNKNOWNOBJECT = "Unknown",
    ACCEPT = "Accept", CANCEL = "Cancel", YES = "Yes", NO = "No",
    SOUNDKIT = { RAID_WARNING = 8959 },
    COMBATLOG_OBJECT_TYPE_PLAYER = 0x400,
    COMBATLOG_HONORGAIN = "%s dies, honorable kill Rank: %s (Estimated Honor Points: %d)",
    COMBATLOG_HONORGAIN_NO_RANK = "%s dies, honorable kill (Estimated Honor Points: %d)",
    ChatTypeInfo = { RAID_WARNING = { r = 1, g = 0.3, b = 0 } },
    RAID_CLASS_COLORS = { ROGUE = { r = 1, g = 0.96, b = 0.41 }, WARRIOR = { r = 0.78, g = 0.61, b = 0.43 } },
    GetRealmName = function() return "Forever" end,
    GetNormalizedRealmName = function() return "Forever" end,
    GetRealZoneText = function() return "Stranglethorn Vale" end,
    GetSubZoneText = function() return "Booty Bay" end,
    PlaySound = function() end,
    RaidWarningFrame = mockObject(),
    UIParent = mockObject(),
    UISpecialFrames = {},
    IsInRaid = function() return false end,
    UnitIsGroupLeader = function() return false end,
    UnitIsGroupAssistant = function() return false end,
    CanBeRaidTarget = function() return true end,
    IsResting = function() return H.resting end,
    IsInGroup = function() return H.inGroup end,
    IsInInstance = function() return H.inInstance, H.inInstance and "pvp" or "none" end,
    UnitInParty = function(name) return H.party[name] or false end,
    UnitInRaid = function() return nil end,
    IsShiftKeyDown = function() return false end,
    InCombatLockdown = function() return H.combat end,
    GetCursorPosition = function() return 0, 0 end,
    Minimap = mockObject(),
    TargetFrame = mockObject(),
    pairs = pairs, ipairs = ipairs, next = next, select = select, type = type, tostring = tostring,
    tonumber = tonumber, pcall = pcall, xpcall = xpcall, unpack = unpack, setmetatable = setmetatable, error = error,
    string = string, table = table, math = math, print = print,
}

------------------------------------------------------------------------
-- Guild model & message bus
------------------------------------------------------------------------

H.clients = {}
H.guild = { name = "Gankbusters", info = "" }
H.sent = {} -- log of every addon message: {from=, msg=}
H.throttleEvery = nil -- simulate throttling every Nth send
H.party = {}

local sendCount = 0

local function rosterList()
    local list = {}
    for _, c in ipairs(H.clients) do
        if c.inGuild then list[#list + 1] = c end
    end
    return list
end

function H.newClient(name, opts)
    opts = opts or {}
    local c = { guildInfoLate = opts.guildInfoLate, name = name, rank = opts.rank or 5, inGuild = opts.inGuild ~= false, online = true, chat = {}, raidWarnings = {} }
    c.units = {} -- unit token -> { name=, realm=, guid=, class=, player=true }
    c.db = opts.db
    c.version = opts.version

    local env = setmetatable({}, { __index = base })
    env._G = env
    c.env = env

    env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) c.chat[#c.chat + 1] = msg end }
    env.RaidNotice_AddMessage = function(_, msg) c.raidWarnings[#c.raidWarnings + 1] = msg end
    env.StaticPopupDialogs = {}
    env.StaticPopup_Show = function(which, a1, a2, data) c.lastPopup = { which = which, a1 = a1, data = data } end
    env.SlashCmdList = {}
    env.UtuDB = c.db
    env.CreateFrame = function() return mockObject() end
    env.GameTooltip = mockObject()

    env.IsInGuild = function() return c.inGuild end
    env.GetGuildInfo = function(unit)
        if unit == "player" then
            if c.inGuild and not c.guildInfoLate then return H.guild.name, "Rank" .. c.rank, c.rank, nil end
            return nil
        end
        local u = c.units[unit]
        if u and u.guild then return u.guild, "Member", 5 end
    end
    env.UnitIsInMyGuild = function(unit) local u = c.units[unit]; return u and u.guild == H.guild.name end
    env.SendChatMessage = function(msg, ch) c.said = c.said or {}; c.said[#c.said + 1] = { msg = msg, ch = ch } end
    env.GetGuildInfoText = function() return H.guild.info end
    env.SetGuildInfoText = function(t) H.guild.info = t end
    env.CanEditGuildInfo = function() return c.inGuild and c.rank <= 1 end
    env.GetRealZoneText = function() return c.zone or "Stranglethorn Vale" end
    -- map position: c.map (default 1434), c.x / c.y normalised; a zone is 3000 yards across
    env.CreateVector2D = function(x, y) return { GetXY = function() return x, y end } end
    env.C_Map = {
        GetBestMapForUnit = function() return c.map or 1434 end,
        GetPlayerMapPosition = function() return env.CreateVector2D(c.x or 0.5, c.y or 0.5) end,
        GetWorldPosFromMapPos = function(map, pos)
            local x, y = pos:GetXY()
            return 0, env.CreateVector2D(x * 3000, y * 3000)
        end,
    }
    env.GetSubZoneText = function() return c.subzone or "Booty Bay" end
    env.GetNumGuildMembers = function() return #rosterList() end
    env.GetGuildRosterInfo = function(i)
        local m = rosterList()[i]
        return m.name .. "-Forever", "Rank" .. m.rank, m.rank
    end
    env.C_GuildInfo = { GuildRoster = function() end }

    env.UnitName = function(unit)
        if unit == "player" then
            -- Forever splits two-word names, the player's own included
            if H.forever and c.name:find(" ", 1, true) then
                local first, rest = c.name:match("^(%S+) (.+)$")
                if opts.firstNameOnly then return first end
                return first, rest
            end
            return c.name
        end
        local u = c.units[unit]
        if u then return u.name, u.realm end
    end
    env.UnitGUID = function(unit)
        if unit == "player" then return "Player-1-" .. c.name end
        local u = c.units[unit]; return u and u.guid
    end
    env.UnitClass = function(unit) local u = c.units[unit]; if u then return u.class, u.class end end
    env.UnitIsPlayer = function(unit) return unit == "player" or (c.units[unit] ~= nil) end
    env.UnitIsUnit = function(a, b)
        -- "<unit>target" == "player": does that unit target me?
        local base = a:match("^(.+)target$")
        if base and b == "player" then local u = c.units[base]; return u ~= nil and u.targeting == "player" end
        return a == b
    end
    env.UnitExists = function(unit) return unit == "player" or c.units[unit] ~= nil end
    env.UnitFactionGroup = function(unit)
        if unit == "player" then return "Alliance" end
        local u = c.units[unit]
        if u then return u.faction or "Horde" end
    end
    env.UnitHealth = function(unit) if unit == "player" then return c.health or 100 end end
    env.GetBuildInfo = function() return "1.60.1", "70862", "Nov 1 2026", 16001 end
    env.GetAddOnMetadata = function(_, field) if field == "Version" then return c.version or "9.9.9" end end
    env.UnitLevel = function(unit)
        if unit == "player" then return c.level or 60 end
        local u = c.units[unit]
        return u and u.level or 60
    end
    env.GetRaidTargetIndex = function(unit) return c.marks and c.marks[unit] end
    env.SetRaidTarget = function(unit, i) c.marks = c.marks or {}; c.marks[unit] = i end
    env.C_NamePlate = { GetNamePlateForUnit = function(unit) if c.units[unit] then return c.plates[unit] end end }
    c.plates = setmetatable({}, { __index = function(t, k) local p = mockObject(); rawset(t, k, p); return p end })
    if H.forever then
        env.issecretvalue = function(v) return type(v) == "table" and v.__secret == true end
        env.C_DeathRecap = { GetRecapEvents = function() return c.recap end }
    else
        env.CombatLogGetCurrentEventInfo = function() return unpack(c.cleu or {}) end
    end

    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function(p) c.prefix = p end,
        SendAddonMessage = function(prefix, msg, channel)
            assert(#msg <= 255, "addon message too long: " .. #msg)
            assert(channel == "GUILD")
            sendCount = sendCount + 1
            if H.throttleEvery and sendCount % H.throttleEvery == 0 then return 3 end -- AddonMessageThrottle
            H.sent[#H.sent + 1] = { from = c.name, msg = msg }
            -- the game echoes guild addon messages back to the sender too
            for _, other in ipairs(H.clients) do
                if other.online and other.inGuild then
                    deliveries[#deliveries + 1] = function()
                        H.fire(other, "CHAT_MSG_ADDON", prefix, msg, "GUILD", c.name .. "-Forever")
                    end
                end
            end
            return 0
        end,
    }

    -- Embedded libraries (the real ones need game frames), stubbed:
    -- ChatThrottleLib sends straight away and retries throttled sends, like
    -- the real one; LibDataBroker/LibDBIcon record what the addon asks for.
    c.ctl = {}
    env.ChatThrottleLib = { version = 99 }
    function env.ChatThrottleLib:SendAddonMessage(prio, prefix, text, chattype, target, queueName, cb, arg)
        assert(prio == "BULK" or prio == "NORMAL" or prio == "ALERT", "bad priority " .. tostring(prio))
        c.ctl[#c.ctl + 1] = { prio = prio, msg = text }
        local function try()
            local r = env.C_ChatInfo.SendAddonMessage(prefix, text, chattype, target)
            if r == 3 then env.C_Timer.After(0.5, try); return end
            if cb then cb(arg, r == 0, r) end
        end
        try()
    end
    c.minimap = { objects = {}, shown = {} }
    local libs = {
        ["LibDataBroker-1.1"] = { NewDataObject = function(_, name, obj) c.minimap.objects[name] = obj; return obj end },
        ["LibDBIcon-1.0"] = {
            Register = function(_, name, obj, db) c.minimap.db = db; c.minimap.registered = name end,
            Show = function(_, name) c.minimap.shown[name] = true end,
            Hide = function(_, name) c.minimap.shown[name] = false end,
        },
    }
    env.LibStub = setmetatable({}, { __call = function(_, name, silent)
        if not libs[name] and not silent then error("no library " .. name) end
        return libs[name]
    end })

    local ns = {}
    for _, f in ipairs(FILES) do
        local chunk = assert(loadfile(ADDON_DIR .. f))
        setfenv(chunk, env)
        chunk("Utu", ns)
    end
    c.KOS = ns.KOS
    c.Sync = ns.Sync
    H.clients[#H.clients + 1] = c

    H.fire(c, "ADDON_LOADED", "Utu")
    H.fire(c, "PLAYER_LOGIN")
    H.fire(c, "PLAYER_ENTERING_WORLD", true, false)
    -- the server pushes roster updates to everyone when a member logs in
    for _, other in ipairs(H.clients) do H.fire(other, "GUILD_ROSTER_UPDATE") end
    c.db = env.UtuDB
    return c
end

function H.fire(c, event, ...)
    local f = c.KOS.frame
    if not c.online then return end
    f.scripts.OnEvent(f, event, ...)
end

function H.slash(c, msg) c.env.SlashCmdList.UTU(msg) end

function H.logout(c) c.online = false end

-- A client logs back in: fresh Lua state, same SavedVariables.
function H.relogin(c)
    for i, x in ipairs(H.clients) do if x == c then table.remove(H.clients, i) break end end
    return H.newClient(c.name, { rank = c.rank, db = c.env.UtuDB, version = c.version })
end

function H.chatContains(c, needle)
    for _, l in ipairs(c.chat) do if l:find(needle, 1, true) then return true end end
    return false
end

function H.reset()
    H.clients = {}
    H.sent = {}
    timers = {}
    deliveries = {}
    H.guild.info = ""
    H.throttleEvery = nil
    H.resting, H.inGroup, H.inInstance = false, false, false
    H.party = {}
    H.combat = false
    H.forever = false
    H.now = 1000
    H.serverTime = 1794096000 + 12 * 3600
end

return H
