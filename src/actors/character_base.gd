class_name CharacterBase
extends CharacterBody2D
## Shared behaviour for survivors and the killer: movement integration, sprite
## animation, perception helpers, scratch marks, blood and stun handling.

const LAYER_WORLD := 0b00001
const LAYER_SURVIVOR := 0b00010
const LAYER_KILLER := 0b00100
const LAYER_INTERACTABLE := 0b01000

signal health_changed(new_health: int)
signal died

var team: int = Enums.Team.SURVIVOR
var health: int = Enums.Health.HEALTHY
var gait: int = Enums.Gait.IDLE
var facing: int = Enums.Facing.DOWN
var facing_rad: float = PI * 0.5
var is_ai := false
var peer_id := 1
var display_name := ""
var char_id := ""

var move_input := Vector2.ZERO
var wish_dir := Vector2.ZERO
var speed_scale := 1.0
var stun_time := 0.0
var slow_scale := 1.0
var invulnerable_time := 0.0
var endurance_time := 0.0
var snared := false

var sprite: AnimatedSprite2D
var shape: CollisionShape2D
var machine: StateMachine
var light: PointLight2D

var _footstep_timer := 0.0
var _scratch_timer := 0.0
var _blood_timer := 0.0
var _facing_lock := false

var perk_mods: Dictionary = {}
var held_item := ""
var item_charge := 0.0


func _ready() -> void:
	add_child(_late_init())


func _late_init() -> Node:
	var n := Node.new()
	return n


func setup_base(p_team: int, sprite_set: String, is_killer_sprite: bool,
		p_name: String, pid: int, ai: bool) -> void:
	team = p_team
	char_id = sprite_set
	display_name = p_name
	peer_id = pid
	is_ai = ai

	collision_layer = LAYER_KILLER if team == Enums.Team.KILLER else LAYER_SURVIVOR
	collision_mask = LAYER_WORLD | LAYER_INTERACTABLE
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	floor_stop_on_slope = false
	wall_min_slide_angle = 0.0

	sprite = AnimatedSprite2D.new()
	sprite.name = "Sprite"
	sprite.sprite_frames = AnimBuilder.build(sprite_set, is_killer_sprite)
	sprite.play("idle_down")
	add_child(sprite)

	shape = CollisionShape2D.new()
	var c := CircleShape2D.new()
	c.radius = GameConfig.K_HITBOX_RADIUS if team == Enums.Team.KILLER else GameConfig.S_HITBOX_RADIUS
	shape.shape = c
	# Centred on the body: an offset circle clips tile corners and wedges the
	# actor inside one-tile corridors.
	shape.position = Vector2(0, -2)
	add_child(shape)

	# Every character carries a light. Combined with the CanvasModulate in the
	# match controller and the wall occluders baked into the TileSet, this is
	# what produces real vision occlusion: standing behind a wall puts you in
	# shadow, and shadows are how a survivor knows someone is around the corner.
	light = PointLight2D.new()
	light.texture = _radial(128)
	light.color = Color(1, 0.96, 0.88)
	light.energy = 0.92 if team == Enums.Team.SURVIVOR else 0.62
	light.texture_scale = 1.7
	light.position = Vector2(0, -6)
	light.shadow_enabled = true
	light.shadow_color = Color(0, 0, 0, 0.55)
	light.shadow_filter = PointLight2D.SHADOW_FILTER_PCF5
	add_child(light)

	machine = StateMachine.new()
	machine.name = "StateMachine"
	machine.actor = self
	add_child(machine)

	if team == Enums.Team.SURVIVOR:
		add_to_group("survivor")
	else:
		add_to_group("killer")
	add_to_group("character")


func _radial(size: int) -> Texture2D:
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_color(1, Color(1, 1, 1, 0))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.width = size
	gt.height = size
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	return gt


# ---------------------------------------------------------------------------
# Movement
# ---------------------------------------------------------------------------
func base_speed() -> float:
	if team == Enums.Team.KILLER:
		return GameConfig.m(GameConfig.K_RUN)
	match gait:
		Enums.Gait.WALK: return GameConfig.m(GameConfig.S_WALK)
		Enums.Gait.CROUCH: return GameConfig.m(GameConfig.S_CROUCH)
		Enums.Gait.CRAWL: return GameConfig.m(GameConfig.S_CRAWL)
		_: return GameConfig.m(GameConfig.S_RUN)


