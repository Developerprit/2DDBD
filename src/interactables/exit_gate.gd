class_name ExitGate
extends Interactable
## One of the two exit gates. Powered once every generator is done, then the
## lever takes 20 s to pull, after which walking into the gateway escapes.

var gate_id: int = 0
var power_ratio: float = 0.0
var opened := false
var inward: Vector2 = Vector2.RIGHT

var closed_tex: Texture2D
var open_tex: Texture2D

var _bar_fill: ColorRect
var _bar_root: Node2D
var _escape_zone: Area2D


func _build() -> void:
	kind = Enums.InteractionKind.EXIT_SWITCH
	prompt_key = "act.open_gate"
	blocking = false
	interact_radius = 30.0
	super._build()

	closed_tex = AnimBuilder.prop_texture("exit_gate_closed")
	open_tex = AnimBuilder.prop_texture("exit_gate_open")

	sprite = Sprite2D.new()
	sprite.texture = closed_tex
	add_child(sprite)

	_build_bar()
	_build_escape_zone()

	var lever := Sprite2D.new()
	lever.texture = AnimBuilder.prop_texture("exit_switch")
	lever.offset = Vector2(0, -10)
	add_child(lever)


func _build_bar() -> void:
	_bar_root = Node2D.new()
	_bar_root.position = Vector2(0, -22)
	add_child(_bar_root)
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.08, 0.85)
	bg.size = Vector2(44, 5)
	bg.position = Vector2(-22, 0)
	_bar_root.add_child(bg)
	var fill := ColorRect.new()
	fill.color = Color(0.95, 0.80, 0.35)
	fill.size = Vector2(0, 3)
	fill.position = Vector2(-21, 1)
	_bar_root.add_child(fill)
	_bar_fill = fill
	_bar_root.visible = false


func _build_escape_zone() -> void:
	_escape_zone = Area2D.new()
	_escape_zone.collision_layer = 0
	_escape_zone.collision_mask = 0b0010   # layer 2: survivors
	_escape_zone.monitoring = true
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(48, 30)
	shape.shape = rect
	shape.position = -inward * 12.0
	_escape_zone.add_child(shape)
	add_child(_escape_zone)
	_escape_zone.body_entered.connect(_on_body_entered)


func _on_body_entered(node: Node) -> void:
	if not opened:
		return
	if node.is_in_group("survivor") and node.has_method("escape_through_gate"):
		node.escape_through_gate()


func is_powered() -> bool:
	return MatchController.instance != null and MatchController.instance.exit_powered


func can_interact(actor: Node) -> bool:
	return is_powered() and not opened and actor.is_in_group("survivor")


func prompt(_actor: Node) -> String:
	return Locale.t("act.open_gate")


func hold_interact() -> bool:
	return true


func interact_time(_actor: Node) -> float:
	return GameConfig.EXIT_GATE_TIME


func on_interact_start(_actor: Node) -> void:
	_bar_root.visible = true
	AudioDirector.play_at("gate_switch", global_position, _camera())
	EventBus.noise_emitted.emit(global_position, 300.0, "gate")


func on_interact_cancel(_actor: Node) -> void:
	_bar_root.visible = false


func on_interact_tick(_actor: Node, delta: float) -> bool:
	if opened:
		return true
	power_ratio = minf(1.0, power_ratio + delta / GameConfig.EXIT_GATE_TIME)
	if _bar_fill != null:
		_bar_fill.size = Vector2(42.0 * power_ratio, 3)
	EventBus.exit_gate_progress.emit(gate_id, power_ratio)
	if power_ratio >= 1.0:
		open_gate()
		return true
	return false


func open_gate() -> void:
	if opened:
		return
	opened = true
	power_ratio = 1.0
	if sprite != null:
		sprite.texture = open_tex
	if _bar_root != null:
		_bar_root.visible = false
	AudioDirector.play_at("gate_open", global_position, _camera())
	if GameConfig.screen_shake:
		EventBus.camera_shake.emit(1.6, 0.5)
	EventBus.exit_gate_opened.emit(gate_id)
	EventBus.toast.emit(Locale.t("hud.gate_powered"), Color(0.95, 0.80, 0.35))


func progress_ratio() -> float:
	return power_ratio


func _camera() -> Camera2D:
	var vp := get_viewport()
	return vp.get_camera_2d() if vp != null else null
