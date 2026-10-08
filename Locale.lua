-- DungeonClear bilingual layer (RebornWOW, DCUI1A).
-- Loaded before DungeonClear.lua. English is the source text everywhere; the
-- zh table maps it to Chinese. Anything missing falls back to English, so a
-- new server string never shows up blank.

DCLoc = DCLoc or {}

local zh = {
    -- window
    ["Dungeon Clear"] = "副本自动清理",
    ["Mode Status:"] = "运行状态：",
    ["Pull Mode:"] = "拉怪模式：",
    ["Current State:"] = "当前状态：",
    ["Next Boss:"] = "下一个首领：",
    ["Warning:"] = "警告：",
    ["OFF"] = "关闭",
    ["ON"] = "开启",
    ["PAUSED"] = "已暂停",
    ["Inactive"] = "未运行",
    ["None"] = "无",
    ["On"] = "开始",
    ["Off"] = "停止",
    ["Skip"] = "跳过",
    ["Pause"] = "暂停",
    ["Resume"] = "继续",
    ["Pull:"] = "拉怪：",
    ["Leeroy"] = "直冲",
    ["Advanced"] = "引怪",
    ["Dynamic"] = "智能",
    ["Waiting for patrol"] = "等待巡逻",
    ["Spectate"] = "观战",
    ["Reset Camera"] = "恢复视角",
    ["Dungeon Bosses"] = "副本首领",
    ["Go"] = "前往",
    ["Tiny"] = "迷你",
    ["Loading boss list..."] = "正在加载首领列表…",
    ["Alive"] = "存活",
    ["Dead"] = "已击杀",
    ["Skipped"] = "已跳过",
    ["Missing"] = "未找到",

    -- states (full window)
    ["Paused"] = "已暂停",
    ["Advanced Pull"] = "引怪中",
    ["Advancing"] = "前进中",
    ["Plotting Route"] = "规划路线",
    ["Closing on Boss"] = "逼近首领",
    ["Recovering / Repathing"] = "恢复 / 重新寻路",
    ["Party Recovering / Resting"] = "队伍休整中",
    ["Collecting Loot"] = "拾取战利品",
    ["Blocked by Door"] = "被门挡住",
    ["Route Blocked"] = "路线受阻",
    ["Clearing Path (Trash)"] = "清理路上小怪",
    ["Engaging Boss!"] = "首领战！",
    ["Idle / Waiting"] = "空闲 / 等待",
    ["Active"] = "运行中",
    -- states (tiny line)
    ["Pulling to Camp"] = "引怪回营地",
    ["Closing In"] = "逼近中",
    ["Repathing"] = "重新寻路",
    ["Resting"] = "休整",
    ["Looting"] = "拾取",
    ["Door Blocked"] = "门被挡住",
    ["Blocked"] = "受阻",
    ["Clearing Trash"] = "清理小怪",
    ["Boss Fight"] = "首领战",
    ["Idle"] = "空闲",
    ["Clearing"] = "清理中",

    -- tooltips
    ["Spectator mode disabled"] = "观战已关闭",
    ["This server has turned off the spectator camera."] = "服务器已关闭观战镜头。",
    ["Left-click: free-flying camera."] = "左键：自由飞行镜头。",
    ["Right-click: follow cam \226\128\148 your view rides the tank."] = "右键：跟随镜头——视角跟着坦克走。",
    ["Previous bot"] = "上一个机器人",
    ["Move the camera to the previous bot in the instance."] = "把镜头切到副本里的上一个机器人。",
    ["Next bot"] = "下一个机器人",
    ["Move the camera to the next bot in the instance. Starts the follow cam if it isn't running."] =
        "把镜头切到副本里的下一个机器人。没开镜头时会自动开启跟随镜头。",
    ["Ends the spectator camera and hands control of your own character back to you."] =
        "关闭观战镜头，把角色控制权交还给你。",
    ["Left-click to start the clear"] = "左键开始清理",
    ["Left-click to resume"] = "左键继续",
    ["Left-click to pause"] = "左键暂停",
    ["Right-click to expand the window"] = "右键展开窗口",
    ["Pull Mode"] = "拉怪模式",
    ["Click to cycle: Leeroy / Advanced / Dynamic"] = "点击切换：直冲 / 引怪 / 智能",
    ["Left-click to toggle the window."] = "左键打开/关闭窗口。",
    ["Drag to reposition this button."] = "拖动可移动这个按钮。",
    ["Switch the panel language"] = "切换界面语言",

    -- chat
    ["|cffff3333DungeonClear: cannot send bot commands right now.|r"] = "|cffff3333副本自动清理：现在无法发送机器人指令。|r",
    ["|cffff3333[DC] Tank bot is no longer in the group \226\128\148 dungeon clear turned off.|r"] =
        "|cffff3333[DC] 坦克机器人已离开队伍——自动清理已关闭。|r",

    -- options / settings panel
    ["Commands & Controls"] = "命令与按钮",
    ["Open DungeonClear"] = "打开副本自动清理",
    ["Dungeon Clear - Settings"] = "副本自动清理 - 设置",
    ["Reset All to Default"] = "全部恢复默认",
    ["Default"] = "默认",
    ["Prevent Bot Release"] = "机器人不放魂",
    ["Dead bots stay as a corpse to be resurrected instead of releasing to the graveyard."] =
        "机器人死亡后留在原地等待复活，不跑回墓地。",
    ["Combat Regroup"] = "战斗中集合",
    ["Keep followers grouped on the tank during a fight, not just on the route \226\128\148 a healer that drifts out of line of sight closes back in."] =
        "战斗中也让队员跟紧坦克——治疗跑出视线会自动靠回来。",
    ["Party Max Spread (yd)"] = "队伍最大间距（码）",
    ["How far the tank may lead the party before it holds to let everyone catch up."] =
        "坦克最多领先队伍多远，超过就停下等大家跟上。",
    ["Minimum Loot Quality"] = "最低拾取品质",
    ["Skip corpses whose best item is below this rarity. Quest items always loot."] =
        "尸体上最好的物品低于这个品质就不拾取。任务物品总会拾取。",
    ["Ignore Chests"] = "忽略宝箱",
    ["Don't stop for treasure chests or other world objects while clearing \226\128\148 only loot creature corpses."] =
        "清理时不停下来开宝箱等物件——只拾取怪物尸体。",
    ["Rest Health %"] = "休整血量 %",
    ["Health the party eats up to between pulls, overriding the server's AiPlayerbot.AlmostFullHealth for this run. 0 = use the server default."] =
        "两波怪之间吃东西回到的血量，本次覆盖服务器的 AiPlayerbot.AlmostFullHealth。0 = 用服务器默认值。",
    ["Rest Mana %"] = "休整法力 %",
    ["Mana the party drinks up to between pulls, overriding the server's AiPlayerbot.HighMana for this run. 0 = use the server default. Ignored while Smart Rest is on."] =
        "两波怪之间喝水回到的法力，本次覆盖服务器的 AiPlayerbot.HighMana。0 = 用服务器默认值。开启智能休整时无效。",
    ["Smart Rest"] = "智能休整",
    ["Push without stopping to eat or drink until someone falls below a trigger, then the whole party rests to FULL health and mana. Off = classic rest-to-target behavior (Rest Health/Mana % above)."] =
        "一直推进不停下吃喝，直到有人低于触发线，全队再休整到满血满蓝。关闭 = 传统方式（按上面的休整血量/法力 %）。",
    ["Smart Rest: Health Trigger %"] = "智能休整：血量触发 %",
    ["Any member below this health stops the party for a full rest. 0 disables the health trigger."] =
        "任何队员血量低于此值，全队停下休整。0 = 关闭血量触发。",
    ["Smart Rest: DPS/Tank Mana Trigger %"] = "智能休整：输出/坦克法力触发 %",
    ["A DPS or tank mana user below this stops the party for a full rest. 0 disables."] =
        "用法力的输出或坦克低于此值，全队停下休整。0 = 关闭。",
    ["Smart Rest: Healer Mana Trigger %"] = "智能休整：治疗法力触发 %",
    ["A healer below this mana stops the party for a full rest. 0 disables."] =
        "治疗法力低于此值，全队停下休整。0 = 关闭。",
    ["Wait at Boss"] = "首领前等待",
    ["Pause the run right before every boss pull and wait for you \226\128\148 hit Resume (or the tiny-mode dot) when your party is ready. Each boss waits once per run."] =
        "每个首领开打前暂停等你——准备好后点「继续」（或迷你模式的圆点）。每个首领每次只等一次。",
    ["Desired maximum mobs per pull"] = "每波最多怪物数",
    ["Dynamic pull only. The party's comfortable simultaneous-mob ceiling: the tank Leeroys a pack at or under this estimated aggro count, and pulls one above it back to camp."] =
        "仅智能拉怪。队伍能同时应付的怪物上限：预计数量不超过它就直冲，超过就引回营地打。",
    ["Pull: Party Lag (yd)"] = "拉怪：队伍落后距离（码）",
    ["Dynamic pull only. How far back the party trails while the tank scouts the next pack, so it reaches aggro range alone to decide Leeroy vs pull."] =
        "仅智能拉怪。坦克侦察下一波怪时队伍落后多远，让坦克独自进入仇恨范围来判断直冲还是引怪。",
    ["Poor"] = "粗糙", ["Common"] = "普通", ["Uncommon"] = "优秀", ["Rare"] = "精良",
    ["Epic"] = "史诗", ["Legendary"] = "传说", ["Artifact"] = "神器",
}

