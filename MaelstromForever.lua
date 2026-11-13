--------------------------------------------------------------------------------
-- MaelstromForever
-- Tracks Maelstrom Weapon (up to 5 stacks) for Shamans in WoW Forever and shows
-- it as a glowing, storm-themed HUD near the bottom of the screen.
--
-- Combat note: Forever uses Midnight's "secret value" rules. In combat the stack
-- count can be a secret number that addon code may not compare or do math on, but
-- may hand to widgets. So the orbs, the charge bar and the overcharge glow are all
-- StatusBars fed directly with the count; no Lua branching on the value is needed.
--
-- Slash commands: /msf  (or /maelstrom)
--------------------------------------------------------------------------------
local ADDON_NAME = ...

local _, playerClass = UnitClass("player")
if playerClass ~= "SHAMAN" then return end

local min, max, abs, sin = math.min, math.max, math.abs, math.sin
local IsSecret = issecretvalue or function() return false end

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------
local MAX_STACKS = 5

-- Known Maelstrom Weapon buff spell IDs (Forever / retail / WotLK).
-- Add more in game with "/msf id <spellID>"; "/msf debug" shows what is detected.
local KNOWN_IDS = { 408505, 344179, 53817 }

local TEX_STAR  = "Interface\\Cooldown\\star4"
local TEX_PING  = "Interface\\Cooldown\\ping4"
local TEX_RING  = "Interface\\Buttons\\UI-ActionButton-Border"
local TEX_WHITE = "Interface\\Buttons\\WHITE8X8"
local TEX_MASK  = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local TEX_BOLT  = "Interface\\Icons\\Spell_Nature_Lightning"

local ORB      = 34
local ORB_STEP = 48
local ORB_Y    = 8

-- Colour per stack count: shaman blue -> electric cyan -> white-gold overcharge.
local TIER = {
    [0] = { 0.00, 0.45, 0.87 },
    [1] = { 0.00, 0.50, 0.95 },
    [2] = { 0.05, 0.62, 1.00 },
    [3] = { 0.20, 0.78, 1.00 },
    [4] = { 0.45, 0.90, 1.00 },
    [5] = { 1.00, 0.88, 0.45 },
}
local SECRET_TIER = 3   -- colour used while the exact count is hidden

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
-- stacks = effective count used for visuals (a plain number; 3 while hidden)
local state = { stacks = 0, visible = false, unlocked = false, secret = false }
local f, ov
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
        if n then NAMES[n] = true end
    end
    for id in pairs(db.extraIDs) do IDS[id] = true end
end

--------------------------------------------------------------------------------
-- Aura lookup
--------------------------------------------------------------------------------
local function Matches(aura)
    local id, name = aura.spellId, aura.name
    if id and not IsSecret(id) and IDS[id] then return true end
    if name and not IsSecret(name) and NAMES[name] then return true end
    return false
end

-- Direct per-spell queries first (these keep working in combat for allowlisted
-- spells); enumeration is only a last resort and is mostly useful out of combat.
local function FindAura()
    local api = C_UnitAuras
    if not api then return nil end

    if api.GetPlayerAuraBySpellID then
        for id in pairs(IDS) do
            local a = api.GetPlayerAuraBySpellID(id)
            if a then return a end
        end
    end
    if api.GetAuraDataBySpellName then
        for name in pairs(NAMES) do
            local a = api.GetAuraDataBySpellName("player", name, "HELPFUL")
            if a then return a end
        end
    end
    if api.GetAuraDataByIndex then
        for i = 1, 255 do
            local a = api.GetAuraDataByIndex("player", i, "HELPFUL")
            if not a then break end
            if Matches(a) then return a end
        end
    end
    return nil
end

-- returns present(boolean), count (number, or a secret value in combat)
local function ScanStacks()
    local aura = FindAura()
    if not aura then return false, 0 end
    local n = aura.applications
    if IsSecret(n) then return true, n end
    if not n or n < 1 then n = 1 end
    return true, n
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

