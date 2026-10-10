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
for i = 1, VISIBLE_ROWS do
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

    local function EditBox(w, numeric)
        local e = CreateFrame("EditBox", nil, tf, "InputBoxTemplate")
        e:SetSize(w, 20)
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
    local listRows = {}
    local filtered = {}

    for i = 1, ROWS do
        local r = CreateFrame("Button", nil, listBox)
        r:SetSize(318, ROW_H)
        r:SetPoint("TOPLEFT", listBox, "TOPLEFT", 6, -4 - (i - 1) * ROW_H)
        r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.text:SetAllPoints()
        r.text:SetJustifyH("LEFT")
        r:SetScript("OnClick", function(self)
            if self.row then
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
        if revealSelection then
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
        local b = Button(m.label, 96, function() DB().mode = m.key; ApplyMode() end, m.tip)
        if i == 1 then b:SetPoint("LEFT", modeLabel, "RIGHT", 6, 0)
        else b:SetPoint("LEFT", modeBtns[i - 1], "RIGHT", 2, 0) end
        b.key = m.key
        modeBtns[i] = b
    end

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
    for i, role in ipairs(ROSTER_ROLES) do
        local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
        local l = tf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        l:SetPoint("TOPLEFT", tf, "TOPLEFT", 16 + col * 116, y - 4 - row * 24)
        DCBind(l, role)
        local e = EditBox(68)
        e:SetPoint("LEFT", l, "RIGHT", 6, 0)
        e:SetScript("OnTextChanged", function(self) DB().roster[i] = self:GetText() end)
        rosterBoxes[i] = e
        rosterGroup[#rosterGroup + 1] = l
        rosterGroup[#rosterGroup + 1] = e
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
        t.ilvl, t.seed = ilvlBox:GetText(), seedBox:GetText()
        Send(cmd)
        if t.autoWatch then watchAt = GetTime() + 10 end
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
        text = "%s",
        button1 = YES, button2 = NO,
        OnShow = function(self) self.text:SetText(DCL("Stop ALL bot test runs and test plans?")) end,
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
    lf:SetSize(392, 640)
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
    local lRefresh = LButton(lf, "Refresh", 64, function() SendDcCommand("testruns", "", true) end)
    lRefresh:SetPoint("TOPRIGHT", lf, "TOPRIGHT", -14, -34)


    local runs, selectedRun, runOffset = {}, nil, 0
    local gear = nil   -- { name, class, level, ilvl, items = { {slot, id, ilvl, q} } }
    local pending, gearPending = nil, nil
    local info, infoPending = nil, nil   -- DCTEST3A run stats: { id, kills, deaths }
    local bottomMode = "gear"            -- what the bottom box shows: "gear" | "stats"
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
    local runBox = Panel(lf, 10, -58, 372, RUN_ROWS * RUN_H + 8)
    local VIEW_H = 28  -- DCTEST4C: the camera row under the runs
    runBox:EnableMouseWheel(true)
    local runRows = {}
    local RenderRuns, RenderMembers, RenderGear  -- forward

    for i = 1, RUN_ROWS do
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
                if button == "RightButton" and DCTestShowRunMenu then DCTestShowRunMenu(self.run) end
            end
        end)
        runRows[i] = r
    end
    runBox:SetScript("OnMouseWheel", function(_, delta)
        runOffset = math.max(0, math.min(runOffset - delta, #runs - RUN_ROWS))
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
    local MEM_ROWS, MEM_H = 5, 20
    local memBox = Panel(lf, 10, -58 - RUN_ROWS * RUN_H - 32 - VIEW_H, 372, MEM_ROWS * MEM_H + 8)
    local memRows = {}
    for i = 1, MEM_ROWS do
        local r = CreateFrame("Frame", nil, memBox)
        r:SetSize(362, MEM_H)
        r:SetPoint("TOPLEFT", memBox, "TOPLEFT", 5, -4 - (i - 1) * MEM_H)
        r.cls = r:CreateTexture(nil, "ARTWORK")
        r.cls:SetSize(16, 16)
        r.cls:SetPoint("LEFT", r, "LEFT", 1, 0)
        r.cls:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
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

    local function RenderStats()
        local run = info and FindRun(info.id)
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
        end
        for i = #lines, 1, -1 do statsBox:AddMessage(lines[i]) end
    end

    local runMenuFrame = CreateFrame("Frame", "DungeonClearTestRunMenu", UIParent, "UIDropDownMenuTemplate")

    -- The same test again: same dungeon, difficulty, seed (= same party) and gear.
    local function ReplayCommand(run)
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

    function DCTestShowRunMenu(run)
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
            { text = DCL("Run it again (same seed and gear)"), notCheckable = true, disabled = run.roster,
              func = function() Send(ReplayCommand(run)) end },
            { text = DCL("Copy its settings to the left"), notCheckable = true, func = function()
                local t = DB()
                t.token, t.heroic, t.mode = run.token, run.heroic, "random"
                t.ilvl = (run.gearIlvl or 0) > 0 and tostring(run.gearIlvl) or ""
                t.seed = (run.seed or 0) > 0 and tostring(run.seed) or ""
                t.quality = ({ [2] = 2, [3] = 3, [4] = 4 })[run.gearQuality or 0] or 1
                tf:Hide(); tf:Show()
            end },
            { text = "|cffff3333" .. DCL("Stop this test") .. "|r", notCheckable = true, func = function()
                StaticPopup_Show("DUNGEONCLEAR_TEST_STOPONE",
                    string.format(DCL("Stop the test run %s (%s)?"), run.id, DungeonName(run.token)), nil,
                    function() Send(".dc test stop " .. run.id); capture.relistAt = GetTime() + 2 end)
            end },
            { text = CANCEL, notCheckable = true, func = function() CloseDropDownMenus() end },
        }
        EasyMenu(menu, runMenuFrame, "cursor", 0, 0, "MENU")
    end

    function DCTestShowMemberMenu(m)
        local run = FindRun(selectedRun)
        if not run then return end
        local menu = {
            { text = m.name, isTitle = true, notCheckable = true },
            { text = DCL("Follow this bot (camera)"), notCheckable = true, func = function() FollowBot(run, m.name) end },
            { text = DCL("Details (gear, stats, talents)"), notCheckable = true, func = function() if DCTestInspect then DCTestInspect(m.name) end end },
            { text = DCL("Show its gear"), notCheckable = true, func = function() SendDcCommand("testgear", m.name, true) end },
            { text = DCL("Teleport next to it (.appear)"), notCheckable = true, func = function() Send(".appear " .. m.name) end },
            { text = CANCEL, notCheckable = true, func = function() CloseDropDownMenus() end },
        }
        EasyMenu(menu, runMenuFrame, "cursor", 0, 0, "MENU")
    end

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
        else b:SetPoint("TOPLEFT", lf, "TOPLEFT", 14, -58 - RUN_ROWS * RUN_H - 14) end
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
        if not run then
            memLabel:SetText(DCL("Party"))
            for _, r in ipairs(memRows) do r:Hide() end
            return
        end
        memLabel:SetText(DCL("Party") .. ": " .. DungeonName(run.token) .. "  |cff999999" .. run.id .. "|r")
        for i, r in ipairs(memRows) do
            local m = run.members[i]
            r.member = m
            if m then
                local token = CLASS_TOKENS[m.class]
                local tc = token and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[token]
                if tc then r.cls:SetTexCoord(unpack(tc)); r.cls:Show() else r.cls:Hide() end
                local cc = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
                local color = cc and string.format("|cff%02x%02x%02x", cc.r * 255, cc.g * 255, cc.b * 255) or "|cffcccccc"
                local role = DCL(ROLE_TAGS[m.role] or m.role)
                local hp = m.alive and (m.hp .. "%") or ("|cffff3333" .. DCL("dead") .. "|r")
                local mp = (m.mp >= 0) and ("  " .. DCL("MP") .. " " .. m.mp .. "%") or ""
                local fight = m.combat and " |cffff6600*|r" or ""
                r.text:SetText(string.format("|cffffd100%s|r  %s%s|r  %s %d  %s %d  %s %s%s%s",
                    role, color, m.name, DCL("Lv"), m.level, DCL("iLvl"), m.ilvl, DCL("HP"), hp, mp, fight))
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
        lCount:SetWidth(196)
        lCount:SetText(DCL("Running:") .. " " .. #runs .. capText)
        local found = false
        for _, r in ipairs(runs) do if r.id == selectedRun then found = true end end
        if not found then selectedRun = runs[1] and runs[1].id or nil end
        runOffset = math.max(0, math.min(runOffset, #runs - RUN_ROWS))
        for i, row in ipairs(runRows) do
            local run = runs[i + runOffset]
            row.run = run
            if run then
                local mark = run.watching and ("|cff00ff00" .. DCL("Watching") .. "|r  ") or ""
                local heroic = run.heroic and (" |cffff8000" .. DCL("(Heroic)") .. "|r") or ""
                local stage = DCL(STAGES[run.stage] or run.stage)
                local alert = run.wiped and ("  |cffff3333" .. DCL("wiped") .. "|r") or (run.combat and ("  |cffff6600" .. DCL("in combat") .. "|r") or "")
                local dead = (run.deaths and run.deaths > 0) and ("  |cffff3333" .. DCL("Deaths") .. " " .. run.deaths .. "|r") or ""
                row.l1:SetText(string.format("%s|cffffd100%s|r%s  %s  %s %d/%d%s%s",
                    mark, DungeonName(run.token), heroic, stage, DCL("Bosses"), run.killed, run.total, dead, alert))
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
        if #runs == 0 then
            runRows[1].run = nil
            runRows[1].l1:SetText("|cff999999" .. DCL("No test run is running. Start one on the left.") .. "|r")
            runRows[1].l2:SetText("")
            runRows[1].watch:Hide()
            runRows[1]:Show()
        else
            runRows[1].watch:Show()
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
            if parts[3] then
                cap.value, cap.conf, cap.over = tonumber(parts[3]) or 0, tonumber(parts[4]) or 0, parts[5] == "1"
            end
        elseif kind == "TR" and pending then
            pending[#pending + 1] = {
                order = #pending + 1, id = parts[2], token = parts[3], heroic = parts[4] == "1",
                stage = parts[5], elapsed = tonumber(parts[6]) or 0, killed = tonumber(parts[7]) or 0,
                total = tonumber(parts[8]) or 0, watching = parts[9] == "1", wiped = parts[10] == "1",
                combat = parts[11] == "1", level = tonumber(parts[12]) or 0, members = {},
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
                    r.comp = {}
                    for name, role in (parts[9] or ""):gmatch("([^:,]+):([^,]*)") do
                        r.comp[#r.comp + 1] = { name = name, role = role }
                    end
                end
            end
        elseif kind == "TI_START" then
            infoPending = { id = parts[2], kills = {}, deaths = {} }
        elseif kind == "TIB" and infoPending then
            infoPending.kills[#infoPending.kills + 1] = { t = tonumber(parts[2]) or 0, name = parts[3] or "" }
        elseif kind == "TID" and infoPending then
            infoPending.deaths[#infoPending.deaths + 1] = { t = tonumber(parts[2]) or 0, name = parts[3] or "",
                onBoss = parts[4] == "1", by = parts[5] or "" }
        elseif kind == "TI_END" and infoPending then
            info, infoPending = infoPending, nil
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
                    }
                end
            end
        elseif kind == "TR_END" and pending then
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
    DCLoc.OnChange(function() if lf:IsShown() then RenderRuns() end end)
    tf:HookScript("OnShow", function() if DB().listShown then lf:Show() end end)
    tf:HookScript("OnHide", function() local was = lf:IsShown(); lf:Hide(); DB().listShown = was end)

    testBtn:SetScript("OnClick", function()
        if tf:IsShown() then tf:Hide() else tf:Show() end
    end)
    Tip(testBtn, "Bot Test Runs (GM)", "Start, watch and stop automated bot test runs (.dc test).")
    DCLoc.OnChange(function() if tf:IsShown() then RefreshDungeonList() end end)
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
    local capH = listLabel:GetHeight()
    if not capH or capH < 1 then capH = 14 end  -- not laid out yet (load time)
    if DungeonClearDB.bossesFolded then
        -- Caption row only. The [+]/[-] button is taller than the caption and
        -- vertically centred on it, so IT sets the lower edge, not the text.
        return LIST_GAP + math.max(capH, capH / 2 + TOGGLE_H / 2)
    end
    return LIST_GAP + capH + LIST_PAD + LIST_H
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
        SetFrameHeight(35 + statusFrame:GetHeight() + 8 + 24 + BelowActionRow() + 12)
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
end

tinyBtn:SetScript("OnClick", function()
    DungeonClearDB.tinyMode = not DungeonClearDB.tinyMode
    UpdateLayout()
end)

toggleBossesBtn:SetScript("OnClick", function()
    DungeonClearDB.bossesFolded = not DungeonClearDB.bossesFolded
    UpdateLayout()
end)

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
            DEFAULT_CHAT_FRAME:AddMessage("|cffff3333[DC] " .. DCL("Auto-play could not start:") .. " " .. (parts[3] or "") .. "|r")
        elseif kind == "no-class-ai" then
            DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[DC] " .. DCL("This class has no bot AI yet: your character follows the run, dodges ground effects and attacks, but casts no class spells.") .. "|r")
        elseif kind == "role-unsupported" then
            DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[DC] " .. DCL("This class cannot play that role for the bot AI; it plays by its talents instead.") .. "|r")
        end
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

            if DungeonClearDB.visible then
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
    else
        -- Parse "/dc <sub> [param]" and send via addon message
        local subCmd, param = msg:match("^(%S+)%s*(.*)$")
        if subCmd then
            SendDcCommand(subCmd, param)
        end
    end
end

-- Print loaded notice
DEFAULT_CHAT_FRAME:AddMessage("|cff3da6ffDungeonClear Addon v3.6-reborn11 loaded.|r Type /dc to toggle window, or see Interface > AddOns > DungeonClear.")
