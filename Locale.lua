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
    -- auto-play row (DCSB1A)
    ["Auto-play:"] = "托管：",
    ["Tank"] = "坦克",
    ["Heal"] = "治疗",
    ["DPS"] = "输出",
    ["Manual"] = "手动",
    ["Let the AI play your character as the tank."] = "让 AI 以坦克身份操作你的角色。",
    ["Let the AI play your character as a healer."] = "让 AI 以治疗身份操作你的角色。",
    ["Let the AI play your character as damage."] = "让 AI 以输出身份操作你的角色。",
    ["Take your character back and play it yourself."] = "收回角色，由你自己操作。",
    ["Auto-play on:"] = "托管中：",
    ["Auto-play off: you are in control."] = "已退出托管，由你自己操作。",
    ["Auto-play could not start:"] = "无法开启托管：",
    ["This class has no bot AI yet: your character follows the run, dodges ground effects and attacks, but casts no class spells."] = "该职业还没有机器人 AI：角色会跟随队伍、躲避地面伤害并普通攻击，但不会释放职业技能。",
    ["This class cannot play that role for the bot AI; it plays by its talents instead."] = "机器人 AI 中该职业不能担任这个职责，改为按天赋行动。",
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
    -- test-run list (DCTEST2A)
    ["Test run list"] = "测试列表",
    ["Follow tank"] = "跟随坦克",
    ["Prev"] = "上一个",
    ["Next"] = "下一个",
    ["Free view"] = "自由视角",
    ["End watching"] = "结束观看",
    ["Camera on the selected run's tank (enters that run first if you are not watching it)."] = "镜头跟随选中那一局的坦克（如果你还没在看那一局，会先进入观看）。",
    ["Camera on the previous bot of the run you are watching."] = "镜头切到正在观看这一局的上一个机器人。",
    ["Camera on the next bot of the run you are watching."] = "镜头切到正在观看这一局的下一个机器人。",
    ["God view: fly the camera freely around the run you are watching (WASD / mouse). Follow tank goes back to following."] = "上帝视角：在正在观看的副本里自由移动镜头（WASD / 鼠标）。点「跟随坦克」回到跟随。",
    ["End the watch: you go back to where you were, visible again."] = "结束观看：回到观看前的位置，并恢复可见。",
    ["Already in free view. Use Follow tank to follow again, or End watching."] = "已经是自由视角了。点「跟随坦克」回到跟随，或点「结束观看」。",
    -- cap control + bot details (DCTEST4A)
    ["Conf"] = "恢复配置",
    ["Test-run limit"] = "同时测试上限",
    ["- / + change how many tests may run at once. Conf goes back to DungeonClear.TestRun.MaxConcurrent. A value set here lasts until the server restarts; edit the conf to keep it."] =
        "用 - / + 调整同时能跑几个测试。「恢复配置」回到 conf 里 DungeonClear.TestRun.MaxConcurrent 的值。这里设置的数值在服务器重启前有效；想永久保存请改 conf。",
    ["limit"] = "上限",
    ["conf"] = "配置",
    ["first = watching"] = "第一个是你正在观看的",
    ["Details"] = "详情",
    ["Details (gear, stats, talents)"] = "查看详情（装备、属性、天赋）",
    ["right-click a run above"] = "右键点上面的测试查看",
    ["Stats"] = "属性",
    ["Talents"] = "天赋",
    ["Glyphs & AI"] = "雕文与策略",
    ["empty"] = "空",
    ["Average item level"] = "平均装等",
    ["Enchants"] = "附魔",
    ["No enchant:"] = "缺附魔：",
    ["Gems"] = "宝石",
    ["Hover an item for its full tooltip."] = "鼠标移到装备上查看完整说明。",
    ["Base"] = "基础",
    ["Strength"] = "力量", ["Agility"] = "敏捷", ["Stamina"] = "耐力", ["Intellect"] = "智力", ["Spirit"] = "精神",
    ["Armor"] = "护甲", ["Health"] = "生命值", ["Mana"] = "法力值",
    ["Melee / Ranged"] = "近战 / 远程",
    ["Attack power"] = "攻击强度", ["Ranged attack power"] = "远程攻击强度", ["Hit rating"] = "命中等级",
    ["Melee crit"] = "近战暴击", ["Ranged crit"] = "远程暴击", ["Haste rating"] = "急速等级",
    ["Expertise"] = "精准", ["Armor penetration rating"] = "护甲穿透等级",
    ["Spell"] = "法术",
    ["Spell power"] = "法术强度", ["Healing"] = "治疗加成", ["Spell hit rating"] = "法术命中等级",
    ["Spell crit"] = "法术暴击", ["Spell haste rating"] = "法术急速等级",
    ["Defense"] = "防御",
    ["Defense rating"] = "防御等级", ["Dodge"] = "躲闪", ["Parry"] = "招架", ["Block"] = "格挡", ["Resilience"] = "韧性",
    ["Rank"] = "等级",
    ["Tree"] = "天赋树",
    ["Glyphs"] = "雕文",
    ["no glyphs"] = "没有雕文",
    ["Combat strategies"] = "战斗策略（playerbots）",
    ["Non-combat strategies"] = "非战斗策略（playerbots）",
    ["Race"] = "种族", ["Class"] = "职业",
    ["unspent"] = "未分配",
    ["Head"] = "头部", ["Neck"] = "颈部", ["Shoulder"] = "肩部", ["Shirt"] = "衬衣", ["Chest"] = "胸部",
    ["Waist"] = "腰部", ["Legs"] = "腿部", ["Feet"] = "脚", ["Wrist"] = "手腕", ["Hands"] = "手",
    ["Finger"] = "手指", ["Trinket"] = "饰品", ["Back"] = "背部", ["Main Hand"] = "主手", ["Off Hand"] = "副手",
    ["Ranged"] = "远程", ["Tabard"] = "战袍",
    ["Warrior"] = "战士", ["Paladin"] = "圣骑士", ["Hunter"] = "猎人", ["Rogue"] = "潜行者", ["Priest"] = "牧师",
    ["Death Knight"] = "死亡骑士", ["Shaman"] = "萨满祭司", ["Mage"] = "法师", ["Warlock"] = "术士", ["Druid"] = "德鲁伊",
    ["Human"] = "人类", ["Orc"] = "兽人", ["Dwarf"] = "矮人", ["Night Elf"] = "暗夜精灵", ["Undead"] = "亡灵",
    ["Tauren"] = "牛头人", ["Gnome"] = "侏儒", ["Troll"] = "巨魔", ["Blood Elf"] = "血精灵", ["Draenei"] = "德莱尼",
    ["Arms"] = "武器", ["Fury"] = "狂怒", ["Protection"] = "防护", ["Holy"] = "神圣", ["Retribution"] = "惩戒",
    ["Beast Mastery"] = "野兽控制", ["Marksmanship"] = "射击", ["Survival"] = "生存",
    ["Assassination"] = "刺杀", ["Combat"] = "战斗", ["Subtlety"] = "敏锐",
    ["Discipline"] = "戒律", ["Shadow"] = "暗影", ["Blood"] = "鲜血", ["Frost"] = "冰霜", ["Unholy"] = "邪恶",
    ["Elemental"] = "元素", ["Enhancement"] = "增强", ["Restoration"] = "恢复",
    ["Arcane"] = "奥术", ["Fire"] = "火焰", ["Affliction"] = "痛苦", ["Demonology"] = "恶魔学识",
    ["Destruction"] = "毁灭", ["Balance"] = "平衡", ["Feral Combat"] = "野性战斗",
    -- right-click menus, run stats, cap popup (DCTEST3A)
    ["Drag to move; right-click a run or a bot for more"] = "可拖动；右键点测试或机器人有更多功能，右键空白处复位",
    ["The test-run limit is %s at a time. Stop a running test first, or raise the limit with + at the top of the test run list (until restart), or in mod_dungeon_clear.conf (DungeonClear.TestRun.MaxConcurrent, then .reload config)."] =
        "同时测试上限是 %s 个，已经满了。\n请先停止一个正在运行的测试；\n或者在测试列表顶部点 + 调高上限（服务器重启前有效）；\n或者在 mod_dungeon_clear.conf 里调高 DungeonClear.TestRun.MaxConcurrent，然后输入 .reload config（永久）。",
    ["Open test run list"] = "打开测试列表",
    ["That test run has already finished."] = "这个测试已经结束了。",
    ["Deaths"] = "死亡",
    ["Pulls"] = "拉怪",
    ["Run stats"] = "本局统计",
    ["Bosses down"] = "已击杀首领",
    ["none yet"] = "暂无",
    ["boss"] = "首领",
    ["out of combat"] = "非战斗",
    ["(my characters)"] = "（我的角色）",
    ["unlimited"] = "不限",
    ["Watch this run"] = "进入观看",
    ["Follow a bot"] = "跟随某个机器人观看",
    ["Run it again (same seed and gear)"] = "用同样的设置再测一次（同种子同装备）",
    ["Copy its settings to the left"] = "把它的设置填到左边",
    ["Stop this test"] = "停止这个测试",
    ["Stop the test run %s (%s)?"] = "确定停止测试 %s（%s）吗？",
    ["Follow this bot (camera)"] = "跟随观看这个机器人",
    ["Show its gear"] = "查看它的装备",
    ["Teleport next to it (.appear)"] = "传送到它身边（.appear）",
    ["Drag to move, right-click to put it back"] = "可拖动，右键回到默认位置",
    ["Open the list of every running test: watch any of them, see each party's bots, their level, item level, health and gear."] =
        "打开所有运行中测试的列表：可以进入任意一个观看，查看每支队伍的机器人、等级、装等、血量和装备。",
    ["Refresh"] = "刷新",
    ["Gear"] = "装备",
    ["Party"] = "队伍",
    ["dead"] = "死亡",
    ["MP"] = "蓝",
    ["HP"] = "血",
    ["iLvl"] = "装等",
    ["click Gear on a bot"] = "点机器人后面的「装备」查看",
    ["Running:"] = "运行中：",
    ["you are watching the first one"] = "第一个是你正在观看的",
    ["Watching"] = "观看中",
    ["(Heroic)"] = "（英雄）",
    ["wiped"] = "团灭",
    ["in combat"] = "战斗中",
    ["Bosses"] = "首领",
    ["Time"] = "用时",
    ["Target:"] = "目标：",
    ["No test run is running. Start one on the left."] = "当前没有运行中的测试。在左边开始一个。",
    ["The test-run list needs a GM account."] = "测试列表需要 GM 账号。",
    ["That bot is no longer online:"] = "这个机器人已经不在线：",
    ["Logging in bots"] = "登录机器人",
    ["Gearing up"] = "配置装备技能",
    ["Grouping"] = "组队",
    ["Teleporting"] = "传送",
    ["Starting"] = "开始",
    ["Clearing"] = "清本中",
    ["Wrapping up"] = "收尾",
    -- test window (DCTEST1A)
    ["Test"] = "测试",
    ["Bot Test Runs (GM)"] = "机器人测试（GM）",
    ["Start, watch and stop automated bot test runs (.dc test)."] = "开始、观战、停止机器人自动测试（.dc test）。",
    ["Dungeon:"] = "副本：",
    ["A dungeon token (e.g. hos) or a map id. Typing also filters the list below."] = "副本代号（如 hos）或地图编号。输入时也会筛选下面的列表。",
    ["Load list"] = "刷新列表",
    ["Ask the server for the dungeons the test harness supports."] = "向服务器获取可测试的副本列表。",
    ["Lv"] = "等级",
    ["H"] = "英雄",
    ["Click Load list to fetch the dungeons."] = "点「刷新列表」获取副本。",
    ["Heroic"] = "英雄",
    ["Party:"] = "队伍：",
    ["Random bots"] = "随机机器人",
    ["My characters"] = "我的角色",
    ["The server rolls a random playerbot party from the bot pool and gears it to the ilvl / quality below. Same seed = same party."] =
        "服务器从机器人池里随机组一支队伍，按下面的装等和品质配装。种子相同 = 队伍相同。",
    ["A party of your own characters, roles in order. They must be OFFLINE (log your bot alts out first): the server logs them in as bots and does not re-gear or re-level them. The character you are playing cannot join a test run - play it with the normal Start button and Auto-play instead."] =
        "用你自己的角色组队，按顺序填职责。这些角色必须离线（先让机器人小号下线）：服务器会把它们登录成机器人，不改装备也不改等级。你正在玩的角色不能加入测试——想自己参与请用主面板的「开始」和「托管」。",
    ["Item level:"] = "装等：",
    ["Gear ceiling for the bots (empty = the server default). Use 'Gear tiers' to see sensible values for the dungeon."] =
        "机器人装备的装等上限（空 = 服务器默认）。点「装备档位」查看这个副本合适的数值。",
    ["Quality:"] = "品质：",
    ["Click to cycle the best item quality the bots may wear."] = "点击切换机器人可穿的最高装备品质。",
    ["Seed:"] = "种子：",
    ["Empty = a new random party. Re-use the seed printed by an earlier run to test the very same party again."] =
        "空 = 随机新队伍。填之前测试打印的种子，可以用同一支队伍再测一次。",
    ["Healer"] = "治疗",
    ["DPS 1"] = "输出1",
    ["DPS 2"] = "输出2",
    ["DPS 3"] = "输出3",
    ["From party"] = "填入队友",
    ["Copy your current party members' names into the five slots (fix the role order by hand). Log those bots out before you start."] =
        "把当前队友的名字填进五个位置（职责顺序请手动调整）。开始前先让这些机器人下线。",
    ["Pick a dungeon first."] = "请先选择副本。",
    ["Fill all five characters (tank, healer, three DPS)."] = "请填满五个角色（坦克、治疗、三个输出）。",
    ["Start test"] = "开始测试",
    ["Start a bot test run with the options above. The bots run the dungeon on their own; use Watch to follow them."] =
        "按上面的设置开始机器人测试。机器人会自己打副本；用「观战」跟着看。",
    ["Gear tiers"] = "装备档位",
    ["List the item-level ceilings worth testing this dungeon at."] = "列出这个副本值得测试的装等档位。",
    ["Watch after start"] = "开始后自动观战",
    ["10 seconds after Start, run Watch: you are hidden, moved to the instance entrance and your camera follows the bots."] =
        "开始测试 10 秒后自动观战：你会隐身、被传送到副本入口，镜头跟随机器人。",
    ["Running tests"] = "运行中的测试",
    ["Status"] = "状态",
    ["Show every running test run (dungeon, party, stage, time)."] = "显示所有运行中的测试（副本、队伍、阶段、用时）。",
    ["Watch"] = "观战",
    ["Hide yourself and put your camera on the running test (only one running) - you are teleported to the instance entrance."] =
        "隐身并把镜头挂到运行中的测试上（只有一个测试时）——你会被传送到副本入口。",
    ["Next run"] = "下一个",
    ["Move the camera to the next running test."] = "把镜头切到下一个运行中的测试。",
    ["Stop watching"] = "退出观战",
    ["End the camera and return to where you were."] = "结束观战，回到原来的位置。",
    ["Stop run"] = "停止测试",
    ["Stop the running test (only one running; otherwise the reply lists the run ids)."] =
        "停止运行中的测试（只有一个时；多个时服务器会列出测试编号）。",
    ["Stop all"] = "全部停止",
    ["Stop every test run and every test plan."] = "停止所有测试和测试计划。",
    ["Stop ALL bot test runs and test plans?"] = "确定停止所有机器人测试和测试计划吗？",
    ["Plan status"] = "计划状态",
    ["Show the batch test plans (.dc test plan start ...) and their progress."] = "显示批量测试计划（.dc test plan start ...）及进度。",
    ["Clear"] = "清空",
    ["Refresh status every 15s while this window is open"] = "窗口打开时每 15 秒自动刷新状态",
    ["GM only. Replies from the server:"] = "仅 GM 可用。服务器回复：",
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