-- A StatusBar that is "full" when value >= maxv and "empty" when value <= minv.
-- Because the fill is geometric, a secret value can be passed straight to SetValue.
local function MakeBar(parent, w, h, texture, minv, maxv, opts)
    opts = opts or {}
    local bar = CreateFrame("StatusBar", nil, parent)
    if w then bar:SetSize(w, h) end
    bar:SetFrameLevel(parent:GetFrameLevel() + (opts.level or 1))
    bar:SetStatusBarTexture(texture)
    bar:SetMinMaxValues(minv, maxv)
    bar:SetValue(minv)
    local tex = bar:GetStatusBarTexture()
    if opts.additive then tex:SetBlendMode("ADD") end
    if opts.circle then
        local m = bar:CreateMaskTexture()
        m:SetTexture(TEX_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        m:SetAllPoints(bar)
        tex:AddMaskTexture(m)
    end
    return bar
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

    -- Top layer for text and one-shot effects (child frames draw above parent textures).
    ov = CreateFrame("Frame", nil, f)
    ov:SetAllPoints(f)
    ov:SetFrameLevel(f:GetFrameLevel() + 10)

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

    -- Overcharge glow: only fills when the count reaches 5 (min 4, max 5).
    ui.full = MakeBar(f, nil, nil, TEX_WHITE, MAX_STACKS - 1, MAX_STACKS, { additive = true, level = 1 })
    ui.full:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -4)
    ui.full:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 4)
    ui.full:SetStatusBarColor(1, 0.85, 0.35)
    ui.full:SetAlpha(0)

    -- Charge bar along the bottom: fills proportionally to stacks.
    ui.chargeBG = f:CreateTexture(nil, "BACKGROUND", nil, 2)
    ui.chargeBG:SetTexture(TEX_WHITE)
    ui.chargeBG:SetVertexColor(0.02, 0.04, 0.08, 0.9)
    ui.chargeBG:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 5)
    ui.chargeBG:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 5)
    ui.chargeBG:SetHeight(4)
    ui.charge = MakeBar(f, nil, 4, TEX_WHITE, 0, MAX_STACKS, { additive = true, level = 2 })
    ui.charge:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 5)
    ui.charge:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 5)

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

    ui.iconGlow = Additive(ov, "OVERLAY", 1, TEX_RING, 108)
    ui.iconGlow:SetPoint("CENTER", f, "CENTER", iconX, iconY)
    ui.iconSpin = Additive(ov, "OVERLAY", 2, TEX_STAR, 110)
    ui.iconSpin:SetPoint("CENTER", f, "CENTER", iconX, iconY)
    ui.iconFlash = Additive(ov, "OVERLAY", 3, TEX_STAR, 60)
    ui.iconFlash:SetPoint("CENTER", f, "CENTER", iconX, iconY)

    -- The five Maelstrom orbs. Orb i is full when count >= i.
    for i = 1, MAX_STACKS do
        local o = { pop = 0 }
        local x = (i - 3) * ORB_STEP
        o.ring = Circle(f, "BACKGROUND", 3, ORB + 8, 0.45, 0.32, 0.16)
        o.socket = Circle(f, "BACKGROUND", 4, ORB, 0.02, 0.04, 0.08, 0.95)
        o.ring:SetPoint("CENTER", f, "CENTER", x, ORB_Y)
        o.socket:SetPoint("CENTER", f, "CENTER", x, ORB_Y)

        o.fill = MakeBar(f, ORB - 6, ORB - 6, TEX_WHITE, i - 1, i, { circle = true, level = 3 })
        o.fill:SetPoint("CENTER", f, "CENTER", x, ORB_Y)
        o.core = MakeBar(f, ORB * 1.6, ORB * 1.6, TEX_STAR, i - 1, i, { additive = true, level = 4 })
        o.core:SetPoint("CENTER", f, "CENTER", x, ORB_Y)
        orbs[i] = o
    end

    -- One-shot effects: overcharge burst and the "spent" discharge.
    ui.burst = Additive(ov, "OVERLAY", 5, TEX_STAR, 120)
    ui.burst:SetPoint("CENTER", f, "CENTER", 0, ORB_Y)
    ui.shock = Additive(ov, "OVERLAY", 4, TEX_PING, 60)
    ui.shock:SetPoint("CENTER", f, "CENTER", 0, ORB_Y)

    -- Stack counter on the right.
    ui.num = ov:CreateFontString(nil, "OVERLAY")
    ui.num:SetFont(STANDARD_TEXT_FONT, 40, "THICKOUTLINE")
    ui.num:SetPoint("CENTER", f, "CENTER", 150, ORB_Y)

    -- Caption under the orbs.
    ui.label = ov:CreateFontString(nil, "OVERLAY")
    ui.label:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    ui.label:SetPoint("BOTTOM", f, "BOTTOM", 0, 12)
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
-- Theming (colour changes whenever the effective stack count changes)
--------------------------------------------------------------------------------
local function ApplyTheme(n)
    local c = TIER[min(n, MAX_STACKS)]
    local r, g, b = c[1], c[2], c[3]
    local full = n >= MAX_STACKS
    local rr, rg, rb = 0.45, 0.32, 0.16
    if full then rr, rg, rb = 0.95, 0.75, 0.25 end

    for _, o in ipairs(orbs) do
        o.fill:SetStatusBarColor(r, g, b)
        if full then o.core:SetStatusBarColor(1, 0.95, 0.75) else o.core:SetStatusBarColor(r, g, b) end
        o.ring:SetVertexColor(rr, rg, rb)
    end

    ui.charge:SetStatusBarColor(r, g, b)
    for _, l in ipairs(ui.lines) do l:SetVertexColor(r, g, b) end
    ui.iconGlow:SetVertexColor(r, g, b)
    ui.iconSpin:SetVertexColor(r, g, b)
    ui.iconRing:SetVertexColor(rr, rg, rb)
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
    if full then
        ui.label:SetText("UNLEASH THE STORM")
        ui.label:SetTextColor(1, 0.85, 0.4)
    else
        ui.label:SetText("MAELSTROM WEAPON")
        ui.label:SetTextColor(0.35, 0.65, 1)
    end
