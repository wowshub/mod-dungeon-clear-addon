-- DungeonClear Lua Companion Addon
-- Drives the C++ mod-dungeon-clear module with a premium UI

local AddonName = "DungeonClear"

-- RebornWOW DCUI1A: Locale.lua not loaded (the .toc changed but the client was only
-- /reload-ed; WoW reads a .toc file list only at startup). Run English-only.
if not DCLoc or not DCBind then
    local function same(s) return s end
    DCL, DCLDetail, DCLName, DCLNote = same, same, same, same
    DCLDungeon, DCLTestLine = same, same
    function DCBind(widget, en) widget:SetText(en) end
    function DCBindPair(widget, en) widget:SetText(en) end
    DCLoc = {
        IsZh = function() return false end,
        OnChange = function() end,
        Init = function() end,
        Apply = function() end,
        AddButton = function(btn) btn:SetText("中文") end,
        Toggle = function()
            DEFAULT_CHAT_FRAME:AddMessage("|cffff3333DungeonClear: 中文需要完全重启游戏客户端（/reload 不会加载新文件 Locale.lua）。" ..
                " Restart the game client to enable Chinese.|r")
        end,
    }
end
local Prefix = "DC"

-- DB Setup
DungeonClearDB = DungeonClearDB or {
    visible = false,
    point = "CENTER",
    relativePoint = "CENTER",
    xOfs = 0,
    yOfs = 0,
    minimapPos = 200  -- angle (degrees) of the minimap button around the dial
}

-- Boss list table. `bosses` is what the UI renders; `pendingBosses` stages an
-- in-flight server response and is only committed to `bosses` on BOSS_END, and
-- only when it's non-empty. This keeps a good list "sticky": a transient empty
-- reply (bot still on a loading screen, a second tank bot not yet in the
-- instance, or two tanks' sequences interleaving) can no longer blank a list
-- that already loaded.
local bosses = {}
local pendingBosses = {}
local bossRows = {}
local RedrawBossList

-- Identity of the instance the boss list currently describes. Compared on every
-- zone change so a move into a *different* dungeon/raid (e.g. walking through a
-- dungeon to reach a raid, or starting a second dungeon without toggling DC off)
-- drops the prior run's stale list instead of clinging to it. nil = open world.
local currentInstanceKey = nil
local function GetInstanceKey()
    local inInstance, instanceType = IsInInstance()
    if not inInstance then return nil end
    -- Instance name distinguishes dungeons/raids; the type guards the rare
    -- same-name case. GetInstanceInfo's first return is the localized name.
    local name
    if GetInstanceInfo then name = GetInstanceInfo() end
    name = name or GetRealZoneText() or ""
    return instanceType .. ":" .. name
end
local UpdateFrameHeight, UpdateLayout
local pauseBtn
local spectateBtn
local spectatePrevBtn, spectateNextBtn  -- seat cycling (< / >) on the same row
local spectateAvailable        -- server allows the spectator camera? (SPECTATE msg)
local ApplySpectateAvailability -- enable/disable the Spectate button to match
local spectateResetBtn         -- ends the camera and hands control back to you
-- What the spectator camera is doing. The server never tells the addon, so this
-- is modelled from the commands we send -- the one source that is always there.
-- PLAYER_CONTROL_LOST/GAINED only correct it when this server happens to raise
-- them; they cannot be relied on, because a module that hands your character to
-- the bot AI can leave you unable to move without ever sending the client a
-- control update.
--
--   false     nothing running -- the camera is on your own character
--   "free"    free-flying camera
--   "follow"  riding a bot
--
-- The distinction earns its keep in the reset: a bare `spectate` toggles the
-- mode you are IN, so ending the follow cam takes two (the first only hands over
-- to the free camera) while the free camera ends on one. Knowing which we are in
-- is what makes one click enough without ever sending a toggle too many.
local cameraState = false
local UpdateResetBtnState      -- greys the reset button in/out with the state
local SetCameraState           -- single place that moves cameraState
local RefreshStatusHeight      -- re-measure the Warning row, then resize to fit
local pullLabel          -- "Pull:" caption left of the segmented control
local pullSegs = {}      -- [0]=Off [1]=On [2]=Dynamic segment buttons (full mode)
local tinyPullDot        -- compact cycling pull circle (tiny mode)
local tinyPullToggle     -- invisible click target over the pull circle
local tinyPullText       -- pull-state caption beside the pull circle
local UpdatePullControls -- styles the segments + tiny circle to the current state
local isDCOn = false
local isPaused = false
-- Advanced-pull preference mirrored from the server's tri-state STATUS field:
-- 0 = Off, 1 = On, 2 = Dynamic. Initialized to the server's default (Dynamic)
-- so the pre-STATUS display matches; the first STATUS overwrites it anyway.
local pullSetting = 2
-- Live Dynamic verdict for the pack the tank is sizing up (server STATUS index
-- 10): 0 none / 1 Leeroy / 2 Advanced / 3 waiting-for-patrol. Only meaningful
-- while pullSetting == 2.
local pullDecision = 0
-- Display metadata per pull state: segment label, command keyword, accent color.
local PullStates = {
    [0] = { seg = "Leeroy",   cmd = "off",     color = {0.55, 0.55, 0.55} },
    [1] = { seg = "Advanced", cmd = "on",      color = {0.20, 0.85, 0.30} },
    [2] = { seg = "Dynamic",  cmd = "dynamic", color = {0.30, 0.70, 1.00} },
}
-- Per Dynamic-verdict display: full + tiny labels and an accent. Leeroy = amber
-- (charge in), Advanced = blue (careful pull), Waiting = yellow (holding for a
-- patrol to pass before committing).
local DynVerdicts = {
    [1] = { full = "Leeroy",   tiny = "L", color = {1.00, 0.65, 0.10} },
    [2] = { full = "Advanced", tiny = "A", color = {0.30, 0.70, 1.00} },
    [3] = { full = "Waiting for patrol", tiny = "W", color = {1.00, 0.90, 0.30} },
}

-- Settings panel (Interface -> AddOns -> DungeonClear -> Settings). These are
-- forward-declared so OnAddonMessage / ADDON_LOADED (defined above the panel
-- code) can call them; they're assigned in the settings-panel block below.
local HandleSettingsLine        -- (parts) -> upsert one SETTINGS row
local OnSettingsSyncBoundary    -- ("start"|"end") -> frame a sync batch
local PushSettings              -- re-send saved overrides to the server
local BuildSettingsFromCache    -- render rows from the cached schema at load


-- UI Frame Creation
local frame = CreateFrame("Frame", "DungeonClearFrame", UIParent)
frame:SetSize(330, 452)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetClampedToScreen(true)
-- Sit above most default UI so the readout stays usable
frame:SetFrameStrata("DIALOG")
frame:SetToplevel(true)
frame:SetScript("OnDragStart", function(self)
    -- Read by PinTopLeft: re-anchoring the frame mid-drag breaks StartMoving's
    -- grip on it, and a STATUS packet can land at any moment during a run.
    self.isMoving = true
    self:StartMoving()
end)
-- Right-click anywhere on the tiny bar restores the full window. Guarded by
-- tinyMode so right-clicks in full mode do nothing, and left-drag still moves.
frame:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" and DungeonClearDB.tinyMode then
        DungeonClearDB.tinyMode = false
        UpdateLayout()
    end
end)

-- Sleek Dark Backdrop
frame:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 }
})
frame:SetBackdropColor(0.03, 0.03, 0.05, 0.90)
frame:SetBackdropBorderColor(0.20, 0.22, 0.28, 1.0)

-- Header Text
local header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
-- Left-aligned so the 中文/EN + Tiny buttons on the right never overlap it.
header:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -12)
DCBind(header, "Dungeon Clear")
header:SetTextColor(0.24, 0.60, 1.0) -- Premium blue

-- Close Button
local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
closeBtn:SetScript("OnClick", function()
    frame:Hide()
end)

-- Status Info Subframe (Glassmorphism effect)
-- Base height with the Warning row hidden. When a warning is showing the box
-- grows by STALL_GAP plus however tall the wrapped warning actually came out
-- (see StallRowHeight) -- it is free text from the server, so no fixed reserve
-- can be right for every message.
local STATUS_H = 131
local STALL_GAP = 8
local statusFrame = CreateFrame("Frame", nil, frame)
statusFrame:SetSize(306, STATUS_H)
statusFrame:SetPoint("TOP", frame, "TOP", 0, -35)
statusFrame:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 12, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
})
statusFrame:SetBackdropColor(0.10, 0.12, 0.16, 0.60)
statusFrame:SetBackdropBorderColor(0.15, 0.17, 0.22, 0.8)

-- Status fields
local statusLabel = statusFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
statusLabel:SetPoint("TOPLEFT", statusFrame, "TOPLEFT", 10, -10)
DCBind(statusLabel, "Mode Status:")
statusLabel:SetTextColor(0.8, 0.8, 0.8)

local statusVal = statusFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
statusVal:SetPoint("LEFT", statusLabel, "RIGHT", 5, 0)
statusVal:SetText(DCL("OFF"))
statusVal:SetTextColor(0.5, 0.5, 0.5)

-- Pull-mode readout. Mirrors the segmented control's active state and, in
-- Dynamic, the live per-pack verdict (Leeroy / Advanced). This used to be
-- crammed into the Dyn segment label, where it overflowed the button.
local pullModeLabel = statusFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
pullModeLabel:SetPoint("TOPLEFT", statusLabel, "BOTTOMLEFT", 0, -8)
DCBind(pullModeLabel, "Pull Mode:")
pullModeLabel:SetTextColor(0.8, 0.8, 0.8)

local pullModeVal = statusFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
pullModeVal:SetPoint("LEFT", pullModeLabel, "RIGHT", 5, 0)
pullModeVal:SetText(DCL("Dynamic"))
pullModeVal:SetTextColor(0.6, 0.6, 0.6)

local stateLabel = statusFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
stateLabel:SetPoint("TOPLEFT", pullModeLabel, "BOTTOMLEFT", 0, -8)
DCBind(stateLabel, "Current State:")
stateLabel:SetTextColor(0.8, 0.8, 0.8)

local stateVal = statusFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
-- Anchor TOPLEFT (not LEFT) so a wrapped second line grows downward instead of
-- expanding around the vertical center into the row above. Width-bounded + LEFT
-- justified so a long state string word-wraps within the frame rather than
-- spilling outside the window (mirrors the stallVal treatment below).
stateVal:SetPoint("TOPLEFT", stateLabel, "TOPRIGHT", 5, 0)
stateVal:SetWidth(196)
stateVal:SetJustifyH("LEFT")
stateVal:SetText(DCL("Inactive"))
stateVal:SetTextColor(0.6, 0.6, 0.6)

-- Free-text detail sub-line under the state (who we're waiting on, what we're
-- heading to, etc.). Wraps to a second line if needed; the reserved gap below
-- keeps the Next Boss / Warning rows from shifting.
local detailVal = statusFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
detailVal:SetPoint("TOPLEFT", stateLabel, "BOTTOMLEFT", 0, -2)
-- 286, not 300: the row starts 10px inside a 306-wide box, so 300 ran past the
-- right edge before the 3px border inset was even counted.
detailVal:SetWidth(286)
detailVal:SetJustifyH("LEFT")
detailVal:SetTextColor(0.7, 0.7, 0.7)
detailVal:SetText("")

local targetLabel = statusFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
-- Reserve enough vertical room for a TWO-LINE detail sub-line above (a long
-- "En route to <boss>." with a parenthesised boss name wraps to two lines of
-- GameFontHighlightSmall, ~17px each). The old -34 left only ~32px, so the
-- second detail line landed on this Next Boss row. -44 clears two full lines
-- with margin; everything below shifts down the same 10px (see the matching
-- statusFrame / frame height bumps) so no new overlap is introduced.
targetLabel:SetPoint("TOPLEFT", stateLabel, "BOTTOMLEFT", 0, -44)
DCBind(targetLabel, "Next Boss:")
targetLabel:SetTextColor(0.8, 0.8, 0.8)

local targetVal = statusFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
targetVal:SetPoint("LEFT", targetLabel, "RIGHT", 5, 0)
-- Unbounded, a long objective name ("Objective: Atal'ai Defender (Mijan)") ran
-- straight out through the box and the window edge. Clamp it to the space left
-- beside the caption and truncate rather than wrap -- wrapping around a LEFT
-- anchor would grow upward into the detail line above.
targetVal:SetWidth(210)
targetVal:SetJustifyH("LEFT")
targetVal:SetWordWrap(false)
targetVal:SetText(DCL("None"))
targetVal:SetTextColor(1, 1, 1)

local stallLabel = statusFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
stallLabel:SetPoint("TOPLEFT", targetLabel, "BOTTOMLEFT", 0, -8)
DCBind(stallLabel, "Warning:")
stallLabel:SetTextColor(0.9, 0.2, 0.2)
stallLabel:Hide()

local stallVal = statusFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
-- TOPLEFT, not LEFT: warning text is server-authored and regularly wraps, and a
-- LEFT anchor centers the wrapped block on the caption, so the second line grew
-- *upward* into the Next Boss row. Anchored at the top it grows downward, and
-- the box grows with it. (Same fix as stateVal above.)
stallVal:SetPoint("TOPLEFT", stallLabel, "TOPRIGHT", 5, 0)
stallVal:SetTextColor(0.9, 0.4, 0.4)
stallVal:SetWidth(226)
stallVal:SetJustifyH("LEFT")
stallVal:Hide()

-- Warning row height, MEASURED rather than reserved. The warning is free text
-- from the server of any length, so the two lines the box used to reserve for it
-- (the old flat SetHeight(151)) were a guess: anything that wrapped to a third
-- line ran straight out of the box and over the action buttons below. Ask the
-- engine how tall the wrapped block actually came out and let the status box --
-- and with it the window, whose height is summed from this one in
-- UpdateFrameHeight -- follow along.
-- GetStringHeight and GetHeight disagree depending on how far the engine has got
-- with the layout, so take whichever is larger, with one caption line as the
-- floor so a one-word warning still gets a full row.
local function StallRowHeight()
    local h = 14
    local lh = stallLabel:GetHeight()
    if lh and lh > h then h = lh end
    local sh = stallVal:GetStringHeight()
    if sh and sh > h then h = sh end
    local rh = stallVal:GetHeight()
    if rh and rh > h then h = rh end
    return h
end

local function ApplyStatusHeight()
    if stallVal:IsShown() then
        statusFrame:SetHeight(STATUS_H + STALL_GAP + StallRowHeight())
    else
        statusFrame:SetHeight(STATUS_H)
    end
    if UpdateFrameHeight then UpdateFrameHeight() end
end

-- The engine only finishes laying wrapped text out on the frame AFTER SetText,
-- so the measurement taken the instant a new warning arrives can still describe
-- the previous one. Re-measure over the next few frames and then stop; a hidden
-- frame gets no OnUpdate, which is what Hide() is doing here as the off switch.
local stallTicker = CreateFrame("Frame")
stallTicker:Hide()
local stallTicks = 0
stallTicker:SetScript("OnUpdate", function(self)
    stallTicks = stallTicks + 1
    ApplyStatusHeight()
    if stallTicks >= 3 then self:Hide() end
end)

RefreshStatusHeight = function()
    ApplyStatusHeight()
    stallTicks = 0
    stallTicker:Show()
end

-- Tiny (single-line) display: on/off circle + status + targeted boss
local tinyIndicator = frame:CreateTexture(nil, "OVERLAY")
tinyIndicator:SetSize(16, 16)
tinyIndicator:SetPoint("LEFT", frame, "LEFT", 10, 0)
tinyIndicator:SetTexture("Interface\\FriendsFrame\\StatusIcon-Offline")
tinyIndicator:Hide()

local tinyText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
tinyText:SetPoint("LEFT", tinyIndicator, "RIGHT", 6, 0)
tinyText:SetText(DCL("Off"))
tinyText:Hide()

-- Click target over the tiny circle; created after SendDcCommand is defined so
-- its OnClick can capture it. Forward-declared here for UpdateLayout/UpdateStatusUI.
local tinyToggle

-- Compact state -> (label, color) for the tiny line
local function FormatStateTinyEN(state)
    if state == "paused" then return "Paused", {0.9, 0.8, 0.2}
    elseif state == "pulling" then return "Pulling to Camp", {0.3, 0.8, 1}
    elseif state == "moving" then return "Advancing", {0.2, 0.7, 1}
    elseif state == "pathing" then return "Plotting Route", {0.4, 0.7, 0.9}
    elseif state == "pursuing" then return "Closing In", {0.3, 0.8, 1}
    elseif state == "recovering" then return "Repathing", {0.9, 0.6, 0.2}
    elseif state == "resting" then return "Resting", {0.9, 0.8, 0.2}
    elseif state == "looting" then return "Looting", {0.9, 0.6, 0.1}
    elseif state == "door_blocked" then return "Door Blocked", {0.9, 0.2, 0.2}
    elseif state == "stalled" then return "Blocked", {0.9, 0.2, 0.2}
    elseif state == "fighting_trash" then return "Clearing Trash", {0.8, 0.3, 0.9}
    elseif state == "fighting_boss" then return "Boss Fight", {1, 0.2, 0.2}
    elseif state == "idle" then return "Idle", {0.6, 0.6, 0.6}
    end
    return "Active", {0.8, 0.8, 0.8}
end
local function FormatStateTiny(state)
    local label, color = FormatStateTinyEN(state)
    return DCL(label), color
end

local function RgbToHex(c)
    return string.format("%02x%02x%02x", math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end

-- Size the frame to hug the single-line content in tiny mode
local function UpdateTinyWidth()
    -- pad(10) + status circle(16) + gap(6) + pull circle(16) + gap(4)
    -- + pull caption + gap(2) + action text + pad(12)
    local w = 10 + 16 + 6 + 16 + 4 + (tinyPullText and tinyPullText:GetStringWidth() or 0)
        + 2 + (tinyText:GetStringWidth() or 0) + 12
    frame:SetWidth(math.max(170, w))
end

-- Helper to update status styling
-- Last STATUS seen, replayed when the language changes (DCLoc.OnChange below).
local lastStatusArgs
local function UpdateStatusUI(enabled, targetName, state, stallReason, detail, pullMode, pullDec)
    lastStatusArgs = { enabled, targetName, state, stallReason, detail, pullMode, pullDec }
    isPaused = (state == "paused")
    pullSetting = tonumber(pullMode) or 2
    if not PullStates[pullSetting] then pullSetting = 2 end
    pullDecision = tonumber(pullDec) or 0
    if not enabled or enabled == "0" then
        isDCOn = false
        isPaused = false
        statusVal:SetText(DCL("OFF"))
        statusVal:SetTextColor(0.5, 0.5, 0.5)
        stateVal:SetText(DCL("Inactive"))
        stateVal:SetTextColor(0.6, 0.6, 0.6)
        detailVal:SetText("")
        targetVal:SetText(DCL("None"))
        targetVal:SetTextColor(0.6, 0.6, 0.6)
        stallLabel:Hide()
        stallVal:Hide()
        RefreshStatusHeight()
    else
        isDCOn = true
        if isPaused then
            statusVal:SetText(DCL("PAUSED"))
            statusVal:SetTextColor(0.9, 0.8, 0.2) -- Yellow
        else
            statusVal:SetText(DCL("ON"))
            statusVal:SetTextColor(0.1, 0.9, 0.1) -- Green
        end

        -- Format state human readable
        local stateText = state or "Idle"
        local stateColor = {0.8, 0.8, 0.8}
        if state == "paused" then
            stateText = "Paused"
            stateColor = {0.9, 0.8, 0.2} -- Yellow
        elseif state == "pulling" then
            stateText = "Advanced Pull"
            stateColor = {0.3, 0.8, 1} -- Light blue
        elseif state == "moving" then
            stateText = "Advancing"
            stateColor = {0.2, 0.7, 1} -- Light blue
        elseif state == "pathing" then
            stateText = "Plotting Route"
            stateColor = {0.4, 0.7, 0.9} -- Blue
        elseif state == "pursuing" then
            stateText = "Closing on Boss"
            stateColor = {0.3, 0.8, 1} -- Light blue
        elseif state == "recovering" then
            stateText = "Recovering / Repathing"
            stateColor = {0.9, 0.6, 0.2} -- Amber
        elseif state == "resting" then
            stateText = "Party Recovering / Resting"
            stateColor = {0.9, 0.8, 0.2} -- Yellow
        elseif state == "looting" then
            stateText = "Collecting Loot"
            stateColor = {0.9, 0.6, 0.1} -- Orange
        elseif state == "door_blocked" then
            stateText = "Blocked by Door"
            stateColor = {0.9, 0.2, 0.2} -- Red
        elseif state == "stalled" then
            stateText = "Route Blocked"
            stateColor = {0.9, 0.2, 0.2} -- Red
        elseif state == "fighting_trash" then
            stateText = "Clearing Path (Trash)"
            stateColor = {0.8, 0.3, 0.9} -- Purple
        elseif state == "fighting_boss" then
            stateText = "Engaging Boss!"
            stateColor = {1, 0.1, 0.1} -- Crimson
        elseif state == "idle" then
            stateText = "Idle / Waiting"
            stateColor = {0.6, 0.6, 0.6}
        end
        stateVal:SetText(DCL(stateText))
        stateVal:SetTextColor(unpack(stateColor))

        if state == "paused" then
            -- `detail` carries WHY we're paused (a manual hold, or a door the
            -- tank can't open) and can be a long sentence, so surface it on the
            -- wrapping sub-line rather than the fixed-width state label above.
            local reason = (detail and detail ~= "") and DCLDetail(detail) or DCLDetail("holding position")
            if DCLoc.IsZh() then
                detailVal:SetText("原地待命（" .. reason .. "），首领进度已保存。")
            else
                detailVal:SetText("Holding (" .. reason .. "); boss progress saved.")
            end
        else
            detailVal:SetText(DCLDetail(detail) or "")
        end

        targetVal:SetText(DCLName(targetName) or DCL("None"))
        targetVal:SetTextColor(1, 0.82, 0) -- Gold

        if stallReason and stallReason ~= "" then
            stallLabel:Show()
            stallVal:Show()
            stallVal:SetText(DCLDetail(stallReason))
        else
            stallLabel:Hide()
            stallVal:Hide()
        end
        -- Measured, not reserved. SetText above only QUEUES the layout, so this
        -- re-measures over the next few frames as well as right now.
        RefreshStatusHeight()
    end

    -- Update the tiny single-line display: circle + status + boss
    if not enabled or enabled == "0" then
        tinyIndicator:SetTexture("Interface\\FriendsFrame\\StatusIcon-Offline")
        tinyText:SetText("|cff999999" .. DCL("Off") .. "|r")
    else
        if isPaused then
            -- Yellow "away" dot signals a held/paused clear.
            tinyIndicator:SetTexture("Interface\\FriendsFrame\\StatusIcon-Away")
        elseif state == "stalled" or state == "door_blocked" then
            -- Red "busy" dot flags an error state that needs player attention.
            tinyIndicator:SetTexture("Interface\\FriendsFrame\\StatusIcon-DnD")
        else
            tinyIndicator:SetTexture("Interface\\FriendsFrame\\StatusIcon-Online")
        end
        local tLabel, tColor = FormatStateTiny(state)
        -- Verbose tiny line: the action sentence (who we're waiting on / where
        -- we're heading), colored by the state, then a grey pipe divider and
        -- the target boss name. Falls back to the state label when there's no
        -- detail. For an ERROR state (stalled / door-blocked) the server leaves
        -- `detail` empty and carries the explanation in the separate stall field,
        -- so surface THAT (capped) instead of a bare, uninformative "Blocked".
        local actionText = (detail and detail ~= "") and DCLDetail(detail) or tLabel
        if (not detail or detail == "") and stallReason and stallReason ~= "" then
            actionText = DCLDetail(stallReason)
            if not DCLoc.IsZh() and string.len(actionText) > 64 then
                actionText = string.sub(actionText, 1, 63) .. "..."
            end
        end
        local line = "|cff" .. RgbToHex(tColor) .. actionText .. "|r"
        if targetName and targetName ~= "None" and targetName ~= "" then
            -- grey vertical divider between action and boss name
            line = line .. "  |cff808080||" .. "|r  |cffffd100" .. DCLName(targetName) .. "|r"
        end
        tinyText:SetText(line)
    end
    -- Pause/Resume button: label reflects current state; disabled when DC is off.
    if pauseBtn then
        if not isDCOn then
            pauseBtn:SetText(DCL("Pause"))
            pauseBtn:Disable()
        else
            pauseBtn:SetText(DCL(isPaused and "Resume" or "Pause"))
            pauseBtn:Enable()
        end
    end
    -- Advanced-pull controls (full-mode segments + tiny cycle button) reflect the
    -- tri-state preference and DC's enabled gate.
    if UpdatePullControls then UpdatePullControls() end

    if DungeonClearDB.tinyMode then
        UpdateTinyWidth()
    end

    if UpdateFrameHeight then
        UpdateFrameHeight()
    end
end

-- Command sender via addon messages (silent, no audio cue)
-- Uses PARTY distribution with LANG_ADDON prefix; the server-side hook
-- intercepts and dispatches before any chat processing occurs.
--
-- Solo transport: a player with no group has no PARTY or RAID channel, so this
-- used to refuse outright — which is what stopped a GM from watching a test run
-- from OUTSIDE the bot party. Spectate is session plumbing and never needed a
-- group; the group requirement lived only here, in the transport. A whisper to
-- oneself is the standard addon channel with no group, and the server hook
-- accepts it (IsDcAddonCommand). Bot commands sent this way still need a tank
-- bot in the sender's group and are refused server-side with that reason, which
-- is a truer error than a client-side guess.
local function SendDcCommand(subCmd, param, silent)
    local inRaid = GetNumRaidMembers() and GetNumRaidMembers() > 0
    local inParty = GetNumPartyMembers() and GetNumPartyMembers() > 0

    local payload = "CMD\t" .. subCmd
    if param and param ~= "" then
        payload = payload .. "\t" .. tostring(param)
    end

    if inRaid or inParty then
        -- In a raid, addon messages on the PARTY channel only reach the sender's
        -- own subgroup, so a tank bot in another subgroup never gets the command.
        -- Send on RAID when in a raid so it reaches every subgroup; PARTY covers
        -- the ordinary 5-man case. The server hook accepts both.
        SendAddonMessage("DC", payload, inRaid and "RAID" or "PARTY")
        return
    end

    local me = UnitName("player")
    if me and me ~= "" then
        SendAddonMessage("DC", payload, "WHISPER", me)
    elseif not silent and param ~= "addon" then
        DEFAULT_CHAT_FRAME:AddMessage(DCL("|cffff3333DungeonClear: cannot send bot commands right now.|r"))
    end
end

-- RebornWOW DCGM1F: cheat-tier tag at the top right of the status box (design §9.5):
-- always one of [Normal] / [Story] / [Casual] / [Speed] for the party this panel
-- controls -- the test run you watch, else the party you are in. Polled every 5 s
-- while the panel is open (the poller is a child of the panel). A do-block keeps its
-- locals out of the main chunk's 200-local budget.
do
    local tag = statusFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tag:SetPoint("TOPRIGHT", statusFrame, "TOPRIGHT", -10, -10)
    local TIERS = { normal = { "Normal", "|cffcccccc" }, story = { "Story", "|cff3da6ff" },
                    casual = { "Casual", "|cff00ff00" }, speed = { "Speed", "|cffff6600" } }
    local current = nil
    local function Paint()
        DCCurrentTier = current  -- RebornWOW DCUI3D1: the panel's top bar shows it too
        local t = TIERS[current or ""]
        if t then tag:SetText(t[2] .. "[" .. DCL(t[1]) .. "]|r") else tag:SetText("") end
    end
    DCLoc.OnChange(Paint)
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("CHAT_MSG_ADDON")
    ev:SetScript("OnEvent", function(_, _, prefix, msg)
        if prefix ~= "DC" or type(msg) ~= "string" or msg:sub(1, 5) ~= "TIER\t" then return end
        local _, tier = strsplit("\t", msg)
        current = tier
        Paint()
    end)
    local elapsed = 5
    local poller = CreateFrame("Frame", nil, frame)
    poller:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed < 5 then return end
        elapsed = 0
        SendDcCommand("tier", "", true)
    end)
    -- ask again right after a tier was changed from a menu
    function DCTierRefreshSoon() elapsed = 4 end
end

-- Action Buttons Panel
-- Four-up action row: On / Off / Skip / Pause-Resume (narrowed to fit one row).
local onBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
onBtn:SetSize(68, 24)
onBtn:SetPoint("TOPLEFT", statusFrame, "BOTTOMLEFT", 0, -8)
DCBind(onBtn, "On")
onBtn:SetScript("OnClick", function()
    SendDcCommand("on")
    -- The leader tank is elected on "on"; push the player's overrides right
    -- after so the run starts with their settings rather than the defaults.
    if PushSettings then PushSettings() end
end)

local offBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
offBtn:SetSize(68, 24)
offBtn:SetPoint("LEFT", onBtn, "RIGHT", 11, 0)
DCBind(offBtn, "Off")
offBtn:SetScript("OnClick", function() SendDcCommand("off") end)

local skipBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
skipBtn:SetSize(68, 24)
skipBtn:SetPoint("LEFT", offBtn, "RIGHT", 11, 0)
DCBind(skipBtn, "Skip")
skipBtn:SetScript("OnClick", function() SendDcCommand("skip") end)

-- Pause/Resume toggle. Label + enabled state are driven by UpdateStatusUI.
-- The click sends the label's INTENT ("pause"/"resume") rather than a bare
-- toggle: a bare "pause" flips whatever the server's flag happens to be, so a
-- click aimed at "Pause" landing just after an auto-pause (door, Wait at Boss)
-- would resume the run instead. With the intent the server no-ops the
-- already-holding case and just resyncs our label.
pauseBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
pauseBtn:SetSize(68, 24)
pauseBtn:SetPoint("LEFT", skipBtn, "RIGHT", 11, 0)
pauseBtn:SetText(DCL("Pause"))
pauseBtn:SetScript("OnClick", function()
    SendDcCommand("pause", isPaused and "resume" or "pause")
end)

-- Advanced-pull control on a second row: a "Pull:" caption + a 3-segment
-- Off / On / Dynamic picker (replaces the old full-width toggle button). Each
-- segment sends an explicit state so there's no client/server cycle drift; the
-- active segment is highlighted + accent-colored by UpdatePullControls. Dynamic
-- is wired through but is a no-op stub server-side for now.
pullLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
pullLabel:SetPoint("TOPLEFT", onBtn, "BOTTOMLEFT", 2, -14)
DCBind(pullLabel, "Pull:")
pullLabel:SetTextColor(0.8, 0.8, 0.8)

local PULL_SEG_W = 86
for i = 0, 2 do
    local seg = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    seg:SetSize(PULL_SEG_W, 24)
    if i == 0 then
        seg:SetPoint("LEFT", pullLabel, "RIGHT", 8, 0)
    else
        seg:SetPoint("LEFT", pullSegs[i - 1], "RIGHT", 2, 0)
    end
    seg:SetText(DCL(PullStates[i].seg))
    seg:SetScript("OnClick", function()
        SendDcCommand("pull", PullStates[i].cmd)
    end)
    pullSegs[i] = seg
end

-- Spectate toggle on its own row: detaches the player into a free-flying
-- camera while their character keeps running under bot AI (server-side
-- possession of an invisible dummy). Stateless label v1 — the server messages
-- confirm on/off. Independent of DC on/off, but the server can disable the
-- feature entirely (DungeonClear.SpectateEnable = 0): when it does, the SPECTATE
-- message flips spectateAvailable false and the button greys out (see
-- ApplySpectateAvailability). Assume available until the server says otherwise.
spectateBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
spectateBtn:SetSize(100, 24)
-- The pull-row segments span -8..-32 below onBtn (24px buttons centered on
-- the label); start this row at -40 to keep the 8px row gap.
spectateBtn:SetPoint("TOPLEFT", onBtn, "BOTTOMLEFT", 0, -40)
DCBind(spectateBtn, "Spectate")
-- Left-click = the free-flying camera. Right-click (or shift-click) = follow
-- cam: the view rides the run's tank instead of flying free, which is what you
-- want when watching rather than exploring. Both are the same server toggle
-- family, so a second click of either ends the camera.
spectateBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
spectateBtn:SetScript("OnClick", function(self, button)
    if button == "RightButton" or IsShiftKeyDown() then
        SendDcCommand("spectate", "follow")
        SetCameraState("follow")
    else
        -- A bare toggle means different things from different seats: from no
        -- camera it starts the free one, from the follow cam it hands over TO
        -- the free one, and only from the free camera does it actually end.
        SendDcCommand("spectate")
        if cameraState == "free" then
            SetCameraState(false)
        else
            SetCameraState("free")
        end
    end
end)

-- Grey out and disable the Spectate button when the server has the feature
-- switched off, so the player can't click into a refusal. A disabled
-- UIPanelButtonTemplate is automatically dimmed and unclickable; the tooltip
-- explains why.
spectateAvailable = true
ApplySpectateAvailability = function()
    if not spectateBtn then return end
    -- The cycle buttons are the same feature; grey them out with it, or they
    -- would click into the same refusal the Spectate button is greyed to avoid.
    for _, b in ipairs({ spectateBtn, spectatePrevBtn, spectateNextBtn }) do
        if b then
            if spectateAvailable then b:Enable() else b:Disable() end
        end
    end
    -- The reset has a second condition (is a camera even running?), so it goes
    -- through its own rule rather than being flipped with the rest of the row.
    if UpdateResetBtnState then UpdateResetBtnState() end
end

spectateBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if not spectateAvailable then
        GameTooltip:SetText(DCL("Spectator mode disabled"), 1, 1, 1)
        GameTooltip:AddLine(DCL("This server has turned off the spectator camera."),
            0.8, 0.8, 0.8, true)
        GameTooltip:Show()
        return
    end
    GameTooltip:SetText(DCL("Spectate"), 1, 1, 1)
    GameTooltip:AddLine(DCL("Left-click: free-flying camera."), 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine(DCL("Right-click: follow cam \226\128\148 your view rides the tank."),
        0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end)
spectateBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Seat cycling, on the same row as Spectate. The camera can sit on ANY bot in
-- the instance, not just the tank — watch the healer through a wipe, a DPS
-- through a burn — and clicking beats typing a randomised bot name. From no
-- camera at all these also start one (server side treats a cycle from cold as
-- "take the default seat"), so this row is a complete spectator control.
spectatePrevBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
spectatePrevBtn:SetSize(30, 24)
spectatePrevBtn:SetPoint("LEFT", spectateBtn, "RIGHT", 6, 0)
spectatePrevBtn:SetText("|cffffd100<|r")
spectatePrevBtn:SetScript("OnClick", function()
    SendDcCommand("spectate", "prev")
    SetCameraState("follow")  -- cycling from cold starts a follow cam too
end)
spectatePrevBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(DCL("Previous bot"), 1, 1, 1)
    GameTooltip:AddLine(DCL("Move the camera to the previous bot in the instance."),
        0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end)
spectatePrevBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

spectateNextBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
spectateNextBtn:SetSize(30, 24)
spectateNextBtn:SetPoint("LEFT", spectatePrevBtn, "RIGHT", 4, 0)
spectateNextBtn:SetText("|cffffd100>|r")
spectateNextBtn:SetScript("OnClick", function()
    SendDcCommand("spectate", "next")
    SetCameraState("follow")
end)
spectateNextBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(DCL("Next bot"), 1, 1, 1)
    GameTooltip:AddLine(DCL("Move the camera to the next bot in the instance. " ..
        "Starts the follow cam if it isn't running."), 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end)
spectateNextBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Way back: ends whatever camera is running and returns you to your own body.
-- It gets its own button because the exit was not discoverable -- nothing on
-- this row said how to get out, and while the camera rides a bot your character
-- does not answer to the keyboard, so being stuck there is the worst state the
-- panel can leave you in. Flush right on the spectate row, set apart from the
-- < > pair by a wider gap so it reads as the exit rather than a third seat
-- control.
spectateResetBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
spectateResetBtn:SetSize(110, 24)
spectateResetBtn:SetPoint("TOPRIGHT", pauseBtn, "BOTTOMRIGHT", 0, -40)
DCBind(spectateResetBtn, "Reset Camera")

-- Greyed out whenever no camera is running, so the button can only ever end one.
UpdateResetBtnState = function()
    if not spectateResetBtn then return end
    if spectateAvailable ~= false and (cameraState ~= false or DCTestWatchActive) then
        spectateResetBtn:Enable()
    else
        spectateResetBtn:Disable()
    end
end

SetCameraState = function(state)
    cameraState = state
    UpdateResetBtnState()
end

-- Apply the starting state now, or the button would sit there looking clickable
-- until something first moved the camera.
UpdateResetBtnState()

-- Ending the follow cam takes two toggles, and they cannot go out back to back:
-- the first has to reach the server and hand the camera over before the second
-- means anything. So the reset sends one now and queues this one a second later.
local secondToggle = CreateFrame("Frame")
local secondElapsed = 0
secondToggle:Hide()
secondToggle:SetScript("OnUpdate", function(self, elap)
    secondElapsed = secondElapsed + elap
    if secondElapsed < 1.0 then return end
    self:Hide()
    SendDcCommand("spectate")
end)

spectateResetBtn:SetScript("OnClick", function()
    -- The whole contract of this button: it always leaves the camera on your own
    -- character, and never takes it away. With nothing running there is nothing
    -- to end, and a toggle here would START a camera -- so it does nothing at
    -- all. Same rule the greying-out uses, belt and braces.
    -- DCTEST4C: while watching a bot test run, "reset" means end the watch: it puts
    -- you back where you were and visible again. Ending only the camera left your
    -- character standing at the test instance's entrance.
    if DCTestWatchActive then
        DCTestWatchActive = false
        SetCameraState(false)
        SendChatMessage(".dc test watch off", "SAY")
        return
    end
    if cameraState == false then return end

    -- Only the follow cam needs the follow-up; from the free camera a second
    -- toggle would switch a fresh camera back on.
    local needsSecond = (cameraState == "follow")
    SetCameraState(false)
    SendDcCommand("spectate")
    secondElapsed = 0
    if needsSecond then secondToggle:Show() end
end)

spectateResetBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(DCL("Reset Camera"), 1, 1, 1)
    GameTooltip:AddLine(DCL("Ends the spectator camera and hands control of your " ..
        "own character back to you."), 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end)
spectateResetBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Invisible click target over the tiny circle. Off -> start DC; running ->
-- toggle pause/resume. Only shown in tiny mode (see UpdateLayout). Sits over
-- just the 16x16 dot so dragging the rest of the bar still works.
tinyToggle = CreateFrame("Button", "DungeonClearTinyToggle", frame)
tinyToggle:SetAllPoints(tinyIndicator)
tinyToggle:EnableMouse(true)
tinyToggle:RegisterForClicks("LeftButtonUp", "RightButtonUp")
tinyToggle:SetScript("OnClick", function(self, button)
    -- Right-click over the circle expands back to the full window (matches the
    -- frame-level OnMouseUp handler that covers the rest of the tiny bar).
    if button == "RightButton" then
        DungeonClearDB.tinyMode = false
        UpdateLayout()
        return
    end
    if not isDCOn then
        SendDcCommand("on")
        if PushSettings then PushSettings() end
    else
        -- Send the intent, not a bare toggle — see pauseBtn's OnClick note.
        SendDcCommand("pause", isPaused and "resume" or "pause")
    end
end)
tinyToggle:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    if not isDCOn then
        GameTooltip:AddLine(DCL("Dungeon Clear"))
        GameTooltip:AddLine(DCL("Left-click to start the clear"), 0.8, 0.8, 0.8, true)
    else
        GameTooltip:AddLine(DCL(isPaused and "Paused" or "Clearing"))
        GameTooltip:AddLine(DCL(isPaused and "Left-click to resume" or "Left-click to pause"), 0.8, 0.8, 0.8, true)
    end
    GameTooltip:AddLine(DCL("Right-click to expand the window"), 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end)
tinyToggle:SetScript("OnLeave", function() GameTooltip:Hide() end)
tinyToggle:Hide()

-- Tiny-mode advanced-pull control: a small colored circle right after the status
-- (pause) circle that cycles Off -> On -> Dynamic, mirroring the pause dot. The
-- live pull state reads out as a short caption beside it, capped with a grey "|"
-- pipe that separates it from the action/boss line that follows.
tinyPullDot = frame:CreateTexture(nil, "OVERLAY")
tinyPullDot:SetSize(16, 16)
tinyPullDot:SetPoint("LEFT", tinyIndicator, "RIGHT", 6, 0)
-- Reuse the FriendsFrame status dots (same family as the pause circle, which is
-- known to render). The texture is swapped per state by UpdatePullControls.
tinyPullDot:SetTexture("Interface\\FriendsFrame\\StatusIcon-Offline")

tinyPullText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
tinyPullText:SetPoint("LEFT", tinyPullDot, "RIGHT", 4, 0)
tinyPullText:SetText(DCL("Off"))

-- The action/boss status text now trails the pull caption.
tinyText:ClearAllPoints()
tinyText:SetPoint("LEFT", tinyPullText, "RIGHT", 2, 0)

-- Invisible click target over the pull circle: left-click cycles Off -> On ->
-- Dynamic; right-click expands back to the full window (matching the other tiny
-- controls). Live whether or not DC is running -- the pull mode is a preference
-- the server stores and applies on the next `dc on`, so it is settable ahead of
-- the run. Shown only in tiny mode.
tinyPullToggle = CreateFrame("Button", "DungeonClearTinyPull", frame)
tinyPullToggle:SetAllPoints(tinyPullDot)
tinyPullToggle:EnableMouse(true)
tinyPullToggle:RegisterForClicks("LeftButtonUp", "RightButtonUp")
tinyPullToggle:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        DungeonClearDB.tinyMode = false
        UpdateLayout()
        return
    end
    local nextState = (pullSetting + 1) % 3
    SendDcCommand("pull", PullStates[nextState].cmd)
end)
tinyPullToggle:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(DCL("Pull Mode"))
    GameTooltip:AddLine(DCL("Click to cycle: Leeroy / Advanced / Dynamic"), 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end)
tinyPullToggle:SetScript("OnLeave", function() GameTooltip:Hide() end)
tinyPullDot:Hide()
tinyPullText:Hide()
tinyPullToggle:Hide()

-- Style the full-mode segments + tiny cycle button to the current pull state.
-- Active segment: locked highlight + accent text. Inactive: dim grey. The
-- controls stay clickable while DC is off: the pull mode is a preference the
-- server stores and applies on the next `dc on`, so it is configurable ahead of
-- the run. While off we still surface the chosen state, just dimmed to read as
-- "pending" rather than live.
UpdatePullControls = function()
    -- Live verdict shown only while Dynamic is the active state and DC is on.
    local verdict = (isDCOn and pullSetting == 2) and DynVerdicts[pullDecision] or nil

    -- Pull-mode readout in the status box: the active state, plus the live verdict
    -- when Dynamic. Dimmed while DC is off (the setting still applies on the next
    -- run, so show it rather than blanking it).
    if pullModeVal then
        local text = DCL(PullStates[pullSetting].seg)
        if pullSetting == 2 then
            text = DCL("Dynamic") .. (verdict and (" (" .. DCL(verdict.full) .. ")") or "")
        end
        pullModeVal:SetText(text)
        if not isDCOn then
            pullModeVal:SetTextColor(0.5, 0.5, 0.5)
        else
            pullModeVal:SetTextColor(unpack(verdict and verdict.color or PullStates[pullSetting].color))
        end
    end

    for i = 0, 2 do
        local seg = pullSegs[i]
        if seg then
            local fs = seg:GetFontString()
            -- Segments keep their base labels (Leeroy / Advanced / Dynamic); the
            -- active state and its live verdict are surfaced in the Pull Mode
            -- readout above instead.
            seg:SetText(DCL(PullStates[i].seg))
            -- Always clickable: the pull mode is settable before the run starts.
            seg:Enable()
            if i == pullSetting then
                seg:LockHighlight()
                -- Active Dyn segment tints to the verdict colour (amber Leeroy /
                -- blue Advanced) so the live choice reads at a glance. While DC
                -- is off the choice is a pending preference, so dim the accent.
                local accent = (i == 2 and verdict) and verdict.color or PullStates[i].color
                if fs then
                    if isDCOn then
                        fs:SetTextColor(unpack(accent))
                    else
                        fs:SetTextColor(accent[1] * 0.6, accent[2] * 0.6, accent[3] * 0.6)
                    end
                end
            else
                seg:UnlockHighlight()
                if fs then fs:SetTextColor(0.7, 0.7, 0.7) end
            end
        end
    end

    if tinyPullDot then
        -- Always clickable: the pull mode is settable before the run starts.
        if tinyPullToggle then tinyPullToggle:Enable() end
        -- The caption is the pull state; in Dynamic with DC on it appends the live
        -- verdict (Leeroy / Advanced) and carries the precise accent colour. The
        -- dot is a coarse 3-state indicator: dark = Off, green = On, blue =
        -- Dynamic. A grey "|" pipe caps the caption to divide it from the action
        -- line. While DC is off the state is a pending preference, so a dim factor
        -- darkens both the dot and caption to read as "set, not yet running".
        local label = DCL(PullStates[pullSetting].seg)
        local color = PullStates[pullSetting].color
        if verdict then
            label = label .. ": " .. DCL(verdict.full)
            color = verdict.color
        end
        local dim = isDCOn and 1.0 or 0.6
        if pullSetting == 1 then
            tinyPullDot:SetTexture("Interface\\FriendsFrame\\StatusIcon-Online") -- green
            tinyPullDot:SetTexCoord(0, 1, 0, 1)
            tinyPullDot:SetVertexColor(dim, dim, dim)
        elseif pullSetting == 2 then
            -- Solid blue circle for Dynamic: the portrait alpha mask is a filled
            -- white disc (tints cleanly to blue). It fills its frame edge to edge,
            -- so pad it with an over-range texcoord (clamps to transparent) to
            -- match the inset of the StatusIcon dots; otherwise it reads oversized.
            tinyPullDot:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
            tinyPullDot:SetTexCoord(-0.35, 1.35, -0.35, 1.35)
            tinyPullDot:SetVertexColor(0.30 * dim, 0.70 * dim, 1.00 * dim)
        else
            tinyPullDot:SetTexture("Interface\\FriendsFrame\\StatusIcon-Offline")
            tinyPullDot:SetTexCoord(0, 1, 0, 1)
            tinyPullDot:SetVertexColor(dim, dim, dim)
        end
        if not isDCOn then
            color = {color[1] * dim, color[2] * dim, color[3] * dim}
        end
        if tinyPullText then
            tinyPullText:SetText("|cff" .. RgbToHex(color) .. label .. "|r |cff808080|| |r")
        end
        if DungeonClearDB.tinyMode then UpdateTinyWidth() end
    end
end

-- Auto-play row (RebornWOW DCSB1A): hand your own character to the playerbot AI
-- in a chosen role, or take it back, without typing commands. The server wraps
-- playerbots' self-bot mode ("selfbot tank|heal|dps|off") and answers with
-- "SELFBOT <1|0> <role>"; the active segment is highlighted. Pair it with
-- Spectate to watch the whole run while the AI plays your character.
local selfBotUI = { role = nil, btns = {} }  -- role nil = you are playing
selfBotUI.label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
selfBotUI.label:SetPoint("TOPLEFT", onBtn, "BOTTOMLEFT", 2, -78)
DCBind(selfBotUI.label, "Auto-play:")
selfBotUI.label:SetTextColor(0.8, 0.8, 0.8)

local SELFBOT_SEGS = {
    { key = "tank", label = "Tank",   tip = "Let the AI play your character as the tank." },
    { key = "heal", label = "Heal",   tip = "Let the AI play your character as a healer." },
    { key = "dps",  label = "DPS",    tip = "Let the AI play your character as damage." },
    { key = "off",  label = "Manual", tip = "Take your character back and play it yourself." },
}
for i, seg in ipairs(SELFBOT_SEGS) do
    local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    b:SetSize(54, 24)
    if i == 1 then
        b:SetPoint("LEFT", selfBotUI.label, "RIGHT", 8, 0)
    else
        b:SetPoint("LEFT", selfBotUI.btns[i - 1], "RIGHT", 2, 0)
    end
    DCBind(b, seg.label)
    b:SetScript("OnClick", function() SendDcCommand("selfbot", seg.key) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(DCL(seg.label))
        GameTooltip:AddLine(DCL(seg.tip), 1, 1, 1, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    selfBotUI.btns[i] = b
end
-- RebornWOW DCGM1E: the "My party (GM)" menu (kill / raise / cheat tier for your own
-- bots, DCGM1D) right on the main panel, at the end of the auto-play row. Kept in
-- selfBotUI.btns so it hides and shows with the row (update() only walks the segs).
do
    local gm = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    gm:SetSize(32, 24)
    gm:SetPoint("LEFT", selfBotUI.btns[#selfBotUI.btns], "RIGHT", 2, 0)
    gm:SetText("GM")
    gm:SetScript("OnClick", function() if DCMyPartyMenu then DCMyPartyMenu() end end)
    gm:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(DCL("My party (GM)"))
        GameTooltip:AddLine(DCL("Kill or raise the bots of the party YOU lead (not a test run), or yourself, to test what happens when nobody can resurrect. Also /dc gm. Other real players are never touched."), 1, 1, 1, true)
        GameTooltip:AddLine(DCL("Cheat tier for my bots"), 1, 0.82, 0)
        GameTooltip:Show()
    end)
    gm:SetScript("OnLeave", function() GameTooltip:Hide() end)
    selfBotUI.btns[#selfBotUI.btns + 1] = gm
end

selfBotUI.update = function()
    for i, seg in ipairs(SELFBOT_SEGS) do
        local b = selfBotUI.btns[i]
        local active = (seg.key == "off" and selfBotUI.role == nil) or seg.key == selfBotUI.role
        if active then b:LockHighlight() else b:UnlockHighlight() end
    end
end
selfBotUI.update()

selfBotUI.show = function(shown)
    selfBotUI.label[shown and "Show" or "Hide"](selfBotUI.label)
    for _, b in ipairs(selfBotUI.btns) do b[shown and "Show" or "Hide"](b) end
end

-- Boss List Label
local listLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
-- Below the pull + spectate + auto-play rows: onBtn bottom, minus three
-- (8px gap + 24px row) bands + 12px.
listLabel:SetPoint("TOPLEFT", onBtn, "BOTTOMLEFT", 0, -108)
DCBind(listLabel, "Dungeon Bosses")
listLabel:SetTextColor(0.24, 0.60, 1.0)

-- Boss List Scroll Frame container
local scrollContainer = CreateFrame("Frame", nil, frame)
scrollContainer:SetSize(306, 205)
scrollContainer:SetPoint("TOPLEFT", listLabel, "BOTTOMLEFT", 0, -4)
scrollContainer:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 12, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
})
scrollContainer:SetBackdropColor(0.05, 0.05, 0.08, 0.50)
scrollContainer:SetBackdropBorderColor(0.15, 0.17, 0.22, 0.8)

-- Uniform row height sized for the worst case: a two-line wrapped name plus a
-- folded-event note beneath it. FauxScrollFrame requires a single fixed row
-- height (all its offset/range math multiplies by it), so short rows are padded
-- to this height rather than shrinking. The note is anchored under the name (not
-- a fixed band) so the name can wrap freely and the note floats down with it.
local ROW_HEIGHT = 48
local VISIBLE_ROWS = 4
local BOSS_ROWS_MAX = 12  -- RebornWOW DCUI3B5: the five-column panel shows as many as fit

-- Row width, chosen per redraw by FitRows. The scroll frame reserves 28px on its
-- right for the scrollbar whether or not one is showing, and the rows were a
-- flat 262 to stay clear of it -- so with four or fewer bosses (the common case)
-- that strip sat empty for good and every row was needlessly narrow. 290 fills
-- it, leaving the same 8px margin on the right that the list has on the left.
local ROW_W = 290
local ROW_W_SCROLLBAR = 262

-- Scrollable boss list. FauxScrollFrame is the idiomatic WotLK pattern: a small
-- fixed pool of visible rows is reused while an offset selects which slice of
-- `bosses` they display, so the list scrolls without growing the window.
local scrollFrame = CreateFrame("ScrollFrame", "DungeonClearScrollFrame", scrollContainer, "FauxScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", scrollContainer, "TOPLEFT", 8, -8)
scrollFrame:SetPoint("BOTTOMRIGHT", scrollContainer, "BOTTOMRIGHT", -28, 8) -- leave room for the scrollbar
scrollFrame:EnableMouseWheel(true)
scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, RedrawBossList)
end)
scrollFrame:SetScript("OnMouseWheel", function(self, delta)
    local bar = DungeonClearScrollFrameScrollBar
    bar:SetValue(bar:GetValue() - delta * ROW_HEIGHT)
end)

-- Pre-create the visible row pool inside scrollContainer, anchored to scrollFrame
for i = 1, BOSS_ROWS_MAX do
    local row = CreateFrame("Frame", nil, scrollContainer)
    row:SetSize(ROW_W, ROW_HEIGHT - 2)
    row:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)

    -- Custom solid color texture instead of SetBackdrop to prevent client crashes
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(row)
    bg:SetTexture(0.08, 0.10, 0.15, 0.4)
    row.bg = bg

    -- Text label
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.text:SetPoint("LEFT", row, "LEFT", 8, 0)
    row.text:SetWidth(150)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)

    -- Folded-event sub-line: a gating event (e.g. an Uldaman altar) shown under
    -- the boss it gates, instead of as its own row with a Go that can't resolve.
    -- Hidden unless the BOSS message carried an event note (field 10).
    row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.sub:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 16, 3)
    -- Near-full row width: on event rows the Go button is lifted onto the name
    -- line (see RedrawBossList) so the note owns the whole bottom band.
    row.sub:SetWidth(234)
    row.sub:SetJustifyH("LEFT")
    -- Single line only: a long note must truncate, never wrap down onto the
    -- next boss's row (that was the overlap bug).
    row.sub:SetWordWrap(false)
    row.sub:Hide()

    -- Status badge
    row.status = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.status:SetPoint("LEFT", row.text, "RIGHT", 5, 0)

    -- "Go" action button
    row.goBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.goBtn:SetSize(46, 20)
    row.goBtn:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    DCBind(row.goBtn, "Go")

    -- Hovering a row with a folded event shows the full note in a tooltip, so a
    -- name too long for the bottom band (which truncates) is still readable.
    -- RedrawBossList stashes the boss name + raw note on the row each draw.
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        if not self.eventNoteFull or self.eventNoteFull == "" then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self.bossName then
            GameTooltip:AddLine(DCLName(self.bossName), 1, 1, 1)
        end
        -- Multiple folded events arrive joined by " | "; one tooltip line each.
        for note in string.gmatch(self.eventNoteFull, "[^|]+") do
            GameTooltip:AddLine(DCLNote(strtrim(note)), 0.78, 0.63, 0.18, true)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- EnableMouse swallows the wheel, so forward it to keep the list scrollable
    -- while the cursor is over a row.
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(_, delta)
        local bar = DungeonClearScrollFrameScrollBar
        bar:SetValue(bar:GetValue() - delta * ROW_HEIGHT)
    end)

    bossRows[i] = row
end
for i = VISIBLE_ROWS + 1, BOSS_ROWS_MAX do bossRows[i]:Hide() end

-- Give the rows back the scrollbar's strip whenever no scrollbar is showing.
-- FauxScrollFrame shows one exactly when there are more bosses than visible
-- rows, which is the same test it makes itself in FauxScrollFrame_Update.
local function FitRows(numItems)
    local w = ROW_W
    if numItems > VISIBLE_ROWS then w = ROW_W_SCROLLBAR end
    for i = 1, VISIBLE_ROWS do
        bossRows[i]:SetWidth(w)
    end
end

-- Colour a folded-event sub-line by each event's completion state. The server
-- (DungeonClearChatActions) appends " (done)" / " (skipped)" to finished events
-- and leaves pending ones bare; several events gating one boss arrive joined by
-- " | ". Done events get a green ready-check tick + green text, skipped events
-- grey out, pending events keep the gold dash.
local function FormatEventNote(note)
    local out = {}
    for seg in string.gmatch(note, "[^|]+") do
        seg = strtrim(seg)
        if seg ~= "" then
            local piece
            if string.find(seg, "%(done%)$") then
                -- Ready-check tick doubles as the "completed" checkbox.
                piece = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t |cff3fd03f" .. DCLNote(seg) .. "|r"
            elseif string.find(seg, "%(skipped%)$") then
                piece = "|cff888888- " .. DCLNote(seg) .. "|r"
            else
                piece = "|cffc8a02e- " .. DCLNote(seg) .. "|r"
            end
            table.insert(out, piece)
        end
    end
    return table.concat(out, "  ")
end

-- Redraw Boss List rows (FauxScrollFrame implementation)
RedrawBossList = function()
    -- Never render a blank panel. Until a real list arrives, show a single
    -- placeholder row so the user sees the list is loading rather than empty.
    -- The OnUpdate ensure-loop keeps re-requesting until bosses populate.
    if #bosses == 0 then
        FauxScrollFrame_Update(scrollFrame, 0, VISIBLE_ROWS, ROW_HEIGHT)
        FitRows(0)
        for i = 1, VISIBLE_ROWS do bossRows[i]:Hide() end
        local row = bossRows[1]
        row.eventNoteFull = nil
        row.text:ClearAllPoints()
        row.text:SetPoint("LEFT", row, "LEFT", 8, 0)
        row.text:SetText(DCL("Loading boss list..."))
        row.text:SetTextColor(0.6, 0.6, 0.6)
        row.sub:Hide()
        row.status:SetText("")
        row.goBtn:Hide()
        row:Show()
        return
    end

    FauxScrollFrame_Update(scrollFrame, #bosses, VISIBLE_ROWS, ROW_HEIGHT)
    FitRows(#bosses)
    local offset = FauxScrollFrame_GetOffset(scrollFrame)

    for i = 1, VISIBLE_ROWS do
        local row = bossRows[i]
        -- 1-based ordinal position in the sorted list: clean sequential numbering
        -- even when a filtered wing yields non-contiguous encounter indices.
        local dataIndex = i + offset
        local boss = bosses[dataIndex]

        if boss then
            -- On split maps, tag the row with its region. Wing labels read like
            -- "Maraudon (Orange)"; show just the parenthetical ("Orange") to
            -- keep the row short, falling back to the full label otherwise.
            local label = dataIndex .. ". " .. DCLName(boss.name)
            if boss.wing then
                local region = boss.wing:match("%((.-)%)") or boss.wing
                label = label .. " |cff9999ff(" .. region .. ")|r"
            end
            row.text:SetText(label)
            -- Reset color: the loading placeholder dims row 1 to grey, so a real
            -- entry reusing that row must restore the normal white highlight.
            row.text:SetTextColor(1, 1, 1)

            -- Folded gating event: render it as a sub-line and lift the boss name
            -- to the top of the row so both fit; otherwise keep the name centered.
            -- Stash for the hover tooltip (full, untruncated note).
            row.eventNoteFull = boss.eventNote
            row.bossName = boss.name

            row.text:ClearAllPoints()
            row.goBtn:ClearAllPoints()
            row.sub:ClearAllPoints()
            if boss.eventNote then
                -- Name (+ Go) on top, the event note directly beneath it. The
                -- note is anchored to the name's BOTTOM (not a fixed row band) so
                -- the name is free to wrap to a second line — the note simply
                -- floats down with it instead of being collided into. Lifting Go
                -- onto the name line keeps it clear of the note.
                row.text:SetWordWrap(true)
                row.text:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -3)
                row.goBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -2)
                row.sub:SetPoint("TOPLEFT", row.text, "BOTTOMLEFT", 8, -2)
                -- Per-event colouring: pending = gold dash, done = green tick,
                -- skipped = grey (see FormatEventNote).
                row.sub:SetText(FormatEventNote(boss.eventNote))
                row.sub:Show()
            else
                -- No sub-line: let a long name (e.g. "Objective: Atal'ai Defender
                -- (Mijan)") wrap to a second line instead of truncating. The row
                -- is tall enough for two lines, and the name owns the full height.
                row.text:SetWordWrap(true)
                row.text:SetPoint("LEFT", row, "LEFT", 8, 0)
                row.goBtn:SetPoint("RIGHT", row, "RIGHT", -6, 0)
                row.sub:Hide()
            end

            -- Style status color
            local statusLabelText = "Alive"
            local statusColor = {0.1, 0.9, 0.1}
            local showGo = true

            if boss.status == "dead" then
                statusLabelText = "Dead"
                statusColor = {0.6, 0.6, 0.6}
                showGo = false
            elseif boss.status == "skipped" then
                statusLabelText = "Skipped"
                statusColor = {0.9, 0.7, 0.1}
                showGo = true
            elseif boss.status == "missing" then
                statusLabelText = "Missing"
                statusColor = {0.5, 0.5, 0.7}
                showGo = true
            end

            -- Standalone off-path "Event:" rows (gates with no boss to drive to —
            -- they fire automatically as the tank passes) get no Go button; it
            -- could never resolve to a creature. Boss-gating events are folded
            -- into their boss row (above) and keep the boss's own working Go.
            if boss.name and string.sub(boss.name, 1, 6) == "Event:" then
                showGo = false
            end

            row.status:SetText(DCL(statusLabelText))
            row.status:SetTextColor(unpack(statusColor))

            if showGo then
                row.goBtn:Show()
                row.goBtn:SetScript("OnClick", function()
                    if not isDCOn then
                        SendDcCommand("on")
                        if PushSettings then PushSettings() end
                    end
                    SendDcCommand("go", boss.entry)
                end)
            else
                row.goBtn:Hide()
            end

            row:Show()
        else
            row:Hide()
        end
    end
end

-- (Chat spam filter checkbox removed — addon messages are inherently silent)

-- Toggle Buttons and Layout Adjustments
local tinyBtn = CreateFrame("Button", "DungeonClearTinyButton", frame, "UIPanelButtonTemplate")
tinyBtn:SetSize(40, 20)
tinyBtn:SetPoint("RIGHT", closeBtn, "LEFT", 2, 0)
tinyBtn:SetText(DCL("Tiny"))

-- RebornWOW: 中文 / EN switch, the same red button as the Witch Doctor talent panel.
local langBtn = CreateFrame("Button", "DungeonClearLangButton", frame, "UIPanelButtonTemplate")
langBtn:SetSize(44, 20)
langBtn:SetPoint("RIGHT", tinyBtn, "LEFT", -2, 0)
langBtn:SetScript("OnClick", function() DCLoc.Toggle() end)
langBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(DCL("Switch the panel language"))
    GameTooltip:Show()
end)
langBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
DCLoc.AddButton(langBtn)

-- Test window (RebornWOW DCTEST1A): the `.dc test` GM commands behind buttons.
-- Start a bot test run (a random playerbot comp, or a hand-picked party of your own
-- offline characters), then watch, inspect and stop runs. The commands are typed for
-- you as chat commands (GM accounts only) and the server's replies are shown in the
-- window as well as in chat. Only the header button is shared with the main chunk.
local testBtn = CreateFrame("Button", "DungeonClearTestButton", frame, "UIPanelButtonTemplate")
testBtn:SetSize(44, 20)
testBtn:SetPoint("RIGHT", langBtn, "LEFT", -2, 0)
DCBind(testBtn, "Test")
-- RebornWOW DCGPS1B: header button for the coordinate copy window (GM: the window's
-- Capture button sends .gps for you). A do-block keeps its local out of the main
-- chunk's 200-local budget.
do
    -- DCGM1D: own name; "DungeonClearGpsButton" is the minimap icon (DCICON1A), which
    -- RebornDock / MinimapButtonFrame remember by that name.
    local gpsBtn = CreateFrame("Button", "DungeonClearHeaderGpsButton", frame, "UIPanelButtonTemplate")
    gpsBtn:SetSize(40, 20)
    gpsBtn:SetPoint("RIGHT", testBtn, "LEFT", -2, 0)
    DCBind(gpsBtn, "GPS")
    gpsBtn:SetScript("OnClick", function() if DCGpsToggle then DCGpsToggle() end end)
    gpsBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(DCL("Coordinates"))
        GameTooltip:AddLine(DCL("Open the coordinate copy window (GM: capture with one click)."), 1, 1, 1, true)
        GameTooltip:Show()
    end)
    gpsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end
-- A function rather than a do-block: its locals then count against its own 200-local
-- limit instead of the main chunk's, which this file is close to.
;(function()
    local QUALITIES = {
        { key = "",         label = "Default" },
        { key = "uncommon", label = "Uncommon" },
        { key = "rare",     label = "Rare" },
        { key = "epic",     label = "Epic" },
    }
    local ROSTER_ROLES = { "Tank", "Healer", "DPS 1", "DPS 2", "DPS 3" }

    local function DB()
        DungeonClearDB.test = DungeonClearDB.test or {}
        local t = DungeonClearDB.test
        t.roster = t.roster or {}
        t.dungeons = t.dungeons or {}
        if t.mode == nil then t.mode = "random" end
        if t.quality == nil then t.quality = 1 end
        if t.autoWatch == nil then t.autoWatch = true end
        return t
    end

    local tf = CreateFrame("Frame", "DungeonClearTestFrame", UIParent)
    tf:SetSize(372, 590)
    tf:SetPoint("CENTER", UIParent, "CENTER", 260, 0)
    tf:SetMovable(true)
    tf:EnableMouse(true)
    tf:RegisterForDrag("LeftButton")
    tf:SetClampedToScreen(true)
    tf:SetFrameStrata("DIALOG")
    tf:SetToplevel(true)
    tf:SetScript("OnDragStart", tf.StartMoving)
    tf:SetScript("OnDragStop", tf.StopMovingOrSizing)
    tf:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    tf:SetBackdropColor(0.03, 0.03, 0.05, 0.92)
    tf:SetBackdropBorderColor(0.20, 0.22, 0.28, 1.0)
    tf:Hide()
    tinsert(UISpecialFrames, "DungeonClearTestFrame")  -- Esc closes it

    local title = tf:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", tf, "TOPLEFT", 14, -12)
    DCBind(title, "Bot Test Runs (GM)")
    title:SetTextColor(0.24, 0.60, 1.0)
    local tclose = CreateFrame("Button", nil, tf, "UIPanelCloseButton")
    tclose:SetPoint("TOPRIGHT", tf, "TOPRIGHT", -4, -4)

    local function Label(text, anchor, rel, x, y, color)
        local fs = tf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint(anchor, rel, x and "BOTTOMLEFT" or anchor, x or 0, y or 0)
        DCBind(fs, text)
        if color then fs:SetTextColor(unpack(color)) else fs:SetTextColor(0.8, 0.8, 0.8) end
        return fs
    end

    local function Tip(widget, head, body)
        widget:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(DCL(head))
            if body then GameTooltip:AddLine(DCL(body), 1, 1, 1, true) end
            GameTooltip:Show()
        end)
        widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local function Button(text, w, onClick, tipBody)
        local b = CreateFrame("Button", nil, tf, "UIPanelButtonTemplate")
        b:SetSize(w, 22)
        DCBind(b, text)
        b:SetScript("OnClick", onClick)
        if tipBody then Tip(b, text, tipBody) end
        return b
    end

    local editBoxCount = 0  -- DCTEST9A
    local function EditBox(w, numeric)
        editBoxCount = editBoxCount + 1
        local e = CreateFrame("EditBox", "DungeonClearTestEdit" .. editBoxCount, tf, "InputBoxTemplate")
        e:SetSize(w, 20)
        local back = e:CreateTexture(nil, "BACKGROUND")  -- DCTEST9A: readable over the painting
        back:SetPoint("TOPLEFT", e, "TOPLEFT", -4, -1); back:SetPoint("BOTTOMRIGHT", e, "BOTTOMRIGHT", 0, 1)
        back:SetTexture(0.02, 0.03, 0.05, 0.92)
        e:SetAutoFocus(false)
        if numeric then e:SetNumeric(true) end
        e:SetScript("OnEscapePressed", e.ClearFocus)
        e:SetScript("OnEnterPressed", e.ClearFocus)
        return e
    end

    ---------------------------------------------------------------- output box
    local out = CreateFrame("ScrollingMessageFrame", nil, tf)
    out:SetPoint("BOTTOMLEFT", tf, "BOTTOMLEFT", 12, 12)
    out:SetPoint("BOTTOMRIGHT", tf, "BOTTOMRIGHT", -12, 12)
    out:SetHeight(150)
    do  -- DCTEST9A: a dark backing for the server log (docked there is no window backdrop)
        local back = tf:CreateTexture(nil, "BACKGROUND")
        back:SetPoint("TOPLEFT", out, "TOPLEFT", -4, 4); back:SetPoint("BOTTOMRIGHT", out, "BOTTOMRIGHT", 4, -4)
        back:SetTexture(0.02, 0.03, 0.05, 0.75)
    end
    out:SetFontObject(GameFontHighlightSmall)
    out:SetJustifyH("LEFT")
    out:SetFading(false)
    out:SetMaxLines(300)
    out:EnableMouseWheel(true)
    out:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then self:ScrollUp() else self:ScrollDown() end
    end)
    local outBg = CreateFrame("Frame", nil, tf)
    outBg:SetPoint("TOPLEFT", out, "TOPLEFT", -4, 4)
    outBg:SetPoint("BOTTOMRIGHT", out, "BOTTOMRIGHT", 4, -4)
    outBg:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 12, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    outBg:SetBackdropColor(0.10, 0.12, 0.16, 0.60)
    outBg:SetBackdropBorderColor(0.15, 0.17, 0.22, 0.8)
    outBg:SetFrameLevel(out:GetFrameLevel())
    out:SetFrameLevel(outBg:GetFrameLevel() + 1)

    ---------------------------------------------------- sending + capturing
    -- Replies to a command arrive as system messages. Everything the server says
    -- for a few seconds after a command is copied into the output box; a quiet
    -- (auto-refresh) poll is also kept out of the chat window.
    local capture = { untilT = 0, quiet = false, list = false }
    local listBuf = nil

    local function Send(cmd, quiet, isList)
        capture.untilT = GetTime() + 4
        capture.quiet = quiet and true or false
        capture.list = isList and true or false
        if isList then listBuf = {} end
        if not quiet then out:AddMessage("|cff3da6ff> " .. cmd .. "|r") end
        -- DCTEST4C: remember whether a test is being watched, so ending the camera
        -- (here or with the main panel's Reset Camera) also takes you back.
        if cmd:find("^%.dc test watch") then
            DCTestWatchActive = not cmd:find(" off$")
            SetCameraState(DCTestWatchActive and "follow" or false)
        end
        SendChatMessage(cmd, "SAY")
    end

    local function Capturing() return GetTime() < capture.untilT end
    local watchAt = nil  -- pending auto-watch after a start

    local RefreshDungeonList  -- forward

    local capFrame = CreateFrame("Frame")
    capFrame:RegisterEvent("CHAT_MSG_SYSTEM")
    capFrame:SetScript("OnEvent", function(_, _, msg)
        if not Capturing() or not msg then return end
        capture.untilT = math.max(capture.untilT, GetTime() + 1.5)
        out:AddMessage(DCLTestLine(msg))
        -- DCTEST3A: the concurrent-run cap deserves more than a chat line.
        local cap = msg:match("max concurrent test runs reached %((%d+)%)")
        if cap then StaticPopup_Show("DUNGEONCLEAR_TEST_CAP", string.format(DCL(
            "The test-run limit is %s at a time. Stop a running test first, or raise the limit with + at the top of the test run list (until restart), or in mod_dungeon_clear.conf (DungeonClear.TestRun.MaxConcurrent, then .reload config)."), cap)) end
        if capture.list and listBuf then
            -- "  hos              Halls of Stone (map 599, level 78, heroic 80)"
            local token, name, lvl, rest = msg:match("^%s+(%S+)%s+(.-) %(map %d+, level (%d+)(.-)%)%s*$")
            if token then
                local heroic = rest and rest:match("heroic (%d+)")
                listBuf[#listBuf + 1] = { token = token, name = name, level = tonumber(lvl),
                                          heroic = heroic and tonumber(heroic) or nil }
                DB().dungeons = listBuf
                if RefreshDungeonList then RefreshDungeonList() end
            end
        end
    end)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function()
        return Capturing() and capture.quiet
    end)

    ----------------------------------------------------------- dungeon picker
    local y = -40
    local dLabel = tf:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dLabel:SetPoint("TOPLEFT", tf, "TOPLEFT", 14, y)
    DCBind(dLabel, "Dungeon:")
    local dungeonBox = EditBox(110)
    dungeonBox:SetPoint("LEFT", dLabel, "RIGHT", 10, 0)
    Tip(dungeonBox, "Dungeon:", "A dungeon token (e.g. hos) or a map id. Typing also filters the list below.")
    local refreshBtn = Button("Load list", 80, function() Send(".dc test list", true, true) end,
        "Ask the server for the dungeons the test harness supports.")
    refreshBtn:SetPoint("LEFT", dungeonBox, "RIGHT", 8, 0)

    local ROWS, ROW_H = 6, 16
    local listBox = CreateFrame("Frame", nil, tf)
    listBox:SetPoint("TOPLEFT", tf, "TOPLEFT", 12, y - 24)
    listBox:SetSize(348, ROWS * ROW_H + 8)
    listBox:SetBackdrop(outBg:GetBackdrop())
    listBox:SetBackdropColor(0.10, 0.12, 0.16, 0.60)
    listBox:SetBackdropBorderColor(0.15, 0.17, 0.22, 0.8)
    listBox:EnableMouseWheel(true)
    local listOffset = 0
    local revealSelection = false  -- scroll the chosen dungeon into view on the next redraw
    -- DCTEST5A/5B: a click on a row writes the token into the box; that must not run the
    -- typing path (reset to the top + re-centre), or the list jumps under the mouse.
    -- OnTextChanged from SetText arrives on a later frame in 3.3.5, so a flag set around
    -- SetText is already gone by then. Remember the picked text instead, and pin the
    -- picked dungeon to the row the mouse clicked on.
    local pickedText = nil
    local pin = nil  -- { token, pos }: keep this token at visible row `pos` on the next redraw
    local listRows = {}
    local filtered = {}

    for i = 1, ROWS do
        local r = CreateFrame("Button", nil, listBox)
        r:SetSize(318, ROW_H)
        r.index = i
        r:SetPoint("TOPLEFT", listBox, "TOPLEFT", 6, -4 - (i - 1) * ROW_H)
        r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.text:SetAllPoints()
        r.text:SetJustifyH("LEFT")
        r:SetScript("OnClick", function(self)
            if self.row then
                pickedText = self.row.token
                pin = { token = self.row.token, pos = self.index }
                dungeonBox:SetText(self.row.token)
                dungeonBox:ClearFocus()
                DB().token = self.row.token
                RefreshDungeonList()
            end
        end)
        listRows[i] = r
    end

    -- DCTEST4D: a scroll bar beside the dungeon list (arrows + draggable thumb), kept in
    -- step with the mouse wheel.
    local scrollUp = CreateFrame("Button", nil, listBox, "UIPanelScrollUpButtonTemplate")
    scrollUp:SetSize(16, 16)
    scrollUp:SetPoint("TOPRIGHT", listBox, "TOPRIGHT", -4, -4)
    local scrollDown = CreateFrame("Button", nil, listBox, "UIPanelScrollDownButtonTemplate")
    scrollDown:SetSize(16, 16)
    scrollDown:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -4, 4)
    local scrollBar = CreateFrame("Slider", nil, listBox)
    scrollBar:SetOrientation("VERTICAL")
    scrollBar:SetWidth(16)
    scrollBar:SetPoint("TOP", scrollUp, "BOTTOM", 0, 0)
    scrollBar:SetPoint("BOTTOM", scrollDown, "TOP", 0, 0)
    scrollBar:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    local track = scrollBar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetTexture(0, 0, 0, 0.35)
    scrollBar:SetValueStep(1)
    scrollBar:SetMinMaxValues(0, 0)
    scrollBar:SetValue(0)
    local syncingBar = false
    scrollBar:SetScript("OnValueChanged", function(_, value)
        if syncingBar then return end
        local v = math.floor(value + 0.5)
        if v ~= listOffset then
            listOffset = v
            RefreshDungeonList()
        end
    end)
    scrollUp:SetScript("OnClick", function()
        listOffset = math.max(0, listOffset - 1)
        RefreshDungeonList()
    end)
    scrollDown:SetScript("OnClick", function()
        listOffset = listOffset + 1
        RefreshDungeonList()
    end)

    RefreshDungeonList = function()
        local t = DB()
        local q = (dungeonBox:GetText() or ""):lower()
        wipe(filtered)
        for _, row in ipairs(t.dungeons) do
            if q == "" or row.token:lower():find(q, 1, true) or row.name:lower():find(q, 1, true)
               or DCLDungeon(row.name):find(q, 1, true)
               or row.token == t.token then
                filtered[#filtered + 1] = row
            end
        end
        -- An exact token match shows the whole list (a chosen dungeon, not a search).
        for _, row in ipairs(t.dungeons) do
            if row.token == q then wipe(filtered); for _, r2 in ipairs(t.dungeons) do filtered[#filtered + 1] = r2 end break end
        end
        -- A chosen dungeon (an exact token) shows the whole list; keep it in sight, centred,
        -- instead of jumping back to the top. Only right after a choice, so the mouse wheel
        -- still scrolls freely.
        if pin then
            for i, row in ipairs(filtered) do
                if row.token == pin.token then listOffset = i - pin.pos break end
            end
            pin = nil
            revealSelection = false
        elseif revealSelection then
            revealSelection = false
            for i, row in ipairs(filtered) do
                if row.token == q and (i <= listOffset or i > listOffset + ROWS) then
                    listOffset = i - math.floor(ROWS / 2) - 1
                end
            end
        end
        listOffset = math.max(0, math.min(listOffset, #filtered - ROWS))
        local maxOffset = math.max(0, #filtered - ROWS)
        syncingBar = true
        scrollBar:SetMinMaxValues(0, maxOffset)
        scrollBar:SetValue(listOffset)
        syncingBar = false
        if maxOffset > 0 then
            scrollBar:Show(); scrollUp:Show(); scrollDown:Show()
            if listOffset > 0 then scrollUp:Enable() else scrollUp:Disable() end
            if listOffset < maxOffset then scrollDown:Enable() else scrollDown:Disable() end
        else
            scrollBar:Hide(); scrollUp:Hide(); scrollDown:Hide()
        end
        for i = 1, ROWS do
            local r = listRows[i]
            local row = filtered[i + listOffset]
            r.row = row
            if row then
                local lv = DCL("Lv") .. " " .. row.level
                if row.heroic then lv = lv .. " / " .. DCL("H") .. " " .. row.heroic end
                local mark = (row.token == q) and "|cff00ff00> |r" or "  "
                r.text:SetText(mark .. "|cffffd100" .. row.token .. "|r  " .. DCLDungeon(row.name) .. "  |cff999999(" .. lv .. ")|r")
                r:Show()
            else
                r:Hide()
            end
        end
        if #t.dungeons == 0 then
            listRows[1].text:SetText("|cff999999" .. DCL("Click Load list to fetch the dungeons.") .. "|r")
            listRows[1].row = nil
            listRows[1]:Show()
        end
    end
    listBox:SetScript("OnMouseWheel", function(_, delta)
        listOffset = listOffset - delta
        RefreshDungeonList()
    end)
    dungeonBox:SetScript("OnTextChanged", function(self)
        DB().token = self:GetText()
        if pickedText and self:GetText() == pickedText then
            pickedText = nil   -- our own click: the list was already pinned under the mouse
            return
        end
        pickedText = nil
        listOffset = 0
        revealSelection = true
        RefreshDungeonList()
    end)

    -------------------------------------------------------------- run options
    y = y - 24 - (ROWS * ROW_H + 8) - 10
    local heroicCheck = CreateFrame("CheckButton", nil, tf, "UICheckButtonTemplate")
    heroicCheck:SetSize(24, 24)
    heroicCheck:SetPoint("TOPLEFT", tf, "TOPLEFT", 10, y)
    local heroicText = heroicCheck:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    heroicText:SetPoint("LEFT", heroicCheck, "RIGHT", 0, 1)
    DCBind(heroicText, "Heroic")
    heroicCheck:SetScript("OnClick", function(self) DB().heroic = self:GetChecked() and true or false end)

    local modeLabel = tf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    modeLabel:SetPoint("LEFT", heroicText, "RIGHT", 18, 0)
    DCBind(modeLabel, "Party:")
    local modeBtns = {}
    local ApplyMode  -- forward
    local MODES = {
        { key = "random", label = "Random bots",
          tip = "The server rolls a random playerbot party from the bot pool and gears it to the ilvl / quality below. Same seed = same party." },
        { key = "roster", label = "My characters",
          tip = "A party of your own characters, roles in order. They must be OFFLINE (log your bot alts out first): the server logs them in as bots and does not re-gear or re-level them. The character you are playing cannot join a test run - play it with the normal Start button and Auto-play instead." },
    }
    for i, m in ipairs(MODES) do
        local b = Button(m.label, 64, function() DB().mode = m.key; ApplyMode() end, m.tip)  -- 96 -> 64: DCGM1C2/DCUI3D2
        if i == 1 then b:SetPoint("LEFT", modeLabel, "RIGHT", 6, 0)
        else b:SetPoint("LEFT", modeBtns[i - 1], "RIGHT", 2, 0) end
        b.key = m.key
        modeBtns[i] = b
    end

    -- RebornWOW DCGM1B: cheat tier for the whole test party (GM). Cycles on click.
    local TIERS = {
        { key = "",       label = "Normal" },
        { key = "story",  label = "Story" },
        { key = "casual", label = "Casual" },
        { key = "speed",  label = "Speed" },
    }
    local tierBtn
    local function TierIndex()
        local cur = DB().cheat or ""
        for i, t in ipairs(TIERS) do if t.key == cur then return i end end
        return 1
    end
    tierBtn = Button("Normal", 46, function()  -- 56 -> 46: DCUI3D2
        local i = TierIndex() % #TIERS + 1
        DB().cheat = TIERS[i].key
        DCBind(tierBtn, TIERS[i].label)
    end, "Cheat tier for the whole party (click to cycle). Normal: no cheats, real difficulty. Story: invincible + unlimited mana, normal damage, events play out. Casual: the same, bots deal half damage. Speed: also no cooldowns, instant casts, 10x damage - route checks only, a boss may die before its script finishes. A run with a tier is marked and kept out of rankings.")
    tierBtn:SetPoint("LEFT", modeBtns[#modeBtns], "RIGHT", 4, 0)
    DCBind(tierBtn, TIERS[TierIndex()].label)
    -- RebornWOW DCGM1C: mode 2 -- you join the random bot party (one bot fewer), optionally
    -- invincible. Kept on tierBtn (the main chunk's 200-local limit).
    local JOIN = { { key = nil, label = "Me: out" }, { key = "me", label = "Me: in" }, { key = "god", label = "Me: in + god" } }
    tierBtn.JoinIndex = function()
        for i, j in ipairs(JOIN) do if j.key == DB().joinMe then return i end end
        return 1
    end
    tierBtn.join = Button("Me: out", 60, function()  -- 92 -> 60: DCGM1C2/DCUI3D2, the row fits the window
        local i = tierBtn.JoinIndex() % #JOIN + 1
        DB().joinMe = JOIN[i].key
        DCBind(tierBtn.join, JOIN[i].label)
    end, "Random bots only: join the test party yourself (one bot fewer). 'in + god' also makes you invincible; the bots keep the party's cheat tier. When the run ends you leave the party and go back to where you started.")
    tierBtn.join:SetPoint("LEFT", tierBtn, "RIGHT", 4, 0)
    DCBind(tierBtn.join, JOIN[tierBtn.JoinIndex()].label)
    -- RebornWOW DCGM1C3: for the refresh on show, and the three options spelled out
    tierBtn.joinLabels = { JOIN[1].label, JOIN[2].label, JOIN[3].label }
    tierBtn.TierLabel = function() return TIERS[TierIndex()].label end
    tierBtn.join:HookScript("OnEnter", function()
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(DCL("Me: out -- god view: you are not in the party, the run is watched at once."), 1, 0.82, 0, true)
        GameTooltip:AddLine(DCL("Me: in -- ride along: you are in the party; play, or put yourself on auto-play."), 1, 0.82, 0, true)
        GameTooltip:AddLine(DCL("Me: in + god -- the same, invincible: any level can come."), 1, 0.82, 0, true)
        GameTooltip:Show()
    end)

    -- random-comp options
    y = y - 30
    local randomGroup = {}
    local ilvlLabel = tf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ilvlLabel:SetPoint("TOPLEFT", tf, "TOPLEFT", 16, y - 4)
    DCBind(ilvlLabel, "Item level:")
    local ilvlBox = EditBox(40, true)
    ilvlBox:SetPoint("LEFT", ilvlLabel, "RIGHT", 8, 0)
    Tip(ilvlBox, "Item level:", "Gear ceiling for the bots (empty = the server default). Use 'Gear tiers' to see sensible values for the dungeon.")
    local qLabel = tf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    qLabel:SetPoint("LEFT", ilvlBox, "RIGHT", 10, 0)
    DCBind(qLabel, "Quality:")
    local qBtn
    qBtn = Button("Default", 70, function()
        local t = DB()
        t.quality = t.quality % #QUALITIES + 1
        DCBind(qBtn, QUALITIES[t.quality].label)
    end, "Click to cycle the best item quality the bots may wear.")
    qBtn:SetPoint("LEFT", qLabel, "RIGHT", 6, 0)
    local seedLabel = tf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    seedLabel:SetPoint("LEFT", qBtn, "RIGHT", 8, 0)
    DCBind(seedLabel, "Seed:")
    local seedBox = EditBox(56, true)
    seedBox:SetPoint("LEFT", seedLabel, "RIGHT", 8, 0)
    Tip(seedBox, "Seed:", "Empty = a new random party. Re-use the seed printed by an earlier run to test the very same party again.")
    randomGroup = { ilvlLabel, ilvlBox, qLabel, qBtn, seedLabel, seedBox }

    -- roster options: five name boxes, roles positional
    local rosterGroup = {}
    local rosterBoxes = {}
    -- RebornWOW DCTEST8A: "..." beside each slot opens the character picker (offline
    -- characters only: your account, the bot pool near the dungeon's level, favourites,
    -- search). A field of rosterBoxes, not a new local (the main chunk's 200-local limit).
    rosterBoxes.Pick = function(i, role)
        if not DCOpenPicker then return end
        local t = DB()
        local level
        for _, row in ipairs(t.dungeons or {}) do
            if row.token == t.token then level = (t.heroic and row.heroic) or row.level end
        end
        DCOpenPicker({
            title = string.format(DCL("Test party: %s"), DCL(role)),
            hint = DCL("A test party needs OFFLINE characters of one faction; the server logs them in as bots."),
            cats = { "account", "pool", "favorites", "search" },
            level = level,
            filter = function(d)
                if d.npc then return false, DCL("NPCBots cannot join a test run.") end
                if d.online then return false, DCL("This character is online; a test character must be offline (log it out first).") end
                return true
            end,
            onPick = function(d) rosterBoxes[i]:SetText(d.name) end,
        })
    end
    for i, role in ipairs(ROSTER_ROLES) do
        local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
        local l = tf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        l:SetPoint("TOPLEFT", tf, "TOPLEFT", 16 + col * 116, y - 4 - row * 24)
        DCBind(l, role)
        -- DCTEST8A: named (an anonymous InputBoxTemplate loses its middle / right art),
        -- a little narrower to make room for the picker button
        local e = CreateFrame("EditBox", "DungeonClearTestRosterBox" .. i, tf, "InputBoxTemplate")
        e:SetSize(48, 20); e:SetAutoFocus(false)
        e:SetScript("OnEscapePressed", e.ClearFocus); e:SetScript("OnEnterPressed", e.ClearFocus)
        e:SetPoint("LEFT", l, "RIGHT", 6, 0)
        e:SetScript("OnTextChanged", function(self) DB().roster[i] = self:GetText() end)
        rosterBoxes[i] = e
        local pick = Button("...", 20, function() rosterBoxes.Pick(i, role) end,
            "Pick a character from a list: your account's offline characters, the bot pool, favourites or search.")
        pick:SetPoint("LEFT", e, "RIGHT", 2, 0)
        rosterGroup[#rosterGroup + 1] = l
        rosterGroup[#rosterGroup + 1] = e
        rosterGroup[#rosterGroup + 1] = pick
    end
    local fillBtn = Button("From party", 80, function()
        -- Party members other than you, in party order; they must log out before the run.
        local n = GetNumPartyMembers and GetNumPartyMembers() or 0
        local names = {}
        for i = 1, n do
            local name = UnitName("party" .. i)
            if name then names[#names + 1] = name end
        end
        for i = 1, 5 do
            rosterBoxes[i]:SetText(names[i] or "")
        end
    end, "Copy your current party members' names into the five slots (fix the role order by hand). Log those bots out before you start.")
    fillBtn:SetPoint("TOPLEFT", tf, "TOPLEFT", 16 + 2 * 116, y - 26)
    rosterGroup[#rosterGroup + 1] = fillBtn

    ApplyMode = function()
        local t = DB()
        for _, b in ipairs(modeBtns) do
            if b.key == t.mode then b:LockHighlight() else b:UnlockHighlight() end
        end
        for _, w in ipairs(randomGroup) do w[t.mode == "random" and "Show" or "Hide"](w) end
        for _, w in ipairs(rosterGroup) do w[t.mode == "roster" and "Show" or "Hide"](w) end
    end

    ------------------------------------------------------------ start + gear
    y = y - 54
    local function Token()
        local token = (dungeonBox:GetText() or ""):gsub("%s", "")
        if token == "" then
            out:AddMessage("|cffff3333" .. DCL("Pick a dungeon first.") .. "|r")
            return nil
        end
        return token
    end

    local startBtn = Button("Start test", 100, function()
        local token = Token()
        if not token then return end
        local t = DB()
        local cmd = ".dc test start " .. token
        if t.mode == "roster" then
            local names = {}
            for i = 1, 5 do
                local nm = (rosterBoxes[i]:GetText() or ""):gsub("%s", "")
                if nm == "" then
                    out:AddMessage("|cffff3333" .. DCL("Fill all five characters (tank, healer, three DPS).") .. "|r")
                    return
                end
                names[i] = nm
            end
            cmd = cmd .. " party=" .. table.concat(names, ",")
        else
            local ilvl = ilvlBox:GetText()
            if ilvl and ilvl ~= "" then cmd = cmd .. " ilvl=" .. ilvl end
            local q = QUALITIES[t.quality].key
            if q ~= "" then cmd = cmd .. " quality=" .. q end
            local seed = seedBox:GetText()
            if seed and seed ~= "" then cmd = cmd .. " seed=" .. seed end
        end
        if heroicCheck:GetChecked() then cmd = cmd .. " heroic" end
        if t.cheat and t.cheat ~= "" then cmd = cmd .. " cheat=" .. t.cheat end  -- DCGM1B
        if t.joinMe and t.mode ~= "roster" then cmd = cmd .. (t.joinMe == "god" and " withmegod" or " withme") end  -- DCGM1C
        t.ilvl, t.seed = ilvlBox:GetText(), seedBox:GetText()
        Send(cmd)
        -- DCGM1C3: "Me: out" is god view -- always watch the run (in the party: never)
        if not (t.joinMe and t.mode ~= "roster") then watchAt = GetTime() + 10 end
    end, "Start a bot test run with the options above. The bots run the dungeon on their own; use Watch to follow them.")
    startBtn:SetPoint("TOPLEFT", tf, "TOPLEFT", 14, y)
    local gearBtn = Button("Gear tiers", 90, function()
        local token = Token()
        if not token then return end
        Send(".dc test gear " .. token .. (heroicCheck:GetChecked() and " heroic" or ""))
    end, "List the item-level ceilings worth testing this dungeon at.")
    gearBtn:SetPoint("LEFT", startBtn, "RIGHT", 4, 0)

    -- Watch automatically once the bots have had time to log in and enter.
    local watchCheck = CreateFrame("CheckButton", nil, tf, "UICheckButtonTemplate")
    watchCheck:SetSize(24, 24)
    watchCheck:SetPoint("LEFT", gearBtn, "RIGHT", 6, 0)
    local watchText = watchCheck:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    watchText:SetPoint("LEFT", watchCheck, "RIGHT", 0, 1)
    DCBind(watchText, "Watch after start")
    watchCheck:SetScript("OnClick", function(self) DB().autoWatch = self:GetChecked() and true or false end)
    Tip(watchCheck, "Watch after start", "10 seconds after Start, run Watch: you are hidden, moved to the instance entrance and your camera follows the bots.")

    ------------------------------------------------------------- running runs
    y = y - 32
    local runLabel = tf:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    runLabel:SetPoint("TOPLEFT", tf, "TOPLEFT", 14, y)
    DCBind(runLabel, "Running tests")
    runLabel:SetTextColor(0.24, 0.60, 1.0)

    y = y - 18
    local RUN_BTNS = {
        { "Status",     ".dc test status",     "Show every running test run (dungeon, party, stage, time)." },
        { "Watch",      ".dc test watch",      "Hide yourself and put your camera on the running test (only one running) - you are teleported to the instance entrance." },
        { "Next run",   ".dc test watch next", "Move the camera to the next running test." },
        { "Stop watching", ".dc test watch off", "End the camera and return to where you were." },
    }
    local prev
    for i, def in ipairs(RUN_BTNS) do
        local b = Button(def[1], i == 4 and 96 or 80, function() Send(def[2]) end, def[3])
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else b:SetPoint("TOPLEFT", tf, "TOPLEFT", 14, y) end
        prev = b
    end

    y = y - 26
    local stopBtn = Button("Stop run", 80, function() Send(".dc test stop") end,
        "Stop the running test (only one running; otherwise the reply lists the run ids).")
    stopBtn:SetPoint("TOPLEFT", tf, "TOPLEFT", 14, y)
    local stopAllBtn = Button("Stop all", 80, function()
        -- RebornWOW DCTEST10D: the finished sentence as the dialog text, no "%s" to fill
        local d = StaticPopupDialogs["DUNGEONCLEAR_TEST_STOPALL"]
        if d then d.text = DCL("Stop ALL bot test runs and test plans?") or "Stop ALL bot test runs and test plans?" end
        StaticPopup_Show("DUNGEONCLEAR_TEST_STOPALL")
    end, "Stop every test run and every test plan.")
    stopAllBtn:SetPoint("LEFT", stopBtn, "RIGHT", 4, 0)
    local planBtn = Button("Plan status", 80, function() Send(".dc test plan status") end,
        "Show the batch test plans (.dc test plan start ...) and their progress.")
    planBtn:SetPoint("LEFT", stopAllBtn, "RIGHT", 4, 0)
    local clearBtn = Button("Clear", 56, function() out:Clear() end)
    clearBtn:SetPoint("LEFT", planBtn, "RIGHT", 4, 0)

    StaticPopupDialogs["DUNGEONCLEAR_TEST_CAP"] = {
        text = "%s",
        button1 = OKAY, button2 = CANCEL,
        OnShow = function(self)
            self.button1:SetText(DCL("Open test run list"))
            self.button2:SetText(OKAY)
        end,
        OnAccept = function() if DungeonClearTestListFrame then DungeonClearTestListFrame:Show() end end,
        timeout = 0, whileDead = true, hideOnEscape = true,
    }
    StaticPopupDialogs["DUNGEONCLEAR_TEST_STOPONE"] = {
        text = "%s",
        button1 = YES, button2 = NO,
        OnAccept = function(self, data) if data then data() end end,
        timeout = 0, whileDead = true, hideOnEscape = true,
    }
    StaticPopupDialogs["DUNGEONCLEAR_TEST_STOPALL"] = {
        text = "Stop ALL bot test runs and test plans?",  -- DCTEST10D: set again (translated) on click
        button1 = YES, button2 = NO,
        OnAccept = function() Send(".dc test stop all") end,
        timeout = 0, whileDead = true, hideOnEscape = true,
    }

    y = y - 26
    local autoCheck = CreateFrame("CheckButton", nil, tf, "UICheckButtonTemplate")
    autoCheck:SetSize(24, 24)
    autoCheck:SetPoint("TOPLEFT", tf, "TOPLEFT", 10, y)
    local autoText = autoCheck:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    autoText:SetPoint("LEFT", autoCheck, "RIGHT", 0, 1)
    DCBind(autoText, "Refresh status every 15s while this window is open")
    autoCheck:SetScript("OnClick", function(self) DB().auto = self:GetChecked() and true or false end)

    local autoElapsed = 0
    -- The pending auto-watch lives on its own frame so it fires with this window closed.
    local watchTimer = CreateFrame("Frame")
    watchTimer:SetScript("OnUpdate", function()
        if watchAt and GetTime() >= watchAt then
            watchAt = nil
            Send(".dc test watch")
        end
    end)

    tf:SetScript("OnUpdate", function(_, elapsed)
        if not DB().auto then return end
        autoElapsed = autoElapsed + elapsed
        if autoElapsed >= 15 and not Capturing() then
            autoElapsed = 0
            out:AddMessage("|cff999999-- " .. date("%H:%M:%S") .. " --|r")
            Send(".dc test status", true)
        end
    end)

    local note = tf:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("BOTTOMLEFT", outBg, "TOPLEFT", 2, 4)
    note:SetPoint("RIGHT", tf, "RIGHT", -14, 0)
    note:SetJustifyH("LEFT")
    DCBind(note, "GM only. Replies from the server:")

    tf:SetScript("OnShow", function()
        local t = DB()
        -- RebornWOW DCGM1C3: the Me / tier buttons from the saved choice (they were set
        -- before the saved variables loaded)
        if tierBtn.JoinIndex then DCBind(tierBtn.join, tierBtn.joinLabels[tierBtn.JoinIndex()]) end
        if tierBtn.TierLabel then DCBind(tierBtn, tierBtn.TierLabel()) end
        dungeonBox:SetText(t.token or "")
        heroicCheck:SetChecked(t.heroic and true or false)
        ilvlBox:SetText(t.ilvl or "")
        seedBox:SetText(t.seed or "")
        DCBind(qBtn, QUALITIES[t.quality].label)
        for i = 1, 5 do rosterBoxes[i]:SetText(t.roster[i] or "") end
        autoCheck:SetChecked(t.auto and true or false)
        watchCheck:SetChecked(t.autoWatch and true or false)
        autoElapsed = 0
        ApplyMode()
        RefreshDungeonList()
        if #t.dungeons == 0 then Send(".dc test list", true, true) end
    end)

    ------------------------------------------------ test-run list (DCTEST2A)
    -- A panel beside the test window: every live run (the one you are watching
    -- first) with a Watch button each, the selected run's party (class, role,
    -- level, item level, health, mana) and one bot's equipped gear. Fed by the
    -- server's "testruns" / "testgear" addon replies, refreshed every 5 seconds
    -- while it is open.
    local CLASS_TOKENS = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT",
                           "SHAMAN", "MAGE", "WARLOCK", nil, "DRUID" }
    local STAGES = {
        spawning_bots = "Logging in bots", provisioning = "Gearing up", grouping = "Grouping",
        teleporting = "Teleporting", starting = "Starting", monitoring = "Clearing",
        tearing_down = "Wrapping up",
    }
    local ROLE_TAGS = { tank = "Tank", healer = "Heal", heal = "Heal", dps = "DPS" }

    local lf = CreateFrame("Frame", "DungeonClearTestListFrame", UIParent)
    lf:SetSize(392, 690)  -- DCTEST9A: taller party rows
    lf:SetFrameStrata("DIALOG")
    lf:EnableMouse(true)
    -- Its own window: opens left of the test window (the main panel usually sits on
    -- the right), drags on its own and remembers where it was put. Right-click puts
    -- it back next to the test window.
    lf:SetMovable(true)
    lf:SetClampedToScreen(true)
    lf:SetToplevel(true)
    lf:RegisterForDrag("LeftButton")
    local function PlaceList()
        lf:ClearAllPoints()
        local pos = DB().listPos
        if pos then
            lf:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
        else
            lf:SetPoint("TOPRIGHT", tf, "TOPLEFT", -4, 0)
        end
    end
    lf:SetScript("OnDragStart", lf.StartMoving)
    lf:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint(1)
        DB().listPos = { point, relPoint, x, y }
    end)
    -- Right-click on the title area puts the panel back next to the test window
    -- (right-clicks on a run or a bot open their own menus).
    lf:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            DB().listPos = nil
            PlaceList()
        end
    end)
    lf:SetBackdrop(tf:GetBackdrop())
    lf:SetBackdropColor(0.03, 0.03, 0.05, 0.92)
    lf:SetBackdropBorderColor(0.20, 0.22, 0.28, 1.0)
    lf:Hide()
    tinsert(UISpecialFrames, "DungeonClearTestListFrame")

    local function LText(parent, font, text, x, y)
        local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
        if x then fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y) end
        if text then DCBind(fs, text) end
        fs:SetJustifyH("LEFT")
        return fs
    end
    local function LButton(parent, text, w, onClick)
        local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetSize(w, 20)
        DCBind(b, text)
        b:SetScript("OnClick", onClick)
        return b
    end
    local function Panel(parent, x, y, w, h)
        local p = CreateFrame("Frame", nil, parent)
        p:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
        p:SetSize(w, h)
        p:SetBackdrop(outBg:GetBackdrop())
        p:SetBackdropColor(0.10, 0.12, 0.16, 0.60)
        p:SetBackdropBorderColor(0.15, 0.17, 0.22, 0.8)
        return p
    end

    local lTitle = LText(lf, "GameFontNormalLarge", "Test run list", 14, -12)
    lTitle:SetTextColor(0.24, 0.60, 1.0)
    local lClose = CreateFrame("Button", nil, lf, "UIPanelCloseButton")
    lClose:SetPoint("TOPRIGHT", lf, "TOPRIGHT", -4, -4)
    local lCount = LText(lf, nil, nil, 14, -38)
    local lHint = LText(lf, "GameFontDisableSmall", "Drag to move; right-click a run or a bot for more", 0, 0)
    lHint:ClearAllPoints()
    lHint:SetPoint("LEFT", lTitle, "RIGHT", 10, -1)
    -- RebornWOW DCTEST10A: whose runs the list shows
    local scopeBtns = {}
    local function PaintScope()
        local all = DB().listScope == "all"
        if all then scopeBtns.all:LockHighlight(); scopeBtns.mine:UnlockHighlight()
        else scopeBtns.mine:LockHighlight(); scopeBtns.all:UnlockHighlight() end
    end
    for i, def in ipairs({ { "mine", "Mine", "Only the test runs this character started." },
                           { "all", "All", "Every GM's test runs, and records from before runs were tagged with their GM." } }) do
        local b = LButton(lf, def[2], 46, function()
            DB().listScope = (def[1] == "all") and "all" or nil
            PaintScope()
            if RenderRuns then RenderRuns() end
        end)
        if i == 1 then b:SetPoint("LEFT", lTitle, "RIGHT", 10, 0) else b:SetPoint("LEFT", scopeBtns.mine, "RIGHT", 2, 0) end
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText(DCL(def[2]))
            GameTooltip:AddLine(DCL(def[3]), 1, 1, 1, true); GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        scopeBtns[def[1]] = b
    end
    lHint:ClearAllPoints()
    lHint:SetPoint("LEFT", scopeBtns.all, "RIGHT", 8, 0)
    PaintScope()
    local lRefresh = LButton(lf, "Refresh", 64, function() SendDcCommand("testruns", "", true) end)
    lRefresh:SetPoint("TOPRIGHT", lf, "TOPRIGHT", -14, -34)


    local runs, selectedRun, runOffset = {}, nil, 0
    local gear = nil   -- { name, class, level, ilvl, items = { {slot, id, ilvl, q} } }
    local pending, gearPending = nil, nil
    local info, infoPending = nil, nil   -- DCTEST3A run stats: { id, kills, deaths }
    local bottomMode = "gear"            -- what the bottom box shows: "gear" | "stats"
    -- DCTEST6A: finished runs stay in the list (saved per account, newest first) until
    -- the GM deletes them; the server also re-sends its last 20 with the outcome.
    local finPending, shownCount = nil, 0
    local LoadStats  -- DCTEST7A: forward; assigned after the run menus
    local function History()
        local t = DB()
        t.history = t.history or {}
        t.historyDeleted = t.historyDeleted or {}
        return t.history, t.historyDeleted
    end
    local function HistFind(id)
        for _, h in ipairs((History())) do if h.id == id then return h end end
    end
    -- test verdict tokens (DcTestRun::VerdictName) for finished runs.
    local RESULT_NAMES = {
        disabled = "Run disabled", wipe = "Party wiped", paused_timeout = "Paused too long",
        stalled_timeout = "Stuck too long", no_progress = "No progress", overall_timeout = "Took too long",
        aborted = "Stopped", setup_failed = "Setup failed", lab_done = "Lab done",
    }
    local pendingFollow = nil            -- { name, at }: follow a bot once the watch has landed

    -- DCTEST4A: the concurrent-run cap, settable here (GM; in memory until restart).
    local cap = { value = nil, conf = 0, over = false }  -- DCTEST4A concurrent-run cap
    local function SetCap(v)
        SendDcCommand("testcap", tostring(v), true)
    end
    local capReset = LButton(lf, "Conf", 44, function() SendDcCommand("testcap", "reset", true) end)
    capReset:SetPoint("RIGHT", lRefresh, "LEFT", -6, 0)
    local capPlus = LButton(lf, "+", 22, function()
        if cap.value and cap.value > 0 and cap.value < 100 then SetCap(cap.value + 1) end
    end)
    capPlus:SetPoint("RIGHT", capReset, "LEFT", -4, 0)
    local capMinus = LButton(lf, "-", 22, function()
        if not cap.value then return end
        if cap.value == 0 then SetCap(math.max(#runs, 1)) elseif cap.value > 1 then SetCap(cap.value - 1) end
    end)
    capMinus:SetPoint("RIGHT", capPlus, "LEFT", -2, 0)
    for _, b in ipairs({ capMinus, capPlus, capReset }) do
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(DCL("Test-run limit"))
            GameTooltip:AddLine(DCL("- / + change how many tests may run at once. Conf goes back to DungeonClear.TestRun.MaxConcurrent. A value set here lasts until the server restarts; edit the conf to keep it."), 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    -- runs ---------------------------------------------------------------
    local RUN_ROWS, RUN_H = 5, 40
    -- RebornWOW DCTEST9A: rows for the docked list (up to RUN_MAX); runVis are shown.
    -- RUN_ROWS (5) still sets the floating window's layout below the list.
    local RUN_MAX, runVis = 16, 5
    local runBox = Panel(lf, 10, -58, 372, RUN_ROWS * RUN_H + 8)
    local VIEW_H = 28  -- DCTEST4C: the camera row under the runs
    runBox:EnableMouseWheel(true)
    local runRows = {}
    local RenderRuns, RenderMembers, RenderGear  -- forward

    for i = 1, RUN_MAX do
        local r = CreateFrame("Button", nil, runBox)
        r:SetSize(362, RUN_H - 2)
        r:SetPoint("TOPLEFT", runBox, "TOPLEFT", 5, -4 - (i - 1) * RUN_H)
        r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        r.l1 = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.l1:SetPoint("TOPLEFT", r, "TOPLEFT", 2, -3)
        r.l1:SetPoint("RIGHT", r, "RIGHT", -64, 0)
        r.l1:SetJustifyH("LEFT")
        r.l2 = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        r.l2:SetPoint("TOPLEFT", r.l1, "BOTTOMLEFT", 0, -3)
        r.l2:SetPoint("RIGHT", r, "RIGHT", -64, 0)
        r.l2:SetJustifyH("LEFT")
        r.watch = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
        r.watch:SetSize(58, 20)
        r.watch:SetPoint("RIGHT", r, "RIGHT", -2, 0)
        r.watch:SetScript("OnClick", function(self)
            local run = self:GetParent().run
            if not run then return end
            selectedRun = run.id
            Send(".dc test watch " .. run.id)
            -- The camera lands after the teleport; ask again so the marker follows.
            capture.relistAt = GetTime() + 4
            RenderRuns()
        end)
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        r:SetScript("OnClick", function(self, button)
            if self.run then
                selectedRun = self.run.id
                gear = nil
                RenderRuns()
                if button == "RightButton" and DCTestShowRunMenu then DCTestShowRunMenu(self.run)
                elseif LoadStats then LoadStats(self.run) end
            end
        end)
        runRows[i] = r
    end
    runBox:SetScript("OnMouseWheel", function(_, delta)
        runOffset = math.max(0, math.min(runOffset - delta, shownCount - runVis))  -- DCTEST9A
        RenderRuns()
    end)

    local function DungeonName(token)
        for _, row in ipairs(DB().dungeons) do
            if row.token == token then return DCLDungeon(row.name) end
        end
        return token
    end
    local function Clock(s)
        s = tonumber(s) or 0
        return string.format("%d:%02d", math.floor(s / 60), s % 60)
    end

    -- members --------------------------------------------------------------
    local memLabel = LText(lf, "GameFontNormal", nil, 14, -58 - RUN_ROWS * RUN_H - 16 - VIEW_H)
    memLabel:SetTextColor(0.24, 0.60, 1.0)
    local MEM_ROWS, MEM_H = 5, 30  -- DCTEST9A: room for the bars
    local memBox = Panel(lf, 10, -58 - RUN_ROWS * RUN_H - 32 - VIEW_H, 372, MEM_ROWS * MEM_H + 8)
    local memRows = {}
    -- RebornWOW DCTEST9A: rows for a 10/20-player party when docked; memVis are shown,
    -- the wheel scrolls past them
    local MEM_MAX, memVis, memOffset = 20, MEM_ROWS, 0
    for i = 1, MEM_MAX do
        local r = CreateFrame("Frame", nil, memBox)
        r:SetSize(362, MEM_H)
        r:SetPoint("TOPLEFT", memBox, "TOPLEFT", 5, -4 - (i - 1) * MEM_H)
        -- RebornWOW DCTEST9A: like the main panel's party -- role chip, icon, name, and a
        -- health and a power bar along the bottom
        r.chip = r:CreateTexture(nil, "ARTWORK"); r.chip:SetSize(22, 16); r.chip:SetPoint("TOPLEFT", r, "TOPLEFT", 1, -2)
        r.chipText = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.chipText:SetPoint("CENTER", r.chip, "CENTER", 0, 0)
        r.cls = r:CreateTexture(nil, "ARTWORK")
        r.cls:SetSize(16, 16)
        r.cls:SetPoint("LEFT", r.chip, "RIGHT", 4, 0)
        r.cls:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
        local function Bar(y, h)
            local bg = r:CreateTexture(nil, "BORDER"); bg:SetTexture(0, 0, 0, 0.6)
            bg:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 27, y); bg:SetSize(362 - 27 - 58, h)
            local fg = r:CreateTexture(nil, "ARTWORK"); fg:SetHeight(h)
            fg:SetPoint("BOTTOMLEFT", bg, "BOTTOMLEFT", 0, 0)
            return bg, fg
        end
        r.hpBg, r.hp = Bar(5, 3)
        r.pwBg, r.pw = Bar(1, 2)
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.text:SetPoint("LEFT", r.cls, "RIGHT", 4, 0)
        r.text:SetPoint("RIGHT", r, "RIGHT", -56, 0)
        r.text:SetJustifyH("LEFT")
        r.gearBtn = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
        r.gearBtn:SetSize(52, 18)
        r.gearBtn:SetPoint("RIGHT", r, "RIGHT", -2, 0)
        DCBind(r.gearBtn, "Details")
        r.gearBtn:SetScript("OnClick", function(self)
            local m = self:GetParent().member
            if m and DCTestInspect then DCTestInspect(m.name) end
        end)
        r:EnableMouse(true)
        r:SetScript("OnMouseUp", function(self, button)
            if button == "RightButton" and self.member and DCTestShowMemberMenu then DCTestShowMemberMenu(self.member) end
        end)
        memRows[i] = r
    end

    -- gear -----------------------------------------------------------------
    local gearTop = -58 - RUN_ROWS * RUN_H - 32 - VIEW_H - (MEM_ROWS * MEM_H + 8) - 8
    local gearLabel = LText(lf, "GameFontNormal", nil, 14, gearTop)
    gearLabel:SetTextColor(0.24, 0.60, 1.0)
    local GEAR_ROWS, GEAR_H = 10, 17
    local gearBox = Panel(lf, 10, gearTop - 16, 372, GEAR_ROWS * GEAR_H + 8)
    local gearCells = {}
    for i = 1, GEAR_ROWS * 2 do
        local col, row = math.floor((i - 1) / GEAR_ROWS), (i - 1) % GEAR_ROWS
        local c = CreateFrame("Button", nil, gearBox)
        c:SetSize(180, GEAR_H)
        c:SetPoint("TOPLEFT", gearBox, "TOPLEFT", 5 + col * 182, -4 - row * GEAR_H)
        c.icon = c:CreateTexture(nil, "ARTWORK")
        c.icon:SetSize(GEAR_H - 2, GEAR_H - 2)
        c.icon:SetPoint("LEFT", c, "LEFT", 0, 0)
        c.text = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        c.text:SetPoint("LEFT", c.icon, "RIGHT", 3, 0)
        c.text:SetPoint("RIGHT", c, "RIGHT", 0, 0)
        c.text:SetJustifyH("LEFT")
        c:SetScript("OnEnter", function(self)
            if not self.itemId then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:" .. self.itemId)
            GameTooltip:Show()
        end)
        c:SetScript("OnLeave", function() GameTooltip:Hide() end)
        gearCells[i] = c
    end
    gearBox:Hide()

    -- Run stats share the bottom box with the gear list (DCTEST3A).
    local statsBox = CreateFrame("ScrollingMessageFrame", nil, lf)
    statsBox:SetPoint("TOPLEFT", gearBox, "TOPLEFT", 6, -4)
    statsBox:SetPoint("BOTTOMRIGHT", gearBox, "BOTTOMRIGHT", -6, 4)
    statsBox:SetFontObject(GameFontHighlightSmall)
    statsBox:SetJustifyH("LEFT")
    statsBox:SetFading(false)
    statsBox:SetMaxLines(200)
    statsBox:SetInsertMode("TOP")
    statsBox:EnableMouseWheel(true)
    statsBox:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then self:ScrollUp() else self:ScrollDown() end
    end)
    statsBox:Hide()

    local QUALITY_NAMES = { [1] = "Common", [2] = "Uncommon", [3] = "Rare", [4] = "Epic", [5] = "Legendary" }
    local function FindRun(id)
        for _, r in ipairs(runs) do if r.id == id then return r end end
    end

    -- RebornWOW DCGM1B2: cheat tiers in the run list. A finished run's tier is the chain
    -- it used ("story", or "normal>casual" when switched mid-run); "-"/"" = normal.
    local CHEAT_TIERS = {
        { key = "normal", label = "Normal" }, { key = "story", label = "Story" },
        { key = "casual", label = "Casual" }, { key = "speed", label = "Speed" },
    }
    local TIER_COLOR = { normal = "|cffcccccc", story = "|cff3da6ff", casual = "|cff00ff00", speed = "|cffff6600" }
    -- DCGM1B3: every run with tier data gets a label (grey [Normal] too) so runs of
    -- the same party at different tiers read apart at a glance; no data = no label.
    local function TierTag(tier)
        if not tier or tier == "" then return "" end
        if tier == "-" then tier = "normal" end
        local names = {}
        for part in tier:gmatch("[^>]+") do
            local label = part
            for _, t in ipairs(CHEAT_TIERS) do if t.key == part then label = DCL(t.label) end end
            names[#names + 1] = label
        end
        local last = tier:match("([^>]+)$")
        return (TIER_COLOR[last] or "|cffffd100") .. "[" .. table.concat(names, ">") .. "]|r "
    end

    -- RebornWOW DCBOSS1A: 12400 -> 12.4k
    local function Kfmt(n)
        n = tonumber(n) or 0
        if n >= 1000000 then return string.format("%.1fm", n / 1000000) end
        if n >= 1000 then return string.format("%.1fk", n / 1000) end
        return tostring(n)
    end
    local function SpellText(id, fallback)
        if id and id > 0 then
            local n = GetSpellInfo(id)
            if n then return n end
        end
        return fallback or ""
    end

    local function RenderStats()
        local run = info and (FindRun(info.id) or HistFind(info.id))
        gearBox:Show()
        for _, c in ipairs(gearCells) do c:Hide() end
        statsBox:Show()
        statsBox:Clear()
        if not info then return end
        local name = run and DungeonName(run.token) or info.id
        gearLabel:SetText(DCL("Run stats") .. ": " .. name)
        -- Inserted at the TOP, so add the lines bottom-up.
        local lines = {}
        if run then
            local q = QUALITY_NAMES[run.gearQuality]
            lines[#lines + 1] = string.format("%s %d/%d   %s %d   %s %d   %s %s",
                DCL("Bosses"), run.killed, run.total, DCL("Deaths"), run.deaths or 0,
                DCL("Pulls"), run.pulls or 0, DCL("Time"), Clock(run.elapsed))
            lines[#lines + 1] = string.format("%s %s   %s %s %s",
                DCL("Seed:"), run.roster and DCL("(my characters)") or tostring(run.seed),
                DCL("Gear"), (run.gearIlvl or 0) > 0 and ("<=" .. run.gearIlvl) or DCL("unlimited"),
                q and DCL(q) or "")
            -- DCGM1B3: the tier on its own line; anything but plain Normal is not a clean result.
            local tag = TierTag(run.tier)
            if tag ~= "" then
                local clean = run.tier == "-" or run.tier == "normal"
                lines[#lines + 1] = DCL("Cheat tier:") .. " " .. tag ..
                    (clean and "" or ("|cff999999" .. DCL("(not a clean result)") .. "|r"))
            end
        end
        -- DCTEST7A: the boss/objective checklist, in clear order.
        if info.list and #info.list > 0 then
            local done = 0
            for _, b in ipairs(info.list) do if b.status == "dead" then done = done + 1 end end
            lines[#lines + 1] = "|cff3da6ff-- " .. DCL("Boss progress") .. " " .. done .. "/" .. #info.list .. " --|r"
            local STATUS = {
                dead = "|cff00ff00" .. DCL("Killed") .. "|r", current = "|cffffd100" .. DCL("Current target") .. "|r",
                skipped = "|cff999999" .. DCL("Skipped") .. "|r", alive = "|cffffffff" .. DCL("Not yet") .. "|r",
            }
            for i, b in ipairs(info.list) do
                local name = b.objective and (DCL("Objective") .. ": " .. b.name) or b.name
                local color = b.status == "dead" and "|cff999999" or (b.status == "current" and "|cffffd100" or "|cffffffff")
                lines[#lines + 1] = string.format("  %d. %s%s|r  %s", i, color, name, STATUS[b.status] or b.status)
            end
        end
        lines[#lines + 1] = "|cff3da6ff-- " .. DCL("Bosses down") .. " --|r"
        if #info.kills == 0 then lines[#lines + 1] = "  |cff999999" .. DCL("none yet") .. "|r" end
        for _, k in ipairs(info.kills) do
            lines[#lines + 1] = "  " .. Clock(k.t) .. "  |cff00ff00" .. k.name .. "|r"
        end
        lines[#lines + 1] = "|cff3da6ff-- " .. DCL("Deaths") .. " --|r"
        if #info.deaths == 0 then lines[#lines + 1] = "  |cff999999" .. DCL("none yet") .. "|r" end
        for _, dd in ipairs(info.deaths) do
            local by = dd.by ~= "" and (" <- " .. dd.by .. (dd.onBoss and (" |cffff8000(" .. DCL("boss") .. ")|r") or "")) or (" |cff999999(" .. DCL("out of combat") .. ")|r")
            lines[#lines + 1] = "  " .. Clock(dd.t) .. "  |cffff3333" .. dd.name .. "|r" .. by
            -- DCBOSS1A: what actually killed them
            if dd.killer and dd.killer ~= "" then
                local sp = SpellText(dd.spellId, dd.spell)
                local txt = dd.killer .. (sp ~= "" and (" - " .. sp) or "") .. "  " .. Kfmt(dd.amount)
                if (dd.overkill or 0) > 0 then txt = txt .. " (" .. DCL("overkill") .. " " .. Kfmt(dd.overkill) .. ")" end
                if (dd.bossHp or -1) >= 0 then txt = txt .. "  " .. string.format(DCL("killer at %d%% health"), dd.bossHp) end
                lines[#lines + 1] = "      |cffbbbbbb" .. DCL("Killed by") .. ": " .. txt .. "|r"
                lines[#lines + 1] = "      |cff999999" .. string.format(DCL("Last 5 s: %s damage taken, %s healing received"),
                    Kfmt(dd.dmg5), Kfmt(dd.heal5)) .. "|r"
                if dd.topSrc and dd.topSrc ~= "" and dd.topAmount > 0 then
                    lines[#lines + 1] = "      |cff999999" .. DCL("Most damage") .. ": " .. dd.topSrc ..
                        ((dd.topSpell ~= "") and (" - " .. dd.topSpell) or "") .. "  " .. Kfmt(dd.topAmount) .. "|r"
                end
            end
            if dd.healers and dd.healers ~= "" then  -- DCBOSS1B: where the healers were
                lines[#lines + 1] = "      |cff999999" .. DCL("Healers") .. ": " .. dd.healers .. "|r"
            end
        end
        if info.dmg and #info.dmg > 0 then
            lines[#lines + 1] = "|cff3da6ff-- " .. DCL("Damage taken by source") .. " --|r"
            for _, t in ipairs(info.dmg) do
                local sp = SpellText(t.spellId, t.spell)
                lines[#lines + 1] = "  " .. Kfmt(t.total) .. "  " .. t.src .. ((sp ~= "") and (" - " .. sp) or "") ..
                    "  |cff999999x" .. t.hits .. "|r"
            end
        end
        if info.heals and #info.heals > 0 then
            lines[#lines + 1] = "|cff3da6ff-- " .. DCL("Healing done") .. " --|r"
            for _, t in ipairs(info.heals) do
                lines[#lines + 1] = "  " .. Kfmt(t.total) .. "  " .. t.name
            end
        end
        if info.hstats and #info.hstats > 0 then  -- DCBOSS1B
            lines[#lines + 1] = "|cff3da6ff-- " .. DCL("Healer activity") .. " --|r"
            for _, h in ipairs(info.hstats) do
                lines[#lines + 1] = "  " .. string.format(DCL("%s: %d s in combat, moving %d s, casting %d s; ally below half health %d s (moving %d s, idle %d s); lowest mana %d%%"),
                    h.name, h.combat, h.moving, h.casting, h.low, h.lowMoving, h.lowIdle, h.minMana)
                if h.casts and h.casts ~= "" then  -- DCBOSS1C
                    lines[#lines + 1] = "      |cff999999" .. DCL("Cast check while idle") .. ": " .. h.casts .. "|r"
                end
            end
        end
        for i = #lines, 1, -1 do statsBox:AddMessage(lines[i]) end
    end

    local runMenuFrame = CreateFrame("Frame", "DungeonClearTestRunMenu", UIParent, "UIDropDownMenuTemplate")

    -- The same test again: same dungeon, difficulty, seed (= same party) and gear.
    local function ReplayCommand(run)
        -- DCTEST6A: a "my characters" run replays the same characters (party=, in comp order).
        if run.roster then
            local names = {}
            for _, c in ipairs(run.comp or {}) do names[#names + 1] = c.name end
            if #names == 0 then for _, m in ipairs(run.members or {}) do names[#names + 1] = m.name end end
            if #names > 0 then
                return ".dc test start " .. run.token .. " party=" .. table.concat(names, ",") .. (run.heroic and " heroic" or "")
            end
        end
        local cmd = ".dc test start " .. run.token
        if run.seed and run.seed > 0 then cmd = cmd .. " seed=" .. run.seed end
        if run.gearIlvl and run.gearIlvl > 0 then cmd = cmd .. " ilvl=" .. run.gearIlvl end
        local qkey = ({ [2] = "uncommon", [3] = "rare", [4] = "epic", [5] = "legendary" })[run.gearQuality or 0]
        if qkey then cmd = cmd .. " quality=" .. qkey end
        if run.heroic then cmd = cmd .. " heroic" end
        return cmd
    end

    local function FollowBot(run, name)
        if run.watching then
            Send(".dc spectate follow " .. name)
        else
            Send(".dc test watch " .. run.id)
            pendingFollow = { name = name, at = GetTime() + 6 }
            capture.relistAt = GetTime() + 4
        end
    end

    -- DCTEST6A: copy a run's settings into the start panel on the left.
    local function CopySettings(run)
        local t = DB()
        t.token, t.heroic, t.mode = run.token, run.heroic, "random"
        t.ilvl = (run.gearIlvl or 0) > 0 and tostring(run.gearIlvl) or ""
        t.seed = (run.seed or 0) > 0 and tostring(run.seed) or ""
        t.quality = ({ [2] = 2, [3] = 3, [4] = 4 })[run.gearQuality or 0] or 1
        tf:Hide(); tf:Show()
    end

    -- RebornWOW DCGM1B2: replay a run at a chosen cheat tier, or at all four side by side
    -- (same seed = same classes and roles; bots busy in another test are swapped for
    -- free ones of the same class). The four starts go out 3 s apart.
    local tierQueue, tierQueueAt = {}, 0
    local tierQueueFrame = CreateFrame("Frame")
    tierQueueFrame:Hide()
    tierQueueFrame:SetScript("OnUpdate", function(self)
        if GetTime() < tierQueueAt then return end
        local cmd = table.remove(tierQueue, 1)
        if not cmd then self:Hide(); return end
        Send(cmd)
        capture.relistAt = GetTime() + 4
        tierQueueAt = GetTime() + 3
    end)
    local function TierReplayCommand(run, key)
        local cmd = ReplayCommand(run)
        if key ~= "normal" then cmd = cmd .. " cheat=" .. key end
        return cmd
    end
    -- RebornWOW DCTEST10C: "Me" is about you, not about the run -- a replay follows the
    -- button as it is now: in / in + god join, out watches (god view)
    local function JoinSuffix(run)
        local me = DB().joinMe
        if run.roster or not me then return "" end
        return me == "god" and " withmegod" or " withme"
    end
    local function ReplayAtTier(run, key)
        local suffix = JoinSuffix(run)
        Send(TierReplayCommand(run, key) .. suffix)
        if suffix == "" then watchAt = GetTime() + 10 end  -- Me: out = god view
        capture.relistAt = GetTime() + 4
    end
    local function ReplayAllTiers(run)
        if run.roster then
            out:AddMessage("|cffff3333" .. DCL("Your own characters cannot run four tests at once - pick one tier.") .. "|r")
            return
        end
        local free = (cap.value and cap.value > 0) and (cap.value - #runs) or #CHEAT_TIERS
        if free < #CHEAT_TIERS then
            out:AddMessage("|cffff3333" .. string.format(DCL("All four tiers need 4 free test slots, %d free now. Raise the limit with + or stop other tests."), math.max(free, 0)) .. "|r")
            return
        end
        for _, t in ipairs(CHEAT_TIERS) do tierQueue[#tierQueue + 1] = TierReplayCommand(run, t.key) end
        tierQueueAt = 0
        tierQueueFrame:Show()
        out:AddMessage("|cff3da6ff" .. DCL("Starting the same party at Normal, Story, Casual and Speed (3 s apart).") .. "|r")
    end
    local function ReplayMenu(run)
        local sub = {}
        for _, t in ipairs(CHEAT_TIERS) do
            sub[#sub + 1] = { text = DCL(t.label), notCheckable = true,
                              func = function() CloseDropDownMenus(); ReplayAtTier(run, t.key) end }
        end
        sub[#sub + 1] = { text = DCL("All four tiers at once") .. "  |cff999999(" .. DCL("Me: out") .. ")|r", notCheckable = true, disabled = run.roster,
                          func = function() CloseDropDownMenus(); ReplayAllTiers(run) end }
        -- DCTEST10C: the title says how it starts (the "Me" button as it is now)
        local how = run.roster and "" or ("  |cff999999(" .. DCL((DB().joinMe == "god" and "Me: in + god") or (DB().joinMe and "Me: in") or "Me: out") .. ")|r")
        return { text = DCL("Run it again (same seed and gear)") .. how, notCheckable = true, hasArrow = true, menuList = sub }
    end
    -- Switch a running test's tier (the server drops the old cheats, applies the new ones).
    local function SwitchTier(run, key)
        Send(".dc test bot " .. run.id .. " all tier " .. key)
        capture.relistAt = GetTime() + 1
    end
    local function TierMenu(run)
        local cur = (run.tier == nil or run.tier == "" or run.tier == "-") and "normal" or run.tier
        local sub = {}
        for _, t in ipairs(CHEAT_TIERS) do
            sub[#sub + 1] = { text = DCL(t.label), checked = cur == t.key,
                              func = function() CloseDropDownMenus(); SwitchTier(run, t.key) end }
        end
        return { text = DCL("Switch cheat tier"), notCheckable = true, hasArrow = true, menuList = sub }
    end

    -- DCTEST6A: right-click menu of a finished run.
    local function ShowFinishedMenu(run)
        local menu = {
            { text = DungeonName(run.token) .. (run.heroic and (" " .. DCL("(Heroic)")) or "") .. "  |cff999999" .. DCL("Finished") .. "|r",
              isTitle = true, notCheckable = true },
            { text = DCL("Run stats"), notCheckable = true, func = function()
                selectedRun = run.id
                if run.kills then
                    info = { id = run.id, kills = run.kills, deaths = run.deathLog or {}, list = run.checklist or {}, dmg = run.dmg, heals = run.heals, hstats = run.hstats }
                    bottomMode = "stats"
                    RenderRuns()
                else
                    SendDcCommand("testinfo", run.id, true)
                end
            end },
            ReplayMenu(run),  -- DCGM1B2: pick the cheat tier
            { text = DCL("Copy its settings to the left"), notCheckable = true, func = function() CopySettings(run) end },
            { text = "|cffff3333" .. DCL("Delete this record") .. "|r", notCheckable = true, func = function()
                local hist, deleted = History()
                for i = #hist, 1, -1 do if hist[i].id == run.id then table.remove(hist, i) end end
                deleted[run.id] = true
                if selectedRun == run.id then selectedRun = nil end
                if info and info.id == run.id then info = nil; bottomMode = "gear" end
                RenderRuns()
            end },
            { text = DCL("Delete all finished records"), notCheckable = true, func = function()
                StaticPopup_Show("DUNGEONCLEAR_TEST_STOPONE", DCL("Delete all finished test records?"), nil, function()
                    local hist, deleted = History()
                    for _, h in ipairs(hist) do deleted[h.id] = true end
                    wipe(hist)
                    if info and not FindRun(info.id) then info = nil; bottomMode = "gear" end
                    RenderRuns()
                end)
            end },
            { text = CANCEL, notCheckable = true, func = function() CloseDropDownMenus() end },
        }
        EasyMenu(menu, runMenuFrame, "cursor", 0, 0, "MENU")
    end

    -- DCTEST7A: selecting a run shows its stats (boss checklist on top); a finished
    -- run uses its saved copy when it has one.
    LoadStats = function(run)
        if not run then return end
        if run.finished and run.kills then
            info = { id = run.id, kills = run.kills, deaths = run.deathLog or {}, list = run.checklist or {}, dmg = run.dmg, heals = run.heals, hstats = run.hstats }
            bottomMode = "stats"
            RenderRuns()
        else
            SendDcCommand("testinfo", run.id, true)
        end
    end

    function DCTestShowRunMenu(run)
        if run.finished then return ShowFinishedMenu(run) end
        local follow = {}
        for _, m in ipairs(run.members) do
            follow[#follow + 1] = { text = m.name, notCheckable = true,
                                    func = function() CloseDropDownMenus(); FollowBot(run, m.name) end }
        end
        local menu = {
            { text = DungeonName(run.token) .. (run.heroic and (" " .. DCL("(Heroic)")) or ""), isTitle = true, notCheckable = true },
            { text = DCL("Watch this run"), notCheckable = true, disabled = run.watching,
              func = function() Send(".dc test watch " .. run.id); capture.relistAt = GetTime() + 4 end },
            { text = DCL("Follow a bot"), notCheckable = true, hasArrow = true, menuList = follow,
              disabled = #follow == 0 },
            { text = DCL("Run stats"), notCheckable = true,
              func = function() SendDcCommand("testinfo", run.id, true) end },
            ReplayMenu(run),  -- DCGM1B2: pick the cheat tier
            TierMenu(run),    -- DCGM1B2: switch this run's tier now
            { text = DCL("Copy its settings to the left"), notCheckable = true, func = function() CopySettings(run) end },
            { text = "|cffff3333" .. DCL("Stop this test") .. "|r", notCheckable = true, func = function()
                StaticPopup_Show("DUNGEONCLEAR_TEST_STOPONE",
                    string.format(DCL("Stop the test run %s (%s)?"), run.id, DungeonName(run.token)), nil,
                    function() Send(".dc test stop " .. run.id); capture.relistAt = GetTime() + 2 end)
            end },
            { text = CANCEL, notCheckable = true, func = function() CloseDropDownMenus() end },
        }
        EasyMenu(menu, runMenuFrame, "cursor", 0, 0, "MENU")
    end

    -- DCGM1A: GM interventions on a running test's bots (.dc test bot).
    local function GMBot(run, who, action, arg)
        Send(".dc test bot " .. run.id .. " " .. who .. " " .. action .. (arg and (" " .. arg) or ""))
        capture.relistAt = GetTime() + 1
    end

    function DCTestShowMemberMenu(m)
        local run = FindRun(selectedRun)
        if not run then return end
        local god = m.cheat and m.cheat:find("g", 1, true) and true or false
        local pow = m.cheat and m.cheat:find("p", 1, true) and true or false
        local menu = {
            { text = m.name, isTitle = true, notCheckable = true },
            { text = DCL("Follow this bot (camera)"), notCheckable = true, func = function() FollowBot(run, m.name) end },
            { text = DCL("Details (gear, stats, talents)"), notCheckable = true, func = function() if DCTestInspect then DCTestInspect(m.name) end end },
            { text = DCL("Show its gear"), notCheckable = true, func = function() SendDcCommand("testgear", m.name, true) end },
            { text = DCL("Teleport next to it (.appear)"), notCheckable = true, func = function() Send(".appear " .. m.name) end },
            { text = DCL("GM actions"), isTitle = true, notCheckable = true },
            { text = DCL("Kill"), notCheckable = true, func = function() GMBot(run, m.name, "die") end },
            { text = DCL("Resurrect"), notCheckable = true, func = function() GMBot(run, m.name, "rez") end },
            { text = DCL("Invincible"), checked = god, keepShownOnClick = false,
              func = function() GMBot(run, m.name, "god", god and "off" or "on") end },
            { text = DCL("Unlimited mana / energy"), checked = pow, keepShownOnClick = false,
              func = function() GMBot(run, m.name, "power", pow and "off" or "on") end },
            { text = DCL("Teleport to the tank"), notCheckable = true, func = function() GMBot(run, m.name, "tele") end },
            { text = DCL("Clear its cheats"), notCheckable = true, func = function() GMBot(run, m.name, "clear") end },
            { text = CANCEL, notCheckable = true, func = function() CloseDropDownMenus() end },
        }
        EasyMenu(menu, runMenuFrame, "cursor", 0, 0, "MENU")
    end

    -- DCGM1A: party-wide GM actions for the selected run.
    -- DCGM1A2: created here, after FindRun / runMenuFrame / GMBot exist -- above them
    -- the click handler saw those names as (nil) globals.
    local partyBtn = LButton(lf, "Party actions", 96, function()
        local run = FindRun(selectedRun)
        if not run then
            out:AddMessage("|cffff3333" .. DCL("Select a running test first.") .. "|r")
            return
        end
        local menu = {
            { text = DCL("Party actions") .. ": " .. run.id, isTitle = true, notCheckable = true },
            { text = DCL("Kill everyone who can resurrect"), notCheckable = true, func = function() GMBot(run, "rezzers", "die") end },
            { text = DCL("Kill the healers"), notCheckable = true, func = function() GMBot(run, "healers", "die") end },
            { text = DCL("Leave only the tank alive"), notCheckable = true, func = function() GMBot(run, "allbuttank", "die") end },
            { text = DCL("Wipe the party"), notCheckable = true, func = function() GMBot(run, "all", "die") end },
            { text = DCL("Resurrect everyone"), notCheckable = true, func = function() GMBot(run, "all", "rez") end },
            { text = DCL("Tank invincible"), notCheckable = true, func = function() GMBot(run, "tank", "god", "on") end },
            { text = DCL("Healers unlimited mana"), notCheckable = true, func = function() GMBot(run, "healers", "power", "on") end },
            { text = DCL("Whole party invincible"), notCheckable = true, func = function() GMBot(run, "all", "god", "on") end },
            { text = DCL("Clear all cheats"), notCheckable = true, func = function() GMBot(run, "all", "clear") end },
            TierMenu(run),  -- DCGM1B2
            { text = CANCEL, notCheckable = true, func = function() CloseDropDownMenus() end },
        }
        EasyMenu(menu, runMenuFrame, "cursor", 0, 0, "MENU")
    end)
    partyBtn:SetPoint("BOTTOMRIGHT", memBox, "TOPRIGHT", 0, 2)

    -- DCTEST4C: camera row. Follow the selected run's tank, step through its bots,
    -- fly free (god view), or end the watch and go back where you were.
    local function TankOf(run)
        for _, m in ipairs(run.members) do if m.role == "tank" then return m.name end end
        return run.members[1] and run.members[1].name
    end
    local VIEW_BTNS = {
        { "Follow tank", 72, "Camera on the selected run's tank (enters that run first if you are not watching it).",
          function()
              local run = FindRun(selectedRun)
              local tank = run and TankOf(run)
              if tank then FollowBot(run, tank); SetCameraState("follow") end
          end },
        { "Prev", 52, "Camera on the previous bot of the run you are watching.",
          function() Send(".dc spectate prev"); SetCameraState("follow") end },
        { "Next", 52, "Camera on the next bot of the run you are watching.",
          function() Send(".dc spectate next"); SetCameraState("follow") end },
        { "Free view", 72, "God view: fly the camera freely around the run you are watching (WASD / mouse). Follow tank goes back to following.",
          function()
              if cameraState == "free" then
                  out:AddMessage("|cffffd100" .. DCL("Already in free view. Use Follow tank to follow again, or End watching.") .. "|r")
                  return
              end
              Send(".dc spectate free"); SetCameraState("free")
          end },
        { "End watching", 80, "End the watch: you go back to where you were, visible again.",
          function() Send(".dc test watch off") end },
    }
    local prevView
    for _, def in ipairs(VIEW_BTNS) do
        local b = LButton(lf, def[1], def[2], def[4])
        if prevView then b:SetPoint("LEFT", prevView, "RIGHT", 4, 0)
        else b:SetPoint("TOPLEFT", lf, "TOPLEFT", 14, -58 - RUN_ROWS * RUN_H - 14); lf.dcCamFirst = b end  -- DCTEST9B
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(DCL(def[1]))
            GameTooltip:AddLine(DCL(def[3]), 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        prevView = b
    end

    local function RunSort(a, b)
        if a.watching ~= b.watching then return a.watching end
        return a.order < b.order
    end

    RenderMembers = function()
        local run
        for _, r in ipairs(runs) do if r.id == selectedRun then run = r end end
        if not run and selectedRun then run = HistFind(selectedRun) end  -- DCTEST6A
        if not run then
            memLabel:SetText(DCL("Party"))
            for _, r in ipairs(memRows) do r:Hide() end
            return
        end
        memLabel:SetText(DCL("Party") .. ": " .. DungeonName(run.token) .. "  |cff999999" .. run.id .. "|r")
        memOffset = math.max(0, math.min(memOffset, #run.members - memVis))  -- DCTEST9A
        for i, r in ipairs(memRows) do
            local m = (i <= memVis) and run.members[i + memOffset] or nil
            r.member = m
            if m then
                local token = CLASS_TOKENS[m.class]
                local tc = token and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[token]
                if tc then r.cls:SetTexCoord(unpack(tc)); r.cls:Show() else r.cls:Hide() end
                local cc = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
                local color = cc and string.format("|cff%02x%02x%02x", cc.r * 255, cc.g * 255, cc.b * 255) or "|cffcccccc"
                -- DCTEST9A: role chip + bars instead of "HP 87%  MP 40%"
                local CHIP = { tank = { "Tank (short)", 0.22, 0.40, 0.75, "T" }, healer = { "Healer (short)", 0.15, 0.52, 0.26, "H" },
                               heal = { "Healer (short)", 0.15, 0.52, 0.26, "H" }, dps = { "DPS (chip)", 0.62, 0.30, 0.15, "D" } }
                local chip = CHIP[m.role or ""] or CHIP.dps
                r.chip:SetTexture(chip[2], chip[3], chip[4], 0.9)
                local ct = DCL(chip[1]); r.chipText:SetText(ct ~= chip[1] and ct or chip[5])
                local POWER = { [0] = { 0.20, 0.45, 1.00 }, [1] = { 0.90, 0.15, 0.15 }, [2] = { 1.00, 0.50, 0.25 },
                                [3] = { 1.00, 0.85, 0.10 }, [6] = { 0.00, 0.82, 1.00 } }
                local W = 362 - 27 - 58
                local live = not run.finished and m.alive
                if live then
                    local f = math.max(0, math.min(1, (m.hp or 0) / 100))
                    local c = f > 0.5 and { 0.15, 0.85, 0.25 } or (f > 0.25 and { 1, 0.75, 0.1 } or { 1, 0.2, 0.15 })
                    r.hpBg:Show(); r.hp:SetTexture(c[1], c[2], c[3], 0.95); r.hp:SetWidth(math.max(1, W * f))
                    if f > 0 then r.hp:Show() else r.hp:Hide() end
                    local pt, pp = m.ptype, m.ppct
                    if not pt and (m.mp or -1) >= 0 then pt, pp = 0, m.mp end  -- older server: mana only
                    if pt and pt >= 0 and pp and pp >= 0 then
                        local pc = POWER[pt] or POWER[0]
                        r.pwBg:Show(); r.pw:SetTexture(pc[1], pc[2], pc[3], 0.95)
                        r.pw:SetWidth(math.max(1, W * math.min(1, pp / 100)))
                        if pp > 0 then r.pw:Show() else r.pw:Hide() end
                    else
                        r.pwBg:Hide(); r.pw:Hide()
                    end
                else
                    r.hpBg:Hide(); r.hp:Hide(); r.pwBg:Hide(); r.pw:Hide()
                end
                local hp = run.finished and ("|cff808080" .. DCL("Finished") .. "|r")
                           or (m.alive and "" or ("|cffff3333" .. DCL("dead") .. "|r"))
                local mp = ""
                local fight = (m.combat and not run.finished) and " |cffff6600*|r" or ""
                -- DCGM1A: active GM cheats on this bot.
                if m.cheat:find("g", 1, true) then fight = fight .. " |cffffd100[" .. DCL("God") .. "]|r" end
                if m.cheat:find("p", 1, true) then fight = fight .. " |cff3da6ff[" .. DCL("Inf. MP") .. "]|r" end
                r.text:SetText(string.format("%s%s|r  |cff9aa4b2%s %d · %s %d|r  %s%s%s",
                    color, m.name, DCL("Lv"), m.level, DCL("iLvl"), m.ilvl, hp, mp, fight))  -- DCTEST9A
                r:Show()
            else
                r:Hide()
            end
        end
    end

    RenderGear = function()
        if bottomMode == "stats" and info then
            RenderStats()
            return
        end
        statsBox:Hide()
        if not gear then
            gearLabel:SetText(DCL("Run stats") .. ": |cff999999" .. DCL("right-click a run above") .. "|r")
            gearBox:Hide()
            return
        end
        gearLabel:SetText(DCL("Gear") .. ": " .. gear.name .. "  |cff999999" .. DCL("iLvl") .. " " .. gear.ilvl .. "|r")
        gearBox:Show()
        for i, c in ipairs(gearCells) do
            local it = gear.items[i]
            c.itemId = it and it.id
            if it then
                local name, _, quality, _, _, _, _, _, _, tex = GetItemInfo(it.id)
                c.icon:SetTexture(tex or (GetItemIcon and GetItemIcon(it.id)) or "Interface\\Icons\\INV_Misc_QuestionMark")
                local q = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality or it.q]
                local hex = q and q.hex or "|cffffffff"
                c.text:SetText(hex .. (name or ("#" .. it.id)) .. "|r |cff999999" .. it.ilvl .. "|r")
                c:Show()
            else
                c:Hide()
            end
        end
    end

    RenderRuns = function()
        table.sort(runs, RunSort)
        local watching = 0
        for _, r in ipairs(runs) do if r.watching then watching = watching + 1 end end
        local capText = ""
        if cap.value then
            capText = " / " .. DCL("limit") .. " " .. (cap.value == 0 and DCL("unlimited") or cap.value)
            if cap.over then capText = capText .. " |cffffd100(" .. DCL("conf") .. " " .. (cap.conf == 0 and DCL("unlimited") or cap.conf) .. ")|r" end
        end
        -- DCTEST6A: live runs first, then the finished ones (newest first).
        local shown = {}
        -- RebornWOW DCTEST10A: [Mine] = runs this character started; [All] = everyone's
        local me, all = UnitName("player"), DB().listScope == "all"
        local liveShown = 0
        for _, r in ipairs(runs) do
            if all or r.gm == me then shown[#shown + 1] = r; liveShown = liveShown + 1 end
        end
        for _, h in ipairs((History())) do
            if all or h.gm == me then shown[#shown + 1] = h end
        end
        shownCount = #shown
        local finCount = #shown - liveShown
        lCount:SetWidth(196)
        lCount:SetText(DCL("Running:") .. " " .. liveShown .. capText ..
            (finCount > 0 and ("  |cff999999" .. DCL("Finished") .. " " .. finCount .. "|r") or ""))
        local found = false
        for _, r in ipairs(shown) do if r.id == selectedRun then found = true end end
        if not found then selectedRun = shown[1] and shown[1].id or nil end
        runOffset = math.max(0, math.min(runOffset, #shown - runVis))  -- DCTEST9A
        for i, row in ipairs(runRows) do
            local run = (i <= runVis) and shown[i + runOffset] or nil
            row.run = run
            if run and run.finished then
                local heroic = run.heroic and (" |cffff8000" .. DCL("(Heroic)") .. "|r") or ""
                local res = run.result == "success" and ("|cff00ff00" .. DCL("Passed") .. "|r")
                    or (run.result and run.result ~= "") and ("|cffff3333" .. DCL(RESULT_NAMES[run.result] or run.result) .. "|r")
                    or ("|cff999999" .. DCL("Result unknown") .. "|r")
                local extra = ""
                if (run.regroups or 0) > 0 then extra = extra .. "  |cffff8000" .. DCL("Entrance revives") .. " " .. run.regroups .. "|r" end
                if (run.cheats or 0) > 0 then extra = extra .. "  |cffffd100" .. DCL("GM actions") .. " " .. run.cheats .. "|r" end
                row.l1:SetText(string.format("|cff999999%s|r  %s|cffffd100%s|r%s  %s  %s %d/%d  %s %d%s",
                    DCL("Finished"), TierTag(run.tier), DungeonName(run.token), heroic, res, DCL("Bosses"),
                    run.killed or 0, run.total or 0, DCL("Deaths"), run.deaths or 0, extra))  -- DCGM1B3 tier first
                local d = DCL("Time") .. " " .. Clock(run.elapsed or 0)
                if run.endedAt and run.endedAt > 0 then d = d .. "  " .. date("%m-%d %H:%M", run.endedAt) end
                if run.reason and run.reason ~= "" then d = d .. "  |cffff3333" .. run.reason .. "|r" end
                row.l2:SetText(d)
                row.watch:Hide()
                if run.id == selectedRun then row:LockHighlight() else row:UnlockHighlight() end
                row:Show()
            elseif run then
                row.watch:Show()
                local mark = run.watching and ("|cff00ff00" .. DCL("Watching") .. "|r  ") or ""
                local heroic = run.heroic and (" |cffff8000" .. DCL("(Heroic)") .. "|r") or ""
                local stage = DCL(STAGES[run.stage or ""] or run.stage or "?")  -- DCTEST9A: never nil
                local alert = run.wiped and ("  |cffff3333" .. DCL("wiped") .. "|r") or (run.combat and ("  |cffff6600" .. DCL("in combat") .. "|r") or "")
                local dead = (run.deaths and run.deaths > 0) and ("  |cffff3333" .. DCL("Deaths") .. " " .. run.deaths .. "|r") or ""
                row.l1:SetText(string.format("%s%s|cffffd100%s|r%s  %s  %s %d/%d%s%s",
                    mark, TierTag(run.tier), DungeonName(run.token), heroic, stage, DCL("Bosses"),
                    run.killed or 0, run.total or 0, dead, alert))  -- DCGM1B3 tier first; DCTEST9A: never nil
                local detail = DCL("Time") .. " " .. Clock(run.elapsed)
                if run.boss and run.boss ~= "" then detail = detail .. "  " .. DCL("Target:") .. " " .. run.boss end
                if run.stall and run.stall ~= "" then
                    detail = detail .. "  |cffff3333" .. (DCLDetail(run.stall) or run.stall) .. "|r"
                elseif run.state and run.state ~= "" then
                    local label, color = FormatStateTiny(run.state)
                    detail = detail .. "  |cff" .. RgbToHex(color) .. label .. "|r"
                end
                row.l2:SetText(detail)
                if run.watching then
                    DCBind(row.watch, "Watching")
                    row.watch:Disable()
                else
                    DCBind(row.watch, "Watch")
                    row.watch:Enable()
                end
                if run.id == selectedRun then row:LockHighlight() else row:UnlockHighlight() end
                row:Show()
            else
                row:Hide()
            end
        end
        if #shown == 0 then
            runRows[1].run = nil
            runRows[1].l1:SetText("|cff999999" .. DCL("No test run is running. Start one on the left.") .. "|r")
            runRows[1].l2:SetText("")
            runRows[1].watch:Hide()
            runRows[1]:Show()
        end
        RenderMembers()
        RenderGear()
    end

    -- Server replies, routed here by OnAddonMessage.
    local INSPECT_KINDS = { TIN_START = true, TIN_END = true, TIN_ERR = true, TIS = true, TIS2 = true,
                            TII = true, TIT = true, TIP = true, TIG = true, TIA = true }
    function DCTestOnAddon(parts)
        local kind = parts[1]
        if INSPECT_KINDS[kind] then
            if DCTestInspectOnAddon then DCTestInspectOnAddon(parts) end
            return
        end
        if kind == "TRCAP" then
            cap.value, cap.conf, cap.over = tonumber(parts[2]) or 0, tonumber(parts[3]) or 0, parts[4] == "1"
            RenderRuns()
            return
        end
        if kind == "TR_START" then
            pending = {}
            finPending = {}
            if parts[3] then
                cap.value, cap.conf, cap.over = tonumber(parts[3]) or 0, tonumber(parts[4]) or 0, parts[5] == "1"
            end
        elseif kind == "TR" and pending then
            pending[#pending + 1] = {
                order = #pending + 1, id = parts[2], token = parts[3], heroic = parts[4] == "1",
                stage = parts[5], elapsed = tonumber(parts[6]) or 0, killed = tonumber(parts[7]) or 0,
                total = tonumber(parts[8]) or 0, watching = parts[9] == "1", wiped = parts[10] == "1",
                combat = parts[11] == "1", level = tonumber(parts[12]) or 0, members = {},
                gm = (parts[13] and parts[13] ~= "-") and parts[13] or nil,  -- DCTEST10A
            }
        elseif kind == "TRS" and pending then
            for _, r in ipairs(pending) do
                if r.id == parts[2] then r.state, r.boss, r.stall = parts[3], parts[4], parts[5] end
            end
        elseif kind == "TRX" and pending then
            for _, r in ipairs(pending) do
                if r.id == parts[2] then
                    r.seed, r.gearIlvl, r.gearQuality = tonumber(parts[3]) or 0, tonumber(parts[4]) or 0, tonumber(parts[5]) or 0
                    r.roster = parts[6] == "1"
                    r.deaths, r.pulls = tonumber(parts[7]) or 0, tonumber(parts[8]) or 0
                    r.tier = parts[10] or ""  -- DCGM1B2
                    r.comp = {}
                    for name, role in (parts[9] or ""):gmatch("([^:,]+):([^,]*)") do
                        r.comp[#r.comp + 1] = { name = name, role = role }
                    end
                end
            end
        elseif kind == "TI_START" then
            infoPending = { id = parts[2], kills = {}, deaths = {}, list = {} }
        elseif kind == "TIB" and infoPending then
            infoPending.kills[#infoPending.kills + 1] = { t = tonumber(parts[2]) or 0, name = parts[3] or "" }
        elseif kind == "TID" and infoPending then
            -- DCBOSS1A: fields 6.. say what killed them; "-" means none
            local function Dash(v) if v == nil or v == "-" then return "" end return v end
            infoPending.deaths[#infoPending.deaths + 1] = { t = tonumber(parts[2]) or 0, name = parts[3] or "",
                onBoss = parts[4] == "1", by = parts[5] or "",
                killer = Dash(parts[6]), spellId = tonumber(parts[7]) or 0, spell = Dash(parts[8]),
                amount = tonumber(parts[9]) or 0, overkill = tonumber(parts[10]) or 0, bossHp = tonumber(parts[11]) or -1,
                dmg5 = tonumber(parts[12]) or 0, heal5 = tonumber(parts[13]) or 0, role = Dash(parts[14]),
                topSrc = Dash(parts[15]), topSpell = Dash(parts[16]), topAmount = tonumber(parts[17]) or 0,
                healers = Dash(parts[18]) }  -- DCBOSS1B
        elseif kind == "TIQ" and infoPending then  -- DCBOSS1A/B2: damage taken by source and spell (TIS is the inspect window's)
            infoPending.dmg = infoPending.dmg or {}
            infoPending.dmg[#infoPending.dmg + 1] = { src = parts[2] or "", spellId = tonumber(parts[3]) or 0,
                spell = (parts[4] ~= "-" and parts[4]) or "", total = tonumber(parts[5]) or 0, hits = tonumber(parts[6]) or 0 }
        elseif kind == "TIX" and infoPending then  -- DCBOSS1B: what each healer did
            infoPending.hstats = infoPending.hstats or {}
            infoPending.hstats[#infoPending.hstats + 1] = { name = parts[2] or "", combat = tonumber(parts[3]) or 0,
                moving = tonumber(parts[4]) or 0, casting = tonumber(parts[5]) or 0, low = tonumber(parts[6]) or 0,
                lowMoving = tonumber(parts[7]) or 0, lowIdle = tonumber(parts[8]) or 0, minMana = tonumber(parts[9]) or 100,
                casts = (parts[10] ~= nil and parts[10] ~= "-") and parts[10] or "" }  -- DCBOSS1C
        elseif kind == "TIH" and infoPending then  -- DCBOSS1A: healing by healer
            infoPending.heals = infoPending.heals or {}
            infoPending.heals[#infoPending.heals + 1] = { name = parts[2] or "", total = tonumber(parts[3]) or 0 }
        elseif kind == "TIL" and infoPending then  -- DCTEST7A: boss checklist row
            infoPending.list[#infoPending.list + 1] = { name = parts[2] or "", objective = parts[3] == "1",
                                                        status = parts[4] or "alive" }
        elseif kind == "TI_END" and infoPending then
            info, infoPending = infoPending, nil
            local h = HistFind(info.id)  -- DCTEST6A: keep the stats with the finished record
            if h then
                h.kills, h.deathLog = info.kills, info.deaths
                h.dmg, h.heals, h.hstats = info.dmg, info.heals, info.hstats  -- DCBOSS1A / 1B
                if #info.list > 0 then h.checklist = info.list end
            end
            bottomMode = "stats"
            if lf:IsShown() then RenderGear() end
        elseif kind == "TI_ERR" then
            out:AddMessage("|cffff3333" .. DCL("That test run has already finished.") .. "|r")
        elseif kind == "TRM" and pending then
            for _, r in ipairs(pending) do
                if r.id == parts[2] then
                    r.members[#r.members + 1] = {
                        name = parts[3], class = tonumber(parts[4]) or 0, role = parts[5],
                        level = tonumber(parts[6]) or 0, ilvl = tonumber(parts[7]) or 0,
                        hp = tonumber(parts[8]) or 0, mp = tonumber(parts[9]) or -1,
                        alive = parts[10] == "1", combat = parts[11] == "1",
                        cheat = parts[13] or "",  -- DCGM1A: "g" god, "p" unlimited power
                        ptype = tonumber(parts[14]), ppct = tonumber(parts[15]),  -- DCTEST9A
                    }
                end
            end
        elseif kind == "TRF" and finPending then
            finPending[#finPending + 1] = {
                id = parts[2], token = parts[3], heroic = parts[4] == "1", result = parts[5] or "",
                elapsed = tonumber(parts[6]) or 0, killed = tonumber(parts[7]) or 0, total = tonumber(parts[8]) or 0,
                deaths = tonumber(parts[9]) or 0, regroups = tonumber(parts[10]) or 0, cheats = tonumber(parts[11]) or 0,
                level = tonumber(parts[12]) or 0, seed = tonumber(parts[13]) or 0, gearIlvl = tonumber(parts[14]) or 0,
                gearQuality = tonumber(parts[15]) or 0, roster = parts[16] == "1", comp = {},
                tier = parts[17] or "",  -- DCGM1B2
                gm = (parts[18] and parts[18] ~= "-") and parts[18] or nil,  -- DCTEST10A
            }
        elseif kind == "TRFC" and finPending then
            for _, f in ipairs(finPending) do
                if f.id == parts[2] then
                    for name, role, cls, lvl in (parts[3] or ""):gmatch("([^:,]+):([^:,]*):([^:,]*):(%d*)") do
                        f.comp[#f.comp + 1] = { name = name, role = role, className = cls, level = tonumber(lvl) or 0 }
                    end
                end
            end
        elseif kind == "TRFR" and finPending then
            for _, f in ipairs(finPending) do
                if f.id == parts[2] then f.endedAt, f.reason = tonumber(parts[3]) or 0, parts[4] or "" end
            end
        elseif kind == "TR_END" and pending then
            -- DCTEST6A: a run that left the live list keeps its last party snapshot; the
            -- server's finished records then fill in the outcome.
            local hist, deleted = History()
            for _, old in ipairs(runs) do
                local still = false
                for _, r in ipairs(pending) do if r.id == old.id then still = true end end
                if not still and not deleted[old.id] and not HistFind(old.id) then
                    local mem = {}
                    for _, m in ipairs(old.members or {}) do
                        mem[#mem + 1] = { name = m.name, class = m.class, role = m.role, level = m.level, ilvl = m.ilvl,
                                          hp = 0, mp = -1, alive = true, combat = false, cheat = "" }
                    end
                    table.insert(hist, 1, { id = old.id, finished = true, token = old.token, heroic = old.heroic,
                        level = old.level, seed = old.seed, gearIlvl = old.gearIlvl, gearQuality = old.gearQuality,
                        roster = old.roster, comp = old.comp, killed = old.killed, total = old.total, tier = old.tier,
                        deaths = old.deaths, pulls = old.pulls, elapsed = old.elapsed, members = mem,
                        result = "", endedAt = time(), gm = old.gm })  -- gm: DCTEST10A
                end
            end
            for i = #(finPending or {}), 1, -1 do
                local f = finPending[i]
                if not deleted[f.id] then
                    local h = HistFind(f.id)
                    if not h then
                        h = { id = f.id, finished = true, members = {} }
                        table.insert(hist, 1, h)
                    end
                    for _, k in ipairs({ "token", "heroic", "result", "elapsed", "killed", "total", "deaths", "regroups",
                                         "cheats", "level", "seed", "gearIlvl", "gearQuality", "roster", "endedAt", "reason",
                                         "tier", "gm" }) do  -- gm: DCTEST10A
                        if f[k] ~= nil then h[k] = f[k] end
                    end
                    if #f.comp > 0 then h.comp = f.comp end
                    if #h.members == 0 then
                        for _, c in ipairs(f.comp) do
                            local cls = 0
                            for id, tok in pairs(CLASS_TOKENS) do
                                if tok:lower() == (c.className or ""):lower():gsub("[%s_]", "") then cls = id end
                            end
                            h.members[#h.members + 1] = { name = c.name, class = cls, role = c.role, level = c.level,
                                                          ilvl = 0, hp = 0, mp = -1, alive = true, combat = false, cheat = "" }
                        end
                    end
                end
            end
            finPending = nil
            table.sort(hist, function(a, b) return (a.endedAt or 0) > (b.endedAt or 0) end)
            while #hist > 50 do table.remove(hist) end
            runs, pending = pending, nil
            -- The server knows which run you sit in; that survives a /reload, the flag does not.
            for _, r in ipairs(runs) do if r.watching then DCTestWatchActive = true end end
            if lf:IsShown() then RenderRuns() end
        elseif kind == "TR_ERR" then
            out:AddMessage("|cffff3333" .. DCL("The test-run list needs a GM account.") .. "|r")
            lf:Hide()
        elseif kind == "TRG_START" then
            gearPending = { name = parts[2], class = tonumber(parts[3]) or 0, level = tonumber(parts[4]) or 0,
                            ilvl = tonumber(parts[5]) or 0, items = {} }
        elseif kind == "TRG" and gearPending then
            local it = { slot = tonumber(parts[2]) or 0, id = tonumber(parts[3]) or 0,
                         ilvl = tonumber(parts[4]) or 0, q = tonumber(parts[5]) or 1 }
            gearPending.items[#gearPending.items + 1] = it
            -- Ask the client cache now so names/icons are there for the next redraw.
            if GetItemInfo(it.id) == nil then
                GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
                GameTooltip:SetHyperlink("item:" .. it.id)
                GameTooltip:Hide()
            end
        elseif kind == "TRG_END" and gearPending then
            gear, gearPending = gearPending, nil
            bottomMode = "gear"
            capture.regearAt = GetTime() + 1.5  -- second paint once the item cache answered
            if lf:IsShown() then RenderGear() end
        elseif kind == "TRG_ERR" then
            out:AddMessage("|cffff3333" .. DCL("That bot is no longer online:") .. " " .. (parts[2] or "") .. "|r")
        end
    end

    local lfElapsed = 0
    lf:SetScript("OnUpdate", function(_, elapsed)
        lfElapsed = lfElapsed + elapsed
        if lfElapsed >= 5 or (capture.relistAt and GetTime() >= capture.relistAt) then
            lfElapsed = 0
            capture.relistAt = nil
            SendDcCommand("testruns", "", true)
            -- DCTEST7A: the open stats of a live run follow its progress.
            if bottomMode == "stats" and info and FindRun(info.id) then SendDcCommand("testinfo", info.id, true) end
        end
        if pendingFollow and GetTime() >= pendingFollow.at then
            Send(".dc spectate follow " .. pendingFollow.name)
            pendingFollow = nil
        end
        if capture.regearAt and GetTime() >= capture.regearAt then
            capture.regearAt = nil
            RenderGear()
        end
    end)
    lf:SetScript("OnShow", function()
        PlaceList()
        DB().listShown = true
        lfElapsed = 0
        RenderRuns()
        SendDcCommand("testruns", "", true)
    end)
    lf:SetScript("OnHide", function() DB().listShown = false end)
    lClose:SetScript("OnClick", function() lf:Hide() end)

    local listBtn = Button("Test run list", 96, function()
        if lf:IsShown() then lf:Hide() else lf:Show() end
    end, "Open the list of every running test: watch any of them, see each party's bots, their level, item level, health and gear.")
    listBtn:SetPoint("LEFT", runLabel, "RIGHT", 12, 0)
    -- RebornWOW DCGM1D: GM kill / raise for YOUR OWN party (not a test run), to test the
    -- player-led death flow on demand. Same menu as /dc gm. Only your bots and you.
    local myMenuFrame = CreateFrame("Frame", "DungeonClearMyPartyMenu", UIParent, "UIDropDownMenuTemplate")
    function DCMyPartyMenu()
        local function P(who, act)
            -- DCGM1G: over the addon channel, so it also works while you are dead
            -- (the client blocks chat from a corpse); the server runs .dc party.
            out:AddMessage("|cff3da6ff> .dc party " .. who .. " " .. act .. "|r")
            SendDcCommand("gmparty", who .. " " .. act)
            if DCTierRefreshSoon then DCTierRefreshSoon() end  -- DCGM1F: repaint the tag
        end
        local tiers = {}
        for _, t in ipairs({ { "normal", "Normal" }, { "story", "Story" }, { "casual", "Casual" }, { "speed", "Speed" } }) do
            tiers[#tiers + 1] = { text = DCL(t[2]), notCheckable = true,
                                  func = function() CloseDropDownMenus(); P("bots", "tier " .. t[1]) end }
        end
        local menu = {
            { text = DCL("My party (GM)"), isTitle = true, notCheckable = true },
            { text = DCL("Kill everyone who can resurrect"), notCheckable = true, func = function() P("rezzers", "die") end },
            { text = DCL("Kill the healers"), notCheckable = true, func = function() P("healers", "die") end },
            { text = DCL("Leave only the tank alive"), notCheckable = true, func = function() P("allbuttank", "die") end },
            { text = DCL("Kill all bots"), notCheckable = true, func = function() P("bots", "die") end },
            { text = DCL("Kill me"), notCheckable = true, func = function() P("me", "die") end },
            { text = DCL("Wipe the party (bots and me)"), notCheckable = true, func = function() P("all", "die") end },
            { text = DCL("Resurrect everyone"), notCheckable = true, func = function() P("all", "rez") end },
            { text = DCL("Cheat tier for my bots"), notCheckable = true, hasArrow = true, menuList = tiers },
            { text = CANCEL, notCheckable = true, func = function() CloseDropDownMenus() end },
        }
        EasyMenu(menu, myMenuFrame, "cursor", 0, 0, "MENU")
    end
    -- DCGM1F: no button here any more -- "my party" is mode 1 and lives on the main
    -- panel (GM button) and /dc gm; this window is for test runs (design §9.1).
    DCLoc.OnChange(function() if lf:IsShown() then RenderRuns() end end)
    tf:HookScript("OnShow", function() if DB().listShown then lf:Show() end end)
    tf:HookScript("OnHide", function() local was = lf:IsShown(); lf:Hide(); DB().listShown = was end)

    testBtn:SetScript("OnClick", function()
        if tf:IsShown() then tf:Hide() else tf:Show() end
    end)
    Tip(testBtn, "Bot Test Runs (GM)", "Start, watch and stop automated bot test runs (.dc test).")
    DCLoc.OnChange(function() if tf:IsShown() then RefreshDungeonList() end end)

    -- ------------------------------------------------------------ dock into the panel (RebornWOW DCUI4A)
    -- Test mode of the big panel: the bot test window becomes the centre column and the
    -- run list is split by height -- runs and camera row (the upper 300 px) stay in the
    -- left column, the party and gear / stats below move to the right column. Nothing is
    -- rebuilt: frames are re-parented and re-anchored, and DCTestUndock() puts every
    -- anchor, size, strata and drag back exactly as it was.
    ;(function()
    local SPLIT = -296           -- list anchors below this move to the right column
    local saved                  -- what DCTestUndock restores
    local docked = false
    local function Anchors(r)
        local list = {}
        for i = 1, (r.GetNumPoints and tonumber((r:GetNumPoints())) or 0) do list[i] = { r:GetPoint(i) } end
        return list
    end
    local function Reanchor(r, list)
        r:ClearAllPoints()
        for _, p in ipairs(list) do r:SetPoint(p[1], p[2], p[3], p[4], p[5]) end
    end
    local origPlace = PlaceList
    PlaceList = function(...)
        if docked then return end    -- the panel places it
        return origPlace(...)
    end
    function DCTestDocked() return docked end
    -- RebornWOW DCUI4A2: RebornWindowScale re-applies its saved scale and UIParent
    -- position on every show of these windows. While docked, each show re-pins them after
    -- that hook (ours is hooked later, so it runs later); its corner grips are hidden.
    local pins, hooked = {}, false
    local function Pin(f) if docked and pins[f] then pins[f]() end end
    -- RebornWOW DCTEST9D: while docked both windows carry `dcHosted`; RebornWindowScale
    -- (WSC1G) then leaves them alone -- no saved place / scale, no re-parent, no re-open.
    local function Hosted(on) tf.dcHosted = on or nil; lf.dcHosted = on or nil end
    local function Grips(f, show)
        for _, c in ipairs({ f:GetChildren() }) do
            local n = c.GetNormalTexture and c:GetNormalTexture()
            local p = n and n:GetTexture()
            if type(p) == "string" and p:find("SizeGrabber") then
                if show then c:Show() else c:Hide() end
            end
        end
    end
    function DCTestDock(hostL, hostC, hostR, view)
        if docked then return end
        docked = true
        Hosted(true)          -- DCTEST9D: before anything moves
        lHint:Hide()          -- DCTEST10A: room for [Mine] [All]
        listBtn:Hide()        -- DCTEST9D: the list is always shown in Test mode
        saved = { tf = {}, lf = {}, moved = {} }
        for key, f in pairs({ tf = tf, lf = lf }) do
            local s = saved[key]
            s.parent, s.points, s.w, s.h = f:GetParent(), Anchors(f), f:GetWidth(), f:GetHeight()
            s.strata, s.bg = f:GetFrameStrata(), { f:GetBackdropColor() }
            s.scale = f:GetScale()                          -- DCUI4A2
            f:SetScale(1)
            Grips(f, false)
            s.border = { f:GetBackdropBorderColor() }
            f:SetParent(view)
            f:SetFrameStrata(view:GetFrameStrata())
            f:SetFrameLevel(view:GetFrameLevel() + 4)
            f:RegisterForDrag()                 -- no dragging out of the panel
            f:SetBackdropColor(0, 0, 0, 0)
            f:SetBackdropBorderColor(0, 0, 0, 0)
        end
        tf:ClearAllPoints()
        tf:SetPoint("TOPLEFT", hostC, "TOPLEFT", 0, 0)
        tf:SetPoint("BOTTOMRIGHT", hostC, "BOTTOMRIGHT", 0, 0)
        lf:ClearAllPoints()
        lf:SetPoint("TOPLEFT", hostL, "TOPLEFT", 0, 0)
        lf:SetSize(hostL:GetWidth(), 300)
        tclose:Hide(); lClose:Hide()
        -- DCTEST9A: the camera row to the column's foot, the run list down to it
        local camY = -58 - RUN_ROWS * RUN_H - 14
        for _, c in ipairs({ lf:GetChildren() }) do
            local np = c.GetNumPoints and tonumber((c:GetNumPoints())) or 0
            local p = np == 1 and { c:GetPoint(1) } or {}
            if c == lf.dcCamFirst or (np == 1 and p[2] == lf and p[3] == "TOPLEFT" and math.abs((tonumber(p[5]) or 0) - camY) < 1) then  -- DCTEST9B
                saved.moved[#saved.moved + 1] = { c, Anchors(c) }
                c:ClearAllPoints(); c:SetPoint("BOTTOMLEFT", hostL, "BOTTOMLEFT", p[4], 10)
            end
        end
        -- DCTEST9A: right column in two halves -- party on top, gear / stats below
        do
            local rh = tonumber((hostR:GetHeight())) or 0
            local half = math.floor(rh / 2)
            local mv = math.max(MEM_ROWS, math.min(MEM_MAX, math.floor((half - 18 - 8) / MEM_H)))
            saved.memH = memBox:GetHeight()
            saved.moved[#saved.moved + 1] = { gearLabel, Anchors(gearLabel) }
            saved.moved[#saved.moved + 1] = { gearBox, Anchors(gearBox) }
            saved.gearSize = { gearBox:GetWidth(), gearBox:GetHeight() }
            memVis = mv
            memBox:SetHeight(mv * MEM_H + 8)
            gearLabel:ClearAllPoints(); gearLabel:SetPoint("TOPLEFT", memBox, "BOTTOMLEFT", 4, -10)
            gearBox:ClearAllPoints()
            gearBox:SetPoint("TOPLEFT", gearLabel, "BOTTOMLEFT", -4, -6)
            gearBox:SetPoint("BOTTOMRIGHT", hostR, "BOTTOMRIGHT", -10, 44)  -- DCTEST9E: the auto-play row below
            memBox:EnableMouseWheel(true)
            memBox:SetScript("OnMouseWheel", function(_, d)
                memOffset = math.max(0, memOffset - d)
                if RenderMembers then RenderMembers() end
            end)
        end
        local hh = tonumber((hostL:GetHeight())) or 0
        local fit = math.floor((hh - 58 - 40 - 8) / RUN_H)
        runVis = math.max(RUN_ROWS, math.min(RUN_MAX, fit))
        runBox:SetHeight(runVis * RUN_H + 8)
        if RenderRuns then RenderRuns() end
        -- the list's lower half: everything anchored straight to lf below SPLIT, or to
        -- its bottom edge, now hangs off the right column (same x, y shifted up)
        local items = { lf:GetChildren() }
        for _, r in ipairs({ lf:GetRegions() }) do items[#items + 1] = r end
        for _, r in ipairs(items) do
            local pts = Anchors(r)
            local move = false
            for _, p in ipairs(pts) do
                if p[2] == lf and ((p[3] or ""):find("BOTTOM") or ((p[3] or ""):find("TOP") and (p[5] or 0) < SPLIT)) then
                    move = true
                end
            end
            if move then
                saved.moved[#saved.moved + 1] = { r, pts }
                r:ClearAllPoints()
                for _, p in ipairs(pts) do
                    local rel, rp, x, y = p[2], p[3] or p[1], p[4] or 0, p[5] or 0
                    if rel == lf then
                        rel = hostR
                        if rp:find("TOP") then y = y + 300 end
                    end
                    r:SetPoint(p[1], rel, rp, x, y)
                end
            end
        end
        -- DCUI4A2: the docked place, re-applied after any other addon's OnShow
        pins[tf] = function()
            tf:SetParent(view); tf:SetScale(1)
            tf:SetFrameStrata(view:GetFrameStrata()); tf:SetFrameLevel(view:GetFrameLevel() + 4)
            tf:ClearAllPoints()
            tf:SetPoint("TOPLEFT", hostC, "TOPLEFT", 0, 0)
            tf:SetPoint("BOTTOMRIGHT", hostC, "BOTTOMRIGHT", 0, 0)
            Grips(tf, false)
        end
        pins[lf] = function()
            lf:SetParent(view); lf:SetScale(1)
            lf:SetFrameStrata(view:GetFrameStrata()); lf:SetFrameLevel(view:GetFrameLevel() + 4)
            lf:ClearAllPoints()
            lf:SetPoint("TOPLEFT", hostL, "TOPLEFT", 0, 0)
            lf:SetSize(hostL:GetWidth(), 300)
            Grips(lf, false)
        end
        if not hooked then
            hooked = true
            tf:HookScript("OnShow", function() Pin(tf) end)
            lf:HookScript("OnShow", function() Pin(lf) end)
        end
        if not tf:IsShown() then tf:Show() end
        lf:Show()
        Pin(tf); Pin(lf)
    end
    function DCTestUndock()
        if not docked then return end
        docked = false
        for _, m in ipairs(saved.moved) do Reanchor(m[1], m[2]) end
        for key, f in pairs({ tf = tf, lf = lf }) do
            local s = saved[key]
            f:SetParent(s.parent)
            f:SetFrameStrata(s.strata)
            Reanchor(f, s.points)
            f:SetSize(s.w, s.h)
            f:RegisterForDrag("LeftButton")
            f:SetBackdropColor(unpack(s.bg))
            f:SetBackdropBorderColor(unpack(s.border))
            if s.scale then f:SetScale(s.scale) end       -- DCUI4A2
            Grips(f, true)
        end
        tclose:Show(); lClose:Show()
        runVis = RUN_ROWS; runBox:SetHeight(RUN_ROWS * RUN_H + 8)  -- DCTEST9A
        memVis, memOffset = MEM_ROWS, 0
        if saved.memH then memBox:SetHeight(saved.memH) end
        if saved.gearSize then gearBox:SetSize(saved.gearSize[1], saved.gearSize[2]) end
        for i = MEM_ROWS + 1, MEM_MAX do if memRows[i] then memRows[i]:Hide() end end
        for i = RUN_ROWS + 1, RUN_MAX do if runRows[i] then runRows[i]:Hide() end end
        lf:Hide()
        tf:Hide()                            -- leaving Test mode closes the test windows
        listBtn:Show()
        lHint:Show()          -- DCTEST10A
        Hosted(false)         -- DCTEST9D: only now, after both are closed
        saved = nil
    end
    -- RebornWOW DCTEST9F: only the mode buttons change the mode. A docked test window that
    -- got hidden (Esc, or anything else) is part of the panel: show it again a frame later
    -- (a frame later, because CopySettings refreshes with Hide(); Show()).
    local later = CreateFrame("Frame")
    later:Hide()
    later:SetScript("OnUpdate", function(self)
        self:Hide()
        if docked and not tf:IsShown() then tf:Show(); lf:Show() end
    end)
    lf:HookScript("OnHide", function()
        if docked then later:Show() end
    end)
    tf:HookScript("OnHide", function()
        if docked then later:Show() end
    end)
    end)()
end)()

-- Bot detail window (RebornWOW DCTEST4A): a test bot's character sheet -- gear laid
-- out like the character pane (C), stats, all three talent trees, glyphs and the
-- playerbots strategies it runs with. The bots are in other instances, so the
-- portrait is the class icon (the client can only draw a live portrait for a unit
-- it can see). Fed by the server's "testinspect <name>" reply.
;(function()
    local CLASS_TOKENS = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT",
                           "SHAMAN", "MAGE", "WARLOCK", nil, "DRUID" }
    local CLASS_NAMES = { "Warrior", "Paladin", "Hunter", "Rogue", "Priest", "Death Knight",
                          "Shaman", "Mage", "Warlock", nil, "Druid" }
    local RACE_NAMES = { "Human", "Orc", "Dwarf", "Night Elf", "Undead", "Tauren", "Gnome", "Troll",
                         nil, "Blood Elf", "Draenei" }
    local TREES = {
        { "Arms", "Fury", "Protection" }, { "Holy", "Protection", "Retribution" },
        { "Beast Mastery", "Marksmanship", "Survival" }, { "Assassination", "Combat", "Subtlety" },
        { "Discipline", "Holy", "Shadow" }, { "Blood", "Frost", "Unholy" },
        { "Elemental", "Enhancement", "Restoration" }, { "Arcane", "Fire", "Frost" },
        { "Affliction", "Demonology", "Destruction" }, nil, { "Balance", "Feral Combat", "Restoration" },
    }
    -- server equipment slot -> paper-doll background
    local SLOT_BG = { [0] = "Head", "Neck", "Shoulder", "Shirt", "Chest", "Waist", "Legs", "Feet", "Wrists",
                      "Hands", "Finger", "Finger", "Trinket", "Trinket", "Chest", "MainHand",
                      "SecondaryHand", "Ranged", "Tabard" }
    local SLOT_NAMES = { [0] = "Head", "Neck", "Shoulder", "Shirt", "Chest", "Waist", "Legs", "Feet", "Wrist",
                         "Hands", "Finger", "Finger", "Trinket", "Trinket", "Back", "Main Hand",
                         "Off Hand", "Ranged", "Tabard" }
    local ENCHANTABLE = { [0] = true, [2] = true, [4] = true, [6] = true, [7] = true, [8] = true,
                          [9] = true, [14] = true, [15] = true }
    local LEFT_SLOTS = { 0, 1, 2, 14, 4, 3, 18, 8 }
    local RIGHT_SLOTS = { 9, 5, 6, 7, 10, 11, 12, 13 }
    local BOTTOM_SLOTS = { 15, 16, 17 }

    local data, pending = nil, nil
    local W, H = 444, 520

    local f = CreateFrame("Frame", "DungeonClearBotInspectFrame", UIParent)
    f:SetSize(W, H)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    f:SetBackdropColor(0.03, 0.03, 0.05, 0.94)
    f:SetBackdropBorderColor(0.20, 0.22, 0.28, 1.0)
    f:Hide()
    tinsert(UISpecialFrames, "DungeonClearBotInspectFrame")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)

    -- header: class icon, name, identity, spec
    local portrait = f:CreateTexture(nil, "ARTWORK")
    portrait:SetSize(48, 48)
    portrait:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -12)
    portrait:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
    local nameText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    nameText:SetPoint("TOPLEFT", portrait, "TOPRIGHT", 10, -2)
    local idText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    idText:SetPoint("TOPLEFT", nameText, "BOTTOMLEFT", 0, -3)
    local specText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    specText:SetPoint("TOPLEFT", idText, "BOTTOMLEFT", 0, -3)
    local refresh = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refresh:SetSize(56, 20)
    refresh:SetPoint("TOPRIGHT", f, "TOPRIGHT", -30, -8)
    DCBind(refresh, "Refresh")
    refresh:SetScript("OnClick", function() if data then SendDcCommand("testinspect", data.name, true) end end)

    -- tabs
    local TAB_DEFS = { "Gear", "Stats", "Talents", "Glyphs & AI" }
    local tabs, pages = {}, {}
    local current = 1
    local Render  -- forward
    for i, label in ipairs(TAB_DEFS) do
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(100, 22)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 14 + (i - 1) * 104, -68)
        DCBind(b, label)
        b:SetScript("OnClick", function() current = i; Render() end)
        tabs[i] = b
        local p = CreateFrame("Frame", nil, f)
        p:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -96)
        p:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 10)
        p:SetBackdrop({
            bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 12, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 }
        })
        p:SetBackdropColor(0.10, 0.12, 0.16, 0.60)
        p:SetBackdropBorderColor(0.15, 0.17, 0.22, 0.8)
        p:Hide()
        pages[i] = p
    end

    local function ItemLink(it)
        return string.format("item:%d:%d:%d:%d:%d:0:%d:%d:%d", it.id, it.ench, it.g1, it.g2, it.g3,
            it.rand, it.suffix, data and data.level or 80)
    end

    ------------------------------------------------------------------ gear page
    local gp = pages[1]
    local slotButtons = {}
    local function MakeSlot(slot, x, y)
        local b = CreateFrame("Button", nil, gp)
        b:SetSize(36, 36)
        b:SetPoint("TOPLEFT", gp, "TOPLEFT", x, y)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        b.bg:SetTexture("Interface\\PaperDoll\\UI-PaperDoll-Slot-" .. SLOT_BG[slot])
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetAllPoints()
        b.border = b:CreateTexture(nil, "OVERLAY")
        b.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        b.border:SetBlendMode("ADD")
        b.border:SetSize(66, 66)
        b.border:SetPoint("CENTER", b, "CENTER", 0, 0)
        b.mark = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b.mark:SetPoint("TOPRIGHT", b, "TOPRIGHT", 1, 1)
        b.ilvl = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        b.ilvl:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 1)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.item then
                GameTooltip:SetHyperlink(ItemLink(self.item))
            else
                GameTooltip:SetText(DCL(SLOT_NAMES[slot]))
                GameTooltip:AddLine(DCL("empty"), 0.6, 0.6, 0.6)
            end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        slotButtons[slot] = b
    end
    for i, slot in ipairs(LEFT_SLOTS) do MakeSlot(slot, 8, -8 - (i - 1) * 42) end
    for i, slot in ipairs(RIGHT_SLOTS) do MakeSlot(slot, W - 20 - 8 - 36, -8 - (i - 1) * 42) end
    for i, slot in ipairs(BOTTOM_SLOTS) do MakeSlot(slot, (W - 20) / 2 - 64 + (i - 1) * 46, -8 - 8 * 42 - 4) end
    local gearSummary = gp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    gearSummary:SetPoint("TOPLEFT", gp, "TOPLEFT", 56, -12)
    gearSummary:SetPoint("RIGHT", gp, "RIGHT", -56, 0)
    gearSummary:SetJustifyH("LEFT")
    gearSummary:SetJustifyV("TOP")
    gearSummary:SetSpacing(4)
    local bigIcon = gp:CreateTexture(nil, "ARTWORK")
    bigIcon:SetSize(96, 96)
    bigIcon:SetPoint("CENTER", gp, "CENTER", 0, -40)
    bigIcon:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
    bigIcon:SetAlpha(0.35)

    local function RenderGear()
        local enchanted, enchantable, gems, sockets, missing = 0, 0, 0, 0, {}
        for slot, b in pairs(slotButtons) do
            local it = data.items[slot]
            b.item = it
            if it then
                local _, _, quality, _, _, _, _, _, _, tex = GetItemInfo(it.id)
                b.icon:SetTexture(tex or (GetItemIcon and GetItemIcon(it.id)) or "Interface\\Icons\\INV_Misc_QuestionMark")
                b.icon:Show()
                local q = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality or it.q]
                if q and (quality or it.q) >= 2 then
                    b.border:SetVertexColor(q.r, q.g, q.b)
                    b.border:Show()
                else
                    b.border:Hide()
                end
                b.ilvl:SetText(it.ilvl)
                            if ENCHANTABLE[slot] then
                    enchantable = enchantable + 1
                    if it.ench > 0 then enchanted = enchanted + 1 else missing[#missing + 1] = DCL(SLOT_NAMES[slot]) end
                end
                local g = (it.g1 > 0 and 1 or 0) + (it.g2 > 0 and 1 or 0) + (it.g3 > 0 and 1 or 0)
                gems, sockets = gems + g, sockets + it.sockets
                b.mark:SetText((ENCHANTABLE[slot] and it.ench == 0) and "|cffff3333!|r" or "")
            else
                b.icon:Hide()
                b.border:Hide()
                b.ilvl:SetText("")
                b.mark:SetText("")
            end
        end
        local lines = {
            DCL("Average item level") .. ": |cffffd100" .. data.ilvl .. "|r",
            DCL("Enchants") .. ": " .. (enchanted < enchantable and "|cffff3333" or "|cff00ff00") ..
                enchanted .. "/" .. enchantable .. "|r",
        }
        if #missing > 0 then lines[#lines + 1] = "|cffff3333" .. DCL("No enchant:") .. " " .. table.concat(missing, ", ") .. "|r" end
        lines[#lines + 1] = DCL("Gems") .. ": " .. (gems < sockets and "|cffff3333" or "|cff00ff00") .. gems .. "/" .. sockets .. "|r"
        lines[#lines + 1] = ""
        lines[#lines + 1] = "|cff999999" .. DCL("Hover an item for its full tooltip.") .. "|r"
        gearSummary:SetText(table.concat(lines, "\n"))
    end

    ------------------------------------------------------------------ stats page
    local sp = pages[2]
    local statCols = {}
    for c = 1, 2 do
        local fs = sp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", sp, "TOPLEFT", 12 + (c - 1) * 212, -10)
        fs:SetWidth(200)
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("TOP")
        fs:SetSpacing(3)
        statCols[c] = fs
    end
    local function Row(label, value) return "|cffcccccc" .. DCL(label) .. "|r  |cffffffff" .. value .. "|r" end
    local function Head(label) return "|cff3da6ff" .. DCL(label) .. "|r" end
    local function RenderStats()
        local s = data.stats or {}
        local s2 = data.stats2 or {}
        local function n(t, i) return t[i] or "-" end
        statCols[1]:SetText(table.concat({
            Head("Base"),
            Row("Strength", n(s, 1)), Row("Agility", n(s, 2)), Row("Stamina", n(s, 3)),
            Row("Intellect", n(s, 4)), Row("Spirit", n(s, 5)), Row("Armor", n(s, 6)),
            Row("Health", data.maxHp), Row("Mana", data.maxMana > 0 and data.maxMana or "-"),
            "",
            Head("Melee / Ranged"),
            Row("Attack power", n(s, 7)), Row("Ranged attack power", n(s, 8)),
            Row("Hit rating", n(s2, 1)), Row("Melee crit", n(s2, 3) .. "%"), Row("Ranged crit", n(s2, 4) .. "%"),
            Row("Haste rating", n(s2, 6)), Row("Expertise", n(s2, 8)), Row("Armor penetration rating", n(s2, 9)),
        }, "\n"))
        statCols[2]:SetText(table.concat({
            Head("Spell"),
            Row("Spell power", n(s, 9)), Row("Healing", n(s, 10)), Row("Spell hit rating", n(s2, 2)),
            Row("Spell crit", n(s2, 5) .. "%"), Row("Spell haste rating", n(s2, 7)),
            "",
            Head("Defense"),
            Row("Defense rating", n(s2, 10)), Row("Dodge", n(s2, 11) .. "%"), Row("Parry", n(s2, 12) .. "%"),
            Row("Block", n(s2, 13) .. "%"), Row("Resilience", n(s2, 14)),
        }, "\n"))
    end

    ---------------------------------------------------------------- talents page
    local tp = pages[3]
    local treeHeads, talentButtons = {}, {}
    local TREE_W, CELL = 138, 31
    for t = 1, 3 do
        local fs = tp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("TOPLEFT", tp, "TOPLEFT", 8 + (t - 1) * (TREE_W + 4), -8)
        fs:SetWidth(TREE_W)
        fs:SetJustifyH("CENTER")
        treeHeads[t] = fs
    end
    local function TalentButton(i)
        local b = talentButtons[i]
        if b then return b end
        b = CreateFrame("Button", nil, tp)
        b:SetSize(26, 26)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetAllPoints()
        b.rank = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        b.rank:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 3, -2)
        b:SetScript("OnEnter", function(self)
            if not self.spell then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("spell:" .. self.spell)
            GameTooltip:AddLine(string.format("%s %d/%d", DCL("Rank"), self.r, self.max), 1, 0.82, 0)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        talentButtons[i] = b
        return b
    end
    local function RenderTalents()
        local names = TREES[data.class]
        for t = 1, 3 do
            local nm = names and DCL(names[t]) or (DCL("Tree") .. " " .. t)
            treeHeads[t]:SetText(nm .. "  |cffffffff" .. (data.points[t] or 0) .. "|r")
        end
        for _, b in ipairs(talentButtons) do b:Hide() end
        for i, tl in ipairs(data.talents) do
            local b = TalentButton(i)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", tp, "TOPLEFT", 8 + tl.tab * (TREE_W + 4) + 6 + tl.col * CELL, -30 - tl.row * CELL)
            local _, _, tex = GetSpellInfo(tl.spell)
            b.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
            b.icon:SetDesaturated(tl.rank == 0)
            b.icon:SetAlpha(tl.rank == 0 and 0.45 or 1)
            local color = tl.rank == 0 and "|cff808080" or (tl.rank >= tl.max and "|cffffd100" or "|cff40ff40")
            b.rank:SetText(color .. tl.rank .. "/" .. tl.max .. "|r")
            b.spell, b.r, b.max = tl.spell, tl.rank, tl.max
            b:Show()
        end
    end

    ------------------------------------------------------------ glyphs & AI page
    local ap = pages[4]
    local glyphHead = ap:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    glyphHead:SetPoint("TOPLEFT", ap, "TOPLEFT", 10, -10)
    DCBind(glyphHead, "Glyphs")
    glyphHead:SetTextColor(0.24, 0.60, 1.0)
    local glyphRows = {}
    for i = 1, 6 do
        local b = CreateFrame("Button", nil, ap)
        b:SetSize(410, 20)
        b:SetPoint("TOPLEFT", ap, "TOPLEFT", 10, -28 - (i - 1) * 22)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetSize(18, 18)
        b.icon:SetPoint("LEFT", b, "LEFT", 0, 0)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
        b:SetScript("OnEnter", function(self)
            if not self.spell then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("spell:" .. self.spell)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        glyphRows[i] = b
    end
    local aiText = ap:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    aiText:SetPoint("TOPLEFT", ap, "TOPLEFT", 10, -28 - 6 * 22 - 8)
    aiText:SetWidth(W - 44)
    aiText:SetJustifyH("LEFT")
    aiText:SetJustifyV("TOP")
    aiText:SetSpacing(3)
    local function RenderGlyphs()
        for i, b in ipairs(glyphRows) do
            local id = data.glyphs[i]
            b.spell = id
            if id then
                local name, _, tex = GetSpellInfo(id)
                b.icon:SetTexture(tex or "Interface\\Icons\\INV_Glyph_MajorWarrior")
                b.text:SetText(name or ("#" .. id))
                b:Show()
            else
                b:Hide()
            end
        end
        if #data.glyphs == 0 then
            glyphRows[1].spell = nil
            glyphRows[1].icon:SetTexture(nil)
            glyphRows[1].text:SetText("|cff999999" .. DCL("no glyphs") .. "|r")
            glyphRows[1]:Show()
        end
        aiText:SetText("|cff3da6ff" .. DCL("Combat strategies") .. "|r\n" .. (data.aiCo ~= "" and data.aiCo or "-") ..
            "\n\n|cff3da6ff" .. DCL("Non-combat strategies") .. "|r\n" .. (data.aiNc ~= "" and data.aiNc or "-"))
    end

    --------------------------------------------------------------------- render
    Render = function()
        for i, p in ipairs(pages) do
            if i == current then p:Show(); tabs[i]:LockHighlight() else p:Hide(); tabs[i]:UnlockHighlight() end
        end
        if not data then return end
        local token = CLASS_TOKENS[data.class]
        local tc = token and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[token]
        if tc then
            portrait:SetTexCoord(unpack(tc)); bigIcon:SetTexCoord(unpack(tc))
            portrait:Show(); bigIcon:Show()
        else
            portrait:Hide(); bigIcon:Hide()
        end
        local cc = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
        nameText:SetText(data.name)
        if cc then nameText:SetTextColor(cc.r, cc.g, cc.b) else nameText:SetTextColor(0.8, 0.8, 0.8) end
        local race = RACE_NAMES[data.race] and DCL(RACE_NAMES[data.race]) or (DCL("Race") .. " " .. data.race)
        local class = CLASS_NAMES[data.class] and DCL(CLASS_NAMES[data.class]) or (DCL("Class") .. " " .. data.class)
        idText:SetText(string.format("%s %d  %s  %s%s", DCL("Lv"), data.level, race, class,
            data.alive and "" or ("  |cffff3333" .. DCL("dead") .. "|r")))
        local trees = TREES[data.class]
        local best, bestPts = 1, -1
        for t = 1, 3 do if (data.points[t] or 0) > bestPts then best, bestPts = t, data.points[t] or 0 end end
        local specName = trees and DCL(trees[best]) or (DCL("Tree") .. " " .. best)
        specText:SetText(string.format("%s %d   %s %s (%d/%d/%d)%s", DCL("iLvl"), data.ilvl, DCL("Talents"), specName,
            data.points[1] or 0, data.points[2] or 0, data.points[3] or 0,
            data.free > 0 and ("  |cffff3333" .. DCL("unspent") .. " " .. data.free .. "|r") or ""))
        if current == 1 then RenderGear()
        elseif current == 2 then RenderStats()
        elseif current == 3 then RenderTalents()
        else RenderGlyphs() end
    end

    local repaintAt
    f:SetScript("OnUpdate", function()
        if repaintAt and GetTime() >= repaintAt then repaintAt = nil; Render() end
    end)

    local function Prefetch(id, kind)
        if kind == "item" and GetItemInfo(id) == nil then
            GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
            GameTooltip:SetHyperlink("item:" .. id)
            GameTooltip:Hide()
        end
    end

    function DCTestInspectOnAddon(parts)
        local kind = parts[1]
        if kind == "TIN_START" then
            pending = { name = parts[2], class = tonumber(parts[3]) or 0, race = tonumber(parts[4]) or 0,
                gender = tonumber(parts[5]) or 0, level = tonumber(parts[6]) or 0, ilvl = tonumber(parts[7]) or 0,
                specTab = tonumber(parts[8]) or 0, maxHp = tonumber(parts[9]) or 0, maxMana = tonumber(parts[10]) or 0,
                free = tonumber(parts[11]) or 0, alive = parts[12] == "1",
                items = {}, talents = {}, points = { 0, 0, 0 }, glyphs = {}, aiCo = "", aiNc = "" }
        elseif not pending then
            if kind == "TIN_ERR" and DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff3333[DC] " .. DCL("That bot is no longer online:") .. " " .. (parts[2] or "") .. "|r")
            end
            return
        elseif kind == "TIS" then
            pending.stats = { unpack(parts, 2) }
        elseif kind == "TIS2" then
            pending.stats2 = { unpack(parts, 2) }
        elseif kind == "TII" then
            local it = { id = tonumber(parts[3]) or 0, ilvl = tonumber(parts[4]) or 0, q = tonumber(parts[5]) or 1,
                ench = tonumber(parts[6]) or 0, g1 = tonumber(parts[7]) or 0, g2 = tonumber(parts[8]) or 0,
                g3 = tonumber(parts[9]) or 0, rand = tonumber(parts[10]) or 0, suffix = tonumber(parts[11]) or 0,
                sockets = tonumber(parts[12]) or 0 }
            pending.items[tonumber(parts[2]) or -1] = it
            Prefetch(it.id, "item")
        elseif kind == "TIT" then
            pending.talents[#pending.talents + 1] = { tab = tonumber(parts[2]) or 0, row = tonumber(parts[3]) or 0,
                col = tonumber(parts[4]) or 0, rank = tonumber(parts[5]) or 0, max = tonumber(parts[6]) or 1,
                spell = tonumber(parts[7]) or 0 }
        elseif kind == "TIP" then
            pending.points = { tonumber(parts[2]) or 0, tonumber(parts[3]) or 0, tonumber(parts[4]) or 0 }
        elseif kind == "TIG" then
            for id in (parts[2] or ""):gmatch("(%d+)") do pending.glyphs[#pending.glyphs + 1] = tonumber(id) end
        elseif kind == "TIA" then
            if parts[2] == "co" then pending.aiCo = parts[3] or "" else pending.aiNc = parts[3] or "" end
        elseif kind == "TIN_END" then
            data, pending = pending, nil
            f:Show()
            Render()
            repaintAt = GetTime() + 1.5  -- once the item cache has answered
        end
    end

    -- Opened from the test-run list.
    function DCTestInspect(name)
        SendDcCommand("testinspect", name, true)
    end

    f:SetScript("OnShow", function() Render() end)
    DCLoc.OnChange(function() if f:IsShown() then Render() end end)
end)()

-- RebornWOW DCRST1A: one-click dungeon reset, on the boss-list caption row.
-- Server side (`instreset`) moves everyone out, rebuilds an LFG group as a
-- normal one with the same bots, then resets. Wrapped in a function so it adds
-- no main-chunk locals (this file sits near Lua 5.1's 200-local limit).
;(function()
    StaticPopupDialogs["DUNGEONCLEAR_INSTRESET"] = {
        text = DCL("Reset dungeon?") .. "\n\n" .. DCL("Everyone is moved out of the dungeon. A dungeon-finder group is rebuilt as a normal group with the same bots. Then the normal-difficulty dungeons are reset."),
        button1 = YES, button2 = NO,
        OnAccept = function() SendDcCommand("instreset") end,
        timeout = 0, whileDead = 1, hideOnEscape = 1, preferredIndex = 3,
    }
    local btn = CreateFrame("Button", "DungeonClearInstResetButton", frame, "UIPanelButtonTemplate")
    btn:SetSize(96, 20)
    btn:SetPoint("LEFT", listLabel, "LEFT", 206, 0)
    DCBind(btn, "Reset dungeon")
    btn:SetScript("OnClick", function()
        -- Rebuild the dialog text in the current language before showing it.
        StaticPopupDialogs["DUNGEONCLEAR_INSTRESET"].text = DCL("Reset dungeon?") .. "\n\n" .. DCL("Everyone is moved out of the dungeon. A dungeon-finder group is rebuilt as a normal group with the same bots. Then the normal-difficulty dungeons are reset.")
        StaticPopup_Show("DUNGEONCLEAR_INSTRESET")
    end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(DCL("Reset dungeon"), 1, 1, 1)
        GameTooltip:AddLine(DCL("Leader only, normal difficulty, nobody in combat or dead, clear stopped."), 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame.dcInstResetBtn = btn
end)()

-- RebornWOW DCQ1A: continuous clear. Tick dungeons in a list; the server
-- teleports the party into each in turn, runs the clear, resets it and moves on
-- (wipe: revive and retry, the second failure skips; low bag space or
-- durability pauses). Server side is the `queue` subcommand. Wrapped in a
-- function so it adds no main-chunk locals.
;(function()
    local rows, listing = {}, nil
    local state = { stage = "idle" }

    local function Sel()
        DungeonClearDB.queueSel = DungeonClearDB.queueSel or {}
        return DungeonClearDB.queueSel
    end

    local f = CreateFrame("Frame", "DungeonClearQueueFrame", UIParent)
    f:SetSize(300, 430)
    f:SetPoint("CENTER", UIParent, "CENTER", 260, 0)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.03, 0.03, 0.05, 0.92)
    f:SetBackdropBorderColor(0.20, 0.22, 0.28, 1.0)
    f:Hide()
    tinsert(UISpecialFrames, "DungeonClearQueueFrame")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -12)
    title:SetTextColor(0.24, 0.60, 1.0)
    DCBind(title, "Continuous clear")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -36)
    hint:SetWidth(272)
    hint:SetJustifyH("LEFT")
    DCBind(hint, "Tick dungeons, then Start. Party leader only; turn off Wait at boss for unattended runs.")

    local scroll = CreateFrame("ScrollFrame", "DungeonClearQueueScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -64)
    scroll:SetSize(254, 250)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(254, 10)
    scroll:SetScrollChild(content)

    local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("TOPLEFT", scroll, "BOTTOMLEFT", 4, -8)
    status:SetWidth(276)
    status:SetJustifyH("LEFT")

    local checks = {}
    local function CountSelected()
        local n, sel = 0, Sel()
        for _, r in ipairs(rows) do if sel[r.token] then n = n + 1 end end
        return n
    end

    local STAGES = {
        idle = "Not running", prepare = "Checking bags and gear", arrive = "Teleporting",
        start = "Starting the clear", run = "Clearing", reset = "Resetting", paused = "Paused", done = "All done",
    }
    local Render  -- forward

    local function RenderList()
        local sel = Sel()
        for i, r in ipairs(rows) do
            local cb = checks[i]
            if not cb then
                cb = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
                cb:SetSize(22, 22)
                cb:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * 22)
                cb.text = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                cb.text:SetPoint("LEFT", cb, "RIGHT", 2, 1)
                cb.text:SetWidth(222)
                cb.text:SetJustifyH("LEFT")
                cb:SetScript("OnClick", function(self)
                    Sel()[self.token] = self:GetChecked() and true or nil
                    Render()
                end)
                checks[i] = cb
            end
            cb.token = r.token
            local lv = r.heroic > 0 and string.format("%d / H%d", r.level, r.heroic) or tostring(r.level)
            local mark = (state.stage ~= "idle" and state.token == r.token) and "|cff33ff33> |r" or ""
            cb.text:SetText(mark .. (DCLDungeon and DCLDungeon(r.name) or r.name) .. "  |cff999999(" .. DCL("Lv") .. " " .. lv .. ")|r")
            cb:SetChecked(sel[r.token] and true or false)
            cb:Show()
        end
        for i = #rows + 1, #checks do checks[i]:Hide() end
        content:SetHeight(math.max(10, #rows * 22))
    end

    local startBtn, stopBtn, resumeBtn
    Render = function()
        RenderList()
        local s = state.stage or "idle"
        local line = DCL(STAGES[s] or s)
        if s ~= "idle" and s ~= "done" and (tonumber(state.total) or 0) > 0 then
            line = line .. "  " .. string.format(DCL("%d of %d"), tonumber(state.index) or 0, tonumber(state.total) or 0)
            if (tonumber(state.fails) or 0) > 0 then
                line = line .. "  " .. string.format(DCL("failed %d"), tonumber(state.fails))
            end
        end
        if state.note and state.note ~= "" then line = line .. "\n|cffcccccc" .. state.note .. "|r" end
        if s == "idle" or s == "done" then
            line = line .. "\n" .. string.format(DCL("%d dungeon(s) ticked"), CountSelected())
        end
        status:SetText(line)
        local running = (s ~= "idle" and s ~= "done")
        if running then startBtn:Disable() else startBtn:Enable() end
        if running then stopBtn:Enable() else stopBtn:Disable() end
        if s == "paused" then resumeBtn:Enable() else resumeBtn:Disable() end
    end

    local function Button(label, w, x, onClick)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(w, 22)
        b:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", x, 12)
        DCBind(b, label)
        b:SetScript("OnClick", onClick)
        return b
    end

    local function Start()
        local tokens = {}
        local sel = Sel()
        for _, r in ipairs(rows) do if sel[r.token] then tokens[#tokens + 1] = r.token end end
        if #tokens == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff3333[DC] " .. DCL("Tick at least one dungeon.") .. "|r")
            return
        end
        -- Addon messages are capped at 255 bytes: send the list in chunks, the
        -- last one with "start".
        local chunk = ""
        for i, t in ipairs(tokens) do
            local nextChunk = (chunk == "") and t or (chunk .. "," .. t)
            if #nextChunk > 180 then
                SendDcCommand("queue", "add\t" .. chunk)
                chunk = t
            else
                chunk = nextChunk
            end
        end
        SendDcCommand("queue", "start\t" .. chunk)
    end

    startBtn = Button("Start", 66, 12, Start)
    stopBtn = Button("Stop", 66, 82, function() SendDcCommand("queue", "stop") end)
    resumeBtn = Button("Resume", 66, 152, function() SendDcCommand("queue", "resume") end)
    Button("Refresh", 66, 222, function() listing = {}; SendDcCommand("queue", "list") end)

    local allBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    allBtn:SetSize(56, 18)
    allBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 38)
    DCBind(allBtn, "Clear")
    allBtn:SetScript("OnClick", function() wipe(Sel()); Render() end)
    local fitBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    fitBtn:SetSize(120, 18)
    fitBtn:SetPoint("LEFT", allBtn, "RIGHT", 4, 0)
    DCBind(fitBtn, "Tick my level")
    fitBtn:SetScript("OnClick", function()
        -- Normal-difficulty dungeons recommended within 5 levels below the player.
        local me, sel = UnitLevel("player") or 80, Sel()
        for _, r in ipairs(rows) do
            if r.level <= me and r.level >= me - 5 then sel[r.token] = true end
        end
        Render()
    end)

    f:SetScript("OnShow", function()
        listing = {}
        SendDcCommand("queue", "list")
        Render()
    end)
    DCLoc.OnChange(function() if f:IsShown() then Render() end end)

    -- QROW / QLISTEND / QSTATE from the server.
    function DCQueueOnAddon(parts)
        local kind = parts[1]
        if kind == "QROW" then
            listing = listing or {}
            listing[#listing + 1] = { token = parts[2], level = tonumber(parts[3]) or 0,
                                      heroic = tonumber(parts[4]) or 0, name = parts[5] or parts[2] }
        elseif kind == "QLISTEND" then
            if listing then
                table.sort(listing, function(a, b)
                    if a.level ~= b.level then return a.level < b.level end
                    return a.name < b.name
                end)
                rows = listing
            end
            listing = nil
            if f:IsShown() then Render() end
        elseif kind == "QSTATE" then
            state = { stage = parts[2], index = parts[3], total = parts[4], token = parts[5],
                      fails = parts[6], note = parts[7] }
            if f:IsShown() then Render() end
        end
    end

    local btn = CreateFrame("Button", "DungeonClearQueueButton", frame, "UIPanelButtonTemplate")
    btn:SetSize(64, 20)
    btn:SetPoint("LEFT", listLabel, "LEFT", 140, 0)
    DCBind(btn, "Queue")
    btn:SetScript("OnClick", function() if f:IsShown() then f:Hide() else f:Show() end end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(DCL("Continuous clear"), 1, 1, 1)
        GameTooltip:AddLine(DCL("Run several dungeons in a row: teleport in, clear, reset, next."), 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame.dcQueueBtn = btn
end)()

local toggleBossesBtn = CreateFrame("Button", "DungeonClearToggleBossesButton", frame)
toggleBossesBtn:SetSize(24, 24)
toggleBossesBtn:SetPoint("LEFT", listLabel, "RIGHT", 6, 0)
toggleBossesBtn:SetNormalFontObject("GameFontNormal")
toggleBossesBtn:SetHighlightFontObject("GameFontHighlight")
toggleBossesBtn:SetText("[-]")
local btnText = toggleBossesBtn:GetFontString()
if btnText then
    btnText:SetTextColor(0.24, 0.60, 1.0)
end

-- Keep the window's top-left corner fixed across height changes. The frame is
-- anchored by CENTER out of the box (and StopMovingOrSizing can leave any anchor
-- behind), so every height change -- a Warning row appearing mid-run, folding the
-- boss list, switching to tiny -- moved the whole window by half the delta and
-- dropped the header somewhere new. Re-pinning to the current top-left first
-- makes the window grow and shrink downward only.
local function PinTopLeft()
    -- Re-anchoring mid-drag breaks StartMoving's grip on the frame, and STATUS
    -- packets (which land continuously during a run) can fire this at any time.
    if frame.isMoving then return end
    local left, top = frame:GetLeft(), frame:GetTop()
    if not left or not top then return end  -- no valid rect yet (load time)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    -- Persist in the same form, so a reload restores the window exactly where it
    -- sits now instead of re-centring it on whatever height it had.
    DungeonClearDB.point = "TOPLEFT"
    DungeonClearDB.relativePoint = "BOTTOMLEFT"
    DungeonClearDB.xOfs = left
    DungeonClearDB.yOfs = top
end

-- Height changes go through here so the pin happens exactly once per real
-- change, not on every status refresh that recomputes the same number.
local function SetFrameHeight(h)
    if math.abs(frame:GetHeight() - h) < 0.5 then return end
    PinTopLeft()
    frame:SetHeight(h)
end

-- The stack hanging off the action row's bottom, read from the anchors that
-- actually place it rather than baked into the height constants:
--   108  onBtn bottom -> boss-list caption top (pull, spectate, auto-play rows)
--   +    the caption's own height
--   4    caption -> list container, then the 205px container itself
local LIST_GAP, LIST_PAD, LIST_H, TOGGLE_H = 108, 4, 205, 24

local function BelowActionRow()
    local gap = DCShellTargetHeight and 100 or LIST_GAP  -- RebornWOW DCUI3D2: the panel's card layout
    local capH = listLabel:GetHeight()
    if not capH or capH < 1 then capH = 14 end  -- not laid out yet (load time)
    if DungeonClearDB.bossesFolded then
        -- Caption row only. The [+]/[-] button is taller than the caption and
        -- vertically centred on it, so IT sets the lower edge, not the text.
        return gap + math.max(capH, capH / 2 + TOGGLE_H / 2)
    end
    return gap + capH + LIST_PAD + LIST_H
end

-- RebornWOW DCUI3B5: in the five-column panel the boss list reaches the panel bottom
-- (DCShellTargetHeight, set by the shell) and shows as many rows as fit.
local LIST_H_BASE = LIST_H
local function SetBossListHeight(h)
    LIST_H = h
    scrollContainer:SetHeight(h)
    local rows = math.max(4, math.min(BOSS_ROWS_MAX, math.floor((h - 16) / ROW_HEIGHT)))
    if rows ~= VISIBLE_ROWS then
        VISIBLE_ROWS = rows
        for i = rows + 1, BOSS_ROWS_MAX do bossRows[i]:Hide() end
        if RedrawBossList then RedrawBossList() end
    end
end

UpdateFrameHeight = function()
    if DungeonClearDB.tinyMode then
        SetFrameHeight(28)
        UpdateTinyWidth()
    else
        frame:SetWidth(330)
        -- Summed from the real stack instead of the four hardcoded figures this
        -- replaces, which had gone stale: 540 left a 31px dead strip below the
        -- boss list, and the warning variants only added the flat 20px the
        -- status box used to grow by, which a three-line warning overran.
        --   35  window top -> status box
        --   +   the box's live height, already grown by however many lines the
        --       Warning actually wrapped to (ApplyStatusHeight measured it)
        --   8   gap, then the 24px action row
        --   +   the stack below it (BelowActionRow)
        --   12  bottom padding
        -- RebornWOW DCUI3D1: in the panel the status box starts at the top (no title row)
        local function Natural()  -- DCUI3D2: card title above the status box, spectate footer below
            return (DCShellTargetHeight and 24 or 35) + statusFrame:GetHeight() + 8 + 24 + BelowActionRow() + 12
                   + (DCShellTargetHeight and 32 or 0)
        end
        -- RebornWOW DCUI3B5: the five-column panel stretches the boss list to its bottom
        local want = (DCShellTargetHeight and not DungeonClearDB.bossesFolded) and DCShellTargetHeight or nil
        local listH = want and math.max(LIST_H_BASE, LIST_H + want - Natural()) or LIST_H_BASE
        if math.abs(listH - LIST_H) >= 1 then SetBossListHeight(listH) end
        SetFrameHeight(Natural())
    end
end

UpdateLayout = function()
    if DungeonClearDB.tinyMode then
        -- Single-line readout only: no header, no close/tiny buttons, no panels
        header:Hide()
        closeBtn:Hide()
        tinyBtn:Hide()
        langBtn:Hide()
        testBtn:Hide()
        onBtn:Hide()
        offBtn:Hide()
        skipBtn:Hide()
        if pauseBtn then pauseBtn:Hide() end
        if pullLabel then pullLabel:Hide() end
        for i = 0, 2 do if pullSegs[i] then pullSegs[i]:Hide() end end
        if spectateBtn then spectateBtn:Hide() end
        if spectatePrevBtn then spectatePrevBtn:Hide() end
        if spectateNextBtn then spectateNextBtn:Hide() end
        if spectateResetBtn then spectateResetBtn:Hide() end
        if selfBotUI then selfBotUI.show(false) end
        listLabel:Hide()
        toggleBossesBtn:Hide()
        if frame.dcInstResetBtn then frame.dcInstResetBtn:Hide() end
        if frame.dcQueueBtn then frame.dcQueueBtn:Hide() end
        scrollContainer:Hide()
        statusFrame:Hide()

        tinyIndicator:Show()
        tinyText:Show()
        if tinyToggle then tinyToggle:Show() end
        if tinyPullDot then tinyPullDot:Show() end
        if tinyPullText then tinyPullText:Show() end
        if tinyPullToggle then tinyPullToggle:Show() end
    else
        tinyIndicator:Hide()
        tinyText:Hide()
        if tinyToggle then tinyToggle:Hide() end
        if tinyPullDot then tinyPullDot:Hide() end
        if tinyPullText then tinyPullText:Hide() end
        if tinyPullToggle then tinyPullToggle:Hide() end

        header:Show()
        closeBtn:Show()
        tinyBtn:Show()
        langBtn:Show()
        testBtn:Show()
        tinyBtn:SetText(DCL("Tiny"))
        onBtn:Show()
        offBtn:Show()
        skipBtn:Show()
        if pauseBtn then pauseBtn:Show() end
        if pullLabel then pullLabel:Show() end
        for i = 0, 2 do if pullSegs[i] then pullSegs[i]:Show() end end
        if spectateBtn then spectateBtn:Show() end
        if spectatePrevBtn then spectatePrevBtn:Show() end
        if spectateNextBtn then spectateNextBtn:Show() end
        if spectateResetBtn then spectateResetBtn:Show() end
        if selfBotUI then selfBotUI.show(true) end
        listLabel:Show()
        toggleBossesBtn:Show()
        if frame.dcInstResetBtn then frame.dcInstResetBtn:Show() end
        if frame.dcQueueBtn then frame.dcQueueBtn:Show() end
        statusFrame:Show()

        statusFrame:ClearAllPoints()
        statusFrame:SetPoint("TOP", frame, "TOP", 0, -35)

        if DungeonClearDB.bossesFolded then
            toggleBossesBtn:SetText("[+]")
            scrollContainer:Hide()

        else
            toggleBossesBtn:SetText("[-]")
            scrollContainer:Show()

        end
    end
    if UpdatePullControls then UpdatePullControls() end
    UpdateFrameHeight()
    if DCShellLayout then DCShellLayout() end  -- RebornWOW DCUI3A/3B: the five-column shell
end

tinyBtn:SetScript("OnClick", function()
    DungeonClearDB.tinyMode = not DungeonClearDB.tinyMode
    UpdateLayout()
end)

toggleBossesBtn:SetScript("OnClick", function()
    DungeonClearDB.bossesFolded = not DungeonClearDB.bossesFolded
    UpdateLayout()
end)

-- RebornWOW DCUI3A/3B: the FIVE-column panel (design doc §15). The existing window is
-- the CENTRE column and keeps every control and every rule it has (dynamic height, the
-- top-left pin, tiny mode). A shell is hung around it, left to right:
--   1 every dungeon and raid (server "dungeons"), with dungeon-clear support and the
--     last test result; right-click for the GM teleport / test
--   2 dungeon runs (DCRUN1A fills it)
--   3 the existing window
--   4 my party, live
--   5 a roster to invite from: my account / online bots / npcbots / real players /
--     favourites / search (server "roster")
-- The shell is a child of the window, so dragging, closing and hiding follow for free;
-- the whole thing scales together (DungeonClearDB.panelScale5, 0.6-1.6, default 1.0).
-- Tiny mode drops back to the old single bar. A do-block keeps its locals out of the
-- main chunk's 200-local budget.
do
    -- RebornWOW DCUI3D1: three columns -- left (dungeons / runs share it), centre, right
    -- (party over invite); a 40 px top bar above them
    -- RebornWOW DCUI3F2: 393 / 433 so Clear mode is as wide as Test mode (1192) -- no size jump
    local W1, W2, WC, W4, W5 = 393, 393, 330, 433, 433
    local GAP, PAD = 8, 10
    local SHELL_W = W1 + WC + W4 + GAP * 2 + PAD * 2                -- 1192 (DCUI3F2; was 1006)
    local SHELL_H = 700                                             -- DCUI3D1: top bar + columns
    local CENTRE_X = PAD + W1 + GAP                                 -- the window's left edge in the shell
    local SCALE_MIN, SCALE_MAX, SCALE_STEP, SCALE_DEFAULT = 0.6, 1.6, 0.1, 1.0
    -- Default: as large as fits 95% of the screen width (1452 wide does not fit 1080p at
    -- 1.0); once +/- is used, the player's own value.
    local function Scale()
        if DungeonClearDB.panelScale5 then return DungeonClearDB.panelScale5 end
        local w = UIParent and tonumber(UIParent:GetWidth())
        if not w or w <= 0 then return SCALE_DEFAULT end
        return math.max(SCALE_MIN, math.min(SCALE_DEFAULT, math.floor(w * 0.95 / SHELL_W * 20) / 20))
    end
    local function Shown(w, on) if on then w:Show() else w:Hide() end end  -- no SetShown on this client

    -- ------------------------------------------------------------ class icons
    -- Stock classes from the stock sheet; the Reborn custom classes from their own art
    -- (the Witch Doctor's round portrait, the Monk compat sheet). Never a question mark
    -- for a class we know.
    local CLASS_BY_ID = { [1] = "WARRIOR", [2] = "PALADIN", [3] = "HUNTER", [4] = "ROGUE", [5] = "PRIEST",
                          [6] = "DEATHKNIGHT", [7] = "SHAMAN", [8] = "MAGE", [9] = "WARLOCK", [11] = "DRUID",
                          [13] = "WITCHDOCTOR", [14] = "MONK" }
    local CUSTOM_ICON = {
        WITCHDOCTOR = { "Interface\\AddOns\\RebornWitchDoctorTalents\\Art\\UI-CHARACTERCREATE-CLASSES-ROUND", 0.75, 0.875, 0.75, 1.0 },
        WITCH_DOCTOR = { "Interface\\AddOns\\RebornWitchDoctorTalents\\Art\\UI-CHARACTERCREATE-CLASSES-ROUND", 0.75, 0.875, 0.75, 1.0 },
        MONK = { "Interface\\Glues\\CharacterCreate\\Reborn-Monk-Classes", 0.125, 0.25, 0, 0.125 },
    }
    local CUSTOM_NAME = { WITCHDOCTOR = "Witch Doctor", WITCH_DOCTOR = "Witch Doctor", MONK = "Monk" }
    local function SetClassIcon(tex, token)
        local c = token and CUSTOM_ICON[token]
        if c then
            tex:SetTexture(c[1]); tex:SetTexCoord(c[2], c[3], c[4], c[5]); return
        end
        local tc = token and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[token]
        if tc then
            tex:SetTexture("Interface\\WorldStateFrame\\Icons-Classes"); tex:SetTexCoord(tc[1], tc[2], tc[3], tc[4]); return
        end
        tex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark"); tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end
    local function ClassHex(token)
        local cc = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
        return cc and string.format("|cff%02x%02x%02x", cc.r * 255, cc.g * 255, cc.b * 255) or "|cffffffff"
    end
    -- RebornWOW DCUI3B4: list text must read over the painted background -- a set size
    -- and a hard black shadow on every list string.
    local function Crisp(fs, size)
        local face = fs:GetFont()
        if face and size then fs:SetFont(face, size) end
        fs:SetShadowColor(0, 0, 0, 1)
        fs:SetShadowOffset(1, -1)
        return fs
    end
    local function ClassName(token)
        if not token then return "" end
        if CUSTOM_NAME[token] then return DCL(CUSTOM_NAME[token]) end
        return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]) or token
    end

    -- ------------------------------------------------------------ shell + background
    local shell = CreateFrame("Frame", "DungeonClearShell", frame)
    shell:SetFrameLevel(math.max(0, frame:GetFrameLevel() - 1))
    shell:EnableMouse(true)  -- clicks on the shell drag the window like its own body
    shell:RegisterForDrag("LeftButton")
    shell:SetScript("OnDragStart", function() if frame:GetScript("OnDragStart") then frame:GetScript("OnDragStart")(frame) end end)
    shell:SetScript("OnDragStop", function() if frame:GetScript("OnDragStop") then frame:GetScript("OnDragStop")(frame) end end)
    shell:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = false, edgeSize = 16,
                        insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    shell:SetBackdropBorderColor(0.42, 0.36, 0.22, 1.0)
    -- Until the painted background arrives (Codex), a dark cold field with a faint
    -- lighter band behind the centre, the way the painting is meant to read.
    local bg = shell:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", 4, -4); bg:SetPoint("BOTTOMRIGHT", -4, 4)
    bg:SetTexture(0.05, 0.07, 0.10, 0.97)
    -- RebornWOW DCUI3B6: one layer each (fill / painting / glow) -- this client does not
    -- honour CreateTexture's sub-level, so two textures on one layer draw in any order.
    local glow = shell:CreateTexture(nil, "ARTWORK")
    glow:SetPoint("TOPLEFT", shell, "TOPLEFT", CENTRE_X - 40, -4)
    glow:SetPoint("BOTTOMLEFT", shell, "BOTTOMLEFT", CENTRE_X - 40, 4)
    glow:SetWidth(WC + 80)
    glow:SetTexture(0.20, 0.30, 0.40, 1)
    glow:SetGradientAlpha("VERTICAL", 0.20, 0.30, 0.40, 0.00, 0.20, 0.30, 0.40, 0.18)
    -- Painted backgrounds (Codex DCUI3BG candidates A/B/C, 2048x1024 BLP2/DXT1, the art in
    -- the top 2048x984). The "Background" button cycles A -> B -> C -> none so the three
    -- can be compared in game. Every login / reload opens on B; the button switches for
    -- this session only, nothing is saved (RebornWOW DCUI3B5).
    -- All three stay; B opens by default (RebornWOW DCUI3B3).
    local BGS = { { "A", "Interface\\AddOns\\DungeonClear\\Art\\DungeonClearBg_A_v1", "A: cold titan hall" },
                  { "B", "Interface\\AddOns\\DungeonClear\\Art\\DungeonClearBg_B_v1", "B: warm dwarven vault" },
                  { "C", "Interface\\AddOns\\DungeonClear\\Art\\DungeonClearBg_C_v1", "C: frost mist ruins" },
                  { "none", nil, "No picture" } }
    local art = shell:CreateTexture(nil, "BORDER")
    art:SetPoint("TOPLEFT", 4, -4); art:SetPoint("BOTTOMRIGHT", -4, 4)
    do  -- DCUI3D1: crop the sides so the 2.08:1 painting is not squeezed into the panel
        local f = math.min(1, (SHELL_W / SHELL_H) / (2048 / 984))
        art:SetTexCoord((1 - f) / 2, (1 + f) / 2, 0, 984 / 1024)
    end
    local columns = {}
    local bgChoice = "B"
    local function BgIndex()
        for i, b in ipairs(BGS) do if b[1] == bgChoice then return i end end
        return 1
    end
    local function PaintBg()
        local b = BGS[BgIndex()]
        if b[2] then art:SetTexture(b[2]); art:Show(); glow:Hide() else art:Hide(); glow:Show() end
        -- over a picture the columns are lighter glass so the painting reads through
        for _, c in ipairs(columns) do c:SetBackdropColor(0.02, 0.03, 0.05, b[2] and 0.50 or 0.60) end
    end

    local function Column(width, titleKey)
        local c = CreateFrame("Frame", nil, shell)
        c:SetWidth(width)
        c:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
                        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                        tile = true, tileSize = 12, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        c:SetBackdropColor(0.02, 0.03, 0.05, 0.55)
        columns[#columns + 1] = c
        c:SetBackdropBorderColor(0.20, 0.22, 0.28, 0.9)
        c.title = c:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        c.title:SetPoint("TOPLEFT", c, "TOPLEFT", 12, -10)
        c.title:SetTextColor(0.24, 0.60, 1.0)
        DCBind(c.title, titleKey)
        c:EnableMouseWheel(true)
        return c
    end
    local function SmallButton(parent, key, w)
        local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetSize(w or 56, 20)
        DCBind(b, key)
        return b
    end
    local function Row(parent, h)
        local r = CreateFrame("Button", nil, parent)
        r:SetHeight(h)
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        r.bgt = r:CreateTexture(nil, "BACKGROUND")
        r.bgt:SetAllPoints()
        r.bgt:SetTexture(0.03, 0.04, 0.06, 0.72)
        return r
    end

    local menuFrame = CreateFrame("Frame", "DungeonClearShellMenu", UIParent, "UIDropDownMenuTemplate")
    local function Chat(cmd) SendChatMessage(cmd, "SAY") end

    -- ============================================================ 1: all dungeons
    local col1 = Column(W1, "All dungeons")
    local dlFilter = "all"                    -- all | supported | unsupported
    local dlRows, dlData, dlOffset = {}, {}, 0
    local DL_ROW_H, DL_ROWS = 22, 26
    local dlFilterBtns = {}
    for i, f in ipairs({ { "all", "All" }, { "supported", "Supported" }, { "unsupported", "Unsupported" } }) do
        local b = SmallButton(col1, f[2], 72)
        b:SetPoint("TOPLEFT", col1, "TOPLEFT", 10 + (i - 1) * 76, -36)
        b:SetScript("OnClick", function() dlFilter = f[1]; dlOffset = 0; if DCShellRenderDungeons then DCShellRenderDungeons() end end)
        dlFilterBtns[f[1]] = b
    end
    local dlRefresh = SmallButton(col1, "Load", 50)
    dlRefresh:SetPoint("TOPRIGHT", col1, "TOPRIGHT", -8, -8)
    for i = 1, DL_ROWS do
        local r = Row(col1, DL_ROW_H)
        r:SetPoint("TOPLEFT", col1, "TOPLEFT", 8, -62 - (i - 1) * DL_ROW_H)
        r:SetPoint("RIGHT", col1, "RIGHT", -8, 0)
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        Crisp(r.text, 14)
        r.text:SetPoint("LEFT", r, "LEFT", 4, 0)
        r.text:SetPoint("RIGHT", r, "RIGHT", -60, 0)
        r.text:SetJustifyH("LEFT")
        r.tag = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        Crisp(r.tag, 13)
        r.tag:SetPoint("RIGHT", r, "RIGHT", -4, 0)
        dlRows[i] = r
    end
    local dlEmpty = col1:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    Crisp(dlEmpty, 13)
    dlEmpty:SetPoint("TOPLEFT", col1, "TOPLEFT", 12, -66)
    dlEmpty:SetPoint("RIGHT", col1, "RIGHT", -12, 0)
    dlEmpty:SetJustifyH("LEFT")

    -- last test result per .dc test token, from the test list's saved history
    local function LastTest(tokens)
        local hist = DungeonClearDB.test and DungeonClearDB.test.history
        if not hist or not tokens then return nil end
        for _, h in ipairs(hist) do  -- newest first
            for t in tokens:gmatch("[^,]+") do
                if h.token == t and h.result and h.result ~= "" then return h.result end
            end
        end
        return nil
    end

    local SIZE_ORDER = { ["5"] = 1, ["10"] = 2, ["10/25"] = 3, ["20"] = 4, ["25"] = 5, ["40"] = 6 }
    local function BuildDisplay()
        local groups, order = {}, {}
        for _, d in ipairs(dlData) do
            local ok = dlFilter == "all" or (dlFilter == "supported") == d.supported
            if ok then
                local key = (d.raid and "R" or "D") .. d.sizes
                if not groups[key] then
                    groups[key] = { raid = d.raid, sizes = d.sizes, list = {} }
                    order[#order + 1] = key
                end
                table.insert(groups[key].list, d)
            end
        end
        table.sort(order, function(a, b)
            local ga, gb = groups[a], groups[b]
            if ga.raid ~= gb.raid then return not ga.raid end
            return (SIZE_ORDER[ga.sizes] or 9) < (SIZE_ORDER[gb.sizes] or 9)
        end)
        local out = {}
        for _, key in ipairs(order) do
            local g = groups[key]
            table.sort(g.list, function(a, b)
                if a.level ~= b.level then return a.level < b.level end
                return a.name < b.name
            end)
            local label = string.format(DCL(g.raid and "%s-player raids" or "%s-player dungeons"), g.sizes)
            out[#out + 1] = { header = true, text = label .. " (" .. #g.list .. ")" }
            for _, d in ipairs(g.list) do out[#out + 1] = d end
        end
        return out
    end

    function DCShellRenderDungeons()
        for k, b in pairs(dlFilterBtns) do if k == dlFilter then b:LockHighlight() else b:UnlockHighlight() end end
        if #dlData == 0 then
            dlEmpty:SetText(DCL("Loading the dungeon list..."))
            for _, r in ipairs(dlRows) do r:Hide() end
            return
        end
        dlEmpty:SetText("")
        local disp = BuildDisplay()
        dlOffset = math.max(0, math.min(dlOffset, #disp - DL_ROWS))
        for i, r in ipairs(dlRows) do
            local d = disp[i + dlOffset]
            r.data = d
            if not d then
                r:Hide()
            elseif d.header then
                r.text:SetText("|cff3da6ff" .. d.text .. "|r"); r.tag:SetText("")
                r.bgt:SetTexture(0.08, 0.13, 0.22, 0.85)
                r:Show()
            else
                local lv = d.level > 0 and (" |cffc8c8c8" .. d.level .. "|r") or ""
                r.text:SetText((d.supported and "|cffffffff" or "|cffb0b0b0") .. d.name .. "|r" .. lv)
                local res = LastTest(d.tokens)
                local tag
                if not d.supported then tag = "|cffa0a0a0" .. DCL("Unsupported") .. "|r"
                elseif res == "success" then tag = "|cff40ff40" .. DCL("Passed") .. "|r"
                elseif res then tag = "|cffff5050" .. DCL("Failed") .. "|r"
                else tag = "|cffffd100" .. DCL("Supported") .. "|r" end
                r.tag:SetText(tag)
                r.bgt:SetTexture(0.03, 0.04, 0.06, 0.72)
                r:Show()
            end
        end
    end
    local function ShowDungeonMenu(d)
        local first = d.tokens and d.tokens:match("^[^,]+")
        local menu = {
            { text = d.name .. "  |cff999999(" .. d.sizes .. ")|r", isTitle = true, notCheckable = true },
            { text = DCL("Teleport to the entrance (GM)"), notCheckable = true, disabled = not d.supported or (d.x == 0 and d.y == 0),
              func = function() Chat(string.format(".go xyz %.1f %.1f %.1f %d", d.x, d.y, d.z, d.mapId)) end },
            -- RebornWOW DCGM2A: you and the whole party
            { text = DCL("Take the whole party to the entrance (GM)"), notCheckable = true,
              disabled = not d.supported or (d.x == 0 and d.y == 0) or not (shell.InGroup and shell.InGroup()),
              func = function() if shell.groupGo then shell.groupGo(d) end end },
            { text = DCL("Start a bot test here (GM)"), notCheckable = true, disabled = not first,
              func = function() Chat(".dc test start " .. first) end },
            { text = CANCEL, notCheckable = true, func = function() CloseDropDownMenus() end },
        }
        EasyMenu(menu, menuFrame, "cursor", 0, 0, "MENU")
    end
    for _, r in ipairs(dlRows) do
        r:SetScript("OnClick", function(self, button)
            local d = self.data
            if d and not d.header and button == "RightButton" then ShowDungeonMenu(d) end
        end)
        r:SetScript("OnEnter", function(self)
            local d = self.data
            if not d or d.header then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(d.name)
            GameTooltip:AddLine(string.format("%s %s   %s %s", DCL("Players:"), d.sizes, DCL("Lv"), d.level > 0 and d.level or "?"), 1, 1, 1)
            if d.supported then
                GameTooltip:AddLine(DCL("Dungeon clear supports this dungeon.") .. (d.rec > 0 and (" " .. DCL("Bot level") .. " " .. d.rec) or ""), 0.4, 1, 0.4, true)
                local res = LastTest(d.tokens)
                if res then GameTooltip:AddLine(DCL("Last test:") .. " " .. res, 1, 0.82, 0) end
            else
                GameTooltip:AddLine(DCL("Dungeon clear does not support this dungeon yet."), 0.6, 0.6, 0.6, true)
            end
            GameTooltip:AddLine(DCL("Right-click: teleport / test (GM)"), 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    col1:SetScript("OnMouseWheel", function(_, delta) dlOffset = dlOffset - delta * 3; DCShellRenderDungeons() end)
    dlRefresh:SetScript("OnClick", function() SendDcCommand("dungeons", "", true) end)

    -- ============================================================ 2: dungeon runs
    local col2 = Column(W2, "Dungeon runs")
    local runsNote = col2:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    Crisp(runsNote, 13)
    runsNote:SetPoint("TOPLEFT", col2.title, "BOTTOMLEFT", 0, -14)
    runsNote:SetPoint("RIGHT", col2, "RIGHT", -12, 0)
    runsNote:SetJustifyH("LEFT")
    DCBind(runsNote, "Every dungeon you clear with your party will be listed here (result, bosses, deaths, time, cheat tier), with right-click to run it again, see its stats or delete it. Coming in the next update.")
    runsNote:SetTextColor(0.82, 0.85, 0.90)

    -- ============================================================ 4: my party
    local col4 = Column(W4, "My party")
    local count = col4:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    count:SetPoint("LEFT", col4.title, "RIGHT", 8, 0)
    count:SetTextColor(0.75, 0.75, 0.75)
    local ROW_H, ROWS = 46, 5
    local prow = {}
    for i = 1, ROWS do
        local r = CreateFrame("Frame", nil, col4)
        r:SetHeight(ROW_H)
        r:SetPoint("TOPLEFT", col4, "TOPLEFT", 10, -40 - (i - 1) * (ROW_H + 6))
        r:SetPoint("RIGHT", col4, "RIGHT", -10, 0)
        r:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                        tile = true, tileSize = 12, edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
        r:SetBackdropBorderColor(0.25, 0.28, 0.35, 0.8)
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(34, 34); r.icon:SetPoint("LEFT", r, "LEFT", 6, 0)
        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal"); Crisp(r.name, 14)
        r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 8, -2); r.name:SetJustifyH("LEFT")
        r.info = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); Crisp(r.info, 12)
        r.info:SetPoint("BOTTOMLEFT", r.icon, "BOTTOMRIGHT", 8, 2); r.info:SetJustifyH("LEFT")
        r.role = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); Crisp(r.role, 13); r.role:SetPoint("RIGHT", r, "RIGHT", -10, 0)
        prow[i] = r
    end
    local function RoleOf(unit)
        -- RebornWOW DCUI3C5: the server's answer (partyroles) first -- a hand-made party
        -- has no LFG roles on the client
        local known = shell.roles and shell.roles[UnitName(unit) or ""]
        if known == "t" then return "Tank" elseif known == "h" then return "Heal" elseif known == "d" then return "DPS" end
        if not UnitGroupRolesAssigned then return nil end
        local ok, a, b, c = pcall(UnitGroupRolesAssigned, unit)
        if not ok then return nil end
        if type(a) == "string" then
            if a == "TANK" then return "Tank" elseif a == "HEALER" then return "Heal" elseif a == "DAMAGER" then return "DPS" end
            return nil
        end
        if a then return "Tank" elseif b then return "Heal" elseif c then return "DPS" end
        return nil
    end
    local function FillParty(r, unit)
        if not unit or not UnitExists(unit) then
            r.icon:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot"); r.icon:SetTexCoord(0, 1, 0, 1)
            r.name:SetText("|cff808080" .. DCL("Empty slot") .. "|r"); r.info:SetText(""); r.role:SetText("")
            r.unit = nil  -- DCUI3C1
            r:SetBackdropColor(0.04, 0.05, 0.07, 0.45)
            return
        end
        r:SetBackdropColor(0.06, 0.08, 0.12, 0.70)
        r.unit = unit  -- DCUI3C1: for the right-click menu
        local locClass, token = UnitClass(unit)
        SetClassIcon(r.icon, token)
        r.name:SetText(ClassHex(token) .. (UnitName(unit) or "?") .. "|r")
        local state = not UnitIsConnected(unit) and ("|cff808080" .. DCL("offline") .. "|r")
            or (UnitIsDeadOrGhost(unit) and ("|cffff3333" .. DCL("dead") .. "|r") or "")
        r.info:SetText(string.format("%s %d  %s  %s", DCL("Lv"), UnitLevel(unit) or 0, locClass or "", state))
        local role = RoleOf(unit)
        r.role:SetText(role and ("|cffffd100" .. DCL(role) .. "|r") or "")
    end
    -- RebornWOW DCUI3B5: a raid gets compact rows for every member (by subgroup,
    -- alternate subgroups shaded, wheel to scroll past RAID_ROWS); a party keeps the
    -- five large rows.
    local RAID_H, RAID_ROWS = 26, 22
    local rrow, raidOffset = {}, 0
    for i = 1, RAID_ROWS do
        local r = CreateFrame("Frame", nil, col4)
        r:SetHeight(RAID_H - 2)
        r:SetPoint("TOPLEFT", col4, "TOPLEFT", 10, -40 - (i - 1) * RAID_H)
        r:SetPoint("RIGHT", col4, "RIGHT", -10, 0)
        r.bgt = r:CreateTexture(nil, "BACKGROUND"); r.bgt:SetAllPoints()
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(20, 20); r.icon:SetPoint("LEFT", r, "LEFT", 3, 0)
        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal"); Crisp(r.name, 13)
        r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0); r.name:SetJustifyH("LEFT")
        r.info = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); Crisp(r.info, 12)
        r.info:SetPoint("RIGHT", r, "RIGHT", -6, 0); r.info:SetJustifyH("RIGHT")
        r:Hide()
        rrow[i] = r
    end
    local function RefreshRaid(n)
        for _, r in ipairs(prow) do r:Hide() end
        local list = {}
        if n == 0 then  -- RebornWOW DCUI3D1: a party uses the same compact rows
            for i, u in ipairs({ "player", "party1", "party2", "party3", "party4" }) do
                if UnitExists(u) then
                    local _, token = UnitClass(u)
                    list[#list + 1] = { unit = u, i = i, name = UnitName(u) or "?", sub = 1, level = UnitLevel(u) or 0,
                                        token = token, online = UnitIsConnected(u), dead = UnitIsDeadOrGhost(u), party = true }
                end
            end
        end
        for i = 1, n do
            local name, _, sub, level, _, token, _, online, dead = GetRaidRosterInfo(i)
            if name then
                list[#list + 1] = { unit = "raid" .. i, i = i, name = name, sub = sub or 0, level = level or 0,
                                    token = token, online = online, dead = dead }
            end
        end
        -- DCUI3C5: you first, then tank -> healer -> DPS, then subgroup
        local me, RANK = UnitName("player"), { Tank = 1, Heal = 2, DPS = 3 }
        for _, d in ipairs(list) do d.rank = (d.name == me) and 0 or (RANK[RoleOf(d.unit) or ""] or 4) end
        table.sort(list, function(a, b)
            if a.rank ~= b.rank then return a.rank < b.rank end
            if a.sub ~= b.sub then return a.sub < b.sub end
            return a.i < b.i
        end)
        local vis = math.min(RAID_ROWS, shell.partyVis or RAID_ROWS)  -- DCUI3D1: rows that fit
        raidOffset = math.max(0, math.min(raidOffset, #list - vis))
        for i, r in ipairs(rrow) do
            local d = list[i + raidOffset]
            if i > vis then d = nil end  -- DCUI3D1
            r.unit = d and d.unit  -- DCUI3C1
            if not d then r:Hide() else
                SetClassIcon(r.icon, d.token)
                r.name:SetText(ClassHex(d.token) .. d.name .. "|r")
                local bits = d.party and { tostring(d.level) } or { "|cff3da6ffG" .. d.sub .. "|r", tostring(d.level) }
                -- DCUI3D9: the role is on the chip at the start of the row
                if not d.online then bits[#bits + 1] = "|cff808080" .. DCL("offline") .. "|r"
                elseif d.dead or UnitIsDeadOrGhost(d.unit) then bits[#bits + 1] = "|cffff3333" .. DCL("dead") .. "|r" end
                r.info:SetText(table.concat(bits, " "))
                if d.sub % 2 == 1 then r.bgt:SetTexture(0.03, 0.04, 0.06, 0.72) else r.bgt:SetTexture(0.07, 0.10, 0.16, 0.80) end
                r:Show()
            end
        end
        local more = #list > vis and ("  |cff999999" .. (raidOffset + 1) .. "-" .. math.min(#list, raidOffset + vis) .. "|r") or ""
        count:SetText((n > 0 and string.format("%s %d", DCL("raid"), #list) or string.format("%d/5", #list)) .. more)
    end
    local function RefreshParty()
        if not col4:IsVisible() then return end
        if shell.c2 and shell.c2.active then return end  -- DCUI3C2: groups page shown
        local n = GetNumRaidMembers() or 0
        -- DCUI3C5: roles from the server -- at once when someone is unknown, else every 15 s
        if n > 0 or (GetNumPartyMembers() or 0) > 0 then
            local missing = false
            for i = 1, (n > 0 and n or 4) do
                local nm = UnitName((n > 0 and "raid" or "party") .. i)
                if nm and not (shell.roles and shell.roles[nm]) then missing = true end
            end
            local wait = missing and 3 or 15
            if GetTime() - (shell.rolesAskedAt or -100) > wait then
                shell.rolesAskedAt = GetTime()
                SendDcCommand("partyroles", "", true)
            end
        end
        RefreshRaid(n)  -- RebornWOW DCUI3D1: party and raid share the compact rows
        do return end
        for _, r in ipairs(rrow) do r:Hide() end
        raidOffset = 0
        local units = { "player" }
        -- DCUI3C5: you first, then tank -> healer -> DPS
        local others, RANK = {}, { Tank = 1, Heal = 2, DPS = 3 }
        for i = 1, 4 do if UnitExists("party" .. i) then others[#others + 1] = "party" .. i end end
        table.sort(others, function(a, b)
            local ra, rb = RANK[RoleOf(a) or ""] or 4, RANK[RoleOf(b) or ""] or 4
            if ra ~= rb then return ra < rb end
            return a < b
        end)
        for _, u in ipairs(others) do units[#units + 1] = u end
        local present = 0
        for i = 1, ROWS do
            local u = units[i]
            if u and not UnitExists(u) then u = nil end
            if u then present = present + 1 end
            prow[i]:Show()
            FillParty(prow[i], u)
        end
        count:SetText(string.format("%d/5", present))
    end
    col4:SetScript("OnMouseWheel", function(_, delta)
        raidOffset = raidOffset - delta * 3; RefreshParty()  -- DCUI3D1: party too (rows that fit)
    end)

    -- ============================================================ 5: roster to invite from
    local col5 = Column(W5, "Invite")
    local CATS = { { "account", "My account" }, { "bots", "Online bots" }, { "npcbots", "NPCBots" },
                   { "players", "Real players" }, { "favorites", "Favorites" }, { "search", "Search" } }
    local rosterCat, rosterRows, rosterData, rosterOffset = "account", {}, {}, 0
    local catBtns = {}
    for i, c in ipairs(CATS) do
        local b = SmallButton(col5, c[2], 84)
        b:SetPoint("TOPLEFT", col5, "TOPLEFT", 10 + ((i - 1) % 3) * 88, -36 - math.floor((i - 1) / 3) * 22)
        catBtns[c[1]] = b
    end
    -- named: an anonymous InputBoxTemplate loses its middle/right art (RebornWOW DCUI3B2)
    local search = CreateFrame("EditBox", "DungeonClearShellSearch", col5, "InputBoxTemplate")
    search:SetSize(W5 - 30, 20)
    search:SetPoint("TOPLEFT", col5, "TOPLEFT", 16, -84)
    search:SetAutoFocus(false)
    local playerFilter = "all"  -- real players: all | friends | guild
    local pfBtns = {}
    for i, f in ipairs({ { "all", "All" }, { "friends", "Friends" }, { "guild", "Guild" } }) do
        local b = SmallButton(col5, f[2], 60)
        b:SetPoint("TOPLEFT", col5, "TOPLEFT", 10 + (i - 1) * 64, -84)
        b:SetScript("OnClick", function() playerFilter = f[1]; if DCShellRenderRoster then DCShellRenderRoster() end end)
        pfBtns[f[1]] = b
    end
    local RS_ROW_H, RS_ROWS = 34, 15
    for i = 1, RS_ROWS do
        local r = Row(col5, RS_ROW_H - 2)
        r:SetPoint("TOPLEFT", col5, "TOPLEFT", 8, -110 - (i - 1) * RS_ROW_H)
        r:SetPoint("RIGHT", col5, "RIGHT", -8, 0)
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(26, 26); r.icon:SetPoint("LEFT", r, "LEFT", 3, 0)
        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); Crisp(r.name, 13)
        r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 6, -1); r.name:SetJustifyH("LEFT")
        r.info = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); Crisp(r.info, 12)
        r.info:SetPoint("BOTTOMLEFT", r.icon, "BOTTOMRIGHT", 6, 1); r.info:SetJustifyH("LEFT")
        r.star = CreateFrame("Button", nil, r)
        r.star:SetSize(16, 16); r.star:SetPoint("RIGHT", r, "RIGHT", -62, 0)
        r.star.tex = r.star:CreateTexture(nil, "ARTWORK"); r.star.tex:SetAllPoints()
        r.star.tex:SetTexture("Interface\\TARGETINGFRAME\\UI-RaidTargetingIcon_1")
        r.act = SmallButton(r, "Invite", 56); r.act:SetPoint("RIGHT", r, "RIGHT", -2, 0)
        rosterRows[i] = r
    end
    local rosterNote = col5:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    Crisp(rosterNote, 13)
    rosterNote:SetPoint("TOPLEFT", col5, "TOPLEFT", 12, -114)
    rosterNote:SetPoint("RIGHT", col5, "RIGHT", -12, 0)
    rosterNote:SetJustifyH("LEFT")

    -- Favourites are shared with MultiBot's star (MultiBotSave.Favorites) when it is loaded.
    local function FavTable()
        if MultiBotSave then
            MultiBotSave.Favorites = MultiBotSave.Favorites or {}
            return MultiBotSave.Favorites
        end
        DungeonClearDB.favorites = DungeonClearDB.favorites or {}
        return DungeonClearDB.favorites
    end
    local function IsFav(name) return FavTable()[name] == true end
    local function ToggleFav(name)
        local t = FavTable()
        t[name] = (not t[name]) or nil
        if MultiBot and MultiBot.UpdateFavoritesIndex then pcall(MultiBot.UpdateFavoritesIndex) end
    end

    local function InGroup(name)
        if UnitName("player") == name then return true end
        for i = 1, 4 do if UnitName("party" .. i) == name then return true end end
        for i = 1, GetNumRaidMembers() do if UnitName("raid" .. i) == name then return true end end
        return false
    end
    local function Invite(d)
        if d.npc then return end
        if d.mine and not d.online then
            Chat(".playerbot bot add " .. d.name)   -- your own offline character: log it in as a bot
        else
            InviteUnit(d.name)
        end
    end

    function DCShellRenderRoster()
        for k, b in pairs(catBtns) do if k == rosterCat then b:LockHighlight() else b:UnlockHighlight() end end
        local isPlayers = rosterCat == "players"
        Shown(search, rosterCat == "search")
        for k, b in pairs(pfBtns) do
            Shown(b, isPlayers)
            if k == playerFilter then b:LockHighlight() else b:UnlockHighlight() end
        end
        local list = {}
        for _, d in ipairs(rosterData) do
            local keep = true
            if isPlayers and playerFilter == "friends" then keep = d.friend
            elseif isPlayers and playerFilter == "guild" then keep = d.guild end
            if keep then list[#list + 1] = d end
        end
        local rvis = math.min(RS_ROWS, shell.rosterVis or RS_ROWS)  -- DCUI3D1
        rosterOffset = math.max(0, math.min(rosterOffset, #list - rvis))
        rosterNote:SetText(rosterData.loading and DCL("Loading...") or (#list == 0 and DCL("Nobody here.") or ""))
        for i, r in ipairs(rosterRows) do
            local d = list[i + rosterOffset]
            if i > rvis then d = nil end  -- DCUI3D1
            r.data = d
            if not d then r:Hide() else
                local token = CLASS_BY_ID[d.cls]
                SetClassIcon(r.icon, token)
                r.name:SetText(ClassHex(token) .. d.name .. "|r")
                local bits = { DCL("Lv") .. " " .. d.level, ClassName(token) }
                if d.npc then bits[#bits + 1] = "|cff3da6ffNPCBot|r"
                elseif not d.online then bits[#bits + 1] = "|cff808080" .. DCL("offline") .. "|r" end
                if d.friend then bits[#bits + 1] = "|cff40ff40" .. DCL("Friend") .. "|r" end
                if d.guild then bits[#bits + 1] = "|cff40c0ff" .. DCL("Guild") .. "|r" end
                r.info:SetText(table.concat(bits, "  "))
                r.star.tex:SetDesaturated(not IsFav(d.name))
                r.star.tex:SetAlpha(IsFav(d.name) and 1 or 0.35)
                local inGroup = InGroup(d.name)
                if d.npc then r.act:Hide()
                else
                    r.act:Show()
                    if inGroup then r.act:Disable() else r.act:Enable() end
                    DCBind(r.act, inGroup and "In party" or (d.mine and not d.online and "Log in" or "Invite"))
                end
                r:Show()
            end
        end
    end
    local function RequestRoster()
        shell.rosterOwner = "panel"  -- DCTEST8A
        rosterData = { loading = true }
        rosterOffset = 0
        if rosterCat == "favorites" then
            local names = {}
            for n in pairs(FavTable()) do names[#names + 1] = n end
            if #names == 0 then rosterData = {}; DCShellRenderRoster(); return end
            local chunk = ""
            for _, n in ipairs(names) do
                if #chunk + #n > 200 then SendDcCommand("botinfo", "|" .. chunk, true); chunk = "" end
                chunk = chunk == "" and n or (chunk .. "," .. n)
            end
            SendDcCommand("botinfo", "|" .. chunk, true)
        else
            SendDcCommand("roster", rosterCat .. "\t" .. (rosterCat == "search" and (search:GetText() or "") or ""), true)
        end
        DCShellRenderRoster()
    end
    for _, c in ipairs(CATS) do
        catBtns[c[1]]:SetScript("OnClick", function() rosterCat = c[1]; RequestRoster() end)
    end
    search:SetScript("OnEnterPressed", function(self) self:ClearFocus(); RequestRoster() end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    for _, r in ipairs(rosterRows) do
        r.act:SetScript("OnClick", function(self) local d = self:GetParent().data; if d then Invite(d) end end)
        r.star:SetScript("OnClick", function(self) local d = self:GetParent().data; if d then ToggleFav(d.name); DCShellRenderRoster() end end)
        r.star:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine(DCL("Add to / remove from favourites")); GameTooltip:Show()
        end)
        r.star:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    col5:SetScript("OnMouseWheel", function(_, delta) rosterOffset = rosterOffset - delta * 3; DCShellRenderRoster() end)

    -- ------------------------------------------------------------ actions (RebornWOW DCUI3C1)
    -- Design doc §16.1/16.2: right-click menus on both lists, and drag a character from
    -- the invite list onto "My party" to invite it. One table holds the helpers (the
    -- main chunk's local budget: it is at 200), in a function of its own; the table hangs
    -- on the shell so the reply handler below can reach it.
    shell.c1 = { myChars = {} }       -- myChars: this account's characters (from "account" rows)
    ;(function()
    local C1 = shell.c1
    C1.IsLeader = function()
        if GetNumRaidMembers() > 0 then return IsRaidLeader() or IsRaidOfficer() end
        return IsPartyLeader()
    end
    C1.Whisper = function(name, text) SendChatMessage(text, "WHISPER", nil, name) end
    C1.Show = function(menu) EasyMenu(menu, menuFrame, "cursor", 0, 0, "MENU") end
    C1.FavItem = function(name)
        return { text = IsFav(name) and DCL("Remove from favourite characters") or DCL("Add to favourite characters"),
                 notCheckable = true, func = function() ToggleFav(name); DCShellRenderRoster() end }
    end
    C1.PartyMenu = function(unit)
        local name = unit and UnitName(unit)
        if not name then return end
        local _, token = UnitClass(unit)
        local menu = { { text = ClassHex(token) .. name .. "|r", isTitle = true, notCheckable = true } }
        local function add(t) t.notCheckable = true; menu[#menu + 1] = t end
        if UnitIsUnit(unit, "player") then
            add({ text = DCL("Leave the group"), func = function() LeaveParty() end })
        else
            local lead = C1.IsLeader()
            add({ text = DCL("Inspect (gear, talents)"), disabled = not CanInspect(unit), func = function() InspectUnit(unit) end })
            add({ text = DCL("Whisper"), func = function() ChatFrame_SendTell(name) end })
            add({ text = DCL("Bot: follow me"), func = function() C1.Whisper(name, "follow") end })
            add({ text = DCL("Bot: stay here"), func = function() C1.Whisper(name, "stay") end })
            add({ text = DCL("Bot: summon to me"), func = function() C1.Whisper(name, "summon") end })
            if C1.myChars[name] then
                add({ text = DCL("Log this character out"), func = function() Chat(".playerbot bot remove " .. name) end })
            end
            add({ text = DCL("Remove from group"), disabled = not lead, func = function() UninviteUnit(name) end })
            add({ text = DCL("Make leader"), disabled = not lead, func = function() PromoteToLeader(unit) end })
            local ri = tonumber(unit:match("^raid(%d+)$") or "")
            if ri and lead then
                local _, _, cur = GetRaidRosterInfo(ri)
                for g = 1, 8 do
                    if g ~= cur then
                        add({ text = string.format(DCL("Move to group %d"), g), func = function() SetRaidSubgroup(ri, g) end })
                    end
                end
            end
        end
        menu[#menu + 1] = C1.FavItem(name)
        if shell.c2 and shell.c2.MenuItems then shell.c2.MenuItems(menu, name, token, UnitLevel(unit)) end  -- DCUI3C2
        add({ text = CANCEL, func = function() CloseDropDownMenus() end })
        C1.Show(menu)
    end
    C1.InviteMenu = function(d)
        local menu = { { text = ClassHex(CLASS_BY_ID[d.cls]) .. d.name .. "|r", isTitle = true, notCheckable = true } }
        local function add(t) t.notCheckable = true; menu[#menu + 1] = t end
        if d.npc then
            add({ text = DCL("NPCBots are managed with the NPCBot commands."), disabled = true })
        else
            add({ text = (d.mine and not d.online) and DCL("Log in and invite") or DCL("Invite"),
                  disabled = InGroup(d.name), func = function() Invite(d) end })
            if d.online then add({ text = DCL("Whisper"), func = function() ChatFrame_SendTell(d.name) end }) end
        end
        menu[#menu + 1] = C1.FavItem(d.name)
        if not d.npc and shell.c2 and shell.c2.MenuItems then shell.c2.MenuItems(menu, d.name, CLASS_BY_ID[d.cls], d.level) end  -- DCUI3C2
        add({ text = CANCEL, func = function() CloseDropDownMenus() end })
        C1.Show(menu)
    end

    -- party rows (both the five large rows and the raid's compact rows)
    for _, list in ipairs({ prow, rrow }) do
        for _, r in ipairs(list) do
            r:EnableMouse(true)
            local hl = r:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(); hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight"); hl:SetBlendMode("ADD")
            r:SetScript("OnMouseUp", function(self, button)
                if button == "RightButton" and self.unit and UnitExists(self.unit) then C1.PartyMenu(self.unit) end
            end)
            r:SetScript("OnEnter", function(self)
                if not (self.unit and UnitExists(self.unit)) then return end
                GameTooltip:SetOwner(self, "ANCHOR_LEFT"); GameTooltip:SetUnit(self.unit)
                GameTooltip:AddLine(DCL("Right-click: more actions"), 0.7, 0.7, 0.7); GameTooltip:Show()
            end)
            r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
    end

    -- drag from the invite list onto "My party"
    local ghost = CreateFrame("Frame", nil, UIParent)
    ghost:SetFrameStrata("TOOLTIP"); ghost:SetSize(36, 36); ghost:Hide()
    ghost.icon = ghost:CreateTexture(nil, "ARTWORK"); ghost.icon:SetAllPoints()
    ghost.text = ghost:CreateFontString(nil, "OVERLAY", "GameFontNormal"); Crisp(ghost.text, 13)
    ghost.text:SetPoint("TOP", ghost, "BOTTOM", 0, -2)
    C1.ghost = ghost  -- DCUI3C3: the raid drag uses it too
    C1.Border = function(on)
        if on then col4:SetBackdropBorderColor(1, 0.82, 0, 1) else col4:SetBackdropBorderColor(0.20, 0.22, 0.28, 0.9) end
    end
    ghost:SetScript("OnUpdate", function(self)
        local x, y = GetCursorPosition()
        local sc = UIParent:GetEffectiveScale()
        self:ClearAllPoints(); self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / sc, y / sc)
        local over = MouseIsOver(col4) and true or false
        if over ~= self.over then self.over = over; C1.Border(over) end
    end)
    for _, r in ipairs(rosterRows) do
        r:RegisterForDrag("LeftButton")
        r:SetScript("OnClick", function(self, button)
            if button == "RightButton" and self.data then C1.InviteMenu(self.data) end
        end)
        r:SetScript("OnEnter", function(self)
            local d = self.data
            if not d then return end
            GameTooltip:SetOwner(self, "ANCHOR_LEFT"); GameTooltip:AddLine(d.name)
            if not d.npc then GameTooltip:AddLine(DCL("Drag onto My party to invite"), 1, 1, 1) end
            GameTooltip:AddLine(DCL("Right-click: more actions"), 0.7, 0.7, 0.7); GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r:SetScript("OnDragStart", function(self)
            local d = self.data
            if not d or d.npc or (InGroup(d.name) and not shell.c2.active) then return end  -- DCUI3C2
            C1.drag = d
            GameTooltip:Hide()
            SetClassIcon(ghost.icon, CLASS_BY_ID[d.cls])
            ghost.text:SetText(ClassHex(CLASS_BY_ID[d.cls]) .. d.name .. "|r")
            ghost.over = nil
            ghost:Show()
        end)
        r:SetScript("OnDragStop", function()
            local d = C1.drag
            C1.drag = nil
            ghost:Hide(); C1.Border(false)
            if d and MouseIsOver(col4) then
                if shell.c2.active then shell.c2.Drop(d) else Invite(d) end  -- DCUI3C2
            end
        end)
    end
    end)()

    -- ------------------------------------------------------------ favourite groups (RebornWOW DCUI3C2)
    -- Design doc §16.3. Column 4 gets two tabs, [Party] [Groups]. Groups are filtered by
    -- size (5/10/20/25/40); click a group to open it and see its members; drag a character
    -- from the invite list onto the column to add it to the open group; "Form" invites the
    -- whole group: your own offline characters are logged in (playerbots puts them in your
    -- group and turns a full party into a raid), online characters are invited. Saved per
    -- account in DungeonClearDB.dcGroups (names, class, level, role). Its own function and
    -- a table on the shell: the main chunk is at its 200-local limit.
    shell.c2 = { active = false, size = 5, offset = 0 }
    ;(function()
    local C2 = shell.c2
    local SIZES = { 5, 10, 20, 25, 40 }
    local function Say(m) DEFAULT_CHAT_FRAME:AddMessage("|cff3da6ff[DC]|r " .. m) end
    -- RebornWOW DCUI3D6: every character keeps its own list (DungeonClearDB.dcGroupsByChar[name]).
    -- The old account-wide list is split once by each group's recorded owner and kept as
    -- dcGroupsOld; a group of another character is reached through "Import".
    local function Groups()
        local db = DungeonClearDB
        db.dcGroupsByChar = db.dcGroupsByChar or {}
        if db.dcGroups then
            for _, g in ipairs(db.dcGroups) do
                local key = g.owner or (g.members and g.members[1] and g.members[1].name) or (UnitName("player") or "?")
                db.dcGroupsByChar[key] = db.dcGroupsByChar[key] or {}
                table.insert(db.dcGroupsByChar[key], g)
            end
            db.dcGroupsOld = db.dcGroups
            db.dcGroups = nil
        end
        local me = UnitName("player") or "?"
        db.dcGroupsByChar[me] = db.dcGroupsByChar[me] or {}
        return db.dcGroupsByChar[me]
    end
    local function SizeFor(n) for _, s in ipairs(SIZES) do if n <= s then return s end end return 40 end
    local function RoleFromUnit(unit)
        local r = RoleOf(unit)
        return (r == "Tank" and "tank") or (r == "Heal" and "heal") or (r == "DPS" and "dps") or nil
    end
    local ROLE_SHOW = { tank = { "Tank", "|cff3da6ff" }, heal = { "Heal", "|cff40ff40" }, dps = { "DPS", "|cffff7f50" } }
    local function Summary(g)
        local t, h, d = 0, 0, 0
        for _, m in ipairs(g.members) do
            if m.role == "tank" then t = t + 1 elseif m.role == "heal" then h = h + 1 elseif m.role == "dps" then d = d + 1 end
        end
        return string.format("%s%d %s%d %s%d", DCL("Tank (short)"), t, DCL("Healer (short)"), h, DCL("DPS (short)"), d)
    end
    local function Find(g, name)
        for i, m in ipairs(g.members) do if m.name == name then return i end end
    end
    -- RebornWOW DCUI3C4: a group belongs to the character that made it. "This character"
    -- (default) shows only those; "All characters" shows the whole account's. Older
    -- groups: the first member is the owner ("Save current party" stores the saver first).
    -- DCUI3D6: the list is this character's own, so everything in it is shown
    local function Owner(g) return UnitName("player") end
    C2.showAll = false
    function C2.Visible(g) return true end
    C2.Groups = Groups

    -- tabs
    local tabGroups = SmallButton(col4, "Groups (tab)", 60)
    tabGroups:SetPoint("TOPRIGHT", col4, "TOPRIGHT", -8, -8)
    local tabParty = SmallButton(col4, "Party (tab)", 48)
    tabParty:SetPoint("RIGHT", tabGroups, "LEFT", -4, 0)

    -- the groups page
    local gp = CreateFrame("Frame", nil, col4)
    gp:SetPoint("TOPLEFT", col4, "TOPLEFT", 8, -36)
    gp:SetPoint("BOTTOMRIGHT", col4, "BOTTOMRIGHT", -8, 8)
    gp:Hide()
    gp:EnableMouseWheel(true)
    local sizeLabel = gp:CreateFontString(nil, "OVERLAY", "GameFontNormal"); Crisp(sizeLabel, 13)
    sizeLabel:SetPoint("TOPLEFT", gp, "TOPLEFT", 2, -4)
    DCBind(sizeLabel, "Size:")
    local sizeBtn = {}
    for i, n in ipairs(SIZES) do
        local b = CreateFrame("Button", nil, gp, "UIPanelButtonTemplate")
        b:SetSize(34, 20); b:SetText(tostring(n))
        b:SetPoint("LEFT", sizeLabel, "RIGHT", 4 + (i - 1) * 36, 0)
        b:SetScript("OnClick", function() C2.size = n; C2.offset = 0; C2.Render() end)
        sizeBtn[n] = b
    end
    local btnSave = SmallButton(gp, "Save current party", 112)
    btnSave:SetPoint("TOPLEFT", gp, "TOPLEFT", 0, -26)
    local btnNew = SmallButton(gp, "New group", 70)
    btnNew:SetPoint("LEFT", btnSave, "RIGHT", 4, 0)
    -- RebornWOW DCUI3D7: "Import" puts the people of another of THIS character's groups (a
    -- 5- or 10-player one, say) into the group of the size on screen -- the open one, or a
    -- new one -- and says how many places are left for the Invite list to fill
    function C2.ImportFrom(src)
        local target = C2.open
        if not (target and target.size == C2.size and target ~= src) then
            target = { name = string.format(DCL("%s (%d)"), src.name, C2.size), size = C2.size, members = {},
                       owner = UnitName("player") }
            table.insert(Groups(), target)
            C2.open = target
        end
        C2.AddMany(target, src.members)
        local left = target.size - #target.members
        if left > 0 then
            Say(string.format(DCL("%s: %d places left -- drag real players or bots in from the Invite list."), target.name, left))
        end
    end
    local btnAll = SmallButton(gp, "Import", 60)
    btnAll:SetPoint("LEFT", btnNew, "RIGHT", 4, 0)
    btnAll:SetScript("OnClick", function()
        local menu = { { text = string.format(DCL("Into the %d-player group, the people of:"), C2.size), isTitle = true, notCheckable = true } }
        local n = 0
        for _, g in ipairs(Groups()) do
            if g ~= C2.open and n < 20 then
                n = n + 1
                menu[#menu + 1] = { text = string.format("%s  |cff999999%d/%d|r", g.name, #g.members, g.size), notCheckable = true,
                                    func = function() C2.ImportFrom(g) end }
            end
        end
        if n == 0 then
            menu[#menu + 1] = { text = DCL("You have no other favourite groups yet."), notCheckable = true, disabled = true }
        end
        menu[#menu + 1] = { text = CANCEL, notCheckable = true, func = function() CloseDropDownMenus() end }
        EasyMenu(menu, menuFrame, "cursor", 0, 0, "MENU")
    end)
    btnAll:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(DCL("Import"))
        GameTooltip:AddLine(DCL("Put the people of another of your favourite groups (a 5- or 10-player one, say) into this size's group; fill the rest from the Invite list."), 1, 1, 1, true)
        GameTooltip:Show()
    end)
    btnAll:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local empty = gp:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); Crisp(empty, 13)
    empty:SetPoint("TOPLEFT", gp, "TOPLEFT", 4, -56); empty:SetPoint("RIGHT", gp, "RIGHT", -4, 0)
    empty:SetJustifyH("LEFT")
    local ROWS, RH = 21, 25
    local rows = {}
    for i = 1, ROWS do
        local r = Row(gp, RH - 2)
        r:SetPoint("TOPLEFT", gp, "TOPLEFT", 0, -52 - (i - 1) * RH)
        r:SetPoint("RIGHT", gp, "RIGHT", 0, 0)
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(16, 16)
        r.info = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); Crisp(r.info, 12)
        r.info:SetJustifyH("RIGHT")
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontNormal"); Crisp(r.text, 13)
        r.text:SetPoint("LEFT", r.icon, "RIGHT", 5, 0); r.text:SetPoint("RIGHT", r.info, "LEFT", -4, 0)
        r.text:SetJustifyH("LEFT")
        r.form = SmallButton(r, "Form", 46); r.form:SetPoint("RIGHT", r, "RIGHT", -2, 0)
        rows[i] = r
    end

    function C2.Render()
        if not C2.active then return end
        -- RebornWOW DCUI3D3: an open group the size / owner filter hides is closed, so a
        -- drop never lands in a group the player cannot see
        if C2.open and not (C2.open.size == C2.size and C2.Visible(C2.open)) then C2.open = nil end
        for _, n in ipairs(SIZES) do if n == C2.size then sizeBtn[n]:LockHighlight() else sizeBtn[n]:UnlockHighlight() end end
        local disp = {}
        for _, g in ipairs(Groups()) do
            if g.size == C2.size and C2.Visible(g) then
                disp[#disp + 1] = { kind = "group", g = g }
                if C2.open == g then
                    for mi, m in ipairs(g.members) do disp[#disp + 1] = { kind = "member", g = g, m = m, mi = mi } end
                    if #g.members < g.size then disp[#disp + 1] = { kind = "hint", g = g } end
                end
            end
        end
        empty:SetText(#disp == 0 and (DCL("No favourite groups of this size yet. Form a party and click 'Save current party', or drag characters from the Invite list in (a new group is made for you).")
                                      .. (C2.showAll and "" or ("\n\n|cff999999" .. DCL("Import puts the people of another of your groups (a 5- or 10-player one, say) into this size.") .. "|r"))) or "")
        local gvis = math.min(ROWS, shell.groupVis or ROWS)  -- DCUI3D1
        C2.offset = math.max(0, math.min(C2.offset, #disp - gvis))
        for i, r in ipairs(rows) do
            local e = disp[i + C2.offset]
            if i > gvis then e = nil end  -- DCUI3D1
            r.e = e
            if not e then r:Hide() else
                r.icon:ClearAllPoints(); r.info:ClearAllPoints()
                if e.kind == "group" then
                    local open = C2.open == e.g
                    r.icon:SetPoint("LEFT", r, "LEFT", 4, 0)
                    r.icon:SetTexture(open and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
                    r.icon:SetTexCoord(0, 1, 0, 1)
                    local owner = Owner(e.g)
                    r.text:SetText("|cffffd100" .. e.g.name .. "|r"
                                   .. (owner ~= UnitName("player") and ("  |cff999999(" .. owner .. ")|r") or ""))
                    r.info:SetPoint("RIGHT", r, "RIGHT", -52, 0)
                    r.info:SetText(string.format("%d/%d  %s", #e.g.members, e.g.size, Summary(e.g)))
                    r.bgt:SetTexture(0.08, 0.13, 0.22, 0.85)
                    r.form:Show()
                elseif e.kind == "member" then
                    r.icon:SetPoint("LEFT", r, "LEFT", 22, 0)
                    SetClassIcon(r.icon, e.m.cls)
                    r.text:SetText(ClassHex(e.m.cls) .. e.m.name .. "|r")
                    r.info:SetPoint("RIGHT", r, "RIGHT", -6, 0)
                    local rs = e.m.role and ROLE_SHOW[e.m.role]
                    r.info:SetText((e.m.level and e.m.level > 0 and (DCL("Lv") .. " " .. e.m.level .. "  ") or "")
                                   .. (rs and (rs[2] .. DCL(rs[1]) .. "|r") or ""))
                    r.bgt:SetTexture(0.03, 0.04, 0.06, 0.72)
                    r.form:Hide()
                else
                    r.icon:SetPoint("LEFT", r, "LEFT", 22, 0)
                    r.icon:SetTexture(nil)
                    r.text:SetText("|cff9a9a9a" .. string.format(DCL("Drag a character here to add it (%d more)"), e.g.size - #e.g.members) .. "|r")
                    r.info:SetPoint("RIGHT", r, "RIGHT", -6, 0); r.info:SetText("")
                    r.bgt:SetTexture(0.03, 0.04, 0.06, 0.45)
                    r.form:Hide()
                end
                r:Show()
            end
        end
    end

    function C2.SetActive(on)
        C2.active = on
        if shell.c3 and shell.c3.bar then if on then shell.c3.bar:Hide() else shell.c3.bar:Show() end end  -- DCUI3C3
        if on then tabGroups:LockHighlight(); tabParty:UnlockHighlight() else tabParty:LockHighlight(); tabGroups:UnlockHighlight() end
        if on then
            for _, r in ipairs(prow) do r:Hide() end
            for _, r in ipairs(rrow) do r:Hide() end
            gp:Show()
            C2.Render()
        else
            gp:Hide()
            RefreshParty()
        end
    end
    tabParty:SetScript("OnClick", function() C2.SetActive(false) end)
    tabGroups:SetScript("OnClick", function() C2.SetActive(true) end)
    tabParty:LockHighlight()
    gp:SetScript("OnMouseWheel", function(_, delta) C2.offset = C2.offset - delta * 3; C2.Render() end)

    -- members
    function C2.AddMember(g, name, cls, level, role)
        if Find(g, name) then Say(string.format(DCL("%s is already in this group."), name)); return end
        if #g.members >= g.size then Say(string.format(DCL("This group is full (%d)."), g.size)); return end
        table.insert(g.members, { name = name, cls = cls, level = level, role = role })
        C2.Render()
    end
    -- RebornWOW DCUI3D5: several at once -- skips names already in the group, stops at its size
    function C2.AddMany(g, list)
        local added, dup, full = 0, 0, 0
        for _, m in ipairs(list) do
            if Find(g, m.name) then dup = dup + 1
            elseif #g.members >= g.size then full = full + 1
            else
                table.insert(g.members, { name = m.name, cls = m.cls, level = m.level, role = m.role })
                added = added + 1
            end
        end
        Say(string.format(DCL("%s: %d added, %d already in it, %d over its size."), g.name, added, dup, full))
        C2.Render()
        return added
    end
    function C2.Drop(d)
        -- RebornWOW DCUI3D3: no shown open group -> a new group of the size on screen
        if C2.open and not (C2.open.size == C2.size and C2.Visible(C2.open)) then C2.open = nil end
        if not C2.open then
            local g = { name = string.format(DCL("Favourite group %d"), #Groups() + 1), size = C2.size, members = {},
                        owner = UnitName("player") }
            table.insert(Groups(), g)
            C2.open = g
            Say(string.format(DCL("New %d-player favourite group %s: drag more characters in; right-click its name to rename it."),
                g.size, g.name))
        end
        C2.AddMember(C2.open, d.name, CLASS_BY_ID[d.cls], d.level)
    end
    local function CurrentMembers()
        local list = {}
        local function add(u)
            if UnitExists(u) then
                local _, tok = UnitClass(u)
                list[#list + 1] = { name = UnitName(u), cls = tok, level = UnitLevel(u), role = RoleFromUnit(u) }
            end
        end
        local n = GetNumRaidMembers()
        if n > 0 then for i = 1, n do add("raid" .. i) end
        else add("player"); for i = 1, 4 do add("party" .. i) end end
        return list
    end
    -- items for the right-click menus of both lists: "add to favourite group ..."
    function C2.MenuItems(menu, name, cls, level)
        if not name then return end
        local list = {}
        for _, g in ipairs(Groups()) do if C2.Visible(g) and #list < 12 then list[#list + 1] = g end end  -- DCUI3C4
        if #list == 0 then return end
        menu[#menu + 1] = { text = DCL("Add to favourite group:"), isTitle = true, notCheckable = true }
        for _, g in ipairs(list) do
            menu[#menu + 1] = { text = string.format("  %s  |cff999999%d/%d|r", g.name, #g.members, g.size), notCheckable = true,
                                disabled = Find(g, name) ~= nil or #g.members >= g.size,
                                func = function() C2.AddMember(g, name, cls, level) end }
        end
    end

    -- names: one popup for new / rename, one for delete
    StaticPopupDialogs["DUNGEONCLEAR_GROUP_NAME"] = {
        text = "%s", button1 = ACCEPT, button2 = CANCEL, hasEditBox = 1, maxLetters = 32,
        OnShow = function(self)
            local eb = _G[self:GetName() .. "EditBox"]
            eb:SetText((C2.pending and C2.pending.default) or ""); eb:HighlightText(); eb:SetFocus()
        end,
        OnAccept = function(self) C2.NameDone(_G[self:GetName() .. "EditBox"]:GetText()) end,
        EditBoxOnEnterPressed = function(self) C2.NameDone(self:GetText()); self:GetParent():Hide() end,
        EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
        timeout = 0, whileDead = 1, hideOnEscape = 1,
    }
    StaticPopupDialogs["DUNGEONCLEAR_GROUP_DELETE"] = {
        text = "%s", button1 = YES, button2 = NO,
        OnAccept = function()
            local g = C2.pendingDel
            C2.pendingDel = nil
            for i, x in ipairs(Groups()) do if x == g then table.remove(Groups(), i); break end end
            if C2.open == g then C2.open = nil end
            C2.Render()
        end,
        timeout = 0, whileDead = 1, hideOnEscape = 1,
    }
    function C2.NameDone(text)
        local p = C2.pending
        C2.pending = nil
        text = text and text:gsub("^%s+", ""):gsub("%s+$", "") or ""
        if not p or text == "" then return end
        if p.mode == "new" then
            local g = { name = text, size = p.size, members = p.members or {}, owner = UnitName("player") }  -- owner: DCUI3C4
            table.insert(Groups(), g)
            C2.size, C2.open = g.size, g
        elseif p.mode == "rename" then
            p.g.name = text
        end
        C2.Render()
    end
    local function AskName(p, prompt)
        C2.pending = p
        StaticPopup_Show("DUNGEONCLEAR_GROUP_NAME", prompt)
    end
    local function DefaultName() return string.format(DCL("Favourite group %d"), #Groups() + 1) end
    btnSave:SetScript("OnClick", function()
        local list = CurrentMembers()
        if #list < 2 then Say(DCL("Form a party first, then save it.")); return end
        local size = SizeFor(#list)
        AskName({ mode = "new", size = size, members = list, default = DefaultName() }, DCL("Name this favourite group:"))
    end)
    btnNew:SetScript("OnClick", function()
        AskName({ mode = "new", size = C2.size, members = {}, default = DefaultName() }, DCL("Name this favourite group:"))
    end)

    -- one click: invite the whole group (botinfo says who is online / yours)
    local qf = CreateFrame("Frame")
    qf:Hide()
    local qacc = 0
    function C2.Form(g)
        local names, me = {}, UnitName("player")
        for _, m in ipairs(g.members) do
            if m.name ~= me and not InGroup(m.name) then names[#names + 1] = m.name end
        end
        if #names == 0 then Say(DCL("Everyone in this group is already with you.")); return end
        local w = { size = g.size, names = {}, got = {}, queue = {}, offline = {}, endAt = GetTime() + 6 }
        for _, n in ipairs(names) do w.names[n] = true end
        C2.want = w
        local chunk = ""
        for _, n in ipairs(names) do
            if #chunk + #n + 1 > 200 then SendDcCommand("botinfo", "|" .. chunk, true); chunk = "" end
            chunk = chunk == "" and n or (chunk .. "," .. n)
        end
        SendDcCommand("botinfo", "|" .. chunk, true)
        Say(string.format(DCL("Forming %s: %d to invite..."), g.name, #names))
        qacc = 0
        qf:Show()
    end
    function C2.OnBI(kind, msg)
        local w = C2.want
        if not w then return end
        if kind == "BI" then
            local _, name, _, _, _, _, online, mine = strsplit("\t", msg)
            if name and w.names[name] and not w.got[name] then
                w.got[name] = true
                if online == "1" then w.queue[#w.queue + 1] = { name = name }
                elseif mine == "1" then w.queue[#w.queue + 1] = { name = name, add = true }
                else w.offline[#w.offline + 1] = name end
            end
        elseif kind == "BI_END" then
            w.endAt = math.min(w.endAt, GetTime() + 1.5)
        end
    end
    qf:SetScript("OnUpdate", function(self, elapsed)
        qacc = qacc + (elapsed or 0)
        if qacc < 0.6 then return end
        qacc = 0
        local w = C2.want
        if not w then self:Hide(); return end
        local item = table.remove(w.queue, 1)
        if item then
            if item.add then
                Chat(".playerbot bot add " .. item.name)
            else
                if w.size > 5 and GetNumRaidMembers() == 0 and GetNumPartyMembers() >= 4 and IsPartyLeader() then
                    ConvertToRaid()
                    table.insert(w.queue, 1, item)   -- invite after the raid exists
                    return
                end
                InviteUnit(item.name)
            end
            return
        end
        if GetTime() < w.endAt then return end
        local missing = {}
        for n in pairs(w.names) do if not w.got[n] then missing[#missing + 1] = n end end
        if #missing > 0 then Say(string.format(DCL("Not found (renamed or deleted?): %s"), table.concat(missing, ", "))) end
        if #w.offline > 0 then Say(string.format(DCL("Offline and not on your account, cannot be logged in: %s"), table.concat(w.offline, ", "))) end
        Say(DCL("Group invitations sent."))
        C2.want = nil
        self:Hide()
    end)

    -- menus on the rows
    local function GroupMenu(g)
        local menu = { { text = g.name .. "  |cff999999" .. #g.members .. "/" .. g.size .. "|r", isTitle = true, notCheckable = true } }
        local function add(t) t.notCheckable = true; menu[#menu + 1] = t end
        add({ text = DCL("Form the whole group"), func = function() C2.Form(g) end })
        add({ text = DCL("Rename"), func = function() AskName({ mode = "rename", g = g, default = g.name }, DCL("New name:")) end })
        add({ text = DCL("Replace with the current party"), func = function()
            local list = CurrentMembers()
            while #list > g.size do table.remove(list) end
            g.members = list
            C2.Render()
        end })
        add({ text = DCL("Copy"), func = function()
            local copy = { name = string.format(DCL("%s (copy)"), g.name), size = g.size, members = {}, owner = UnitName("player") }
            for _, m in ipairs(g.members) do copy.members[#copy.members + 1] = { name = m.name, cls = m.cls, level = m.level, role = m.role } end
            table.insert(Groups(), copy)
            C2.Render()
        end })
        -- RebornWOW DCUI3D5: move this group's people into another group / a group of another size
        local others = {}
        for _, x in ipairs(Groups()) do if x ~= g and C2.Visible(x) and #others < 10 then others[#others + 1] = x end end
        if #others > 0 then
            menu[#menu + 1] = { text = DCL("Add everyone to:"), isTitle = true, notCheckable = true }
            for _, x in ipairs(others) do
                add({ text = string.format("  %s  |cff999999%d/%d|r", x.name, #x.members, x.size), func = function() C2.AddMany(x, g.members) end })
            end
        end
        menu[#menu + 1] = { text = DCL("Copy as a group of:"), isTitle = true, notCheckable = true }
        for _, n in ipairs(SIZES) do
            if n ~= g.size then
                add({ text = "  " .. string.format(DCL("%d players"), n), func = function()
                    local ng = { name = string.format(DCL("%s (%d)"), g.name, n), size = n, members = {}, owner = UnitName("player") }
                    table.insert(Groups(), ng)
                    C2.size, C2.open = n, ng
                    C2.AddMany(ng, g.members)
                end })
            end
        end
        add({ text = "|cffff5050" .. DCL("Delete") .. "|r", func = function()
            C2.pendingDel = g
            StaticPopup_Show("DUNGEONCLEAR_GROUP_DELETE", string.format(DCL("Delete the favourite group %s?"), g.name))
        end })
        add({ text = CANCEL, func = function() CloseDropDownMenus() end })
        EasyMenu(menu, menuFrame, "cursor", 0, 0, "MENU")
    end
    local function MemberMenu(g, mi)
        local m = g.members[mi]
        if not m then return end
        local menu = { { text = ClassHex(m.cls) .. m.name .. "|r", isTitle = true, notCheckable = true } }
        local function add(t) t.notCheckable = true; menu[#menu + 1] = t end
        add({ text = DCL("Invite this character"), disabled = InGroup(m.name), func = function()
            if shell.c1 and shell.c1.myChars[m.name] then Chat(".playerbot bot add " .. m.name) else InviteUnit(m.name) end
        end })
        for _, rk in ipairs({ { "tank", "Role: tank" }, { "heal", "Role: healer" }, { "dps", "Role: DPS" } }) do
            menu[#menu + 1] = { text = DCL(rk[2]), checked = m.role == rk[1],
                                func = function() m.role = (m.role ~= rk[1]) and rk[1] or nil; C2.Render() end }
        end
        add({ text = DCL("Remove from this group"), func = function() table.remove(g.members, mi); C2.Render() end })
        add({ text = CANCEL, func = function() CloseDropDownMenus() end })
        EasyMenu(menu, menuFrame, "cursor", 0, 0, "MENU")
    end
    for _, r in ipairs(rows) do
        r:SetScript("OnClick", function(self, button)
            local e = self.e
            if not e then return end
            if e.kind == "group" then
                if button == "RightButton" then GroupMenu(e.g)
                else C2.open = (C2.open ~= e.g) and e.g or nil; C2.Render() end
            elseif e.kind == "member" and button == "RightButton" then
                MemberMenu(e.g, e.mi)
            end
        end)
        r.form:SetScript("OnClick", function(self) local e = self:GetParent().e; if e and e.g then C2.Form(e.g) end end)
        r:SetScript("OnEnter", function(self)
            local e = self.e
            if not e or e.kind == "hint" then return end
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            if e.kind == "group" then
                GameTooltip:AddLine(e.g.name)
                GameTooltip:AddLine(DCL("Click: open / close.  Right-click: more"), 0.7, 0.7, 0.7)
            else
                GameTooltip:AddLine(e.m.name)
                GameTooltip:AddLine(DCL("Right-click: more actions"), 0.7, 0.7, 0.7)
            end
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    DCLoc.OnChange(function() C2.Render() end)
    end)()

    -- ------------------------------------------------------------ party tools (RebornWOW DCUI3C3)
    -- Design doc §16.4/16.5: a bar at the bottom of the party tab -- Fill up (the server
    -- picks free online bots near your level by missing role), Disband, My bots log out --
    -- and, in a raid, drag a member onto someone in another subgroup to move it there
    -- (swap when that subgroup is full). Own function + a table on the shell.
    shell.c3 = {}
    ;(function()
    local C3, C1 = shell.c3, shell.c1
    local function Say(m) DEFAULT_CHAT_FRAME:AddMessage("|cff3da6ff[DC]|r " .. m) end
    local function MemberNames()
        local list, me = {}, UnitName("player")
        local n = GetNumRaidMembers()
        if n > 0 then
            for i = 1, n do local name = GetRaidRosterInfo(i); if name and name ~= me then list[#list + 1] = name end end
        else
            for i = 1, 4 do local name = UnitName("party" .. i); if name then list[#list + 1] = name end end
        end
        return list
    end

    local bar = CreateFrame("Frame", nil, col4)
    bar:SetPoint("BOTTOMLEFT", col4, "BOTTOMLEFT", 8, 8); bar:SetPoint("BOTTOMRIGHT", col4, "BOTTOMRIGHT", -8, 8)
    bar:SetHeight(22)
    C3.bar = bar
    local bFill = SmallButton(bar, "Fill up", 64); bFill:SetPoint("LEFT", bar, "LEFT", 0, 0)
    local bDisband = SmallButton(bar, "Disband", 80); bDisband:SetPoint("LEFT", bFill, "RIGHT", 4, 0)
    local bLogout = SmallButton(bar, "My bots log out", 104); bLogout:SetPoint("LEFT", bDisband, "RIGHT", 4, 0)
    local function Tip(b, line1, line2)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine(DCL(line1))
            GameTooltip:AddLine(DCL(line2), 1, 1, 1, true); GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    Tip(bFill, "Fill up", "Invite free online bots of your faction near your level, by the roles the group is missing (tank / healer / DPS).")
    Tip(bDisband, "Disband", "Remove everyone from the group (you must be the leader).")
    Tip(bLogout, "My bots log out", "Log out every character of your own account that is in the group.")

    -- confirm popup shared by Disband / Log out
    StaticPopupDialogs["DUNGEONCLEAR_PARTY_CONFIRM"] = {
        text = "%s", button1 = YES, button2 = NO,
        OnAccept = function() local f = C3.pendingAction; C3.pendingAction = nil; if f then f() end end,
        timeout = 0, whileDead = 1, hideOnEscape = 1,
    }
    local function Confirm(text, f) C3.pendingAction = f; StaticPopup_Show("DUNGEONCLEAR_PARTY_CONFIRM", text) end

    bDisband:SetScript("OnClick", function()
        local names = MemberNames()
        if #names == 0 then Say(DCL("You are not in a group.")); return end
        if not C1.IsLeader() then
            Confirm(DCL("You are not the leader. Leave the group?"), function() LeaveParty() end)
            return
        end
        Confirm(string.format(DCL("Disband the group (remove %d)?"), #names), function()
            for _, n in ipairs(MemberNames()) do UninviteUnit(n) end
        end)
    end)
    bLogout:SetScript("OnClick", function()
        local mine = {}
        for _, n in ipairs(MemberNames()) do if C1.myChars[n] then mine[#mine + 1] = n end end
        if #mine == 0 then Say(DCL("None of your own characters are in the group.")); return end
        Confirm(string.format(DCL("Log out your own characters in the group (%d)?"), #mine), function()
            for _, n in ipairs(mine) do Chat(".playerbot bot remove " .. n) end
        end)
    end)

    -- Fill up: choose the size, ask the server, invite what comes back
    local qf = CreateFrame("Frame"); qf:Hide()
    local qacc = 0
    bFill:SetScript("OnClick", function()
        local have = math.max(1, GetNumRaidMembers() > 0 and GetNumRaidMembers() or (GetNumPartyMembers() + 1))
        local menu = { { text = DCL("Fill the group to:"), isTitle = true, notCheckable = true } }
        for _, n in ipairs({ 5, 10, 20, 25, 40 }) do
            menu[#menu + 1] = { text = string.format(DCL("%d players"), n), notCheckable = true, disabled = n <= have,
                                func = function()
                                    C3.fill = { size = n, names = {} }
                                    SendDcCommand("fill", tostring(n), true)
                                    Say(DCL("Looking for online bots..."))
                                end }
        end
        menu[#menu + 1] = { text = CANCEL, notCheckable = true, func = function() CloseDropDownMenus() end }
        EasyMenu(menu, menuFrame, "cursor", 0, 0, "MENU")
    end)
    function C3.OnFill(msg)
        local f = C3.fill
        if not f then return end
        local kind, a, b = strsplit("\t", msg)
        if kind == "FILL" then
            if a and a ~= "" then f.names[#f.names + 1] = a end
        elseif kind == "FILL_END" then
            local need = tonumber(b) or 0
            if need == 0 then Say(DCL("The group is already that size.")); C3.fill = nil; return end
            if #f.names == 0 then Say(DCL("No free online bots near your level.")); C3.fill = nil; return end
            Say(string.format(DCL("Found %d of %d needed; inviting..."), #f.names, need))
            f.queue = f.names
            qacc = 0
            qf:Show()
        end
    end
    qf:SetScript("OnUpdate", function(self, elapsed)
        qacc = qacc + (elapsed or 0)
        if qacc < 0.6 then return end
        qacc = 0
        local f = C3.fill
        if not (f and f.queue) then self:Hide(); return end
        local name = f.queue[1]
        if not name then C3.fill = nil; self:Hide(); return end
        if f.size > 5 and GetNumRaidMembers() == 0 and GetNumPartyMembers() >= 4 and IsPartyLeader() then
            ConvertToRaid()
            return
        end
        table.remove(f.queue, 1)
        InviteUnit(name)
    end)

    -- raid: drag a member onto someone in another subgroup
    for _, r in ipairs(rrow) do
        r:RegisterForDrag("LeftButton")
        r:SetScript("OnDragStart", function(self)
            local ri = self.unit and tonumber(self.unit:match("^raid(%d+)$") or "")
            if not ri or not C1.IsLeader() then return end
            local name, _, _, _, _, token = GetRaidRosterInfo(ri)
            C3.drag = ri
            GameTooltip:Hide()
            SetClassIcon(C1.ghost.icon, token)
            C1.ghost.text:SetText(ClassHex(token) .. (name or "?") .. "|r")
            C1.ghost.over = nil
            C1.ghost:Show()
        end)
        r:SetScript("OnDragStop", function()
            local ri = C3.drag
            C3.drag = nil
            C1.ghost:Hide(); C1.Border(false)
            if not ri then return end
            for _, t in ipairs(rrow) do
                local tj = t:IsShown() and t.unit and MouseIsOver(t) and tonumber(t.unit:match("^raid(%d+)$") or "")
                if tj and tj ~= ri then
                    local _, _, subI = GetRaidRosterInfo(ri)
                    local _, _, subJ = GetRaidRosterInfo(tj)
                    if subI and subJ and subI ~= subJ then
                        local count = 0
                        for i = 1, GetNumRaidMembers() do local _, _, s = GetRaidRosterInfo(i); if s == subJ then count = count + 1 end end
                        if count >= 5 then SwapRaidSubgroup(ri, tj) else SetRaidSubgroup(ri, subJ) end
                    end
                    return
                end
            end
        end)
    end
    end)()

    -- ------------------------------------------------------------ dungeon runs (RebornWOW DCRUN1A)
    -- Design doc §13: column 2 lists your own dungeon-clear runs (server DcPlayerRuns:
    -- the last 20 per character; this addon keeps up to 50 per character so they survive
    -- a server restart). Each row: [tier] dungeon (heroic), result, bosses, deaths, time,
    -- date. Right-click: run it again (the continuous-clear queue resets the dungeon and
    -- starts again), run stats, delete. Asked for every 15 s while the column is shown.
    -- Own function + a table on the shell (the main chunk's 200-local limit).
    shell.runs = {}
    ;(function()
    local R = shell.runs
    local function Say(m) DEFAULT_CHAT_FRAME:AddMessage("|cff3da6ff[DC]|r " .. m) end
    local TIER = { normal = { "Normal", "|cffcccccc" }, story = { "Story", "|cff3da6ff" },
                   casual = { "Casual", "|cff00ff00" }, speed = { "Speed", "|cffff6600" } }
    local RESULT = { clear = { "Cleared", "|cff40ff40" }, stop = { "Stopped", "|cffaaaaaa" }, wipe = { "Wiped", "|cffff5050" },
                     death = { "Stopped after deaths", "|cffff9933" }, left = { "Left the dungeon", "|cffaaaaaa" },
                     ["end"] = { "Ended", "|cffaaaaaa" }, running = { "In progress", "|cffffd100" } }
    local KIND = { a = "your account", b = "playerbot", n = "NPCBot", p = "real player" }
    local MAX_KEEP = 50

    local function Store()
        DungeonClearDB.myRuns = DungeonClearDB.myRuns or {}
        local me = UnitName("player") or "?"
        DungeonClearDB.myRuns[me] = DungeonClearDB.myRuns[me] or { list = {}, deleted = {} }
        return DungeonClearDB.myRuns[me]
    end
    local function Dur(sec)
        sec = tonumber(sec) or 0
        local h, m, s = math.floor(sec / 3600), math.floor(sec % 3600 / 60), sec % 60
        if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
        return string.format("%d:%02d", m, s)
    end
    local function Date(t)
        local ok, s = pcall(date, "%m-%d %H:%M", tonumber(t) or 0)
        return ok and s or ""
    end

    runsNote:Hide()
    local emptyNote = col2:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); Crisp(emptyNote, 13)
    emptyNote:SetPoint("TOPLEFT", col2.title, "BOTTOMLEFT", 0, -14)
    emptyNote:SetPoint("RIGHT", col2, "RIGHT", -12, 0)
    emptyNote:SetJustifyH("LEFT")
    emptyNote:SetTextColor(0.82, 0.85, 0.90)
    local ROWS, RH = 14, 42
    local rows, offset = {}, 0
    for i = 1, ROWS do
        local r = Row(col2, RH - 3)
        r:SetPoint("TOPLEFT", col2, "TOPLEFT", 8, -38 - (i - 1) * RH)
        r:SetPoint("RIGHT", col2, "RIGHT", -8, 0)
        r.l1 = r:CreateFontString(nil, "OVERLAY", "GameFontNormal"); Crisp(r.l1, 13)
        r.l1:SetPoint("TOPLEFT", r, "TOPLEFT", 5, -4); r.l1:SetPoint("RIGHT", r, "RIGHT", -60, 0); r.l1:SetJustifyH("LEFT")
        r.res = r:CreateFontString(nil, "OVERLAY", "GameFontNormal"); Crisp(r.res, 13)
        r.res:SetPoint("TOPRIGHT", r, "TOPRIGHT", -5, -4)
        r.l2 = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); Crisp(r.l2, 12)
        r.l2:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 5, 4); r.l2:SetPoint("RIGHT", r, "RIGHT", -5, 0); r.l2:SetJustifyH("LEFT")
        r:Hide()
        rows[i] = r
    end

    function R.Render()
        local list = Store().list
        emptyNote:SetText(#list == 0 and DCL("No runs yet. Start dungeon clear with your party; when the run ends (cleared, stopped or wiped) it is listed here.") or "")
        offset = math.max(0, math.min(offset, #list - ROWS))
        for i, r in ipairs(rows) do
            local d = list[i + offset]
            r.d = d
            if not d then r:Hide() else
                local t = TIER[d.tier] or TIER.normal
                local res = RESULT[d.result] or RESULT["end"]
                r.l1:SetText(t[2] .. "[" .. DCL(t[1]) .. "]|r " .. DCLDungeon(d.name)
                             .. (d.heroic and (" |cffff8000" .. DCL("(Heroic)") .. "|r") or ""))
                r.res:SetText(res[2] .. DCL(res[1]) .. "|r")
                r.l2:SetText(string.format("%s %d/%d   %s %d   %s %s   |cff999999%s|r", DCL("Bosses"), d.bosses or 0,
                    d.total or 0, DCL("Deaths"), d.deaths or 0, DCL("Time"), Dur(d.dur), Date(d.start)))
                r:Show()
            end
        end
    end

    -- server replies: MR rows (upserted by id), MRX detail -> the stats window
    local pendingDetail = {}
    function R.OnMsg(kind, msg)
        if kind == "MR" then
            local _, id, mapId, heroic, start, dur, result, bosses, total, deaths, tier, token, name = strsplit("\t", msg)
            local st = Store()
            if not id or st.deleted[id] then return end
            local row = { id = id, map = tonumber(mapId) or 0, heroic = heroic == "1", start = tonumber(start) or 0,
                          dur = tonumber(dur) or 0, result = result, bosses = tonumber(bosses) or 0,
                          total = tonumber(total) or 0, deaths = tonumber(deaths) or 0, tier = tier,
                          token = (token ~= "-") and token or nil, name = name or "?" }
            local found
            for i, x in ipairs(st.list) do if x.id == id then st.list[i] = row; found = true; break end end
            if not found then table.insert(st.list, row) end
            table.sort(st.list, function(a, b) return (a.start or 0) > (b.start or 0) end)
            while #st.list > MAX_KEEP do table.remove(st.list) end
        elseif kind == "MR_END" then
            R.Render()
        elseif kind == "MRX" then
            local _, id, what, a, b, c, d = strsplit("\t", msg)
            local det = pendingDetail[id]
            if not det then det = { members = {}, bosses = {}, deaths = {} }; pendingDetail[id] = det end
            if what == "R" then det.reason = a
            elseif what == "S" then det.restarts = tonumber(a) or 0
            elseif what == "M" then det.members[#det.members + 1] = { name = a, cls = tonumber(b) or 0, level = tonumber(c) or 0, kind = d }
            elseif what == "B" then det.bosses[#det.bosses + 1] = { t = tonumber(a) or 0, name = b }
            elseif what == "D" then det.deaths[#det.deaths + 1] = { t = tonumber(a) or 0, name = b } end
        elseif kind == "MRX_END" then
            local id = msg:match("^MRX_END\t(.*)$")
            local det = pendingDetail[id]
            pendingDetail[id] = nil
            if id and id == R.wantDetail then R.wantDetail = nil; R.ShowStats(id, det) end
        end
    end

    -- the stats window
    local sf
    function R.ShowStats(id, det)
        local d
        for _, x in ipairs(Store().list) do if x.id == id then d = x end end
        if not d then return end
        if not sf then
            sf = CreateFrame("Frame", "DungeonClearRunStatsFrame", UIParent)
            sf:SetSize(400, 480); sf:SetPoint("CENTER"); sf:SetFrameStrata("DIALOG")
            sf:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                             tile = true, tileSize = 12, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
            sf:SetBackdropColor(0.03, 0.04, 0.06, 0.95); sf:SetBackdropBorderColor(0.42, 0.36, 0.22, 1)
            sf:EnableMouse(true); sf:SetMovable(true); sf:RegisterForDrag("LeftButton")
            sf:SetScript("OnDragStart", sf.StartMoving); sf:SetScript("OnDragStop", sf.StopMovingOrSizing)
            local close = CreateFrame("Button", nil, sf, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -2, -2)
            sf.title = sf:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"); sf.title:SetPoint("TOPLEFT", 14, -12)
            sf.title:SetPoint("RIGHT", sf, "RIGHT", -34, 0); sf.title:SetJustifyH("LEFT")
            sf.body = sf:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); Crisp(sf.body, 12)
            sf.body:SetPoint("TOPLEFT", 14, -40); sf.body:SetPoint("RIGHT", sf, "RIGHT", -14, 0)
            sf.body:SetJustifyH("LEFT"); sf.body:SetJustifyV("TOP")
            tinsert(UISpecialFrames, "DungeonClearRunStatsFrame")
        end
        det = det or { members = {}, bosses = {}, deaths = {} }
        local res = RESULT[d.result] or RESULT["end"]
        local t = TIER[d.tier] or TIER.normal
        sf.title:SetText(DCLDungeon(d.name) .. (d.heroic and (" " .. DCL("(Heroic)")) or ""))
        local L = {}
        local function add(s) L[#L + 1] = s end
        add(string.format("|cffffd100%s|r %s%s|r   |cffffd100%s|r %s%s|r", DCL("Result"), res[2], DCL(res[1]), DCL("Cheat tier"), t[2], DCL(t[1])))
        if det.reason and det.reason ~= "" then add("|cffffd100" .. DCL("Reason") .. "|r " .. DCLDetail(det.reason)) end
        add(string.format("|cffffd100%s|r %s   |cffffd100%s|r %s   |cffffd100%s|r %d", DCL("Started"), Date(d.start),
            DCL("Time"), Dur(d.dur), DCL("Restarts"), det.restarts or 0))
        add("")
        add(string.format("|cff3da6ff%s %d/%d|r", DCL("Boss kills"), #det.bosses, d.total or 0))
        for _, e in ipairs(det.bosses) do add("  " .. Dur(e.t) .. "  " .. e.name) end
        add("")
        add(string.format("|cff3da6ff%s %d|r", DCL("Deaths"), #det.deaths))
        for i, e in ipairs(det.deaths) do
            if i > 12 then add("  " .. string.format(DCL("and %d more"), #det.deaths - 12)); break end
            add("  " .. Dur(e.t) .. "  " .. e.name)
        end
        add("")
        add(string.format("|cff3da6ff%s %d|r", DCL("Members"), #det.members))
        for i, m in ipairs(det.members) do
            if i > 12 then add("  " .. string.format(DCL("and %d more"), #det.members - 12)); break end
            local token = CLASS_BY_ID[m.cls]
            add(string.format("  %s%s|r  %s %d  |cff999999%s|r", ClassHex(token), m.name, DCL("Lv"), m.level, DCL(KIND[m.kind] or "real player")))
        end
        sf.body:SetText(table.concat(L, "\n"))
        sf:Show()
    end

    -- right-click menu
    StaticPopupDialogs["DUNGEONCLEAR_RUNS_DELETE_ALL"] = {
        text = "%s", button1 = YES, button2 = NO,
        OnAccept = function()
            local st = Store()
            for _, x in ipairs(st.list) do st.deleted[x.id] = true end
            st.list = {}
            SendDcCommand("myrundel", "all", true)
            R.Render()
        end,
        timeout = 0, whileDead = 1, hideOnEscape = 1,
    }
    local function Menu(d)
        local menu = { { text = DCLDungeon(d.name), isTitle = true, notCheckable = true } }
        local function add(t) t.notCheckable = true; menu[#menu + 1] = t end
        add({ text = DCL("Run it again"), func = function()
            if not d.token then Say(DCL("This dungeon has no dungeon-clear route.")); return end
            SendDcCommand("queue", "start\t" .. d.token, true)
            Say(DCL("Queued: the dungeon is reset and the clear starts again."))
        end })
        add({ text = DCL("Run stats"), func = function()
            R.wantDetail = d.id
            SendDcCommand("myrun", d.id, true)
            R.ShowStats(d.id, nil)   -- open now with the summary; the detail fills in on reply
            R.wantDetail = d.id
        end })
        add({ text = DCL("Delete this run"), func = function()
            local st = Store()
            st.deleted[d.id] = true
            for i, x in ipairs(st.list) do if x.id == d.id then table.remove(st.list, i); break end end
            SendDcCommand("myrundel", d.id, true)
            R.Render()
        end })
        add({ text = "|cffff5050" .. DCL("Delete all runs") .. "|r", func = function()
            StaticPopup_Show("DUNGEONCLEAR_RUNS_DELETE_ALL", DCL("Delete all your dungeon runs?"))
        end })
        add({ text = CANCEL, func = function() CloseDropDownMenus() end })
        EasyMenu(menu, menuFrame, "cursor", 0, 0, "MENU")
    end
    for _, r in ipairs(rows) do
        r:SetScript("OnClick", function(self, button) if button == "RightButton" and self.d then Menu(self.d) end end)
        r:SetScript("OnEnter", function(self)
            if not self.d then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(DCLDungeon(self.d.name))
            GameTooltip:AddLine(DCL("Right-click: run again / stats / delete"), 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    col2:SetScript("OnMouseWheel", function(_, delta) offset = offset - delta * 3; R.Render() end)

    -- ask every 15 s while the column is shown (the first time right away)
    local poll = CreateFrame("Frame", nil, col2)
    local acc = 15
    poll:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        if acc < 15 then return end
        acc = 0
        SendDcCommand("myruns", "", true)
    end)
    R.Render()
    DCLoc.OnChange(function() R.Render() end)
    end)()

    -- ------------------------------------------------------------ character picker (RebornWOW DCTEST8A)
    -- Design doc §12.1: one pop-up list to pick a character, shared by callers.
    --   DCOpenPicker{ title, cats = { "account", "pool", "favorites", "search" }, level = n,
    --                 filter = function(d) return ok, why end, onPick = function(d) end }
    -- Categories are the server's roster ones (+ "pool": OFFLINE random-bot characters of
    -- your faction near `level`) and "favorites" (the shared stars, via botinfo). Replies
    -- are routed here while the picker owns the request (shell.rosterOwner). Own function +
    -- a table on the shell (the main chunk's 200-local limit).
    shell.picker = {}
    ;(function()
    local P = shell.picker
    local CAT_LABEL = { account = "My account", pool = "Bot pool", bots = "Online bots", npcbots = "NPCBots",
                        players = "Real players", favorites = "Favorites", search = "Search" }
    local pf = CreateFrame("Frame", "DungeonClearPickerFrame", UIParent)
    pf:SetSize(320, 470); pf:SetPoint("CENTER", UIParent, "CENTER", 260, 0); pf:SetFrameStrata("DIALOG")
    pf:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                     tile = true, tileSize = 12, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    pf:SetBackdropColor(0.03, 0.04, 0.06, 0.96); pf:SetBackdropBorderColor(0.42, 0.36, 0.22, 1)
    pf:EnableMouse(true); pf:SetMovable(true); pf:RegisterForDrag("LeftButton")
    pf:SetScript("OnDragStart", pf.StartMoving); pf:SetScript("OnDragStop", pf.StopMovingOrSizing)
    pf:Hide()
    tinsert(UISpecialFrames, "DungeonClearPickerFrame")
    local close = CreateFrame("Button", nil, pf, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -2, -2)
    local title = pf:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"); title:SetPoint("TOPLEFT", 12, -12)
    title:SetPoint("RIGHT", pf, "RIGHT", -34, 0); title:SetJustifyH("LEFT")
    local hint = pf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); Crisp(hint, 12)
    hint:SetPoint("TOPLEFT", 12, -36); hint:SetPoint("RIGHT", pf, "RIGHT", -12, 0); hint:SetJustifyH("LEFT")
    hint:SetTextColor(0.75, 0.78, 0.85)
    local tabs = {}
    local search = CreateFrame("EditBox", "DungeonClearPickerSearch", pf, "InputBoxTemplate")
    search:SetSize(200, 20); search:SetAutoFocus(false)
    local note = pf:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); Crisp(note, 13)
    note:SetJustifyH("LEFT")
    local ROWS, RH = 13, 26
    local rows, data, offset = {}, {}, 0
    for i = 1, ROWS do
        local r = Row(pf, RH - 2)
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(20, 20); r.icon:SetPoint("LEFT", r, "LEFT", 3, 0)
        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal"); Crisp(r.name, 13)
        r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0); r.name:SetJustifyH("LEFT")
        r.info = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); Crisp(r.info, 12)
        r.info:SetPoint("RIGHT", r, "RIGHT", -6, 0); r.info:SetJustifyH("RIGHT")
        rows[i] = r
    end

    local function Say(m) DEFAULT_CHAT_FRAME:AddMessage("|cff3da6ff[DC]|r " .. m) end
    local function Filtered()
        local list = {}
        for _, d in ipairs(data) do list[#list + 1] = d end
        return list
    end
    local function Render()
        local o = P.opts
        if not o then return end
        for k, b in pairs(tabs) do if k == P.cat then b:LockHighlight() else b:UnlockHighlight() end end
        local list = Filtered()
        note:SetText(P.loading and DCL("Loading...") or (#list == 0 and DCL("Nobody here.") or ""))
        offset = math.max(0, math.min(offset, #list - ROWS))
        for i, r in ipairs(rows) do
            local d = list[i + offset]
            r.d = d
            if not d then r:Hide() else
                local token = CLASS_BY_ID[d.cls]
                SetClassIcon(r.icon, token)
                local ok = true
                if o.filter then ok = o.filter(d) end
                r.name:SetText((ok and ClassHex(token) or "|cff777777") .. d.name .. "|r")
                local bits = { DCL("Lv") .. " " .. d.level }
                if d.npc then bits[#bits + 1] = "|cff3da6ffNPCBot|r"
                elseif d.online then bits[#bits + 1] = "|cff40ff40" .. DCL("online") .. "|r"
                else bits[#bits + 1] = "|cff999999" .. DCL("offline") .. "|r" end
                r.info:SetText(table.concat(bits, "  "))
                r:Show()
            end
        end
    end
    local function Request()
        data, offset = {}, 0
        P.loading = true
        shell.rosterOwner = "picker"
        local o = P.opts
        if P.cat == "favorites" then
            local names = {}
            for n in pairs(FavTable()) do names[#names + 1] = n end
            if #names == 0 then P.loading = nil; Render(); return end
            P.wantBI = true
            local chunk = ""
            for _, n in ipairs(names) do
                if #chunk + #n + 1 > 200 then SendDcCommand("botinfo", "|" .. chunk, true); chunk = "" end
                chunk = chunk == "" and n or (chunk .. "," .. n)
            end
            SendDcCommand("botinfo", "|" .. chunk, true)
        else
            local q = (P.cat == "search" or P.cat == "pool") and (search:GetText() or "") or ""
            if P.cat == "pool" then q = q .. "\t" .. tostring(o.level or 0) end
            SendDcCommand("roster", P.cat .. "\t" .. q, true)
        end
        Render()
    end
    local function Layout()
        local o = P.opts
        for _, b in pairs(tabs) do b:Hide() end
        local x, y = 10, -58
        for i, c in ipairs(o.cats) do
            local b = tabs[c]
            if not b then
                b = CreateFrame("Button", nil, pf, "UIPanelButtonTemplate")
                b:SetSize(96, 20)
                b:SetScript("OnClick", function() P.cat = c; Request() end)
                tabs[c] = b
            end
            DCBind(b, CAT_LABEL[c] or c)
            b:ClearAllPoints(); b:SetPoint("TOPLEFT", pf, "TOPLEFT", x + ((i - 1) % 3) * 100, y - math.floor((i - 1) / 3) * 22)
            b:Show()
        end
        local top = y - math.ceil(#o.cats / 3) * 22 - 4
        search:ClearAllPoints(); search:SetPoint("TOPLEFT", pf, "TOPLEFT", 16, top)
        note:ClearAllPoints(); note:SetPoint("TOPLEFT", pf, "TOPLEFT", 12, top - 30); note:SetPoint("RIGHT", pf, "RIGHT", -12, 0)
        for i, r in ipairs(rows) do
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", pf, "TOPLEFT", 8, top - 28 - (i - 1) * RH)
            r:SetPoint("RIGHT", pf, "RIGHT", -8, 0)
        end
    end

    function P.Open(opts)
        P.opts = opts
        title:SetText(opts.title or DCL("Pick a character"))
        hint:SetText(opts.hint or "")
        P.cat = opts.cats[1]
        Layout()
        pf:Show()
        Request()
    end
    DCOpenPicker = P.Open

    -- replies routed here while we own the roster request
    function P.OnRoster(kind, msg)
        if kind == "RO_START" then data = {}
        elseif kind == "RO" then
            local _, cat, name, cls, level, race, team, online, mine, extra = strsplit("\t", msg)
            extra = extra or "-"
            data[#data + 1] = { name = name, cls = tonumber(cls) or 0, level = tonumber(level) or 0, online = online == "1",
                                mine = mine == "1", npc = extra:find("n") ~= nil, real = extra:find("p") ~= nil }
        elseif kind == "RO_END" then
            P.loading = nil
            shell.rosterOwner = nil
            Render()
        end
    end
    function P.OnBI(kind, msg)
        if not (P.wantBI and pf:IsShown() and P.cat == "favorites") then return end
        if kind == "BI" then
            local _, name, cls, level, race, team, online, mine = strsplit("\t", msg)
            if name then
                for _, d in ipairs(data) do if d.name == name then return end end
                data[#data + 1] = { name = name, cls = tonumber(cls) or 0, level = tonumber(level) or 0,
                                    online = online == "1", mine = mine == "1" }
            end
        elseif kind == "BI_END" then
            P.wantBI = nil
            P.loading = nil
            Render()
        end
    end

    for _, r in ipairs(rows) do
        r:SetScript("OnClick", function(self)
            local d, o = self.d, P.opts
            if not (d and o) then return end
            if o.filter then
                local ok, why = o.filter(d)
                if not ok then Say(why or DCL("This character cannot be picked here.")); return end
            end
            if o.onPick then o.onPick(d) end
            pf:Hide()
        end)
        r:SetScript("OnEnter", function(self)
            local d, o = self.d, P.opts
            if not (d and o) then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine(d.name)
            if o.filter then
                local ok, why = o.filter(d)
                if not ok then GameTooltip:AddLine(why or "", 1, 0.4, 0.4, true) end
            end
            GameTooltip:AddLine(DCL("Click: pick"), 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    pf:EnableMouseWheel(true)
    pf:SetScript("OnMouseWheel", function(_, delta) offset = offset - delta * 3; Render() end)
    search:SetScript("OnEnterPressed", function(self) self:ClearFocus(); if P.cat ~= "search" and P.cat ~= "pool" then P.cat = "search" end; Request() end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    DCLoc.OnChange(function() if pf:IsShown() then Render() end end)
    end)()

    -- ------------------------------------------------------------ auto-play question (RebornWOW DCSB2A)
    -- Design doc §10: when you are a real player in a party whose clear is running, the
    -- server asks once per run (SBASK <suggested role> <tank>); this pops "auto (tank /
    -- heal / dps) or manual". The choice can be changed any time on the panel's
    -- "Auto-play" row. Own function (the main chunk's 200-local limit).
    ;(function()
    local ask = CreateFrame("Frame", "DungeonClearSelfBotAsk", UIParent)
    ask:SetSize(360, 150); ask:SetPoint("TOP", UIParent, "TOP", 0, -180); ask:SetFrameStrata("DIALOG")
    ask:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                      tile = true, tileSize = 12, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    ask:SetBackdropColor(0.03, 0.04, 0.06, 0.96); ask:SetBackdropBorderColor(0.42, 0.36, 0.22, 1)
    ask:EnableMouse(true); ask:SetMovable(true); ask:RegisterForDrag("LeftButton")
    ask:SetScript("OnDragStart", ask.StartMoving); ask:SetScript("OnDragStop", ask.StopMovingOrSizing)
    ask:Hide()
    local title = ask:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"); title:SetPoint("TOP", 0, -12)
    DCBind(title, "Let the AI play for you?")
    local text = ask:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); Crisp(text, 13)
    text:SetPoint("TOPLEFT", 14, -38); text:SetPoint("RIGHT", ask, "RIGHT", -14, 0); text:SetJustifyH("LEFT")
    local btns = {}
    for i, b in ipairs({ { "tank", "Tank" }, { "heal", "Heal" }, { "dps", "DPS" }, { "off", "Manual" } }) do
        local x = CreateFrame("Button", nil, ask, "UIPanelButtonTemplate")
        x:SetSize(78, 24)
        x:SetPoint("BOTTOMLEFT", ask, "BOTTOMLEFT", 14 + (i - 1) * 84, 14)
        DCBind(x, b[2])
        x:SetScript("OnClick", function()
            if b[1] ~= "off" then SendDcCommand("selfbot", b[1], true) end
            ask:Hide()
        end)
        btns[b[1]] = x
    end
    function DCShowSelfBotAsk(role, tank)
        for k, x in pairs(btns) do if k == role then x:LockHighlight() else x:UnlockHighlight() end end
        text:SetText(string.format(DCL("Your party is running dungeon clear (tank: %s). Pick a role and the AI plays your character with the bots, or stay manual. You can switch any time on the dungeon-clear panel's Auto-play row; leaving the dungeon or the party hands the character back to you."), tank or "?"))
        ask:Show()
    end
    end)()

    -- ------------------------------------------------------------ menus close on an outside click (RebornWOW DCUI3C7)
    -- The stock dropdown only closes on a click in the game world (or after its timer),
    -- so a right-click menu stayed open while the player clicked around the panel. A
    -- watcher on DropDownList1 (it only runs while a menu is open) closes a menu that a
    -- DungeonClear frame opened on any NEW mouse press outside the menu lists; a
    -- right-click on another row then closes the old menu and opens the new one.
    ;(function()
    if not DropDownList1 then return end
    local watch = CreateFrame("Frame", nil, DropDownList1)
    local wasDown = true   -- the press that opened the menu does not count
    local function OurMenu()
        local m = UIDROPDOWNMENU_OPEN_MENU
        local name = (type(m) == "table" and m.GetName and m:GetName()) or (type(m) == "string" and m) or ""
        return name:sub(1, 12) == "DungeonClear"
    end
    local function Down()
        return (IsMouseButtonDown and (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton"))) and true or false
    end
    watch:SetScript("OnShow", function() wasDown = true end)
    watch:SetScript("OnUpdate", function()
        local down = Down()
        if down and not wasDown and OurMenu() then
            local inside = MouseIsOver(DropDownList1) or (DropDownList2 and DropDownList2:IsShown() and MouseIsOver(DropDownList2))
            if not inside then CloseDropDownMenus() end
        end
        wasDown = down
    end)
    end)()

    -- ------------------------------------------------------------ top bar + left tabs (RebornWOW DCUI3D1)
    -- Panel redesign R1 (user-approved mock-up, 2026-10-18): a top bar over three columns.
    -- The bar shows the dungeon, the run state and time, boss progress and the cheat tier;
    -- the tools (GPS / Test / EN / Tiny / close) sit at its right end (DCShellLayout). The
    -- left column holds "All dungeons" and "Dungeon runs" in one place behind two tabs.
    -- Own function + tables on the shell (the main chunk's 200-local limit).
    shell.topbar = CreateFrame("Frame", nil, shell)
    ;(function()
    local tb = shell.topbar
    tb:SetPoint("TOPLEFT", shell, "TOPLEFT", PAD, -6)
    tb:SetPoint("TOPRIGHT", shell, "TOPRIGHT", -PAD, -6)
    tb:SetHeight(36)
    tb:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                     tile = true, tileSize = 12, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    tb:SetBackdropColor(0.03, 0.04, 0.06, 0.85)
    tb:SetBackdropBorderColor(0.42, 0.36, 0.22, 0.9)
    local function Text(size)
        local f = tb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        Crisp(f, size or 13)
        f:SetTextColor(0.91, 0.93, 0.95)
        return f
    end
    local function Sep(anchor)
        local s = tb:CreateTexture(nil, "ARTWORK")
        s:SetSize(1, 18); s:SetTexture(0.25, 0.28, 0.35, 1)
        s:SetPoint("LEFT", anchor, "RIGHT", 10, 0)
        return s
    end
    local title = tb:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", tb, "LEFT", 12, 0)
    title:SetTextColor(0.24, 0.60, 1.0)
    DCBind(title, "Dungeon Clear")
    -- RebornWOW DCUI4A: [Clear] [Test] [Field] -- one panel, three modes
    shell.modeBtns = {}
    local modeBar = CreateFrame("Frame", nil, tb)
    modeBar:SetSize(3 * 52 + 8, 24)
    modeBar:SetPoint("LEFT", Sep(title), "RIGHT", 10, 0)
    for i, m in ipairs({ { "clear", "Clear mode" }, { "test", "Test mode" }, { "field", "Field mode" } }) do
        local b = SmallButton(modeBar, m[2], 50)
        b:SetPoint("LEFT", modeBar, "LEFT", 2 + (i - 1) * 52, 0)
        b:SetScript("OnClick", function() if DCShellSetMode then DCShellSetMode(m[1]) end end)
        b.dcMode = m[1]
        shell.modeBtns[m[1]] = b
    end
    local dungeon = Text(13); dungeon:SetPoint("LEFT", Sep(modeBar), "RIGHT", 10, 0)
    local dot = tb:CreateTexture(nil, "ARTWORK"); dot:SetSize(8, 8); dot:SetPoint("LEFT", dungeon, "RIGHT", 16, 0)
    local state = Text(13); state:SetPoint("LEFT", dot, "RIGHT", 5, 0)
    local timer = Text(13); timer:SetPoint("LEFT", state, "RIGHT", 12, 0)
    local bossTxt = Text(13); bossTxt:SetPoint("LEFT", timer, "RIGHT", 12, 0)
    local barBg = tb:CreateTexture(nil, "ARTWORK"); barBg:SetSize(80, 6); barBg:SetTexture(0.11, 0.14, 0.19, 1)
    barBg:SetPoint("LEFT", bossTxt, "RIGHT", 6, 0)
    local barFill = tb:CreateTexture(nil, "OVERLAY"); barFill:SetHeight(6); barFill:SetTexture(0.91, 0.77, 0.42, 1)
    barFill:SetPoint("LEFT", barBg, "LEFT", 0, 0)
    local tier = Text(13); tier:SetPoint("LEFT", barBg, "RIGHT", 12, 0)
    local TIERS = { normal = { "Normal", "|cffcccccc" }, story = { "Story", "|cff3da6ff" },
                    casual = { "Casual", "|cff00ff00" }, speed = { "Speed", "|cffff6600" } }
    local runSince, acc = nil, 1
    local function Paint()
        local name, itype, diff = GetInstanceInfo()
        if itype == "party" or itype == "raid" then
            local hero = (itype == "party" and diff == 2) or (itype == "raid" and (diff == 3 or diff == 4))
            dungeon:SetText("|cffe8c46a" .. DCLDungeon(name or "?") .. "|r  " .. DCL(hero and "Heroic" or "Normal dungeon"))
        else
            dungeon:SetText("|cff9aa4b2" .. (GetRealZoneText() or "") .. "|r")
        end
        if isDCOn then
            dot:SetTexture(0.25, 0.75, 0.35, 1)
            state:SetText(DCL("Running"))
            runSince = runSince or GetTime()
        else
            dot:SetTexture(0.42, 0.46, 0.52, 1)
            state:SetText("|cff9aa4b2" .. DCL("Not running") .. "|r")
            runSince = nil
        end
        if runSince then
            local s = math.floor(GetTime() - runSince)
            timer:SetText(DCL("Time") .. " " .. string.format("%d:%02d", math.floor(s / 60), s % 60))
        else
            timer:SetText("")
        end
        local total, dead = #bosses, 0
        for _, b in ipairs(bosses) do if b.status == "dead" then dead = dead + 1 end end
        if total > 0 then
            bossTxt:SetText(DCL("Bosses") .. " " .. dead .. "/" .. total)
            barBg:Show(); barFill:Show(); barFill:SetWidth(math.max(1, 80 * dead / total))
        else
            bossTxt:SetText(""); barBg:Hide(); barFill:Hide()
        end
        local t = TIERS[DCCurrentTier or ""]
        tier:SetText(t and (t[2] .. "[" .. DCL(t[1]) .. "]|r") or "")
    end
    tb:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        if acc < 0.5 then return end
        acc = 0
        Paint()
    end)
    DCLoc.OnChange(Paint)

    -- left column: two tabs over one place (col1 and col2 share the same rectangle)
    local tabAll = SmallButton(shell, "All dungeons", 100)
    local tabRuns = SmallButton(shell, "Dungeon runs", 100)
    tabAll:SetPoint("TOPLEFT", shell, "TOPLEFT", PAD + 8, -(PAD + 40) - 8)
    tabRuns:SetPoint("LEFT", tabAll, "RIGHT", 4, 0)
    tabAll:SetFrameLevel(col1:GetFrameLevel() + 10)
    tabRuns:SetFrameLevel(col1:GetFrameLevel() + 10)
    col1.title:Hide()
    col2.title:Hide()
    function shell.ApplyLeftTab()
        if DungeonClearDB.leftTab == "runs" then
            col1:Hide(); col2:Show(); tabRuns:LockHighlight(); tabAll:UnlockHighlight()
        else
            col2:Hide(); col1:Show(); tabAll:LockHighlight(); tabRuns:UnlockHighlight()
        end
    end
    tabAll:SetScript("OnClick", function() DungeonClearDB.leftTab = "all"; shell.ApplyLeftTab() end)
    tabRuns:SetScript("OnClick", function() DungeonClearDB.leftTab = "runs"; shell.ApplyLeftTab() end)
    end)()

    -- ------------------------------------------------------------ cards + flat buttons (RebornWOW DCUI3D2)
    -- Panel redesign R2 (user-approved mock-up + "softer, more professional buttons",
    -- 2026-10-18).
    --   * The centre window becomes three cards in the panel: Run (status + On / Off /
    --     Skip / Pause), Strategy (pull + auto-play rows), Bosses (the list); spectate
    --     moves to a footer row. DCShellLayout places the rows; the cards sit behind.
    --   * Every UIPanelButtonTemplate button in the addon's windows loses the red art for
    --     a flat dark button: slate fill, thin border, white text; On = soft green, Off =
    --     soft red, GM = gold border; a "selected" button (LockHighlight: modes, tabs,
    --     filters) is blue with a gold border. A light scan every 1.5 s skins buttons of
    --     windows that build late.
    -- Own function + tables on the shell (the main chunk's 200-local limit).
    shell.cards = {}
    ;(function()
    local function Card(titleKey)
        local c = CreateFrame("Frame", nil, frame)
        c:SetFrameLevel(math.max(0, frame:GetFrameLevel()))
        c:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\Buttons\\WHITE8X8",
                        tile = true, tileSize = 8, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        c:SetBackdropColor(0.02, 0.03, 0.05, 0.72)
        c:SetBackdropBorderColor(0.20, 0.24, 0.31, 1)
        if titleKey then
            c.title = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            c.title:SetPoint("TOPLEFT", c, "TOPLEFT", 8, -5)
            c.title:SetTextColor(0.91, 0.77, 0.42)
            DCBind(c.title, titleKey)
        end
        c:Hide()
        return c
    end
    local run, strat, boss = Card("Run (card)"), Card("Strategy (card)"), Card(nil)
    run:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -4)
    run:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -4)
    run:SetPoint("BOTTOM", onBtn, "BOTTOM", 0, -8)
    strat:SetPoint("LEFT", frame, "LEFT", 6, 0)
    strat:SetPoint("RIGHT", frame, "RIGHT", -6, 0)
    strat:SetPoint("TOP", onBtn, "BOTTOM", 0, -14)
    strat:SetPoint("BOTTOM", onBtn, "BOTTOM", 0, -88)
    boss:SetPoint("LEFT", frame, "LEFT", 6, 0)
    boss:SetPoint("RIGHT", frame, "RIGHT", -6, 0)
    boss:SetPoint("TOP", onBtn, "BOTTOM", 0, -94)
    boss:SetPoint("BOTTOM", frame, "BOTTOM", 0, 36)
    shell.cards.list = { run, strat, boss }

    -- flat buttons --------------------------------------------------------
    local COLORS = {   -- fill r, g, b, a, border r, g, b
        base = { 0.13, 0.16, 0.21, 0.95, 0.27, 0.31, 0.38 },
        go   = { 0.14, 0.36, 0.21, 0.95, 0.30, 0.62, 0.38 },
        stop = { 0.40, 0.13, 0.13, 0.95, 0.72, 0.28, 0.26 },
        gm   = { 0.18, 0.15, 0.08, 0.95, 0.70, 0.56, 0.26 },
        sel  = { 0.18, 0.31, 0.50, 0.98, 0.91, 0.77, 0.42 },
    }
    local fontN = CreateFont("DungeonClearBtnFontNormal"); fontN:SetFontObject(GameFontNormal); fontN:SetTextColor(0.92, 0.94, 0.97)
    local fontH = CreateFont("DungeonClearBtnFontHighlight"); fontH:SetFontObject(GameFontHighlight); fontH:SetTextColor(1, 1, 1)
    local fontD = CreateFont("DungeonClearBtnFontDisable"); fontD:SetFontObject(GameFontDisable); fontD:SetTextColor(0.50, 0.52, 0.56)
    local function Paint(b, kind)
        local c = COLORS[kind] or COLORS.base
        local on = (not b.IsEnabled) or b:IsEnabled()
        on = on == true or on == 1
        b.dcFill:SetTexture(c[1], c[2], c[3], on and c[4] or 0.40)  -- DCUI3D9: disabled = dim
        b:SetBackdropBorderColor(c[5], c[6], c[7], on and 1 or 0.35)
    end
    -- RebornWOW DCUI3D9: the template's red art -- the state textures, or three named slices
    -- (Left / Middle / Right) that its mouse scripts re-texture; the highlight is kept apart
    local function PanelTextures(b)
        local list, seen = {}, {}
        local hl = b.GetHighlightTexture and b:GetHighlightTexture()
        local function check(t)
            if not t or t == hl or seen[t] then return end
            local p = t.GetTexture and t:GetTexture()
            if type(p) == "string" and p:lower():find("ui%-panel%-button") then seen[t] = true; list[#list + 1] = t end
        end
        if b.GetNormalTexture then check(b:GetNormalTexture()) end
        if b.GetPushedTexture then check(b:GetPushedTexture()) end
        if b.GetDisabledTexture then check(b:GetDisabledTexture()) end
        if b.GetRegions then
            for _, r in ipairs({ b:GetRegions() }) do
                if r.GetObjectType and r:GetObjectType() == "Texture" then check(r) end
            end
        end
        return list
    end
    local function IsPanelButton(b)
        if not (b.GetObjectType and b:GetObjectType() == "Button") then return false end
        return #PanelTextures(b) > 0
    end
    shell.PanelTextures = PanelTextures
    local function Skin(b)
        if b.dcSkin or not IsPanelButton(b) then return end
        b.dcSkin = true
        b.dcKind = b.dcKindPref or "base"
        -- DCUI3D9: fade every red piece (a re-textured slice keeps its alpha 0)
        for _, t in ipairs(PanelTextures(b)) do t:SetAlpha(0) end
        local h = b.GetHighlightTexture and b:GetHighlightTexture()
        if h then h:SetTexture(1, 1, 1, 0.10); h:SetTexCoord(0, 1, 0, 1); h:SetAllPoints(b); h:SetAlpha(1) end
        b.dcFill = b:CreateTexture(nil, "BACKGROUND")
        b.dcFill:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
        b.dcFill:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
        b:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        b:SetNormalFontObject(fontN)
        b:SetHighlightFontObject(fontH)
        b:SetDisabledFontObject(fontD)
        local lock, unlock = b.LockHighlight, b.UnlockHighlight
        b.LockHighlight = function(self) lock(self); self.dcLocked = true; Paint(self, "sel") end
        b.UnlockHighlight = function(self) unlock(self); self.dcLocked = false; Paint(self, self.dcKind) end
        -- DCUI3D9: enabled / disabled and pressed states on the flat fill
        local en, dis = b.Enable, b.Disable
        b.Enable = function(self) en(self); Paint(self, self.dcLocked and "sel" or self.dcKind) end
        b.Disable = function(self) dis(self); Paint(self, self.dcLocked and "sel" or self.dcKind) end
        b:HookScript("OnMouseDown", function(self) self.dcFill:SetVertexColor(0.70, 0.70, 0.70) end)
        b:HookScript("OnMouseUp", function(self) self.dcFill:SetVertexColor(1, 1, 1) end)
        Paint(b, b.dcKind)
    end
    local function SkinTree(f, depth)
        if not f or depth > 8 then return end
        Skin(f)
        local kids = { f:GetChildren() }
        for _, k in ipairs(kids) do SkinTree(k, depth + 1) end
    end
    shell.SkinButton = Skin
    shell.SkinTree = function(f) SkinTree(f, 0) end
    onBtn.dcKindPref = "go"
    offBtn.dcKindPref = "stop"
    if selfBotUI.btns[#selfBotUI.btns] then selfBotUI.btns[#selfBotUI.btns].dcKindPref = "gm" end

    local WINDOWS = { "DungeonClearFrame", "DungeonClearTestFrame", "DungeonClearTestListFrame", "DungeonClearQueueFrame",
                      "DungeonClearGpsFrame", "DungeonClearChatCopyFrame", "DungeonClearCorpseRunFrame", "DungeonClearPickerFrame",
                      "DungeonClearRunStatsFrame", "DungeonClearSelfBotAsk", "DungeonClearBotInspectFrame" }
    -- RebornWOW DCUI3F1: skin before the first draw -- once for every window (shown or
    -- not) and again in each window's OnShow, which runs before it is drawn; a window
    -- created later is hooked as soon as it exists. The timer only catches buttons added
    -- after a window opened.
    local hookedWin = {}
    local function HookWindow(w)
        if hookedWin[w] then return end
        hookedWin[w] = true
        SkinTree(w, 0)
        w:HookScript("OnShow", function(self) SkinTree(self, 0) end)
    end
    local function HookAll()
        for _, name in ipairs(WINDOWS) do
            local w = _G[name]
            if type(w) == "table" and w.HookScript and w.GetChildren then HookWindow(w) end
        end
    end
    local scan = CreateFrame("Frame", nil, UIParent)
    local acc, hookAcc = 2, 0
    scan:SetScript("OnUpdate", function(_, elapsed)
        hookAcc = hookAcc + (elapsed or 0)
        if hookAcc >= 0.5 then hookAcc = 0; HookAll() end  -- DCUI3F1: new windows at once
        acc = acc + (elapsed or 0)
        if acc < 1.5 then return end
        acc = 0
        for _, name in ipairs(WINDOWS) do
            local w = _G[name]
            if type(w) == "table" and w.IsShown and w:IsShown() then SkinTree(w, 0) end
        end
    end)
    scan:RegisterEvent("PLAYER_LOGIN")
    scan:SetScript("OnEvent", function() HookAll() end)  -- every window exists by now
    HookAll()
    end)()

    -- ------------------------------------------------------------ multi-select in the invite list (RebornWOW DCUI3D5)
    -- The user asked for Windows-style multi-select (2026-10-18): a check box per row,
    -- click = only this one, Ctrl+click = add / remove one, Shift+click = a range. With
    -- several picked, dragging any picked row carries all of them (onto the groups page:
    -- into the open group, or a new one; onto the party: invited one after another), a
    -- bar under the list offers Invite / Add to group / Clear, and right-click on a picked
    -- row works on all of them. Own function + a table on the shell (200-local limit).
    shell.sel = { names = {}, order = {} }
    ;(function()
    local S, C1, C2 = shell.sel, shell.c1, shell.c2
    local function Say(m) DEFAULT_CHAT_FRAME:AddMessage("|cff3da6ff[DC]|r " .. m) end
    local function Count() local n = 0; for _ in pairs(S.names) do n = n + 1 end; return n end
    local function Selected()
        local list = {}
        for _, name in ipairs(S.order) do if S.names[name] then list[#list + 1] = S.names[name] end end
        return list
    end
    local function Add(d) if not S.names[d.name] then S.order[#S.order + 1] = d.name end; S.names[d.name] = d end
    local function Clear() wipe(S.names); wipe(S.order) end
    local function Members(list)
        local out = {}
        for _, d in ipairs(list) do out[#out + 1] = { name = d.name, cls = CLASS_BY_ID[d.cls], level = d.level } end
        return out
    end

    -- the bar under the list (right of background / - / +)
    local bar = CreateFrame("Frame", nil, col5)
    bar:SetPoint("BOTTOMRIGHT", col5, "BOTTOMRIGHT", -8, 8)
    bar:SetSize(206, 22)
    bar:Hide()
    local count = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal"); Crisp(count, 12)
    count:SetPoint("LEFT", bar, "LEFT", 0, 0)
    count:SetTextColor(0.91, 0.77, 0.42)
    local bClear = SmallButton(bar, "Clear the selection", 40); bClear:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
    DCBind(bClear, "Clear (short)")
    local bGroup = SmallButton(bar, "Add to group", 60); bGroup:SetPoint("RIGHT", bClear, "LEFT", -3, 0)
    local bInvite = SmallButton(bar, "Invite", 46); bInvite:SetPoint("RIGHT", bGroup, "LEFT", -3, 0)

    local function Paint()
        if S.cat ~= rosterCat then Clear(); S.cat = rosterCat end
        for _, r in ipairs(rosterRows) do
            local d = r.data
            local on = d and S.names[d.name] ~= nil
            if r.chk then
                if d and not d.npc then r.chk:Show(); r.chk:SetChecked(on and true or false) else r.chk:Hide() end
            end
            if r.selbg then if on then r.selbg:Show() else r.selbg:Hide() end end
        end
        local n = Count()
        if n > 0 then count:SetText(string.format(DCL("%d selected"), n)); bar:Show() else bar:Hide() end
    end
    S.Paint = Paint

    -- invite several, one every 0.6 s (a full party turns into a raid first)
    local q, queue, qacc = CreateFrame("Frame"), {}, 0
    q:Hide()
    q:SetScript("OnUpdate", function(self, elapsed)
        qacc = qacc + (elapsed or 0)
        if qacc < 0.6 then return end
        qacc = 0
        local d = queue[1]
        if not d then self:Hide(); return end
        if GetNumRaidMembers() == 0 and GetNumPartyMembers() >= 4 and IsPartyLeader() then ConvertToRaid(); return end
        table.remove(queue, 1)
        if d.mine and not d.online then Chat(".playerbot bot add " .. d.name) else InviteUnit(d.name) end
    end)
    local function InviteAll(list)
        local n = 0
        for _, d in ipairs(list) do if not d.npc and not InGroup(d.name) then queue[#queue + 1] = d; n = n + 1 end end
        if n == 0 then return end
        Say(string.format(DCL("Inviting %d characters..."), n))
        qacc = 0
        q:Show()
    end
    local function AddToGroup(g, list)
        if C2.AddMany then C2.AddMany(g, Members(list)) end
    end
    local function AddToOpenGroup(list)
        if #list == 0 then return end
        local open = C2.open
        if not (open and open.size == C2.size and C2.Visible(open)) then
            C2.Drop(list[1])          -- opens or creates a group of the size on screen, adds the first
            table.remove(list, 1)
        end
        if #list > 0 and C2.open then AddToGroup(C2.open, list) end
    end
    local function NewGroup(size, list)
        local all = C2.Groups()  -- DCUI3D6: this character's list
        local g = { name = string.format(DCL("Favourite group %d"), #all + 1), size = size, members = {}, owner = UnitName("player") }
        table.insert(all, g)
        if not C2.active then C2.SetActive(true) end
        C2.size, C2.open = size, g
        AddToGroup(g, list)
    end

    local function Menu()
        local list = Selected()
        local menu = { { text = string.format(DCL("%d characters selected"), #list), isTitle = true, notCheckable = true } }
        local function add(t) t.notCheckable = true; menu[#menu + 1] = t end
        add({ text = string.format(DCL("Invite the %d selected"), #list), func = function() InviteAll(Selected()) end })
        local groups = {}
        for _, g in ipairs(C2.Groups()) do  -- DCUI3D6
            if #groups < 10 then groups[#groups + 1] = g end
        end
        if #groups > 0 then
            menu[#menu + 1] = { text = DCL("Add to favourite group:"), isTitle = true, notCheckable = true }
            for _, g in ipairs(groups) do
                add({ text = string.format("  %s  |cff999999%d/%d|r", g.name, #g.members, g.size), func = function() AddToGroup(g, Selected()) end })
            end
        end
        menu[#menu + 1] = { text = DCL("New favourite group:"), isTitle = true, notCheckable = true }
        for _, n in ipairs({ 5, 10, 20, 25, 40 }) do
            add({ text = "  " .. string.format(DCL("%d players"), n), func = function() NewGroup(n, Selected()) end })
        end
        add({ text = DCL("Clear the selection"), func = function() Clear(); Paint() end })
        add({ text = CANCEL, func = function() CloseDropDownMenus() end })
        EasyMenu(menu, menuFrame, "cursor", 0, 0, "MENU")
    end
    bInvite:SetScript("OnClick", function() InviteAll(Selected()) end)
    bGroup:SetScript("OnClick", Menu)
    bClear:SetScript("OnClick", function() Clear(); Paint() end)

    for i, r in ipairs(rosterRows) do
        r.icon:ClearAllPoints(); r.icon:SetPoint("LEFT", r, "LEFT", 21, 0)
        r.chk = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
        r.chk:SetSize(20, 20); r.chk:SetPoint("LEFT", r, "LEFT", 0, 0)
        r.chk:SetScript("OnClick", function(self)
            local d = r.data
            if d and not d.npc then
                if S.names[d.name] then S.names[d.name] = nil else Add(d) end
                S.anchor = i
            end
            Paint()
        end)
        r.selbg = r:CreateTexture(nil, "BORDER"); r.selbg:SetAllPoints(); r.selbg:SetTexture(0.20, 0.40, 0.70, 0.35); r.selbg:Hide()
        local origClick = r:GetScript("OnClick")
        r:SetScript("OnClick", function(self, button)
            local d = self.data
            if not d then return end
            if button == "RightButton" then
                if S.names[d.name] and Count() > 1 then Menu() elseif origClick then origClick(self, button) end
                return
            end
            if d.npc then return end
            if IsControlKeyDown() then
                if S.names[d.name] then S.names[d.name] = nil else Add(d) end
                S.anchor = i
            elseif IsShiftKeyDown() and S.anchor then
                -- like Windows: Shift+click = exactly the rows from the last clicked one to this one
                Clear()
                local a, b = math.min(S.anchor, i), math.max(S.anchor, i)
                for k = a, b do
                    local x = rosterRows[k] and rosterRows[k]:IsShown() and rosterRows[k].data
                    if x and not x.npc then Add(x) end
                end
            else
                local only = S.names[d.name] and Count() == 1
                Clear()
                if not only then Add(d) end
                S.anchor = i
            end
            Paint()
        end)
        local origStart, origStop = r:GetScript("OnDragStart"), r:GetScript("OnDragStop")
        r:SetScript("OnDragStart", function(self)
            local d = self.data
            if d and S.names[d.name] and Count() > 1 then
                S.dragging = true
                GameTooltip:Hide()
                C1.ghost.icon:SetTexture("Interface\\Icons\\INV_Misc_GroupLooking"); C1.ghost.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                C1.ghost.text:SetText(string.format(DCL("%d characters"), Count()))
                C1.ghost.over = nil
                C1.ghost:Show()
            elseif origStart then
                origStart(self)
            end
        end)
        r:SetScript("OnDragStop", function(self)
            if S.dragging then
                S.dragging = nil
                C1.ghost:Hide(); C1.Border(false)
                if MouseIsOver(col4) then
                    if C2.active then AddToOpenGroup(Selected()) else InviteAll(Selected()) end
                end
            elseif origStop then
                origStop(self)
            end
        end)
        r:HookScript("OnEnter", function(self)
            if self.data and not self.data.npc then
                GameTooltip:AddLine(DCL("Ctrl+click: pick several; Shift+click: a range"), 0.7, 0.7, 0.7)
                GameTooltip:Show()
            end
        end)
    end
    local orig = DCShellRenderRoster
    DCShellRenderRoster = function(...)
        orig(...)
        Paint()
    end
    end)()

    -- ------------------------------------------------------------ faction badges (RebornWOW DCUI3D8)
    -- A small Alliance / Horde banner after each name in the invite list (every category)
    -- and in "My party", so a mixed-faction party reads at a glance. Own function (the
    -- main chunk's 200-local limit).
    ;(function()
    local FACTION = {
        [0] = { "Interface\\Icons\\INV_BannerPVP_02", "Alliance" },
        [1] = { "Interface\\Icons\\INV_BannerPVP_01", "Horde" },
    }
    local function Badge(parent, anchor)
        local t = parent:CreateTexture(nil, "OVERLAY")
        t:SetSize(14, 14)
        t:SetPoint("LEFT", anchor, "RIGHT", 4, 0)
        t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        t:Hide()
        return t
    end
    local function Set(t, team)
        local f = team and FACTION[team]
        if f then t:SetTexture(f[1]); t:Show() else t:Hide() end
    end
    for _, r in ipairs(rosterRows) do r.fac = Badge(r, r.name) end
    for _, r in ipairs(rrow) do r.fac = Badge(r, r.name) end
    local origRoster = DCShellRenderRoster
    DCShellRenderRoster = function(...)
        origRoster(...)
        for _, r in ipairs(rosterRows) do Set(r.fac, r:IsShown() and r.data and r.data.team) end
    end
    local origParty = RefreshParty
    RefreshParty = function(...)
        origParty(...)
        for _, r in ipairs(rrow) do
            local team
            if r:IsShown() and r.unit and UnitExists(r.unit) then
                local fg = UnitFactionGroup(r.unit)
                team = (fg == "Alliance" and 0) or (fg == "Horde" and 1) or nil
            end
            Set(r.fac, team)
        end
    end
    end)()

    -- ------------------------------------------------------------ R3 details (RebornWOW DCUI3D9)
    -- Closer to the approved mock-up: a coloured role chip at the start of each "My party"
    -- row (Me / T / H / D), coloured plates under the dungeon list's status tags, and
    -- /dcskin to report the flat-button skin on a client whose buttons stay red. Own
    -- function (the main chunk's 200-local limit).
    ;(function()
    local CHIP = { me = { "Me (chip)", 0.55, 0.43, 0.16, "Me" }, Tank = { "Tank (short)", 0.22, 0.40, 0.75, "T" },
                   Heal = { "Healer (short)", 0.15, 0.52, 0.26, "H" }, DPS = { "DPS (chip)", 0.62, 0.30, 0.15, "D" } }
    for _, r in ipairs(rrow) do
        r.chip = r:CreateTexture(nil, "ARTWORK"); r.chip:SetSize(20, 16); r.chip:SetPoint("LEFT", r, "LEFT", 3, 0)
        r.chipText = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); Crisp(r.chipText, 11)
        r.chipText:SetPoint("CENTER", r.chip, "CENTER", 0, 0)
        r.icon:ClearAllPoints(); r.icon:SetPoint("LEFT", r, "LEFT", 27, 0)
    end
    local origParty = RefreshParty
    RefreshParty = function(...)
        origParty(...)
        for _, r in ipairs(rrow) do
            local c
            if r:IsShown() and r.unit and UnitExists(r.unit) then
                c = UnitIsUnit(r.unit, "player") and CHIP.me or CHIP[RoleOf(r.unit) or ""]
            end
            if c then
                r.chip:SetTexture(c[2], c[3], c[4], 0.85); r.chip:Show()
                local t = DCL(c[1])
                r.chipText:SetText(t ~= c[1] and t or c[5]); r.chipText:Show()  -- English: a plain letter
            else
                r.chip:Hide(); r.chipText:Hide()
            end
        end
    end

    -- status tags of the dungeon list on a coloured plate
    for _, r in ipairs(dlRows) do
        r.tagbg = r:CreateTexture(nil, "ARTWORK")
        r.tagbg:SetHeight(16)
        r.tagbg:SetPoint("RIGHT", r.tag, "RIGHT", 4, 0)
        r.tagbg:Hide()
    end
    local origDL = DCShellRenderDungeons
    DCShellRenderDungeons = function(...)
        origDL(...)
        for _, r in ipairs(dlRows) do
            local d = r:IsShown() and r.data
            if d and not d.header then
                local res = LastTest(d.tokens)
                local c = (not d.supported and { 0.35, 0.38, 0.42, 0.30 }) or (res == "success" and { 0.15, 0.45, 0.22, 0.50 })
                          or (res and { 0.58, 0.15, 0.13, 0.50 }) or { 0.45, 0.35, 0.10, 0.45 }
                r.tagbg:SetTexture(c[1], c[2], c[3], c[4])
                r.tagbg:SetWidth((tonumber(r.tag:GetStringWidth()) or 30) + 8)
                r.tagbg:Show()
            else
                r.tagbg:Hide()
            end
        end
    end

    -- /dcskin: what the flat-button skin found
    SLASH_DCSKIN1 = "/dcskin"
    SlashCmdList["DCSKIN"] = function()
        local found, skinned = 0, 0
        local function walk(f, depth)
            if not f or depth > 8 then return end
            if f.GetObjectType and f:GetObjectType() == "Button" then
                if shell.PanelTextures and #shell.PanelTextures(f) > 0 then found = found + 1 end
                if f.dcSkin then skinned = skinned + 1 end
            end
            for _, k in ipairs({ f:GetChildren() }) do walk(k, depth + 1) end
        end
        walk(frame, 0)
        local paths = {}
        local n = onBtn.GetNormalTexture and onBtn:GetNormalTexture()
        paths[#paths + 1] = "normal=" .. tostring(n and n:GetTexture())
        for _, rg in ipairs({ onBtn:GetRegions() }) do
            if rg.GetObjectType and rg:GetObjectType() == "Texture" then paths[#paths + 1] = tostring(rg:GetTexture()) end
        end
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff3da6ff[DC]|r skin: %d red buttons left to convert, %d converted; On button textures: %s",
            found - skinned < 0 and 0 or found - skinned, skinned, table.concat(paths, " | ")))
    end
    end)()

    -- ------------------------------------------------------------ teammate joins from the panel (RebornWOW DCSB2B)
    -- When the party's clear asks you (SBASK: a real teammate, the run already going),
    -- the full panel opens and the Auto-play row flashes until you pick a role there
    -- (or Manual). Picking a role is all it takes: the AI plays your character with the
    -- party and the panel shows the running clear -- no Start needed. Replaces the
    -- DCSB2A popup. Own function (the main chunk's 200-local limit).
    ;(function()
    if not (selfBotUI and selfBotUI.label and selfBotUI.btns[4]) then return end
    local glow = CreateFrame("Frame", nil, frame)
    glow:SetPoint("LEFT", selfBotUI.label, "LEFT", -6, 0)
    glow:SetPoint("RIGHT", selfBotUI.btns[#selfBotUI.btns], "RIGHT", 5, 0)
    glow:SetHeight(34)
    glow:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
    glow:SetBackdropBorderColor(1, 0.82, 0, 1)
    local fill = glow:CreateTexture(nil, "BACKGROUND")
    fill:SetAllPoints(glow); fill:SetTexture(1, 0.82, 0, 0.16)
    glow:Hide()
    local t, left = 0, 0
    glow:SetScript("OnUpdate", function(self, e)
        t = t + e; left = left - e
        self:SetAlpha(0.25 + 0.75 * math.abs(math.sin(t * 3)))
        if left <= 0 then self:Hide() end
    end)
    local function Flash(on)
        if on then t = 0; left = 120; glow:Show() else glow:Hide() end
    end
    shell.sbFlash = Flash
    for i = 1, 4 do
        selfBotUI.btns[i]:HookScript("OnClick", function()
            Flash(false)
            -- the server answers the role first, then the run (from the party's tank)
            if i < 4 then SendDcCommand("status", "addon") end
        end)
    end
    local ROLE = { tank = "Tank", heal = "Heal", dps = "DPS" }
    DCShowSelfBotAsk = function(role, tank)
        DungeonClearDB.tinyMode = false
        UpdateLayout()
        frame:Show()
        SendDcCommand("status", "addon")
        Flash(true)
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[DC] " .. string.format(DCL("Your party is running dungeon clear (tank: %s). Pick a role on the flashing Auto-play row of the panel and the AI plays your character with the party (suggested: %s); pick Manual to play yourself."),
            tank or "?", DCL(ROLE[role or ""] or "DPS")) .. "|r")
    end
    end)()

    -- ------------------------------------------------------------ party member state (RebornWOW DCUI3E1)
    -- Design doc §16.4: each "My party" row gets a thin health bar and power bar along its
    -- bottom, and "far" (out of 40 yd) / "not nearby" (another map or instance copy, or
    -- simply far away) before the level. Refreshed twice a second while the column is
    -- shown. Own function (the main chunk's 200-local limit).
    ;(function()
    local POWER = { [0] = { 0.20, 0.45, 1.00 }, [1] = { 0.90, 0.15, 0.15 }, [2] = { 1.00, 0.50, 0.25 },
                    [3] = { 1.00, 0.85, 0.10 }, [6] = { 0.00, 0.82, 1.00 } }
    local function Bar(r, y, h)
        local bg = r:CreateTexture(nil, "BORDER")
        bg:SetHeight(h); bg:SetTexture(0, 0, 0, 0.55)
        -- DCUI3E3: two anchors on two lines (an inline comment had swallowed the second)
        bg:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 50, y)  -- after the chip and class icon
        bg:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -4, y)
        local fg = r:CreateTexture(nil, "ARTWORK")
        fg:SetHeight(h); fg:SetPoint("BOTTOMLEFT", bg, "BOTTOMLEFT", 0, 0)
        bg:Hide(); fg:Hide()
        return bg, fg
    end
    for _, r in ipairs(rrow) do
        r.hpBg, r.hp = Bar(r, 3, 3)  -- DCUI3E3: health 3 px
        r.mpBg, r.mp = Bar(r, 0, 2)
        r.range = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); Crisp(r.range, 11)
        r.range:SetPoint("RIGHT", r.info, "LEFT", -4, 0)
    end
    local function Fill(bg, fg, cur, max, c)
        -- DCUI3E4: GetWidth() on a two-anchor texture is not the laid-out width on this
        -- client; use the bar's edges, else the row (minus chip + icon + margins)
        local w = 0
        local l, rt = bg:GetLeft(), bg:GetRight()
        if l and rt and rt - l > 10 then w = rt - l end
        if w <= 10 then
            local row = bg:GetParent()
            local rl, rr = row and row:GetLeft(), row and row:GetRight()
            if rl and rr and rr - rl > 64 then w = rr - rl - 54 end
        end
        if w <= 10 then w = tonumber((bg:GetWidth())) or 0 end
        if not max or max <= 0 or w <= 0 then bg:Hide(); fg:Hide(); return end
        local f = math.max(0, math.min(1, (cur or 0) / max))
        bg:Show()
        if f <= 0 then fg:Hide() return end
        fg:SetWidth(math.max(1, w * f)); fg:SetTexture(c[1], c[2], c[3], 0.95); fg:Show()
    end
    local function InRange(u)
        if type(UnitInRange) ~= "function" then return true end
        local ok, v = pcall(UnitInRange, u)
        return not ok or v == 1 or v == true
    end
    local function Update()
        for _, r in ipairs(rrow) do
            local u = r.unit
            if r:IsShown() and u and UnitExists(u) and UnitIsConnected(u) then
                -- DCUI3E2: one value each -- UnitPowerType also returns a token ("MANA"),
                -- which tonumber() took as its base
                local hp, hpMax = tonumber((UnitHealth(u))) or 0, tonumber((UnitHealthMax(u))) or 0
                local f = hpMax > 0 and hp / hpMax or 0
                Fill(r.hpBg, r.hp, hp, hpMax, f > 0.5 and { 0.15, 0.85, 0.25 } or (f > 0.25 and { 1, 0.75, 0.1 } or { 1, 0.2, 0.15 }))
                Fill(r.mpBg, r.mp, tonumber((UnitPower(u))) or 0, tonumber((UnitPowerMax(u))) or 0, POWER[tonumber((UnitPowerType(u))) or 0] or POWER[0])
                local tag = ""
                if not UnitIsUnit(u, "player") then
                    if not UnitIsVisible(u) then tag = "|cff9a9a9a" .. DCL("not nearby") .. "|r"
                    elseif not InRange(u) then tag = "|cffffb030" .. DCL("far") .. "|r" end
                end
                r.range:SetText(tag)
            else
                r.hpBg:Hide(); r.hp:Hide(); r.mpBg:Hide(); r.mp:Hide(); r.range:SetText("")
            end
        end
    end
    local origParty = RefreshParty
    RefreshParty = function(...)
        origParty(...)
        Update()
    end
    local tick = CreateFrame("Frame", nil, col4)
    local acc = 0
    tick:SetScript("OnUpdate", function(_, e)
        acc = acc + (e or 0)
        if acc < 0.5 then return end
        acc = 0
        Update()
    end)
    shell.partyState = Update
    end)()

    -- ------------------------------------------------------------ whole party to the entrance (RebornWOW DCGM2A)
    -- Dungeon list right-click: the GM teleports to the entrance (.go xyz) and, once
    -- arrived -- a loading screen or zone change, then 1.5 s; or 4 s when nothing
    -- changes (already in that sub-zone) -- summons the whole party there with
    -- .groupsummon <own name>. Gives up after 60 s. Own function (200-local limit).
    ;(function()
    local pend
    local w = CreateFrame("Frame", nil, UIParent)
    for _, e in ipairs({ "PLAYER_LEAVING_WORLD", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS" }) do
        pcall(w.RegisterEvent, w, e)
    end
    w:SetScript("OnEvent", function(_, ev)
        if not pend then return end
        if ev == "PLAYER_LEAVING_WORLD" then pend.loading = true return end
        pend.loading = false; pend.moved = true; pend.t = 0
    end)
    w:SetScript("OnUpdate", function(_, e)
        if not pend then return end
        e = e or 0
        pend.total = pend.total + e
        if pend.total > 60 then pend = nil; return end
        if pend.loading then return end
        pend.t = pend.t + e
        if (pend.moved and pend.t >= 1.5) or (not pend.moved and pend.t >= 4) then
            pend = nil
            local me = UnitName("player")
            if me then
                SendChatMessage(".groupsummon " .. me, "SAY")
                DEFAULT_CHAT_FRAME:AddMessage("|cff3da6ff[DC] " .. DCL("Summoning the party to the entrance.") .. "|r")
            end
        end
    end)
    shell.InGroup = function()
        return (GetNumPartyMembers() or 0) > 0 or (GetNumRaidMembers() or 0) > 0
    end
    shell.groupGo = function(d)
        if not shell.InGroup() then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff3333[DC] " .. DCL("You are not in a party.") .. "|r")
            return
        end
        pend = { t = 0, total = 0 }
        SendChatMessage(string.format(".go xyz %.1f %.1f %.1f %d", d.x, d.y, d.z, d.mapId), "SAY")
        DEFAULT_CHAT_FRAME:AddMessage("|cff3da6ff[DC] " .. DCL("Teleporting to the entrance; the party follows when you arrive.") .. "|r")
    end
    end)()

    -- ------------------------------------------------------------ pop-ups on top (RebornWOW DCUI3E3)
    -- Every DungeonClear pop-up opened behind the big panel (same DIALOG strata, the
    -- panel's children higher). They sit one strata up, toplevel, raised on show. Some are
    -- created on first use, so a light watcher applies it as they appear.
    ;(function()
    local POPUPS = { "DungeonClearTestFrame", "DungeonClearTestListFrame", "DungeonClearQueueFrame",
                     "DungeonClearGpsFrame", "DungeonClearChatCopyFrame", "DungeonClearCorpseRunFrame",
                     "DungeonClearPickerFrame", "DungeonClearRunStatsFrame", "DungeonClearSelfBotAsk",
                     "DungeonClearBotInspectFrame" }
    local function Lift(f)
        if not f or f.dcLifted then return end
        f.dcLifted = true
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        if f.SetToplevel then f:SetToplevel(true) end
        f:HookScript("OnShow", function(self) self:Raise() end)
        if f:IsShown() then f:Raise() end
    end
    local w = CreateFrame("Frame", nil, UIParent)
    local acc, left = 0.5, #POPUPS
    w:SetScript("OnUpdate", function(self, e)
        acc = acc + (e or 0)
        if acc < 0.5 then return end
        acc = 0
        left = 0
        for _, n in ipairs(POPUPS) do
            local f = _G[n]
            if f then Lift(f) else left = left + 1 end
        end
        if left == 0 then self:SetScript("OnUpdate", nil) end
    end)
    -- RebornWOW DCTEST10E: the game's confirm dialogs that DungeonClear opens go one strata
    -- up as well (they stayed at DIALOG, behind the lifted panel windows), back on close
    local function LiftConfirm(which)
        if type(which) ~= "string" or which:sub(1, 13) ~= "DUNGEONCLEAR_" then return end
        for i = 1, (STATICPOPUP_NUMDIALOGS or 4) do
            local d = _G["StaticPopup" .. i]
            if d and d:IsShown() and d.which == which then
                if not d.dcStrataHook then
                    d.dcStrataHook = true
                    d:HookScript("OnHide", function(self)
                        if self.dcLiftedUp then self.dcLiftedUp = nil; self:SetFrameStrata("DIALOG") end
                    end)
                end
                d.dcLiftedUp = true
                d:SetFrameStrata("FULLSCREEN_DIALOG")
                d:Raise()
            end
        end
    end
    hooksecurefunc("StaticPopup_Show", LiftConfirm)
    end)()

    -- ------------------------------------------------------------ panel modes (RebornWOW DCUI4A)
    -- [Clear] is the panel as it was. [Test] widens the panel and docks the bot test
    -- window (centre) and the run list (left: runs; right: party, gear / stats) in it, over
    -- a cover painted with the same background so the Clear controls stay out of sight.
    -- [Field] is coming (DCFIELD1A). The mode is kept per account.
    ;(function()
    local TL, TC, TR = 392, 372, 392
    local TEST_W = PAD + TL + GAP + TC + GAP + TR + PAD      -- 1192
    local view = CreateFrame("Frame", "DungeonClearTestView", shell)
    view:SetPoint("TOPLEFT", shell, "TOPLEFT", 4, -(PAD + 40))
    view:SetPoint("BOTTOMRIGHT", shell, "BOTTOMRIGHT", -4, 4)
    view:EnableMouse(true)                                    -- clicks never reach the Clear controls
    view:Hide()
    local cover = view:CreateTexture(nil, "BACKGROUND")
    cover:SetAllPoints(view); cover:SetTexture(0.05, 0.07, 0.10, 0.98)
    local paint = view:CreateTexture(nil, "BORDER")
    paint:SetAllPoints(view)
    local hosts = {}
    for i, w in ipairs({ TL, TC, TR }) do
        local h = CreateFrame("Frame", nil, view)
        h:SetWidth(w)
        h:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                        tile = true, tileSize = 12, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        h:SetBackdropColor(0.02, 0.03, 0.05, 0.55)
        h:SetBackdropBorderColor(0.20, 0.23, 0.30, 0.9)
        hosts[i] = h
    end
    local function Place()
        local x = PAD - 4
        for i, w in ipairs({ TL, TC, TR }) do
            local h = hosts[i]
            h:ClearAllPoints()
            h:SetPoint("TOPLEFT", view, "TOPLEFT", x, 0)
            h:SetPoint("BOTTOMLEFT", view, "BOTTOMLEFT", x, PAD - 4)
            x = x + w + GAP
        end
    end
    Place()
    -- the cover shows the part of the shell's painting it hides
    local function Paint()
        local tex = art:IsShown() and art:GetTexture()
        if not tex then paint:Hide() return end
        local W, H = shell:GetWidth() or TEST_W, shell:GetHeight() or SHELL_H
        local f = math.min(1, (W / H) / (2048 / 984))
        local u0, u1, v1 = (1 - f) / 2, (1 + f) / 2, 984 / 1024
        art:SetTexCoord(u0, u1, 0, v1)
        local top = (PAD + 40 - 4) / (H - 8)
        paint:SetTexture(tex)
        paint:SetTexCoord(u0, u1, top * v1, v1)
        paint:Show()
    end
    local function Mode() return DungeonClearDB.panelMode == "test" and "test" or "clear" end
    local function PaintButtons()
        for m, b in pairs(shell.modeBtns or {}) do
            if m == Mode() then b:LockHighlight() else b:UnlockHighlight() end
            if m == "field" then b:Disable() end
        end
    end
    -- re-applied after every layout; `off` forces the Clear look (tiny mode)
    function shell.ApplyMode(off)
        local test = not off and Mode() == "test" and not DungeonClearDB.tinyMode and DCTestDock ~= nil
        if test then
            local h = shell:GetHeight() or SHELL_H
            shell:SetWidth(TEST_W)
            frame:SetClampRectInsets(-CENTRE_X, TEST_W - CENTRE_X - WC, PAD + 40, -(h - frame:GetHeight() - PAD - 40))
            view:SetFrameLevel(frame:GetFrameLevel() + 30)
            view:Show()
            Paint()
            DCTestDock(hosts[1], hosts[2], hosts[3], view)
            if shell.panelGrip then  -- DCTEST9A: the scale triangle above the docked windows
                shell.panelGrip:SetFrameStrata(view:GetFrameStrata())
                shell.panelGrip:SetFrameLevel(view:GetFrameLevel() + 20)
                shell.panelGrip:Show()
            end
        else
            if DCTestUndock then DCTestUndock() end
            view:Hide()
            if not DungeonClearDB.tinyMode and shell:IsShown() then shell:SetWidth(SHELL_W) end
            local f = math.min(1, (SHELL_W / SHELL_H) / (2048 / 984))
            art:SetTexCoord((1 - f) / 2, (1 + f) / 2, 0, 984 / 1024)
        end
        PaintButtons()
    end
    function DCShellSetMode(m)
        if m == "field" then return end
        local want = (m == "test") and "test" or nil
        if DungeonClearDB.panelMode == want then return end
        DungeonClearDB.panelMode = want
        if DungeonClearDB.tinyMode then DungeonClearDB.tinyMode = false; UpdateLayout() end
        if not frame:IsShown() then frame:Show() end
        if DCShellLayout then DCShellLayout() else shell.ApplyMode() end  -- clamp + mode
    end
    -- the top bar's Test tool switches modes (tiny mode keeps the floating window)
    testBtn:SetScript("OnClick", function()
        if DungeonClearDB.tinyMode then
            local tf = _G.DungeonClearTestFrame
            if tf then if tf:IsShown() then tf:Hide() else tf:Show() end end
            return
        end
        DCShellSetMode(Mode() == "test" and "clear" or "test")
    end)
    for m, b in pairs(shell.modeBtns or {}) do
        b:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:AddLine(DCL(m == "clear" and "Clear mode" or (m == "test" and "Test mode" or "Field mode")))
            GameTooltip:AddLine(DCL(m == "clear" and "Run dungeon clear with your party." or
                (m == "test" and "Bot test runs (GM): settings, the run list and the test party in this panel." or
                "Levelling, quests and gathering for you and your bots -- coming next.")), 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:HookScript("OnLeave", function() GameTooltip:Hide() end)
    end
    frame:HookScript("OnHide", function() if DCTestUndock and DCTestDocked and DCTestDocked() then DCTestUndock() end end)
    frame:HookScript("OnShow", function() if shell:IsShown() then shell.ApplyMode() end end)
    PaintButtons()
    -- ------------------------------------------------------------ test party notice (RebornWOW DCTEST10B)
    -- In Clear mode, a party that belongs to a running test (you joined it, or were left
    -- in it) is not "your" party: the run controls are covered by a notice with a way to
    -- Test mode, and the party column reads "Test party". The server says which test run
    -- the player's party belongs to on the 5 s tier poll (TIER line, 4th field).
    do
        local testRun
        local cover = CreateFrame("Frame", nil, frame)
        cover:SetPoint("TOPLEFT", onBtn, "TOPLEFT", -3, 3)
        cover:SetPoint("BOTTOMRIGHT", pauseBtn or skipBtn, "BOTTOMRIGHT", 3, -3)
        cover:SetFrameLevel(onBtn:GetFrameLevel() + 6)
        cover:EnableMouse(true)                       -- clicks never reach the run buttons
        cover:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\Buttons\\WHITE8X8",
                            edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        cover:SetBackdropColor(0.05, 0.06, 0.09, 0.94)
        cover:SetBackdropBorderColor(0.91, 0.77, 0.42, 0.8)
        local txt = cover:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        txt:SetPoint("LEFT", cover, "LEFT", 8, 0)
        DCBind(txt, "Test party -- controlled by the test")
        local go = SmallButton(cover, "Test mode", 64)
        go:SetPoint("RIGHT", cover, "RIGHT", -4, 0)
        go:SetScript("OnClick", function() DCShellSetMode("test") end)
        cover:Hide()
        local function Paint()
            local inTest = testRun ~= nil and Mode() ~= "test" and not DungeonClearDB.tinyMode
            if inTest then cover:Show() else cover:Hide() end
            DCBind(col4.title, testRun and "Test party" or "My party")
        end
        local ev = CreateFrame("Frame", nil, frame)
        ev:RegisterEvent("CHAT_MSG_ADDON")
        ev:SetScript("OnEvent", function(_, _, prefix, msg)
            if prefix ~= "DC" or type(msg) ~= "string" or msg:sub(1, 5) ~= "TIER\t" then return end
            local _, _, _, run = strsplit("\t", msg)
            testRun = (run and run ~= "" and run ~= "-") and run or nil
            if shell.testAutoRow then  -- DCGM1C3: no party, nothing to auto-play
                if testRun then shell.testAutoRow:Show() else shell.testAutoRow:Hide() end
            end
            Paint()
        end)
        local origApply = shell.ApplyMode
        shell.ApplyMode = function(...) origApply(...); Paint() end
    end
    -- ------------------------------------------------------------ Test mode auto-play row (RebornWOW DCTEST9E)
    -- Joined to a test party ("Join" / "Join + god"), the auto-play question used to jump
    -- to the Clear panel's row. Test mode has its own row at the right column's foot: the
    -- same commands, the same highlight, and it is the one that flashes in Test mode.
    do
        local hostR = hosts[3]
        local row = CreateFrame("Frame", nil, hostR)
        shell.testAutoRow = row  -- DCGM1C3: shown only while you are in a test party
        row:Hide()
        row:SetPoint("BOTTOMLEFT", hostR, "BOTTOMLEFT", 8, 8)
        row:SetPoint("BOTTOMRIGHT", hostR, "BOTTOMRIGHT", -8, 8)
        row:SetHeight(28)
        local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("LEFT", row, "LEFT", 4, 0)
        DCBind(label, "Auto-play:")
        local btns, prev = {}, label
        for _, seg in ipairs(SELFBOT_SEGS) do
            local b = SmallButton(row, seg.label, 54)
            b:SetPoint("LEFT", prev, "RIGHT", prev == label and 6 or 2, 0)
            b:SetScript("OnClick", function()
                SendDcCommand("selfbot", seg.key)
                if seg.key ~= "off" then SendDcCommand("status", "addon") end
                if row.glow then row.glow:Hide() end
            end)
            b:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(DCL(seg.label)); GameTooltip:AddLine(DCL(seg.tip), 1, 1, 1, true); GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
            b.dcKey = seg.key
            btns[#btns + 1] = b
            prev = b
        end
        local gm = SmallButton(row, "GM", 34)
        gm:SetPoint("LEFT", prev, "RIGHT", 2, 0)
        gm:SetScript("OnClick", function() if DCMyPartyMenu then DCMyPartyMenu() end end)
        gm.dcKindPref = "gm"
        -- highlight follows the server's SELFBOT state, like the Clear row
        local function Paint()
            for _, b in ipairs(btns) do
                local on = (b.dcKey == "off" and selfBotUI.role == nil) or b.dcKey == selfBotUI.role
                if on then b:LockHighlight() else b:UnlockHighlight() end
            end
        end
        local origUpdate = selfBotUI.update
        selfBotUI.update = function(...) origUpdate(...); Paint() end
        Paint()
        -- the flashing frame
        local glow = CreateFrame("Frame", nil, row)
        glow:SetAllPoints(row)
        glow:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
        glow:SetBackdropBorderColor(1, 0.82, 0, 1)
        local fill = glow:CreateTexture(nil, "BACKGROUND"); fill:SetAllPoints(glow); fill:SetTexture(1, 0.82, 0, 0.16)
        glow:Hide()
        local t, left = 0, 0
        glow:SetScript("OnUpdate", function(self, e)
            t = t + (e or 0); left = left - (e or 0)
            self:SetAlpha(0.25 + 0.75 * math.abs(math.sin(t * 3)))
            if left <= 0 then self:Hide() end
        end)
        row.glow = glow
        -- the question: in Test mode flash this row and stay; otherwise the Clear panel
        local origAsk = DCShowSelfBotAsk
        local ROLE = { tank = "Tank", heal = "Heal", dps = "DPS" }
        DCShowSelfBotAsk = function(role, tank)
            -- DCTEST9F: by the current mode only, never switching it; Test mode opens the
            -- panel (in Test mode) when it is closed or tiny
            if Mode() == "test" then
                if DungeonClearDB.tinyMode then DungeonClearDB.tinyMode = false; UpdateLayout() end
                if not frame:IsShown() then frame:Show() end
                if DCShellLayout and not (DCTestDocked and DCTestDocked()) then DCShellLayout() end
                SendDcCommand("status", "addon")
                row:Show()  -- DCGM1C3: the ask means you are in the party (TIER may lag 5 s)
                t, left = 0, 120; glow:Show()
                DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[DC] " .. string.format(DCL("Your party is running dungeon clear (tank: %s). Pick a role on the flashing Auto-play row of the panel and the AI plays your character with the party (suggested: %s); pick Manual to play yourself."),
                    tank or "?", DCL(ROLE[role or ""] or "DPS")) .. "|r")
                return
            end
            if origAsk then return origAsk(role, tank) end
        end
    end
    end)()

    -- ------------------------------------------------------------ server replies
    local dlPending
    local ev = CreateFrame("Frame", nil, shell)
    ev:RegisterEvent("CHAT_MSG_ADDON")
    for _, e in ipairs({ "PARTY_MEMBERS_CHANGED", "RAID_ROSTER_UPDATE", "UNIT_LEVEL", "PLAYER_ENTERING_WORLD", "UNIT_HEALTH" }) do
        pcall(ev.RegisterEvent, ev, e)
    end
    local partyDirty, rosterDirty = true, false
    ev:SetScript("OnEvent", function(_, event, prefix, msg)
        if event ~= "CHAT_MSG_ADDON" then partyDirty = true; rosterDirty = true; return end
        if prefix ~= "DC" or type(msg) ~= "string" then return end
        local kind = msg:match("^([^\t]+)")
        if (kind == "BI" or kind == "BI_END") and shell.c2 and shell.c2.OnBI then shell.c2.OnBI(kind, msg) end  -- DCUI3C2
        if (kind == "FILL" or kind == "FILL_END") and shell.c3 and shell.c3.OnFill then shell.c3.OnFill(msg) end  -- DCUI3C3
        if kind and kind:sub(1, 2) == "MR" and shell.runs and shell.runs.OnMsg then shell.runs.OnMsg(kind, msg) end  -- DCRUN1A
        -- DCUI3C5: party roles
        if kind == "PR_START" then shell.rolesNew = {}; return end
        if kind == "PR" then
            local _, nm, role = strsplit("\t", msg)
            if shell.rolesNew and nm then shell.rolesNew[nm] = role end
            return
        end
        if kind == "PR_END" then shell.roles = shell.rolesNew or {}; shell.rolesNew = nil; partyDirty = true; return end
        if (kind == "BI" or kind == "BI_END") and shell.picker and shell.picker.OnBI then shell.picker.OnBI(kind, msg) end  -- DCTEST8A
        if (kind == "RO_START" or kind == "RO" or kind == "RO_END") and shell.rosterOwner == "picker" and shell.picker then
            shell.picker.OnRoster(kind, msg)   -- DCTEST8A: the picker asked, not the invite column
            return
        end
        if kind == "DL_START" then dlPending = {}
        elseif kind == "DL" and dlPending then
            local _, mapId, raid, sizes, level, rec, heroic, exp, name, tokens, x, y, z = strsplit("\t", msg)
            dlPending[#dlPending + 1] = { mapId = tonumber(mapId) or 0, raid = raid == "1", sizes = sizes or "?",
                level = tonumber(level) or 0, rec = tonumber(rec) or 0, heroic = tonumber(heroic) or 0,
                exp = tonumber(exp) or 0, name = DCLDungeon and DCLDungeon(name or "?") or (name or "?"), tokens = (tokens ~= "-" and tokens) or nil,
                supported = tokens ~= nil and tokens ~= "-", x = tonumber(x) or 0, y = tonumber(y) or 0, z = tonumber(z) or 0 }
        elseif kind == "DL_END" and dlPending then
            dlData = dlPending; dlPending = nil
            DCShellRenderDungeons()
        elseif kind == "RO_START" then
            rosterData = {}
        elseif kind == "RO" then
            local _, cat, name, cls, level, race, team, online, mine, extra = strsplit("\t", msg)
            if mine == "1" and name then shell.c1.myChars[name] = true end  -- DCUI3C1
            if cat == rosterCat then
                extra = extra or "-"
                rosterData[#rosterData + 1] = { name = name, cls = tonumber(cls) or 0, level = tonumber(level) or 0,
                    online = online == "1", mine = mine == "1", npc = extra:find("n") ~= nil,
                    friend = extra:find("f") ~= nil, guild = extra:find("g") ~= nil, team = tonumber(team) }  -- team: DCUI3D8
            end
        elseif kind == "RO_END" then
            rosterData.loading = nil
            DCShellRenderRoster()
        elseif kind == "BI" and rosterCat == "favorites" then
            local _, name, cls, level, race, team, online, mine = strsplit("\t", msg)
            if name and IsFav(name) then
                for _, d in ipairs(rosterData) do if d.name == name then return end end
                rosterData[#rosterData + 1] = { name = name, cls = tonumber(cls) or 0, level = tonumber(level) or 0,
                    online = online == "1", mine = mine == "1", team = tonumber(team) }  -- team: DCUI3D8
            end
        elseif kind == "BI_END" and rosterCat == "favorites" then
            rosterData.loading = nil
            DCShellRenderRoster()
        end
    end)
    -- RebornWOW DCUI3B6: a request sent during the loading screen is lost; while the
    -- panel is open, ask again every 3 s until the answer has arrived.
    local retryAcc = 0
    ev:SetScript("OnUpdate", function(_, elapsed)
        retryAcc = retryAcc + (elapsed or 0)
        if retryAcc >= 3 then
            retryAcc = 0
            if shell:IsVisible() then
                if #dlData == 0 then SendDcCommand("dungeons", "", true) end
                if rosterData.loading then RequestRoster() end
            end
        end
        if partyDirty then partyDirty = false; RefreshParty() end
        if rosterDirty then rosterDirty = false; if col5:IsVisible() then DCShellRenderRoster() end end
    end)
    col4:SetScript("OnShow", function() partyDirty = true end)

    -- ------------------------------------------------------------ size buttons
    local function SizeButton(label, delta)
        local b = CreateFrame("Button", nil, col5, "UIPanelButtonTemplate")
        b:SetSize(24, 20)
        b:SetText(label)
        b:SetScript("OnClick", function()
            local s = math.max(SCALE_MIN, math.min(SCALE_MAX, math.floor((Scale() + delta) * 10 + 0.5) / 10))
            DungeonClearDB.panelScale5 = s
            DCShellLayout()
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine(DCL("Panel size"))
            GameTooltip:AddLine(string.format("%.1fx", Scale()), 1, 1, 1); GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return b
    end
    local bigger = SizeButton("+", SCALE_STEP); bigger:SetPoint("TOPRIGHT", col5, "TOPRIGHT", -8, -8)
    local smaller = SizeButton("-", -SCALE_STEP); smaller:SetPoint("RIGHT", bigger, "LEFT", -2, 0)

    -- RebornWOW DCUI3B5: the scale triangle at the WHOLE panel's bottom-right (it used to
    -- be RebornWindowScale's, on the centre window; that addon now leaves this window to
    -- us). Drag = scale the panel with its top-left corner kept still; double-click = the
    -- size that fits the screen.
    local function SetPanelScale(sc, keepSaved)
        sc = math.max(SCALE_MIN, math.min(SCALE_MAX, sc))
        local l, t = shell:GetLeft(), shell:GetTop()
        local eff = shell:GetEffectiveScale()
        if not keepSaved then DungeonClearDB.panelScale5 = sc end
        frame:SetScale(sc)
        if l and t then
            local k = eff / frame:GetEffectiveScale()
            frame:ClearAllPoints()
            frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l * k + CENTRE_X, t * k - PAD - 40)  -- DCUI3D1: top bar
        end
    end
    local function SavePosition()
        local stop = frame:GetScript("OnDragStop")
        if stop then pcall(stop, frame) end
    end
    local grip = CreateFrame("Button", nil, shell)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", shell, "BOTTOMRIGHT", -5, 5)
    grip:SetFrameLevel(shell:GetFrameLevel() + 60)
    shell.panelGrip = grip  -- DCTEST9A: Test mode lifts it over the test view
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT"); GameTooltip:AddLine(DCL("Panel size"), 1, 0.82, 0.3)
        GameTooltip:AddLine(DCL("Drag: scale the whole panel"), 1, 1, 1)
        GameTooltip:AddLine(DCL("Double-click: fit the screen"), 1, 1, 1)
        GameTooltip:AddLine(string.format("%.2fx", Scale()), 0.7, 0.7, 0.7); GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", function() GameTooltip:Hide() end)
    grip:SetScript("OnMouseDown", function(self)
        self.left = shell:GetLeft() * shell:GetEffectiveScale()
        self:SetScript("OnUpdate", function(g)
            local cx = GetCursorPosition()
            local sc = (cx - g.left) / ((tonumber((shell:GetWidth())) or SHELL_W) * UIParent:GetEffectiveScale())  -- DCTEST9A: the width shown (Test mode is wider)
            if math.abs(sc - frame:GetScale()) > 0.005 then SetPanelScale(sc) end
        end)
    end)
    grip:SetScript("OnMouseUp", function(self) self:SetScript("OnUpdate", nil); SavePosition() end)
    grip:SetScript("OnDoubleClick", function()
        DungeonClearDB.panelScale5 = nil
        SetPanelScale(Scale(), true)
        SavePosition()
    end)
    local bgBtn = CreateFrame("Button", nil, col5, "UIPanelButtonTemplate")
    bgBtn:SetSize(64, 20)
    -- RebornWOW DCUI3B7: background / - / + at column 5's bottom-left; its top-right now
    -- holds the window's header buttons (see DCShellLayout).
    bgBtn:SetPoint("BOTTOMLEFT", col5, "BOTTOMLEFT", 10, 10)
    smaller:ClearAllPoints(); smaller:SetPoint("LEFT", bgBtn, "RIGHT", 4, 0)
    bigger:ClearAllPoints(); bigger:SetPoint("LEFT", smaller, "RIGHT", 2, 0)
    local function PaintBgBtn() bgBtn:SetText(DCL("Background") .. " " .. BGS[BgIndex()][1]:gsub("none", "-")) end
    bgBtn:SetScript("OnClick", function(self)
        bgChoice = BGS[BgIndex() % #BGS + 1][1]
        PaintBg(); PaintBgBtn()
        if GameTooltip:IsOwned(self) then self:GetScript("OnEnter")(self) end
    end)
    bgBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine(DCL("Panel background"))
        GameTooltip:AddLine(DCL(BGS[BgIndex()][3]), 1, 1, 1)
        GameTooltip:AddLine(DCL("Click: next picture (A / B / C / none)"), 0.7, 0.7, 0.7); GameTooltip:Show()
    end)
    bgBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    PaintBg(); PaintBgBtn()

    -- ------------------------------------------------------------ layout
    local loaded = false
    function DCShellLayout()
        if DungeonClearDB.tinyMode then
            if shell.ApplyMode then shell.ApplyMode(true) end  -- DCUI4A: tiny = no test dock
            DCShellTargetHeight = nil
            closeBtn:ClearAllPoints(); closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
            -- RebornWOW DCUI3D2: the window's own row layout back
            for _, c in ipairs(shell.cards.list or {}) do c:Hide() end
            pullLabel:ClearAllPoints(); pullLabel:SetPoint("TOPLEFT", onBtn, "BOTTOMLEFT", 2, -14)
            selfBotUI.label:ClearAllPoints(); selfBotUI.label:SetPoint("TOPLEFT", onBtn, "BOTTOMLEFT", 2, -78)
            listLabel:ClearAllPoints(); listLabel:SetPoint("TOPLEFT", onBtn, "BOTTOMLEFT", 0, -108)
            listLabel:SetTextColor(0.24, 0.60, 1.0)
            spectateBtn:ClearAllPoints(); spectateBtn:SetPoint("TOPLEFT", onBtn, "BOTTOMLEFT", 0, -40)
            spectateResetBtn:ClearAllPoints(); spectateResetBtn:SetPoint("TOPRIGHT", pauseBtn, "BOTTOMRIGHT", 0, -40)
            shell:Hide()
            frame:SetScale(1)
            frame:SetBackdropColor(0.03, 0.03, 0.05, 0.90)
            frame:SetBackdropBorderColor(0.20, 0.22, 0.28, 1.0)
            frame:SetClampRectInsets(0, 0, 0, 0)
            return
        end
        frame:SetScale(Scale())
        frame:SetBackdropColor(0, 0, 0, 0)      -- the window is the centre column now
        -- RebornWOW DCUI3D1: the tools (GPS / Test / EN / Tiny / close hang off closeBtn) at the
        -- right end of the top bar; the window's own title row is the top bar's now
        closeBtn:ClearAllPoints(); closeBtn:SetPoint("RIGHT", shell.topbar, "RIGHT", -2, 0)
        header:Hide()
        -- RebornWOW DCUI3D2: three cards -- Run (status + On/Off/Skip/Pause), Strategy (pull,
        -- auto-play), Bosses (the list); spectate on a footer row at the bottom
        statusFrame:ClearAllPoints(); statusFrame:SetPoint("TOP", frame, "TOP", 0, -24)
        if statusFrame.SetBackdropColor then
            statusFrame:SetBackdropColor(0, 0, 0, 0); statusFrame:SetBackdropBorderColor(0, 0, 0, 0)
        end
        pullLabel:ClearAllPoints(); pullLabel:SetPoint("TOPLEFT", onBtn, "BOTTOMLEFT", 4, -36)
        selfBotUI.label:ClearAllPoints(); selfBotUI.label:SetPoint("TOPLEFT", onBtn, "BOTTOMLEFT", 4, -64)
        listLabel:ClearAllPoints(); listLabel:SetPoint("TOPLEFT", onBtn, "BOTTOMLEFT", 2, -100)
        listLabel:SetTextColor(0.91, 0.77, 0.42)
        spectateBtn:ClearAllPoints(); spectateBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 8)
        spectateResetBtn:ClearAllPoints(); spectateResetBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 8)
        for _, c in ipairs(shell.cards.list or {}) do c:Show() end
        if shell.SkinTree then shell.SkinTree(frame) end
        if DCShellTargetHeight ~= SHELL_H - PAD * 2 - 40 then   -- DCUI3B5: boss list to the bottom
            DCShellTargetHeight = SHELL_H - PAD * 2 - 40
            UpdateFrameHeight()
        end
        frame:SetBackdropBorderColor(0, 0, 0, 0)
        local h = math.max(SHELL_H, (frame:GetHeight() or 0) + PAD * 2 + 40)
        shell:ClearAllPoints()
        shell:SetPoint("TOPLEFT", frame, "TOPLEFT", -CENTRE_X, PAD + 40)
        shell:SetSize(SHELL_W, h)
        -- left: dungeons and runs share one place (tabs); right: party (260 high) over invite
        local top, rx = -(PAD + 40), PAD + W1 + GAP + WC + GAP
        for _, c in ipairs({ col1, col2 }) do
            c:ClearAllPoints(); c:SetWidth(W1)
            c:SetPoint("TOPLEFT", shell, "TOPLEFT", PAD, top)
            c:SetPoint("BOTTOMLEFT", shell, "BOTTOMLEFT", PAD, PAD)
        end
        col4:ClearAllPoints(); col4:SetWidth(W4); col4:SetHeight(260)
        col4:SetPoint("TOPLEFT", shell, "TOPLEFT", rx, top)
        col5:ClearAllPoints(); col5:SetWidth(W5)
        col5:SetPoint("TOPLEFT", col4, "BOTTOMLEFT", 0, -GAP)
        col5:SetPoint("BOTTOMLEFT", shell, "BOTTOMLEFT", rx, PAD)
        shell.partyVis = math.floor((260 - 40 - 34) / 26)
        shell.groupVis = math.floor((260 - 36 - 52 - 6) / 25)
        shell.rosterVis = math.max(1, math.floor((h - PAD * 2 - 40 - 260 - GAP - 110 - 34) / 34))
        if shell.ApplyLeftTab then shell.ApplyLeftTab() end
        -- keep the WHOLE panel on screen, not just the centre window
        frame:SetClampRectInsets(-CENTRE_X, SHELL_W - CENTRE_X - WC, PAD + 40, -(h - frame:GetHeight() - PAD - 40))
        shell:Show()
        if shell.ApplyMode then shell.ApplyMode() end  -- DCUI4A
        partyDirty = true
        if not loaded then
            loaded = true
            SendDcCommand("dungeons", "", true)
            RequestRoster()
        end
    end
    frame:HookScript("OnSizeChanged", function()
        if not DungeonClearDB.tinyMode and shell:IsShown() then
            local h = math.max(SHELL_H, (frame:GetHeight() or 0) + PAD * 2 + 40)  -- DCUI3D1: top bar
            if math.abs(shell:GetHeight() - h) > 0.5 then shell:SetHeight(h) end
        end
    end)
    DCLoc.OnChange(function()
        partyDirty = true
        PaintBgBtn()
        if DCShellRenderDungeons then DCShellRenderDungeons() end
        if DCShellRenderRoster then DCShellRenderRoster() end
    end)
end

-- Layout saving on drag stop
frame:SetScript("OnDragStop", function(self)
    self.isMoving = nil
    self:StopMovingOrSizing()
    local point, _, relativePoint, xOfs, yOfs = self:GetPoint()
    DungeonClearDB.point = point
    DungeonClearDB.relativePoint = relativePoint
    DungeonClearDB.xOfs = xOfs
    DungeonClearDB.yOfs = yOfs
end)

-- Event Handling Frame
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
-- Corrective only, for the camera state the addon models from its own commands:
-- the spectator camera takes control of our character away and hands it back, so
-- these let the "Reset Camera" button tell a camera that is still running from
-- one that has already been released (a typed `.dc spectate`, or the server
-- dropping it on its own). Not every server raises them -- see cameraState.
eventFrame:RegisterEvent("PLAYER_CONTROL_LOST")
eventFrame:RegisterEvent("PLAYER_CONTROL_GAINED")

-- Request the boss list from the tank bot. The server's "dungeon bosses" value
-- returns empty (and caches that for ~5s) whenever the bot isn't fully in the
-- dungeon yet, so a single query on zone-change is unreliable. Callers pair this
-- with the empty-list retry below to keep asking until a real list comes back;
-- once populated, the server pushes any further changes on its own.
local function RequestBossList()
    SendDcCommand("bosses", "addon")
end

-- The server is now event-driven: while a clear is running it recomputes the
-- tank's status every world tick and pushes a STATUS packet only when the state
-- changes (entered combat, pulled a boss, a boss died, stalled, looting, party
-- recovered, …), and likewise re-pushes the BOSS list whenever a boss's
-- alive/dead/skipped state or the committed target changes. So we no longer
-- poll for either — STATUS and BOSS arrive on their own the instant they move.
--
-- The one case the push path can't cover is browsing the boss list while DC is
-- OFF: with no clear running there's no server-side pusher, and the bot's
-- "dungeon bosses" value returns empty (cached ~5s) until it's fully zoned into
-- the dungeon. So keep a bounded retry that fires ONLY while the list is still
-- empty — it self-terminates the moment a real list arrives and never becomes a
-- steady poll. RedrawBossList preserves the scroll offset.
local bossEnsureElapsed = 0
local function OnUpdateHandler(self, elap)
    if not frame:IsVisible() then return end
    if #bosses > 0 then return end  -- populated: the server pushes updates from here

    bossEnsureElapsed = bossEnsureElapsed + elap
    if bossEnsureElapsed >= 2.0 then
        bossEnsureElapsed = 0
        local inInstance, instanceType = IsInInstance()
        if inInstance and (instanceType == "party" or instanceType == "raid") then
            RequestBossList()
        end
    end
end
frame:SetScript("OnUpdate", OnUpdateHandler)

-- Addon Messages parsing
local function OnAddonMessage(prefix, message, channel, sender)
    if prefix ~= "DC" then return end
    
    local parts = {}
    local start = 1
    while true do
        local pos = string.find(message, "\t", start)
        if not pos then
            table.insert(parts, string.sub(message, start))
            break
        end
        table.insert(parts, string.sub(message, start, pos - 1))
        start = pos + 1
    end

    if parts[1] == "STATUS" then
        local enabled = parts[2]
        local nextBossEntry = parts[3]
        local nextBossName = parts[4]
        local stallReason = parts[5]
        local skippedCount = parts[6]
        local state = parts[7]
        local detail = parts[8]
        -- Trailing field (index 9): advanced-pull toggle ("1"/"0"). Older servers
        -- omit it; nil reads as off.
        local pullMode = parts[9]
        -- Trailing field (index 10): live Dynamic verdict (0 none / 1 Leeroy /
        -- 2 Advanced). Older servers omit it; nil reads as none.
        local pullDec = parts[10]

        if nextBossName == "None" then nextBossName = nil end
        if stallReason == "" then stallReason = nil end
        if detail == "" then detail = nil end

        UpdateStatusUI(enabled, nextBossName, state, stallReason, detail, pullMode, pullDec)
    elseif parts[1] == "BOSS_START" then
        -- Stage into pendingBosses; the live list is untouched until BOSS_END
        -- so a response that turns out empty (or never finalizes) can't blank
        -- a list that's already showing.
        pendingBosses = {}
    elseif parts[1] == "BOSS" then
        local entry = tonumber(parts[2])
        local index = tonumber(parts[3])
        local name = parts[4]
        local status = parts[5]
        local x = tonumber(parts[6])
        local y = tonumber(parts[7])
        local z = tonumber(parts[8])
        -- Optional trailing field: wing/region label on split maps (e.g.
        -- Maraudon "Orange"/"Purple"/"Pristine Waters"). Empty/absent on
        -- single-wing dungeons. Older servers omit it; nil is fine.
        local wing = parts[9]
        if wing == "" then wing = nil end
        -- Optional trailing field (index 10): folded-event note for an event that
        -- gates this boss (e.g. "Activate the Altar (pending)"). Rendered as a
        -- sub-line under the row. Older servers omit it; nil reads as none.
        local eventNote = parts[10]
        if eventNote == "" then eventNote = nil end

        table.insert(pendingBosses, {
            entry = entry,
            encounterIndex = index,
            eventNote = eventNote,
            -- Arrival order = the server's clear order. Used as the sort
            -- tiebreak so that several anchors sharing one encounterIndex
            -- (e.g. Sunken Temple's six forcefield defenders, all index 0)
            -- keep a stable, server-matching order in the panel — Lua's
            -- table.sort is not stable, so without this they'd shuffle.
            seq = #pendingBosses,
            name = name,
            status = status,
            x = x, y = y, z = z,
            wing = wing
        })
    elseif parts[1] == "BOSS_END" then
        if #pendingBosses > 0 then
            -- A real list arrived: commit it, sorted by encounter index, with
            -- arrival order as a stable tiebreak so same-index anchors keep the
            -- server's clear order (see `seq` above).
            table.sort(pendingBosses, function(a, b)
                if a.encounterIndex ~= b.encounterIndex then
                    return a.encounterIndex < b.encounterIndex
                end
                return (a.seq or 0) < (b.seq or 0)
            end)
            bosses = pendingBosses
            pendingBosses = {}
            RedrawBossList()
        else
            -- Empty response. Never downgrade a good list to empty — that's the
            -- transient-empty case the ensure-loop will retry past. Only redraw
            -- (to show the "Loading" placeholder) if we have nothing yet.
            if #bosses == 0 then
                RedrawBossList()
            end
        end
    elseif parts[1] == "SYNCSTART" then
        if OnSettingsSyncBoundary then OnSettingsSyncBoundary("start") end
    elseif parts[1] == "SETTINGS" then
        -- One player-facing setting's effective value + schema (key, value, min,
        -- max, type, overridden). Renders/refreshes its control in the panel.
        if HandleSettingsLine then HandleSettingsLine(parts) end
    elseif parts[1] == "SPECTATE" then
        -- Server tells us whether the spectator camera is enabled (DungeonClear.
        -- SpectateEnable). Grey out / disable the button when it's off so a click
        -- can't run into a refusal. Sent in answer to our status poll.
        spectateAvailable = (parts[2] ~= "0")
        if ApplySpectateAvailability then ApplySpectateAvailability() end
    elseif parts[1] and (parts[1]:sub(1, 2) == "TR" or parts[1]:sub(1, 2) == "TI") and DCTestOnAddon then
        -- Test-run list / bot gear for the test window (RebornWOW DCTEST2A).
        DCTestOnAddon(parts)
    elseif parts[1] == "RZ" and DCRezOnAddon then
        -- Corpse-run choice (RebornWOW DCRZ2B).
        DCRezOnAddon(parts)
    elseif (parts[1] == "QROW" or parts[1] == "QLISTEND" or parts[1] == "QSTATE") and DCQueueOnAddon then
        -- Continuous-clear list and progress (RebornWOW DCQ1A).
        DCQueueOnAddon(parts)
    elseif parts[1] == "SELFBOT" then
        -- Self-bot state for the auto-play row: "1 <role>" or "0".
        local was = selfBotUI and selfBotUI.role
        local now = nil
        if parts[2] == "1" then
            now = (parts[3] and parts[3] ~= "") and parts[3] or "dps"
        end
        if selfBotUI then
            selfBotUI.role = now
            selfBotUI.update()
        end
        if was ~= now then
            if now then
                local roleText = ({ tank = "Tank", heal = "Heal", dps = "DPS" })[now] or now
                DEFAULT_CHAT_FRAME:AddMessage("|cff3da6ff[DC] " .. DCL("Auto-play on:") .. " " .. DCL(roleText) .. "|r")
            elseif was then
                DEFAULT_CHAT_FRAME:AddMessage("|cff3da6ff[DC] " .. DCL("Auto-play off: you are in control.") .. "|r")
            end
        end
    elseif parts[1] == "SELFBOT_MSG" then
        local kind = parts[2]
        if kind == "fail" then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff3333[DC] " .. DCL("Auto-play could not start:") .. " " .. DCL(parts[3] or "") .. "|r")  -- DCSB2A: translated
        elseif kind == "no-class-ai" then
            DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[DC] " .. DCL("This class has no bot AI yet: your character follows the run, dodges ground effects and attacks, but casts no class spells.") .. "|r")
        elseif kind == "role-unsupported" then
            DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[DC] " .. DCL("This class cannot play that role for the bot AI; it plays by its talents instead.") .. "|r")
        elseif kind == "revoked" then  -- RebornWOW DCSB2A
            DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[DC] " .. DCL("You left the dungeon or the party: auto-play is off, you play your character again.") .. "|r")
        end
    elseif parts[1] == "SBASK" then  -- RebornWOW DCSB2A: the party's clear asks a real teammate
        if DCShowSelfBotAsk then DCShowSelfBotAsk(parts[2], parts[3]) end
    elseif parts[1] == "SYNCEND" then
        if OnSettingsSyncBoundary then OnSettingsSyncBoundary("end") end
    elseif parts[1] == "CHAT" then
        -- Bot announcements routed through addon channel (silent)
        local chatMsg = parts[2] or ""
        DEFAULT_CHAT_FRAME:AddMessage("|cff3da6ff[DC] " .. DCLDetail(chatMsg) .. "|r")
    elseif parts[1] == "ERROR" then
        -- The only error the server hook raises is "no tank bot found", which
        -- our background status/boss polls provoke constantly whenever the tank
        -- bot isn't in the instance with us. While DC is OFF that's expected and
        -- says nothing useful, so it must never reach chat — printing it spammed
        -- the player on every poll. We only act on it during a live clear: if we
        -- still think DC is active, the tank left mid-run, so revert to OFF
        -- (one-shot, since this flips isDCOn false) and say so once.
        if isDCOn then
            UpdateStatusUI("0", nil, "off", nil)
            DEFAULT_CHAT_FRAME:AddMessage(DCL("|cffff3333[DC] Tank bot is no longer in the group \226\128\148 dungeon clear turned off.|r"))
        end
    end
end

-- Event handler
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == AddonName then
            -- Initialize DB defaults if needed
            if DungeonClearDB.tinyMode == nil then DungeonClearDB.tinyMode = false end
            if DungeonClearDB.bossesFolded == nil then DungeonClearDB.bossesFolded = false end
            DungeonClearDB.hideChatSpam = nil -- Clean up legacy saved variable

            -- Per-player setting overrides + the last schema the server told us
            -- about (so the panel can render controls even before a sync lands).
            DungeonClearDB.settings = DungeonClearDB.settings or {}
            DungeonClearDB.schema = DungeonClearDB.schema or {}
            DungeonClearDB.schemaOrder = DungeonClearDB.schemaOrder or {}
            if BuildSettingsFromCache then BuildSettingsFromCache() end

            -- Restore layout
            frame:ClearAllPoints()
            frame:SetPoint(DungeonClearDB.point or "CENTER", UIParent, DungeonClearDB.relativePoint or "CENTER", DungeonClearDB.xOfs or 0, DungeonClearDB.yOfs or 0)
            
            if UpdateLayout then
                UpdateLayout()
            end
            -- Language: saved choice, or the client locale on first run.
            DCLoc.Init()

            -- RebornWOW DCUI3C6: only the tiny bar comes back by itself; the five-column
            -- panel is too big to pop up over the login screens -- open it with the
            -- minimap button or /dc.
            if DungeonClearDB.visible and DungeonClearDB.tinyMode then
                frame:Show()
            else
                frame:Hide()
            end
            
            -- WotLK addon message prefix registration (only needed/exists in 4.1+)
            if RegisterAddonMessagePrefix then
                RegisterAddonMessagePrefix(Prefix)
            end
        end
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, channel, sender = ...
        OnAddonMessage(prefix, message, channel, sender)
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" or event == "GROUP_ROSTER_UPDATE" then
        local inInstance, instanceType = IsInInstance()

        -- Did we cross into a *different* instance since the list was built? If
        -- so, drop the stale boss list now. This re-arms the empty-list ensure
        -- loop (it only retries while #bosses == 0) so it keeps re-requesting
        -- until the new dungeon/raid's list arrives, and paints "Loading..."
        -- meanwhile — instead of showing the previous run's bosses until the
        -- player manually toggles DC on. Covers both walking a dungeon into a
        -- raid and starting a second dungeon without toggling off.
        local newKey = GetInstanceKey()
        if newKey ~= currentInstanceKey then
            currentInstanceKey = newKey
            bosses = {}
            pendingBosses = {}
            bossEnsureElapsed = 0
            RedrawBossList()
        end

        if inInstance and (instanceType == "party" or instanceType == "raid") then
            -- Auto-query bosses list when entering dungeon/raid
            -- Small delay to ensure party is fully loaded on the server
            local delayFrame = CreateFrame("Frame")
            local delayElapsed = 0
            delayFrame:SetScript("OnUpdate", function(sf, elap)
                delayElapsed = delayElapsed + elap
                if delayElapsed >= 3.0 then
                    RequestBossList()
                    -- Re-apply this player's saved overrides for the new run:
                    -- the server keeps them only in memory keyed to the leader
                    -- tank, so they must be pushed again each time we (re)enter.
                    if PushSettings then PushSettings() end
                    sf:SetScript("OnUpdate", nil)
                end
            end)
        end
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        if frame:IsVisible() and isDCOn then
            SendDcCommand("status", "addon")
        end
    elseif event == "PLAYER_CONTROL_LOST" then
        -- Corrective only: catches a camera started outside this panel (a typed
        -- `.dc spectate`). If we already track a mode, that one is more precise
        -- than the guess this could make, so it is left alone.
        if not cameraState then SetCameraState("free") end
    elseif event == "PLAYER_CONTROL_GAINED" then
        -- The camera let go for real. Cancel a queued second toggle -- it was
        -- meant to finish the job, and now it would only start a new camera.
        secondToggle:Hide()
        SetCameraState(false)
    end
end)

-- Window show/hide triggers status update
frame:SetScript("OnShow", function()
    DungeonClearDB.visible = true
    SendDcCommand("status", "addon")
    RequestBossList()
    -- Paint the loading placeholder now so the panel is never blank on open;
    -- it's replaced the moment a BOSS_END arrives (and the ensure-loop keeps
    -- re-requesting until then).
    bossEnsureElapsed = 0
    RedrawBossList()
end)

frame:SetScript("OnHide", function()
    DungeonClearDB.visible = false
end)

-- Interface -> AddOns options panel (informational front door)
-- A simple, read-only page registered under Game Menu -> Interface -> AddOns:
-- overview text, a command/control reference, and a button that opens the main
-- window exactly like typing /dc. No settings live here; all controls stay in
-- the floating window.
local optionsPanel = CreateFrame("Frame", "DungeonClearOptionsPanel", UIParent)
optionsPanel.name = "DungeonClear"

local optTitle = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
optTitle:SetPoint("TOPLEFT", optionsPanel, "TOPLEFT", 16, -16)
DCBind(optTitle, "Dungeon Clear")
optTitle:SetTextColor(0.24, 0.60, 1.0) -- match the main window header

local optSubtitle = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
optSubtitle:SetPoint("TOPLEFT", optTitle, "BOTTOMLEFT", 0, -4)
optSubtitle:SetText("Autonomous dungeon-clearing companion for mod-dungeon-clear.")
optSubtitle:SetTextColor(0.6, 0.6, 0.6)
DCBindPair(optSubtitle, optSubtitle:GetText(), "mod-dungeon-clear 的副本自动清理助手。")

local optOverview = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
optOverview:SetPoint("TOPLEFT", optSubtitle, "BOTTOMLEFT", 0, -14)
optOverview:SetWidth(560)
optOverview:SetJustifyH("LEFT")
optOverview:SetText(
    "A mod-playerbots tank bot walks your party from boss to boss, clearing trash and " ..
    "pathing the route on its own. This addon is the front-end for that mode: it gives you " ..
    "one-click On / Off / Skip / Pause-Resume control, a live status readout (what the bot " ..
    "is doing and which boss it's heading for), and a boss list with a per-boss \"Go\" button. " ..
    "You must be in a party that contains a tank bot \226\128\148 the addon only relays commands.")

DCBindPair(optOverview, optOverview:GetText(),
    "一个 mod-playerbots 坦克机器人带着你的队伍，自己规划路线、清理小怪，一个首领一个首领地推进。" ..
    "这个插件是它的操作面板：一键开始 / 停止 / 跳过 / 暂停-继续，实时显示机器人在做什么、要去打哪个首领，" ..
    "首领列表里每行都有「前往」按钮。你必须和一个坦克机器人在同一队伍里——插件只负责转发指令。")

local optCmdHeader = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
optCmdHeader:SetPoint("TOPLEFT", optOverview, "BOTTOMLEFT", 0, -18)
DCBind(optCmdHeader, "Commands & Controls")
optCmdHeader:SetTextColor(0.24, 0.60, 1.0)

local optCmdList = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
optCmdList:SetPoint("TOPLEFT", optCmdHeader, "BOTTOMLEFT", 0, -8)
optCmdList:SetWidth(560)
optCmdList:SetJustifyH("LEFT")
optCmdList:SetText(
    "|cffffd100/dc|r  \226\128\148  Toggle the main window (always reopens in full mode).\n" ..
    "|cffffd100On / Off|r  \226\128\148  Start or stop the autonomous clear.\n" ..
    "|cffffd100Skip|r  \226\128\148  Skip the current boss / objective and move to the next.\n" ..
    "|cffffd100Pause / Resume|r  \226\128\148  Hold the tank in place without ending the clear, then resume.\n" ..
    "|cffffd100Pull: Off / On / Dynamic|r  \226\128\148  LOS pull-to-camp control. |cff33d94dOn|r: the tank runs " ..
    "in to grab a pack and drags it back to where the party waits (passive) before everyone engages. " ..
    "|cff4db3ffDynamic|r: the tank scans each upcoming pack and auto-picks \226\128\148 it |cffffa61aLeeroys|r a lone " ..
    "pack (charges in) but uses the careful |cff4db3ffAdvanced|r pull when packs are bunched in a room. The live " ..
    "choice shows on the Dyn control. " ..
    "|cff8c8c8cOff|r: walk up and fight in place.\n" ..
    "|cffffd100Spectate|r  \226\128\148  Left-click detaches you into a free-flying camera while your " ..
    "character keeps running under bot AI. Right-click instead rides the tank (follow cam), handing off " ..
    "if it dies. Click again (or |cffffd100.dc spectate|r) to return to your body.\n" ..
    "|cffffd100< >|r (next to Spectate)  \226\128\148  Move the camera to any other bot in the instance, " ..
    "tank or not \226\128\148 healer during a wipe, DPS during a burn. Also starts the follow cam if it " ..
    "isn't running. |cffffd100.dc spectate next/prev/list|r, or " ..
    "|cffffd100.dc spectate follow <name>|r to jump straight to one.\n" ..
    "|cffffd100Go|r (per boss row)  \226\128\148  Send the tank straight to that boss (turns the clear on first).\n" ..
    "|cffffd100Tiny|r  \226\128\148  Collapse the window to a single-line, movable readout.\n" ..
    "|cffffd100Settings|r (sub-page)  \226\128\148  Override the server defaults (loot quality, rest %, " ..
    "party spread, pull tuning, …) for your own runs. Saved per character and re-applied each run.")

DCBindPair(optCmdList, optCmdList:GetText(),
    "|cffffd100/dc|r  ——  打开/关闭主窗口（总是以完整模式打开）。|cffffd100/dc lang|r 切换中文 / English。\n" ..
    "|cffffd100开始 / 停止|r  ——  开始或停止自动清理。\n" ..
    "|cffffd100跳过|r  ——  跳过当前首领 / 目标，去下一个。\n" ..
    "|cffffd100暂停 / 继续|r  ——  让坦克原地待命但不结束清理，之后继续。\n" ..
    "|cffffd100拉怪：直冲 / 引怪 / 智能|r  ——  |cff33d94d引怪|r：坦克冲进去拉一波怪，再引回队伍等待的位置（营地）一起打。" ..
    "|cff4db3ff智能|r：坦克侦察每一波怪自动选择——单独的一小波就|cffffa61a直冲|r，房间里扎堆的就用稳妥的|cff4db3ff引怪|r。" ..
    "|cff8c8c8c直冲|r：走上去原地开打。\n" ..
    "|cffffd100观战|r  ——  左键进入自由飞行镜头，你的角色由机器人 AI 继续操作。右键改为跟随镜头，坦克死了自动换人。" ..
    "再点一次（或 |cffffd100.dc spectate|r）回到自己身上。\n" ..
    "|cffffd100< >|r（观战旁边）  ——  把镜头切到副本里任意一个机器人；没开镜头时自动开启跟随镜头。\n" ..
    "|cffffd100前往|r（首领列表每行）  ——  让坦克直接去这个首领（会先开启清理）。\n" ..
    "|cffffd100迷你|r  ——  把窗口收成一行、可拖动的小条。\n" ..
    "|cffffd100设置|r（子页面）  ——  为你自己的副本覆盖服务器默认值（拾取品质、休整 %、队伍间距、拉怪参数……），按角色保存，每次进本自动应用。")

local openBtn = CreateFrame("Button", nil, optionsPanel, "UIPanelButtonTemplate")
openBtn:SetSize(160, 24)
openBtn:SetPoint("TOPLEFT", optCmdList, "BOTTOMLEFT", 0, -20)
DCBind(openBtn, "Open DungeonClear")
openBtn:SetScript("OnClick", function()
    -- Mirror the /dc (no-arg) open branch: always reopen in full (non-tiny) mode.
    DungeonClearDB.tinyMode = false
    UpdateLayout()
    frame:Show()
end)

InterfaceOptions_AddCategory(optionsPanel)

-- ===========================================================================
-- Settings sub-panel (Interface -> AddOns -> DungeonClear -> Settings)
-- ===========================================================================
-- Schema-driven per-player overrides. The server is the source of truth for
-- which settings exist and their type/range: each `sync` streams one SETTINGS
-- line per player-facing setting (key, value, min, max, type, overridden) and
-- this panel renders a control for each. A new setting added server-side shows
-- up here automatically with no addon change. Overrides are saved per character
-- in DungeonClearDB.settings and re-pushed to the server each run (it keeps them
-- only in memory, keyed to the leader tank).

-- Friendly labels + tooltips. Optional decoration only: any key missing here
-- still renders, falling back to the raw key as its label.
local SettingMeta = {
    PreventBotRelease    = { label = "Prevent Bot Release",
                             desc = "Dead bots stay as a corpse to be resurrected instead of releasing to the graveyard." },
    CombatRegroup        = { label = "Combat Regroup",
                             desc = "Keep followers grouped on the tank during a fight, not just on the route — a healer that drifts out of line of sight closes back in." },
    PartyMaxSpread       = { label = "Party Max Spread (yd)",
                             desc = "How far the tank may lead the party before it holds to let everyone catch up." },
    LootMinQuality       = { label = "Minimum Loot Quality",
                             desc = "Skip corpses whose best item is below this rarity. Quest items always loot." },
    IgnoreChests         = { label = "Ignore Chests",
                             desc = "Don't stop for treasure chests or other world objects while clearing — only loot creature corpses." },
    RestHealthPct        = { label = "Rest Health %",
                             desc = "Health the party eats up to between pulls, overriding the server's AiPlayerbot.AlmostFullHealth for this run. 0 = use the server default." },
    RestManaPct          = { label = "Rest Mana %",
                             desc = "Mana the party drinks up to between pulls, overriding the server's AiPlayerbot.HighMana for this run. 0 = use the server default. Ignored while Smart Rest is on." },
    SmartRest            = { label = "Smart Rest",
                             desc = "Push without stopping to eat or drink until someone falls below a trigger, then the whole party rests to FULL health and mana. Off = classic rest-to-target behavior (Rest Health/Mana % above)." },
    SmartRestHealthPct   = { label = "Smart Rest: Health Trigger %",
                             desc = "Any member below this health stops the party for a full rest. 0 disables the health trigger." },
    SmartRestDpsManaPct  = { label = "Smart Rest: DPS/Tank Mana Trigger %",
                             desc = "A DPS or tank mana user below this stops the party for a full rest. 0 disables." },
    SmartRestHealerManaPct = { label = "Smart Rest: Healer Mana Trigger %",
                             desc = "A healer below this mana stops the party for a full rest. 0 disables." },
    WaitAtBoss           = { label = "Wait at Boss",
                             desc = "Pause the run right before every boss pull and wait for you — hit Resume (or the tiny-mode dot) when your party is ready. Each boss waits once per run." },
    PullDynamicMaxLeeroyMobs = { label = "Desired maximum mobs per pull",
                             desc = "Dynamic pull only. The party's comfortable simultaneous-mob ceiling: the tank Leeroys a pack at or under this estimated aggro count, and pulls one above it back to camp." },
    PullDynamicPartyLag  = { label = "Pull: Party Lag (yd)",
                             desc = "Dynamic pull only. How far back the party trails while the tank scouts the next pack, so it reaches aggro range alone to decide Leeroy vs pull." },
}

-- The only settings exposed in the player-facing panel. The server streams many
-- more (and the conf file still tunes them all), but the rest are advanced
-- pathfinding/engage/pull-geometry knobs better left at the server default, so we
-- allowlist exactly the player-relevant ones here. UpsertSetting drops anything
-- not listed, so a live sync can't recreate a row for a setting we don't want.
local VisibleSettings = {
    PreventBotRelease        = true,
    IgnoreChests             = true,
    CombatRegroup            = true,
    LootMinQuality           = true,
    RestHealthPct            = true,
    RestManaPct              = true,
    SmartRest                = true,
    SmartRestHealthPct       = true,
    SmartRestDpsManaPct      = true,
    SmartRestHealerManaPct   = true,
    WaitAtBoss               = true,
    PartyMaxSpread           = true,
    PullDynamicMaxLeeroyMobs = true,
    PullDynamicPartyLag      = true,
}


-- WoW item-quality id -> display name + color (used by the Minimum Loot Quality
-- dropdown). Mirrors the client's ITEM_QUALITY_COLORS / ITEM_QUALITYn_DESC but
-- hardcoded so the colored entries render identically regardless of locale.
local QualityInfo = {
    [0] = { name = "Poor",      hex = "ff9d9d9d" },
    [1] = { name = "Common",    hex = "ffffffff" },
    [2] = { name = "Uncommon",  hex = "ff1eff00" },
    [3] = { name = "Rare",      hex = "ff0070dd" },
    [4] = { name = "Epic",      hex = "ffa335ee" },
    [5] = { name = "Legendary", hex = "ffff8000" },
    [6] = { name = "Artifact",  hex = "ffe6cc80" },
}
local function QualityText(v)
    local info = QualityInfo[v] or QualityInfo[0]
    return "|c" .. info.hex .. DCL(info.name) .. "|r"
end

-- Setting type ids mirror DcType in the server registry.
local DCT_BOOL, DCT_UINT, DCT_INT, DCT_FLOAT = 0, 1, 2, 3

-- Built-in fallback schema mirroring the server's DcSettingsRegistry. It lets
-- the panel render controls (with correct defaults/ranges) even with no live
-- sync yet — e.g. solo, or browsing the ESC menu outside a dungeon. A live
-- `sync` refines these with the server's real effective values and can add keys
-- not listed here, so the panel still auto-extends when the server gains a
-- setting; this table only needs touching to give a new setting nicer defaults.
local DefaultSchema = {
    PreventBotRelease        = { type = DCT_BOOL,  min = 0,  max = 1,  default = 1 },
    IgnoreChests             = { type = DCT_BOOL,  min = 0,  max = 1,  default = 1 },
    CombatRegroup            = { type = DCT_BOOL,  min = 0,  max = 1,  default = 1 },
    LootMinQuality           = { type = DCT_UINT,  min = 0,  max = 6,  default = 0 },
    RestHealthPct            = { type = DCT_UINT,  min = 0,  max = 100, default = 0 },
    RestManaPct              = { type = DCT_UINT,  min = 0,  max = 100, default = 0 },
    SmartRest                = { type = DCT_BOOL,  min = 0,  max = 1,  default = 0 },
    SmartRestHealthPct       = { type = DCT_UINT,  min = 0,  max = 100, default = 50 },
    SmartRestDpsManaPct      = { type = DCT_UINT,  min = 0,  max = 100, default = 10 },
    SmartRestHealerManaPct   = { type = DCT_UINT,  min = 0,  max = 100, default = 40 },
    WaitAtBoss               = { type = DCT_BOOL,  min = 0,  max = 1,  default = 0 },
    PartyMaxSpread           = { type = DCT_FLOAT, min = 10, max = 60, default = 25 },
    PullDynamicMaxLeeroyMobs = { type = DCT_UINT,  min = 1,  max = 20, default = 5 },
    PullDynamicPartyLag      = { type = DCT_FLOAT, min = 6,  max = 40, default = 15 },
}
local DefaultSchemaOrder = {
    "PreventBotRelease", "IgnoreChests", "CombatRegroup",
    "LootMinQuality", "RestHealthPct", "RestManaPct",
    "SmartRest", "SmartRestHealthPct", "SmartRestDpsManaPct", "SmartRestHealerManaPct",
    "WaitAtBoss",
    "PartyMaxSpread", "PullDynamicMaxLeeroyMobs", "PullDynamicPartyLag",
}

local settingRows = {}     -- key -> row frame
local settingOrder = {}    -- insertion order for layout
local inSyncBatch = false

local function StepFor(stype) return stype == DCT_FLOAT and 0.5 or 1 end

local function RoundVal(stype, v)
    if stype == DCT_FLOAT then
        return math.floor(v * 2 + 0.5) / 2   -- snap to 0.5
    end
    return math.floor(v + 0.5)
end

local function FmtVal(stype, v)
    if stype == DCT_BOOL then return DCL((v ~= 0) and "On" or "Off") end
    if stype == DCT_FLOAT then return string.format("%.1f", v) end
    return tostring(math.floor(v + 0.5))
end

local settingsPanel = CreateFrame("Frame", "DungeonClearSettingsPanel", UIParent)
settingsPanel.name = "Settings"
settingsPanel.parent = optionsPanel.name  -- nests under "DungeonClear"

local setTitle = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
setTitle:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", 16, -16)
DCBind(setTitle, "Dungeon Clear - Settings")
setTitle:SetTextColor(0.24, 0.60, 1.0)

local setIntro = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
setIntro:SetPoint("TOPLEFT", setTitle, "BOTTOMLEFT", 0, -4)
setIntro:SetWidth(580)
setIntro:SetJustifyH("LEFT")
setIntro:SetText(
    "These override the server defaults for your own dungeon runs. Changes apply " ..
    "immediately and are saved per character. You must be in a party with a tank " ..
    "bot for them to take effect; \"Default\" reverts a setting to the server value.")
setIntro:SetTextColor(0.6, 0.6, 0.6)
DCBindPair(setIntro, setIntro:GetText(),
    "这些设置会为你自己的副本覆盖服务器默认值，立即生效，按角色保存。必须和坦克机器人在同一队伍才会生效；" ..
    "「默认」把这一项恢复成服务器的值。")

-- Reset-everything-to-server-default button.
local resetAllBtn = CreateFrame("Button", nil, settingsPanel, "UIPanelButtonTemplate")
resetAllBtn:SetSize(150, 22)
resetAllBtn:SetPoint("TOPLEFT", setIntro, "BOTTOMLEFT", 0, -10)
DCBind(resetAllBtn, "Reset All to Default")
resetAllBtn:SetScript("OnClick", function()
    DungeonClearDB.settings = {}
    SendDcCommand("reset", "", true)  -- empty key = clear the whole run
end)

-- Scroll area so the panel scales to any number of settings.
local setScroll = CreateFrame("ScrollFrame", "DungeonClearSettingsScroll", settingsPanel, "UIPanelScrollFrameTemplate")
setScroll:SetPoint("TOPLEFT", resetAllBtn, "BOTTOMLEFT", 0, -10)
setScroll:SetPoint("BOTTOMRIGHT", settingsPanel, "BOTTOMRIGHT", -28, 16)

local setContent = CreateFrame("Frame", "DungeonClearSettingsContent", setScroll)
setContent:SetSize(560, 10)
setScroll:SetScrollChild(setContent)

-- Control-type ordering for the panel: checkboxes, then dropdowns, then text
-- boxes, then sliders. Keeps like controls grouped regardless of insertion order.
local function ControlGroup(row)
    if row.stype == DCT_BOOL then return 1 end
    if row.isQuality then return 2 end
    return 4  -- slider
end

-- Position every known row top-to-bottom (grouped by control type) and size the
-- scroll child.
local function RelayoutSettings()
    -- Stable sort by control group, preserving insertion order within a group.
    local idx, keys = {}, {}
    for i, key in ipairs(settingOrder) do idx[key] = i end
    for _, key in ipairs(settingOrder) do
        if settingRows[key] then table.insert(keys, key) end
    end
    table.sort(keys, function(a, b)
        local ga, gb = ControlGroup(settingRows[a]), ControlGroup(settingRows[b])
        if ga ~= gb then return ga < gb end
        return idx[a] < idx[b]
    end)

    local y = -6
    for _, key in ipairs(keys) do
        local row = settingRows[key]
        if row then
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", setContent, "TOPLEFT", 6, y)
            row:SetPoint("RIGHT", setContent, "RIGHT", -6, 0)
            row:Show()
            -- Sliders carry min/max sublabels under the track, so they need extra
            -- room before the next row's title; other controls don't.
            y = y - (row.isSlider and 66 or 52)
        end
    end
    setContent:SetHeight(math.max(10, -y + 6))
end

-- Build a row's frame + control (control type fixed by the setting's type).
local function CreateSettingRow(key, stype)
    local meta = SettingMeta[key] or {}
    local row = CreateFrame("Frame", nil, setContent)
    row:SetSize(540, 48)
    row.key = key
    row.stype = stype

    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.label:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -2)
    DCBind(row.label, meta.label or key)
    row.label:SetTextColor(0.92, 0.92, 0.92)

    if meta.desc then
        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
            GameTooltip:SetText(DCL(meta.label or key), 1, 1, 1)
            GameTooltip:AddLine(DCL(meta.desc), 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    -- Per-row revert button, shown only while this setting is overridden.
    row.defBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.defBtn:SetSize(64, 18)
    row.defBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -2, -2)
    DCBind(row.defBtn, "Default")
    row.defBtn:SetScript("OnClick", function()
        DungeonClearDB.settings[key] = nil
        SendDcCommand("reset", key, true)
    end)
    row.defBtn:Hide()

    if stype == DCT_BOOL then
        local cb = CreateFrame("CheckButton", "DungeonClearCheck_" .. key, row, "UICheckButtonTemplate")
        cb:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 8, 0)
        cb:SetScript("OnClick", function(self)
            if row.updating then return end
            local v = self:GetChecked() and 1 or 0
            DungeonClearDB.settings[key] = v
            row.defBtn:Show()
            SendDcCommand("set", key .. "\t" .. v, true)
        end)
        row.control = cb
    elseif key == "LootMinQuality" then
        -- Loot rarity reads as named tiers, not a number, so a colored dropdown
        -- ("Common", "Rare", "Epic", …) is clearer than a 0-6 slider.
        local dd = CreateFrame("Frame", "DungeonClearDropdown_" .. key, row, "UIDropDownMenuTemplate")
        dd:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", -6, -2)
        UIDropDownMenu_SetWidth(dd, 130)
        local function OnSelect(self)
            local v = self.value
            UIDropDownMenu_SetSelectedValue(dd, v)
            UIDropDownMenu_SetText(dd, QualityText(v))
            if row.updating then return end
            DungeonClearDB.settings[key] = v
            row.defBtn:Show()
            SendDcCommand("set", key .. "\t" .. v, true)
        end
        UIDropDownMenu_Initialize(dd, function(self, level)
            for q = 0, 6 do
                local entry = UIDropDownMenu_CreateInfo()
                entry.text = QualityText(q)
                entry.value = q
                entry.func = OnSelect
                entry.checked = (UIDropDownMenu_GetSelectedValue(dd) == q)
                UIDropDownMenu_AddButton(entry, level)
            end
        end)
        row.control = dd
        row.isQuality = true
    else
        local s = CreateFrame("Slider", "DungeonClearSlider_" .. key, row, "OptionsSliderTemplate")
        s:SetWidth(300)
        s:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 10, 2)
        s:SetOrientation("HORIZONTAL")
        getglobal(s:GetName() .. "Text"):SetText("")  -- use our own label instead
        row.valText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.valText:SetPoint("LEFT", s, "RIGHT", 14, 0)
        row.valText:SetTextColor(1, 0.82, 0)
        row.isSlider = true
        s:SetScript("OnValueChanged", function(self, value)
            value = RoundVal(stype, value)
            row.valText:SetText(FmtVal(stype, value))
            if row.updating then return end
            DungeonClearDB.settings[key] = value
            row.defBtn:Show()
            SendDcCommand("set", key .. "\t" .. value, true)
        end)
        row.control = s
    end

    return row
end

-- Create-or-update the row for one setting from a SETTINGS line / cache entry.
local function UpsertSetting(key, value, minV, maxV, stype, overridden)
    -- Show only the allowlisted player-facing settings, even if the server
    -- streams others in a live sync.
    if not VisibleSettings[key] then return end

    -- Cache the schema so the panel can render before any sync (e.g. at login).
    if not DungeonClearDB.schema[key] then
        DungeonClearDB.schema[key] = {}
        table.insert(DungeonClearDB.schemaOrder, key)
    end
    local sc = DungeonClearDB.schema[key]
    sc.min, sc.max, sc.type = minV, maxV, stype

    local row = settingRows[key]
    if not row then
        row = CreateSettingRow(key, stype)
        settingRows[key] = row
        table.insert(settingOrder, key)
    end

    row.updating = true
    if stype == DCT_BOOL then
        row.control:SetChecked(value ~= 0)
    elseif row.isQuality then
        local v = math.floor(value + 0.5)
        if v < 0 then v = 0 elseif v > 6 then v = 6 end
        UIDropDownMenu_SetSelectedValue(row.control, v)
        UIDropDownMenu_SetText(row.control, QualityText(v))
    else
        row.control:SetMinMaxValues(minV, maxV)
        row.control:SetValueStep(StepFor(stype))
        getglobal(row.control:GetName() .. "Low"):SetText(FmtVal(stype, minV))
        getglobal(row.control:GetName() .. "High"):SetText(FmtVal(stype, maxV))
        row.control:SetValue(value)
        row.valText:SetText(FmtVal(stype, value))
    end
    row.updating = false

    if overridden then row.defBtn:Show() else row.defBtn:Hide() end
end

-- Assign the forward-declared hooks used by OnAddonMessage / ADDON_LOADED.
HandleSettingsLine = function(parts)
    local key = parts[2]
    local value = tonumber(parts[3])
    local minV = tonumber(parts[4])
    local maxV = tonumber(parts[5])
    local stype = tonumber(parts[6])
    local overridden = (parts[7] == "1")
    if not key or value == nil or stype == nil then return end
    UpsertSetting(key, value, minV, maxV, stype, overridden)
    if not inSyncBatch then RelayoutSettings() end
end

OnSettingsSyncBoundary = function(which)
    if which == "start" then
        inSyncBatch = true
    else
        inSyncBatch = false
        RelayoutSettings()
    end
end

PushSettings = function()
    if not DungeonClearDB.settings then return end
    for k, v in pairs(DungeonClearDB.settings) do
        SendDcCommand("set", k .. "\t" .. v, true)
    end
end

BuildSettingsFromCache = function()
    local seen = {}
    local function render(key, stype, minV, maxV, defaultV)
        local v = DungeonClearDB.settings[key]
        local overridden = (v ~= nil)
        if v == nil then v = (defaultV ~= nil) and defaultV or minV end
        UpsertSetting(key, v, minV, maxV, stype, overridden)
        seen[key] = true
    end

    -- Built-in settings first (correct defaults/ranges), preferring any cached
    -- min/max/type from a past sync but always using the built-in default value.
    for _, key in ipairs(DefaultSchemaOrder) do
        local d = DefaultSchema[key]
        local c = DungeonClearDB.schema[key]
        render(key,
            (c and c.type) or d.type,
            (c and c.min) or d.min,
            (c and c.max) or d.max,
            d.default)
    end

    -- Any extra keys a server sync advertised that aren't built in.
    for _, key in ipairs(DungeonClearDB.schemaOrder or {}) do
        local sc = DungeonClearDB.schema[key]
        if sc and sc.type and not seen[key] then
            render(key, sc.type, sc.min, sc.max, nil)
        end
    end

    RelayoutSettings()
end

-- Refresh whenever the panel is shown. First re-render every row from the cached
-- schema NOW that the panel is visible: InputBoxTemplate EditBoxes (the Rest %
-- fields) don't reliably display text set while their parent is hidden, so the
-- ADDON_LOADED population can leave them blank until re-applied on show. Then ask
-- the server for live effective values (silent "addon" param; a missing tank bot
-- no longer reaches chat, so there's nothing to suppress).
local function RefreshSettings()
    if BuildSettingsFromCache then BuildSettingsFromCache() end
    SendDcCommand("sync", "addon")
end
settingsPanel.refresh = RefreshSettings
settingsPanel:SetScript("OnShow", RefreshSettings)

InterfaceOptions_AddCategory(settingsPanel)

-- Minimap Button
-- Self-contained (no LibDBIcon dependency): a draggable button pinned to the
-- minimap edge. Left-click toggles the main window exactly like /dc; drag moves
-- it around the dial, with the angle persisted in DungeonClearDB.minimapPos.
local function ToggleMainWindow()
    if frame:IsVisible() then
        frame:Hide()
    else
        -- Always reopen in full (non-tiny) mode, matching the /dc behavior.
        DungeonClearDB.tinyMode = false
        UpdateLayout()
        frame:Show()
    end
end

local minimapButton = CreateFrame("Button", "DungeonClearMinimapButton", Minimap)
minimapButton:SetFrameStrata("MEDIUM")
minimapButton:SetFrameLevel(8)
minimapButton:SetSize(31, 31)
minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
minimapButton:RegisterForDrag("LeftButton")

local mmOverlay = minimapButton:CreateTexture(nil, "OVERLAY")
mmOverlay:SetSize(53, 53)
mmOverlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
mmOverlay:SetPoint("TOPLEFT")

local mmIcon = minimapButton:CreateTexture(nil, "BACKGROUND")
mmIcon:SetSize(20, 20)
mmIcon:SetTexture("Interface\\Icons\\inv_misc_enggizmos_17")
mmIcon:SetPoint("CENTER", minimapButton, "CENTER", 0, 1)
mmIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

local function UpdateMinimapButtonPosition()
    local angle = math.rad(DungeonClearDB.minimapPos or 200)
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER",
        80 * math.cos(angle), 80 * math.sin(angle))
end

minimapButton:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
        local mx, my = Minimap:GetCenter()
        local scale = Minimap:GetEffectiveScale()
        local px, py = GetCursorPosition()
        px, py = px / scale, py / scale
        DungeonClearDB.minimapPos = math.deg(math.atan2(py - my, px - mx))
        UpdateMinimapButtonPosition()
    end)
end)
minimapButton:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
end)

minimapButton:SetScript("OnClick", function(self, button)
    ToggleMainWindow()
end)

minimapButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(DCL("Dungeon Clear"))
    GameTooltip:AddLine(DCL("Left-click to toggle the window."), 1, 1, 1)
    GameTooltip:AddLine(DCL("Drag to reposition this button."), 1, 1, 1)
    GameTooltip:Show()
end)
minimapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

UpdateMinimapButtonPosition()

-- SavedVariables aren't restored until ADDON_LOADED fires (which happens after
-- this file has finished executing), so the call above positions the button
-- using the default angle. Re-apply the persisted angle once the DB is actually
-- loaded, otherwise the button snaps back to the default on every login.
local mmLoader = CreateFrame("Frame")
mmLoader:RegisterEvent("ADDON_LOADED")
mmLoader:SetScript("OnEvent", function(self, _, name)
    if name == AddonName then
        UpdateMinimapButtonPosition()
        self:UnregisterEvent("ADDON_LOADED")
    end
end)

-- Re-render everything drawn from runtime state when the language flips.
DCLoc.OnChange(function()
    if lastStatusArgs then
        UpdateStatusUI(unpack(lastStatusArgs, 1, 7))
    else
        UpdateStatusUI("0")
    end
    RedrawBossList()
    if UpdateLayout then UpdateLayout() end
    if BuildSettingsFromCache then BuildSettingsFromCache() end
end)

-- Coordinate copy box (RebornWOW DCGPS1A/1C). `.gps` (GM) also prints one machine-readable
-- "[gps] ..." line; this window keeps those points with the place name they were taken at,
-- shows each one in a pick of formats, and copies it. Copying uses CopyToClipboard() when the
-- client provides it (AwesomeWotlk does); otherwise the text is pre-selected for Ctrl+C.
-- Open by hand with /dc gps or the header GPS button.
;(function()
    local MAX_HISTORY = 200   -- unstarred points kept; starred ones are never pushed out
    local PAGE_SIZE = 10
    local FORMATS = {
        { key = "raw",  label = "Raw",          width = 60 },
        { key = "go",   label = "Teleport",     width = 84 },
        { key = "sql",  label = "SQL",          width = 56 },
        { key = "dc",   label = "Event consts", width = 84 },
        { key = "move", label = "Move NPC SQL", width = 120 },
    }
    local current = nil      -- the point shown
    local fmt = "raw"
    local loadedFormat = false  -- saved format is read once, then the buttons own it
    local page = 1
    local Render  -- forward

    local function DB()
        DungeonClearDB.gps = DungeonClearDB.gps or {}
        local g = DungeonClearDB.gps
        g.history = g.history or {}
        if g.autoPopup == nil then g.autoPopup = true end
        if g.format and not loadedFormat then fmt = g.format end
        loadedFormat = true
        return g
    end

    local function Parse(line)
        local x, y, z, o, map, zone, area, inst, phase, kind, entry, spawn, name = line:match(
            "^%[gps%] X (%S+) Y (%S+) Z (%S+) O (%S+) map (%d+) zone (%d+) area (%d+) instance (%d+) phase (%d+) type (%S+) entry (%d+) spawn (%d+) name ?(.*)$")
        if not x then return nil end
        return { x = tonumber(x), y = tonumber(y), z = tonumber(z), o = tonumber(o), map = tonumber(map),
                 zone = tonumber(zone), area = tonumber(area), instance = tonumber(inst), phase = tonumber(phase),
                 kind = kind, entry = tonumber(entry), spawn = tonumber(spawn), name = name or "",
                 time = date("%m-%d %H:%M"),
                 -- the place is read from the client at capture time (a targeted creature is
                 -- where you are, give or take): real zone (or instance) and sub-zone
                 place = GetRealZoneText and GetRealZoneText() or "",
                 sub = GetSubZoneText and GetSubZoneText() or "" }
    end

    -- "达拉然 - 紫罗兰城堡"; older points saved without a place show their map id.
    local function Place(p)
        local place = p.place or p.zoneName or ""
        if place == "" then return DCL("map") .. " " .. p.map end
        if p.sub and p.sub ~= "" and p.sub ~= place then place = place .. " - " .. p.sub end
        return place
    end

    local function Label(p)
        if p.note and p.note ~= "" then return p.note end
        return Place(p)
    end

    local function Format(p, key)
        if not p then return "" end
        if key == "go" then
            return string.format(".go xyz %.2f %.2f %.2f %d %.2f", p.x, p.y, p.z, p.map, p.o)
        elseif key == "sql" then
            return string.format("(%d, %.4f, %.4f, %.4f, %.4f)", p.map, p.x, p.y, p.z, p.o)
        elseif key == "dc" then
            return string.format("X = %.2ff, Y = %.2ff, Z = %.2ff, O = %.3ff; // map %d %s", p.x, p.y, p.z, p.o, p.map, Label(p))
        elseif key == "move" then
            if p.kind ~= "creature" or p.spawn == 0 then
                return "-- " .. DCL("Select a creature first (Move NPC SQL needs a spawned creature).")
            end
            return string.format("UPDATE `creature` SET `position_x` = %.4f, `position_y` = %.4f, `position_z` = %.4f, `orientation` = %.4f WHERE `guid` = %d; -- %s (entry %d)",
                p.x, p.y, p.z, p.o, p.spawn, p.name, p.entry)
        end
        return string.format("X %.4f Y %.4f Z %.4f O %.4f map %d", p.x, p.y, p.z, p.o, p.map)
    end

    local f = CreateFrame("Frame", "DungeonClearGpsFrame", UIParent)
    f:SetSize(460, 384)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 140)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    f:SetBackdropColor(0.03, 0.03, 0.05, 0.94)
    f:SetBackdropBorderColor(0.20, 0.22, 0.28, 1.0)
    f:Hide()
    tinsert(UISpecialFrames, "DungeonClearGpsFrame")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -12)
    DCBind(title, "Coordinates")
    title:SetTextColor(0.24, 0.60, 1.0)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    -- RebornWOW DCCHAT1A: open the chat log copy panel (command output you can copy).
    local chatBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    chatBtn:SetSize(96, 20)
    chatBtn:SetPoint("RIGHT", close, "LEFT", -2, 0)
    DCBind(chatBtn, "Chat log")
    chatBtn:SetScript("OnClick", function() if DCChatCopyToggle then DCChatCopyToggle() end end)
    chatBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(DCL("Command output and chat lines in a box you can copy from. Also /dc chat."), 1, 1, 1, true)
        GameTooltip:Show()
    end)
    chatBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    info:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -38)
    info:SetPoint("RIGHT", f, "RIGHT", -14, 0)
    info:SetJustifyH("LEFT")

    -- format row (fixed widths so the Chinese labels fit)
    local fmtButtons = {}
    for i, def in ipairs(FORMATS) do
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(def.width, 20)
        if i == 1 then b:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -56)
        else b:SetPoint("LEFT", fmtButtons[i - 1], "RIGHT", 3, 0) end
        DCBind(b, def.label)
        b:SetScript("OnClick", function() fmt = def.key; DB().format = fmt; Render() end)
        b.key = def.key
        fmtButtons[i] = b
    end

    -- the copy box and its Copy button
    local box = CreateFrame("EditBox", "DungeonClearGpsEditBox", f, "InputBoxTemplate")
    box:SetSize(358, 22)
    box:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -84)
    box:SetAutoFocus(false)
    box:SetFontObject(ChatFontNormal)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus(); f:Hide() end)
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    -- Keep the text what we put there: typing would only break the copy.
    box:SetScript("OnTextChanged", function(self, userInput)
        if userInput then Render() end
    end)
    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", box, "BOTTOMLEFT", -4, -4)
    local hintUntil = 0

    local function Hint(text, seconds)
        hint:SetText(text)
        hintUntil = seconds and (GetTime() + seconds) or 0
    end
    local function DefaultHint()
        if CopyToClipboard then
            Hint(DCL("Click Copy or press Ctrl+C. Esc closes."))
        else
            Hint(DCL("Already selected: press Ctrl+C to copy. Esc closes."))
        end
    end
    f:SetScript("OnUpdate", function()
        if hintUntil > 0 and GetTime() > hintUntil then hintUntil = 0; DefaultHint() end
    end)

    -- Copy `text`: straight to the clipboard when the client can, else select it in the box.
    local function Copy(text)
        if not text or text == "" then return end
        if CopyToClipboard then
            CopyToClipboard(text)
            Hint("|cff33ff33" .. DCL("Copied to the clipboard.") .. "|r", 3)
        else
            box:SetText(text)
            box:SetFocus()
            box:HighlightText()
            Hint("|cffffd100" .. DCL("This client cannot copy directly: press Ctrl+C.") .. "|r", 5)
        end
    end

    local copyBtn = CreateFrame("Button", "DungeonClearGpsCopyButton", f, "UIPanelButtonTemplate")
    copyBtn:SetSize(66, 22)
    copyBtn:SetPoint("LEFT", box, "RIGHT", 6, 0)
    DCBind(copyBtn, "Copy")
    copyBtn:SetScript("OnClick", function() Copy(Format(current, fmt)) end)

    -- history list: label row, filter, pager
    local histLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    histLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -134)
    DCBind(histLabel, "Saved points (right-click for more)")
    histLabel:SetTextColor(0.24, 0.60, 1.0)

    local starOnly = CreateFrame("CheckButton", "DungeonClearGpsStarOnly", f, "UICheckButtonTemplate")
    starOnly:SetSize(20, 20)
    starOnly:SetPoint("TOPLEFT", f, "TOPLEFT", 196, -130)
    local starOnlyText = starOnly:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    starOnlyText:SetPoint("LEFT", starOnly, "RIGHT", 0, 1)
    DCBind(starOnlyText, "Starred only")
    starOnly:SetScript("OnClick", function(self) DB().starOnly = self:GetChecked() and true or false; page = 1; Render() end)

    local nextBtn = CreateFrame("Button", "DungeonClearGpsNextPage", f, "UIPanelButtonTemplate")
    nextBtn:SetSize(24, 20)
    nextBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -130)
    nextBtn:SetText(">")
    nextBtn:SetScript("OnClick", function() page = page + 1; Render() end)
    local pageText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pageText:SetPoint("RIGHT", nextBtn, "LEFT", -4, 0)
    local prevBtn = CreateFrame("Button", "DungeonClearGpsPrevPage", f, "UIPanelButtonTemplate")
    prevBtn:SetSize(24, 20)
    prevBtn:SetPoint("RIGHT", pageText, "LEFT", -4, 0)
    prevBtn:SetText("<")
    prevBtn:SetScript("OnClick", function() page = page - 1; Render() end)

    local menuFrame = CreateFrame("Frame", "DungeonClearGpsMenu", UIParent, "UIDropDownMenuTemplate")

    local function RemovePoint(p)
        local h = DB().history
        for i = #h, 1, -1 do if h[i] == p then table.remove(h, i) end end
        if current == p then current = nil end
    end

    local function FormatName(key)
        for _, d in ipairs(FORMATS) do if d.key == key then return DCL(d.label) end end
        return key
    end

    local function ChatText(p)
        return string.format("%s: %.2f %.2f %.2f map %d", Label(p), p.x, p.y, p.z, p.map)
    end

    StaticPopupDialogs["DUNGEONCLEAR_GPS_NOTE"] = {
        text = "%s",
        button1 = OKAY, button2 = CANCEL,
        hasEditBox = 1, maxLetters = 60,
        OnShow = function(self, data)
            data = data or self.data
            local eb = _G[self:GetName() .. "EditBox"]
            if eb then eb:SetText(data and data.note or ""); eb:HighlightText() end
        end,
        OnAccept = function(self, data)
            local eb = _G[self:GetName() .. "EditBox"]
            if data and eb then data.note = eb:GetText(); Render() end
        end,
        EditBoxOnEnterPressed = function(self)
            local parent = self:GetParent()
            if parent.data then parent.data.note = self:GetText(); Render() end
            parent:Hide()
        end,
        EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
        timeout = 0, whileDead = true, hideOnEscape = true,
    }

    local function ShowPointMenu(p)
        local copyAs = {}
        for _, def in ipairs(FORMATS) do
            copyAs[#copyAs + 1] = { text = DCL(def.label), notCheckable = true,
                func = function() CloseDropDownMenus(); current = p; Copy(Format(p, def.key)); Render() end }
        end
        local inParty = GetNumPartyMembers and GetNumPartyMembers() > 0
        local inRaid = GetNumRaidMembers and GetNumRaidMembers() > 0
        local inGuild = IsInGuild and IsInGuild()
        local function SendTo(channel)
            return function() CloseDropDownMenus(); SendChatMessage(ChatText(p), channel) end
        end
        local chat = {
            { text = DCL("Say"), notCheckable = true, func = SendTo("SAY") },
            { text = DCL("Party"), notCheckable = true, disabled = not inParty, func = SendTo("PARTY") },
            { text = DCL("Raid"), notCheckable = true, disabled = not inRaid, func = SendTo("RAID") },
            { text = DCL("Guild"), notCheckable = true, disabled = not inGuild, func = SendTo("GUILD") },
        }
        local menu = {
            { text = Label(p), isTitle = true, notCheckable = true },
            { text = DCL("Copy") .. " (" .. FormatName(fmt) .. ")", notCheckable = true,
              func = function() current = p; Copy(Format(p, fmt)); Render() end },
            { text = DCL("Copy as"), notCheckable = true, hasArrow = true, menuList = copyAs },
            { text = DCL("Teleport here (GM)"), notCheckable = true,
              func = function() SendChatMessage(Format(p, "go"), "SAY") end },
            { text = DCL("Rename / note..."), notCheckable = true,
              func = function() StaticPopup_Show("DUNGEONCLEAR_GPS_NOTE", DCL("Note for this point:"), nil, p) end },
            { text = p.star and DCL("Unstar") or DCL("Star"), notCheckable = true,
              func = function() p.star = not p.star or nil; Render() end },
            { text = DCL("Send to chat"), notCheckable = true, hasArrow = true, menuList = chat },
            { text = "|cffff3333" .. DCL("Delete") .. "|r", notCheckable = true,
              func = function() RemovePoint(p); Render() end },
            { text = CANCEL, notCheckable = true, func = function() CloseDropDownMenus() end },
        }
        EasyMenu(menu, menuFrame, "cursor", 0, 0, "MENU")
    end

    local function ShowPointTooltip(row)
        local p = row.point
        if not p then return end
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        GameTooltip:AddLine((p.star and "|cffffd100★|r " or "") .. Label(p))
        if p.note and p.note ~= "" then GameTooltip:AddLine(Place(p), 0.8, 0.8, 0.8) end
        GameTooltip:AddLine(string.format("X %.2f  Y %.2f  Z %.2f  O %.2f", p.x, p.y, p.z, p.o), 1, 0.82, 0)
        GameTooltip:AddLine(string.format("%s %d  %s %d  %s %d", DCL("map"), p.map, DCL("zone"), p.zone or 0, DCL("area"), p.area or 0), 0.7, 0.7, 0.7)
        if p.kind == "creature" then
            GameTooltip:AddLine(string.format("%s (entry %d, spawn %d)", p.name, p.entry, p.spawn), 0.6, 0.9, 1)
        elseif p.name and p.name ~= "" then
            GameTooltip:AddLine(p.name, 0.6, 0.9, 1)
        end
        GameTooltip:AddLine(p.time or "", 0.6, 0.6, 0.6)
        GameTooltip:AddLine(DCL("Left-click: show   Right-click: more"), 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end

    local rows = {}
    for i = 1, PAGE_SIZE do
        local r = CreateFrame("Button", nil, f)
        r:SetSize(432, 18)
        r:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -154 - (i - 1) * 18)
        r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.text:SetAllPoints()
        r.text:SetJustifyH("LEFT")
        r:SetScript("OnClick", function(self, button)
            if not self.point then return end
            current = self.point
            if button == "RightButton" then ShowPointMenu(self.point) end
            Render()
        end)
        r:SetScript("OnEnter", ShowPointTooltip)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        rows[i] = r
    end

    local auto = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    auto:SetSize(22, 22)
    auto:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 6)
    local autoText = auto:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    autoText:SetPoint("LEFT", auto, "RIGHT", 0, 1)
    DCBind(autoText, "Open automatically on .gps")
    auto:SetScript("OnClick", function(self) DB().autoPopup = self:GetChecked() and true or false end)
    local clear = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clear:SetSize(70, 20)
    clear:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 8)
    DCBind(clear, "Clear")
    -- Starred points survive Clear: they are the ones worth keeping.
    clear:SetScript("OnClick", function()
        local h = DB().history
        for i = #h, 1, -1 do if not h[i].star then table.remove(h, i) end end
        if current and not current.star then current = nil end
        page = 1
        Render()
    end)
    clear:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(DCL("Clear the list (starred points are kept)."), 1, 1, 1, true)
        GameTooltip:Show()
    end)
    clear:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- DCGPS1B: send .gps for the player (the server answers with the [gps] line,
    -- which lands back in this window). Target a creature first to capture it.
    local capture = CreateFrame("Button", "DungeonClearGpsCaptureButton", f, "UIPanelButtonTemplate")
    capture:SetSize(130, 22)
    capture:SetPoint("RIGHT", clear, "LEFT", -6, 0)
    DCBind(capture, "Capture position")
    capture:SetScript("OnClick", function() SendChatMessage(".gps", "SAY") end)
    capture:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(DCL("Sends .gps (GM). With a creature targeted, records the creature instead of you."), 1, 1, 1, true)
        GameTooltip:Show()
    end)
    capture:SetScript("OnLeave", function() GameTooltip:Hide() end)

    Render = function()
        local g = DB()
        for _, b in ipairs(fmtButtons) do
            if b.key == fmt then b:LockHighlight() else b:UnlockHighlight() end
        end
        -- the list shown: everything, or starred only
        local view = {}
        for _, h in ipairs(g.history) do
            if not g.starOnly or h.star then view[#view + 1] = h end
        end
        local pages = math.max(1, math.ceil(#view / PAGE_SIZE))
        if page > pages then page = pages end
        if page < 1 then page = 1 end

        local p = current or view[1] or g.history[1]
        current = p
        if p then
            local who = (p.kind == "creature") and string.format("%s (entry %d, spawn %d)", p.name, p.entry, p.spawn)
                or (p.kind == "player" and p.name or p.kind)
            info:SetText(string.format("|cffffd100%s|r  %s  |cff999999%s  %s %d|r",
                Label(p), who, p.time or "", DCL("map"), p.map))
        else
            info:SetText("|cff999999" .. DCL("Type .gps in game (GM) to capture a point; select a creature to capture it instead.") .. "|r")
        end
        box:SetText(Format(p, fmt))
        box:SetFocus()
        box:HighlightText()
        if hintUntil == 0 then DefaultHint() end

        for i, r in ipairs(rows) do
            local h = view[(page - 1) * PAGE_SIZE + i]
            r.point = h
            if h then
                local mark = (h == p) and "|cff00ff00>|r" or " "
                local star = h.star and "|cffffd100★|r" or " "
                local who = (h.kind == "creature" and h.name ~= "") and ("  |cff99e6ff" .. h.name .. "|r") or ""
                r.text:SetText(string.format("%s%s %s  %s  |cffffd100%.1f, %.1f, %.1f|r%s",
                    mark, star, h.time or "", Label(h), h.x, h.y, h.z, who))
                r:Show()
            else
                r:Hide()
            end
        end
        pageText:SetText(string.format(DCL("Page %d/%d (%d)"), page, pages, #view))
        if page > 1 then prevBtn:Enable() else prevBtn:Disable() end
        if page < pages then nextBtn:Enable() else nextBtn:Disable() end
        auto:SetChecked(g.autoPopup and true or false)
        starOnly:SetChecked(g.starOnly and true or false)
    end

    f:SetScript("OnShow", function() Render() end)

    local ev = CreateFrame("Frame")
    ev:RegisterEvent("CHAT_MSG_SYSTEM")
    ev:SetScript("OnEvent", function(_, _, msg)
        if not msg or msg:sub(1, 5) ~= "[gps]" then return end
        local p = Parse(msg)
        if not p then return end
        local g = DB()
        table.insert(g.history, 1, p)
        -- trim the oldest unstarred points beyond the cap
        local unstarred = 0
        for i = 1, #g.history do if not g.history[i].star then unstarred = unstarred + 1 end end
        for i = #g.history, 1, -1 do
            if unstarred <= MAX_HISTORY then break end
            if not g.history[i].star then table.remove(g.history, i); unstarred = unstarred - 1 end
        end
        current = p
        page = 1
        if f:IsShown() then Render() elseif g.autoPopup then f:Show() end
    end)

    function DCGpsToggle()
        if f:IsShown() then f:Hide() else f:Show() end
    end
    DCLoc.OnChange(function() if f:IsShown() then Render() end end)
end)()

-- Chat log copy panel (RebornWOW DCCHAT1A, reworked in DCCHAT1B, 1E mirrors the chat frame, 1F records slash commands and tells your commands apart, 1G recognises chat by its channel tag).
-- Chat-frame lines cannot be selected or copied in this client, so the lines you care about
-- are kept here. Two views, picked at the top:
--   "my commands only": the commands YOU type (in the chat box or in this panel) and what
--       they print -- no bot or player talk, and no output of other addons' automatic commands;
--   "everything": the same plus all chat and other system lines, drawn in a colour you pick.
-- It has its own input line, so commands can be typed here without opening the chat box.
-- Copy with the buttons (CopyToClipboard when the client has it), or switch to "select
-- mode" to mark text with the mouse and press Ctrl+C. /dc chat, or the "Chat log" button
-- on the coordinate window.
;(function()
    -- DCCHAT1C: the whole panel is built inside pcall. If anything in this client rejects a
    -- call, the error text is printed in the chat frame (red) instead of the panel silently
    -- missing, and the open function below still exists.
    local buildError
    local stage = "start"
    local buildOk, buildErr = pcall(function()
    local CAP_MINE, CAP_CHAT = 400, 200   -- lines kept: your commands + output / everything else
    local FIRST_WAIT = 3.0                -- seconds a command waits for its first output line
    local IDLE_GAP = 1.0                  -- seconds without output that close a command's window
    local CHAT_EVENTS = {
        CHAT_MSG_SAY = "Say", CHAT_MSG_YELL = "Yell", CHAT_MSG_PARTY = "Party", CHAT_MSG_PARTY_LEADER = "Party",
        CHAT_MSG_RAID = "Raid", CHAT_MSG_RAID_LEADER = "Raid", CHAT_MSG_GUILD = "Guild",
        CHAT_MSG_WHISPER = "Whisper from", CHAT_MSG_WHISPER_INFORM = "Whisper to", CHAT_MSG_CHANNEL = "Channel",
        CHAT_MSG_MONSTER_SAY = "NPC", CHAT_MSG_MONSTER_YELL = "NPC", CHAT_MSG_MONSTER_WHISPER = "NPC",
    }
    -- Colour of the lines that are not your commands. Gray by default: red reads like an
    -- error and is hard on the eyes for long text, gray stays out of the way of your output.
    local COLORS = {
        { key = "gray",   label = "Other chat: Gray",   r = 0.62, g = 0.62, b = 0.62 },
        { key = "red",    label = "Other chat: Red",    r = 1.00, g = 0.30, b = 0.30 },
        { key = "green",  label = "Other chat: Green",  r = 0.35, g = 0.85, b = 0.35 },
        { key = "yellow", label = "Other chat: Yellow", r = 1.00, g = 0.92, b = 0.20 },
        { key = "orange", label = "Other chat: Orange", r = 1.00, g = 0.55, b = 0.10 },
        { key = "purple", label = "Other chat: Purple", r = 0.78, g = 0.50, b = 1.00 },
    }
    -- Your own lines use colours none of the choices above can be mistaken for:
    -- the command you typed in bright cyan, what it printed in white (indented).
    -- A printed line that starts with one of these "[Tag] " is somebody talking, never output.
    local CHAT_TAGS = {
        ["World"] = true, ["Guild"] = true, ["Officer"] = true, ["Party"] = true, ["Party Leader"] = true,
        ["Raid"] = true, ["Raid Leader"] = true, ["Raid Warning"] = true, ["Battleground"] = true,
        ["General"] = true, ["Trade"] = true, ["LocalDefense"] = true, ["LookingForGroup"] = true,
        ["Say"] = true, ["Yell"] = true, ["Whisper"] = true,
        ["世界"] = true, ["公会"] = true, ["官员"] = true, ["队伍"] = true, ["队长"] = true,
        ["团队"] = true, ["团队领袖"] = true, ["团队警报"] = true, ["战场"] = true, ["综合"] = true,
        ["交易"] = true, ["本地防务"] = true, ["寻求组队"] = true,
    }
    local function IsChatterLine(plain)
        local tag = plain:match("^%[([^%]]+)%] ")
        if not tag then return false end
        if tag:find("^%d+%.") then return true end     -- "[1. General]"
        return CHAT_TAGS[tag] == true
    end
    local CMD_COLOR = { r = 0.20, g = 1.00, b = 1.00 }   -- "> .command" / "> /command" lines
    local OUT_COLOR = { r = 1.00, g = 1.00, b = 1.00 }   -- what the command printed
    local echoing = false      -- true while the panel itself writes a line into the chat frame
    local sendingSlash = false -- true while the panel itself runs a slash command
    local cmdOpenUntil = 0     -- GetTime() until which printed lines count as the last command's output
    local needRender = false   -- a line was re-labelled: redraw soon

    -- call obj:name(...) only if the client has it, never let it raise
    local function Try(obj, name, ...)
        local fn = obj[name]
        if type(fn) == "function" then return pcall(fn, obj, ...) end
        return false
    end

    local function DB()
        DungeonClearDB.chatcopy = DungeonClearDB.chatcopy or {}
        local c = DungeonClearDB.chatcopy
        c.log = c.log or {}
        if c.mode ~= "all" then c.mode = "mine" end
        c.color = c.color or "gray"
        if c.filter == nil then c.filter = "wd1" end   -- hide-words; editable in the panel
        return c
    end
    local function ColorIndex(key)
        for i, c in ipairs(COLORS) do if c.key == key then return i end end
        return 1
    end

    -- Strip colour codes, links and textures: what you copy is plain text.
    local function Plain(s)
        s = tostring(s or "")
        s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        s = s:gsub("|H.-|h(.-)|h", "%1")
        s = s:gsub("|T.-|t", "")
        s = s:gsub("||", "|")
        return s
    end

    stage = "window"
    local f = CreateFrame("Frame", "DungeonClearChatCopyFrame", UIParent)
    f:SetSize(640, 470)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    f:SetBackdropColor(0.03, 0.03, 0.05, 0.94)
    f:SetBackdropBorderColor(0.20, 0.22, 0.28, 1.0)
    f:Hide()
    tinsert(UISpecialFrames, "DungeonClearChatCopyFrame")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -12)
    DCBind(title, "Chat log")
    title:SetTextColor(0.24, 0.60, 1.0)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    local count = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    count:SetPoint("RIGHT", close, "LEFT", -8, 0)

    local function Tip(w, text)
        w:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(DCL(text), 1, 1, 1, true)
            GameTooltip:Show()
        end)
        w:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    local function Button(label, w, onClick, tip)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(w, 22)
        DCBind(b, label)
        b:SetScript("OnClick", onClick)
        if tip then Tip(b, tip) end
        return b
    end

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -62)
    hint:SetPoint("RIGHT", f, "RIGHT", -14, 0)
    hint:SetJustifyH("LEFT")
    local hintUntil = 0
    local function Hint(text, seconds)
        hint:SetText(text)
        hintUntil = seconds and (GetTime() + seconds) or 0
    end
    local function DefaultHint()
        Hint(DCL("Wheel scrolls (Shift = page). Type a command in the box below. Select mode lets you mark text with the mouse."))
    end

    stage = "views"
    -- ------------------------------------------------------------ the two views
    local bg = CreateFrame("Frame", nil, f)
    bg:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -78)
    bg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 74)
    bg:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground", tile = true, tileSize = 16 })
    bg:SetBackdropColor(0, 0, 0, 0.5)

    -- coloured, scrolling view (no keyboard focus, so Enter still opens the chat box)
    local view = CreateFrame("ScrollingMessageFrame", "DungeonClearChatCopyView", bg)
    view:SetPoint("TOPLEFT", bg, "TOPLEFT", 8, -6)
    view:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", -8, 6)
    if not Try(view, "SetFontObject", ChatFontNormal) then
        Try(view, "SetFont", STANDARD_TEXT_FONT or "Fonts\FRIZQT__.TTF", 13)   -- fallback
    end
    Try(view, "SetJustifyH", "LEFT")
    Try(view, "SetFading", false)
    Try(view, "SetMaxLines", 600)
    Try(view, "EnableMouseWheel", true)
    view:SetScript("OnMouseWheel", function(self, delta)
        if IsShiftKeyDown() then
            Try(self, delta > 0 and "PageUp" or "PageDown")
        else
            for _ = 1, 3 do Try(self, delta > 0 and "ScrollUp" or "ScrollDown") end
        end
    end)

    -- plain, selectable view (select mode)
    local scroll = CreateFrame("ScrollFrame", "DungeonClearChatCopyScroll", bg, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", bg, "TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", -26, 6)
    local eb = CreateFrame("EditBox", "DungeonClearChatCopyEditBox", scroll)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetFontObject(ChatFontNormal)
    eb:SetWidth(580)
    eb:SetHeight(300)
    eb:SetMaxLetters(0)
    scroll:SetScrollChild(eb)
    scroll:Hide()
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnCursorChanged", function(self, x, y, w, h) ScrollingEdit_OnCursorChanged(self, x, y, w, h) end)
    eb:SetScript("OnUpdate", function(self, elapsed) ScrollingEdit_OnUpdate(self, elapsed, scroll) end)

    local selectMode = false
    local shownText = ""
    -- the box is for selecting, not editing: a typed change is put back
    eb:SetScript("OnTextChanged", function(self, userInput)
        if userInput and self:GetText() ~= shownText then self:SetText(shownText) end
    end)

    stage = "log"
    -- ------------------------------------------------------------ the log
    local function Visible(e) return DB().mode == "all" or e.kind ~= "chat" end
    local function ColorOf(e)
        if e.kind == "cmd" then return CMD_COLOR end
        if e.kind == "out" then return OUT_COLOR end
        return COLORS[ColorIndex(DB().color)]
    end
    local function LineText(e)
        return "[" .. e.t .. "] " .. (e.kind == "out" and "    " or "") .. e.text
    end
    local function VisibleText()
        local out = {}
        for _, e in ipairs(DB().log) do
            if Visible(e) then out[#out + 1] = LineText(e) end
        end
        return table.concat(out, "\n")
    end
    local function UpdateCount()
        local n = 0
        for _, e in ipairs(DB().log) do if Visible(e) then n = n + 1 end end
        count:SetText(string.format(DCL("%d lines"), n))
    end
    local function RefreshSelect()
        shownText = VisibleText()
        eb:SetText(shownText)
        scroll:UpdateScrollChildRect()
        scroll:SetVerticalScroll(scroll:GetVerticalScrollRange())
    end
    local function Render()
        view:Clear()
        for _, e in ipairs(DB().log) do
            if Visible(e) then
                local c = ColorOf(e)
                view:AddMessage(LineText(e), c.r, c.g, c.b)
            end
        end
        Try(view, "ScrollToBottom")
        if selectMode then RefreshSelect() end
        UpdateCount()
    end

    local function Trim(log)
        local mine, chat = 0, 0
        for _, e in ipairs(log) do if e.kind == "chat" then chat = chat + 1 else mine = mine + 1 end end
        local i = 1
        while (chat > CAP_CHAT or mine > CAP_MINE) and i <= #log do
            local e = log[i]
            if e.kind == "chat" and chat > CAP_CHAT then table.remove(log, i); chat = chat - 1
            elseif e.kind ~= "chat" and mine > CAP_MINE then table.remove(log, i); mine = mine - 1
            else i = i + 1 end
        end
    end

    -- lines containing any of the words typed in the "Hide" box are not recorded at all
    local function Blocked(text)
        local filt = DB().filter
        if not filt or filt == "" then return false end
        local low = text:lower()
        for term in filt:gmatch("[^,;%s]+") do
            if low:find(term:lower(), 1, true) then return true end
        end
        return false
    end

    local function Add(kind, text)
        local c = DB()
        if c.paused then return end
        local plain = Plain(text)
        if Blocked(plain) then return end
        local e = { t = date("%H:%M:%S"), at = GetTime(), kind = kind, text = plain }
        c.log[#c.log + 1] = e
        Trim(c.log)
        if f:IsShown() and Visible(e) then
            local col = ColorOf(e)
            view:AddMessage(LineText(e), col.r, col.g, col.b)
            if selectMode and not eb:HasFocus() then RefreshSelect() end
            UpdateCount()
        end
        return e
    end

    -- A command you typed. Dot commands are answered by the server a little later, so the
    -- window for its output opens now. A local slash command (/run print(...)) prints its
    -- output at once, before this hook runs: pull those lines up under the command.
    local function NoteCommand(text, backfill)
        local c = DB()
        if c.paused then return end
        local now = GetTime()
        cmdOpenUntil = now + FIRST_WAIT
        if not backfill then Add("cmd", "> " .. text); return end
        local plain = Plain("> " .. text)
        if Blocked(plain) then return end
        local log = c.log
        local first = #log + 1
        while first > 1 and log[first - 1].at and log[first - 1].at >= now - 0.15 and log[first - 1].kind ~= "cmd" do
            first = first - 1
        end
        table.insert(log, first, { t = date("%H:%M:%S"), at = now, kind = "cmd", text = plain })
        for i = first + 1, #log do
            if log[i].kind == "chat" and not log[i].chatter then log[i].kind = "out" end
        end
        Trim(log)
        needRender = true
    end

    -- ------------------------------------------------------------ copy
    local function SelectText(text)
        selectMode = true
        view:Hide(); scroll:Show()
        shownText = text
        eb:SetText(text)
        eb:SetFocus()
        eb:HighlightText()
    end
    local function Copy(text)
        if not text or text == "" then
            Hint("|cffffd100" .. DCL("Nothing to copy yet.") .. "|r", 3)
            return
        end
        if CopyToClipboard then
            CopyToClipboard(text)
            Hint("|cff33ff33" .. DCL("Copied to the clipboard.") .. "|r", 3)
        else
            SelectText(text)
            Hint("|cffffd100" .. DCL("This client cannot copy directly: press Ctrl+C.") .. "|r", 8)
        end
    end
    -- the last command you typed and everything it printed
    local function LastCommandText()
        local log = DB().log
        local from
        for i = #log, 1, -1 do
            if log[i].kind == "cmd" then from = i; break end
        end
        if not from then return nil end
        local out = { LineText(log[from]) }
        for i = from + 1, #log do
            if log[i].kind == "out" then out[#out + 1] = LineText(log[i]) else break end
        end
        return table.concat(out, "\n")
    end

    stage = "top row"
    -- ------------------------------------------------------------ top row: view, colour, pause
    -- two side-by-side choices, the active one stays highlighted
    local mineBtn, allBtn, colorBtn
    local function ApplyTopRow()
        local c = DB()
        if c.mode == "all" then
            mineBtn:UnlockHighlight(); allBtn:LockHighlight(); colorBtn:Enable()
        else
            mineBtn:LockHighlight(); allBtn:UnlockHighlight(); colorBtn:Disable()
        end
        DCBind(colorBtn, COLORS[ColorIndex(c.color)].label)
    end
    mineBtn = Button("My commands", 110, function()
        DB().mode = "mine"
        ApplyTopRow(); Render()
    end, "Only the commands you type (in the chat box or in this panel) and what they print. No bot or player talk, nothing printed by other tools.")
    mineBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -36)
    allBtn = Button("Everything", 90, function()
        DB().mode = "all"
        ApplyTopRow(); Render()
    end, "Everything the chat box shows, plus your commands. Lines that are not yours use the colour on the right.")
    allBtn:SetPoint("LEFT", mineBtn, "RIGHT", 2, 0)
    colorBtn = Button("Other chat: Gray", 130, function()
        local c = DB()
        c.color = COLORS[ColorIndex(c.color) % #COLORS + 1].key
        ApplyTopRow(); Render()
    end, "Colour of the lines that are not your commands (click to cycle). Only used in 'Everything'. Gray stays out of the way; red looks like an error and is tiring to read.")
    colorBtn:SetPoint("LEFT", allBtn, "RIGHT", 8, 0)

    local pause = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    pause:SetSize(22, 22)
    pause:SetPoint("LEFT", colorBtn, "RIGHT", 10, 0)
    local pauseText = pause:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pauseText:SetPoint("LEFT", pause, "RIGHT", 0, 1)
    DCBind(pauseText, "Pause recording")
    pause:SetScript("OnClick", function(self) DB().paused = self:GetChecked() and true or false end)

    -- words to hide: noise from other tools (an automatic test command that prints every second ...)
    local filterLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    filterLabel:SetPoint("LEFT", pauseText, "RIGHT", 12, 0)
    DCBind(filterLabel, "Hide:")
    local filterBox = CreateFrame("EditBox", "DungeonClearChatCopyFilter", f, "InputBoxTemplate")
    filterBox:SetSize(110, 20)
    filterBox:SetPoint("LEFT", filterLabel, "RIGHT", 8, 0)
    filterBox:SetAutoFocus(false)
    filterBox:SetMaxLetters(80)
    filterBox:SetFontObject(ChatFontNormal)
    filterBox:SetScript("OnTextChanged", function(self, userInput)
        if userInput then DB().filter = self:GetText() end
    end)
    filterBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    filterBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    Tip(filterBox, "Lines containing any of these words (separate them with commas) are not recorded. Use it to hide the noise of other tools. Capital letters do not matter.")

    stage = "input line"
    -- ------------------------------------------------------------ bottom: input line
    local input = CreateFrame("EditBox", "DungeonClearChatCopyInput", f, "InputBoxTemplate")
    input:SetSize(540, 22)
    input:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 40)
    input:SetAutoFocus(false)
    input:SetMaxLetters(255)
    input:SetFontObject(ChatFontNormal)
    Try(input, "SetAltArrowKeyMode", false)
    local inputHint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    inputHint:SetPoint("BOTTOMLEFT", input, "TOPLEFT", -4, 2)
    DCBind(inputHint, "Command (starts with . or /), Enter sends, Esc or a click outside leaves the box:")

    local history, histPos = {}, 0
    local panelSending = false
    local function Send(text)
        if text:sub(1, 1) == "/" then
            -- slash commands go through the normal chat parser
            local box = DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox or ChatFrame1EditBox
            if box then
                NoteCommand(text)
                sendingSlash = true
                pcall(function() box:SetText(text); ChatEdit_SendText(box, 1) end)
                sendingSlash = false
            end
            return
        end
        if text:sub(1, 1) == "." and DEFAULT_CHAT_FRAME then
            echoing = true
            DEFAULT_CHAT_FRAME:AddMessage("|cff3da6ff> " .. text .. "|r")   -- also in the chat frame
            echoing = false
        end
        panelSending = true
        SendChatMessage(text, "SAY")
        panelSending = false
    end
    input:SetScript("OnEnterPressed", function(self)
        local text = (self:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if text == "" then self:ClearFocus(); return end
        history[#history + 1] = text
        if #history > 40 then table.remove(history, 1) end
        histPos = #history + 1
        self:SetText("")
        Send(text)
    end)
    input:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    -- command history on Up/Down: optional, a client that rejects it just has no history
    pcall(input.SetScript, input, "OnArrowPressed", function(self, key)
        if key == "UP" and histPos > 1 then histPos = histPos - 1
        elseif key == "DOWN" and histPos <= #history then histPos = histPos + 1
        else return end
        self:SetText(history[histPos] or "")
    end)

    stage = "buttons"
    -- ------------------------------------------------------------ bottom: buttons
    local copyAll = Button("Copy all", 90, function() Copy(VisibleText()) end, "Copy every line shown.")
    copyAll:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 10)
    local copyLast = Button("Copy last command", 150, function()
        local t = LastCommandText()
        if not t then
            Hint("|cffffd100" .. DCL("No command found. Type a command starting with a dot first.") .. "|r", 4)
            return
        end
        Copy(t)
    end, "The command you typed last and everything it printed.")
    copyLast:SetPoint("LEFT", copyAll, "RIGHT", 6, 0)
    local selectBtn
    selectBtn = Button("Select mode", 100, function()
        selectMode = not selectMode
        if selectMode then
            view:Hide(); scroll:Show(); RefreshSelect()
            DCBind(selectBtn, "Back to view")
        else
            eb:ClearFocus(); scroll:Hide(); view:Show()
            DCBind(selectBtn, "Select mode")
            Render()
        end
    end, "Show the lines as plain text you can mark with the mouse and copy with Ctrl+C.")
    selectBtn:SetPoint("LEFT", copyLast, "RIGHT", 6, 0)
    local latest = Button("Scroll to latest", 110, function() Try(view, "ScrollToBottom") end)
    latest:SetPoint("LEFT", selectBtn, "RIGHT", 6, 0)
    local clear = Button("Clear", 70, function() wipe(DB().log); Render() end)
    clear:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)

    f:SetScript("OnUpdate", function()
        if hintUntil > 0 and GetTime() > hintUntil then hintUntil = 0; DefaultHint() end
        -- a click anywhere outside the panel gives the keyboard back (Enter opens the chat box again)
        if (input:HasFocus() or eb:HasFocus() or filterBox:HasFocus()) and IsMouseButtonDown("LeftButton") and not MouseIsOver(f) then
            input:ClearFocus(); eb:ClearFocus(); filterBox:ClearFocus()
        end
        if needRender and f:IsShown() then needRender = false; Render() end
    end)
    f:SetScript("OnHide", function() input:ClearFocus(); eb:ClearFocus(); filterBox:ClearFocus() end)

    stage = "recording"
    -- ------------------------------------------------------------ what gets recorded

    -- A command counts as "yours" only when it came from a chat edit box (you typed it and
    -- pressed Enter) or from this panel's input line. Other addons that send commands by
    -- themselves (automatic test tools) are not yours and are left out of "my commands".
    local function TypedByUser()
        if panelSending then return true end
        local fo = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus() or nil
        if not fo then return false end
        local name = fo.GetName and fo:GetName() or ""
        return fo.chatFrame ~= nil or name:find("^ChatFrame%d+EditBox$") ~= nil
    end
    pcall(hooksecurefunc, "SendChatMessage", function(msg)
        if not DungeonClearDB or type(msg) ~= "string" or msg:sub(1, 1) ~= "." then return end
        local ok = pcall(function()
            if not TypedByUser() then return end
            NoteCommand(msg)
        end)
    end)

    -- Slash commands typed in a chat box do not go through SendChatMessage. Remember the
    -- last text of each chat edit box and read it when the box is sent.
    local lastTyped = {}
    local function WatchEditBox(box)
        if box.dcWatched then return end
        box.dcWatched = true
        box:HookScript("OnTextChanged", function(self)
            local t = self:GetText()
            if t and t ~= "" then lastTyped[self] = t end
        end)
        box:HookScript("OnEditFocusGained", function(self) lastTyped[self] = nil end)
    end
    for i = 1, (NUM_CHAT_WINDOWS or 7) do
        local box = _G["ChatFrame" .. i .. "EditBox"]
        if box then pcall(WatchEditBox, box) end
    end
    pcall(hooksecurefunc, "ChatEdit_SendText", function(box)
        local t = lastTyped[box]
        lastTyped[box] = nil
        if sendingSlash or not t then return end
        if t:sub(1, 1) == "/" and not t:find("^/dc%s+chat") then NoteCommand(t, true) end
    end)

    -- What is recorded is what the chat frame shows: its AddMessage is hooked, so lines other
    -- addons print straight into the chat box are caught too. The CHAT_MSG_* events are only
    -- used to tell player/bot talk (not command output) apart, in either order of arrival.
    local chatterTick = -1     -- GetTime() of the last chat event (same frame = same message)
    local chatterBodies = {}   -- { plain text of a chat event, expires }
    local function RememberChatter(body)
        local pb = Plain(body)
        if pb == "" then return end
        chatterBodies[#chatterBodies + 1] = { pb, GetTime() + 4 }
        if #chatterBodies > 80 then table.remove(chatterBodies, 1) end
    end
    local function IsChatterBody(plain)
        local now = GetTime()
        for i = #chatterBodies, 1, -1 do
            local r = chatterBodies[i]
            if r[2] < now then table.remove(chatterBodies, i)
            elseif plain:find(r[1], 1, true) then return true end
        end
        return false
    end
    -- the event arrived AFTER its line was printed: the line was taken for command output
    local function RelabelAsChatter(body)
        local pb = Plain(body)
        if pb == "" then return false end
        local log = DB().log
        for i = #log, math.max(1, #log - 6), -1 do
            local e = log[i]
            if e.kind == "out" and e.text:find(pb, 1, true) then e.kind = "chat"; return true end
        end
        return false
    end

    -- the chat box can show its own "[06:33:14] " in front of each line: drop it, the panel has its own
    local function StripStamp(s)
        s = s:gsub("^%[%d%d?:%d%d:?%d*%s*[APMapm]*%]%s*", "")
        s = s:gsub("^%d%d?:%d%d:?%d*%s*[APMapm]*%s+", "")
        return s
    end

    local function OnChatLine(_, text)
        if echoing or not DungeonClearDB or type(text) ~= "string" then return end
        local plain = StripStamp(Plain(text))
        if plain == "" then return end
        -- "[World] [Name]: text" lines are chat the server prints as ordinary text
        local chatter = IsChatterLine(plain) or plain:find("^%[[^%]]+%] %[[^%]]+%]:") ~= nil
            or chatterTick == GetTime() or IsChatterBody(plain)
        if not chatter and GetTime() <= cmdOpenUntil then
            Add("out", plain)
            cmdOpenUntil = GetTime() + IDLE_GAP
        else
            local e = Add("chat", plain)
            if e and chatter then e.chatter = true end
        end
    end
    local chatFrame = DEFAULT_CHAT_FRAME or _G["ChatFrame1"]
    if chatFrame then pcall(hooksecurefunc, chatFrame, "AddMessage", OnChatLine) end

    local ev = CreateFrame("Frame")
    for e in pairs(CHAT_EVENTS) do pcall(ev.RegisterEvent, ev, e) end
    ev:SetScript("OnEvent", function(_, _, msg)
        if not DungeonClearDB or type(msg) ~= "string" then return end
        RememberChatter(msg)
        local now = GetTime()
        chatterTick = now
        -- the line may have been printed a moment before this event: same frame -> same message
        local log = DB().log
        for i = #log, math.max(1, #log - 6), -1 do
            local e = log[i]
            if e.at == now and e.kind == "out" then e.kind = "chat"; e.chatter = true; needRender = true end
        end
        if RelabelAsChatter(msg) then needRender = true end
    end)

    f:SetScript("OnShow", function()
        local ok, e = pcall(function()
            pause:SetChecked(DB().paused and true or false)
            filterBox:SetText(DB().filter or "")
            ApplyTopRow()
            DefaultHint()
            Render()
        end)
        if not ok and DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff3333[DungeonClear] chat log panel error: " .. tostring(e) .. "|r")
        end
    end)

    DCLoc.OnChange(function() if f:IsShown() then ApplyTopRow(); DefaultHint(); UpdateCount() end end)
    end)  -- pcall
    if not buildOk then
        buildError = "|cffff3333[DungeonClear] chat log panel failed to build (stage: " .. stage .. "): " .. tostring(buildErr) .. "|r"
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(buildError) end
    end
    local frame = _G["DungeonClearChatCopyFrame"]
    function DCChatCopyToggle()
        if buildError and DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(buildError) end
        if not frame then return end
        if frame:IsShown() then frame:Hide() else frame:Show() end
    end
end)()

-- Corpse-run choice (RebornWOW DCRZ2B). When nobody in your party can resurrect, the
-- clear no longer stops: a corpse run counts down, then the dead bots revive at the
-- entrance and the clear continues. Choose: wait for me / run now / stop.
;(function()
    local f = CreateFrame("Frame", "DungeonClearCorpseRunFrame", UIParent)
    f:SetSize(360, 112)
    f:SetPoint("TOP", UIParent, "TOP", 0, -140)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    f:SetBackdropColor(0.08, 0.03, 0.03, 0.94)
    f:SetBackdropBorderColor(0.6, 0.2, 0.2, 1.0)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -12)
    DCBind(title, "No one can resurrect")
    title:SetTextColor(1, 0.4, 0.4)
    local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("TOP", title, "BOTTOM", 0, -6)
    text:SetWidth(330)

    local dueAt, waiting = nil, false
    local function Refresh()
        if waiting then
            text:SetText(DCL("Waiting for you to resurrect the party."))
        elseif dueAt then
            local left = math.max(0, math.ceil(dueAt - GetTime()))
            text:SetText(string.format(DCL("Corpse run in %ds: the dead bots revive at the entrance."), left))
        end
    end
    f:SetScript("OnUpdate", function() Refresh() end)

    local function Btn(label, x, choice)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(104, 22)
        b:SetPoint("BOTTOM", f, "BOTTOM", x, 12)
        DCBind(b, label)
        b:SetScript("OnClick", function()
            SendDcCommand("rezchoice", choice, true)
            if choice == "wait" then waiting = true; Refresh()
            elseif choice == "stop" then f:Hide() end
        end)
        return b
    end
    Btn("Wait for me", -110, "wait")
    Btn("Run now", 0, "run")
    Btn("Stop clear", 110, "stop")

    function DCRezOnAddon(parts)
        local kind = parts[2]
        if kind == "count" then
            waiting = false
            dueAt = GetTime() + (tonumber(parts[3]) or 30)
            Refresh()
            f:Show()
        elseif kind == "wait" then
            waiting = true
            Refresh()
            f:Show()
        elseif kind == "end" then
            f:Hide()
            dueAt, waiting = nil, false
        end
    end
end)()

-- RebornWOW DCICON1A: the coordinate box and the chat log panel each get their own
-- minimap icon, so neither needs the Dungeon Clear window open. Same behaviour as the
-- Dungeon Clear button: left-click toggles, drag moves it around the minimap (angle
-- saved per icon). Names end in a letter so RebornDock can collect them. /dc icons
-- hides or shows both.
do
    local toolIcons = {}

    local function MakeToolIcon(name, texture, posKey, defaultPos, title, tip, onClick)
        local b = CreateFrame("Button", name, Minimap)
        b:SetFrameStrata("MEDIUM")
        b:SetFrameLevel(8)
        b:SetSize(31, 31)
        b:RegisterForClicks("LeftButtonUp")
        b:RegisterForDrag("LeftButton")
        b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

        local border = b:CreateTexture(nil, "OVERLAY")
        border:SetSize(53, 53)
        border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
        border:SetPoint("TOPLEFT")

        local icon = b:CreateTexture(nil, "BACKGROUND")
        icon:SetSize(20, 20)
        icon:SetTexture(texture)
        icon:SetPoint("CENTER", b, "CENTER", 0, 1)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        b.icon = icon

        local function Place()
            local angle = math.rad(DungeonClearDB[posKey] or defaultPos)
            b:ClearAllPoints()
            b:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(angle), 80 * math.sin(angle))
        end
        b.Place = Place

        b:SetScript("OnDragStart", function(self)
            self:SetScript("OnUpdate", function()
                local mx, my = Minimap:GetCenter()
                local scale = Minimap:GetEffectiveScale()
                local px, py = GetCursorPosition()
                px, py = px / scale, py / scale
                DungeonClearDB[posKey] = math.deg(math.atan2(py - my, px - mx))
                Place()
            end)
        end)
        b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
        b:SetScript("OnClick", function() onClick() end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine(DCL(title))
            GameTooltip:AddLine(DCL(tip), 1, 1, 1, true)
            GameTooltip:AddLine(DCL("Drag to reposition this button."), 1, 1, 1)
            GameTooltip:AddLine(DCL("/dc icons hides or shows these icons."), 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)

        Place()
        toolIcons[#toolIcons + 1] = b
        return b
    end

    MakeToolIcon("DungeonClearGpsButton", "Interface\\Icons\\INV_Misc_Map_01", "gpsIconPos", 225,
        "Coordinates", "Open the coordinate copy box. Also /dc gps.",
        function() if DCGpsToggle then DCGpsToggle() end end)
    MakeToolIcon("DungeonClearChatLogButton", "Interface\\Icons\\INV_Misc_Note_01", "chatIconPos", 250,
        "Chat log", "Command output and chat lines in a box you can copy from. Also /dc chat.",
        function() if DCChatCopyToggle then DCChatCopyToggle() end end)

    local function ApplyShown()
        for _, b in ipairs(toolIcons) do
            if DungeonClearDB.toolIconsHidden then b:Hide() else b:Show() end
        end
    end

    function DCToolIconsToggle()
        DungeonClearDB.toolIconsHidden = not DungeonClearDB.toolIconsHidden
        ApplyShown()
        if DungeonClearDB.toolIconsHidden then
            DEFAULT_CHAT_FRAME:AddMessage("|cff3da6ffDungeonClear|r " .. DCL("Coordinate and chat log icons hidden. /dc icons shows them again."))
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cff3da6ffDungeonClear|r " .. DCL("Coordinate and chat log icons shown."))
        end
    end

    -- Saved angles arrive with ADDON_LOADED, after this file ran (see mmLoader).
    local loader = CreateFrame("Frame")
    loader:RegisterEvent("ADDON_LOADED")
    loader:SetScript("OnEvent", function(self, _, name)
        if name == AddonName then
            for _, b in ipairs(toolIcons) do b.Place() end
            ApplyShown()
            self:UnregisterEvent("ADDON_LOADED")
        end
    end)
end

-- Slash Command Registration
SLASH_DUNGEONCLEAR1 = "/dc"
SlashCmdList["DUNGEONCLEAR"] = function(msg)
    if msg == "" then
        if frame:IsVisible() then
            frame:Hide()
        else
            -- Always reopen in full (non-tiny) mode
            DungeonClearDB.tinyMode = false
            UpdateLayout()
            frame:Show()
        end
    elseif msg == "lang" then
        DCLoc.Toggle()
    elseif msg == "gps" then
        -- RebornWOW DCGPS1A: coordinate copy box
        if DCGpsToggle then DCGpsToggle() end
    elseif msg == "chat" then
        -- RebornWOW DCCHAT1A: chat log copy panel
        if DCChatCopyToggle then DCChatCopyToggle() end
    elseif msg == "gm" then
        -- RebornWOW DCGM1D: GM kill / raise menu for your own party
        if DCMyPartyMenu then DCMyPartyMenu() end
    elseif msg == "icons" then
        -- RebornWOW DCICON1A: hide or show the coordinate / chat log minimap icons
        if DCToolIconsToggle then DCToolIconsToggle() end
    else
        -- Parse "/dc <sub> [param]" and send via addon message
        local subCmd, param = msg:match("^(%S+)%s*(.*)$")
        if subCmd then
            SendDcCommand(subCmd, param)
        end
    end
end

-- Print loaded notice
DEFAULT_CHAT_FRAME:AddMessage("|cff3da6ffDungeonClear Addon v3.6-reborn14 loaded.|r Type /dc to toggle window, or see Interface > AddOns > DungeonClear.")
