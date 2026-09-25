extends Node
## Boot -- guarantees autoloads and data tables are ready, then hands off to the
## main menu. Kept deliberately tiny; all the real work lives in the systems.

func _ready() -> void:
	randomize()
	# Make sure the generated data tables are loaded before anything reads them.
	if not GameConfig.data_ready:
		GameConfig.load_data()
	# Apply saved settings (language, volumes, theme).
	SaveData.load_all()
	Locale.current = GameConfig.language
	await get_tree().process_frame
	await get_tree().process_frame
	# Headless soak-test hook: skip the title screen and jump straight into a
	# trial. Pair with match_controller's --killer/--as-killer/--debug-match.
	for arg in OS.get_cmdline_user_args():
		if arg == "--boot-match":
			# Headless soak-test hook: skip the title screen AND the fade tween
			# (the tween's `await tw.finished` never resolves without a display
			# loop). Swap straight into the trial scene.
			get_tree().change_scene_to_file("res://scenes/match.tscn")
			return
	SceneRouter.goto("res://scenes/main_menu.tscn")
