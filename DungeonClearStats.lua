-- DungeonClearStats.lua -- RebornWOW DCSTAT1A: one "run statistics" view for the Clear panel and the Test panel.
-- A model table goes in, a layered, coloured page comes out (header -> big numbers -> sections).
-- Sections hide themselves when the model has no data for them; a section header folds it.
-- The two callers (DungeonClear.lua) build the model; nothing here talks to the server.
--
-- model = {
--   key        = "run id",                 -- same key = the scroll position is kept on refresh
--   mode       = "clear" | "test",
--   title      = "Dungeon name", heroic = bool,
--   result     = { text = "Cleared", rgb = {r,g,b}, ok = true|false|nil },
--   subline    = "10-23 10:14 . restarts 1",
--   tiles      = { { label, value, rgb, frac }, ... },       -- the big numbers
--   party      = { { name, classId, role, kind, ilvl, dmg, heal, taken, deaths, me }, ... },
--   refIlvl    = number | nil,             -- item-level reference (else the party median)
--   bosses     = { { name, status = "dead"|"current"|"skipped"|"alive", t, dur }, ... },
--   deaths     = { { t, name, classId, killer, spell, amount, overkill, dmg5, heal5, healers, onBoss }, ... },
--   taken      = { { src, spell, total, hits }, ... },
--   healers    = { { name, heal, combat, moving, casting, low, lowIdle, minMana, castList }, ... },
--   conditions = { "text", ... },          -- test: cheat tier, helpers ... (shown as warnings)
--   tech       = { "text", ... },          -- test only; folded by default
--   notes      = { "text", ... },          -- quiet grey lines at the bottom (e.g. "no data yet")
--   onFull     = function() end,           -- embedded view: the "full stats" button
-- }

local S = {}
DCStats = S

local function Zh() return DCLoc and DCLoc.IsZh and DCLoc.IsZh() end
local function T(zh, en) if Zh() then return zh end return en end

local FACE = (GameFontNormal and select(1, GameFontNormal:GetFont())) or "Fonts\\FRIZQT__.TTF"
S.T = T

-- ------------------------------------------------------------------ palette
local C = {
    bg    = { 0.035, 0.05, 0.08, 0.96 }, card = { 0.075, 0.10, 0.145, 1 }, card2 = { 0.105, 0.14, 0.20, 1 },
    track = { 0.12, 0.15, 0.21, 1 },
    white = { 0.91, 0.93, 0.96 }, grey = { 0.55, 0.60, 0.66 }, dim = { 0.40, 0.45, 0.52 },
    gold = { 0.91, 0.77, 0.42 }, blue = { 0.24, 0.65, 1.0 }, green = { 0.25, 0.88, 0.38 }, red = { 1.0, 0.31, 0.28 },
    orange = { 1.0, 0.59, 0.16 }, yellow = { 1.0, 0.82, 0.0 }, purple = { 0.69, 0.43, 1.0 },
}
local MODE = { clear = { C.blue, "我的清本", "My clear" }, test = { C.purple, "测试", "Test" } }

-- ------------------------------------------------------------------ small helpers
local function Kfmt(n)
    n = tonumber(n) or 0
    if n >= 1000000 then return string.format("%.2fM", n / 1000000) end
    if n >= 10000 then return string.format("%dK", math.floor(n / 1000 + 0.5)) end
    if n >= 1000 then return string.format("%.1fK", n / 1000) end
    return tostring(math.floor(n + 0.5))
end
local function Clock(s)
    s = tonumber(s) or 0
    local h, m, sec = math.floor(s / 3600), math.floor(s % 3600 / 60), math.floor(s % 60)
    if h > 0 then return string.format("%d:%02d:%02d", h, m, sec) end
    return string.format("%d:%02d", m, sec)
end
-- the drawn width of a string: a CJK glyph is about one em, a Latin one about 0.55 em
local function Width(s, size)
    local w, i, len = 0, 1, #(s or "")
    while i <= len do
        local b = s:byte(i)
        local step = (b >= 240 and 4) or (b >= 224 and 3) or (b >= 192 and 2) or 1
        w = w + (step >= 3 and size or size * 0.55)
        i = i + step
    end
    return w
end
-- cut a UTF-8 string to `max` characters (CJK counts as one)
local function Cut(s, max)
    s = tostring(s or "")
    local n, i, len = 0, 1, #s
    while i <= len do
        local b = s:byte(i)
        local step = (b >= 240 and 4) or (b >= 224 and 3) or (b >= 192 and 2) or 1
        n = n + 1
        if n > max then return s:sub(1, i - 1) .. ".." end
        i = i + step
    end
    return s
end
local function SpellIcon(id)
    local _, _, icon = GetSpellInfo(id)
    return icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end
local function ItemIcon(id)
    return (GetItemIcon and GetItemIcon(id)) or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local CLASS_BY_ID = { [1] = "WARRIOR", [2] = "PALADIN", [3] = "HUNTER", [4] = "ROGUE", [5] = "PRIEST",
                      [6] = "DEATHKNIGHT", [7] = "SHAMAN", [8] = "MAGE", [9] = "WARLOCK", [11] = "DRUID",
                      [13] = "WITCHDOCTOR", [14] = "MONK", [21] = "WITCHDOCTOR" }  -- DCSTAT2B: NPCBot witch doctor (bot class 21)
local CUSTOM_ICON = {
    WITCHDOCTOR = { "Interface\\AddOns\\RebornWitchDoctorTalents\\Art\\UI-CHARACTERCREATE-CLASSES-ROUND", 0.75, 0.875, 0.75, 1.0 },
    MONK = { "Interface\\Glues\\CharacterCreate\\Reborn-Monk-Classes", 0.125, 0.25, 0, 0.125 },
}
local CUSTOM_RGB = { WITCHDOCTOR = { 0.25, 0.88, 0.62 }, MONK = { 0.0, 1.0, 0.59 } }
local function ClassRGB(id)
    local token = CLASS_BY_ID[tonumber(id) or 0]
    local cc = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    if cc then return { cc.r, cc.g, cc.b } end
    return (token and CUSTOM_RGB[token]) or C.white
