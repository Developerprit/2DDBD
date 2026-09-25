class_name Locker
extends Interactable
## A metal locker. Survivors hide inside; the killer can rip the doors open.

var hidden_occupant: Node = null
var open_anim := 0.0
var _lid: Sprite2D


func _build() -> void:
	kind = Enums.InteractionKind.LOCKER_HIDE
	prompt_key = "act.enter_locker"
	interact_radius = 20.0
	super._build()

	sprite = Sprite2D.new()
	sprite.texture = AnimBuilder.prop_texture("locker")
	sprite.offset = Vector2(0, -14)
	add_child(sprite)
	add_blocker(Vector2(0, -14), Vector2(12, 20))
	set_process(false)


func can_interact(actor: Node) -> bool:
	if actor.is_in_group("survivor"):
		if hidden_occupant == actor:
			return true
		return hidden_occupant == null
	if actor.is_in_group("killer"):
		return true
	return false


func prompt(actor: Node) -> String:
	if actor.is_in_group("killer"):
		return "act.grab" if _has_victim() else Locale.t("act.enter_locker")
	if hidden_occupant == actor:
		return Locale.t("act.exit_locker")
	return Locale.t("act.enter_locker")


func hold_interact() -> bool:
	return false


func _has_victim() -> bool:
	return hidden_occupant != null and is_instance_valid(hidden_occupant)


func on_interact_start(actor: Node) -> void:
	if actor.is_in_group("survivor"):
		if hidden_occupant == actor:
			_exit(actor)
		elif hidden_occupant == null:
			_enter(actor)
		return
	# killer
	if _has_victim():
		var victim: Node = hidden_occupant
		hidden_occupant = null
		AudioDirector.play_at("locker_grab", global_position, _camera())
		EventBus.noise_emitted.emit(global_position, 300.0, "locker_grab")
		if victim.has_method("on_grabbed_from_locker"):
			victim.on_grabbed_from_locker(actor)
		if actor.has_method("start_carry"):
			actor.start_carry(victim)
	else:
		AudioDirector.play_at("locker_exit", global_position, _camera())
		_pulse()


func _enter(actor: Node) -> void:
	hidden_occupant = actor
	AudioDirector.play_at("locker_enter", global_position, _camera())
	if actor.has_method("on_enter_locker"):
		actor.on_enter_locker(self)
	_pulse()


func _exit(actor: Node) -> void:
	hidden_occupant = null
	AudioDirector.play_at("locker_exit", global_position, _camera())
	if actor.has_method("on_exit_locker"):
		actor.on_exit_locker()
	_pulse()


func _pulse() -> void:
	var t := create_tween()
	t.tween_property(self, "open_anim", 1.0, 0.08)
	t.tween_property(self, "open_anim", 0.0, 0.35)


func hide_victim(victim: Node) -> void:
	hidden_occupant = victim


func is_occupied() -> bool:
	return _has_victim()


func has_free_slot() -> bool:
	return hidden_occupant == null


func _camera() -> Camera2D:
	var vp := get_viewport()
	return vp.get_camera_2d() if vp != null else null
