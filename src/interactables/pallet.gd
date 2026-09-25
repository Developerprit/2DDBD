class_name Pallet
extends Interactable
## A wooden pallet wedged between two supports.
##
##   STANDING  upright and NOT in the way -- both teams walk straight past it.
##             Survivors may slam it down to cut a loop short.
##   DROPPED   lying across the gap, blocking the killer. Survivors vault it in
##             0.5 s; the killer has to break it, which costs him 2.6 s.
##   BROKEN    gone.
##
## THREE STATES, THREE SPRITES, ONE COLLIDER
## -----------------------------------------
## Two separate defects used to live here, and together they read to a player as one
## confusing thing:
##
##   * STANDING built a collider, so an upright pallet sealed a doorway that should
##     have been open -- "there is no pallet down, why can I not walk through";
##   * DROPPED pointed at the `pallet_broken` texture, so the board looked smashed
##     the moment it was put down -- "the model looks destroyed after I drop it".
##
## Only the dropped board blocks anything, and each state draws its own sprite.

enum State { STANDING, DROPPED, BROKEN }

## state -> prop sprite. A table, so the three states cannot drift apart.
const SPRITES := {
	State.STANDING: "pallet",
	State.DROPPED: "pallet_dropped",
	State.BROKEN: "pallet_broken",
}

var state: int = State.STANDING
var direction: Vector2 = Vector2.RIGHT   ## axis the pallet spans
var _stun_cooldown := 0.0
var _tex: Dictionary = {}


func _build() -> void:
	kind = Enums.InteractionKind.PALLET_DROP
	prompt_key = "act.drop_pallet"
	interact_radius = 20.0
	super._build()

	for st in SPRITES.keys():
		_tex[st] = AnimBuilder.prop_texture(SPRITES[st])

	sprite = Sprite2D.new()
	sprite.texture = _tex[State.STANDING]
	add_child(sprite)
	rotation = direction.angle()
	_refresh()
	set_process(true)


## Applies the collider and the sprite for the current state.
##
## ONLY a dropped pallet is solid. An upright one is leaning in its frame, not
## barring the gap: giving it a collider closes doorways the player can plainly see
## through, which is exactly how this was reported.
func _refresh() -> void:
	if body != null:
		for c in body.get_children():
			c.queue_free()
	if state == State.DROPPED:
		# Written in local space; the sprite rotation carries it.
		add_blocker(Vector2.ZERO, Vector2(30, 14))
	if sprite != null:
		sprite.texture = _tex.get(state, _tex[State.STANDING])


func can_interact(actor: Node) -> bool:
	if state == State.BROKEN:
		return false
	if actor.is_in_group("survivor"):
		# Upright -> slam it down. Dropped -> vault over it.
		return true
	if actor.is_in_group("killer"):
		# The killer can only interact with a board that is actually in his way.
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
		drop(actor)


func on_interact_complete(_actor: Node) -> void:
	pass


## Slams the pallet down.
##
## If the killer is standing in the gap the board lands on him. That stun is the
## whole reason a survivor spends a pallet at this moment instead of saving it, and
## nothing used to call try_stun() at all -- so the stun mechanic existed on paper
## only.
func drop(by_actor: Node = null) -> void:
	if state != State.STANDING:
		return
	state = State.DROPPED
	_refresh()
	AudioDirector.play_at("pallet_drop", global_position, _camera())
	EventBus.noise_emitted.emit(global_position, 260.0, "pallet")

	var t := create_tween()
	sprite.scale = Vector2(1.08, 1.08)
	t.tween_property(sprite, "scale", Vector2.ONE, 0.15)

	for n in get_tree().get_nodes_in_group("killer"):
		var kk := n as Node2D
		if kk == null or not is_instance_valid(kk):
			continue
		if kk.global_position.distance_to(global_position) <= GameConfig.TILE * 1.7:
			try_stun(kk)
	if by_actor != null and by_actor.has_method("on_pallet_dropped"):
		by_actor.on_pallet_dropped(self)


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
## pallet's span, on the *far* side of it.
##
## Same sign bug as the window -- see WindowVault.landing_point(). The side term used
## to be added, which landed the actor back where they came from.
func landing_point(from_pos: Vector2) -> Vector2:
	var normal := Vector2(-direction.y, direction.x)
	var side := signf((from_pos - global_position).dot(normal))
	if is_zero_approx(side):
		side = 1.0
	return global_position - normal * side * GameConfig.TILE * 2.4


## Only a dropped pallet is worth vaulting. An upright one is not in the way, so
## neither team should get a vault prompt on it -- the killer walking through an
## open gap is correct behaviour, not a missing vault.
func vaultable_by(actor: Node) -> bool:
	if state == State.BROKEN:
		return false
	if actor.is_in_group("killer"):
		return false
	return state == State.DROPPED


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
