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
local function feedHas(c, needle)
    for _, e in ipairs(c.KOS:Feed()) do if e.text:find(needle, 1, true) then return true end end
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

test("nameplate detection: alert on arrival, guild noted, re-alert only after they leave", function()
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
    H.advance(200)
    H.fire(a, "NAME_PLATE_UNIT_ADDED", "nameplate3")
    eq(#a.raidWarnings, 2, "alerts again when he returns")
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
    H.advance(200)
    H.slash(a, "set srcTarget off")
    H.fire(a, "PLAYER_TARGET_CHANGED")
    eq(#a.raidWarnings, 0, "targeting source disabled")
    H.slash(a, "set srcTarget on")
    H.resting = true
    H.slash(a, "set quietResting on")
    H.advance(200)
    H.fire(a, "PLAYER_TARGET_CHANGED")
    eq(#a.raidWarnings, 0, "quiet while resting")
    H.resting = false
    H.inInstance = true
    H.advance(200)
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
    H.advance(200)
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
        "set sound pvp", "set cooldown 300", "season", "strike 1" }) do
        H.slash(a, cmd)
    end
    eq(a.KOS.S.sound, "pvp"); eq(a.KOS.S.cooldown, 300)
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

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
