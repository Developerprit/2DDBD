extends Node
## GameConfig -- the single source of truth for every tunable number.
##
## Scale convention: 1 tile = 16 world px = 1 metre, so Dead by Daylight's
## real world metre-per-second values translate 1:1 into world px/second.
## Speeds below are therefore "metres per second" and "px per second" at once.

# ---------------------------------------------------------------------------
# World / scale
# ---------------------------------------------------------------------------
const TILE := 16
const MAP_TILES := 80
const MAP_SIZE := MAP_TILES * TILE       # 1280 x 1280 px
const CAMERA_ZOOM := 1.0

# ---------------------------------------------------------------------------
# Survivor speeds (m/s == px/s)
# ---------------------------------------------------------------------------
const S_RUN := 4.0
const S_WALK := 2.26
const S_CROUCH := 1.13
const S_CRAWL := 0.72
const S_HOOKED_STRUGGLE_SLOW := 0.0

# ---------------------------------------------------------------------------
# Killer speeds
# ---------------------------------------------------------------------------
const K_RUN := 4.6
const K_CARRY := 3.68
const K_COOLDOWN := 2.76          ## 3s after a swing
const K_BLOODLUST := [4.78, 4.97, 5.15]
const K_LUNGE := 6.0
const K_LUNGE_TIME := 0.5
const K_LUNGE_RECOVER := 1.0
const K_WINDOW_VAULT_TIME := 1.5
const K_PALLET_BREAK_TIME := 2.6
const K_ATTACK_WINDUP := 0.35
const K_ATTACK_COOLDOWN_TIME := 3.0
const K_ATTACK_RANGE := 2.2
const K_ATTACK_ARC_DEG := 90.0
const K_HITBOX_RADIUS := 5.5

# ---------------------------------------------------------------------------
# Survivor body
# ---------------------------------------------------------------------------
const S_HITBOX_RADIUS := 4.5
const S_VAULT_PALLET_TIME := 0.5
const S_VAULT_WINDOW_TIME := 0.5
const S_VAULT_PALLET_TIME_INJURED := 0.5
const S_INTERACT_RANGE := 16.0
const S_SELF_UNHOOK_CHANCE := 0.04
const S_SELF_UNHOOK_ATTEMPT := 2.5

## --- Struggle phase ---------------------------------------------------------
## The bar drains at 1 / HOOK_STRUGGLE_TIME per second on its own. Holding interact
## adds S_STRUGGLE_INPUT, which is just above the drain, so a player who keeps at it
## holds their ground and one who gives up is sacrificed 60 s later.
##
## Bots add nothing and fumble, so they lose roughly 0.022 / s and are taken at
## around 46 s. That number matters: it has to be short enough that a hooked bot
## really is in danger (otherwise the whole sacrifice loop is decorative) and long
## enough that a teammate can cross the realm to rescue them.
const S_STRUGGLE_INPUT := 0.019
const AI_STRUGGLE_FUMBLE_CHANCE := 0.5    ## average fumbles per second
const AI_STRUGGLE_FUMBLE_LOSS := 0.01

# ---------------------------------------------------------------------------
# Objectives
# ---------------------------------------------------------------------------
const GENERATORS_TOTAL := 5
const GENERATOR_TIME := 80.0
const GENERATOR_COOP_PENALTY := 0.15   ## each extra repairer costs 15% efficiency
const EXIT_GATE_TIME := 20.0
const EXIT_GATE_COUNT := 2
const HATCH_REVEAL_REMAINING := 1      ## hatch opens when survivors left == 1
const GATE_POWER_THRESHOLD := GENERATORS_TOTAL

## --- Damaging generators (kicking) -----------------------------------------
## Straight from the original: the killer damages a generator in 1.8 s, it loses
## 5% of its maximum progress on the spot and then regresses at 0.25 charges per
## second until a survivor works on it again. A generator may only suffer
## GEN_REGRESSION_LIMIT regression events in total, after which it cannot be
## damaged again by any means.
const GEN_DAMAGE_TIME := 1.8
const GEN_DAMAGE_LOSS := 0.05
const GEN_REGRESS_CHARGES := 0.25
const GEN_REGRESSION_LIMIT := 8