func current_speed() -> float:
	if stun_time > 0.0 or snared:
		return 0.0
	return base_speed() * speed_scale * slow_scale


func apply_movement(delta: float) -> void:
	var spd := current_speed()
	if move_input.length() > 0.05:
		wish_dir = move_input.normalized()
	else:
		wish_dir = Vector2.ZERO
	velocity = wish_dir * spd
	move_and_slide()
	_post_move(delta)


func _post_move(delta: float) -> void:
	var moving := velocity.length() > 4.0
	if moving and not _facing_lock:
		set_facing_from(wish_dir)
	if is_ai or true:
		_update_animation()
	_handle_footsteps(delta, moving)
	_scratch_timer -= delta
	_blood_timer -= delta
	if invulnerable_time > 0.0:
		invulnerable_time -= delta
	if endurance_time > 0.0:
		endurance_time -= delta
	if stun_time > 0.0:
		stun_time -= delta


func set_facing_from(v: Vector2) -> void:
	if v.length() < 0.05:
		return
	var new_facing := Utils.facing_from_vector(v)
	facing_rad = v.angle()
	facing = new_facing


func face_towards(pos: Vector2) -> void:
	set_facing_from(pos - global_position)


func lock_facing(locked: bool) -> void:
	_facing_lock = locked


func _update_animation() -> void:
	if sprite == null:
		return
	var suffix := Utils.facing_suffix(facing)
	var anim := "idle_%s" % suffix
	var moving := velocity.length() > 6.0 or wish_dir.length() > 0.1
	match gait:
		Enums.Gait.CROUCH:
			anim = ("crouch_run_%s" if moving else "crouch_idle_%s") % suffix
		Enums.Gait.WALK:
			anim = ("walk_%s" if moving else "idle_%s") % suffix
		Enums.Gait.RUN:
			anim = ("run_%s" if moving else "idle_%s") % suffix
		Enums.Gait.CRAWL:
			anim = "downed"
		Enums.Gait.CARRY:
			anim = "carry_side"
		_:
			anim = "idle_%s" % suffix
	match anim:
		"run_side", "walk_side", "idle_side", "crouch_run_side", "crouch_idle_side":
			sprite.flip_h = Utils.facing_flip(facing)
		_:
			sprite.flip_h = false
	play_if_different(anim)


func play_if_different(anim: String) -> void:
	if sprite == null or not sprite.sprite_frames.has_animation(anim):
		return
	if sprite.animation != anim or not sprite.is_playing():
		sprite.play(anim)


func play_anim(anim: String, restart := false) -> void:
	if sprite == null or not sprite.sprite_frames.has_animation(anim):
		return
	if restart or sprite.animation != anim:
		sprite.play(anim)


func _handle_footsteps(delta: float, moving: bool) -> void:
	if not moving or gait == Enums.Gait.IDLE:
		return
	_footstep_timer -= delta
	if _footstep_timer > 0.0:
		return
	_footstep_timer = 0.34 if gait == Enums.Gait.RUN else 0.55
	var cam := get_viewport().get_camera_2d() if get_viewport() != null else null
	AudioDirector.play_at("footstep_dirt", global_position, cam, -10.0,
			randf_range(0.92, 1.08))
	if team == Enums.Team.SURVIVOR and not is_ai and gait == Enums.Gait.RUN:
		EventBus.noise_emitted.emit(global_position, 120.0, "footstep")


# ---------------------------------------------------------------------------
# Perception
# ---------------------------------------------------------------------------
func can_see(target: Node, range_px: float, fov_deg: float, use_walls: bool = true) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var other := target as Node2D
	if other == null:
		return false
	var to: Vector2 = other.global_position - global_position
	if to.length() > range_px:
		return false
	if to.length() > 8.0:
		var half := deg_to_rad(fov_deg) * 0.5
		if absf(Utils.angle_delta(facing_rad, to.angle())) > half:
			return false
	if use_walls:
		return not blocked_by_wall(global_position, other.global_position)
	return true


