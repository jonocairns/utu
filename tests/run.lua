package.path = (arg[0]:match("^(.*)/") or ".") .. "/?.lua;" .. package.path
local H = require("harness")

local passed, failed = 0, 0
local only = arg[1]
local function test(name, fn)
    if only and not name:find(only, 1, true) then return end
    H.reset()
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print("PASS  " .. name)
    else failed = failed + 1; print("FAIL  " .. name .. "\n      " .. tostring(err)) end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function allSame()
    local first
    for _, c in ipairs(H.clients) do
        if c.online then
            local d = c.KOS:Digest()
            if first and d ~= first then return false end
            first = d
        end
    end
    return true
end
local function countSent(tag)
    local n = 0
    for _, s in ipairs(H.sent) do if s.msg:sub(1, 1) == tag then n = n + 1 end end
    return n
end
local function active(c)
    local n = 0
    for _, T in pairs(c.KOS:Targets()) do if T.w > 0 then n = n + 1 end end
    return n
end
local function T_(c, name) return c.KOS:GetTarget(c.KOS:Canonical(name)) end
local function weight(c, name) local T = T_(c, name); return T and T.w or 0 end
local function level(c, name) local T = T_(c, name); return T and c.KOS:LevelOf(T) or 0 end
local function points(c, name) return (c.KOS:PointsOf(name .. "-Forever")) end
local function killEvent(c, victim, guid)
    c.cleu = { 0, "PARTY_KILL", false, "Player-1-" .. c.name, c.name, 0x511, 0, guid or ("Player-1-" .. victim), victim, 0x548 }
    H.fire(c, "COMBAT_LOG_EVENT_UNFILTERED")
end
local function hit(c, attacker, guid)
    c.cleu = { 0, "SWING_DAMAGE", false, guid or ("Player-1-" .. attacker), attacker, 0x548, 0, "Player-1-" .. c.name, c.name, 0x511 }
    H.fire(c, "COMBAT_LOG_EVENT_UNFILTERED")
end
local function dieTo(c, killer, guid)
    hit(c, killer, guid)
    H.fire(c, "PLAYER_DEAD")
end
local function jumpDays(days)
    H.serverTime = H.serverTime + days * 86400
    H.advance(31, 1) -- let score caches expire
    for _, c in ipairs(H.clients) do if c.online then c.KOS:RecalcAll(); c.KOS:InvalidateGuildStats() end end
end
-- leave the zone and come back: a new zone visit
local function revisit(c)
    c.zone = "Duskwood"
    H.fire(c, "ZONE_CHANGED_NEW_AREA")
    c.zone = nil
    H.fire(c, "ZONE_CHANGED_NEW_AREA")
end
local function feedHas(c, needle)
    for _, e in ipairs(c.KOS:Activity()) do if e.text:find(needle, 1, true) then return true end end
    return false
end

------------------------------------------------------------------------
-- Basics & ladders
------------------------------------------------------------------------

test("name canonicalisation", function()
    local K = H.newClient("Alice").KOS
    local key, full = K:Canonical("gankdude")
    eq(key, "gankdude-forever"); eq(full, "Gankdude-Forever")
    key, full = K:Canonical("BOB-Other Realm")
    eq(key, "bob-otherrealm"); eq(full, "Bob-OtherRealm")
    key, full = K:Canonical("  Mietta   Grace ")
    eq(key, "mietta grace-forever"); eq(full, "Mietta Grace-Forever") -- Forever allows spaces
    eq(K:Canonical("kind eyes"), "kind eyes-forever")
    eq(select(2, K:Canonical("kind eyes")), "Kind Eyes-Forever", "each word capitalised, like the game does")
    eq(select(2, K:Canonical("MIETTA grace")), "Mietta Grace-Forever")
    eq(K:Canonical("Ab.cd"), nil)
    eq(K:Canonical("x1"), nil)
    eq(K:Display("Gankdude-Forever"), "Gankdude")
end)

test("utf8-safe truncation and note cleaning", function()
    local K = H.newClient("Alice").KOS
    eq(K.Utf8Truncate("h\195\169llo", 2), "h")
    eq(K.CleanText("  |cffff0000red|r\tx\n "), "cffff0000redr x")
end)

test("level ladders are continuous", function()
    local K = H.newClient("Alice").KOS
    eq(K.BountyLevel(0), 0); eq(K.BountyLevel(19.9), 0); eq(K.BountyLevel(20), 1)
    for L = 1, 80 do eq(K.BountyLevel(K.ScoreForLevel(L)), L, "bounty L" .. L) end
    eq(K.BountyBand(0).name, "Dormant"); eq(K.BountyBand(8).name, "Wanted"); eq(K.BountyBand(40).name, "Legendary")
    eq(K.PayoutForLevel(0), 0); eq(K.PayoutForLevel(10), 35)
    eq(K.HunterRank(0).name, "Recruit")
    eq(K.HunterRank(10).name, "Tracker I")
    eq(K.HunterRank(K.PointsForHunterLevel(6)).name, "Scout I")
    eq(K.HunterRank(K.PointsForHunterLevel(30)).name, "Revenger V")
    eq(K.HunterRank(K.PointsForHunterLevel(51)).name, "Legend 1")
    for L = 1, 60 do eq(K.HunterLevel(K.PointsForHunterLevel(L)), L, "hunter L" .. L) end
    local r = K.HunterRank(100)
    assert(r.progress >= 0 and r.progress <= 1)
end)

------------------------------------------------------------------------
-- Marks, decay, sync
------------------------------------------------------------------------

test("marks from distinct guildies raise the bounty level", function()
    local a, b, c = H.newClient("Alice"), H.newClient("Bob"), H.newClient("Carol")
    H.advance(20)
    H.slash(a, "add gankdude camped BRD")
    H.advance(2)
    eq(weight(b, "Gankdude"), 1)
    eq(level(b, "Gankdude"), 2, "one mark = Lv 2")
    H.slash(b, "add Gankdude also ganked me")
    H.slash(a, "add Gankdude updated note")
    H.advance(2)
    eq(weight(c, "Gankdude"), 2)
    eq(level(c, "Gankdude"), 4, "two marks = Lv 4")
    H.slash(b, "rm Gankdude")
    H.advance(2)
    eq(level(c, "Gankdude"), 2)
    assert(allSame())
end)

test("decay: bounties cool off, old marks expire, re-marking refreshes", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    a.KOS:Mark("Gankdude", "x")
    b.KOS:Mark("Gankdude", "y")
    H.advance(2)
    eq(level(a, "Gankdude"), 4)
    jumpDays(14)
    eq(level(a, "Gankdude"), 2, "halved after 14 days")
    jumpDays(33)
    eq(level(a, "Gankdude"), 0, "dormant after ~7 weeks")
    eq(weight(a, "Gankdude"), 2, "still listed")
    b.KOS:Mark("Gankdude", "he's back") -- refresh
    H.advance(2)
    eq(level(a, "Gankdude"), 3, "Bob's refreshed mark counts in full again")
    jumpDays(50) -- Alice's mark is now 94 days old (> 4 half-lives)
    eq(weight(a, "Gankdude"), 1, "Alice's old mark expired")
    eq(a.KOS:MyVote(T_(a, "Gankdude")), nil)
end)

test("offline member catches up and shares their own marks", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    local c = H.newClient("Carol")
    H.advance(20)
    H.logout(c)
    H.slash(a, "add Gankdude ganker")
    H.slash(b, "add Gankdude yep")
    H.slash(b, "add Rogueguy stunlocks lowbies")
    H.advance(2)
    local T = c.KOS:GetTarget("sneaky-forever", "Sneaky-Forever", true)
    T.votes["carol-forever"] = { by = "Carol-Forever", note = "only Carol knew", t = math.floor(H.serverTime) }
    c.KOS:Recalc(T)
    H.sent = {}
    c = H.relogin(c)
    H.advance(90)
    eq(active(a), 3); eq(active(c), 3)
    assert(a.KOS:Lookup("sneaky-forever"), "Carol's mark reached Alice")
    assert(allSame(), "converged")
end)

test("pardon clears every mark; stale copies don't resurrect", function()
    local a, b, off = H.newClient("Alice"), H.newClient("Bob"), H.newClient("Officer", { rank = 1 })
    H.advance(20)
    H.slash(a, "add Gankdude x")
    H.slash(b, "add Gankdude y")
    H.advance(2)
    H.logout(b)
    H.slash(off, "pardon Gankdude")
    H.advance(2)
    eq(weight(a, "Gankdude"), 0)
    b = H.relogin(b)
    H.advance(90)
    eq(weight(b, "Gankdude"), 0)
    H.slash(b, "add Gankdude he's back")
    H.advance(2)
    eq(weight(a, "Gankdude"), 1, "new mark after the pardon counts")
    assert(allSame())
end)

test("permissions: addrank, pardon rank, forged live and dump messages", function()
    H.guild.info = "Raid nights Tue/Thu\nKOS:addrank=3"
    local gm = H.newClient("Boss", { rank = 0 })
    local member = H.newClient("Member", { rank = 3 })
    local pleb = H.newClient("Pleb", { rank = 4 })
    H.advance(20)
    H.slash(pleb, "add Gankdude nope")
    eq(weight(pleb, "Gankdude"), 0)
    H.slash(member, "add Gankdude ok")
    H.advance(2)
    eq(weight(gm, "Gankdude"), 1)
    H.slash(member, "pardon Gankdude")
    assert(H.chatContains(member, "can pardon"))
    pleb.Sync:BroadcastClear({ n = "Gankdude-Forever" }, { by = "Pleb-Forever", t = H.serverTime + 100 })
    H.advance(2)
    eq(weight(gm, "Gankdude"), 1, "forged live pardon ignored")
    local send = pleb.env.C_ChatInfo.SendAddonMessage
    send("KOS2", "D\tc\tGankdude-Forever\tPleb-Forever\t" .. (math.floor(H.serverTime) + 200), "GUILD")
    send("KOS2", "D\ts\tPleb-Forever\t" .. (math.floor(H.serverTime) + 200), "GUILD")
    H.advance(2)
    eq(weight(gm, "Gankdude"), 1, "forged dump pardon ignored")
    eq(gm.KOS:List().season, nil, "forged dump season ignored")
end)

test("officer messages that arrive before the roster loads are retried", function()
    local a, off = H.newClient("Alice"), H.newClient("Officer", { rank = 1 })
    H.advance(20)
    a.KOS:Mark("Gankdude", "x")
    H.advance(2)
    a.KOS.roster = {}
    H.slash(off, "pardon Gankdude")
    H.advance(2)
    eq(weight(a, "Gankdude"), 1, "held")
    H.fire(a, "GUILD_ROSTER_UPDATE")
    eq(weight(a, "Gankdude"), 0, "applied once the roster arrives")
end)

------------------------------------------------------------------------
-- Detection & alerts
------------------------------------------------------------------------