-- Test window (DCTEST1B): dungeon names of the `.dc test` registry and the server's
-- replies. The server always answers in English; these translate what the window shows.
local zhDungeons = {
    ["Ragefire Chasm"] = "怒焰裂谷",
    ["Wailing Caverns"] = "哀嚎洞穴",
    ["The Deadmines"] = "死亡矿井",
    ["Shadowfang Keep"] = "影牙城堡",
    ["The Stockade"] = "监狱",
    ["Blackfathom Deeps"] = "黑暗深渊",
    ["Razorfen Kraul"] = "剃刀沼泽",
    ["Scarlet Monastery: Graveyard"] = "血色修道院：墓地",
    ["Gnomeregan"] = "诺莫瑞根",
    ["Scarlet Monastery: Library"] = "血色修道院：图书馆",
    ["Scarlet Monastery: Armory"] = "血色修道院：军械库",
    ["Scarlet Monastery: Cathedral"] = "血色修道院：大教堂",
    ["Razorfen Downs"] = "剃刀高地",
    ["Uldaman"] = "奥达曼",
    ["Zul'Farrak"] = "祖尔法拉克",
    ["Maraudon"] = "玛拉顿",
    ["The Temple of Atal'Hakkar"] = "阿塔哈卡神庙",
    ["Blackrock Depths: Detention Block"] = "黑石深渊：监狱区",
    ["Blackrock Depths: Upper City"] = "黑石深渊：上层城区",
    ["Lower Blackrock Spire"] = "黑石塔下层",
    ["Upper Blackrock Spire"] = "黑石塔上层",
    ["Dire Maul: East"] = "厄运之槌：东",
    ["Dire Maul: West"] = "厄运之槌：西",
    ["Dire Maul: North"] = "厄运之槌：北",
    ["Scholomance"] = "通灵学院",
    ["Stratholme"] = "斯坦索姆",
    ["Hellfire Ramparts"] = "地狱火城墙",
    ["The Blood Furnace"] = "鲜血熔炉",
    ["The Slave Pens"] = "奴隶围栏",
    ["The Underbog"] = "幽暗沼泽",
    ["Mana-Tombs"] = "法力陵墓",
    ["Auchenai Crypts"] = "奥金尼地穴",
    ["Sethekk Halls"] = "塞泰克大厅",
    ["Old Hillsbrad Foothills"] = "旧希尔斯布莱德丘陵",
    ["Shadow Labyrinth"] = "暗影迷宫",
    ["The Steamvault"] = "蒸汽地窟",
    ["The Shattered Halls"] = "破碎大厅",
    ["The Black Morass"] = "黑色沼泽",
    ["The Botanica"] = "生态船",
    ["The Mechanar"] = "能源舰",
    ["The Arcatraz"] = "禁魔监狱",
    ["Magisters' Terrace"] = "魔导师平台",
    ["Utgarde Keep"] = "乌特加德城堡",
    ["The Nexus"] = "魔枢",
    ["Azjol-Nerub"] = "艾卓-尼鲁布",
    ["Ahn'kahet: The Old Kingdom"] = "安卡赫特：古代王国",
    ["Drak'Tharon Keep"] = "达克萨隆要塞",
    ["The Violet Hold"] = "紫罗兰监狱",
    ["Gundrak"] = "古达克",
    ["Halls of Stone"] = "岩石大厅",
    ["Halls of Lightning"] = "闪电大厅",
    ["The Culling of Stratholme"] = "净化斯坦索姆",
    ["The Oculus"] = "魔环",
    ["Utgarde Pinnacle"] = "乌特加德之巅",
    ["Trial of the Champion"] = "冠军的试炼",
    ["The Forge of Souls"] = "灵魂洪炉",
    ["Pit of Saron"] = "萨隆矿坑",
    ["Halls of Reflection"] = "映像大厅",
    ["Molten Core"] = "熔火之心",
    ["Blackwing Lair"] = "黑翼之巢",
    ["Gruul's Lair"] = "格鲁尔的巢穴",
    ["Karazhan"] = "卡拉赞",
    ["Karazhan: Chess"] = "卡拉赞：象棋",
}

