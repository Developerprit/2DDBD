extends Node
## SaveData -- persists settings and the bloodpoint wallet to user://save.cfg

const SAVE_PATH := "user://save.cfg"

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
	if cfg.has_section_key("bloodweb", "data"):
		var raw := str(cfg.get_value("bloodweb", "data", ""))
		if raw != "":
			var parsed: Variant = JSON.parse_string(raw)
			if typeof(parsed) == TYPE_DICTIONARY:
				bloodweb = parsed


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
	cfg.set_value("bloodweb", "data", JSON.stringify(bloodweb))
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
func _grant_starters(char_id: String, st: Dictionary) -> void:
	var arr: Array = st.get("unlocked", [])
	if GameConfig.killers.has(char_id):
		for pid in Bloodweb.STARTER_PERKS["killer"]:
			arr.append("perk:" + pid)
	else:
		for pid in Bloodweb.STARTER_PERKS["survivor"]:
			arr.append("perk:" + pid)
		var personal := str(GameConfig.survivors.get(char_id, {}).get("personal_perk", ""))
		if personal != "":
			arr.append("perk:" + personal)
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
			out.append(k.substr(5))
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