-- Server-authored sentences (DcStatusPublisher / DcPartyState). Matched in
-- order; the captured name stays as the server sent it.
local zhPatterns = {
    { "^Plotting a route to (.-)%.?$", "规划前往 %1 的路线。" },
    { "^En route to (.-)%.?$", "正在前往 %1。" },
    { "^Closing in on (.-)%.?$", "逼近 %1。" },
    { "^Engaging (.-)%.?$", "开打：%1" },
    { "^Fighting (.-)%.?$", "正在战斗：%1" },
    { "^Clearing the room before pulling (.-)%.?$", "引 %1 之前先清理房间。" },
    { "^Stuck; replanning the route to (.-)%.?$", "卡住了，重新规划前往 %1 的路线。" },
    { "^Holding near (.-)%.?$", "在 %1 附近待命。" },
    { "^Opening the door to (.-)%.?$", "正在打开通往 %1 的门。" },
    { "^Waiting for you to resurrect (.-)%.?$", "等待你复活 %1。" },
    { "^Escort stalled: I can't keep up with (.-)%.?$", "护送停滞：跟不上 %1。" },
}
local zhExact = {
    ["En route"] = "前进中",
    ["Collecting loot."] = "正在拾取战利品。",
    ["Clearing trash from the path."] = "清理路上的小怪。",
    ["Resting the party."] = "队伍休整中。",
    ["Waiting for the party to recover."] = "等待队伍恢复。",
    ["Recovering a fallen party member."] = "正在救起倒下的队员。",
    ["Pulling the pack back to camp."] = "把这波怪引回营地。",
    ["Pulling the pack back to camp"] = "把这波怪引回营地",
    ["Pulling the ranged pack back to camp, out of line of sight."] = "把远程怪引回营地，躲开视线。",
    ["Pulling \226\128\148 party holding at camp"] = "引怪中——队伍在营地待命",
    ["In combat"] = "战斗中",
    ["Blocked by a door"] = "被门挡住",
    ["holding position"] = "原地待命",
}
local zhReasons = {
    ["low HP"] = "血量低", ["low mana"] = "法力低", ["out of range"] = "不在范围内",
    ["dead"] = "已死亡", ["drinking"] = "喝水中", ["eating"] = "进食中",
    ["out of line of sight"] = "不在视线内", ["offline"] = "离线",
}

