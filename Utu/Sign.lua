-- Signing my own marks and claims, so my client can recognise them later.
--
-- Full-list syncs relay everyone's items and can't prove who wrote one, so
-- the forgery check (KOS:Ledger) compares items in my name with what this
-- client recorded me doing. That record can miss genuine actions: a game
-- crash loses the session's saved data. So each mark, removal and claim I
-- make carries a tag: an HMAC-SHA256 of its details under a secret key
-- saved on this computer. The tag travels with the item through syncs;
-- other clients just carry it. When an item in my name comes back that my
-- record doesn't know, a valid tag shows I really made it. Without the key
-- a forger can't make a valid tag, and changing any signed detail breaks it.
--
-- Only actions created here are signed (Mark, Unmark, RecordClaim), never
-- merged or seeded items. The signed text (version "1") is frozen: change
-- it only with a new version character.

local _, ns = ...
local KOS = ns.KOS

------------------------------------------------------------------------
-- SHA-256 and HMAC on 32-bit words held in Lua numbers. Uses the game's
-- bit library when it passes a self-test, else 4-bit lookup tables.
------------------------------------------------------------------------

local MOD = 4294967296
local floor = math.floor

local AND, XOR = {}, {}
for i = 0, 15 do
    for j = 0, 15 do
        local a, b, ra, rx, p = i, j, 0, 0, 1
        for _ = 1, 4 do
            local x, y = a % 2, b % 2
            if x == 1 and y == 1 then ra = ra + p end
            if x ~= y then rx = rx + p end
            a, b, p = (a - x) / 2, (b - y) / 2, p * 2
        end
        AND[i * 16 + j], XOR[i * 16 + j] = ra, rx
    end
end
local function nibbles(t, a, b)
    local r, p = 0, 1
    for _ = 1, 8 do
        local x, y = a % 16, b % 16
        r = r + t[x * 16 + y] * p
        a, b, p = (a - x) / 16, (b - y) / 16, p * 16
    end
    return r
end
local band = function(a, b) return nibbles(AND, a, b) end
local bxor = function(a, b) return nibbles(XOR, a, b) end

local function rrot(x, n)
    local lo = x % 2 ^ n
    return (x - lo) / 2 ^ n + lo * 2 ^ (32 - n)
