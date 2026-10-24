-- DungeonClearPrep.lua -- RebornWOW DCPREP1B: the readiness panel.
-- One card per party member: class icon, the item level as a big coloured number with a bar,
-- the four or five stats that matter for the role as icon chips, and four consumable slots
-- (flask/elixir, food, health potion, mana potion). Pictures and numbers, hardly any sentences.
-- Data comes from the server's "prep" command (PRP_* messages, see DungeonClearAddonHook.cpp):
-- the live party, or the snapshot a test run stored when it started.
-- Opened by the "Readiness" button in the top bar, the run list's right-click menu, or /dcprep.

local P = { byName = {}, order = {}, ref = 0, tag = "-", runId = nil, askedAt = 0, err = nil, loaded = false }
local U = {}          -- helpers
local cards = {}      -- the card frames
local frame           -- the window, built on first use

local MAX_CARDS = 10
local CARD_H, CARD_GAP, CARD_W = 80, 6, 624

local function IsZh() return DCLoc and DCLoc.IsZh and DCLoc.IsZh() end

-- DCPREP2C: the name column ends where the item-level block starts
local NAME_W = 112
-- put `text` into `fs` so that it is at most `maxw` wide; returns true when it had to be cut
local function Fit(fs, text, maxw)
    text = text or ""
    fs:SetText(text)
    if fs:GetStringWidth() <= maxw then return false end
    local cut = text
    while #cut > 0 do
        cut = cut:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")  -- drop the last whole UTF-8 character
        fs:SetText(cut .. "...")
        if fs:GetStringWidth() <= maxw then break end
    end
    return true
end
local function T(zh, en) if IsZh() then return zh end return en end

-- ------------------------------------------------------------------ data
local CLASS_BY_ID = { [1] = "WARRIOR", [2] = "PALADIN", [3] = "HUNTER", [4] = "ROGUE", [5] = "PRIEST",
                      [6] = "DEATHKNIGHT", [7] = "SHAMAN", [8] = "MAGE", [9] = "WARLOCK", [11] = "DRUID",
                      [13] = "WITCHDOCTOR", [14] = "MONK", [21] = "WITCHDOCTOR" }
local CUSTOM_ICON = {
    WITCHDOCTOR = { "Interface\\AddOns\\RebornWitchDoctorTalents\\Art\\UI-CHARACTERCREATE-CLASSES-ROUND", 0.75, 0.875, 0.75, 1.0 },
    MONK = { "Interface\\Glues\\CharacterCreate\\Reborn-Monk-Classes", 0.125, 0.25, 0, 0.125 },
}
local CUSTOM_RGB = { WITCHDOCTOR = { 0.25, 0.88, 0.62 }, MONK = { 0.0, 1.0, 0.59 } }

function U.ClassRGB(classId)
    local token = CLASS_BY_ID[classId]
    local cc = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    if cc then return cc.r, cc.g, cc.b end
    local c = token and CUSTOM_RGB[token]
    if c then return c[1], c[2], c[3] end
    return 0.8, 0.8, 0.8
end

function U.SetClassIcon(tex, classId)
    local token = CLASS_BY_ID[classId]
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

-- icons are taken from the game's own tables (spell / item ids), never from a guessed file name
function U.SpellIcon(spellId)
    local name, _, icon = GetSpellInfo(spellId)
    return icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end
function U.ItemIcon(itemId)
    local icon = itemId and GetItemIcon and GetItemIcon(itemId)
    return icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- spells whose icons say what a stat is
local STAT_ICON = { hp = 1243, armor = 71, defense = 71, ap = 6673, sp = 133, healSp = 2061, crit = 1752,
                    hit = 19434, haste = 2825, expertise = 3127, avoid = 5277, resil = 642, mana = 1459, role_tank = 71,
                    role_heal = 2061, role_dps = 1752 }
local STAT_NAME = {
    hp = { "生命", "Health" }, armor = { "护甲", "Armor" }, defense = { "防御", "Defense" }, ap = { "攻击强度", "Attack power" },
    sp = { "法术强度", "Spell power" }, healSp = { "治疗强度", "Healing power" }, crit = { "暴击", "Crit" },
    hit = { "命中", "Hit" }, haste = { "急速", "Haste" }, expertise = { "精准", "Expertise" },
    avoid = { "躲闪/招架/格挡", "Dodge/parry/block" }, resil = { "韧性", "Resilience" }, mana = { "法力/能量", "Mana / energy" },
}