local function IsZh()
    return DungeonClearDB and DungeonClearDB.lang == "zh"
end

function DCLoc.IsZh() return IsZh() end

-- Fixed UI text.
function DCL(en)
    if en == nil then return nil end
    if IsZh() then return zh[en] or en end
    return en
end

-- Free text from the server: exact sentences, "Waiting on A (low HP), B (...)",
-- then prefix patterns. Unknown text is returned unchanged (English).
function DCLDetail(s)
    if not s or s == "" or not IsZh() then return s end
    if zhExact[s] then return zhExact[s] end
    local who = s:match("^Waiting on (.+)$")
    if who then
        -- " (low HP)" -> "（血量低）": full-width brackets take no leading space in Chinese
        who = who:gsub("%s*%((.-)%)", function(r) return "（" .. (zhReasons[r] or r) .. "）" end)
        who = who:gsub("%.$", "")
        return "等待 " .. who .. "。"
    end
    for _, p in ipairs(zhPatterns) do
        local out, n = s:gsub(p[1], p[2])
        if n > 0 then return out end
    end
    return s
end

-- Boss/objective row names: translate the English prefix only.
function DCLName(name)
    if not name or not IsZh() then return name end
    name = name:gsub("^Objective: ", "目标：")
    name = name:gsub("^Event: ", "事件：")
    return name
end

-- Folded event notes carry an English status suffix.
function DCLNote(seg)
    if not seg or not IsZh() then return seg end
    seg = seg:gsub("%(done%)$", "（已完成）")
    seg = seg:gsub("%(skipped%)$", "（已跳过）")
    seg = seg:gsub("%(pending%)$", "（待完成）")
    return seg
end

-- Static widgets: remember the English source so a language switch can re-apply.
local bindings = {}
function DCBind(widget, en)
    bindings[widget] = { en = en }
    widget:SetText(DCL(en))
end
-- Long paragraphs: both languages given explicitly (no lookup key to drift).
function DCBindPair(widget, en, zhText)
    bindings[widget] = { en = en, zh = zhText }
    widget:SetText(IsZh() and zhText or en)
end

local refreshHooks = {}
function DCLoc.OnChange(fn) refreshHooks[#refreshHooks + 1] = fn end

local langButtons = {}
local function ButtonLabel() return IsZh() and "EN" or "中文" end
function DCLoc.AddButton(btn)
    langButtons[#langButtons + 1] = btn
    btn:SetText(ButtonLabel())
end

function DCLoc.Apply()
    for widget, b in pairs(bindings) do
        if b.zh then widget:SetText(IsZh() and b.zh or b.en)
        else widget:SetText(DCL(b.en)) end
    end
    for _, btn in ipairs(langButtons) do btn:SetText(ButtonLabel()) end
    for _, fn in ipairs(refreshHooks) do fn() end
end

function DCLoc.Toggle()
    if not DungeonClearDB then return end
    DungeonClearDB.lang = IsZh() and "en" or "zh"
    GameTooltip:Hide()
    DCLoc.Apply()
end

-- First run follows the client locale; afterwards the saved choice wins.
function DCLoc.Init()
    if DungeonClearDB and DungeonClearDB.lang == nil then
        local loc = GetLocale and GetLocale() or "enUS"
        DungeonClearDB.lang = (loc == "zhCN" or loc == "zhTW") and "zh" or "en"
    end
    DCLoc.Apply()
end
