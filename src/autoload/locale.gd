extends Node
## Locale -- bilingual text table (English / Simplified Chinese).
## UI code calls Locale.t("menu.play"). Unknown keys fall back to the key
## itself so nothing ever renders as blank.

var current: String = "zh"

const STRINGS := {
	# --- generic -------------------------------------------------------
	"app.title": {"en": "2DDBD", "zh": "2DDBD"},
	"app.subtitle": {
		"en": "A top-down pixel asymmetric horror game",
		"zh": "俯视角像素非对称生存恐怖",
	},
	"common.back": {"en": "Back", "zh": "返回"},
	"common.close": {"en": "Close", "zh": "关闭"},
	"common.apply": {"en": "Apply", "zh": "应用"},
	"common.cancel": {"en": "Cancel", "zh": "取消"},
	"common.confirm": {"en": "Confirm", "zh": "确定"},
	"common.random": {"en": "Random", "zh": "随机"},
	"common.ready": {"en": "Ready", "zh": "准备"},
	"common.not_ready": {"en": "Not Ready", "zh": "未准备"},
	"common.locked": {"en": "Locked", "zh": "未解锁"},
	"common.on": {"en": "On", "zh": "开"},
	"settings.fullscreen": {"en": "Fullscreen", "zh": "全屏"},
	"common.off": {"en": "Off", "zh": "关"},
	"common.low": {"en": "Low", "zh": "低"},
	"common.medium": {"en": "Medium", "zh": "中"},
	"common.high": {"en": "High", "zh": "高"},
	"common.none": {"en": "None", "zh": "无"},

	# --- main menu -----------------------------------------------------
	"menu.play": {"en": "Play", "zh": "开始游戏"},
	"menu.loadout": {"en": "Loadout", "zh": "配装"},
	"menu.bloodweb": {"en": "Bloodweb", "zh": "血网"},
	"bloodweb.tier": {"en": "Tier", "zh": "层级"},
	"bloodweb.points": {"en": "Bloodpoints", "zh": "血网点"},
	"bloodweb.progress": {"en": "Taken", "zh": "已解锁"},
	"bloodweb.advance": {"en": "Advance to next tier", "zh": "晋升至下一层"},
	"bloodweb.ready": {"en": "You may advance to the next tier.", "zh": "可以晋升到下一层了。"},
	"bloodweb.need_more": {"en": "Take %d more node(s) to advance.", "zh": "再解锁 %d 个节点即可晋升。"},
	"bloodweb.insufficient": {"en": "Not enough bloodpoints", "zh": "血网点不足"},
	"bloodweb.unlocked": {"en": "Unlocked", "zh": "已解锁"},
	"bloodweb.cost": {"en": "Cost", "zh": "消耗"},
	"bloodweb.hint": {"en": "Spend bloodpoints on the ring to unlock perks, items and add-ons. Anything you unlock here becomes selectable in the Loadout screen.",
		"zh": "用血网点解锁环上的节点，获得技能、道具与配件。解锁后的内容会出现在配装页面里。"},
	"menu.customize": {"en": "Customize", "zh": "角色定制"},
	"menu.multiplayer": {"en": "Multiplayer", "zh": "多人对战"},
	"menu.settings": {"en": "Settings", "zh": "设置"},
	"menu.tutorial": {"en": "How to Play", "zh": "操作说明"},
	"menu.credits": {"en": "Credits", "zh": "制作信息"},
	"menu.quit": {"en": "Quit", "zh": "退出游戏"},
	"menu.resume": {"en": "Resume", "zh": "继续游戏"},
	"menu.back_to_menu": {"en": "Main Menu", "zh": "返回主菜单"},

	# --- role / loadout ------------------------------------------------
	"loadout.role": {"en": "Role", "zh": "阵营"},
	"loadout.role.survivor": {"en": "Survivor", "zh": "逃生者"},
	"loadout.role.killer": {"en": "Killer", "zh": "杀手"},
	"loadout.character": {"en": "Character", "zh": "角色"},
	"loadout.power": {"en": "Power", "zh": "力量"},
	"loadout.perks": {"en": "Perks", "zh": "技能"},
	"loadout.item": {"en": "Item", "zh": "道具"},
	"loadout.addons": {"en": "Add-ons", "zh": "配件"},
	"loadout.map": {"en": "Realm", "zh": "地图"},
	"loadout.map.auto": {"en": "Random Realm", "zh": "随机地图"},
	"loadout.stats.speed": {"en": "Speed", "zh": "移动速度"},
	"loadout.stats.terror": {"en": "Terror Radius", "zh": "恐惧半径"},
	"loadout.locked_hint": {"en": "Pick up to 4 perks", "zh": "最多选择 4 个技能"},

	# --- hud -----------------------------------------------------------
	"hud.generators": {"en": "Generators", "zh": "发电机"},
	"hud.generators_left": {"en": "Generators Left", "zh": "剩余发电机"},
	"hud.survivors_left": {"en": "Survivors Left", "zh": "幸存者"},
	"hud.sacrificed": {"en": "Sacrificed", "zh": "已献祭"},
	"hud.escaped": {"en": "Escaped", "zh": "已逃脱"},
	"hud.gate_powered": {"en": "EXIT GATES POWERED", "zh": "出口大门已通电"},
	"hud.hatch_open": {"en": "The hatch has opened", "zh": "地窖已开启"},
	"hud.power": {"en": "Power", "zh": "力量"},
	"hud.bloodlust": {"en": "Bloodlust", "zh": "杀戮欲望"},
	"hud.heartbeat": {"en": "HEARTBEAT", "zh": "心跳"},
	"hud.hooked": {"en": "HOOKED", "zh": "被挂"},
	"hud.dead": {"en": "DEAD", "zh": "死亡"},
	"hud.perks": {"en": "Perks", "zh": "技能"},
	"unit.meters": {"en": "m", "zh": "米"},
	"hud.item": {"en": "Item", "zh": "道具"},

	# --- interactions --------------------------------------------------
	"act.repair": {"en": "Repair", "zh": "修理"},
	"act.repairing": {"en": "Repairing", "zh": "修理中"},
	"act.heal_self": {"en": "Heal Yourself", "zh": "治疗自己"},
	"act.heal_other": {"en": "Heal", "zh": "治疗队友"},
	"act.revive": {"en": "Revive", "zh": "扶起"},
	"act.unhook": {"en": "Unhook", "zh": "解救"},
	"act.escape": {"en": "Escape", "zh": "逃脱"},
	"act.open_gate": {"en": "Open Gate", "zh": "开启大门"},
	"act.vault_window": {"en": "Vault Window", "zh": "翻越窗户"},
	"act.vault_pallet": {"en": "Vault Pallet", "zh": "翻越木板"},
	"act.drop_pallet": {"en": "Drop Pallet", "zh": "放下木板"},
	"act.break_pallet": {"en": "Break Pallet", "zh": "破坏木板"},
	"act.damage_gen": {"en": "Damage Generator", "zh": "破坏发电机"},
	"act.enter_locker": {"en": "Enter Locker", "zh": "躲进衣柜"},
	"act.exit_locker": {"en": "Exit Locker", "zh": "离开衣柜"},
	"act.search_chest": {"en": "Search", "zh": "搜索"},
	"act.enter_hatch": {"en": "Enter Hatch", "zh": "进入地窖"},
	"act.place_trap": {"en": "Set Trap", "zh": "放置陷阱"},
	"act.pickup_trap": {"en": "Pick Up Trap", "zh": "拾取陷阱"},
	"act.disarm_trap": {"en": "Disarm Trap", "zh": "拆除陷阱"},
	"act.escape_trap": {"en": "Free Yourself", "zh": "挣脱陷阱"},
	"act.pickup": {"en": "Pick Up", "zh": "抱起"},
	"act.hook": {"en": "Hook", "zh": "挂钩"},
	"act.self_unhook": {"en": "Attempt Escape", "zh": "尝试挣脱"},
	"act.struggle": {"en": "STRUGGLE", "zh": "挣扎"},
	"act.wiggle": {"en": "WIGGLE", "zh": "扭动"},
	"act.calibrate": {"en": "CALIBRATE", "zh": "校准"},
	"act.use_item": {"en": "Use Item", "zh": "使用道具"},
	"hint.hold": {"en": "Hold", "zh": "长按"},
	"hint.press": {"en": "Hold [E]", "zh": "长按 [E]"},
	"hint.mash": {"en": "Mash [Space]", "zh": "连打 [空格]"},
	"hint.skill_check": {"en": "Press [Space]", "zh": "按 [空格]"},
	"hint.exit_locker": {"en": "Press [E] to leave", "zh": "按 [E] 离开柜子"},
	"hint.no_target": {"en": "Nothing to interact with", "zh": "附近没有可交互的东西"},

	# --- states / feedback ---------------------------------------------
	"state.healthy": {"en": "Healthy", "zh": "健康"},
	"state.injured": {"en": "Injured", "zh": "受伤"},
	"state.downed": {"en": "Downed", "zh": "倒地"},
	"state.dying": {"en": "Dying", "zh": "濒死"},
	"state.hooked": {"en": "Hooked", "zh": "被挂钩"},
	"state.escaped": {"en": "Escaped", "zh": "已逃脱"},
	"state.dead": {"en": "Dead", "zh": "已死亡"},
	"fb.skillcheck_great": {"en": "GREAT!", "zh": "完美!"},
	"fb.skillcheck_good": {"en": "Good", "zh": "不错"},
	"fb.skillcheck_miss": {"en": "MISS", "zh": "失误"},
	"fb.generator_done": {"en": "Generator complete", "zh": "发电机已修复"},
	"fb.generator_exploded": {"en": "Generator exploded", "zh": "发电机爆炸"},
	"fb.chase": {"en": "CHASE", "zh": "追逐中"},
	"fb.bloodlust_up": {"en": "Bloodlust increased", "zh": "杀戮欲望提升"},
	"fb.trapped": {"en": "You are trapped!", "zh": "你被夹住了!"},
	"fb.killer_broke": {"en": "The killer broke something!", "zh": "杀手正在破坏障碍!"},
	"fb.pallet_stun": {"en": "Stunned", "zh": "被击晕"},
	"fb.hooked_first": {"en": "You have been hooked", "zh": "你被挂上了钩子"},
	"fb.hooked_struggle": {"en": "Struggle phase!", "zh": "进入挣扎阶段!"},
	"fb.sacrificed": {"en": "Sacrificed", "zh": "已被献祭"},
	"fb.escaped": {"en": "You escaped", "zh": "你成功逃脱"},

	# --- results -------------------------------------------------------
	"result.title.killer_win": {"en": "ENTITY SATISFIED", "zh": "恶灵满意了"},
	"result.title.survivor_win": {"en": "ESCAPED", "zh": "成功逃脱"},
	"result.title.draw": {"en": "DRAW", "zh": "平局"},
	"result.objective": {"en": "Objective", "zh": "目标"},
	"result.survival": {"en": "Survival", "zh": "生存"},
	"result.altruism": {"en": "Altruism", "zh": "利他"},
	"result.sacrifice": {"en": "Sacrifice", "zh": "献祭"},
	"result.total": {"en": "Total Bloodpoints", "zh": "血网点合计"},
	"result.rematch": {"en": "Play Again", "zh": "再来一局"},
	"result.generators": {"en": "Generators repaired", "zh": "修复发电机"},
	"result.escaped_count": {"en": "Survivors escaped", "zh": "逃生者逃脱数"},
	"result.sacrificed_count": {"en": "Survivors sacrificed", "zh": "逃生者献祭数"},

	# --- settings ------------------------------------------------------
	"settings.title": {"en": "Settings", "zh": "设置"},
	"settings.language": {"en": "Language", "zh": "语言"},
	"settings.audio": {"en": "Audio", "zh": "音频"},
	"settings.master": {"en": "Master Volume", "zh": "主音量"},
	"settings.sfx": {"en": "Effects", "zh": "音效"},
	"settings.music": {"en": "Music", "zh": "音乐"},
	"settings.video": {"en": "Video", "zh": "画面"},
	"settings.theme": {"en": "Interface Theme", "zh": "界面主题"},
	"settings.theme.dark": {"en": "Dark", "zh": "深色"},
	"settings.theme.light": {"en": "Light", "zh": "浅色"},
	"settings.fps": {"en": "Show FPS", "zh": "显示帧率"},
	"settings.blood": {"en": "Blood & Gore", "zh": "血液效果"},
	"settings.shake": {"en": "Screen Shake", "zh": "屏幕震动"},
	"settings.pixel_snap": {"en": "Pixel Snap", "zh": "像素对齐"},
	"settings.gameplay": {"en": "Gameplay", "zh": "玩法"},
	"settings.bot_difficulty": {"en": "Bot Difficulty", "zh": "AI 难度"},
	"settings.difficulty.easy": {"en": "Easy", "zh": "简单"},
	"settings.difficulty.normal": {"en": "Normal", "zh": "普通"},
	"settings.difficulty.hard": {"en": "Hard", "zh": "困难"},
	"settings.difficulty.nightmare": {"en": "Nightmare", "zh": "噩梦"},
	"settings.reset": {"en": "Reset Progress", "zh": "重置进度"},

	# --- multiplayer ---------------------------------------------------
	"mp.title": {"en": "Multiplayer", "zh": "多人对战"},
	"mp.mode": {"en": "Mode", "zh": "模式"},
	"mp.mode.offline": {"en": "Offline (Bots)", "zh": "单机（AI）"},
	"mp.mode.lan": {"en": "LAN / ENet", "zh": "局域网 / ENet"},
	"mp.mode.p2p": {"en": "Peer-to-Peer (no server)", "zh": "点对点（无服务器）"},
	"mp.host": {"en": "Host Match", "zh": "创建房间"},
	"mp.join": {"en": "Join Match", "zh": "加入房间"},
	"mp.ip": {"en": "Host IP", "zh": "主机 IP"},
	"mp.port": {"en": "Port", "zh": "端口"},
	"mp.lobby": {"en": "Lobby", "zh": "房间"},
	"mp.start": {"en": "Start Match", "zh": "开始比赛"},
	"mp.waiting": {"en": "Waiting for players...", "zh": "等待玩家加入..."},
	"mp.signal_local": {"en": "Your offer (send to host)", "zh": "你的 offer（发给主机）"},
	"mp.signal_remote": {"en": "Paste remote offer / answer", "zh": "粘贴对方 offer / answer"},
	"mp.signal_generate": {"en": "Generate Offer", "zh": "生成 Offer"},
	"mp.signal_accept": {"en": "Accept & Reply", "zh": "接受并回复"},
	"mp.signal_reply": {"en": "Your answer (send back)", "zh": "你的 answer（发回对方）"},
	"mp.signal_finish": {"en": "Finish Connection", "zh": "完成连接"},
	"mp.copy": {"en": "Copy", "zh": "复制"},
	"mp.paste": {"en": "Paste", "zh": "粘贴"},
	"mp.connected": {"en": "Connected", "zh": "已连接"},
	"mp.disconnected": {"en": "Disconnected", "zh": "未连接"},

	# --- tutorial ------------------------------------------------------
	"tut.title": {"en": "How to Play", "zh": "操作说明"},
	"tut.survivor": {"en": "As Survivor", "zh": "逃生者"},
	"tut.killer": {"en": "As Killer", "zh": "杀手"},
	"tut.lore": {"en": "Objective", "zh": "目标"},

	# --- realms / characters -------------------------------------------
	"realm.autohaven": {"en": "Auto Haven Wreckers", "zh": "汽车坟场"},
	"realm.macmillan": {"en": "MacMillan Estate", "zh": "麦克米伦庄园"},
	"realm.coldwind": {"en": "Coldwind Farm", "zh": "冷风农场"},
	"realm.yamaoka": {"en": "Yamaoka Estate", "zh": "山冈宅邸"},
	"realm.ormond": {"en": "Ormond Lake Mine", "zh": "奥蒙德矿井"},
	"realm.random": {"en": "Unknown Realm", "zh": "未知地图"},

	"char.dwight": {"en": "Dwight Fairfield", "zh": "德怀特·费尔菲尔德"},
	"char.meg": {"en": "Meg Thomas", "zh": "梅格·托马斯"},
	"char.claudette": {"en": "Claudette Morel", "zh": "克劳黛特·莫瑞尔"},
	"char.jake": {"en": "Jake Park", "zh": "杰克·帕克"},
	"char.trapper": {"en": "The Trapper", "zh": "陷阱杀手"},
	"char.wraith": {"en": "The Wraith", "zh": "幽灵"},
	"char.feng_min": {"en": "Feng Min", "zh": "凤敏"},

	"power.bear_trap": {"en": "Bear Trap", "zh": "捕兽夹"},
	"power.bear_trap.desc": {
		"en": "Place hidden bear traps. Survivors who step on them are held in place until they free themselves.",
		"zh": "在地面放置隐藏的捕兽夹。踩中的逃生者将被定住，直到挣脱为止。",
	},
	"power.bell": {"en": "Wailing Bell", "zh": "哀嚎之铃"},
	"power.bell.desc": {
		"en": "Ring the bell to cloak (2.5s) or uncloak (3s). While cloaked you are invisible beyond 20m, a faint shimmer within, leave no red stain and make no heartbeat, and move at 5.0m/s -- but you cannot attack. Uncloaking grants a 1s burst of 150% speed.",
		"zh": "敲响哀嚎之铃以隐身（2.5秒）或显形（3秒）。隐身时：20米外完全不可见、20米内仅半透明微光，不留下红光、没有心跳，且以5.0米/秒移动——但无法攻击。显形后获得1秒150%移速爆发。",
	},
	"power.bell.cloaked": {"en": "Cloaked", "zh": "隐身"},
	"power.bell.uncloaked": {"en": "Uncloaked", "zh": "显形"},
	"power.bell.ringing": {"en": "Ringing…", "zh": "敲钟中…"},
	"power.bell.cancelled": {"en": "Bell released", "zh": "已松手"},
}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	current = GameConfig.language


func set_language(code: String) -> void:
	current = code
	GameConfig.language = code
	EventBus.settings_changed.emit()


func toggle() -> void:
	set_language("en" if current == "zh" else "zh")


## Translate a key. Optional args are substituted for {0}, {1}, ...
func t(key: String, args: Array = []) -> String:
	var entry: Variant = STRINGS.get(key)
	if entry == null:
		return key
	var text: String = str(entry.get(current, entry.get("en", key)))
	for i in args.size():
		text = text.replace("{%d}" % i, str(args[i]))
	return text
