--------------------------------------------------------------------------------
-- MaelstromForever
-- Tracks Maelstrom Weapon (up to 5 stacks) for Shamans in WoW Forever and shows
-- it as a glowing, storm-themed HUD near the bottom of the screen.
--
-- Slash commands: /msf  (or /maelstrom)
--------------------------------------------------------------------------------
local ADDON_NAME = ...

local _, playerClass = UnitClass("player")
if playerClass ~= "SHAMAN" then return end

local min, max, abs, sin = math.min, math.max, math.abs, math.sin

-- Forever uses Midnight's restricted API: some aura fields can be "secret" values
-- that must not be compared or used in arithmetic. Maelstrom Weapon is allowlisted
-- by Blizzard, but we guard every read anyway.
local IsSecret = issecretvalue or function() return false end

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------
local MAX_STACKS = 5

-- Known Maelstrom Weapon buff spell IDs (retail / WotLK / Season of Discovery).
-- Detection also falls back to the buff NAME, and you can add an ID in-game with
-- "/msf id <spellID>" if Forever uses a different one ("/msf debug" lists your buffs).
local KNOWN_IDS = { 344179, 53817, 408505 }

local TEX_STAR  = "Interface\\Cooldown\\star4"
local TEX_PING  = "Interface\\Cooldown\\ping4"
local TEX_RING  = "Interface\\Buttons\\UI-ActionButton-Border"
local TEX_WHITE = "Interface\\Buttons\\WHITE8X8"
local TEX_MASK  = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local TEX_BOLT  = "Interface\\Icons\\Spell_Nature_Lightning"

local ORB      = 34     -- orb diameter
local ORB_STEP = 48     -- distance between orb centres
local ORB_Y    = 8      -- vertical offset of the orb row from frame centre

-- Colour per stack count: shaman blue -> electric cyan -> white-gold overcharge.
local TIER = {
    [0] = { 0.00, 0.45, 0.87 },
    [1] = { 0.00, 0.50, 0.95 },
    [2] = { 0.05, 0.62, 1.00 },
    [3] = { 0.20, 0.78, 1.00 },
    [4] = { 0.45, 0.90, 1.00 },
    [5] = { 1.00, 0.88, 0.45 },
}