# ---------------------------------------------------------------------------
# Health / healing
# ---------------------------------------------------------------------------
const HEAL_SELF_TIME := 16.0
const HEAL_OTHER_TIME := 16.0
const REVIVE_TIME := 8.0               ## downed -> injured
const UNHOOK_TIME := 1.0
const HOOK_STAGE_TIME := 60.0
const HOOK_STRUGGLE_TIME := 60.0
const HOOK_SACRIFICE_TIME := 2.0
const BLEEDOUT_TIME := 240.0
const MEDKIT_HEAL_BONUS := 0.5         ## 50% faster with a medkit
const MEDKIT_CHARGES := 24.0

# ---------------------------------------------------------------------------
# Terror radius & perception
# ---------------------------------------------------------------------------
const TERROR_RADIUS := 512.0           ## 32 m
const HEARTBEAT_NEAR := 96.0
const KILLER_VISION_RANGE := 380.0
const KILLER_VISION_FOV_DEG := 100.0
const SURVIVOR_VISION_RANGE := 420.0
const SCRATCH_MARK_LIFETIME := 10.0
const SCRATCH_MARK_INTERVAL := 0.35
const BLOOD_DROP_INTERVAL := 0.6
const BLOOD_LIFETIME := 90.0
const CROUCH_PROFILE_SCALE := 0.45     ## how much smaller a crouching survivor looks

# ---------------------------------------------------------------------------
# Bloodlust
# ---------------------------------------------------------------------------
const BLOODLUST_TIERS := [15.0, 25.0, 35.0]

## --- Red stain: the cone of light the killer casts where he is looking ------
## Survivors read this to know which way he is committing, even through a wall.
##
## This is a pool of light at his feet, not a searchlight. At 11 m it lit up most of
## the screen and stopped reading as "the direction he is facing", which is the only
## job it has. At 3 m it is a committed, local signal again.
const RED_STAIN_RANGE := 48.0           ## 3 m
const RED_STAIN_ANGLE_DEG := 64.0

## --- Scratch-mark following (killer AI) ------------------------------------
const SCRATCH_FOLLOW_RADIUS := 256.0    ## 16 m, per design

## --- Visibility occlusion ---------------------------------------------------
## Ambient light level applied by a CanvasModulate. Walls carry light occluders,
## so anything behind one falls into shadow -- the visual half of line of sight.
##
## 0.46 was too dark to play: a rendered frame showed the terrain almost completely
## lost in shadow, so the layout you had just generated was invisible. The point is
## to make the far side of a wall fall dark, not to make the floor unreadable.
const AMBIENT_DARKNESS := 0.64          ## 1.0 = untouched, 0.0 = pitch black
## How transparent an enemy becomes when a wall is between you and them.
const OCCLUDED_ALPHA := 0.30
const BLOODLUST_RESET := 4.0           ## seconds without a chase to lose a tier
## A chase does not end the instant line of sight breaks. As long as the target
## is still this close the Bloodlust clock keeps running -- without a grace
## window the timer resets constantly and the tiers never fire.
const BLOODLUST_KEEP_RANGE := 256.0     ## 16 m           ## seconds without a chase to lose a tier

# ---------------------------------------------------------------------------
# Bear trap (Trapper power)
# ---------------------------------------------------------------------------
const TRAP_MAX := 6
const TRAP_START := 2
const TRAP_PLACE_TIME := 2.5
const TRAP_PICKUP_TIME := 2.5
const TRAP_ESCAPE_CHANCE := 0.16
const TRAP_ESCAPE_ATTEMPT := 2.5
const TRAP_RADIUS := 5.0
const TRAP_INJURE_ON_ESCAPE := true

# ---------------------------------------------------------------------------
# Wraith (幽灵) — "Wailing Bell" cloak power
# ---------------------------------------------------------------------------
## Cloaked the killer leaves no red stain and makes no heartbeat, and moves a
## touch faster. Uncloaking takes a moment of vulnerability (slower + visible)
## before he is back to full pace. He cannot attack while cloaked.
const WRAITH_CLOAK_CLOAKED_SPEED := 4.6   ## m/s while invisible
const WRAITH_UNCLOAK_SPEED := 4.4         ## m/s once fully materialised
const WRAITH_CLOAK_UNCLOAK_SLOW := 0.86   ## speed multiplier during the materialise lock
const WRAITH_CLOAK_UNCLOAK_LOCK := 1.5   ## seconds of slow + visible after uncloaking
const WRAITH_CLOAK_TOGGLE_CD := 0.3       ## min seconds between cloak toggles (anti-flicker)
const WRAITH_CLOAK_ALPHA := 0.45          ## sprite transparency while cloaked