-- the well-known caps of this game version, used only to colour the numbers
local HIT_CAP = { melee = 8.0, ranged = 8.0, spell = 17.0 }
local DEFENSE_CAP, EXPERTISE_CAP = 540, 26

local function Short(n)
    n = tonumber(n) or 0
    if n >= 100000 then return string.format("%dK", math.floor(n / 1000 + 0.5)) end
    if n >= 10000 then return string.format("%.1fK", n / 1000) end
    return tostring(math.floor(n + 0.5))
end
local function Pct(v) return string.format("%.1f%%", tonumber(v) or 0) end
-- DCPREP2A: an NPCBot that needs no hit rating reports 100; say so instead of "100.0%"
local function HitText(v, bot)
    if bot and (v or 0) >= 99.9 then return T("已满", "capped") end
    return Pct(v)
end

-- ------------------------------------------------------------------ colours
function U.IlvlRGB(v, ref)
    if not ref or ref <= 0 then return 0.55, 0.8, 1.0 end
    local f = v / ref
    if f >= 0.98 then return 0.25, 1.0, 0.35 end
    if f >= 0.92 then return 0.75, 1.0, 0.2 end
    if f >= 0.85 then return 1.0, 0.70, 0.1 end
    return 1.0, 0.25, 0.20
end
local GOOD, WARN, BAD, PLAIN = { 0.25, 1, 0.35 }, { 1, 0.75, 0.15 }, { 1, 0.3, 0.25 }, { 0.78, 0.9, 1 }
local function Grade(v, good, warn)
    if v >= good then return GOOD end
    if v >= warn then return WARN end
    return BAD
end