local DEFAULTS = {
    scale    = 1,
    point    = "BOTTOM",
    relPoint = "BOTTOM",
    x        = 0,
    y        = 190,
    always   = false,
    extraIDs = {},
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local db
local state = { stacks = 0, visible = false, unlocked = false }
local f                 -- main frame
local ui, orbs = {}, {}
local IDS, NAMES = {}, { ["Maelstrom Weapon"] = true }
local warnedScanError = false

local function Say(msg)
    print("|cff0099ffMaelstromForever|r: " .. tostring(msg))
end

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
    if GetSpellInfo then return (GetSpellInfo(id)) end
end

--------------------------------------------------------------------------------
-- Saved variables
--------------------------------------------------------------------------------
local function InitDB()
    MaelstromForeverDB = MaelstromForeverDB or {}
    db = MaelstromForeverDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then
            if type(v) == "table" then db[k] = CopyTable(v) else db[k] = v end
        end
    end
end

local function BuildLookup()
    for _, id in ipairs(KNOWN_IDS) do
        IDS[id] = true
        local n = SpellName(id)
        if n then NAMES[n] = true end        -- picks up the localized name
    end
    for id in pairs(db.extraIDs) do IDS[id] = true end
end

--------------------------------------------------------------------------------
-- Aura scanning
--------------------------------------------------------------------------------
local function Matches(aura)
    local id, name = aura.spellId, aura.name
    if id and not IsSecret(id) and IDS[id] then return true end
    if name and not IsSecret(name) and NAMES[name] then return true end
    return false
end

local function ScanStacks()
    local get = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if not get then return 0 end
    state.unreadable = false
    for i = 1, 255 do
        local aura = get("player", i, "HELPFUL")
        if not aura then break end
        if Matches(aura) then
            local n = aura.applications
            if IsSecret(n) then
                state.unreadable = true
                return 0
            end
            state.unreadable = false
            if not n or n < 1 then n = 1 end      -- non-stacking aura = 1
            return n
        end
    end
    return 0
end

--------------------------------------------------------------------------------
-- UI helpers
--------------------------------------------------------------------------------
-- A circular, tintable texture (white square + circle mask).
local function Circle(parent, layer, sub, size, r, g, b, a)
    local t = parent:CreateTexture(nil, layer, nil, sub)
    t:SetSize(size, size)
    t:SetTexture(TEX_WHITE)
    t:SetVertexColor(r, g, b, a or 1)
    local m = parent:CreateMaskTexture()
    m:SetTexture(TEX_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    m:SetAllPoints(t)
    t:AddMaskTexture(m)
    return t
end

local function Additive(parent, layer, sub, texture, w, h)
    local t = parent:CreateTexture(nil, layer, nil, sub)
    t:SetTexture(texture)
    t:SetBlendMode("ADD")
    t:SetSize(w, h or w)
    t:SetAlpha(0)
    return t
end

--------------------------------------------------------------------------------
-- UI construction
--------------------------------------------------------------------------------
local function BuildUI()
    f = CreateFrame("Frame", "MaelstromForeverFrame", UIParent, "BackdropTemplate")
    f:SetSize(400, 96)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")
    f:SetScale(db.scale)
    f:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
    f:SetAlpha(0)
    f:Hide()

    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets   = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0.02, 0.05, 0.10, 0.80)
    f:SetBackdropBorderColor(0.35, 0.50, 0.70, 1)

    -- Rising storm-glow along the bottom of the panel.
    ui.glow = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    ui.glow:SetTexture(TEX_WHITE)
    ui.glow:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 4, 4)
    ui.glow:SetPoint("TOPRIGHT", f, "RIGHT", -4, 0)
    ui.glow:SetBlendMode("ADD")
    ui.glow:SetAlpha(0)

    -- Crackling edge lines (top and bottom).
    ui.lines = {}
    for _, side in ipairs({ "TOP", "BOTTOM" }) do
        local l = f:CreateTexture(nil, "BORDER")
        l:SetTexture(TEX_WHITE)
        l:SetBlendMode("ADD")
        l:SetHeight(2)
        local y = (side == "TOP") and -3 or 3
        l:SetPoint(side .. "LEFT", f, side .. "LEFT", 12, y)
        l:SetPoint(side .. "RIGHT", f, side .. "RIGHT", -12, y)
        l:SetAlpha(0)
        ui.lines[#ui.lines + 1] = l
    end

    -- Lightning-bolt medallion on the left.
    local iconX, iconY = -155, 4
    ui.iconRing = Circle(f, "BACKGROUND", 2, 66, 0.45, 0.32, 0.16)
    ui.iconRing:SetPoint("CENTER", f, "CENTER", iconX, iconY)
    ui.iconBack = Circle(f, "BACKGROUND", 3, 58, 0.02, 0.05, 0.10, 1)
    ui.iconBack:SetPoint("CENTER", f, "CENTER", iconX, iconY)

    ui.icon = f:CreateTexture(nil, "ARTWORK", nil, 2)
    ui.icon:SetSize(52, 52)
    ui.icon:SetPoint("CENTER", f, "CENTER", iconX, iconY)
    ui.icon:SetTexture(TEX_BOLT)
    ui.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local im = f:CreateMaskTexture()
    im:SetTexture(TEX_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    im:SetAllPoints(ui.icon)
    ui.icon:AddMaskTexture(im)
    ui.icon:SetDesaturated(true)
    ui.icon:SetVertexColor(0.5, 0.6, 0.8)

    ui.iconGlow = Additive(f, "OVERLAY", 1, TEX_RING, 108)
    ui.iconGlow:SetPoint("CENTER", f, "CENTER", iconX, iconY)
    ui.iconSpin = Additive(f, "OVERLAY", 2, TEX_STAR, 110)
    ui.iconSpin:SetPoint("CENTER", f, "CENTER", iconX, iconY)
    ui.iconFlash = Additive(f, "OVERLAY", 3, TEX_STAR, 60)
    ui.iconFlash:SetPoint("CENTER", f, "CENTER", iconX, iconY)

    -- The five Maelstrom orbs.
    for i = 1, MAX_STACKS do
        local o = { level = 0, pop = 0 }
        local x = (i - 3) * ORB_STEP
        o.ring = Circle(f, "BACKGROUND", 3, ORB + 8, 0.45, 0.32, 0.16)
        o.socket = Circle(f, "BACKGROUND", 4, ORB, 0.02, 0.04, 0.08, 0.95)
        o.fill = Circle(f, "ARTWORK", 1, ORB - 6, 0.0, 0.55, 1.0)
        o.fill:SetAlpha(0)
        o.core = Additive(f, "OVERLAY", 1, TEX_STAR, ORB * 1.6)
        for _, t in ipairs({ o.ring, o.socket, o.fill, o.core }) do
            t:SetPoint("CENTER", f, "CENTER", x, ORB_Y)
        end
        orbs[i] = o
    end

    -- One-shot effects: overcharge burst and the "spent" discharge.
    ui.burst = Additive(f, "OVERLAY", 5, TEX_STAR, 120)
    ui.burst:SetPoint("CENTER", f, "CENTER", 0, ORB_Y)
    ui.shock = Additive(f, "OVERLAY", 4, TEX_PING, 60)
    ui.shock:SetPoint("CENTER", f, "CENTER", 0, ORB_Y)

    -- Stack counter on the right.
    ui.num = f:CreateFontString(nil, "OVERLAY")
    ui.num:SetFont(STANDARD_TEXT_FONT, 40, "THICKOUTLINE")
    ui.num:SetPoint("CENTER", f, "CENTER", 150, ORB_Y)
    ui.num:SetDrawLayer("OVERLAY", 6)

    -- Caption under the orbs.
    ui.label = f:CreateFontString(nil, "OVERLAY")
    ui.label:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    ui.label:SetPoint("BOTTOM", f, "BOTTOM", 0, 9)
    ui.label:SetDrawLayer("OVERLAY", 6)
    ui.label:SetText("MAELSTROM WEAPON")

    -- Hint shown while the frame is unlocked.
    ui.hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ui.hint:SetPoint("BOTTOM", f, "TOP", 0, 4)
    ui.hint:SetText("Drag to move  -  /msf lock when done")
    ui.hint:Hide()

    f:SetScript("OnDragStart", function(self)
        if state.unlocked then self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        db.point, db.relPoint, db.x, db.y = p, rp, x, y
    end)
end

--------------------------------------------------------------------------------
-- Theming (colour changes whenever the stack count changes)
--------------------------------------------------------------------------------
local function ApplyTheme(n)
    local c = TIER[min(n, MAX_STACKS)]
    local r, g, b = c[1], c[2], c[3]
    local full = n >= MAX_STACKS

    for _, o in ipairs(orbs) do
        o.fill:SetVertexColor(r, g, b)
        o.core:SetVertexColor(full and 1 or r, full and 0.95 or g, full and 0.75 or b)
        o.ring:SetVertexColor(full and 0.95 or 0.45, full and 0.75 or 0.32, full and 0.25 or 0.16)
    end

    ui.glow:SetGradient("VERTICAL", CreateColor(r, g, b, 0.9), CreateColor(r, g, b, 0))
    for _, l in ipairs(ui.lines) do l:SetVertexColor(r, g, b) end
    ui.iconGlow:SetVertexColor(r, g, b)
    ui.iconSpin:SetVertexColor(r, g, b)
    ui.iconRing:SetVertexColor(full and 0.95 or 0.45, full and 0.75 or 0.32, full and 0.25 or 0.16)
    ui.burst:SetVertexColor(1, 0.9, 0.5)
    ui.shock:SetVertexColor(r, g, b)
    ui.iconFlash:SetVertexColor(0.7, 0.9, 1)

    if n > 0 then
        ui.icon:SetDesaturated(false)
        ui.icon:SetVertexColor(1, 1, 1)
    else
        ui.icon:SetDesaturated(true)
        ui.icon:SetVertexColor(0.5, 0.6, 0.8)
    end

    ui.num:SetTextColor(r, g, b)
    ui.num:SetText(n > 0 and n or "")
    if full then
        ui.label:SetText("UNLEASH THE STORM")
        ui.label:SetTextColor(1, 0.85, 0.4)
    else
        ui.label:SetText("MAELSTROM WEAPON")
        ui.label:SetTextColor(0.35, 0.65, 1)
    end
end

--------------------------------------------------------------------------------
-- Per-frame animation
--------------------------------------------------------------------------------
local function OnUpdate(self, dt)
    local t = GetTime()
    local n = state.stacks
    local lit = min(n, MAX_STACKS)
    local full = n >= MAX_STACKS
    local frac = lit / MAX_STACKS
    local speed = full and 9 or (2 + n * 1.1)
    local pulse = 0.5 + 0.5 * sin(t * speed)

    -- Fade in / out.
    local target = state.visible and 1 or 0
    local a = self:GetAlpha()
    a = a + (target - a) * min(1, dt * 9)
    if abs(a - target) < 0.02 then a = target end
    self:SetAlpha(a)
    if a == 0 and target == 0 then self:Hide() return end

    local c = TIER[min(n, MAX_STACKS)]

    -- Ambient glow scales with stacks.
    ui.glow:SetAlpha(frac * (0.30 + 0.35 * pulse))
    for _, l in ipairs(ui.lines) do l:SetAlpha(lit > 0 and (0.25 + 0.6 * pulse) * (0.3 + 0.7 * frac) or 0) end
    if lit > 0 then
        self:SetBackdropBorderColor(
            0.35 + (c[1] - 0.35) * frac,
            0.50 + (c[2] - 0.50) * frac,
            0.70 + (c[3] - 0.70) * frac,
            0.6 + 0.4 * pulse)
    else
        self:SetBackdropBorderColor(0.35, 0.50, 0.70, 1)
    end

    -- Medallion.
    ui.iconGlow:SetAlpha(lit > 0 and (0.25 + 0.5 * pulse) * (0.4 + 0.6 * frac) or 0)
    ui.iconSpin:SetRotation(t * (0.6 + lit * 0.6))
    ui.iconSpin:SetAlpha(lit > 0 and (0.15 + 0.35 * pulse) * frac or 0)

    -- Orbs.
    for i, o in ipairs(orbs) do
        local want = (i <= lit) and 1 or 0
        o.level = o.level + (want - o.level) * min(1, dt * 14)
        o.pop = max(0, o.pop - dt * 2.5)
        o.fill:SetAlpha(o.level)
        o.core:SetAlpha(min(1, o.level * (0.35 + 0.40 * pulse) + o.pop))
        local s = ORB * (1.6 + 0.3 * pulse * o.level + 0.9 * o.pop)
        o.core:SetSize(s, s)
    end

    -- Overcharge burst (reaching 5 stacks).
    if state.burstT then
        state.burstT = state.burstT + dt
        local p = state.burstT / 0.7
        if p >= 1 then
            state.burstT = nil
            ui.burst:SetAlpha(0)
            ui.shock:SetAlpha(0)
        else
            local s = 120 + 200 * p
            ui.burst:SetSize(s, s)
            ui.burst:SetAlpha((1 - p) ^ 2)
            local ss = 60 + 320 * p
            ui.shock:SetSize(ss, ss * 0.45)
            ui.shock:SetAlpha(1 - p)
        end
    end

    -- Discharge flash on the medallion (stacks spent).
    if state.flashT then
        state.flashT = state.flashT + dt
        local p = state.flashT / 0.4
        if p >= 1 then
            state.flashT = nil
            ui.iconFlash:SetAlpha(0)
        else
            local s = 50 + 110 * p
            ui.iconFlash:SetSize(s, s)
            ui.iconFlash:SetAlpha(1 - p)
        end
    end

    if full then
        ui.label:SetAlpha(0.6 + 0.4 * pulse)
    else
        ui.label:SetAlpha(lit > 0 and 0.9 or 0.55)
    end
end

--------------------------------------------------------------------------------
-- Refresh: read stacks, update visuals/effects
--------------------------------------------------------------------------------
local function Refresh()
    if not f then return end

    local n
    if state.test then
        n = state.test
    elseif state.unlocked then
        n = 3
    else
        local ok, res = pcall(ScanStacks)
        if ok then
            n = res
        else
            n = 0
            if not warnedScanError then
                warnedScanError = true
                Say("aura scan error: " .. tostring(res))
            end
        end
    end

    local prev = state.stacks
    state.stacks = n

    if n ~= prev then
        if n > prev then
            for i = max(prev + 1, 1), min(n, MAX_STACKS) do orbs[i].pop = 1 end
        end
        if n >= MAX_STACKS and prev < MAX_STACKS then state.burstT = 0 end
        if n == 0 and prev > 0 then state.flashT = 0 end
        ApplyTheme(n)
    end

    state.visible = (n > 0) or db.always or state.unlocked
    if state.visible then f:Show() end
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------
local function StartTest()
    if state.testTicker then state.testTicker:Cancel() end
    local seq = { 1, 2, 3, 4, 5, 5, 0, 0 }
    local idx = 0
    state.test = 0
    state.testTicker = C_Timer.NewTicker(0.7, function()
        idx = idx + 1
        state.test = seq[(idx - 1) % #seq + 1]
        if idx >= #seq * 2 then
            state.test = nil
            state.testTicker = nil
        end
        Refresh()
    end, #seq * 2)
    Say("running a demo (builds to 5 stacks, then spends).")
end

local function DebugBuffs()
    local get = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if not get then Say("C_UnitAuras is not available.") return end
    Say("your current buffs (tracked one is marked):")
    local count = 0
    for i = 1, 255 do
        local aura = get("player", i, "HELPFUL")
        if not aura then break end
        count = count + 1
        local id, name, apps = aura.spellId, aura.name, aura.applications
        local sid   = IsSecret(id)   and "hidden" or tostring(id)
        local sname = IsSecret(name) and "<hidden>" or tostring(name)
        local sapps = IsSecret(apps) and "?" or tostring(apps)
        print(("  %s  [%s]  x%s%s"):format(sname, sid, sapps, Matches(aura) and "   <-- tracked" or ""))
    end
    if count == 0 then Say("no buffs found. Get some Maelstrom Weapon stacks first, then run this again.") end
    if state.unreadable then Say("the stack count is hidden by Blizzard's addon restrictions.") end
end

local function HandleSlash(msg)
    local cmd, arg = (msg or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()

    if cmd == "unlock" then
        state.unlocked = true
        f:EnableMouse(true)
        ui.hint:Show()
        Refresh()
        Say("unlocked. Drag the frame, then /msf lock.")
    elseif cmd == "lock" then
        state.unlocked = false
        f:EnableMouse(false)
        ui.hint:Hide()
        state.stacks = -1          -- force a theme/state refresh
        Refresh()
        Say("locked.")
    elseif cmd == "test" then
        StartTest()
    elseif cmd == "scale" then
        local s = tonumber(arg)
        if s and s >= 0.5 and s <= 2.5 then
            db.scale = s
            f:SetScale(s)
            Say("scale set to " .. s)
        else
            Say("usage: /msf scale 0.5 - 2.5   (current: " .. db.scale .. ")")
        end
    elseif cmd == "always" then
        db.always = not db.always
        Refresh()
        Say(db.always and "always showing the (empty) tracker." or "only showing while you have stacks.")
    elseif cmd == "reset" then
        db.point, db.relPoint, db.x, db.y, db.scale = DEFAULTS.point, DEFAULTS.relPoint, DEFAULTS.x, DEFAULTS.y, DEFAULTS.scale
        f:ClearAllPoints()
        f:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
        f:SetScale(db.scale)
        Say("position and scale reset.")
    elseif cmd == "id" then
        local id = tonumber(arg)
        if id then
            db.extraIDs[id] = true
            IDS[id] = true
            Refresh()
            Say("now also tracking spell ID " .. id)
        else
            Say("usage: /msf id <spellID>   (find it with /msf debug)")
        end
    elseif cmd == "debug" then
        DebugBuffs()
    else
        Say("commands:")
        print("  /msf unlock | lock   - move the tracker")
        print("  /msf test            - play a demo of 0-5 stacks")
        print("  /msf scale <0.5-2.5> - resize")
        print("  /msf always          - toggle showing the empty tracker")
        print("  /msf reset           - reset position and scale")
        print("  /msf debug           - list your buffs / tracked buff")
        print("  /msf id <spellID>    - also track a spell ID")
    end
end

SLASH_MAELSTROMFOREVER1 = "/msf"
SLASH_MAELSTROMFOREVER2 = "/maelstrom"
SlashCmdList["MAELSTROMFOREVER"] = function(msg)
    if not f then return end
    HandleSlash(msg)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        self:UnregisterEvent("ADDON_LOADED")
        InitDB()
        self:RegisterEvent("PLAYER_LOGIN")

    elseif event == "PLAYER_LOGIN" then
        BuildLookup()
        BuildUI()
        f:SetScript("OnUpdate", OnUpdate)
        ApplyTheme(0)
        self:RegisterUnitEvent("UNIT_AURA", "player")
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("PLAYER_REGEN_ENABLED")
        self:RegisterEvent("PLAYER_REGEN_DISABLED")
        Refresh()

    else
        Refresh()
    end
end)