end
local function SetClassIcon(tex, id)
    local token = CLASS_BY_ID[tonumber(id) or 0]
    local c = token and CUSTOM_ICON[token]
    if c then tex:SetTexture(c[1]); tex:SetTexCoord(c[2], c[3], c[4], c[5]); return end
    local tc = token and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[token]
    if tc then
        tex:SetTexture("Interface\\WorldStateFrame\\Icons-Classes")
        tex:SetTexCoord(tc[1], tc[2], tc[3], tc[4])
        return
    end
    tex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark"); tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
end

-- icons are taken from spell ids (always valid), never from guessed file names
local SEC_ICON = { party = 6673, bosses = 355, deaths = nil, taken = 772, healers = 2061, builds = 1459, tech = 1459 }
local ROLE_ICON = { tank = 71, heal = 2061, dps = 1752 }

-- item level colour against a reference
local function IlvlRGB(v, ref)
    if not ref or ref <= 0 or not v or v <= 0 then return C.grey end
    local f = v / ref
    if f >= 0.98 then return C.green end
    if f >= 0.92 then return { 0.75, 1.0, 0.2 } end
    if f >= 0.85 then return C.orange end
    return C.red
end

-- ------------------------------------------------------------------ the view
local View = {}
View.__index = View

local function DB()
    local ok, t = pcall(function()
        DungeonClearDB = DungeonClearDB or {}
        DungeonClearDB.statsFold = DungeonClearDB.statsFold or {}
        return DungeonClearDB.statsFold
    end)
    return ok and t or {}
end

-- opts: compact (embedded: sections that are long start folded, header gets a "full" button)
function S.NewView(parent, width, opts)
    opts = opts or {}
    local v = setmetatable({}, View)
    v.W = width
    v.compact = opts.compact and true or false
    v.holder = CreateFrame("Frame", nil, parent)
    v.sf = CreateFrame("ScrollFrame", nil, v.holder)
    v.sf:SetPoint("TOPLEFT", v.holder, "TOPLEFT", 0, 0)
    v.sf:SetPoint("BOTTOMRIGHT", v.holder, "BOTTOMRIGHT", -18, 0)
    v.content = CreateFrame("Frame", nil, v.sf)
    v.content:SetSize(width, 10)
    v.sf:SetScrollChild(v.content)
    v.fs, v.tex, v.btn = {}, { BACKGROUND = {}, BORDER = {}, ARTWORK = {}, OVERLAY = {} }, {}
    v.nfs, v.ntex, v.nbtn = 0, { BACKGROUND = 0, BORDER = 0, ARTWORK = 0, OVERLAY = 0 }, 0

    -- scroll bar: arrows + slider, the same pattern as the other lists
    local up = CreateFrame("Button", nil, v.holder, "UIPanelScrollUpButtonTemplate")
    up:SetSize(16, 16); up:SetPoint("TOPRIGHT", v.holder, "TOPRIGHT", 0, 0)
    local down = CreateFrame("Button", nil, v.holder, "UIPanelScrollDownButtonTemplate")
    down:SetSize(16, 16); down:SetPoint("BOTTOMRIGHT", v.holder, "BOTTOMRIGHT", 0, 0)
    local bar = CreateFrame("Slider", nil, v.holder)
    bar:SetOrientation("VERTICAL"); bar:SetWidth(16)
    bar:SetPoint("TOP", up, "BOTTOM", 0, 0); bar:SetPoint("BOTTOM", down, "TOP", 0, 0)
    bar:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    local track = bar:CreateTexture(nil, "BACKGROUND"); track:SetAllPoints(); track:SetTexture(0, 0, 0, 0.35)
    bar:SetMinMaxValues(0, 0); bar:SetValueStep(1); bar:SetValue(0)
    v.bar = bar
    local syncing = false
    bar:SetScript("OnValueChanged", function(_, value) if not syncing then v.sf:SetVerticalScroll(value) end end)
    local function Wheel(_, delta)
        local lo, hi = bar:GetMinMaxValues()
        bar:SetValue(math.max(lo, math.min(hi, bar:GetValue() - delta * 40)))
    end
    v.holder:EnableMouseWheel(true); v.holder:SetScript("OnMouseWheel", Wheel)
    v.sf:EnableMouseWheel(true); v.sf:SetScript("OnMouseWheel", Wheel)
    up:SetScript("OnClick", function() Wheel(nil, 1) end)
    down:SetScript("OnClick", function() Wheel(nil, -1) end)
    function v:Sync(want)
        local view = self.sf:GetHeight() or 0
        if view <= 0 then view = self.holder:GetHeight() or 0 end
        local max = math.max(0, math.ceil(self.contentH - view))
        local val = math.max(0, math.min(want or self.sf:GetVerticalScroll() or 0, max))
        syncing = true
        bar:SetMinMaxValues(0, max); bar:SetValue(val)
        syncing = false
        self.sf:SetVerticalScroll(val)
    end
    v.holder:SetScript("OnShow", function() if v.model then v:Sync() end end)
    v.sf:SetScript("OnSizeChanged", function() if v.model then v:Sync() end end)
    return v
end