-- the party's reference item level: what the run was rolled to, else the party's median
function U.Reference()
    if P.ref and P.ref > 0 then return P.ref, true end
    local list = {}
    for _, n in ipairs(P.order) do local r = P.byName[n]; if r and r.ilvl and r.ilvl > 0 then list[#list + 1] = r.ilvl end end
    if #list == 0 then return 0, false end
    table.sort(list)
    return list[math.ceil(#list / 2)], false
end

-- ------------------------------------------------------------------ the stat chips of a role
function U.Chips(r)
    local st = r.st or {}
    local out = {}
    local function add(key, text, rgb) out[#out + 1] = { key = key, text = text, rgb = rgb or PLAIN } end
    local hunter = r.class == 3
    if r.role == "tank" then
        add("hp", Short(st.hp)); add("armor", Short(st.armor))
        add("defense", tostring(st.defense or 0), Grade(st.defense or 0, DEFENSE_CAP, DEFENSE_CAP - 40))
        add("avoid", Pct((st.dodge or 0) + (st.parry or 0) + (st.block or 0)))
        add("resil", Short(st.resil))
    elseif r.role == "heal" then
        add("hp", Short(st.hp)); add("mana", Short(st.mana)); add("healSp", Short(st.healSp))
        add("crit", Pct(st.scrit)); add("haste", Pct(st.haste))
    else
        local phys = math.max(st.ap or 0, st.rap or 0)
        if (st.sp or 0) > phys then
            add("sp", Short(st.sp)); add("crit", Pct(st.scrit))
            add("hit", HitText(st.shit, r.npcBot), Grade(st.shit or 0, HIT_CAP.spell - 0.3, HIT_CAP.spell * 0.7))
            add("haste", Pct(st.haste)); add("hp", Short(st.hp))
        else
            add("ap", Short(hunter and (st.rap or 0) or (st.ap or 0)))
            add("crit", Pct(hunter and st.rcrit or st.crit))
            local hit = hunter and (st.rhit or 0) or (st.hit or 0)
            add("hit", HitText(hit, r.npcBot), Grade(hit, HIT_CAP.melee - 0.3, HIT_CAP.melee * 0.7))
            add("haste", Pct(st.haste))
            if hunter then add("hp", Short(st.hp))
            else add("expertise", tostring(st.expertise or 0), Grade(st.expertise or 0, EXPERTISE_CAP, EXPERTISE_CAP * 0.6)) end
        end
    end
    return out
end

-- ------------------------------------------------------------------ messages from the server
local function Split(s)
    local parts, start = {}, 1
    while true do
        local pos = string.find(s, "\t", start, true)
        if not pos then parts[#parts + 1] = string.sub(s, start); break end
        parts[#parts + 1] = string.sub(s, start, pos - 1)
        start = pos + 1
    end
    return parts
end
local function N(v) return tonumber(v) or 0 end
local function Row(name)
    local r = P.byName[name]
    if not r then
        r = { name = name, buffs = {}, stock = {} }
        P.byName[name] = r
        P.order[#P.order + 1] = name
    end
    return r
end

function U.Handle(message)
    local p = Split(message)
    local kind = p[1]
    if kind == "PRP_START" then
        P.byName, P.order, P.err = {}, {}, nil
        P.tag, P.ref = p[2] or "-", N(p[3])
    elseif kind == "PRP_M" then
        local r = Row(p[2])
        r.class, r.level, r.role = N(p[3]), N(p[4]), p[5] or "dps"
        r.ilvl, r.minIlvl, r.empty, r.dur = N(p[6]), N(p[7]), N(p[8]), N(p[9])
        r.needPet, r.hasPet, r.talents = p[10] == "1", p[11] == "1", p[12] or ""
        r.npcBot = p[13] == "n"  -- DCPREP2A
    elseif kind == "PRP_S" then
        local r = Row(p[2])
        r.st = { hp = N(p[3]), mana = N(p[4]), powerType = N(p[5]), armor = N(p[6]), ap = N(p[7]), rap = N(p[8]),
                 sp = N(p[9]), healSp = N(p[10]), crit = N(p[11]), rcrit = N(p[12]), scrit = N(p[13]),
                 hit = N(p[14]), rhit = N(p[15]), shit = N(p[16]), haste = N(p[17]), expertise = N(p[18]),
                 defense = N(p[19]), dodge = N(p[20]), parry = N(p[21]), block = N(p[22]), resil = N(p[23]) }
    elseif kind == "PRP_B" then
        local r = Row(p[2]); r.buffs[#r.buffs + 1] = { kind = p[3], spell = N(p[4]), secs = N(p[5]) }
    elseif kind == "PRP_K" then
        local r = Row(p[2]); r.stock[p[3] or "?"] = { item = N(p[4]), count = N(p[5]) }
    elseif kind == "PRP_END" then
        P.loaded = true
        if frame and frame:IsShown() then U.Render() end
    elseif kind == "PRP_ERR" then
        P.err = (p[2] == "gm") and T("需要 GM 权限", "GM only") or T("没有这一局的记录", "No such run")
        P.loaded = true
        if frame and frame:IsShown() then U.Render() end
    end
end

-- ------------------------------------------------------------------ the window
local function Fill(tex, r, g, b, a) tex:SetTexture(r, g, b, a or 1) end

function U.MakeChip(card, i)
    local c = CreateFrame("Frame", nil, card)
    c:SetSize(78, 20)
    c:EnableMouse(true)
    c.icon = c:CreateTexture(nil, "ARTWORK"); c.icon:SetSize(18, 18); c.icon:SetPoint("LEFT", c, "LEFT", 0, 0)
    c.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    c.text = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.text:SetPoint("LEFT", c.icon, "RIGHT", 3, 0)
    c:SetScript("OnEnter", function(self)
        if not self.key then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        local n = STAT_NAME[self.key]
        GameTooltip:SetText(n and T(n[1], n[2]) or self.key)
        GameTooltip:Show()
    end)
    c:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return c
end

function U.MakeSlot(card)
    local s = CreateFrame("Frame", nil, card)
    s:SetSize(32, 32)
    s:EnableMouse(true)
    s:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\Buttons\\WHITE8X8",
                    tile = true, tileSize = 8, edgeSize = 2, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
    s:SetBackdropColor(0, 0, 0, 0.6)
    s.icon = s:CreateTexture(nil, "ARTWORK"); s.icon:SetPoint("TOPLEFT", 2, -2); s.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    s.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    s.count = s:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    s.count:SetPoint("BOTTOMRIGHT", s, "BOTTOMRIGHT", -1, 2)
    s.note = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    s.note:SetPoint("TOP", s, "BOTTOM", 0, -1)
    s:SetScript("OnEnter", function(self)
        if not self.tip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(self.tip)
        GameTooltip:Show()
    end)
    s:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return s
end

function U.MakeCard(parent, i)
    local card = CreateFrame("Frame", nil, parent)
    card:SetSize(CARD_W, CARD_H)
    card:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                       tile = true, tileSize = 12, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    card:SetBackdropColor(0.05, 0.06, 0.09, 0.92)
    card:SetBackdropBorderColor(0.3, 0.3, 0.36, 0.9)

    card.stripe = card:CreateTexture(nil, "ARTWORK"); card.stripe:SetPoint("TOPLEFT", 4, -4); card.stripe:SetPoint("BOTTOMLEFT", 4, 4); card.stripe:SetWidth(4)
    card.class = card:CreateTexture(nil, "ARTWORK"); card.class:SetSize(44, 44); card.class:SetPoint("LEFT", card, "LEFT", 14, 4)
    card.role = card:CreateTexture(nil, "OVERLAY"); card.role:SetSize(20, 20); card.role:SetPoint("BOTTOMRIGHT", card.class, "BOTTOMRIGHT", 7, -7)
    card.role:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    card.name = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    card.name:SetPoint("TOPLEFT", card.class, "TOPRIGHT", 12, 0); card.name:SetJustifyH("LEFT")
    card.nameHit = CreateFrame("Frame", nil, card)  -- DCPREP2C: hover shows the whole name
    card.nameHit:SetPoint("TOPLEFT", card.name, "TOPLEFT", 0, 0)
    card.nameHit:SetSize(NAME_W, 34)
    card.nameHit:EnableMouse(true)
    card.nameHit:SetScript("OnEnter", function(self)
        if not self.full then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(self.full)
        GameTooltip:Show()
    end)
    card.nameHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
    card.sub = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.sub:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, -2); card.sub:SetJustifyH("LEFT"); card.sub:SetTextColor(0.6, 0.65, 0.72)
    card.warn = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.warn:SetPoint("TOPLEFT", card.sub, "BOTTOMLEFT", 0, -2); card.warn:SetJustifyH("LEFT")

    -- the item level: a big number over a bar
    card.ilvlCap = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.ilvlCap:SetPoint("TOP", card, "TOPLEFT", 235, -7); card.ilvlCap:SetTextColor(0.6, 0.65, 0.72)
    card.ilvl = card:CreateFontString(nil, "OVERLAY")
    card.ilvl:SetFont("Fonts\\FRIZQT__.TTF", 30, "OUTLINE")
    card.ilvl:SetPoint("TOP", card.ilvlCap, "BOTTOM", 0, -1)
    card.barBg = card:CreateTexture(nil, "ARTWORK"); card.barBg:SetSize(96, 6); card.barBg:SetPoint("TOP", card.ilvl, "BOTTOM", 0, -3); Fill(card.barBg, 0.12, 0.14, 0.2, 1)
    card.bar = card:CreateTexture(nil, "OVERLAY"); card.bar:SetHeight(6); card.bar:SetPoint("LEFT", card.barBg, "LEFT", 0, 0)
    card.weak = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.weak:SetPoint("TOP", card.barBg, "BOTTOM", 0, -2)

    -- the stat chips: two rows of up to three
    card.chips = {}
    for k = 1, 6 do
        local chip = U.MakeChip(card, k)
        chip:SetPoint("TOPLEFT", card, "TOPLEFT", 300 + ((k - 1) % 2) * 80, -12 - math.floor((k - 1) / 2) * 22)
        card.chips[k] = chip
    end

    -- four consumable slots
    card.slots = {}
    for k = 1, 4 do
        local s = U.MakeSlot(card)
        s:SetPoint("TOPLEFT", card, "TOPLEFT", 482 + (k - 1) * 35 + ((k > 2) and 4 or 0), -12)
        card.slots[k] = s
    end
    card.foot = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.foot:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -10, 7); card.foot:SetJustifyH("RIGHT")

    -- a red frame that flashes on the one who is far behind
    card.alert = CreateFrame("Frame", nil, card)
    card.alert:SetAllPoints()
    card.alert:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14 })
    card.alert:SetBackdropBorderColor(1, 0.15, 0.1, 1)
    card.alert:Hide()
    return card
end

-- one slot: `worn` = the aura on the character, `stock` = what the bags hold, `placeholder` = an item id
-- whose icon shows when there is nothing
function U.PaintSlot(s, worn, stock, placeholder, label)
    s.count:SetText("")
    s.note:SetText("")
    if worn then
        s.icon:SetTexture(U.SpellIcon(worn.spell)); s.icon:SetDesaturated(false); s.icon:SetVertexColor(1, 1, 1)
        s:SetBackdropBorderColor(0.25, 1, 0.35, 1)
        if worn.secs and worn.secs > 0 then s.note:SetText("|cff7fe08f" .. math.floor(worn.secs / 60 + 0.5) .. T("分", "m") .. "|r") end
        s.tip = label .. ": " .. (GetSpellInfo(worn.spell) or "")
    elseif stock and stock.count > 0 then
        s.icon:SetTexture(U.ItemIcon(stock.item)); s.icon:SetDesaturated(false); s.icon:SetVertexColor(1, 1, 1)
        s:SetBackdropBorderColor(1, 0.8, 0.2, 1)
        s.count:SetText(stock.count); s.count:SetTextColor(1, 1, 1)
        s.tip = label .. ": " .. T("背包里有 ", "in the bags: ") .. stock.count
    else
        s.icon:SetTexture(U.ItemIcon(placeholder)); s.icon:SetDesaturated(true); s.icon:SetVertexColor(0.55, 0.55, 0.6)
        s:SetBackdropBorderColor(1, 0.25, 0.2, 1)
        s.note:SetText("|cffff5040" .. T("缺", "none") .. "|r")
        s.tip = label .. ": " .. T("没有", "none")
    end
end

function U.PaintCard(card, r, ref, refIsTier, index)
    card:Show()
    local cr, cg, cb = U.ClassRGB(r.class)
    Fill(card.stripe, cr, cg, cb, 1)
    U.SetClassIcon(card.class, r.class)
    card.role:SetTexture(U.SpellIcon(STAT_ICON["role_" .. (r.role or "dps")] or STAT_ICON.role_dps))
    local cut = Fit(card.name, r.name, NAME_W)
    card.name:SetTextColor(cr, cg, cb)
    card.nameHit.full = cut and r.name or nil
    local roleText = (r.role == "tank" and T("坦克", "Tank")) or (r.role == "heal" and T("治疗", "Healer")) or T("输出", "DPS")
    card.sub:SetText(roleText .. "  " .. (r.npcBot and "|cff9fd8ffNPCBot|r" or (r.talents or "")) .. "  Lv" .. (r.level or 0))
    if card.sub:GetStringWidth() > NAME_W + 10 then  -- a long role + talents line must not reach the item level either
        card.sub:SetText(roleText .. "  " .. (r.npcBot and "|cff9fd8ffNPCBot|r" or "") .. "  Lv" .. (r.level or 0))
    end

    -- item level: the number counts up, the bar and colour say how it compares
    local v = r.ilvl or 0
    card.target = v
    card.cur = card.cur and math.min(card.cur, v) or 0
    local ir, ig, ib = U.IlvlRGB(v, ref)
    card.ilvl:SetTextColor(ir, ig, ib)
    card.ilvlCap:SetText(T("装等", "iLvl"))
    local frac = (ref and ref > 0) and math.max(0.04, math.min(1, v / (ref * 1.1))) or 0.5
    card.bar:SetWidth(96 * frac); Fill(card.bar, ir, ig, ib, 1)
    if r.minIlvl and r.minIlvl > 0 then
        local wr, wg, wb = U.IlvlRGB(r.minIlvl, ref)
        card.weak:SetText(string.format("|cff8a93a0%s|r |cff%02x%02x%02x%d|r", T("最弱", "low"), wr * 255, wg * 255, wb * 255, r.minIlvl))
    else
        card.weak:SetText("")
    end

    local behind = ref and ref > 0 and v > 0 and v / ref < 0.85
    if behind then
        card.alert:Show()
        if UIFrameFlash then UIFrameFlash(card.alert, 0.6, 0.6, -1, true, 0.2, 0.2) end
    else
        if UIFrameFlashStop then UIFrameFlashStop(card.alert) end
        card.alert:Hide()
    end

    -- the stat chips
    local chips = U.Chips(r)
    for k = 1, 6 do
        local c, d = card.chips[k], chips[k]
        if d then
            c:Show(); c.key = d.key
            c.icon:SetTexture(U.SpellIcon(STAT_ICON[d.key] or 1243))
            c.text:SetText(d.text); c.text:SetTextColor(d.rgb[1], d.rgb[2], d.rgb[3])
        else
            c:Hide()
        end
    end

    -- the consumables
    local flaskBuff, foodBuff
    for _, b in ipairs(r.buffs or {}) do
        if b.kind == "F" and not flaskBuff then flaskBuff = b end
        if b.kind == "E" and not flaskBuff then flaskBuff = b end
        if b.kind == "W" and not foodBuff then foodBuff = b end
    end
    local st = r.stock or {}
    U.PaintSlot(card.slots[1], flaskBuff, st.F or st.E, 46377, T("合剂/药剂", "Flask / elixir"))
    U.PaintSlot(card.slots[2], foodBuff, st.W, 43015, T("食物", "Food"))
    U.PaintSlot(card.slots[3], nil, st.H, 33447, T("治疗药水", "Health potion"))
    U.PaintSlot(card.slots[4], nil, st.M, 33448, T("法力药水", "Mana potion"))
    for k = 3, 4 do  -- DCPREP2A
        if r.npcBot then card.slots[k]:Hide() else card.slots[k]:Show() end
    end

    -- the small red flags: empty slots, worn-out gear, no pet
    local flags = {}
    if (r.empty or 0) > 0 then flags[#flags + 1] = "|cffff4030" .. T("空槽", "empty") .. " " .. r.empty .. "|r" end
    if (r.dur or 100) < 60 then
        flags[#flags + 1] = string.format("|cff%s%s %d%%|r", (r.dur or 100) < 30 and "ff4030" or "ffb020", T("耐久", "dur"), r.dur or 0)
    end
    if r.needPet and not r.hasPet then flags[#flags + 1] = "|cffff4030" .. T("没带宠物", "no pet") .. "|r" end
    card.foot:SetText(table.concat(flags, "   "))
    card.warn:SetText("")
end

function U.Render()
    if not frame then return end
    local n = math.min(#P.order, MAX_CARDS)
    local ref, isTier = U.Reference()
    for i = 1, MAX_CARDS do
        local card = cards[i]
        if i <= n then
            local r = P.byName[P.order[i]]
            if not card.shownOnce then card.fadeAt = GetTime() + (i - 1) * 0.08; card:SetAlpha(0); card.shownOnce = true end
            U.PaintCard(card, r, ref, isTier, i)
        else
            card:Hide(); card.shownOnce = nil; card.cur = nil
            if UIFrameFlashStop then UIFrameFlashStop(card.alert) end
        end
    end
    frame:SetHeight(48 + math.max(1, n) * (CARD_H + CARD_GAP) + 34)

    -- header / footer: a few words
    local live = P.runId == nil
    frame.mode:SetText(live and T("当前队伍", "Current party") or (T("测试 ", "Test ") .. tostring(P.runId):sub(-12)))
    if P.err then
        frame.sum:SetText("|cffff5040" .. P.err .. "|r")
    elseif n == 0 then
        frame.sum:SetText("|cff8a93a0" .. (P.loaded and T("没有数据", "no data") or T("读取中…", "loading...")) .. "|r")
    else
        local total, weakName, weakV = 0, nil, nil
        for i = 1, n do
            local r = P.byName[P.order[i]]
            total = total + (r.ilvl or 0)
            if not weakV or (r.ilvl or 0) < weakV then weakV, weakName = r.ilvl or 0, r.name end
        end
        local avg = math.floor(total / n + 0.5)
        local ar, ag, ab = U.IlvlRGB(avg, ref)
        local text = string.format("%s |cff%02x%02x%02x%d|r", T("平均装等", "avg iLvl"), ar * 255, ag * 255, ab * 255, avg)
        if ref > 0 then
            text = text .. string.format("   %s %s%d", isTier and T("目标", "target") or T("中位", "median"), "|cffffffff", ref) .. "|r"
        end
        if weakName and n > 1 then
            local wr, wg, wb = U.IlvlRGB(weakV, ref)
            text = text .. string.format("   %s |cff%02x%02x%02x%s %d|r", T("最低", "lowest"), wr * 255, wg * 255, wb * 255, weakName, weakV)
        end
        frame.sum:SetText(text)
    end
end

function U.Request()
    local now = GetTime()
    if now - P.askedAt < 1 then return end
    P.askedAt = now
    if DungeonClearSendCommand then
        DungeonClearSendCommand("prep", P.runId or "", true)
    end
end

function U.Build()
    local stage = "frame"
    local ok, err = pcall(function()
        frame = CreateFrame("Frame", "DungeonClearPrepFrame", UIParent)
        frame:SetSize(CARD_W + 28, 200)
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
        -- one strata above the big panel (DIALOG), like every DungeonClear pop-up (DCUI3E3)
        frame:SetFrameStrata("FULLSCREEN_DIALOG")
        frame:SetToplevel(true)
        frame:SetMovable(true); frame:EnableMouse(true); frame:SetClampedToScreen(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
        frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
        frame:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                            tile = true, tileSize = 16, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        frame:SetBackdropColor(0.02, 0.03, 0.05, 0.96)
        frame:SetBackdropBorderColor(0.42, 0.36, 0.22, 1)

        stage = "header"
        frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -14)
        frame.title:SetText("|cff3da6ff" .. T("准备度", "Readiness") .. "|r")
        frame.mode = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        frame.mode:SetPoint("LEFT", frame.title, "RIGHT", 12, 0); frame.mode:SetTextColor(0.7, 0.75, 0.82)
        local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 2, 2)
        local refresh = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        refresh:SetSize(64, 22); refresh:SetPoint("RIGHT", close, "LEFT", -2, -2)
        refresh:SetText(T("刷新", "Refresh"))
        refresh:SetScript("OnClick", function() P.askedAt = 0; U.Request() end)
        local live = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        live:SetSize(64, 22); live:SetPoint("RIGHT", refresh, "LEFT", -2, 0)
        live:SetText(T("队伍", "Party"))
        live:SetScript("OnClick", function() P.runId = nil; P.askedAt = 0; U.Request() end)

        stage = "cards"
        for i = 1, MAX_CARDS do
            local card = U.MakeCard(frame, i)
            card:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -42 - (i - 1) * (CARD_H + CARD_GAP))
            card:Hide()
            cards[i] = card
        end

        stage = "footer"
        frame.sum = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        frame.sum:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 18, 12)

        stage = "scripts"
        local acc = 0
        frame:SetScript("OnUpdate", function(self, el)
            local now = GetTime()
            for _, card in ipairs(cards) do
                if card:IsShown() then
                    if card.fadeAt then
                        if now >= card.fadeAt then
                            local a = card:GetAlpha() + el * 4
                            if a >= 1 then a = 1; card.fadeAt = nil end
                            card:SetAlpha(a)
                        end
                    end
                    if card.cur and card.target and card.cur ~= card.target then
                        card.cur = math.min(card.target, card.cur + math.max(2, math.ceil((card.target - card.cur) * 0.22)))
                    end
                    if card.target then card.ilvl:SetText(card.cur or card.target) end
                end
            end
            acc = acc + el
            if acc >= 15 then
                acc = 0
                if P.runId == nil then U.Request() end  -- the live party refreshes itself
            end
        end)
        frame:SetScript("OnShow", function(self) self:Raise(); U.Request(); U.Render() end)
        frame:Hide()
    end)
    if not ok then
        frame = nil
        DEFAULT_CHAT_FRAME:AddMessage("|cffff3333DungeonClear readiness panel failed at '" .. stage .. "': " .. tostring(err) .. "|r")
    end
    return ok
end

-- ------------------------------------------------------------------ entry points
function DungeonClearOpenPrep(runId)
    if not frame and not U.Build() then return end
    if runId and runId ~= "" then P.runId = runId else P.runId = nil end
    P.byName, P.order, P.err, P.loaded = {}, {}, nil, false
    for _, card in ipairs(cards) do card.shownOnce = nil; card.cur = nil end
    P.askedAt = 0
    frame:Show()
    frame:Raise()  -- already shown: still come to the front
    U.Request()
    U.Render()
end

function DungeonClearTogglePrep()
    if frame and frame:IsShown() then frame:Hide() else DungeonClearOpenPrep(nil) end
end

SLASH_DCPREP1 = "/dcprep"
SlashCmdList["DCPREP"] = function(msg)
    msg = msg and msg:match("^%s*(.-)%s*$") or ""
    DungeonClearOpenPrep(msg ~= "" and msg or nil)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:SetScript("OnEvent", function(_, event, prefix, message)
    if prefix ~= "DC" or type(message) ~= "string" or string.sub(message, 1, 4) ~= "PRP_" then return end
    local ok, err = pcall(U.Handle, message)
    if not ok then DEFAULT_CHAT_FRAME:AddMessage("|cffff3333DungeonClear readiness: " .. tostring(err) .. "|r") end
end)
