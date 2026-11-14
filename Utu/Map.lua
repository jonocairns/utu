-- Utu: world map pins for guildies' help calls and recent KoS sightings.
-- Draws what Core.lua's pin store holds (KOS:MapPins). Nothing else
-- depends on this file, so a /reload straight after the update that
-- added it (which can't load new files) just means no pins yet.
local _, ns = ...
local KOS = ns.KOS

local ICON = {
    seen = KOS.SKULL,
    help = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_6", -- blue square, like the help banner
}
local SIZE = 20

local canvasMap        -- the world map's canvas, once our provider is added
local frames = {}      -- reused pin buttons

local function ago(seconds)
    seconds = math.max(0, math.floor(seconds))
    if seconds < 60 then return seconds .. "s" end
    return math.floor(seconds / 60) .. "m"
end

-- Where (x, y) on map `from` falls on map `to`, or nil if it's off it.
-- Lets a zone's pins show on the continent map too.
local function translate(from, x, y, to)
    if from == to then return x, y end
    if not (C_Map.GetWorldPosFromMapPos and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return nil end
    local ok, continent, world = pcall(C_Map.GetWorldPosFromMapPos, from, CreateVector2D(x, y))
    if not ok or not continent or not world then return nil end
    local ok2, _, pos = pcall(C_Map.GetMapPosFromWorldPos, continent, world, to)
    if not ok2 or not pos then return nil end
    local tx, ty = pos:GetXY()
    if not tx or not ty or tx < 0 or tx > 1 or ty < 0 or ty > 1 then return nil end
    return tx, ty
end
KOS.TranslateMapPos = translate

-- Tooltip lines for a pin, as { text, r, g, b }. Kept apart from the
-- frame so the tests can check it.
function KOS:PinTooltip(p)
    local lines = {}
    local age = ago(GetTime() - p.at)
    local T = self:Lookup(p.key)
    if p.kind == "help" then
        lines[1] = { "HELP! " .. self:Display(p.by), 0.25, 0.75, 1 }
        lines[2] = { "Fighting " .. self:Display(p.name) .. (T and (" (" .. self:BountyTag(T) .. ")") or "")
            .. ", " .. age .. " ago", 1, 1, 1 }
        lines[3] = { "Kill them within 3 minutes for a rescue bonus.", 0.6, 0.6, 0.6 }
    else
        lines[1] = { self:Display(p.name) .. (T and (" (" .. self:BountyTag(T) .. ")") or ""), 1, 0.38, 0.38 }
        local who = (p.by == self:MyName()) and "you" or self:Display(p.by)
        lines[2] = { "Seen near here by " .. who .. ", " .. age .. " ago", 1, 1, 1 }
    end
    return lines
end

local function showTip(self)
    if not self.pin then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    for _, l in ipairs(KOS:PinTooltip(self.pin)) do GameTooltip:AddLine(l[1], l[2], l[3], l[4], true) end
    GameTooltip:Show()
end

-- The map's own pins (and in Classic the map art itself) sit at frame
-- levels 2000-9000, set absolutely, not relative to the canvas. Go just
-- under the player and party arrows, so your own arrow stays on top, or
-- above everything if the map has no layer for them.
local function pinLevel(canvas)
    local m = canvasMap.GetPinFrameLevelsManager and canvasMap:GetPinFrameLevelsManager()
    local function level(kind, index)
        if not (m and m.GetValidFrameLevel) then return nil end
        local ok, v = pcall(m.GetValidFrameLevel, m, kind, index)
        return ok and tonumber(v) or nil
    end
    local arrows = type(m) == "table" and type(m.definitions) == "table" and m.definitions.PIN_FRAME_LEVEL_GROUP_MEMBER
        and level("PIN_FRAME_LEVEL_GROUP_MEMBER")
    if arrows then return arrows - 1 end
    local top = level("PIN_FRAME_LEVEL_TOPMOST", 1e6) or (canvas:GetFrameLevel() + 3000)
    return math.min(top + 1, 9000)
end

local function pinFrame(i, canvas, level)
    local b = frames[i]
    if not b then
        b = CreateFrame("Button", nil, canvas)
        b:SetSize(SIZE, SIZE)
        b.icon = b:CreateTexture(nil, "OVERLAY")
        b.icon:SetAllPoints()
        b:SetScript("OnEnter", showTip)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        frames[i] = b
    end
    b:SetFrameLevel(level)
    return b
end

local function hideAll()
    for _, b in ipairs(frames) do b:Hide(); b.pin = nil end
    KOS.mapPinsShown = 0 -- for the tests
end

local function draw()
    hideAll()
    if not canvasMap or not KOS.S.mapPins then return end
    local mapID = canvasMap.GetMapID and canvasMap:GetMapID()
    local canvas = canvasMap.GetCanvas and canvasMap:GetCanvas()
    if not mapID or not canvas then return end
    -- keep pins the same size on screen however far the map is zoomed
    local scale = 1 / ((canvasMap.GetCanvasScale and canvasMap:GetCanvasScale()) or 1)
    local w, h = canvas:GetWidth(), canvas:GetHeight()
    local now, n, level = GetTime(), 0, pinLevel(canvas)
    KOS.mapPinLevel = level -- for the tests
    for _, p in ipairs(KOS:MapPins()) do
        local x, y = translate(p.map, p.x, p.y, mapID)
        if x then
            n = n + 1
            local b = pinFrame(n, canvas, level)
            b.pin = p
            b.icon:SetTexture(ICON[p.kind])
            b:SetScale(scale)
            b:ClearAllPoints()
            b:SetPoint("CENTER", canvas, "TOPLEFT", x * w / scale, -y * h / scale)
            -- fade as the pin gets old
            b:SetAlpha(1 - 0.6 * math.min(1, (now - p.at) / KOS.PIN_SECONDS[p.kind]))
            b:Show()
        end
    end
    KOS.mapPinsShown = n
end

function KOS:RefreshMapPins()
    if canvasMap and WorldMapFrame and WorldMapFrame:IsShown() then draw() end
end

-- A map canvas data provider: the map calls it when it opens, changes
-- zone or zooms. Built on Blizzard's mixin when there is one.
local function addProvider()
    if canvasMap or not (WorldMapFrame and WorldMapFrame.AddDataProvider) then return canvasMap ~= nil end
    local base = MapCanvasDataProviderMixin
    local provider = (base and CreateFromMixins) and CreateFromMixins(base) or {}
    function provider:OnAdded(map)
        if base and base.OnAdded then base.OnAdded(self, map) end
        canvasMap = map
    end
    function provider:OnRemoved(map)
        if base and base.OnRemoved then base.OnRemoved(self, map) end
        hideAll()
        canvasMap = nil
    end
    function provider:RemoveAllData() hideAll() end
    function provider:RefreshAllData() draw() end
    function provider:OnMapChanged() draw() end
    function provider:OnCanvasScaleChanged() draw() end
    local ok, err = pcall(WorldMapFrame.AddDataProvider, WorldMapFrame, provider)
    if not ok then
        if KOS.RecordError then KOS:RecordError("map pins", err) end
        return false
    end
    -- redraw now and then while the map is open, so pins fade and expire
    local ticker = CreateFrame("Frame", nil, WorldMapFrame)
    local acc = 0
    ticker:SetScript("OnUpdate", function(_, dt)
        acc = acc + dt
        if acc >= 5 then acc = 0; draw() end
    end)
    return true
end

-- The world map is load-on-demand on some clients.
KOS:On("PLAYER_LOGIN", function() addProvider() end)
KOS:On("ADDON_LOADED", function(name)
    if name == "Blizzard_WorldMap" then addProvider() end
end)
