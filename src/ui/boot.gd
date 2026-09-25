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
	SceneRouter.goto("res://scenes/main_menu.tscn")
