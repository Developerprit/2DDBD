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


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_all()


func load_all() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	var settings := {}
	for key in ["language", "master_volume", "sfx_volume", "music_volume",
			"ui_theme", "show_fps", "pixel_snap", "screen_shake", "bot_difficulty"]:
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
	cfg.save(SAVE_PATH)


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
