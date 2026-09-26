extends Node
## SaveData -- persists settings and the bloodpoint wallet to user://save.cfg

const SAVE_PATH := "user://save.cfg"

## Bumped whenever the perk rules change so an older save can be migrated.
## 2 = the "three exclusive perks per character" rework.
const PERK_VERSION := 2

var wallet: Dictionary = {
	"objective": 0,
	"survival": 0,
	"altruism": 0,
	"sacrifice": 0,
	"total": 0,
}
var stats: Dictionary = {
	"matches": 0,
	"survivor_escapes": 0,
	"survivor_deaths": 0,
	"killer_sacrifices": 0,
	"generators_repaired": 0,
	"skill_checks_great": 0,
}
var last_loadout: Dictionary = {}

## The side (survivor / killer) is chosen once, on the first trial, and locked from
## then on. Persisted here so a restart cannot reopen the choice.
var role_locked := false
var locked_role: int = Enums.Team.SURVIVOR

## Bloodweb progress: char_id -> {"tier": int, "taken": [node_id], "unlocked": ["perk:x"]}.
## Only ids are stored -- the node graph itself is regenerated from a seed, so a
## save file stays tiny and every machine sees an identical web.
var bloodweb: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_all()
	_ensure_starter_budget()


## A fresh profile gets one lump of bloodpoints so the first visit to the
## Bloodweb is not a dead end.
func _ensure_starter_budget() -> void:
	if bloodweb.is_empty() and int(wallet.get("total", 0)) <= 0:
		wallet["total"] = Bloodweb.STARTER_BLOODPOINTS
		wallet["objective"] = Bloodweb.STARTER_BLOODPOINTS
		save_all()


func load_all() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	var settings := {}
	for key in ["language", "master_volume", "sfx_volume", "music_volume",
			"ui_theme", "show_fps", "pixel_snap", "screen_shake", "fullscreen",
		"bot_difficulty"]:
		if cfg.has_section_key("settings", key):
			settings[key] = cfg.get_value("settings", key)
	GameConfig.apply_save(settings)

	if cfg.has_section("wallet"):
		for key in wallet.keys():
			wallet[key] = int(cfg.get_value("wallet", key, wallet[key]))
	if cfg.has_section("stats"):
		for key in stats.keys():
			stats[key] = int(cfg.get_value("stats", key, stats[key]))
	if cfg.has_section("loadout"):
		for key in ["selected_killer", "selected_survivor", "selected_map", "player_role"]:
			if cfg.has_section_key("loadout", key):
				last_loadout[key] = cfg.get_value("loadout", key)
		role_locked = bool(cfg.get_value("loadout", "role_locked", false))
		locked_role = int(cfg.get_value("loadout", "locked_role", Enums.Team.SURVIVOR))
		if role_locked:
			# Re-apply the locked side, or a fresh launch would hand the choice back.
			GameConfig.player_role = locked_role
	if cfg.has_section_key("bloodweb", "data"):
		var raw := str(cfg.get_value("bloodweb", "data", ""))
		if raw != "":
			var parsed: Variant = JSON.parse_string(raw)
			if typeof(parsed) == TYPE_DICTIONARY:
				bloodweb = parsed
	var loaded_version := 0
	if cfg.has_section_key("meta", "perk_version"):
		loaded_version = int(cfg.get_value("meta", "perk_version", 0))
	if loaded_version < PERK_VERSION:
		if migrate_to_three_exclusives():
			save_all()


## The three-exclusives rework changed what a character may use: free shared perks
## are gone and other characters' perks are locked behind TEACHABLE_TIER. Saves
## written before it therefore get their unlock lists rebuilt from the new rules.
## Tier and taken nodes are preserved, so nobody loses bloodweb progress.
func migrate_to_three_exclusives() -> bool:
	# Bail rather than blank everybody's perks if the data tables are not up yet.
	if GameConfig.perks.is_empty():
		return false
	for cid in bloodweb.keys():
		var st: Dictionary = bloodweb[cid]
		if typeof(st) != TYPE_DICTIONARY:
			continue
		var arr: Array = []
		for pid in Bloodweb.exclusive_perks_for(str(cid)):
			arr.append("perk:" + pid)
		st["unlocked"] = arr
	return true


func save_all() -> void:
	var cfg := ConfigFile.new()
	var settings := GameConfig.to_save()
	for key in settings.keys():
		cfg.set_value("settings", key, settings[key])
	for key in wallet.keys():
		cfg.set_value("wallet", key, wallet[key])
	for key in stats.keys():
		cfg.set_value("stats", key, stats[key])
	for key in last_loadout.keys():
		cfg.set_value("loadout", key, last_loadout[key])
	cfg.set_value("loadout", "role_locked", role_locked)
	cfg.set_value("loadout", "locked_role", locked_role)
	cfg.set_value("bloodweb", "data", JSON.stringify(bloodweb))
	cfg.set_value("meta", "perk_version", PERK_VERSION)
	cfg.save(SAVE_PATH)


