class_name Pallet
extends Interactable
## A wooden pallet wedged between two supports.
##
##   STANDING  both teams can vault it (survivor 0.5 s / killer 1.5 s)
##             survivors may drop it to block the killer
##   DROPPED   survivors still vault it, the killer must break it (2.6 s)
##   BROKEN    gone

enum State { STANDING, DROPPED, BROKEN }

var state: int = State.STANDING
var direction: Vector2 = Vector2.RIGHT   ## axis the pallet spans
var _stun_cooldown := 0.0

var standing_tex: Texture2D
var dropped_tex: Texture2D


func _build() -> void:
	kind = Enums.InteractionKind.PALLET_DROP
	prompt_key = "act.drop_pallet"
	interact_radius = 20.0
	super._build()
	standing_tex = AnimBuilder.prop_texture("pallet")
	dropped_tex = AnimBuilder.prop_texture("pallet_broken")

	sprite = Sprite2D.new()
	sprite.texture = standing_tex
	add_child(sprite)
	rotation = direction.angle()
	_refresh_blocker()
	set_process(true)


func _refresh_blocker() -> void:
	if body != null:
		for c in body.get_children():
			c.queue_free()
	# The blocker is written in local space, so the sprite rotation carries it.
	if state == State.STANDING:
		add_blocker(Vector2.ZERO, Vector2(30, 10))
	elif state == State.DROPPED:
		add_blocker(Vector2.ZERO, Vector2(30, 14))
	if sprite != null:
		sprite.texture = standing_tex if state == State.STANDING else dropped_tex


func can_interact(actor: Node) -> bool:
	if state == State.BROKEN:
		return false
	if actor.is_in_group("survivor"):
		# Standing -> slam it down. Dropped -> vault over it.
		return true
	if actor.is_in_group("killer"):
		return state == State.DROPPED
	return false


func prompt(actor: Node) -> String:
	if actor.is_in_group("killer"):
		return Locale.t("act.break_pallet")
	if state == State.STANDING:
		return Locale.t("act.drop_pallet")
	return Locale.t("act.vault_pallet")


func hold_interact() -> bool:
	return false


func interact_time(_actor: Node) -> float:
	return 0.0


func on_interact_start(actor: Node) -> void:
	if actor.is_in_group("survivor") and state == State.STANDING:
		drop()


func on_interact_complete(_actor: Node) -> void:
	pass


func drop() -> void:
	if state != State.STANDING:
		return
	state = State.DROPPED
	AudioDirector.play_at("pallet_drop", global_position, _camera())
	EventBus.noise_emitted.emit(global_position, 260.0, "pallet")
	_refresh_blocker()
	var t := create_tween()
	sprite.scale = Vector2(1.0, 1.5)
	t.tween_property(sprite, "scale", Vector2.ONE, 0.16)


func break_pallet() -> void:
	if state == State.BROKEN:
		return
	state = State.BROKEN
	AudioDirector.play_at("pallet_break", global_position, _camera())
	EventBus.noise_emitted.emit(global_position, 320.0, "pallet_break")
	if body != null:
		for c in body.get_children():
			c.queue_free()
	var t := create_tween()
	t.tween_property(sprite, "modulate:a", 0.0, 0.35)
	t.tween_callback(queue_free)


## Called by the killer when he finishes breaking it.
func on_broken_by_killer(killer: Node) -> void:
	break_pallet()
	SaveData.add_bloodpoints("sacrifice", 0)


## Where the actor ends up after vaulting: straight over, perpendicular to the
## pallet's span, on whichever side they started from.
func landing_point(from_pos: Vector2) -> Vector2:
	var normal := Vector2(-direction.y, direction.x)
	var side := signf((from_pos - global_position).dot(normal))
	if is_zero_approx(side):
		side = 1.0
	return global_position + normal * side * GameConfig.TILE * 2.4


func vaultable_by(actor: Node) -> bool:
	if state == State.BROKEN:
		return false
	if actor.is_in_group("killer"):
		return state == State.STANDING
	return true


func vault_time(actor: Node) -> float:
	if actor.is_in_group("killer"):
		return GameConfig.K_WINDOW_VAULT_TIME
	return GameConfig.S_VAULT_PALLET_TIME


## Returns true if the pallet stunned the killer.
func try_stun(killer: Node) -> bool:
	if state != State.DROPPED or _stun_cooldown > 0.0:
		return false
	if not killer.has_method("apply_stun"):
		return false
	_stun_cooldown = 3.0
	killer.apply_stun(2.5)
	AudioDirector.play_at("pallet_stun", global_position, _camera())
	SaveData.add_bloodpoints("survival", 300)
	return true


func _process(delta: float) -> void:
	if _stun_cooldown > 0.0:
		_stun_cooldown -= delta


func _camera() -> Camera2D:
	var vp := get_viewport()
	return vp.get_camera_2d() if vp != null else null