end

--------------------------------------------------------------------------------
-- Per-frame animation (never touches the raw, possibly secret, count)
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

    -- Ambient effects.
    ui.full:SetAlpha(0.10 + 0.16 * pulse)
    ui.charge:SetAlpha(0.7 + 0.3 * pulse)
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

    -- Orbs (their fill is driven by the StatusBars; we only animate the glow).
    for _, o in ipairs(orbs) do
        o.pop = max(0, o.pop - dt * 2.5)
        o.core:SetAlpha(min(1, 0.35 + 0.40 * pulse + o.pop))
        local s = ORB * (1.6 + 0.3 * pulse + 0.9 * o.pop)
        o.core:SetSize(s, s)
    end

    -- Overcharge burst (reaching 5 stacks; only when the count is readable).
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

    -- Discharge flash on the medallion (stacks spent / buff gone).
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
-- Refresh: read the aura, feed the widgets
--------------------------------------------------------------------------------
local function SetBars(v)
    for _, o in ipairs(orbs) do
        o.fill:SetValue(v)
        o.core:SetValue(v)
    end
    ui.charge:SetValue(v)
    ui.full:SetValue(v)
end

local function Refresh()
    if not f then return end

    local present, count
    if state.test then
        present, count = state.test > 0, state.test
    elseif state.unlocked then
        present, count = true, 3
    else
        local ok, p, c = pcall(ScanStacks)
        if ok then
            present, count = p, c
        else
            present, count = false, 0
            if not warnedScanError then
                warnedScanError = true
                Say("aura scan error: " .. tostring(p))
            end
        end
    end

    local secret = present and IsSecret(count) or false
    state.secret = secret

    -- Effective count for visuals/effects: a plain number we are allowed to branch on.
    local n
    if secret then n = SECRET_TIER elseif present then n = count else n = 0 end

    -- Widgets take the real value (secret or not) directly.
    SetBars(present and count or 0)

    if secret then
        -- Hidden count: let the FontString format it for us.
        local ok = pcall(ui.num.SetFormattedText, ui.num, "%d", count)
        if not ok then ui.num:SetText("") end
    else
        ui.num:SetText(n > 0 and n or "")
    end

    local prev = state.stacks
    state.stacks = n
    if n ~= prev then
        if not secret then
            if n > prev then
                for i = max(prev + 1, 1), min(n, MAX_STACKS) do orbs[i].pop = 1 end
            end
            if n >= MAX_STACKS and prev < MAX_STACKS then state.burstT = 0 end
        end
        if n == 0 and prev > 0 then state.flashT = 0 end
        ApplyTheme(n)
    end

    state.visible = present or db.always or state.unlocked
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
    local api = C_UnitAuras
    if not api then Say("C_UnitAuras is not available.") return end

    Say("direct lookups by spell ID:")
    local anyDirect = false
    if api.GetPlayerAuraBySpellID then
        for id in pairs(IDS) do
            local a = api.GetPlayerAuraBySpellID(id)
            if a then
                anyDirect = true
                local apps = a.applications
                print(("  [%d] FOUND, stacks: %s"):format(id, IsSecret(apps) and "hidden (secret in combat)" or tostring(apps)))
            else
                print(("  [%d] not found"):format(id))
            end
        end
    end
    state.inCombatNote = InCombatLockdown and InCombatLockdown()
    if state.inCombatNote then
        Say("you are in combat; the buff list below may be mostly hidden.")
    end

    if api.GetAuraDataByIndex then
        Say("your current buffs:")
        local count = 0
        for i = 1, 255 do
            local aura = api.GetAuraDataByIndex("player", i, "HELPFUL")
            if not aura then break end
            count = count + 1
            local id, name, apps = aura.spellId, aura.name, aura.applications
            local sid   = IsSecret(id)   and "hidden" or tostring(id)
            local sname = IsSecret(name) and "<hidden>" or tostring(name)
            local sapps = IsSecret(apps) and "?" or tostring(apps)
            print(("  %s  [%s]  x%s%s"):format(sname, sid, sapps, Matches(aura) and "   <-- tracked" or ""))
        end
        if count == 0 then Say("no buffs listed.") end
    end
    if not anyDirect then
        Say("Maelstrom Weapon not found. Get some stacks and run /msf debug again.")
    end
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
        print("  /msf debug           - show what the addon can see")
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