# ---------------------------------------------------------------------------
# Scoring (bloodpoints)
# ---------------------------------------------------------------------------
const BP_GENERATOR_TICK := 0.5         ## per second of repair
const BP_GENERATOR_DONE := 1250
const BP_SKILLCHECK_GREAT := 150
const BP_SKILLCHECK_GOOD := 50
const BP_HEAL_OTHER := 400
const BP_HEAL_SELF := 250
const BP_UNHOOK := 1500
const BP_ESCAPE := 5000
const BP_CHASE_TICK := 2.0
const BP_HIT := 500
const BP_DOWN := 500
const BP_HOOK := 800
const BP_SACRIFICE := 1500
const BP_TRAP_CATCH := 300

# ---------------------------------------------------------------------------
# Runtime options (persisted by SaveData)
# ---------------------------------------------------------------------------
var language: String = "zh"
var master_volume: float = 0.8
var sfx_volume: float = 0.9
var music_volume: float = 0.6
var ui_theme: String = "dark"
var show_fps: bool = false
var pixel_snap: bool = true
var screen_shake: bool = true
var fullscreen: bool = false      ## borderless fullscreen (F11)

## Currently selected loadout, filled by the Loadout screen.
var selected_killer: String = "trapper"
var selected_map: String = "auto"
var player_role: int = Enums.Team.SURVIVOR
var selected_survivor: String = "dwight"
var selected_item: String = ""
var selected_addons: Array = []
var survivor_perks: Array = []
var killer_perks: Array = []
var net_mode: int = Enums.NetMode.OFFLINE
var bot_difficulty: float = 1.0        ## 0.6 easy .. 1.4 nightmare

## Data tables, populated at boot from res://src/data/*.json
var killers: Dictionary = {}
var survivors: Dictionary = {}
var perks: Dictionary = {}
var items: Dictionary = {}
var maps: Dictionary = {}
var data_ready := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_data()


func load_data() -> void:
	killers = _load_json("res://src/data/killers.json")
	survivors = _load_json("res://src/data/survivors.json")
	perks = _load_json("res://src/data/perks.json")
	items = _load_json("res://src/data/items.json")
	maps = _load_json("res://src/data/maps.json")
	data_ready = true


func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("GameConfig: missing data file %s" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("GameConfig: bad JSON in %s" % path)
		return {}
	return parsed


func apply_save(data: Dictionary) -> void:
	language = str(data.get("language", language))
	master_volume = float(data.get("master_volume", master_volume))
	sfx_volume = float(data.get("sfx_volume", sfx_volume))
	music_volume = float(data.get("music_volume", music_volume))
	ui_theme = str(data.get("ui_theme", ui_theme))
	show_fps = bool(data.get("show_fps", show_fps))
	pixel_snap = bool(data.get("pixel_snap", pixel_snap))
	screen_shake = bool(data.get("screen_shake", screen_shake))
	fullscreen = bool(data.get("fullscreen", fullscreen))
	bot_difficulty = float(data.get("bot_difficulty", bot_difficulty))


func to_save() -> Dictionary:
	return {
		"language": language,
		"master_volume": master_volume,
		"sfx_volume": sfx_volume,
		"music_volume": music_volume,
		"ui_theme": ui_theme,
		"show_fps": show_fps,
		"pixel_snap": pixel_snap,
		"screen_shake": screen_shake,
		"fullscreen": fullscreen,
		"bot_difficulty": bot_difficulty,
	}


## Convert a metre value (DBD real number) to world pixels. Kept as a helper so
## the scale convention stays obvious at call sites.
func m(v: float) -> float:
	return v * float(TILE)


func speed_for_gait(team: int, gait: int, injured: bool) -> float:
	if team == Enums.Team.KILLER:
		match gait:
			Enums.Gait.IDLE: return 0.0
			Enums.Gait.WALK: return m(K_RUN)
			Enums.Gait.RUN: return m(K_RUN)
			Enums.Gait.CARRY: return m(K_CARRY)
			Enums.Gait.CRAWL: return m(K_COOLDOWN)
		return m(K_RUN)
	match gait:
		Enums.Gait.IDLE: return 0.0
		Enums.Gait.WALK: return m(S_WALK)
		Enums.Gait.RUN: return m(S_RUN)
		Enums.Gait.CROUCH: return m(S_CROUCH)
		Enums.Gait.CRAWL: return m(S_CRAWL)
	return m(S_RUN)
