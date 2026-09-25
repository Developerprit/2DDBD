class_name WindowVault
extends Interactable
## A window punched through a wall. Both teams vault it, the killer much slower,
## which is what makes a window loop survivable.

var direction: Vector2 = Vector2.RIGHT
var broken := false


func _build() -> void:
	kind = Enums.InteractionKind.WINDOW_VAULT
	prompt_key = "act.vault_window"
	blocking = false
	interact_radius = 18.0
	super._build()

	sprite = Sprite2D.new()
	sprite.texture = AnimBuilder.prop_texture("window")
	add_child(sprite)
	rotation = direction.angle()


func can_interact(actor: Node) -> bool:
	return actor.is_in_group("survivor") or actor.is_in_group("killer")


func prompt(_actor: Node) -> String:
	return Locale.t("act.vault_window")


func hold_interact() -> bool:
	return false


func interact_time(_actor: Node) -> float:
	return 0.0


func vault_time(actor: Node) -> float:
	if actor.is_in_group("killer"):
		return GameConfig.K_WINDOW_VAULT_TIME
	return GameConfig.S_VAULT_WINDOW_TIME


## Where the actor ends up after vaulting: straight through, perpendicular.
func landing_point(from_pos: Vector2) -> Vector2:
	var normal := Vector2(-direction.y, direction.x)
	var side := signf((from_pos - global_position).dot(normal))
	if is_zero_approx(side):
		side = 1.0
	return global_position + normal * side * GameConfig.TILE * 2.6


func on_interact_start(actor: Node) -> void:
	AudioDirector.play_at("vault", global_position, _camera())
	EventBus.noise_emitted.emit(global_position, 180.0, "vault")
	if actor.is_in_group("survivor") and actor.has_method("notify_vaulted"):
		actor.notify_vaulted(self)


func _camera() -> Camera2D:
	var vp := get_viewport()
	return vp.get_camera_2d() if vp != null else null