end
local function shr(x, n) return floor(x / 2 ^ n) end
local function bnot(x) return MOD - 1 - x end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- SHA-256 of a byte string, as a 32-byte string.
local function sha256(msg)
    local len = #msg
    local bits = len * 8
    local hi = floor(bits / MOD)
    local lo = bits % MOD
    msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64)
        .. string.char(floor(hi / 16777216) % 256, floor(hi / 65536) % 256, floor(hi / 256) % 256, hi % 256,
            floor(lo / 16777216) % 256, floor(lo / 65536) % 256, floor(lo / 256) % 256, lo % 256)
    local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    local w = {}
    for i = 1, #msg, 64 do
        for j = 0, 15 do
            local a, b, c, d = msg:byte(i + j * 4, i + j * 4 + 3)
            w[j] = ((a * 256 + b) * 256 + c) * 256 + d
        end
        for j = 16, 63 do
            local x, y = w[j - 15], w[j - 2]
            local s0 = bxor(bxor(rrot(x, 7), rrot(x, 18)), shr(x, 3))
            local s1 = bxor(bxor(rrot(y, 17), rrot(y, 19)), shr(y, 10))
            w[j] = (w[j - 16] + s0 + w[j - 7] + s1) % MOD
        end
        local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
        for j = 0, 63 do
            local S1 = bxor(bxor(rrot(e, 6), rrot(e, 11)), rrot(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = (h + S1 + ch + K[j + 1] + w[j]) % MOD
            local S0 = bxor(bxor(rrot(a, 2), rrot(a, 13)), rrot(a, 22))
            local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
            local t2 = (S0 + maj) % MOD
            h, g, f, e, d, c, b, a = g, f, e, (d + t1) % MOD, c, b, a, (t1 + t2) % MOD
        end
        H[1], H[2], H[3], H[4] = (H[1] + a) % MOD, (H[2] + b) % MOD, (H[3] + c) % MOD, (H[4] + d) % MOD
        H[5], H[6], H[7], H[8] = (H[5] + e) % MOD, (H[6] + f) % MOD, (H[7] + g) % MOD, (H[8] + h) % MOD
    end
    local out = {}
    for i = 1, 8 do
        local x = H[i]
        out[i] = string.char(floor(x / 16777216) % 256, floor(x / 65536) % 256, floor(x / 256) % 256, x % 256)
    end
    return table.concat(out)
end

local function hmac(key, msg)
    if #key > 64 then key = sha256(key) end
    key = key .. string.rep("\0", 64 - #key)
    local ipad, opad = {}, {}
    for i = 1, 64 do
        local k = key:byte(i)
        ipad[i] = string.char(bxor(k, 0x36))
        opad[i] = string.char(bxor(k, 0x5c))
    end
    return sha256(table.concat(opad) .. sha256(table.concat(ipad) .. msg))
end

local function hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
local function unhex(h)
    return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
end

KOS.SHA256 = function(msg) return hex(sha256(msg)) end
KOS.HMAC = function(key, msg) return hex(hmac(key, msg)) end

-- Prefer the game's bit library (much faster), but only if it gives the
-- right answer: builds differ in how they treat numbers above 2^31.
do
    local lib = bit
    if type(lib) == "table" and lib.band and lib.bxor then
        local fastAnd = function(a, b) return lib.band(a, b) % MOD end
        local fastXor = function(a, b) return lib.bxor(a, b) % MOD end
        local slowAnd, slowXor = band, bxor
        band, bxor = fastAnd, fastXor
        local ok, digest = pcall(KOS.HMAC, "Jefe", "what do ya want for nothing?")
        if not ok or digest ~= "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843" then
            band, bxor = slowAnd, slowXor
        end
    end
end

------------------------------------------------------------------------
-- The key: 32 random bytes, made once per computer (account-wide saved
-- data) and never sent anywhere. The game has no secure random source,
-- so it's a hash of many timing readings, random numbers and memory
-- addresses: unguessable from outside this client.
------------------------------------------------------------------------

local function freshKey()
    local parts = {}
    for _ = 1, 48 do
        parts[#parts + 1] = tostring(debugprofilestop and debugprofilestop() or 0)
        parts[#parts + 1] = tostring(math.random(0, 2147483646))
        parts[#parts + 1] = tostring({})
    end
    parts[#parts + 1] = table.concat({ tostring(GetTime and GetTime()), tostring(time()),
        tostring(GetServerTime and GetServerTime()), tostring(UnitGUID and UnitGUID("player")),
        tostring(collectgarbage and collectgarbage("count")) }, "|")
    return hex(sha256(table.concat(parts, "|")))
end

local keyCache
-- Keys this client accepts, the first one signs. Made on first use.
function KOS:SigKeys()
    local db = self.db
    if not db then return nil end
    if keyCache and db.signing == keyCache.of then return keyCache end
    if type(db.signing) ~= "table" or type(db.signing.keys) ~= "table" then db.signing = { keys = {} } end
    local keys = {}
    for _, h in ipairs(db.signing.keys) do
        if type(h) == "string" and #h == 64 and not h:find("%X") then keys[#keys + 1] = unhex(h) end
    end
    if #keys == 0 then
        local h = freshKey()
        db.signing.keys = { h }
        keys[1] = unhex(h)
    end
    keys.of = db.signing
    keyCache = keys
    return keys
end

------------------------------------------------------------------------
-- What gets signed. Keys (lowercase names) rather than display names, so
-- capitalisation repairs don't break tags. Notes are signed as sent: the
-- sync layer drops the tag rather than trim a signed note.
------------------------------------------------------------------------

-- listKey: the guild list it belongs to, so it can't be replayed into another.
function KOS.VoteSigText(listKey, targetKey, byKey, t, del, note)
    return table.concat({ "utu1", listKey, "v", targetKey, byKey, tostring(t), del and "1" or "0",
        del and "" or (note or "") }, "|")
end

function KOS.KillSigText(listKey, byKey, targetKey, t, v)
    return table.concat({ "utu1", listKey, "k", byKey, targetKey, tostring(t), tostring(v) }, "|")
end

local function tag(key, text) return "1" .. hex(hmac(key, text)):sub(1, 16) end

local function valid(sig, text, keys)
    if type(sig) ~= "string" or #sig ~= 17 or not keys then return false end
    for _, key in ipairs(keys) do
        if tag(key, text) == sig then return true end
    end
    return false
end

-- A claim's value as it's stored and synced.
local function claimValue(v) return math.max(0, math.min(KOS.MAX_CLAIM, math.floor(tonumber(v) or 0))) end

-- Tag for my vote v on targetKey (nil if there's no saved data yet).
function KOS:SignVote(targetKey, v)
    local keys, lk = self:SigKeys(), self:ListKey()
    if not keys or not lk then return nil end
    return tag(keys[1], self.VoteSigText(lk, targetKey, self:Canonical(v.by), v.t, v.del, v.note))
end

function KOS:SignKill(k)
    local keys, lk = self:SigKeys(), self:ListKey()
    if not keys or not lk then return nil end
    return tag(keys[1], self.KillSigText(lk, self:Canonical(k.by), self:Canonical(k.target), k.t, claimValue(k.v)))
end

-- Did this client sign the synced vote / claim it, for the current list?
-- (it = a decoded item)
function KOS:VerifyVote(it)
    local lk = self:ListKey()
    if not it.sig or not lk then return false end
    return valid(it.sig, self.VoteSigText(lk, it.key, self:Canonical(it.by), it.t, it.del, it.note), self:SigKeys())
end

function KOS:VerifyKill(it)
    local lk = self:ListKey()
    if not it.sig or not lk then return false end
    return valid(it.sig, self.KillSigText(lk, self:Canonical(it.by), self:Canonical(it.target), it.t, claimValue(it.v)),
        self:SigKeys())
end

-- A tag as it appears in a message: "1" and 16 hex digits, else nil.
function KOS.CleanSig(s)
    return (type(s) == "string" and #s == 17 and s:match("^1%x+$")) and s or nil
end
