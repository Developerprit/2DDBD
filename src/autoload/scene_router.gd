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