-- ---- pooled drawing primitives (everything is placed from the content's top-left corner)
function View:Begin()
    self.nfs, self.nbtn = 0, 0
    for k in pairs(self.ntex) do self.ntex[k] = 0 end
end

function View:End()
    for i = self.nfs + 1, #self.fs do self.fs[i]:Hide() end
    for layer, list in pairs(self.tex) do
        for i = self.ntex[layer] + 1, #list do list[i]:Hide() end
    end
    for i = self.nbtn + 1, #self.btn do self.btn[i]:Hide() end
end

function View:Text(x, y, str, size, rgb, just, w)
    self.nfs = self.nfs + 1
    local f = self.fs[self.nfs]
    if not f then f = self.content:CreateFontString(nil, "OVERLAY"); self.fs[self.nfs] = f end
    f:SetFont(FACE, size or 12, "")
    f:SetShadowColor(0, 0, 0, 1); f:SetShadowOffset(1, -1)
    rgb = rgb or C.white
    f:SetTextColor(rgb[1], rgb[2], rgb[3], rgb[4] or 1)
    f:ClearAllPoints()
    if just == "RIGHT" then
        f:SetPoint("TOPRIGHT", self.content, "TOPLEFT", x, -y)
    elseif just == "CENTER" then
        f:SetPoint("TOP", self.content, "TOPLEFT", x, -y)
    else
        f:SetPoint("TOPLEFT", self.content, "TOPLEFT", x, -y)
    end
    f:SetJustifyH(just or "LEFT")
    f:SetText(str or "")
    f:Show()
    return f
end

function View:Big(x, y, str, size, rgb, just)
    local f = self:Text(x, y, str, size, rgb, just)
    f:SetFont(FACE, size, "OUTLINE")  -- the locale's own face: digits and the odd "sec" glyph both draw
    return f
end

function View:Tex(layer, x, y, w, h, rgb)
    self.ntex[layer] = self.ntex[layer] + 1
    local list = self.tex[layer]
    local t = list[self.ntex[layer]]
    if not t then t = self.content:CreateTexture(nil, layer); list[self.ntex[layer]] = t end
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", self.content, "TOPLEFT", x, -y)
    t:SetSize(w, h)
    t:SetTexCoord(0, 1, 0, 1)
    t:SetVertexColor(1, 1, 1, 1)
    if t.SetDesaturated then t:SetDesaturated(false) end
    if rgb then t:SetTexture(rgb[1], rgb[2], rgb[3], rgb[4] or 1) end
    t:Show()
    return t
end

function View:Rect(layer, x, y, w, h, rgb) return self:Tex(layer, x, y, w, h, rgb) end

function View:Icon(x, y, size, path, coords)
    local t = self:Tex("ARTWORK", x, y, size, size)
    t:SetTexture(path)
    if coords then t:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    else t:SetTexCoord(0.07, 0.93, 0.07, 0.93) end
    return t
end

function View:Bar(x, y, w, h, frac, rgb)
    self:Rect("BORDER", x, y, w, h, C.track)
    frac = math.max(0, math.min(1, frac or 0))
    if frac > 0 then self:Rect("ARTWORK", x, y, math.max(3, math.floor(w * frac)), h, rgb) end
end

function View:Button(x, y, w, h, onClick, tip)
    self.nbtn = self.nbtn + 1
    local b = self.btn[self.nbtn]
    if not b then
        b = CreateFrame("Button", nil, self.content)
        b:SetScript("OnEnter", function(self_)
            if self_.tip then GameTooltip:SetOwner(self_, "ANCHOR_TOP"); GameTooltip:SetText(self_.tip); GameTooltip:Show() end
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        self.btn[self.nbtn] = b
    end
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", self.content, "TOPLEFT", x, -y)
    b:SetSize(w, h)
    b:SetScript("OnClick", onClick)
    b.tip = tip
    b:Show()
    return b
end

-- a coloured rounded-ish label: a filled rect with centred text
function View:Badge(x, y, w, h, str, textRGB, fillRGB, size)
    self:Rect("BACKGROUND", x, y, w, h, fillRGB)
    self:Text(x + w / 2, y + math.floor((h - (size or 11)) / 2) - 1, str, size or 11, textRGB, "CENTER")
end

-- ------------------------------------------------------------------ sections
function View:Folded(key, default)
    local t = DB()
    local f = t[key]
    if f == nil then return default end
    return f
end

-- header bar of a section; returns the y of its body (nil when folded)
function View:Section(y, key, iconSpell, title, summary, accent, foldedDefault)
    local W = self.W
    self:Rect("BACKGROUND", 0, y, W, 28, C.card2)
    self:Rect("ARTWORK", 0, y, 3, 28, accent)
    if iconSpell then self:Icon(10, y + 5, 18, SpellIcon(iconSpell)) end
    self:Text(34, y + 6, title, 14, C.white)
    local folded = self:Folded(key, foldedDefault)
    if summary and summary ~= "" then self:Text(W - 26, y + 8, summary, 11, C.grey, "RIGHT") end
    self:Text(W - 12, y + 6, folded and "+" or "-", 14, C.dim, "CENTER")
    self:Button(0, y, W, 28, function()
        DB()[key] = not folded
        if self.model then self:Render(self.model, true) end
    end)
    return (not folded) and (y + 30) or nil, y + 32
end

-- ------------------------------------------------------------------ render
local function Median(list)
    if #list == 0 then return 0 end
    table.sort(list)
    return list[math.ceil(#list / 2)]
end

function View:Render(m, keepScroll)
    self.model = m
    local W = self.W
    local keep = nil
    if keepScroll or (self.key and self.key == m.key) then keep = self.sf:GetVerticalScroll() or 0 end
    self.key = m.key
    self:Begin()
    local mode = MODE[m.mode] or MODE.clear
    local accent = mode[1]
    local y = 0
    local compact = self.compact

    -- ---- header
    local hh = compact and 66 or 66
    self:Rect("BACKGROUND", 0, y, W, hh, C.card)
    self:Rect("ARTWORK", 0, y, 4, hh, accent)
    local tx = 14
    local title = Cut(m.title or "?", compact and 12 or 16)
    self:Text(tx, y + 7, title, compact and 17 or 20, C.gold)
    local bx = math.min(tx + Width(title, compact and 17 or 20) + 10, W - 150)
    if m.heroic then self:Badge(bx, y + 9, 40, 18, T("英雄", "Heroic"), C.orange, { 0.27, 0.14, 0.05, 1 }); bx = bx + 46 end
    self:Badge(bx, y + 9, Zh() and 52 or 56, 18, Zh() and mode[2] or mode[3], accent, { 0.10, 0.12, 0.25, 1 })
    if m.subline and m.subline ~= "" then self:Text(tx, y + (compact and 32 or 42), Cut(m.subline, compact and 34 or 70), 11, C.grey) end
    if m.result then
        local r = m.result
        local rc = r.rgb or C.white
        local bw = compact and 70 or 96
        self:Rect("BACKGROUND", W - bw - 8, y + 8, bw, 36, { rc[1] * 0.22, rc[2] * 0.22, rc[3] * 0.22, 1 })
        self:Rect("ARTWORK", W - bw - 8, y + 8, bw, 1, rc)
        self:Rect("ARTWORK", W - bw - 8, y + 43, bw, 1, rc)
        self:Text(W - 8 - bw / 2, y + 17, r.text or "", compact and 14 or 17, rc, "CENTER")
    end
    if compact and m.onFull then
        self:Rect("BACKGROUND", W - 78, y + 44, 70, 16, { 0.10, 0.18, 0.30, 1 })
        self:Button(W - 78, y + 44, 70, 16, function() m.onFull() end, T("打开完整统计", "Open full stats"))
        self:Text(W - 43, y + 46, T("完整统计", "Full stats"), 10, C.blue, "CENTER")
    end
    y = y + hh + 8

    -- ---- the big numbers
    if m.tiles and #m.tiles > 0 then
        local n = #m.tiles
        local gap = 6
        local tw = math.floor((W - gap * (n - 1)) / n)
        local th = compact and 50 or 62
        for i, t in ipairs(m.tiles) do
            local x = (i - 1) * (tw + gap)
            self:Rect("BACKGROUND", x, y, tw, th, C.card)
            self:Text(x + 8, y + 5, t.label, 11, C.grey)
            self:Big(x + 8, y + (compact and 19 or 21), tostring(t.value), compact and 20 or 26, t.rgb or C.white)
            if t.frac then self:Bar(x + 8, y + th - 9, tw - 16, 4, t.frac, t.rgb or C.green) end
        end
        y = y + th + 8
    end

    -- ---- party
    if m.party and #m.party > 0 then
        local ilvls = {}
        local hasDmg, hasHeal, hasTaken, hasIl, maxDmg, maxHeal = false, false, false, false, 1, 1
        local totalDmg = 0
        for _, p in ipairs(m.party) do
            if (p.ilvl or 0) > 0 then ilvls[#ilvls + 1] = p.ilvl; hasIl = true end
            if p.dmg then hasDmg = true; maxDmg = math.max(maxDmg, p.dmg); totalDmg = totalDmg + p.dmg end
            if p.heal then hasHeal = true; maxHeal = math.max(maxHeal, p.heal) end
            if p.taken then hasTaken = true end
        end
        local ref = m.refIlvl or Median(ilvls)
        local sum = ""
        if hasIl then
            local lo, loName = nil, nil
            local total = 0
            for _, p in ipairs(m.party) do
                if (p.ilvl or 0) > 0 then
                    total = total + p.ilvl
                    if not lo or p.ilvl < lo then lo, loName = p.ilvl, p.name end
                end
            end
            sum = string.format("%s %d  .  %s %s %d", T("平均装等", "avg iLvl"), math.floor(total / #ilvls + 0.5), T("最低", "lowest"), loName or "", lo or 0)
        end
        local body, nexty = self:Section(y, "party", SEC_ICON.party, T("队伍", "Party"), sum, C.blue, false)
        if body then
            local RH = 34
            local rows = #m.party
            self:Rect("BACKGROUND", 0, body, W, rows * RH + 6, C.card)
            -- columns from the right edge; only the ones that have data
            local cols = {}
            if true then cols[#cols + 1] = { "deaths", 44, T("死亡", "Deaths") } end
            if hasTaken and W >= 520 then cols[#cols + 1] = { "taken", 56, T("承伤", "Taken") } end
            if hasHeal then cols[#cols + 1] = { "heal", (W >= 520) and 92 or 60, T("治疗", "Heal") } end
            if hasDmg then cols[#cols + 1] = { "dmg", (W >= 520) and 128 or 70, T("输出", "Dmg") } end
            if hasIl then cols[#cols + 1] = { "ilvl", 44, T("装等", "iLvl") } end
            local right = W - 8
            local pos = {}
            for _, c in ipairs(cols) do
                right = right - c[2]
                pos[c[1]] = { x = right, w = c[2] }
                self:Text(right + c[2] / 2, body + 2, c[3], 10, C.dim, "CENTER")
            end
            local ry = body + 12
            for _, p in ipairs(m.party) do
                local rgb = ClassRGB(p.classId)
                local ic = self:Icon(8, ry + 2, 24, "Interface\\Icons\\INV_Misc_QuestionMark")
                SetClassIcon(ic, p.classId)
                self:Text(38, ry, Cut(p.name or "?", 10), 13, rgb)
                local sub = ""
                if p.role == "tank" then sub = T("坦克", "Tank") elseif p.role == "heal" then sub = T("治疗", "Healer")
                elseif p.role == "dps" then sub = T("输出", "DPS") end
                if p.kind and p.kind ~= "" then sub = (sub ~= "" and (sub .. " . ") or "") .. p.kind end
                if p.me then sub = (sub ~= "" and (sub .. " . ") or "") .. T("你", "you") end
                self:Text(38, ry + 16, sub, 10, C.dim)
                if pos.ilvl then
                    local c = IlvlRGB(p.ilvl, ref)
                    self:Big(pos.ilvl.x + pos.ilvl.w / 2, ry + 2, (p.ilvl and p.ilvl > 0) and tostring(p.ilvl) or "-", 16, c, "CENTER")
                end
                if pos.dmg then
                    if p.dmg and p.dmg > 0 then
                        local bw = pos.dmg.w - 52
                        self:Bar(pos.dmg.x, ry + 8, bw, 8, p.dmg / maxDmg, C.orange)
                        self:Text(pos.dmg.x + bw + 4, ry, Kfmt(p.dmg), 12, C.white)
                        if totalDmg > 0 then self:Text(pos.dmg.x + bw + 4, ry + 14, string.format("%d%%", math.floor(p.dmg * 100 / totalDmg + 0.5)), 9, C.dim) end
                    else
                        self:Text(pos.dmg.x + 6, ry + 4, "-", 13, C.dim)
                    end
                end
                if pos.heal then
                    if p.heal and p.heal > 0 then
                        local bw = pos.heal.w - 46
                        self:Bar(pos.heal.x, ry + 8, bw, 8, p.heal / maxHeal, C.green)
                        self:Text(pos.heal.x + bw + 4, ry + 3, Kfmt(p.heal), 12, C.green)
                    else
                        self:Text(pos.heal.x + 6, ry + 4, "-", 13, C.dim)
                    end
                end
                if pos.taken then
                    self:Text(pos.taken.x + pos.taken.w / 2, ry + 3, p.taken and Kfmt(p.taken) or "-", 12, p.taken and C.white or C.dim, "CENTER")
                end
                local dead = p.deaths or 0
                if dead > 0 then
                    local sk = self:Icon(pos.deaths.x + 4, ry + 3, 16, "Interface\\TargetingFrame\\UI-RaidTargetingIcons", { 0.75, 1, 0.25, 0.5 })
                    self:Text(pos.deaths.x + 24, ry + 3, tostring(dead), 13, C.red)
                else
                    self:Text(pos.deaths.x + pos.deaths.w / 2, ry + 4, "-", 13, C.dim, "CENTER")
                end
                ry = ry + RH
            end
            y = body + rows * RH + 14
        else
            y = nexty
        end
    end

    -- ---- bosses
    if m.bosses and #m.bosses > 0 then
        local done, slow, slowName = 0, 0, nil
        for _, b in ipairs(m.bosses) do
            if b.status == "dead" then done = done + 1 end
            if (b.dur or 0) > slow then slow, slowName = b.dur, b.name end
        end
        local sum = string.format("%d/%d", done, #m.bosses)
        if slowName and done > 1 then sum = sum .. string.format("  .  %s %s %s", T("最慢", "slowest"), Cut(slowName, 8), Clock(slow)) end
        local body, nexty = self:Section(y, "bosses", SEC_ICON.bosses, T("首领", "Bosses"), sum, C.gold, false)
        if body then
            local RH = 24
            self:Rect("BACKGROUND", 0, body, W, #m.bosses * RH + 8, C.card)
            local ry = body + 5
            for _, b in ipairs(m.bosses) do
                local st = b.status
                local tex = (st == "dead" and "Interface\\RaidFrame\\ReadyCheck-Ready") or (st == "current" and "Interface\\RaidFrame\\ReadyCheck-Waiting")
                    or (st == "skipped" and "Interface\\RaidFrame\\ReadyCheck-NotReady") or nil
                if tex then self:Icon(8, ry + 1, 16, tex, { 0, 1, 0, 1 }) else self:Rect("ARTWORK", 13, ry + 7, 6, 6, C.dim) end
                local nc = (st == "dead" and C.white) or (st == "current" and C.yellow) or C.grey
                self:Text(32, ry + 2, Cut(b.name, compact and 14 or 22), 13, nc)
                if st == "dead" and b.t then
                    self:Text(W - 8, ry + 3, T("击杀 ", "kill ") .. Clock(b.t), 11, C.grey, "RIGHT")
                    if b.dur then self:Text(W - 8 - (compact and 80 or 110), ry + 3, T("耗时 ", "took ") .. Clock(b.dur), 11, (b.dur == slow and done > 1) and C.yellow or C.grey, "RIGHT") end
                elseif st == "current" then
                    self:Text(W - 8, ry + 3, T("当前目标", "current"), 11, C.yellow, "RIGHT")
                elseif st == "skipped" then
                    self:Text(W - 8, ry + 3, T("已跳过", "skipped"), 11, C.dim, "RIGHT")
                end
                ry = ry + RH
            end
            y = body + #m.bosses * RH + 16
        else
            y = nexty
        end
    end

    -- ---- deaths
    if m.deaths then
        local n = #m.deaths
        local top, topN = nil, 0
        local count = {}
        for _, d in ipairs(m.deaths) do
            local k = (d.killer and d.killer ~= "") and d.killer or nil
            if k then count[k] = (count[k] or 0) + 1; if count[k] > topN then top, topN = k, count[k] end end
        end
        local sum = n == 0 and T("没有人死亡", "no deaths") or string.format("%d %s", n, T("次", "")) ..
            (top and ("  .  " .. T("主要死因 ", "main cause ") .. Cut(top, 10)) or "")
        local body, nexty = self:Section(y, "deaths", nil, T("死亡", "Deaths"), sum, C.red, false)
        local hdrIcon = true
        if body then
            local shown = math.min(n, compact and 4 or 6)
            local RH = 40
            local h = math.max(1, shown) * RH + (n > shown and 22 or 0) + 8
            self:Rect("BACKGROUND", 0, body, W, h, C.card)
            if n == 0 then
                self:Text(14, body + 8, T("本局没有人死亡", "Nobody died this run"), 13, C.green)
            end
            local ry = body + 5
            for i = 1, shown do
                local d = m.deaths[i]
                self:Text(10, ry + 1, Clock(d.t), 11, C.dim)
                self:Text(56, ry, Cut(d.name or "?", 10), 13, ClassRGB(d.classId))
                if d.killer and d.killer ~= "" then
                    self:Text(56 + math.min(#(d.name or "?"), 24) * 6 + 22, ry, "<- " .. Cut(d.killer, compact and 10 or 16), 13, C.red)
                else
                    self:Text(W - 8, ry + 1, T("战斗外", "out of combat"), 11, C.dim, "RIGHT")
                end
                local sub = {}
                local sp = d.spell and d.spell ~= "" and d.spell or nil
                if sp or (d.amount or 0) > 0 then sub[#sub + 1] = (sp and (Cut(sp, 12) .. " ") or "") .. Kfmt(d.amount or 0) end
                if (d.dmg5 or 0) > 0 or (d.heal5 or 0) > 0 then
                    sub[#sub + 1] = string.format(T("前5秒 承伤%s 受疗%s", "5s: -%s +%s"), Kfmt(d.dmg5 or 0), Kfmt(d.heal5 or 0))
                end
                if d.healerNote and d.healerNote ~= "" then sub[#sub + 1] = d.healerNote end
                if #sub > 0 then self:Text(56, ry + 18, table.concat(sub, "  .  "), 10, C.grey) end
                ry = ry + RH
            end
            if n > shown then self:Text(14, ry + 2, string.format(T("还有 %d 条", "%d more"), n - shown), 11, C.dim) end
            y = body + h + 8
        else
            y = nexty
        end
    end

    -- ---- damage taken
    if m.taken and #m.taken > 0 then
        local total = 0
        for _, t in ipairs(m.taken) do total = total + (t.total or 0) end
        local body, nexty = self:Section(y, "taken", SEC_ICON.taken, T("承伤", "Damage taken"),
            string.format("%s %s", T("前几项合计", "top total"), Kfmt(total)), C.orange, compact)
        if body then
            local show = math.min(#m.taken, compact and 3 or 5)
            local RH = 24
            self:Rect("BACKGROUND", 0, body, W, show * RH + 8, C.card)
            local ry = body + 5
            local maxv = m.taken[1].total or 1
            for i = 1, show do
                local t = m.taken[i]
                local label = Cut(t.src or "?", compact and 8 or 12)
                if t.spell and t.spell ~= "" then label = label .. " . " .. Cut(t.spell, compact and 7 or 12) end
                self:Text(10, ry + 2, label, 12, C.white)
                local bx = compact and 150 or 250
                self:Bar(bx, ry + 6, W - bx - 62, 9, (t.total or 0) / maxv, C.orange)
                self:Text(W - 8, ry + 2, Kfmt(t.total), 12, C.white, "RIGHT")
                ry = ry + RH
            end
            y = body + show * RH + 16
        else
            y = nexty
        end
    end

    -- ---- healers
    if m.healers and #m.healers > 0 then
        local best = m.healers[1]
        local sum = ""
        if best and best.heal and best.combat and best.combat > 0 then
            sum = string.format("%s %s  .  %s %d", T("治疗", "healing"), Kfmt(best.heal), T("每秒", "per s"), math.floor(best.heal / best.combat))
        end
        local body, nexty = self:Section(y, "healers", SEC_ICON.healers, T("治疗者", "Healers"), sum, C.green, false)
        if body then
            local RH = compact and 60 or 66
            self:Rect("BACKGROUND", 0, body, W, #m.healers * RH + 6, C.card)
            local ry = body + 4
            for _, h in ipairs(m.healers) do
                self:Text(10, ry, Cut(h.name or "?", 12), 13, C.green)
                local idle = h.lowIdle or 0
                local ic = (idle >= 20 and C.red) or (idle >= 6 and C.yellow) or C.green
                local mn = h.minMana or 100
                local mc = (mn < 20 and C.red) or (mn < 50 and C.yellow) or C.green
                local cw = math.floor((W - 20) / 3)
                local tiles = {
                    { T("队友低血时站着", "idle, ally low"), string.format("%d%s", idle, T(" 秒", "s")), ic, string.format(T("共低血 %d 秒", "of %ds low"), h.low or 0) },
                    { T("读条", "casting"), string.format("%d%s", h.casting or 0, T(" 秒", "s")), C.white, string.format(T("战斗 %d 秒", "combat %ds"), h.combat or 0) },
                    { T("最低蓝量", "lowest mana"), string.format("%d%%", mn), mc, "" },
                }
                for i, t in ipairs(tiles) do
                    local x = 10 + (i - 1) * cw
                    self:Text(x, ry + 18, t[1], 10, C.grey)
                    self:Big(x, ry + 30, t[2], compact and 17 or 20, t[3])
                    if t[4] ~= "" and not compact then self:Text(x + 78, ry + 38, t[4], 10, C.dim) end
                end
                ry = ry + RH
            end
            y = body + #m.healers * RH + 12
        else
            y = nexty
        end
    end

    -- ---- conditions (test)
    if m.conditions and #m.conditions > 0 then
        local body, nexty = self:Section(y, "cond", SEC_ICON.builds, T("条件", "Conditions"), T("不算干净结果", "not a clean result"), C.yellow, false)
        if body then
            self:Rect("BACKGROUND", 0, body, W, #m.conditions * 20 + 8, C.card)
            local ry = body + 5
            for _, s in ipairs(m.conditions) do
                self:Text(12, ry, Cut(s, compact and 36 or 64), 12, C.yellow)
                ry = ry + 20
            end
            y = body + #m.conditions * 20 + 16
        else
            y = nexty
        end
    end

    -- ---- technical details (test), folded by default
    if m.tech and #m.tech > 0 then
        local body, nexty = self:Section(y, "tech", SEC_ICON.tech, T("技术细节", "Technical"), "", C.dim, true)
        if body then
            local n = math.min(#m.tech, 40)
            self:Rect("BACKGROUND", 0, body, W, n * 16 + 8, C.card)
            local ry = body + 5
            for i = 1, n do
                self:Text(10, ry, Cut(m.tech[i], compact and 44 or 80), 10, C.grey)
                ry = ry + 16
            end
            y = body + n * 16 + 16
        else
            y = nexty
        end
    end

    -- ---- quiet notes
    for _, s in ipairs(m.notes or {}) do
        self:Text(8, y + 2, Cut(s, compact and 44 or 80), 10, C.dim)
        y = y + 16
    end

    self:End()
    self.contentH = y + 8
    self.content:SetHeight(self.contentH)
    self:Sync(keep or 0)
end

-- ------------------------------------------------------------------ the full window
local win
function S.Open(m)
    if not win then
        local ok, err = pcall(function()
            win = CreateFrame("Frame", "DungeonClearStatsFrame", UIParent)
            win:SetSize(580, 640)
            win:SetPoint("CENTER", UIParent, "CENTER", 40, 0)
            win:SetFrameStrata("FULLSCREEN_DIALOG")  -- above the big panel, like every other pop-up
            win:SetToplevel(true)
            win:SetMovable(true); win:EnableMouse(true); win:SetClampedToScreen(true)
            win:RegisterForDrag("LeftButton")
            win:SetScript("OnDragStart", function(self) self:StartMoving() end)
            win:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
            win:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                              tile = true, tileSize = 16, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
            win:SetBackdropColor(C.bg[1], C.bg[2], C.bg[3], C.bg[4])
            win:SetBackdropBorderColor(0.42, 0.36, 0.22, 1)
            local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
            close:SetPoint("TOPRIGHT", win, "TOPRIGHT", 2, 2)
            win.view = S.NewView(win, 540, {})
            win.view.holder:SetPoint("TOPLEFT", win, "TOPLEFT", 14, -34)
            win.view.holder:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -12, 12)
            local cap = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            cap:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -12)
            cap:SetText("|cff3da6ff" .. T("本局统计", "Run statistics") .. "|r")
            win:SetScript("OnShow", function(self) self:Raise() end)
            if UISpecialFrames then table.insert(UISpecialFrames, "DungeonClearStatsFrame") end
            win:Hide()
        end)
        if not ok then
            win = nil
            DEFAULT_CHAT_FRAME:AddMessage("|cffff3333DungeonClear stats window failed: " .. tostring(err) .. "|r")
            return
        end
    end
    local ok, err = pcall(function() win.view:Render(m) end)
    if not ok then DEFAULT_CHAT_FRAME:AddMessage("|cffff3333DungeonClear stats: " .. tostring(err) .. "|r") end
    win:Show()
    win:Raise()
end

function S.Refresh(m)  -- refresh the window only when it is open AND shows this same run
    if win and win:IsShown() and win.view.key == m.key then pcall(function() win.view:Render(m) end) end
end

-- ------------------------------------------------------------------ compare (RebornWOW DCRUN2A)
-- Two to six runs side by side: one column per run (oldest on the left), the best value of a
-- row in green, the worst in red/yellow, then each boss's split time, then the analysis lines.
-- cm = {
--   key, title = "Dungeon" | nil (several), heroic = bool,
--   runs  = { { date, tier, heroic, name, result = { text, rgb }, dur, bosses, total, deaths,
--               restarts, ilvl, killer, party = { classId, ... }, kills = { [boss] = { t, dur } },
--               det = bool, clear = bool, loading = bool }, ... },
--   order = { "boss name", ... },          -- kill order of the run with the most kills
--   notes = { "text", ... },
-- }
local LABEL_W = 120

-- best / worst of a list of numbers (nil skipped); lowGood: the smallest is the best
local function Extremes(vals, lowGood)
    local lo, hi, n = nil, nil, 0
    for _, v in pairs(vals) do
        if v then
            n = n + 1
            if not lo or v < lo then lo = v end
            if not hi or v > hi then hi = v end
        end
    end
    if n < 2 or lo == hi then return nil, nil end
    if lowGood then return lo, hi end
    return hi, lo
end

function View:RenderCompare(cm)
    self.model = nil
    local W, n = self.W, #cm.runs
    self:Begin()
    local cw = math.floor((W - LABEL_W) / math.max(1, n))
    local function cx(i) return LABEL_W + (i - 1) * cw + math.floor(cw / 2) end
    local y = 0

    -- ---- header
    self:Rect("BACKGROUND", 0, y, W, 56, C.card)
    self:Rect("ARTWORK", 0, y, 4, 56, C.blue)
    local title = Cut(cm.title or T("多个副本", "Several dungeons"), 18)
    self:Text(14, y + 7, title, 20, C.gold)
    local bx = math.min(14 + Width(title, 20) + 10, W - 120)
    if cm.heroic then self:Badge(bx, y + 9, 40, 18, T("英雄", "Heroic"), C.orange, { 0.27, 0.14, 0.05, 1 }); bx = bx + 46 end
    self:Badge(bx, y + 9, 64, 18, T("对比统计", "Compare"), C.blue, { 0.10, 0.12, 0.25, 1 })
    self:Text(14, y + 36, string.format(T("%d 局并排对比，绿色最好，红色最差", "%d runs side by side; green = best, red = worst"), n), 11, C.grey)
    y = y + 64

    -- ---- one head per run
    self:Rect("BACKGROUND", 0, y, W, 48, C.card2)
    self:Text(10, y + 8, T("日期", "Date"), 12, C.grey)
    self:Text(10, y + 26, T("结果", "Result"), 12, C.grey)
    for i, r in ipairs(cm.runs) do
        if i > 1 then self:Rect("ARTWORK", LABEL_W + (i - 1) * cw, y + 6, 1, 36, C.track) end
        self:Text(cx(i), y + 6, r.date or "", 12, C.white, "CENTER")
        local sub = r.result.text
        if not cm.title then sub = Cut(r.name or "", 6) .. " " .. sub end
        self:Text(cx(i), y + 25, sub, 12, r.result.rgb or C.white, "CENTER")
    end
    y = y + 52

    -- ---- metric rows
    local odd = false
    local function Line(label, cells, h)
        h = h or 30
        odd = not odd
        self:Rect("BACKGROUND", 0, y, W, h, odd and C.card or { 0.055, 0.075, 0.11, 1 })
        self:Text(10, y + math.floor((h - 12) / 2), label, 12, C.grey)
        for i, c in ipairs(cells) do
            if c.party then
                local k = math.min(#c.party, 6)
                local size = 16
                local x0 = cx(i) - math.floor(k * (size + 1) / 2)
                for j = 1, k do
                    local ic = self:Icon(x0 + (j - 1) * (size + 1), y + math.floor((h - size) / 2), size, "Interface\\Icons\\INV_Misc_QuestionMark")
                    SetClassIcon(ic, c.party[j])
                end
                if k == 0 then self:Text(cx(i), y + 8, "-", 13, C.dim, "CENTER") end
            elseif c.sub then
                self:Text(cx(i), y + 3, c[1], 14, c[2] or C.white, "CENTER")
                self:Text(cx(i), y + 18, c.sub, 10, c.subRGB or C.dim, "CENTER")
            else
                self:Text(cx(i), y + math.floor((h - 14) / 2), c[1], 14, c[2] or C.white, "CENTER")
            end
        end
        y = y + h
    end

    -- time: the fastest clear is the reference
    local ref
    for _, r in ipairs(cm.runs) do if r.clear and (not ref or r.dur < ref.dur) then ref = r end end
    local cells = {}
    for i, r in ipairs(cm.runs) do
        if r == ref then cells[i] = { Clock(r.dur), C.green, sub = T("最快", "fastest"), subRGB = C.green }
        elseif r.clear and ref then cells[i] = { Clock(r.dur), C.white, sub = "+" .. Clock(r.dur - ref.dur), subRGB = C.red }
        else cells[i] = { Clock(r.dur), C.grey, sub = T("未全清", "not cleared") } end
    end
    Line(T("用时", "Time"), cells)

    cells = {}
    for i, r in ipairs(cm.runs) do
        cells[i] = { string.format("%d/%d", r.bosses, r.total), (r.total > 0 and r.bosses >= r.total) and C.green or C.white }
    end
    Line(T("首领", "Bosses"), cells)

    local vals = {}
    for i, r in ipairs(cm.runs) do vals[i] = r.deaths end
    local best, worst = Extremes(vals, true)
    cells = {}
    for i, r in ipairs(cm.runs) do
        cells[i] = { tostring(r.deaths), (r.deaths == best and C.green) or (r.deaths == worst and C.red) or C.white }
    end
    Line(T("死亡", "Deaths"), cells)

    cells = {}
    for i, r in ipairs(cm.runs) do
        if r.restarts then cells[i] = { tostring(r.restarts), r.restarts > 0 and C.yellow or C.white }
        else cells[i] = { r.loading and "..." or "-", C.dim } end
    end
    Line(T("重新开始", "Restarts"), cells)

    vals = {}
    for i, r in ipairs(cm.runs) do vals[i] = r.ilvl end
    best, worst = Extremes(vals, false)
    cells = {}
    for i, r in ipairs(cm.runs) do
        if r.ilvl then cells[i] = { tostring(r.ilvl), (r.ilvl == best and C.green) or (r.ilvl == worst and C.orange) or C.white }
        else cells[i] = { r.loading and "..." or "-", C.dim } end
    end
    Line(T("平均装等", "Avg iLvl"), cells)

    cells = {}
    for i, r in ipairs(cm.runs) do
        if r.killer then cells[i] = { Cut(r.killer, math.max(4, math.floor(cw / 14))), C.red }
        else cells[i] = { (r.loading and "...") or (r.deaths > 0 and "?" or "-"), C.dim } end
    end
    Line(T("主要死因", "Main killer"), cells)

    cells = {}
    for i, r in ipairs(cm.runs) do cells[i] = { party = r.party or {} } end
    Line(T("队伍", "Party"), cells)
    y = y + 10

    -- ---- boss splits
    self:Rect("BACKGROUND", 0, y, W, 28, C.card2)
    self:Rect("ARTWORK", 0, y, 3, 28, C.gold)
    self:Icon(10, y + 5, 18, SpellIcon(SEC_ICON.bosses))
    self:Text(34, y + 6, T("首领分段用时", "Boss splits"), 14, C.white)
    self:Text(W - 10, y + 8, T("上：这一段用时   下：击杀时刻", "top: split   bottom: kill time"), 11, C.grey, "RIGHT")
    y = y + 32
    odd = false
    if #cm.order == 0 then
        local loading = false
        for _, r in ipairs(cm.runs) do if r.loading then loading = true end end
        self:Rect("BACKGROUND", 0, y, W, 28, C.card)
        self:Text(12, y + 7, loading and T("正在向服务器读取详细数据…", "Asking the server for the detail...")
            or T("这些记录没有首领击杀明细", "These runs have no boss kill detail"), 12, C.dim)
        y = y + 32
    end
    for _, name in ipairs(cm.order) do
        vals = {}
        for i, r in ipairs(cm.runs) do vals[i] = r.kills[name] and r.kills[name].dur or nil end
        best, worst = Extremes(vals, true)
        cells = {}
        for i, r in ipairs(cm.runs) do
            local k = r.kills[name]
            if k then
                cells[i] = { Clock(k.dur), (k.dur == best and C.green) or (k.dur == worst and C.yellow) or C.white, sub = "@" .. Clock(k.t) }
            else
                cells[i] = { r.loading and "..." or "-", C.dim }
            end
        end
        Line(Cut(name, 8), cells)
    end
    y = y + 10

    -- ---- analysis
    if cm.notes and #cm.notes > 0 then
        self:Rect("BACKGROUND", 0, y, W, 28, C.card2)
        self:Rect("ARTWORK", 0, y, 3, 28, C.purple)
        self:Icon(10, y + 5, 18, SpellIcon(SEC_ICON.tech))
        self:Text(34, y + 6, T("分析", "Analysis"), 14, C.white)
        y = y + 32
        local per = math.max(20, math.floor((W - 24) / 12))
        self:Rect("BACKGROUND", 0, y, W, #cm.notes * 20 + 8, C.card)
        for _, s in ipairs(cm.notes) do
            self:Text(12, y + 5, Cut(s, per), 12, C.white)
            y = y + 20
        end
        y = y + 12
    end

    self:End()
    self.contentH = y + 8
    self.content:SetHeight(self.contentH)
    self:Sync(0)
end

local cwin
function S.OpenCompare(cm)
    local n = #cm.runs
    local W = math.max(520, math.min(900, LABEL_W + n * 130))
    if not cwin then
        local ok, err = pcall(function()
            cwin = CreateFrame("Frame", "DungeonClearCompareFrame", UIParent)
            cwin:SetPoint("CENTER", UIParent, "CENTER", 60, 0)
            cwin:SetFrameStrata("FULLSCREEN_DIALOG")
            cwin:SetToplevel(true)
            cwin:SetMovable(true); cwin:EnableMouse(true); cwin:SetClampedToScreen(true)
            cwin:RegisterForDrag("LeftButton")
            cwin:SetScript("OnDragStart", function(self) self:StartMoving() end)
            cwin:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
            cwin:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                               tile = true, tileSize = 16, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
            cwin:SetBackdropColor(C.bg[1], C.bg[2], C.bg[3], C.bg[4])
            cwin:SetBackdropBorderColor(0.42, 0.36, 0.22, 1)
            local close = CreateFrame("Button", nil, cwin, "UIPanelCloseButton")
            close:SetPoint("TOPRIGHT", cwin, "TOPRIGHT", 2, 2)
            cwin.view = S.NewView(cwin, W, {})
            cwin.view.holder:SetPoint("TOPLEFT", cwin, "TOPLEFT", 14, -34)
            cwin.view.holder:SetPoint("BOTTOMRIGHT", cwin, "BOTTOMRIGHT", -12, 12)
            local cap = cwin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            cap:SetPoint("TOPLEFT", cwin, "TOPLEFT", 16, -12)
            cap:SetText("|cff3da6ff" .. T("副本记录对比", "Compare runs") .. "|r")
            cwin:SetScript("OnShow", function(self) self:Raise() end)
            if UISpecialFrames then table.insert(UISpecialFrames, "DungeonClearCompareFrame") end
            cwin:Hide()
        end)
        if not ok then
            cwin = nil
            DEFAULT_CHAT_FRAME:AddMessage("|cffff3333DungeonClear compare window failed: " .. tostring(err) .. "|r")
            return
        end
    end
    cwin:SetSize(W + 44, 640)
    cwin.view.W = W
    cwin.view.content:SetWidth(W)
    local ok, err = pcall(function() cwin.view:RenderCompare(cm) end)
    if not ok then DEFAULT_CHAT_FRAME:AddMessage("|cffff3333DungeonClear compare: " .. tostring(err) .. "|r") end
    cwin.key = cm.key
    cwin:Show()
    cwin:Raise()
end

function S.RefreshCompare(cm)  -- only while the window shows these same runs
    if cwin and cwin:IsShown() and cwin.key == cm.key then
        local keep = cwin.view.sf:GetVerticalScroll() or 0
        local ok = pcall(function() cwin.view:RenderCompare(cm) end)
        if ok then cwin.view:Sync(keep) end
    end
end
