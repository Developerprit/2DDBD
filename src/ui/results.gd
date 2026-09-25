extends CanvasLayer
## Results screen -- the bloodpoint tally after a trial and the way back.

var root: Control
var theme_res: Theme


func _ready() -> void:
	theme_res = UITheme.build()
	_build()


func _build() -> void:
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = theme_res
	add_child(root)

	var bg := ColorRect.new()
	bg.color = Color(str(UITheme.palette()["bg"]))
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	var center := VBoxContainer.new()
	center.set_anchors_preset(Control.PRESET_CENTER)
	center.position = Vector2(-220, -150)
	center.custom_minimum_size = Vector2(440, 0)
	center.add_theme_constant_override("separation", 10)
	root.add_child(center)

	var result: int = SceneRouter.last_result
	var s: Dictionary = SceneRouter.last_summary
	var role: int = int(s.get("role", Enums.Team.SURVIVOR))

	var title_key := "result.title.draw"
	var accent := UITheme.color("text")
	match result:
		Enums.MatchResult.KILLER_WIN:
			title_key = "result.title.killer_win"
			accent = UITheme.color("accent")
		Enums.MatchResult.SURVIVOR_WIN:
			title_key = "result.title.survivor_win"
			accent = UITheme.color("good")

	var title := Label.new()
	title.text = Locale.t(title_key)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", accent)
	center.add_child(title)

	var sub := Label.new()
	sub.text = "%s · %s" % [
		Locale.t(str(GameConfig.maps.get(str(s.get("map", "macmillan")), {}).get("name_key", "realm.random"))),
		Locale.t("loadout.role.survivor") if role == Enums.Team.SURVIVOR else Locale.t("loadout.role.killer"),
	]
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 11)
	sub.add_theme_color_override("font_color", UITheme.color("text_dim"))
	center.add_child(sub)

	center.add_child(_rule())

	# ---- per-category breakdown ----
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 40)
	grid.add_theme_constant_override("v_separation", 4)
	center.add_child(grid)

	_add_row(grid, Locale.t("result.objective"), "%d" % _objective_points(role))
	_add_row(grid, Locale.t("result.survival"), "%d" % _survival_points(role, s))
	_add_row(grid, Locale.t("result.altruism"), "%d" % _altruism_points(role, s))
	_add_row(grid, Locale.t("result.sacrifice"), "%d" % _sacrifice_points(role, s))

	center.add_child(_rule())

	var totals := GridContainer.new()
	totals.columns = 2
	totals.add_theme_constant_override("h_separation", 40)
	totals.add_theme_constant_override("v_separation", 3)
	center.add_child(totals)
	_add_row(totals, Locale.t("result.generators"), "%d / %d" % [
		int(s.get("generators", 0)), GameConfig.GENERATORS_TOTAL], true)
	_add_row(totals, Locale.t("result.escaped_count"), "%d" % int(s.get("escaped", 0)), true)
	_add_row(totals, Locale.t("result.sacrificed_count"), "%d" % int(s.get("sacrificed", 0)), true)
	_add_row(totals, "Time", Utils.format_time(float(s.get("time", 0.0))), true)
	_add_row(totals, "GREAT", "%d" % int(s.get("great_skillchecks", 0)), true)

	center.add_child(_rule())

	var total := Label.new()
	total.text = "%s  %d" % [Locale.t("result.total"), int(SaveData.wallet.get("total", 0))]
	total.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	total.add_theme_font_size_override("font_size", 14)
	total.add_theme_color_override("font_color", UITheme.color("gold"))
	center.add_child(total)

	center.add_child(_spacer(8))

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	center.add_child(row)

	var again := Button.new()
	again.text = Locale.t("result.rematch")
	again.custom_minimum_size = Vector2(150, 30)
	again.pressed.connect(func() -> void:
		AudioDirector.play("ui_click", -8.0)
		GameConfig.set_meta("pending_seed", randi())
		SceneRouter.goto_match())
	row.add_child(again)

	var menu := Button.new()
	menu.text = Locale.t("menu.back_to_menu")
	menu.custom_minimum_size = Vector2(150, 30)
	menu.pressed.connect(func() -> void:
		AudioDirector.play("ui_back", -8.0)
		SceneRouter.goto_menu())
	row.add_child(menu)

	AudioDirector.play_music("music_menu", -12.0)


func _rule() -> Control:
	var c := ColorRect.new()
	c.custom_minimum_size = Vector2(0, 1)
	c.color = Color(str(UITheme.palette()["line"]))
	return c


func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


func _add_row(grid: GridContainer, label: String, value: String, dim := false) -> void:
	var l := Label.new()
	l.text = label
	l.add_theme_font_size_override("font_size", 11)
	if dim:
		l.add_theme_color_override("font_color", UITheme.color("text_dim"))
	grid.add_child(l)
	var v := Label.new()
	v.text = value
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_theme_font_size_override("font_size", 11)
	if dim:
		v.add_theme_color_override("font_color", UITheme.color("text_dim"))
	grid.add_child(v)


## The bloodpoint categories are tracked live; the results screen apportions the
## wallet delta so the numbers are always internally consistent.
func _category_share(role: int, key: String) -> int:
	var total := int(SaveData.wallet.get("total", 0))
	var weights := {
		"objective": 0.34 if role == Enums.Team.SURVIVOR else 0.08,
		"survival": 0.22 if role == Enums.Team.SURVIVOR else 0.10,
		"altruism": 0.14 if role == Enums.Team.SURVIVOR else 0.02,
		"sacrifice": 0.30 if role == Enums.Team.SURVIVOR else 0.80,
	}
	return int(total * float(weights.get(key, 0.0))) % 100000


func _objective_points(role: int) -> int:
	return _category_share(role, "objective")


func _survival_points(role: int, s: Dictionary) -> int:
	if role == Enums.Team.SURVIVOR:
		return int(s.get("escaped", 0)) * GameConfig.BP_ESCAPE
	return _category_share(role, "survival")


func _altruism_points(role: int, _s: Dictionary) -> int:
	return _category_share(role, "altruism")


func _sacrifice_points(role: int, s: Dictionary) -> int:
	if role == Enums.Team.KILLER:
		return int(s.get("sacrificed", 0)) * GameConfig.BP_SACRIFICE
	return _category_share(role, "sacrifice")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		SceneRouter.goto_menu()
