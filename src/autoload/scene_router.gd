extends Node
## SceneRouter -- owns scene transitions with a quick fade so nothing pops.
## Also remembers the match summary between the match scene and the results UI.

const FADE_TIME := 0.25

var _fade: ColorRect
var _layer: CanvasLayer
var _busy := false

## Set by the match scene, read by the results screen.
var last_summary: Dictionary = {}
var last_result: int = Enums.MatchResult.DRAW


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	restore_window_mode()
	_layer = CanvasLayer.new()
	_layer.layer = 128
	_layer.name = "TransitionLayer"
	add_child(_layer)

	_fade = ColorRect.new()
	_fade.color = Color(0, 0, 0, 0)
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_fade)


func _make_cover() -> void:
	_fade.mouse_filter = Control.MOUSE_FILTER_STOP


func _uncover() -> void:
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE


## F11 toggles a borderless fullscreen window; the choice is remembered.
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_fullscreen"):
		toggle_fullscreen()
		get_viewport().set_input_as_handled()


func toggle_fullscreen() -> void:
	var want_full := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED
	_apply_fullscreen(want_full)
	GameConfig.fullscreen = want_full
	SaveData.save_all()
	EventBus.toast.emit(Locale.t("settings.fullscreen") + ": "
			+ Locale.t("common.on" if want_full else "common.off"), Color(0.8, 0.82, 0.86))


func _apply_fullscreen(full: bool) -> void:
	# WINDOW_MODE_FULLSCREEN is a borderless window covering the whole screen:
	# no title bar, no frame, and it alt-tabs far more gracefully than
	# EXCLUSIVE_FULLSCREEN on Windows.
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if full
			else DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, full)


func restore_window_mode() -> void:
	var saved := GameConfig.fullscreen
	if saved:
		_apply_fullscreen(true)


func goto(path: String) -> void:
	if _busy:
		return
	_busy = true
	_make_cover()
	var tw := create_tween()
	tw.tween_property(_fade, "color:a", 1.0, FADE_TIME)
	await tw.finished
	var err := get_tree().change_scene_to_file(path)
	if err != OK:
		push_error("SceneRouter: cannot load %s (%d)" % [path, err])
	await get_tree().process_frame
	await get_tree().process_frame
	var tw2 := create_tween()
	tw2.tween_property(_fade, "color:a", 0.0, FADE_TIME)
	await tw2.finished
	_uncover()
	_busy = false


func goto_match() -> void:
	goto("res://scenes/match.tscn")


func goto_menu() -> void:
	get_tree().paused = false
	goto("res://scenes/main_menu.tscn")


func goto_results(result: int, summary: Dictionary) -> void:
	last_result = result
	last_summary = summary
	get_tree().paused = false
	goto("res://scenes/results.tscn")


func quit_game() -> void:
	SaveData.save_all()
	await get_tree().create_timer(0.05).timeout
	get_tree().quit()
