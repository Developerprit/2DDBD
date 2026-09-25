class_name BearTrap
extends Interactable
## The Trapper's power: a hidden bear trap.
##
## A survivor who steps on it is held in place and must gamble on escaping
## (16% per 2.5 s attempt, injuring them on success by default). The killer can
## pick a placed trap back up and re-arm it elsewhere.

var owner_killer: Node = null
var snapped := false
var victim: Node = null
var armed := false            ## set false once the killer carries it away
var stealth := false

var _sprite: Sprite2D


func _build() -> void:
	kind = Enums.InteractionKind.TRAP_PLACE
	prompt_key = "act.escape_trap"
	blocking = false
	interact_radius = 14.0
	super._build()

	_sprite = Sprite2D.new()
	_sprite.texture = AnimBuilder.prop_texture("beartrap_open")
	add_child(_sprite)
	set_process(false)


func can_interact(actor: Node) -> bool:
	if not snapped:
		return false
	if actor != victim:
		return false
	return actor.is_in_group("survivor")


func prompt(_actor: Node) -> String:
	return Locale.t("act.escape_trap")


func hold_interact() -> bool:
	return true


func interact_time(actor: Node) -> float:
	var t := GameConfig.TRAP_ESCAPE_ATTEMPT
	if actor.has_method("get_perk_mods"):
		t *= float(actor.get_perk_mods().get("trap_escape_mult", 1.0))
	return t


func on_interact_complete(actor: Node) -> void:
	if not snapped:
		return
	var bonus := 0.0
	if actor != null and actor.has_method("get_perk_mods"):
		bonus = float(actor.get_perk_mods().get("trap_escape_bonus", 0.0))
	if randf() < GameConfig.TRAP_ESCAPE_CHANCE + bonus:
		release()
		AudioDirector.play_at("trap_escape", global_position, _camera())
		if actor.has_method("on_trap_escaped"):
			actor.on_trap_escaped(true)
	else:
		AudioDirector.play_at("trap_snap", global_position, _camera())
		if actor.has_method("on_trap_failed_escape"):
			actor.on_trap_failed_escape(self)


func snap_on(survivor: Node, killer: Node = null) -> void:
	if snapped:
		return
	snapped = true
	victim = survivor
	if killer != null:
		owner_killer = killer
	if _sprite != null:
		_sprite.texture = AnimBuilder.prop_texture("beartrap_closed")
	AudioDirector.play_at("trap_snap", global_position, _camera())
	if GameConfig.screen_shake:
		EventBus.camera_shake.emit(1.2, 0.2)
	EventBus.noise_emitted.emit(global_position, 200.0, "trap")
	EventBus.killer_power_used.emit("bear_trap", {"event": "snap", "pos": global_position})
	SaveData.add_bloodpoints("sacrifice", GameConfig.BP_TRAP_CATCH)


func release() -> void:
	snapped = false
	victim = null
	if _sprite != null:
		_sprite.texture = AnimBuilder.prop_texture("beartrap_open")


func disarm_and_free() -> void:
	release()
	queue_free()


func can_be_picked_up_by(killer: Node) -> bool:
	return killer == owner_killer and not snapped and owner_killer != null


func _camera() -> Camera2D:
	var vp := get_viewport()
	return vp.get_camera_2d() if vp != null else null