-- Longest first, so "The Culling of Stratholme" is replaced before "Stratholme".
local zhDungeonOrder = {}
for en in pairs(zhDungeons) do zhDungeonOrder[#zhDungeonOrder + 1] = en end
table.sort(zhDungeonOrder, function(a, b) return #a > #b end)

local function PlainPattern(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end

function DCLDungeon(name)
    if not name or not IsZh() then return name end
    return zhDungeons[name] or name
end

-- Fixed replies of the `.dc test` commands.
local zhTestExact = {
    ["Supported test dungeons (.dc test start <token> [heroic]):"] = "可测试的副本（.dc test start <代号> [heroic]）：",
    ["no test runs active"] = "当前没有运行中的测试。",
    ["no test run active"] = "没有运行中的测试。",
    ["There is no such command."] = "没有这个命令（需要 GM 权限）。",
    ["There is no such subcommand"] = "没有这个子命令。",
}
local zhTestPatterns = {
    { "^multiple test runs active", "有多个测试在运行，请指定测试编号或副本代号" },
    { "^no run matches '(.-)'", "没有匹配 '%1' 的测试" },
    { "^Test run not started: ", "测试未开始：" },
    { "^stopping all test plans", "正在停止所有测试计划" },
    { "is logged in — a roster character must be offline", "已登录——测试队伍的角色必须离线" },
    { "^no character named '(.-)'", "找不到名为 '%1' 的角色" },
    { "is already in another live test run", "已在另一个运行中的测试里" },
    { "No spectator camera running", "当前没有在观战" },
    { "This command must be used in%-game%.", "这个命令需要在游戏内使用。" },
    { "(%d+) test runs? active %(max ([^%)]+)%):", "%1 个测试运行中（上限 %2）：" },
    -- status line: "<runId> hos (heroic) [monitoring] elapsed 312s, gear ilvl<=200 epic, bosses 2/4, state ..."
    { " %(heroic%) %[", "（英雄） [" },
    { "%[spawning_bots%]", "[登录机器人]" }, { "%[provisioning%]", "[配置装备技能]" },
    { "%[grouping%]", "[组队]" }, { "%[teleporting%]", "[传送]" }, { "%[starting%]", "[开始]" },
    { "%[monitoring%]", "[清本中]" }, { "%[tearing_down%]", "[收尾]" },
    { "%] elapsed (%d+)s", "] 已用 %1 秒" },
    { ", gear ilvl<=(%d+) ", "，装备 装等≤%1 " }, { ", gear unlimited ", "，装备 装等不限 " },
    { " server default", " 服务器默认" }, { " normal(,?)", " 普通%1" }, { " uncommon", " 优秀" },
    { " rare", " 精良" }, { " epic", " 史诗" }, { " legendary", " 传说" },
    { ", bosses (%d+)/(%d+)", "，首领 %1/%2" }, { ", state ", "，状态 " },
}

-- One line of a `.dc test` reply, for the test window's output box.
function DCLTestLine(s)
    if not s or s == "" or not IsZh() then return s end
    if zhTestExact[s] then return zhTestExact[s] end
    -- "  hos              Halls of Stone (map 599, level 78, heroic 80)"
    local lead, token, gap, name, map, lvl, rest =
        s:match("^(%s*)(%S+)(%s+)(.-) %(map (%d+), level (%d+)(.-)%)%s*$")
    if token then
        local extra = rest:gsub(", heroic (%d+)", "，英雄 %1"):gsub(", scenario of (%S+)", "，%1 的场景")
        return lead .. token .. gap .. (zhDungeons[name] or name) ..
            "（地图 " .. map .. "，等级 " .. lvl .. extra .. "）"
    end
    for _, p in ipairs(zhTestPatterns) do
        s = s:gsub(p[1], p[2])
    end
    for _, en in ipairs(zhDungeonOrder) do
        s = s:gsub(PlainPattern(en), zhDungeons[en])
    end
    -- The run's live state is the panel's own status text.
    s = s:gsub("，状态 (.*)$", function(st) return "，状态 " .. (DCLDetail(st) or st) end)
    return s
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
