class_name Hatch
extends Interactable
## The hatch. Opens when only one survivor is left and is an instant escape.

var is_open := false

var closed_tex: Texture2D
var open_tex: Texture2D
var _glow: PointLight2D


func _build() -> void:
	kind = Enums.InteractionKind.HATCH
	prompt_key = "act.enter_hatch"
	interact_radius = 26.0
	super._build()

	closed_tex = AnimBuilder.prop_texture("hatch_closed")
	open_tex = AnimBuilder.prop_texture("hatch_open")

	sprite = Sprite2D.new()
	sprite.texture = closed_tex
	add_child(sprite)

	_glow = PointLight2D.new()
	var grad := Gradient.new()
	grad.set_color(0, Color(0.55, 0.78, 0.95, 0.45))
	grad.set_color(1, Color(0.3, 0.5, 0.8, 0.0))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.width = 96
	gt.height = 96
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	_glow.texture = gt
	_glow.energy = 0.0
	_glow.texture_scale = 1.4
	add_child(_glow)


func open_hatch() -> void:
	if is_open:
		return
	is_open = true
	if sprite != null:
		sprite.texture = open_tex
	if _glow != null:
		_glow.energy = 0.9
	AudioDirector.play_at("hatch_open", global_position, _camera())
	EventBus.hatch_state_changed.emit(true)
	EventBus.toast.emit(Locale.t("hud.hatch_open"), Color(0.55, 0.78, 0.95))


func can_interact(actor: Node) -> bool:
	return is_open and actor.is_in_group("survivor")


func prompt(_actor: Node) -> String:
	return Locale.t("act.enter_hatch")


func hold_interact() -> bool:
	return false


func on_interact_start(actor: Node) -> void:
	if not is_open:
		return
	AudioDirector.play_at("hatch_enter", global_position, _camera())
	if actor.has_method("escape_through_hatch"):
		actor.escape_through_hatch()


func _camera() -> Camera2D:
	var vp := get_viewport()
	return vp.get_camera_2d() if vp != null else null