# ---------------------------------------------------------------------------
# Bloodweb
# ---------------------------------------------------------------------------
func web_state(char_id: String) -> Dictionary:
	if not bloodweb.has(char_id):
		var st := {"tier": 1, "taken": [], "unlocked": []}
		bloodweb[char_id] = st
		_grant_starters(char_id, st)
	return bloodweb[char_id]


## Signatures are granted directly (not through grant_unlock) because that would
## call back into web_state() while it is still building the entry.
##
## A character starts with its own three exclusive perks and NOTHING else. Shared
## perks are progression and must be bought on the bloodweb; other characters'
## exclusives unlock wholesale once their owner reaches Bloodweb.TEACHABLE_TIER.
func _grant_starters(char_id: String, st: Dictionary) -> void:
	var arr: Array = st.get("unlocked", [])
	for pid in Bloodweb.exclusive_perks_for(char_id):
		arr.append("perk:" + pid)
	st["unlocked"] = arr


func web_tier(char_id: String) -> int:
	return int(web_state(char_id).get("tier", 1))


func is_node_taken(char_id: String, node_id: String) -> bool:
	var taken: Array = web_state(char_id).get("taken", [])
	return taken.has(node_id)


func has_unlock(char_id: String, key: String) -> bool:
	var arr: Array = web_state(char_id).get("unlocked", [])
	return arr.has(key)


func grant_unlock(char_id: String, key: String) -> void:
	var st := web_state(char_id)
	var arr: Array = st.get("unlocked", [])
	if not arr.has(key):
		arr.append(key)
		st["unlocked"] = arr


## Spends bloodpoints and claims a node. Returns false when it is already taken
## or the wallet cannot cover it.
func take_node(char_id: String, node_id: String, cost: int) -> bool:
	if is_node_taken(char_id, node_id):
		return false
	if int(wallet.get("total", 0)) < cost:
		return false
	wallet["total"] = int(wallet.get("total", 0)) - cost
	var st := web_state(char_id)
	var taken: Array = st.get("taken", [])
	taken.append(node_id)
	st["taken"] = taken
	save_all()
	return true


func advance_web(char_id: String) -> bool:
	var st := web_state(char_id)
	var nodes := Bloodweb.nodes_for(char_id, GameConfig.killers.has(char_id),
			int(st.get("tier", 1)))
	var taken: Array = st.get("taken", [])
	if taken.size() < Bloodweb.advance_goal(nodes.size()):
		return false
	st["tier"] = int(st.get("tier", 1)) + 1
	st["taken"] = []
	save_all()
	return true


func unlocked_perk_ids(char_id: String) -> Array:
	var out: Array = []
	for key in web_state(char_id).get("unlocked", []):
		var k := str(key)
		if k.begins_with("perk:"):
			var pid := k.substr(5)
			if not out.has(pid):
				out.append(pid)
	# Teachables. Once a same-side character has taken their own web to
	# TEACHABLE_TIER, their three exclusive perks become usable by this one even
	# though they were never bought here.
	var is_killer := GameConfig.killers.has(char_id)
	for pid in GameConfig.perks.keys():
		if out.has(pid):
			continue
		var owner := str(GameConfig.perks[pid].get("owner", ""))
		if owner == "" or owner == char_id:
			continue
		if GameConfig.killers.has(owner) != is_killer:
			continue
		if web_tier(owner) >= Bloodweb.TEACHABLE_TIER:
			out.append(pid)
	return out


func unlocked_item_ids(char_id: String) -> Array:
	var out: Array = []
	for key in web_state(char_id).get("unlocked", []):
		var k := str(key)
		if k.begins_with("item:"):
			out.append(k.substr(5))
	return out


func unlocked_addon_ids(char_id: String) -> Array:
	var out: Array = []
	for key in web_state(char_id).get("unlocked", []):
		var k := str(key)
		if k.begins_with("addon:"):
			out.append(k.substr(6))
	return out


func add_bloodpoints(category: String, amount: int) -> void:
	if amount <= 0:
		return
	wallet[category] = int(wallet.get(category, 0)) + amount
	wallet["total"] = int(wallet.get("total", 0)) + amount
	EventBus.bloodpoints_earned.emit(category, amount)


func commit_match(role: int, summary: Dictionary) -> void:
	stats["matches"] = int(stats["matches"]) + 1
	if role == Enums.Team.SURVIVOR:
		if int(summary.get("escaped", 0)) > 0:
			stats["survivor_escapes"] = int(stats["survivor_escapes"]) + 1
		else:
			stats["survivor_deaths"] = int(stats["survivor_deaths"]) + 1
	else:
		stats["killer_sacrifices"] = int(stats["killer_sacrifices"]) + int(summary.get("sacrificed", 0))
	stats["generators_repaired"] = int(stats["generators_repaired"]) + int(summary.get("generators", 0))
	stats["skill_checks_great"] = int(stats["skill_checks_great"]) + int(summary.get("great_skillchecks", 0))
	save_all()