func blocked_by_wall(a: Vector2, b: Vector2) -> bool:
	var space := get_world_2d().direct_space_state
	var q := PhysicsRayQueryParameters2D.create(a, b, LAYER_WORLD, [get_rid()])
	var hit := space.intersect_ray(q)
	return not hit.is_empty()


func has_line_of_sight(target: Node) -> bool:
	var other := target as Node2D
	if other == null:
		return false
	return not blocked_by_wall(global_position, other.global_position)


# ---------------------------------------------------------------------------
# Damage & status
# ---------------------------------------------------------------------------
func apply_stun(seconds: float) -> void:
	stun_time = maxf(stun_time, seconds)
	speed_scale = 1.0
	if machine != null and machine.has_state("stun"):
		machine.change("stun")


func set_health(h: int) -> void:
	if health == h:
		return
	health = h
	health_changed.emit(h)
	match h:
		Enums.Health.DEAD:
			died.emit()


func is_incapacitated() -> bool:
	return health == Enums.Health.DOWNED or health == Enums.Health.DYING \
			or health == Enums.Health.HOOKED or health == Enums.Health.DEAD


func emit_scratch_mark() -> void:
	if team != Enums.Team.SURVIVOR:
		return
	if gait != Enums.Gait.RUN:
		return
	var parent := get_parent()
	if parent == null:
		return
	var m := Sprite2D.new()
	m.texture = AnimBuilder.prop_texture("scratch_mark")
	m.global_position = global_position + Vector2(0, 4) \
			+ Vector2(randf_range(-4, 4), randf_range(-3, 3))
	m.rotation = facing_rad
	parent.add_child(m)
	# Grouped + timestamped so the killer AI can ask "what is the freshest trail
	# within 16 m?" instead of wandering blindly.
	m.add_to_group("scratch_mark")
	m.set_meta("scratch", true)
	m.set_meta("born", Time.get_ticks_msec())
	var tw := m.create_tween()
	tw.tween_property(m, "modulate:a", 0.0, GameConfig.SCRATCH_MARK_LIFETIME)
	tw.tween_callback(m.queue_free)


func emit_blood() -> void:
	if team != Enums.Team.SURVIVOR:
		return
	if health != Enums.Health.INJURED and health != Enums.Health.DOWNED:
		return
	var parent := get_parent()
	if parent == null:
		return
	var b := Sprite2D.new()
	b.texture = AnimBuilder.prop_texture("blood_drop")
	b.global_position = global_position + Vector2(randf_range(-5, 5), randf_range(-2, 6))
	parent.add_child(b)
	var life := GameConfig.BLOOD_LIFETIME
	if perk_mods.has("blood_life_mult"):
		life *= float(perk_mods["blood_life_mult"])
	var tw := b.create_tween()
	tw.tween_property(b, "modulate:a", 0.0, life)
	tw.tween_callback(b.queue_free)


func tick_trails(delta: float) -> void:
	if _scratch_timer <= 0.0:
		_scratch_timer = GameConfig.SCRATCH_MARK_INTERVAL
		emit_scratch_mark()
	if _blood_timer <= 0.0:
		_blood_timer = GameConfig.BLOOD_DROP_INTERVAL
		emit_blood()


func get_perk_mods() -> Dictionary:
	return perk_mods


## Dims the sprite when a wall sits between this character and the local player.
## The tint is carried by `self_modulate` and the transparency by `modulate`, so
## a stun tint and an occlusion fade can coexist without fighting.
func set_obscured(obscured: bool) -> void:
	if sprite == null:
		return
	var want := GameConfig.OCCLUDED_ALPHA if obscured else 1.0
	sprite.modulate.a = lerpf(sprite.modulate.a, want, 0.18)


## The direction this character is looking, as a unit vector.
func facing_vector() -> Vector2:
	return Vector2(cos(facing_rad), sin(facing_rad))


## True when `target` sits inside this character's forward cone (no wall check).
func is_in_cone(target: Node2D, range_px: float, half_angle: float) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var to := target.global_position - global_position
	if to.length() > range_px:
		return false
	return absf(Utils.angle_delta(facing_rad, to.angle())) <= half_angle
