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


## Where the actor ends up after vaulting: straight through, on the far side.
##
## The sign of `side` used to be applied as-is, which placed the landing point back
## on the side the actor came from. Vaulting therefore moved you 2.6 tiles *towards*
## where you started -- in play it reads as "I pressed vault and got shoved one step
## backwards", which is exactly the bug that was reported.
##
## Crossing means ending up opposite the side you approached from, so the side term
## is subtracted rather than added. The raw point is then snapped to the nearest
## walkable cell so a window backed by a wall (a common map edge case) cannot drop
## the actor inside solid geometry.
func landing_point(from_pos: Vector2) -> Vector2:
	var normal := Vector2(-direction.y, direction.x)
	var side := signf((from_pos - global_position).dot(normal))
	if is_zero_approx(side):
		side = 1.0
	var raw := global_position - normal * side * GameConfig.TILE * 2.6
	var mc := MatchController.instance
	if mc != null:
		var cell := mc.nearest_open_cell(Utils.tile_of(raw))
		if cell.x >= 0:
			var fixed := Utils.tile_center(cell)
			# Only accept the snap if it stays on the far side of the window; a
			# cell back on the near side would silently turn the vault into a shove.
			if (fixed - global_position).dot(raw - global_position) >= 0.0:
				raw = fixed
	return raw


func on_interact_start(actor: Node) -> void:
	AudioDirector.play_at("vault", global_position, _camera())
	EventBus.noise_emitted.emit(global_position, 180.0, "vault")
	if actor.is_in_group("survivor") and actor.has_method("notify_vaulted"):
		actor.notify_vaulted(self)


func _camera() -> Camera2D:
	var vp := get_viewport()
	return vp.get_camera_2d() if vp != null else null