test("nameplate detection: one alert per zone visit, guild noted", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    a.KOS:Mark("Gankdude", "ganker")
    b.KOS:Mark("Gankdude", "")
    H.advance(2)
    a.units.nameplate3 = { name = "Gankdude", guid = "Player-1-0001", class = "ROGUE", guild = "Gankers", level = 60 }
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate3")
    H.advance(2)
    eq(#a.raidWarnings, 1)
    assert(a.raidWarnings[1]:find("MARKED LV 4"), a.raidWarnings[1])
    eq(b.KOS:Lookup("gankdude-forever").guild, "Gankers", "guild synced")
    assert(feedHas(b, "spotted"), "Bob's feed has the sighting")
    for _ = 1, 10 do
        H.advance(30)
        H.fire(a, "NAME_PLATE_UNIT_REMOVED", "nameplate3")
        H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate3")
    end
    eq(#a.raidWarnings, 1, "no repeats while he hangs around")
    H.advance(3600)
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate3")
    eq(#a.raidWarnings, 1, "not even an hour later in the same zone")
    a.units.target = { name = "Gankdude", guid = "Player-1-0001" }
    H.fire(a, "PLAYER_TARGET_CHANGED")
    eq(#a.raidWarnings, 1, "or when you target him")
    H.fire(a, "ZONE_CHANGED_NEW_AREA")
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate3")
    eq(#a.raidWarnings, 1, "a subzone change isn't a new visit")
    revisit(a)
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate3")
    eq(#a.raidWarnings, 2, "alerts again on your next visit")
end)

test("marking the player you're targeting doesn't then alert you about them", function()
    local a = H.newClient("Alice")
    H.advance(20)
    a.units.target = { name = "Gankdude", guid = "Player-1-0001", class = "ROGUE" }
    H.fire(a, "PLAYER_TARGET_CHANGED")
    H.slash(a, "target camps the flight path")
    eq(active(a), 1)
    a.units.nameplate1 = a.units.target
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.fire(a, "PLAYER_TARGET_CHANGED")
    eq(#a.raidWarnings, 0, "you already know he's there")
    -- marked by name while he's elsewhere: alerts when he shows up
    a.KOS:Mark("Otherguy", "")
    a.units.nameplate2 = { name = "Otherguy", guid = "Player-1-0002" }
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate2")
    eq(#a.raidWarnings, 1)
    revisit(a)
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    eq(#a.raidWarnings, 2, "and the targeted one alerts on your next visit")
end)

test("once-per-visit alerts still share sightings, and quiet places don't use up the warning", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    a.KOS:Mark("Gankdude", "")
    b.KOS:Mark("Gankdude", "")
    H.advance(5)
    local function sights() return countSent("W") end
    local s0 = sights()
    a.units.nameplate1 = { name = "Gankdude", guid = "Player-1-0001" }
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.advance(2)
    eq(#a.raidWarnings, 1)
    eq(sights() - s0, 1, "first sighting shared")
    -- gone 400s, back in the same zone: no banner, but guildies hear again
    H.advance(400)
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.advance(2)
    eq(#a.raidWarnings, 1, "no second banner this visit")
    eq(sights() - s0, 2, "sighting shared again after a gap")
    -- hanging around doesn't re-share
    H.advance(30)
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.advance(2)
    eq(sights() - s0, 2)
    -- seen while resting (quiet): shared, but the warning is still owed
    revisit(a)
    H.resting = true
    H.slash(a, "set quietResting on")
    H.advance(400)
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.advance(2)
    eq(#a.raidWarnings, 1, "quiet while resting")
    eq(sights() - s0, 3, "still shared")
    H.resting = false
    H.advance(5)
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    eq(#a.raidWarnings, 2, "warned once you leave the rested area")
end)

test("zone visits: empty or late zone names don't miss or double the reset", function()
    local a = H.newClient("Alice")
    H.advance(20)
    a.KOS:Mark("Gankdude", "")
    a.units.nameplate1 = { name = "Gankdude", guid = "Player-1-0001" }
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    eq(#a.raidWarnings, 1)
    -- the zone name is briefly empty, then the same zone again: same visit
    a.zone = ""
    H.fire(a, "ZONE_CHANGED_NEW_AREA")
    a.zone = nil
    H.advance(2)
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    eq(#a.raidWarnings, 1, "not a new visit")
    -- the event fires before the name updates: picked up a second later
    H.fire(a, "ZONE_CHANGED_NEW_AREA")
    a.zone = "Duskwood"
    H.advance(2)
    a.zone = nil
    H.fire(a, "ZONE_CHANGED_NEW_AREA")
    H.advance(2)
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    eq(#a.raidWarnings, 2, "the late zone change still started a new visit")
    -- a loading screen always starts one
    H.fire(a, "PLAYER_ENTERING_WORLD", false, false)
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    eq(#a.raidWarnings, 3)
end)

test("marking a renamed player from their list entry while targeting them doesn't alert", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    b.KOS:Mark("Oldname", "", "Player-1-0009", "ROGUE")
    H.advance(5)
    a.units.target = { name = "Newname", guid = "Player-1-0009" }
    H.fire(a, "PLAYER_TARGET_CHANGED")
    eq(#a.raidWarnings, 0, "below Alice's threshold")
    a.KOS:Mark("Oldname", "")
    H.fire(a, "PLAYER_TARGET_CHANGED")
    eq(#a.raidWarnings, 0, "you already know he's there")
end)

test("a crowd of KoS players collapses into one summary banner", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    for i = 1, 8 do
        a.KOS:Mark("Raider" .. string.char(96 + i), "")
        b.KOS:Mark("Raider" .. string.char(96 + i), "")
    end
    H.advance(2)
    for i = 1, 8 do
        a.units["nameplate" .. i] = { name = "Raider" .. string.char(96 + i), guid = "Player-1-R" .. i }
        H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate" .. i)
    end
    H.advance(3)
    eq(#a.raidWarnings, 4, "3 individual banners + 1 summary")
    assert(a.raidWarnings[4]:find("5 KoS players nearby"), a.raidWarnings[4])
end)

test("combat log detection + rename caught by GUID", function()
    local a = H.newClient("Alice")
    H.advance(20)
    a.KOS:Mark("Gankdude", "ganker", "Player-1-0001", "ROGUE")
    a.cleu = { 0, "SPELL_DAMAGE", false, "Player-1-0001", "Newname", 0x548, 0, "Player-1-0002", "Zed", 0x548 }
    H.fire(a, "COMBAT_LOG_EVENT_UNFILTERED")
    eq(#a.raidWarnings, 1)
    assert(a.raidWarnings[1]:find("now Newname"), a.raidWarnings[1])
end)

test("personal alert settings: min level, my own marks, sources, quiet places", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    b.KOS:Mark("Gankdude", "")
    H.advance(2)
    a.units.target = { name = "Gankdude", guid = "Player-1-1" }
    H.fire(a, "PLAYER_TARGET_CHANGED")
    eq(#a.raidWarnings, 0, "Lv 2 from someone else stays quiet (min Lv 3)")
    b.units.target = { name = "Gankdude", guid = "Player-1-1" }
    H.fire(b, "PLAYER_TARGET_CHANGED")
    eq(#b.raidWarnings, 1, "but Bob's own grudge always alerts him")
    H.slash(a, "set minLevel 1")
    revisit(a)
    H.slash(a, "set srcTarget off")
    H.fire(a, "PLAYER_TARGET_CHANGED")
    eq(#a.raidWarnings, 0, "targeting source disabled")
    H.slash(a, "set srcTarget on")
    H.resting = true
    H.slash(a, "set quietResting on")
    revisit(a)
    H.fire(a, "PLAYER_TARGET_CHANGED")
    eq(#a.raidWarnings, 0, "quiet while resting")
    H.resting = false
    H.inInstance = true
    revisit(a)
    H.fire(a, "PLAYER_TARGET_CHANGED")
    eq(#a.raidWarnings, 0, "quiet in battlegrounds by default")
end)

test("visible party/guild chat posts are opt-in and rate-limited", function()
    local a = H.newClient("Alice")
    H.advance(20)
    a.KOS:Mark("Gankdude", "camper")
    a.KOS:Mark("Otherguy", "")
    a.units.target = { name = "Gankdude", guid = "Player-1-1" }
    H.fire(a, "PLAYER_TARGET_CHANGED")
    eq(a.said, nil, "off by default")
    H.slash(a, "set guildChat on")
    revisit(a)
    H.fire(a, "PLAYER_TARGET_CHANGED")
    eq(#a.said, 1)
    assert(a.said[1].msg:find("%[KoS%] Gankdude"), a.said[1].msg)
    a.units.target = { name = "Otherguy", guid = "Player-1-2" }
    H.fire(a, "PLAYER_TARGET_CHANGED")
    eq(#a.said, 1, "20s global limit")
end)

------------------------------------------------------------------------
-- Bounty game
------------------------------------------------------------------------

test("kill payouts: 5 + 3 x level, top bounty and first blood, bounty drains", function()
    local a, b, c = H.newClient("Alice"), H.newClient("Bob"), H.newClient("Carol")
    H.advance(20)
    a.KOS:Mark("Gankdude", ""); b.KOS:Mark("Gankdude", ""); c.KOS:Mark("Gankdude", "")
    H.advance(2)
    killEvent(a, "Gankdude")
    H.advance(2)
    eq(points(a, "Alice"), 34, "Lv 4 without Alice's own mark = 17, +50% top, +50% first blood")
    eq(points(b, "Alice"), 34, "leaderboard synced")
    H.advance(10); killEvent(a, "Gankdude")
    H.advance(10); killEvent(a, "Gankdude")
    H.advance(2)
    eq(points(c, "Alice"), 34 + 21 + 17, "every kill counts, but each one drains the bounty")
    eq(#a.KOS:Claims("Alice"), 3)
    for _, cl in ipairs(a.KOS:Claims("Alice")) do eq(#cl.flags, 0, "legit claims aren't flagged") end
end)

test("anti-farm: own mark pays nothing, low-level targets slide to nothing, own deaths excluded", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    a.KOS:Mark("Myalt", "")
    killEvent(a, "Myalt")
    eq(points(a, "Alice"), 0)
    assert(H.chatContains(a, "only your own mark"))
    b.KOS:Mark("Lowbie", ""); b.KOS:Mark("Midbie", "")
    H.advance(2)
    a.units.nameplate1 = { name = "Lowbie", guid = "Player-1-Lowbie", level = 20 }
    a.units.nameplate2 = { name = "Midbie", guid = "Player-1-Midbie", level = 54 }
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate2")
    killEvent(a, "Lowbie")
    eq(points(a, "Alice"), 0, "40 levels below: nothing")
    assert(H.chatContains(a, "too low level"))
    killEvent(a, "Midbie")
    eq(points(a, "Alice"), 14, "6 levels below: two thirds of 11 = 7, then +50% top +50% first blood")
    for _ = 1, 3 do dieTo(b, "Friendalt"); H.advance(31) end
    local T = T_(b, "Friendalt")
    eq(b.KOS:BountyValue(T, b.KOS:MyKey()), 0, "Bob's own deaths don't pay Bob")
    assert(a.KOS:BountyValue(T_(a, "Friendalt"), a.KOS:MyKey()) > 0, "but they do pay Alice")
end)

test("auto-mark on death, gank evidence, revenge, hunter ranks", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    local c = H.newClient("Carol")
    H.advance(20)
    b.KOS:Mark("Gankdude", "")
    H.advance(2)
    dieTo(c, "Gankdude")
    H.advance(2)
    eq(weight(a, "Gankdude"), 2, "Carol auto-marked her killer")
    eq(level(a, "Gankdude"), 6, "2 marks + 1 gank = 300 = Lv 6")
    assert(feedHas(a, "was killed by"), "gank in Alice's feed")
    killEvent(a, "Gankdude")
    H.advance(2)
    eq(points(b, "Alice"), 58, "base 23, +50% top, revenge, first blood")
    assert(H.chatContains(c, "avenging you"), "Carol is told (about-me events always show)")
    local _, row = b.KOS:PointsOf("Alice-Forever")
    eq(row.revenges, 1)
    assert(H.chatContains(a, "Rank up"))
    H.advance(10)
    killEvent(a, "Gankdude")
    H.advance(2)
    eq(points(b, "Alice"), 58 + 30, "second kill: drained, no revenge or first blood")
    local before = T_(c, "Gankdude").votes["carol-forever"].t
    H.advance(40)
    dieTo(c, "Gankdude")
    assert(T_(c, "Gankdude").votes["carol-forever"].t > before, "being killed again refreshes the mark")
end)

test("call for help + rescue bonus; help calls are deduplicated and zone-aware", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    local c = H.newClient("Carol")
    local d = H.newClient("Dave")
    d.zone, d.map = "Duskwood", 1431
    H.advance(20)
    b.KOS:Mark("Gankdude", "")
    H.advance(2)
    hit(c, "Gankdude")
    H.advance(1)
    hit(b, "Gankdude")
    H.advance(2)
    local helps = 0
    for _, w in ipairs(a.raidWarnings) do if w:find("HELP!") then helps = helps + 1 end end
    eq(helps, 1, "one banner for one attacker")
    for _, w in ipairs(d.raidWarnings) do assert(not w:find("HELP!"), "no banner for another zone") end
    assert(feedHas(d, "HELP!"), "but it's in Dave's feed")
    killEvent(a, "Gankdude")
    H.advance(2)
    eq(points(b, "Alice"), 28, "base 11, +50% top, rescue, first blood")
    local _, row = b.KOS:PointsOf("Alice-Forever")
    eq(row.rescues, 1)
end)

test("help calls are distance-gated within the zone; On my way + responder assist", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    local c, e = H.newClient("Carol"), H.newClient("Eve")
    -- Carol at (0.50, 0.50); Alice 120 yd away; Bob 300 yd; Eve ~1700 yd, same zone
    c.x, c.y = 0.50, 0.50
    a.x, a.y = 0.54, 0.50
    b.x, b.y = 0.50, 0.40
    e.x, e.y = 0.90, 0.90
    H.advance(20)
    b.KOS:Mark("Gankdude", ""); e.KOS:Mark("Gankdude", "")
    H.advance(2)
    hit(c, "Gankdude")
    H.advance(2)
    local function helpBanner(cl)
        for _, w in ipairs(cl.raidWarnings) do if w:find("HELP!") then return w end end
    end
    local w = helpBanner(a)
    assert(w and w:find("120 yd W"), "Alice gets distance and direction: " .. tostring(w))
    assert(helpBanner(b), "Bob (300 yd) is within the default 400")
    eq(helpBanner(e), nil, "Eve is too far away for a banner")
    assert(feedHas(e, "HELP!"), "but it's in her feed")
    a.KOS:Respond("Gankdude-Forever")
    e.KOS:Respond("Gankdude-Forever")
    H.advance(2)
    assert(H.chatContains(c, "Alice is on the way"), "Carol knows help is coming")
    killEvent(b, "Gankdude")
    H.advance(7) -- the assist waits a moment in case the game credits a full kill
    local _, row = c.KOS:PointsOf("Alice-Forever")
    assert(row and row.assists == 1 and row.points > 0, "Alice made it (120 yd): assist")
    eq(points(c, "Eve"), 0, "Eve was still 1700 yd away: no assist")
end)

test("zone threat warning on entering a zone with recent KoS activity", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    local c = H.newClient("Carol")
    a.zone, a.map = "Duskwood", 1431
    H.advance(20)
    b.KOS:Mark("Gankdude", "")
    H.advance(2)
    dieTo(c, "Gankdude")
    H.advance(2)
    b.units.nameplate1 = { name = "Gankdude", guid = "Player-1-Gankdude" }
    H.fire(b, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.advance(2)
    H.fire(a, "ZONE_CHANGED_NEW_AREA")
    H.advance(3)
    assert(not H.chatContains(a, "threat"), "Duskwood is clear: no warning")
    a.zone, a.map = "Stranglethorn Vale", 1434
    H.fire(a, "ZONE_CHANGED_NEW_AREA")
    H.advance(3)
    assert(H.chatContains(a, "Stranglethorn Vale: High threat"), "warned on entry")
    assert(H.chatContains(a, "Gankdude Lv"), "names the KoS player")
    local before = #a.chat
    a.zone = "Duskwood"; H.fire(a, "ZONE_CHANGED_NEW_AREA"); H.advance(3)
    a.zone = "Stranglethorn Vale"; H.fire(a, "ZONE_CHANGED_NEW_AREA"); H.advance(3)
    eq(#a.chat, before, "no repeat within 10 minutes")
    jumpDays(1)
    eq(a.KOS:ZoneThreat("Stranglethorn Vale").level, 0, "activity older than 30 minutes doesn't count")
end)

test("defending a lowbie from an unmarked bully pays and marks them", function()
    local a, c = H.newClient("Alice"), H.newClient("Carol")
    c.level = 20
    H.advance(20)
    c.units.nameplate1 = { name = "Bully", guid = "Player-1-Bully", level = 60 }
    H.fire(c, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    hit(c, "Bully", "Player-1-Bully")
    H.advance(2)
    assert(a.KOS:RescueFor("bully-forever"), "Carol called for help against a much higher level")
    killEvent(a, "Bully", "Player-1-Bully")
    H.advance(2)
    eq(points(c, "Alice"), a.KOS.DEFENSE_POINTS)
    eq(weight(c, "Bully"), 1, "bully is now marked")
    assert(T_(c, "Bully").votes["alice-forever"].note:find("Attacked Carol"))
end)

test("assists: grouped guildies who hit the target get half the base", function()
    local a, b, c = H.newClient("Alice"), H.newClient("Bob"), H.newClient("Carol")
    H.advance(20)
    b.KOS:Mark("Gankdude", ""); c.KOS:Mark("Gankdude", "")
    H.advance(2)
    H.party = { Alice = true, Bob = true }
    b.cleu = { 0, "SPELL_DAMAGE", false, "Player-1-Bob", "Bob", 0x511, 0, "Player-1-Gankdude", "Gankdude", 0x548 }
    H.fire(b, "COMBAT_LOG_EVENT_UNFILTERED")
    b.cleu = { 0, "PARTY_KILL", false, "Player-1-Alice", "Alice", 0x511, 0, "Player-1-Gankdude", "Gankdude", 0x548 }
    H.fire(b, "COMBAT_LOG_EVENT_UNFILTERED")
    H.advance(2)
    eq(points(a, "Bob"), 6, "Bob's base without his own mark is 11; half is 6")
    local _, row = a.KOS:PointsOf("Bob-Forever")
    eq(row.assists, 1); eq(row.kills, 0)
end)

test("battlegrounds don't count: no claims, deaths or help calls", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    b.KOS:Mark("Gankdude", "")
    H.advance(2)
    H.inInstance = true
    killEvent(a, "Gankdude")
    dieTo(a, "Gankdude")
    H.advance(2)
    eq(points(b, "Alice"), 0)
    eq(#b.KOS:GanksBy("gankdude-forever"), 0)
    eq(countSent("A"), 0)
end)

test("enemy guilds: whole-guild KoS needs level and ganks; members pay a flat amount", function()
    H.guild.info = "KOS:guild=3"
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    for i, n in ipairs({ "Ganka", "Gankb", "Gankc" }) do
        b.KOS:Mark(n, "")
        H.advance(1)
        a.units["nameplate" .. i] = { name = n, guid = "Player-1-" .. n, guild = "Gankers" }
        H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate" .. i)
    end
    H.advance(2)
    local g = b.KOS:GuildStats()["Gankers"]
    eq(g.members, 3)
    assert(g.level >= 3)
    eq(g.kos, false, "level alone isn't enough without ganks")
    for i = 1, 10 do
        local dd = { victim = "Carol-Forever", killer = "Ganka-Forever", t = math.floor(H.serverTime) - i * 700, zone = "" }
        a.KOS:MergeDeath(dd); b.KOS:MergeDeath(dd)
    end
    b.KOS:InvalidateGuildStats(); a.KOS:InvalidateGuildStats()
    g = b.KOS:GuildStats()["Gankers"]
    eq(g.ganks, 10, "war ledger counts their ganks")
    eq(g.kos, true)
    local before = #a.raidWarnings
    a.units.nameplate9 = { name = "Innocentish", guid = "Player-1-Inno", guild = "Gankers" }
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate9")
    eq(#a.raidWarnings, before, "KoS-guild members get a skull, not a banner, by default")
    killEvent(a, "Innocentish", "Player-1-Inno")
    H.advance(2)
    eq(points(b, "Alice"), 2, "flat 2, no bonuses")
end)

test("nemesis: who's killed you most, and your record against them", function()
    local a, c = H.newClient("Alice"), H.newClient("Carol")
    H.advance(20)
    dieTo(c, "Gankdude"); H.advance(31); dieTo(c, "Gankdude")
    H.advance(2)
    local nem = a.KOS:NemesisOf("Carol-Forever")
    assert(nem, "nemesis found")
    eq(nem.killer, "Gankdude-Forever"); eq(nem.theirKills, 2); eq(nem.myKills, 0)
end)

test("badges come from the synced history", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    b.KOS:Mark("Gankdude", "")
    H.advance(2)
    killEvent(a, "Gankdude")
    H.advance(2)
    assert(H.chatContains(a, "Badge earned: First Blood"))
    eq(b.KOS:BadgeSet("Alice-Forever").first, true, "Bob sees Alice's badge too")
end)

test("calendar seasons: leaderboard resets, history stays", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    b.KOS:Mark("Gankdude", "")
    H.advance(2)
    killEvent(a, "Gankdude")
    H.advance(2)
    local p1 = points(b, "Alice")
    assert(p1 > 0)
    local _, ends = b.KOS:SeasonBounds()
    assert(ends, "calendar season has an end")
    jumpDays(math.ceil((ends - H.serverTime) / 86400) + 1)
    eq(points(b, "Alice"), 0, "new season, fresh board")
    local _, _, _, ps, pe = b.KOS:SeasonBounds()
    eq(b.KOS:PointsOf("Alice-Forever", ps, pe), p1, "last season still viewable")
    assert(next(b.KOS:Kills()), "claims kept as history")
end)

test("officer early season reset keeps history", function()
    local a, b = H.newClient("Alice"), H.newClient("Boss", { rank = 0 })
    H.advance(20)
    b.KOS:Mark("Gankdude", "")
    H.advance(2)
    killEvent(a, "Gankdude")
    H.advance(2)
    b.KOS:NewSeason()
    H.advance(2)
    eq(points(a, "Alice"), 0)
    assert(feedHas(a, "new bounty season"))
    assert(next(a.KOS:Kills()), "kills kept")
end)

test("officer strike voids a claim everywhere; forged big claims get flagged", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    local off = H.newClient("Officer", { rank = 1 })
    local pleb = H.newClient("Pleb")
    H.advance(20)
    b.KOS:Mark("Gankdude", "")
    H.advance(2)
    killEvent(a, "Gankdude")
    H.advance(2)
    pleb.env.C_ChatInfo.SendAddonMessage("KOS2",
        "S\tk\tGankdude-Forever\tPleb-Forever\t" .. math.floor(H.serverTime) .. "\t9999\t\t\t\t", "GUILD")
    H.advance(2)
    eq(points(off, "Pleb"), 500, "capped at MAX_CLAIM on receive")
    local flagged, id = false, nil
    for _, cl in ipairs(off.KOS:Claims("Pleb")) do
        id = cl.id
        for _, f in ipairs(cl.flags) do if f == "inflated?" then flagged = true end end
    end
    assert(flagged, "forged claim flagged")
    H.logout(b)
    off.KOS:Strike(id)
    H.advance(2)
    eq(points(a, "Pleb"), 0)
    b = H.relogin(b)
    H.advance(90)
    eq(points(b, "Pleb"), 0, "stale claim doesn't come back")
    jumpDays(30)
    for _, cl in ipairs(off.KOS:Claims("Alice")) do eq(#cl.flags, 0, "old legit claims don't become 'inflated'") end
end)

------------------------------------------------------------------------
-- Review fixes (GPT-6.1 Sol)
------------------------------------------------------------------------

test("a member can't forge an officer's pardon/season inside a dump", function()
    local gm, a = H.newClient("Boss", { rank = 0 }), H.newClient("Alice")
    local pleb = H.newClient("Pleb", { rank = 4 })
    H.advance(20)
    a.KOS:Mark("Gankdude", "x")
    H.advance(2)
    local send = pleb.env.C_ChatInfo.SendAddonMessage
    local t = math.floor(H.serverTime) + 50
    send("KOS2", "D\tc\tGankdude-Forever\tBoss-Forever\t" .. t, "GUILD")
    send("KOS2", "D\ts\tBoss-Forever\t" .. t, "GUILD")
    H.advance(2)
    eq(weight(a, "Gankdude"), 1, "pardon 'from the GM' relayed by a member is ignored")
    eq(a.KOS:List().season, nil)
end)

test("a demoted officer's old pardon still reaches newcomers via current officers", function()
    local off = H.newClient("Oldofficer", { rank = 1 })
    local gm, a = H.newClient("Boss", { rank = 0 }), H.newClient("Alice")
    H.advance(20)
    a.KOS:Mark("Gankdude", "x")
    H.advance(2)
    H.logout(a)
    off.KOS:Pardon("Gankdude")
    H.advance(2)
    off.rank = 5 -- demoted
    for _, c in ipairs(H.clients) do H.fire(c, "GUILD_ROSTER_UPDATE") end
    a = H.relogin(a)
    H.advance(120)
    eq(weight(a, "Gankdude"), 0, "the GM relays the old pardon")
    assert(allSame(), "everyone agrees")
end)

test("two newcomers a few seconds apart both get the data", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    for i = 1, 6 do a.KOS:Mark("Foe" .. string.char(96 + i), "") end
    H.advance(10)
    local n1 = H.newClient("Newa")
    H.advance(25)
    local n2 = H.newClient("Newb")
    H.advance(200)
    eq(active(n1), 6); eq(active(n2), 6)
    assert(allSame())
end)

test("absurdly long names are rejected instead of clogging sync", function()
    local a = H.newClient("Alice")
    H.advance(20)
    eq(a.KOS:Canonical(string.rep("a", 40)), nil)
    a.KOS:Mark(string.rep("a", 40), "x")
    eq(active(a), 0)
    eq(a.KOS:Canonical("Abcdefghijkl-" .. string.rep("r", 50)), nil)
end)

test("a fall or a mob finishing you off isn't a gank", function()
    local a = H.newClient("Alice")
    H.advance(20)
    hit(a, "Poker")
    a.cleu = { 0, "SWING_DAMAGE", false, "Creature-0-1", "Murloc", 0xa48, 0, "Player-1-Alice", "Alice", 0x511 }
    H.fire(a, "COMBAT_LOG_EVENT_UNFILTERED")
    H.fire(a, "PLAYER_DEAD")
    eq(weight(a, "Poker"), 0, "not auto-marked")
    eq(#a.KOS:GanksBy("poker-forever"), 0, "no gank recorded")
    -- but a logged killing blow from a player counts even if a mob hit last
    a.cleu = { 0, "SPELL_DAMAGE", false, "Player-1-Realganker", "Realganker", 0x548, 0, "Player-1-Alice", "Alice", 0x511,
        0, 133, "Fireball", 4, 900, 120 }
    H.fire(a, "COMBAT_LOG_EVENT_UNFILTERED")
    a.cleu = { 0, "SWING_DAMAGE", false, "Creature-0-1", "Murloc", 0xa48, 0, "Player-1-Alice", "Alice", 0x511, 0, 5, -1 }
    H.fire(a, "COMBAT_LOG_EVENT_UNFILTERED")
    H.fire(a, "PLAYER_DEAD")
    eq(weight(a, "Realganker"), 1, "killing blow (overkill) attributed")
end)

test("ganks keep a player on the list after the last mark is removed", function()
    local a, c = H.newClient("Alice"), H.newClient("Carol")
    H.advance(20)
    dieTo(c, "Gankdude")
    H.advance(2)
    H.slash(c, "rm Gankdude")
    H.advance(2)
    local T = T_(a, "Gankdude")
    eq(T.w, 0, "no marks")
    assert(T.on, "still on the list on gank evidence")
    assert(a.KOS:Lookup("gankdude-forever"), "still detected")
    a.cleu = { 0, "SPELL_DAMAGE", false, "Player-1-Gankdude", "Gankdude", 0x548, 0, "Player-1-Zed", "Zed", 0x548 }
    H.slash(a, "set minLevel 0")
    H.fire(a, "COMBAT_LOG_EVENT_UNFILTERED")
    eq(#a.raidWarnings, 1, "and alerts")
end)

test("conflicting copies of one claim settle on the lower value; values are capped", function()
    local a = H.newClient("Alice")
    H.advance(20)
    local k = { target = "Gankdude-Forever", by = "Bob-Forever", t = math.floor(H.serverTime), v = 9999 }
    a.KOS:MergeKill(k)
    eq(points(a, "Bob"), 500, "capped before storing")
    a.KOS:MergeKill({ target = k.target, by = k.by, t = k.t, v = 40 })
    eq(points(a, "Bob"), 40, "lower copy wins")
    a.KOS:MergeKill({ target = k.target, by = k.by, t = k.t, v = 300 })
    eq(points(a, "Bob"), 40, "higher copy ignored")
end)

------------------------------------------------------------------------
-- Noise control
------------------------------------------------------------------------

test("chatter: routine guild events go to the feed, not chat", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    H.slash(a, "add Gankdude hi")
    H.advance(2)
    assert(feedHas(b, "marked"), "in the feed")
    assert(not H.chatContains(b, "marked"), "not in chat by default")
    H.slash(b, "set chatter all")
    H.slash(a, "add Otherguy hi")
    H.advance(2)
    assert(H.chatContains(b, "marked"), "shows with chatter = all")
end)

test("chat rate limit: at most 4 guild lines per 10 seconds", function()
    local a = H.newClient("Alice")
    H.advance(20)
    local before = #a.chat
    for i = 1, 8 do a.KOS:Notify("big", "event " .. i) end
    eq(#a.chat - before, 4)
    H.advance(11)
    assert(H.chatContains(a, "More guild activity"))
    assert(#a.KOS:Feed() >= 8, "all in the feed")
end)

test("tracker copes with raids", function()
    local a = H.newClient("Alice")
    H.advance(20)
    a.KOS:Mark("Gankdude", "")
    local T = T_(a, "Gankdude")
    a.KOS:TrackSighting(T, "Bob-Forever", "Elwynn")
    a.env.IsInRaid = function() return true end
    a.KOS:TrackSighting(T, "Bob-Forever", "Elwynn")
end)

test("officer rules are edited in the guild info, without clobbering it", function()
    H.guild.info = "Raid nights Tue/Thu"
    local off, pleb = H.newClient("Officer", { rank = 1 }), H.newClient("Pleb", { rank = 4 })
    H.advance(20)
    assert(off.KOS:SetGuildRule("guild", 10))
    assert(H.guild.info:find("Raid nights Tue/Thu"), "kept the rest")
    assert(H.guild.info:find("KOS:guild=10"))
    off.KOS:SetGuildRule("guild", 15)
    local _, n = H.guild.info:gsub("KOS:guild", "")
    eq(n, 1, "replaced, not duplicated")
    eq(pleb.KOS:GuildThreshold(), 15, "everyone reads the same rule")
    off.KOS:SetGuildRule("addrank", 3)
    off.KOS:SetGuildRule("addrank", nil)
    assert(not H.guild.info:find("addrank"), "removed")
    eq(pleb.KOS:SetGuildRule("guild", 1), false, "non-officers can't")
end)

test("while you were away: one summary line after logging in", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    local c = H.newClient("Carol")
    H.advance(20)
    H.logout(c)
    a.KOS:Mark("Gankdude", ""); b.KOS:Mark("Gankdude", ""); b.KOS:Mark("Rogueguy", "")
    H.advance(2)
    killEvent(a, "Gankdude")
    H.advance(2)
    c = H.relogin(c)
    H.advance(130)
    assert(H.chatContains(c, "While you were away"), "summary shown")
    assert(H.chatContains(c, "bounties claimed"))
end)

------------------------------------------------------------------------
-- Sync robustness
------------------------------------------------------------------------

test("no dump storm: 12 synced members, one newcomer", function()
    local cs = {}
    for i = 1, 12 do cs[i] = H.newClient("Member" .. string.char(96 + i)) end
    H.advance(20)
    for i = 1, 30 do cs[1 + i % 3].KOS:Mark("Enemy" .. string.char(96 + (i % 26) + 1) .. string.rep("x", math.floor(i / 26)), "n" .. i) end
    H.advance(60)
    assert(allSame(), "baseline in sync")
    H.sent = {}
    local newbie = H.newClient("Newbie")
    H.advance(120)
    assert(allSame(), "newcomer converged")
    eq(active(newbie), 30)
    local dumps = countSent("B")
    print("      dumps sent for newcomer: " .. dumps .. ", total messages: " .. #H.sent)
    assert(dumps <= 2, "too many dumps: " .. dumps)
end)

test("bulk sync waits until out of combat", function()
    local a = H.newClient("Alice")
    H.advance(20)
    for i = 1, 10 do a.KOS:Mark("Foe" .. string.char(96 + i), "") end
    H.advance(10)
    H.combat = true
    local b = H.newClient("Bob")
    H.advance(60)
    eq(active(b), 0, "no dump while fighting")
    H.combat = false
    H.advance(90)
    eq(active(b), 10)
end)

test("sync survives throttling", function()
    H.throttleEvery = 3
    local a = H.newClient("Alice")
    H.advance(20)
    for i = 1, 20 do a.KOS:Mark("Foe" .. string.char(96 + i), "") end
    local b = H.newClient("Bob")
    H.advance(150)
    eq(active(b), 20)
    assert(allSame())
end)

test("max-size messages fit", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    a.KOS:Mark("Abcdefghijkl-Averyveryverylongrealmname", string.rep("\195\169", 60), "Player-12345-0ABCDEF0", "WARRIOR")
    H.advance(2)
    local T = b.KOS:Lookup("abcdefghijkl-averyveryverylongrealmname")
    assert(T, "received")
    local note = T.votes["alice-forever"].note
    assert(#note <= 100 and #note % 2 == 0)
end)

------------------------------------------------------------------------
-- Smoke
------------------------------------------------------------------------

test("UI: every tab renders, detail panes and officer tab", function()
    local off, b = H.newClient("Officer", { rank = 1 }), H.newClient("Bob")
    H.advance(20)
    b.KOS:Mark("Gankdude", "camper")
    off.units.nameplate1 = { name = "Gankdude", guid = "Player-1-G", guild = "Gankers" }
    H.fire(off, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.advance(2)
    killEvent(off, "Gankdude")
    H.advance(2)
    off.KOS:ShowUI("wanted")
    off.KOS:ShowTarget("Gankdude")
    for _, tab in ipairs({ "wanted", "hunters", "guilds", "activity", "settings", "officer" }) do
        off.KOS:SetTab(tab)
        off.KOS:RefreshUI()
    end
    off.KOS:OpenSettings()
    off.KOS:ToggleUI()
end)

test("personal list and slash commands don't error", function()
    local a = H.newClient("Solo", { inGuild = false })
    H.advance(20)
    eq(a.KOS:ListKey(), "_personal")
    H.slash(a, "add Gankdude solo note")
    eq(active(a), 1)
    eq(#H.sent, 0)
    for _, cmd in ipairs({ "", "list", "list gank", "top", "guilds", "claims", "config", "test", "sync", "help",
        "set sound pvp", "set minLevel 5", "season", "strike 1" }) do
        H.slash(a, cmd)
    end
    eq(a.KOS.S.sound, "pvp"); eq(a.KOS.S.minLevel, 5)
    a.KOS:Flash(true)
    a.KOS:RefreshTargetBadge()
    H.slash(a, "rm Gankdude")
    eq(active(a), 0)
    H.slash(a, "add")
    assert(H.chatContains(a, "Target a player first"))
end)

test("data persists across relog; 0.1 data migrates", function()
    local recent = math.floor(H.serverTime) - 86400
    local db = { lists = { ["Gankbusters-Forever"] = { entries = {
        ["gankdude-forever"] = { n = "Gankdude-Forever", note = "old format", by = "Alice-Forever", t = recent },
        ["gone-forever"] = { n = "Gone-Forever", note = "", by = "Alice-Forever", t = recent, del = true },
    } } } }
    local a = H.newClient("Alice", { db = db })
    H.advance(20)
    local T = a.KOS:Lookup("gankdude-forever")
    assert(T, "migrated")
    eq(T.votes["alice-forever"].note, "old format")
    eq(a.KOS:Lookup("gone-forever"), nil)
    a.KOS:Mark("Second", "persist me")
    a = H.relogin(a)
    eq(a.KOS:Lookup("second-forever").votes["alice-forever"].note, "persist me")
end)


------------------------------------------------------------------------
-- WoW: Forever (no combat log, secret values)
------------------------------------------------------------------------

local function honor(c, victim)
    H.fire(c, "CHAT_MSG_COMBAT_HONOR_GAIN", victim .. " dies, honorable kill Rank: Scout (Estimated Honor Points: 12)")
end

test("forever: no combat log, caps say so, nothing errors", function()
    H.forever = true
    local a = H.newClient("Alice")
    H.advance(20)
    eq(a.KOS.caps.combatLog, false)
    eq(a.KOS.caps.secrets, true)
    eq(a.KOS.frame.events.COMBAT_LOG_EVENT_UNFILTERED, nil, "never registers the combat log")
    a.KOS:ShowUI("settings")
    for _, tab in ipairs({ "wanted", "hunters", "guilds", "activity", "settings" }) do a.KOS:SetTab(tab) end
    eq(#a.KOS:CapsSummary(), 3)
end)

test("forever: secret names are skipped, readable ones still alert", function()
    H.forever = true
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    a.KOS:Mark("Gankdude", ""); b.KOS:Mark("Gankdude", "")
    H.advance(2)
    a.units.nameplate1 = { name = H.SECRET, guid = H.SECRET, level = H.SECRET }
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.advance(1)
    eq(#a.raidWarnings, 0)
    eq(a.KOS:UnitInfo("nameplate1"), nil)
    a.units.nameplate2 = { name = "Gankdude", guid = "Player-1-0001", level = 60, guild = H.SECRET }
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate2")
    H.advance(1)
    eq(#a.raidWarnings, 1, "a readable name still alerts even if the guild is secret")
end)

test("forever: honour kills pay every credited guildie; the bounty drains once", function()
    H.forever = true
    local a, b, c = H.newClient("Alice"), H.newClient("Bob"), H.newClient("Carol")
    H.advance(20)
    c.KOS:Mark("Gankdude", "")
    b.KOS:Mark("Gankdude", "")
    H.advance(2)
    local before = c.KOS:Score(T_(c, "Gankdude"))
    eq(a.KOS.HonorVictim("Gankdude dies, honorable kill Rank: Scout (Estimated Honor Points: 12)"), "Gankdude")
    eq(a.KOS.HonorVictim("Mietta Grace dies, honorable kill (Estimated Honor Points: 9)"), "Mietta Grace")
    local pat, cap = a.KOS.HonorPatternFrom("Rang %2$s: %1$s stirbt (%3$d)")
    eq(select(cap, ("Rang Späher: Gankdude stirbt (12)"):match(pat)), "Gankdude", "positional formats pick argument 1")
    honor(a, "Gankdude")
    honor(b, "Gankdude")
    H.advance(2)
    assert(points(c, "Alice") > 0, "Alice credited")
    assert(points(c, "Bob") > 0, "Bob credited")
    H.advance(31, 1)
    local after = c.KOS:Score(T_(c, "Gankdude"))
    assert(math.abs((before - after) - 50) < 1, "one drain for one kill: " .. before .. " -> " .. after)
    honor(a, "Randomguy")
    H.advance(1)
    eq(#a.KOS:Claims("Alice"), 1, "unmarked players pay nothing")
end)

test("forever: who killed me comes from a prompt; confirming records the gank and marks", function()
    H.forever = true
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    local shown
    local orig = a.KOS.ShowDeathPrompt
    a.KOS.ShowDeathPrompt = function(self, cands, at, zone) shown = { cands = cands, at = at, zone = zone }; orig(self, cands, at, zone) end
    a.units.nameplate4 = { name = "Gankdude", guid = "Player-1-0009", level = 60, targeting = "player" }
    a.units.nameplate5 = { name = "Friendly", guid = "Player-1-0010", level = 60, faction = "Alliance", targeting = "player" }
    a.units.nameplate6 = { name = "Bystander", guid = "Player-1-0011", level = 60 }
    for i = 4, 6 do H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate" .. i) end
    H.fire(a, "PLAYER_REGEN_DISABLED")
    a.health = 50; H.fire(a, "UNIT_HEALTH", "player")
    H.advance(1)
    H.fire(a, "PLAYER_DEAD")
    H.advance(1.5)
    assert(shown, "prompt shown")
    eq(#shown.cands, 1, "only the hostile player targeting me")
    eq(shown.cands[1].full, "Gankdude-Forever")
    a.KOS:ConfirmKiller(shown.cands[1], shown.at, shown.zone)
    H.advance(2)
    local T = b.KOS:Lookup("gankdude-forever")
    assert(T, "marked and synced")
    eq(#b.KOS:GanksBy("gankdude-forever"), 1, "the gank reached Bob")
end)

test("forever: the death recap's killer is offered first", function()
    H.forever = true
    local a = H.newClient("Alice")
    H.advance(20)
    local shown
    a.KOS.ShowDeathPrompt = function(_, cands) shown = cands end
    -- entry 1 is the killing blow, as in Blizzard's recap window
    a.recap = {
        { timestamp = 12, sourceName = "Recapper", sourceGUID = "Player-1-0021" },
        { timestamp = 10, sourceName = "Earlier", sourceGUID = "Player-1-0020" },
    }
    H.fire(a, "PLAYER_DEAD")
    eq(shown, nil, "waits a moment for the recap")
    H.advance(1.5)
    assert(shown and shown[1].full == "Recapper-Forever" and shown[1].why == "death recap", "recap killer first")
    shown = nil
    H.fire(a, "PLAYER_DEAD"); H.advance(1.5)
    eq(shown, nil, "the same recap isn't reused for the next death")
    a.recap = { { timestamp = 20, sourceName = "Murloc", sourceGUID = "Creature-0-1" } }
    H.fire(a, "PLAYER_DEAD"); H.advance(1.5)
    eq(shown, nil, "a mob finishing you off isn't offered")
    -- a recap left over from before logging in isn't offered
    local b = H.newClient("Bob")
    b.recap = { { timestamp = 5, sourceName = "Oldkiller", sourceGUID = "Player-1-0030" } }
    b = H.relogin(b)
    b.recap = { { timestamp = 5, sourceName = "Oldkiller", sourceGUID = "Player-1-0030" } }
    local bShown
    b.KOS.ShowDeathPrompt = function(_, cands) bShown = cands end
    H.fire(b, "PLAYER_LOGIN")
    H.fire(b, "PLAYER_DEAD"); H.advance(1.5)
    eq(bShown, nil, "stale recap ignored")
end)

test("forever: KoS player targeting me while I take damage calls for help; /kos sos too", function()
    H.forever = true
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    b.KOS:Mark("Gankdude", ""); a.KOS:Mark("Gankdude", "")
    H.advance(2)
    a.units.nameplate1 = { name = "Gankdude", guid = "Player-1-0001", level = 60, targeting = "player" }
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.fire(a, "PLAYER_REGEN_DISABLED")
    a.health = 80; H.fire(a, "UNIT_HEALTH", "player")
    a.health = 60; H.fire(a, "UNIT_HEALTH", "player")
    H.advance(2)
    local function helped(cl) for _, w in ipairs(cl.raidWarnings) do if w:find("HELP!") then return true end end end
    assert(helped(b), "Bob got the help call")
    local w
    for _, x in ipairs(b.raidWarnings) do if x:find("HELP!") then w = x end end
    assert(w:find("likely by Gankdude"), "worded as a likely attacker: " .. w)
    -- fighting a mob of my own: no automatic call
    local c = H.newClient("Carol")
    H.advance(20)
    c.KOS:Mark("Otherganker", "")
    H.advance(2)
    c.units.target = { name = "Murloc", npc = true }
    c.env.UnitIsPlayer = function(u) return u == "player" or (c.units[u] ~= nil and not c.units[u].npc) end
    c.env.UnitCanAttack = function(_, u) return c.units[u] ~= nil end
    c.units.nameplate2 = { name = "Otherganker", guid = "Player-1-0077", level = 60, targeting = "player" }
    H.fire(c, "NAME_PLATE_UNIT_ADDED", "nameplate2")
    H.fire(c, "PLAYER_REGEN_DISABLED")
    c.health = 80; H.fire(c, "UNIT_HEALTH", "player")
    c.health = 60; H.fire(c, "UNIT_HEALTH", "player")
    H.advance(2)
    assert(not feedHas(b, "likely by Otherganker"), "no help call while Carol fights her own mob")
    -- manual call against an unmarked target
    a.units.target = { name = "Somebody", guid = "Player-1-0005", level = 30 }
    H.slash(a, "sos")
    H.advance(2)
    assert(feedHas(b, "Somebody"), "manual help call reached Bob")
end)

test("forever: /kos probe saves results; secret fields show as SECRET", function()
    H.forever = true
    local a = H.newClient("Alice")
    H.advance(20)
    a.units.target = { name = H.SECRET, guid = "Player-1-0001", level = 60 }
    H.slash(a, "probe")
    local p = a.db.probe
    assert(p, "probe saved")
    eq(p.client.toc, 16001)
    eq(p.target.name, "SECRET")
    eq(p.caps.combatLog, false)
    assert(p.events.ADDON_LOADED, "event counts saved")
end)

test("handler errors are saved for troubleshooting and don't stop other handlers", function()
    local a = H.newClient("Alice")
    H.advance(20)
    local caught, ran = {}, false
    a.env.geterrorhandler = function() return function(e) caught[#caught + 1] = e end end
    a.KOS:On("KOS_TEST_EVENT", function() error("boom") end)
    a.KOS:On("KOS_TEST_EVENT", function() ran = true end)
    H.fire(a, "KOS_TEST_EVENT")
    H.fire(a, "KOS_TEST_EVENT")
    assert(ran, "second handler still ran")
    eq(#caught, 2, "passed on to the normal error handler")
    local e = a.db.diag.errors
    eq(#e, 1, "repeats are counted, not duplicated")
    assert(e[1].msg:find("boom") and e[1].n == 2, e[1].msg)
end)

test("names with spaces (Forever) can be marked, synced and seen", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    a.KOS:Mark("Kind Eyes", "camps the flight path")
    b.KOS:Mark("kind eyes", "")
    H.advance(2)
    eq(weight(b, "Kind Eyes"), 2)
    H.slash(a, 'add "Mietta Grace" rude')
    H.advance(2)
    assert(b.KOS:Lookup("mietta grace-forever"), "quoted slash name with spaces")
    b.units.nameplate1 = { name = "Kind Eyes", guid = "Player-1-0042", level = 60 }
    H.fire(b, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.advance(1)
    eq(#b.raidWarnings, 1, "Bob marked them himself, so he's alerted")
    eq(b.KOS:ResolveUnit("nameplate1").n, "Kind Eyes-Forever")
end)

test("search filters the Wanted list and trims spaces", function()
    local a = H.newClient("Alice")
    H.advance(20)
    a.KOS:Mark("Gankdude", "camps the flight path")
    a.KOS:Mark("Otherguy", "")
    a.KOS:ShowUI("wanted")
    local w = a.KOS.WantedWidgets()
    local function search(text)
        w.search:SetText(text)
        w.search.scripts.OnTextChanged(w.search)
        return w.count:GetText()
    end
    eq(search(""), "2 players")
    eq(search("flight "), "1 player", "matches notes; trailing space ignored")
    eq(search("OTHER"), "1 player", "case-insensitive names")
    eq(search("nobody"), "0 players")
    assert(w.list.empty:GetText():find("No one matches"), "says nothing matched rather than 'list empty'")
end)


test("forever: everyone on one shared kill is priced the same, whichever claim lands first", function()
    H.forever = true
    local a, b, c, d = H.newClient("Alice"), H.newClient("Bob"), H.newClient("Carol"), H.newClient("Dave")
    H.advance(20)
    c.KOS:Mark("Gankdude", ""); d.KOS:Mark("Gankdude", "")
    H.advance(2)
    honor(a, "Gankdude")
    H.advance(3) -- Alice's claim (and its drain) reaches Bob first
    honor(b, "Gankdude")
    H.advance(2)
    eq(points(c, "Bob"), points(c, "Alice"), "Bob isn't priced after Alice's drain")
    for _, cl in ipairs(c.KOS:Claims()) do eq(#cl.flags, 0, "neither claim looks inflated") end
end)

test("forever: a responder credited by honour gets the kill, not an assist as well", function()
    H.forever = true
    local a, b, c = H.newClient("Alice"), H.newClient("Bob"), H.newClient("Carol")
    c.x, c.y = 0.50, 0.50; a.x, a.y = 0.52, 0.50
    H.advance(20)
    b.KOS:Mark("Gankdude", "")
    H.advance(2)
    c.KOS:ManualHelp() -- no target: nothing to call against
    c.units.target = { name = "Gankdude", guid = "Player-1-0001", level = 60 }
    c.KOS:ManualHelp()
    H.advance(2)
    a.KOS:Respond("Gankdude-Forever")
    H.advance(1)
    honor(b, "Gankdude") -- Bob's claim arrives at Alice first...
    H.advance(1)
    honor(a, "Gankdude") -- ...then the game credits Alice too
    H.advance(7)
    local _, row = c.KOS:PointsOf("Alice-Forever")
    eq(row.assists, 0, "no extra assist")
    eq(row.kills, 1)
end)

test("events fired from inside a handler don't scramble the outer handler's arguments", function()
    local a = H.newClient("Alice")
    H.advance(20)
    local got
    a.KOS:On("KOS_OUTER", function() H.fire(a, "KOS_INNER", "inner") end)
    a.KOS:On("KOS_OUTER", function(x) got = x end)
    a.KOS:On("KOS_INNER", function() end)
    H.fire(a, "KOS_OUTER", "outer")
    eq(got, "outer")
end)

test("sync holds its messages inside instances and sends them back in the world", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    H.inInstance = true
    a.KOS:Mark("Gankdude", "")
    H.advance(5)
    eq(b.KOS:Lookup("gankdude-forever"), nil, "nothing sent from the dungeon")
    H.inInstance = false
    H.advance(5)
    assert(b.KOS:Lookup("gankdude-forever"), "sent once back outside")
end)


test("forever: a group gank can be reported against several players", function()
    H.forever = true
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    local shown
    a.KOS.ShowDeathPrompt = function(_, cands, at, zone) shown = { cands = cands, at = at, zone = zone } end
    a.units.nameplate1 = { name = "Gankone", guid = "Player-1-0101", level = 60, targeting = "player" }
    a.units.nameplate2 = { name = "Ganktwo", guid = "Player-1-0102", level = 60, targeting = "player" }
    for i = 1, 2 do H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate" .. i) end
    H.fire(a, "PLAYER_REGEN_DISABLED")
    a.health = 50; H.fire(a, "UNIT_HEALTH", "player")
    H.advance(1)
    H.fire(a, "PLAYER_DEAD")
    H.advance(1.5)
    eq(#shown.cands, 2)
    for _, c in ipairs(shown.cands) do a.KOS:ConfirmKiller(c, shown.at, shown.zone) end
    H.advance(2)
    eq(#b.KOS:GanksBy("gankone-forever"), 1)
    eq(#b.KOS:GanksBy("ganktwo-forever"), 1)
    assert(b.KOS:Lookup("gankone-forever") and b.KOS:Lookup("ganktwo-forever"), "both marked")
end)

test("guild rules are read from a cache in combat, where reading guild info is blocked", function()
    H.guild.info = "KOS:season=2"
    local a = H.newClient("Alice")
    H.advance(5)
    eq(a.KOS:GuildTag("season"), 2)
    H.combat = true
    local reads = 0
    local real = a.env.GetGuildInfoText
    a.env.GetGuildInfoText = function() reads = reads + 1; return real() end
    H.guild.info = "KOS:season=4"
    eq(a.KOS:GuildTag("season"), 2, "combat uses the cached text")
    eq(reads, 0, "no guild info read in combat")
    H.combat = false
    eq(a.KOS:GuildTag("season"), 4, "out of combat it's read live again")
end)

test("/kos sync reports what was sent and who has been heard from, with versions", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    a.KOS:Mark("Kind Eyes", "camps the flight path")
    H.advance(2)
    H.slash(b, "sync")
    H.advance(5)
    a.chat = {}
    H.slash(a, "sync")
    assert(H.chatContains(a, "Syncing with guild"), "guild line")
    assert(H.chatContains(a, "Heard from: Bob (9.9.9"), "Bob's version from his hello")
    local st = a.KOS.db.diag.sync
    assert(st.sent >= 2, "sent counted")
    assert(st.recv >= 1, "received counted")
    eq(next(st.fail), nil, "no failed sends")
    assert(not H.chatContains(a, "Registering the message channel"), "a normal registration isn't reported")
    -- an old client's hello has no addon version
    H.fire(a, "CHAT_MSG_ADDON", a.KOS.PREFIX, "H\tabc\t3\t2", "GUILD", "Carol-Forever")
    eq(st.peers["carol-forever"].ver, "older than 0.6.3")
end)

test("a guildie on a newer version tells you once when you log in", function()
    local b = H.newClient("Bob", { version = "0.7.0" })
    local c = H.newClient("Carol", { version = "0.7.0" })
    H.advance(30)
    local before = countSent("V")
    local a = H.newClient("Alice", { version = "0.6.3" })
    H.advance(30)
    eq(countSent("V") - before, 1, "one newer guildie answers; the other stands down")
    local notices = 0
    for _, l in ipairs(a.chat) do if l:find("A newer Utu (0.7.0) is out", 1, true) then notices = notices + 1 end end
    eq(notices, 1, "told once")
    eq(a.KOS.Sync:NewerVersion(), "0.7.0")
    eq(b.KOS.Sync:NewerVersion(), nil, "the newer client isn't nagged")
    -- same version: nobody answers
    before = countSent("V")
    H.newClient("Dave", { version = "0.7.0" })
    H.advance(30)
    eq(countSent("V") - before, 0)
    eq(a.KOS.Sync.versionNum("0.10.2") > a.KOS.Sync.versionNum("0.9.9"), true)
    eq(a.KOS.Sync.versionNum("1.0"), nil)
end)

test("forever: two-word names the game splits into name and realm are put back together", function()
    H.forever = true
    -- saved by an earlier version: "Pi Target" stored as Pi-Target, plus a
    -- correct mark for the same player and a gank by Sqwert Sqwert
    local old = { lists = { ["Gankbusters-Forever"] = {
        targets = {
            ["pi-target"] = { n = "Pi-Target", guid = "Player-1-0P1", class = "ROGUE", guild = "Washed IRL", w = 1, on = true,
                votes = { ["dangley-forever"] = { by = "Dangley-Forever", note = "", t = math.floor(H.serverTime) - 100 } } },
            ["pi target-forever"] = { n = "Pi Target-Forever", w = 1, on = true,
                votes = { ["bob-forever"] = { by = "Bob-Forever", note = "camps", t = math.floor(H.serverTime) - 50 } } },
            ["kind eyes-camwowau1realm2pvp"] = { n = "kind eyes-CAMWOWAU1Realm2PvP", w = 1, on = true,
                votes = { ["bob-forever"] = { by = "Bob-Forever", note = "", t = math.floor(H.serverTime) - 50 } } },
        },
        deaths = { ["dangley-forever|sqwert-sqwert|" .. (math.floor(H.serverTime) - 60)] =
            { victim = "Dangley-Forever", killer = "Sqwert-Sqwert", t = math.floor(H.serverTime) - 60, zone = "" } },
        kills = {}, struck = {},
    } } }
    local a = H.newClient("Alice", { db = old })
    H.advance(20)
    local K = a.KOS
    local T = K:Lookup("pi target-forever")
    assert(T, "repaired key")
    eq(K:Lookup("pi-target"), nil, "old key gone")
    eq(T.n, "Pi Target-Forever")
    assert(T.votes["dangley-forever"] and T.votes["bob-forever"], "marks merged")
    eq(T.guid, "Player-1-0P1"); eq(T.class, "ROGUE")
    eq(#K:GanksBy("sqwert sqwert-forever"), 1, "gank re-keyed")
    assert(K:Lookup("kind eyes-camwowau1realm2pvp"), "a realm with digits is a realm")
    eq(K:Lookup("kind eyes-camwowau1realm2pvp").n, "Kind Eyes-CAMWOWAU1Realm2PvP", "saved lowercase name capitalised")
    eq(K:Canonical("Gankdude-Forever"), "gankdude-forever", "our own realm stays a realm")
    eq(select(2, K:Canonical("Fourty-Shots")), "Fourty Shots-Forever")

    -- clicking a player: the game hands back ("Fourty", "Shots")
    a.units.target = { name = "Fourty", realm = "Shots", guid = "Player-1-0F1", level = 36 }
    eq(K:UnitInfo("target").full, "Fourty Shots")
    K:Mark(K:UnitInfo("target").full, "")
    assert(K:Lookup("fourty shots-forever"), "marked under the whole name")

    -- an older guildie still sends the split form
    local b = H.newClient("Bob")
    H.advance(20)
    H.fire(a, "CHAT_MSG_ADDON", K.PREFIX, "S\tv\tSqwert-Sqwert\tBob-Forever\t" .. math.floor(H.serverTime) .. "\t0\t\t\t", "GUILD", "Bob-Forever")
    assert(K:Lookup("sqwert sqwert-forever"), "incoming split name stored whole")
end)

test("activity shows marks and ganks that arrived by sync, your own marks, and no duplicates", function()
    local b = H.newClient("Bob")
    H.advance(20)
    b.KOS:Mark("Gankdude", "camps the flight path")
    H.advance(2)
    -- Alice wasn't online for that: it reaches her in a dump
    local a = H.newClient("Alice", { db = { feeds = { ["Gankbusters-Forever"] = {
        { t = 1, p = "info", text = "Old marked |cffff6060Someone|r - Suspect" },
        { t = 2, p = "nearby", text = "Carol spotted Someone in Duskwood" },
    } } } })
    H.advance(30)
    local function count(c, needle)
        local n = 0
        for _, e in ipairs(c.KOS:Activity()) do if e.text:find(needle, 1, true) then n = n + 1 end end
        return n
    end
    eq(count(a, "Bob marked"), 1, "synced mark shows up")
    eq(count(a, "camps the flight path"), 1)
    a.KOS:Mark("Gankdude", "")
    H.advance(2)
    eq(count(a, "You marked"), 1, "your own mark shows up")
    eq(count(b, "Alice marked"), 1, "a live mark shows once, not twice")
    eq(count(a, "Old marked"), 0, "copies old versions kept in the feed are dropped")
    eq(count(a, "spotted Someone"), 1, "event-only entries are kept")
end)

test("minimap button is a LibDBIcon launcher and keeps the old position", function()
    local a = H.newClient("Alice", { db = { settings = { minimapAngle = 123 } } })
    H.advance(5)
    eq(a.minimap.registered, "Utu")
    local obj = a.minimap.objects.Utu
    eq(obj.type, "launcher")
    eq(a.minimap.db.minimapPos, 123, "carried over from the old button")
    eq(a.minimap.shown.Utu, true)
    H.slash(a, "set minimap false")
    eq(a.minimap.shown.Utu, false, "the setting hides it")
    eq(a.minimap.db.hide, true)
    local lines = {}
    obj.OnTooltipShow({ AddLine = function(_, l) lines[#lines + 1] = l end })
    eq(lines[1], "Utu")
end)

test("sync goes through ChatThrottleLib: live messages NORMAL, bulk sync BULK", function()
    local b = H.newClient("Bob")
    H.advance(20)
    b.KOS:Mark("Gankdude", "")
    H.advance(2)
    local a = H.newClient("Alice")
    H.advance(30)
    local prio = {}
    for _, m in ipairs(b.ctl) do prio[m.msg:sub(1, 1)] = m.prio end
    eq(prio.S, "NORMAL", "live mark")
    eq(prio.D, "BULK", "dump item")
    assert(a.KOS:Lookup("gankdude-forever"), "still syncs")
    assert(b.KOS.db.diag.sync.sent > 0, "sends counted from the callback")
end)

test("help banner wording follows the kind of call", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    b.KOS.S.helpBanner = "any"
    local verbs = {}
    b.KOS.ShowHelpPrompt = function(_, attacker, victim, where, T, verb) verbs[#verbs + 1] = verb end
    local function call(attacker, how)
        H.fire(b, "CHAT_MSG_ADDON", b.KOS.PREFIX, "A\t" .. attacker .. "\tElwynn Forest\t\t\t\t" .. (how or ""), "GUILD", "Alice-Forever")
        H.advance(20)
    end
    call("Gankone-Forever", "t")
    call("Ganktwo-Forever", "m")
    call("Gankthree-Forever", nil)
    eq(verbs[1], " is under attack, likely by ")
    eq(verbs[2], " needs help against ")
    eq(verbs[3], " is being ganked by ")
end)

test("muting a guildie hides their marks and sightings from you; bounties stay the same", function()
    local a, b, c = H.newClient("Alice"), H.newClient("Bob"), H.newClient("Carol")
    H.advance(20)
    a.KOS.S.minLevel = 0
    H.slash(a, "mute Bob")
    assert(a.KOS:IsMuted("Bob-Forever"))
    b.KOS:Mark("Spamtarget", "looked at me funny")
    H.advance(2)
    eq(level(a, "Spamtarget"), level(c, "Spamtarget"), "bounty is the same for everyone")
    assert(not feedHas(a, "Bob marked"), "Bob's mark is hidden from Activity")
    assert(feedHas(c, "Bob marked"), "only for Alice")
    a.units.nameplate1 = { name = "Spamtarget", guid = "Player-1-0S1", level = 60 }
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.advance(2)
    eq(#a.raidWarnings, 0, "no alert: only Bob marked them")
    -- Bob's sightings stay out of Alice's Activity too
    b.units.nameplate1 = { name = "Spamtarget", guid = "Player-1-0S1", level = 60 }
    H.fire(b, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.advance(2)
    assert(feedHas(c, "Bob spotted"), "Carol sees Bob's sighting")
    assert(not feedHas(a, "Bob spotted"), "Alice doesn't")
    -- once someone else marks them, alerts are back
    c.KOS:Mark("Spamtarget", "")
    H.advance(2)
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.advance(2)
    eq(#a.raidWarnings, 1, "Carol's mark counts")
    assert(feedHas(a, "Carol marked"))
    -- a gank on record also counts, whoever marked them
    b.KOS:Mark("Gankerx", "")
    H.advance(2)
    assert(a.KOS:OnlyMutedMarks(a.KOS:Lookup("gankerx-forever")))
    a.KOS:MergeDeath({ victim = "Dave-Forever", killer = "Gankerx-Forever", t = math.floor(H.serverTime) - 10, zone = "" })
    eq(a.KOS:OnlyMutedMarks(a.KOS:Lookup("gankerx-forever")), false, "ganks still alert")
    -- undo, and you can't mute yourself
    H.slash(a, "unmute Bob")
    assert(feedHas(a, "Bob marked"), "unmuting brings Bob's marks back")
    H.slash(a, "mute Alice")
    eq(a.KOS:IsMuted("Alice-Forever"), false)
    -- the "Mute a guildie by name" box
    a.env.StaticPopupDialogs.UTU_MUTE.OnAccept({ editBox = { GetText = function() return " bob " end } })
    assert(a.KOS:IsMuted("Bob-Forever"), "muted from the name box")
end)

test("what's new: shown once after an update, never on a fresh install", function()
    local function newsLines(c)
        local n = 0
        for _, l in ipairs(c.chat) do -- header lines only, not the bullets
            if l:find("Utu|r: What's new in", 1, true) or l:find("What's new since", 1, true) then n = n + 1 end
        end
        return n
    end
    -- the generated notes are current: the newest section is this version
    local toc = io.open("Utu/Utu.toc"):read("*a")
    local tocVersion = toc:match("## Version: ([%d%.]+)")
    local a = H.newClient("Alice", { version = tocVersion })
    eq(a.KOS.CHANGES[1][1], tocVersion, "CHANGELOG.md's top section matches the toc (run ./build.sh)")
    for _, c in ipairs(a.KOS.CHANGES) do
        assert(a.KOS.VersionNum(c[1]), "version " .. tostring(c[1]))
        assert(#c[2] > 0, c[1] .. " has notes")
    end
    H.advance(30)
    eq(newsLines(a), 0, "fresh install: no news")
    eq(a.KOS.db.seenVersion, tocVersion)
    -- saved data from before 0.7.4 counts as 0.7.3
    local b = H.newClient("Bob", { version = "0.7.4", db = { lists = {} } })
    H.advance(30)
    eq(newsLines(b), 1, "told about 0.7.4")
    assert(H.chatContains(b, "/utu news shows it again"))
    eq(b.KOS.db.seenVersion, "0.7.4")
    -- logging in again on the same version: nothing
    b = H.relogin(b)
    H.advance(30)
    eq(newsLines(b), 0, "only once")
    -- skipping versions lists everything since, capped, newest first
    local c = H.newClient("Carol", { version = "0.7.4", db = { lists = {}, seenVersion = "0.6.0" } })
    H.advance(30)
    assert(H.chatContains(c, "Updated to 0.7.4. What's new since 0.6.0:"))
    local bullets = 0
    for _, l in ipairs(c.chat) do if l:sub(1, 4) == "  - " then bullets = bullets + 1 end end
    eq(bullets, c.KOS.NEWS_MAX)
    assert(H.chatContains(c, "CHANGELOG.md"), "points at the full changelog")
    -- notes for versions newer than the one installed aren't shown
    eq(#c.KOS:ChangesSince("0.7.3"), 1)
    -- /utu news: this version's notes
    local before = newsLines(a)
    H.slash(a, "news")
    eq(newsLines(a), before + 1)
end)

test("hostile sync input: future or odd timestamps, escape codes, bad numbers", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    local K, now = a.KOS, math.floor(H.serverTime)
    local function from(c, msg) H.fire(c, "CHAT_MSG_ADDON", K.PREFIX, msg, "GUILD", "Bob-Forever") end
    -- a claim dated far in the future (or not a number at all) is dropped
    for _, t in ipairs({ "1e999", "9999999999", tostring(now + 7200), "123.5", "nan", "-5" }) do
        from(a, "S\tk\tGankdude-Forever\tBob-Forever\t" .. t .. "\t500\t\t\t\t")
    end
    eq((K:PointsOf("Bob-Forever")), 0, "no claim accepted")
    eq(K.Sync.stamp(tostring(now + 60)), now + 60, "a little ahead is fine (lag)")
    -- marks too
    from(a, "S\tv\tGankdude-Forever\tBob-Forever\t9999999999\t0\t\t\t")
    eq(K:GetTarget("gankdude-forever"), nil)
    -- escape codes in the realm part never reach the UI
    local key, full = K:Canonical("Gankdude-|cff00ff00Boss|r")
    assert(not full:find("|", 1, true), full)
    eq(key, "gankdude-cff00ff00bossr")
    eq(K:Canonical("Gankdude-|||"), nil)
    -- a help call with broken coordinates doesn't error
    from(a, "A\tGankdude-Forever\tElwynn Forest\t1429\tnan\t0.5\tt")
    from(a, "A\tOtherguy-Forever\tElwynn Forest\t1429\t1e999\t\tt")
    from(a, "O\tGankdude-Forever\tAlice-Forever\t1e999")
    -- a junk version string isn't stored or printed
    from(a, "H\tabc\t3\t2\t|cffff0000haha|r")
    H.slash(a, "sync")
    for _, l in ipairs(a.chat) do assert(not l:find("haha", 1, true), l) end
    local e = a.db.diag and a.db.diag.errors
    eq(e and #e or 0, 0, "no handler errors: " .. tostring(e and e[1] and e[1].msg))
end)

test("damaged saved data is dropped instead of stopping the addon loading", function()
    local now = math.floor(H.serverTime)
    local db = { lists = { ["Gankbusters-Forever"] = {
        targets = {
            ["good-forever"] = { n = "Good-Forever", votes = { ["bob-forever"] = { by = "Bob-Forever", t = now - 100, note = "" } } },
            ["bad-forever"] = { n = "Bad-Forever", votes = { ["bob-forever"] = { by = "Bob-Forever", note = "no time" }, x = "junk" } },
            ["junk"] = "not a table",
        },
        kills = { k1 = { by = "Bob-Forever" }, k2 = "junk" },
        deaths = { d1 = { victim = "Bob-Forever", t = now } },
        struck = { s1 = 5 },
    } } }
    local a = H.newClient("Alice", { db = db })
    H.advance(20)
    local e = a.db.diag and a.db.diag.errors
    eq(e and #e or 0, 0, "loaded: " .. tostring(e and e[1] and e[1].msg))
    assert(a.env.SlashCmdList.UTU, "slash commands registered")
    local list = db.lists["Gankbusters-Forever"]
    eq(list.targets.junk, nil)
    eq(next(list.targets["bad-forever"].votes), nil, "bad votes dropped")
    eq(list.targets["good-forever"].on, true, "good marks kept")
    eq(next(list.kills), nil); eq(next(list.deaths), nil); eq(next(list.struck), nil)
end)

test("forgery check: items in my name that I never made are flagged, not rejected", function()
    local a, b = H.newClient("Alice"), H.newClient("Bob")
    H.advance(20)
    local K = a.KOS
    local now = math.floor(H.serverTime)
    local function dump(c, item) H.fire(c, "CHAT_MSG_ADDON", K.PREFIX, "D\t" .. item, "GUILD", "Bob-Forever") end
    local function flagged(c, needle)
        for _, l in ipairs(c.chat) do if l:find("Possible forgery", 1, true) and (not needle or l:find(needle, 1, true)) then return true end end
        return false
    end
    local function flags(c) return #c.KOS:Ledger().flags end
    K:Mark("Gankdude", "camps the flight path")
    H.advance(5)
    local mine = T_(a, "Gankdude").votes[K:MyKey()]
    -- my own mark coming back unchanged (or as an older copy) is fine
    dump(a, "v\tGankdude-Forever\tAlice-Forever\t" .. mine.t .. "\t0\t\t\tcamps the flight path")
    dump(a, "v\tGankdude-Forever\tAlice-Forever\t" .. mine.t .. "\t0\t\t\tcamps the fli")
    dump(a, "v\tGankdude-Forever\tAlice-Forever\t" .. (mine.t - 50) .. "\t0\t\t\told note")
    eq(flags(a), 0, "no flags for real or stale copies")
    -- a forged removal of my mark: flagged with the relay named, and still applied
    dump(a, "v\tGankdude-Forever\tAlice-Forever\t" .. (mine.t + 10) .. "\t1\t\t\t")
    assert(flagged(a, "relayed by Bob"), "warned, naming the relay")
    assert(flagged(a, "/utu add Gankdude"), "with the fix")
    eq(K:MyVote(T_(a, "Gankdude")), nil, "data handling unchanged: the removal applied")
    -- the same item again isn't flagged twice
    dump(a, "v\tGankdude-Forever\tAlice-Forever\t" .. (mine.t + 10) .. "\t1\t\t\t")
    eq(flags(a), 1)
    -- re-marking puts it back for everyone
    b.KOS:MergeVote("gankdude-forever", "Gankdude-Forever", { by = "Alice-Forever", t = mine.t + 10, del = true, note = "" })
    H.slash(a, "add Gankdude camps the flight path")
    H.advance(5)
    assert(K:MyVote(T_(a, "Gankdude")), "re-marked")
    assert(b.KOS:MyVote(T_(b, "Gankdude")) == nil and T_(b, "Gankdude").votes["alice-forever"] and not T_(b, "Gankdude").votes["alice-forever"].del,
        "Bob has Alice's mark back")
    -- a mark in my name on someone I never marked
    dump(a, "v\tVictim-Forever\tAlice-Forever\t" .. now .. "\t0\t\t\tforged")
    assert(flagged(a, "Victim"))
    -- claims: a lowered copy of mine is flagged; a made-up one too
    K:RecordClaim({ target = "Gankdude-Forever", by = "Alice-Forever", t = now + 1, v = 20, zone = "" }, function() return "x" end)
    K:RecordClaim({ target = "Gankdude-Forever", by = "Alice-Forever", t = now + 1, v = 12, zone = "" }, function() return "x" end)
    dump(a, "k\tGankdude-Forever\tAlice-Forever\t" .. (now + 1) .. "\t20\t\t\t\t")
    eq(flags(a), 2, "a higher copy of a claim that shares an id with a lower one isn't flagged")
    dump(a, "k\tGankdude-Forever\tAlice-Forever\t" .. (now + 1) .. "\t0\t\t\t\t")
    assert(flagged(a, "from 12 to 0"), "zeroing flagged")
    dump(a, "k\tSomeone-Forever\tAlice-Forever\t" .. now .. "\t40\t\t\t\t")
    eq(flags(a), 4, "recorded")
    assert(not flagged(a, "40-point bounty claim"), "but at most 3 warnings a minute")
    H.advance(61)
    dump(a, "v\tVictimtwo-Forever\tAlice-Forever\t" .. now .. "\t0\t\t\tforged")
    assert(flagged(a, "1 more flagged; see /utu sync"), "the held-back one is mentioned")
    -- shown in /utu sync
    H.slash(a, "sync")
    assert(H.chatContains(a, "Possible forgeries in your name"))
    -- items for other people aren't audited
    local before = flags(a)
    dump(a, "v\tGankdude-Forever\tCarol-Forever\t" .. now .. "\t0\t\t\t")
    eq(flags(a), before)
end)

test("forgery check: no flags for history from before tracking, a reinstall, or an alt", function()
    local now = math.floor(H.serverTime)
    -- saved data from 0.7.7: my mark and claim already in the list
    local db = { lists = { ["Gankbusters-Forever"] = {
        targets = { ["gankdude-forever"] = { n = "Gankdude-Forever", w = 1, on = true,
            votes = { ["alice-forever"] = { by = "Alice-Forever", t = now - 500, note = "old" } } } },
        kills = { ["alice-forever|gankdude-forever|" .. (now - 400)] = { by = "Alice-Forever", target = "Gankdude-Forever", t = now - 400, v = 15 } },
        deaths = {}, struck = {},
    } } }
    local a = H.newClient("Alice", { db = db })
    H.newClient("Bob")
    H.advance(20)
    local K = a.KOS
    local function dump(item) H.fire(a, "CHAT_MSG_ADDON", K.PREFIX, "D\t" .. item, "GUILD", "Bob-Forever") end
    dump("v\tGankdude-Forever\tAlice-Forever\t" .. (now - 500) .. "\t0\t\t\told")
    dump("k\tGankdude-Forever\tAlice-Forever\t" .. (now - 400) .. "\t15\t\t\t\t")
    -- something "of mine" dated before this install started tracking: unknown, not flagged
    dump("v\tOther-Forever\tAlice-Forever\t" .. (now - 300) .. "\t0\t\t\t")
    eq(#K:Ledger().flags, 0, "seeded from the saved list")
    -- an alt on the same account (shared saved data) keeps its own record
    local alt = H.newClient("Alicealt", { db = db })
    H.advance(20)
    alt.KOS:Mark("Thing", "")
    assert(alt.KOS:Ledger() ~= K:Ledger(), "separate records")
    eq(K:Ledger().votes["thing-forever"], nil)
    H.advance(300)
    assert(allSame(), "lists still converge")
end)

test("forgery check edge cases: old claims, pardons, far-ahead forged removals", function()
    local a = H.newClient("Alice", { rank = 1 })
    local b = H.newClient("Bob")
    H.advance(20)
    local K = a.KOS
    local now = math.floor(H.serverTime)
    local function dump(item) H.fire(a, "CHAT_MSG_ADDON", K.PREFIX, "D\t" .. item, "GUILD", "Bob-Forever") end
    K:Ledger()
    -- a claim past the horizon is never judged
    dump("k\tGankdude-Forever\tAlice-Forever\t" .. (K:KillHorizon() - 10) .. "\t40\t\t\t\t")
    eq(#K:Ledger().flags, 0)
    -- forged removal dated as far ahead as sync allows; then a pardon; re-marking still wins everywhere
    K:Mark("Gankdude", "")
    H.advance(5)
    local t = T_(a, "Gankdude").votes[K:MyKey()].t
    local forged = "D\tv\tGankdude-Forever\tAlice-Forever\t" .. (math.floor(H.serverTime) + 3600) .. "\t1\t\t\t"
    H.fire(a, "CHAT_MSG_ADDON", K.PREFIX, forged, "GUILD", "Carol-Forever")
    H.fire(b, "CHAT_MSG_ADDON", K.PREFIX, forged, "GUILD", "Carol-Forever")
    eq(#K:Ledger().flags, 1)
    assert(T_(b, "Gankdude").votes["alice-forever"].del, "Bob took the forged removal")
    assert(T_(a, "Gankdude").votes[K:MyKey()].t > t)
    K:Pardon("Gankdude")
    H.advance(2)
    H.slash(a, "add Gankdude back again")
    H.advance(5)
    assert(K:MyVote(T_(a, "Gankdude")), "Alice's mark is back")
    local bv = T_(b, "Gankdude").votes["alice-forever"]
    assert(not bv.del, "and Bob has it")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
