class_name Generator
extends Interactable
## A generator. Five of them gate the exit gates.
##
## Cooperative repair mirrors the original: one survivor is 100% efficient,
## two 170%, three 240%, four 300%. Extra hands add up to diminishing returns.

const COOP_SPEED := [1.0, 1.7, 2.4, 3.0]

var progress: float = 0.0
var completed := false
var repairers: Array = []
var index: int = 0

## Set once the killer has damaged it; cleared the moment a survivor touches it.
var regressing := false
## How many times the killer has damaged it. Capped, exactly as in the original.
var regression_events := 0

var _lamp: PointLight2D
var _bar_bg: ColorRect
var _bar_fill: ColorRect
var _bar_root: Node2D


func _build() -> void:
	kind = Enums.InteractionKind.GENERATOR
	prompt_key = "act.repair"
	interact_radius = 26.0
	super._build()

	animated = AnimatedSprite2D.new()
	animated.sprite_frames = AnimBuilder.strip(
			"res://assets/sprites/props/generator.png", 32, 40, 4.0)
	animated.offset = Vector2(0, -14)
	add_child(animated)

	add_blocker(Vector2(0, -14), Vector2(18, 18))

	_lamp = PointLight2D.new()
	_lamp.texture = _make_light_texture()
	_lamp.color = Color(0.85, 0.72, 0.30)
	_lamp.energy = 0.0
	_lamp.texture_scale = 1.6
	_lamp.position = Vector2(0, -22)
	add_child(_lamp)

	_build_progress_bar()
	set_process(true)


func _build_progress_bar() -> void:
	_bar_root = Node2D.new()
	_bar_root.position = Vector2(0, -40)
	add_child(_bar_root)
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.08, 0.85)
	bg.size = Vector2(30, 4)
	bg.position = Vector2(-15, 0)
	_bar_root.add_child(bg)
	var fill := ColorRect.new()
	fill.color = Color(0.90, 0.75, 0.30)
	fill.size = Vector2(0, 2)
	fill.position = Vector2(-14, 1)
	_bar_root.add_child(fill)
	_bar_fill = fill
	_bar_root.visible = false


func _make_light_texture() -> Texture2D:
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_color(1, Color(1, 1, 1, 0))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.width = 128
	gt.height = 128
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	return gt


func interact_time(_actor: Node) -> float:
	return GameConfig.GENERATOR_TIME


# ---------------------------------------------------------------------------
# Damaging (the killer's side of the interaction)
# ---------------------------------------------------------------------------
func kick_time(actor: Node) -> float:
	# Shortened by the killer's interaction-speed bonus (a cloaked Wraith is 4%
	# faster, so kicking a generator while invisible is slightly quicker).
	var mult := 1.0
	if actor != null and actor.has_method("interaction_speed_mult"):
		mult = float(actor.interaction_speed_mult())
	return GameConfig.GEN_DAMAGE_TIME / maxf(0.01, mult)


## A killer may damage a generator that has progress on it, has not been
## finished, and has not already been damaged as many times as the game allows.
func can_be_kicked_by(actor: Node) -> bool:
	if completed or actor == null:
		return false
	if not actor.is_in_group("killer"):
		return false
	if regression_events >= GameConfig.GEN_REGRESSION_LIMIT:
		return false
	return progress > 0.005


func prompt(actor: Node) -> String:
	if actor != null and actor.is_in_group("killer"):
		return Locale.t("act.damage_gen")
	return Locale.t("act.repair")


## Called when the killer finishes the damage animation.
func damage_by_killer(actor: Node) -> void:
	if not can_be_kicked_by(actor):
		return
	regression_events += 1
	progress = maxf(0.0, progress - GameConfig.GEN_DAMAGE_LOSS)
	regressing = true
	if _bar_root != null:
		_bar_root.visible = true
	_update_bar()
	AudioDirector.play_at("gen_explode", global_position, _active_camera(), -8.0)
	EventBus.noise_emitted.emit(global_position, 320.0, "generator_damaged")
	if _active_camera() != null and GameConfig.screen_shake:
		EventBus.camera_shake.emit(0.8, 0.15)
	# Red sparks, the original's cue that a generator is bleeding progress.
	var tween := create_tween()
	if _lamp != null:
		_lamp.color = Color(0.95, 0.25, 0.18)
		_lamp.energy = 1.3
		tween.tween_property(_lamp, "energy", 0.3, 0.9)
	_update_bar()


func can_interact(actor: Node) -> bool:
	if completed:
		return false
	if not actor.is_in_group("survivor"):
		return false
	return actor.health == Enums.Health.HEALTHY or actor.health == Enums.Health.INJURED


func on_interact_start(actor: Node) -> void:
	if not repairers.has(actor):
		repairers.append(actor)
	_refresh_bar()


func on_interact_cancel(actor: Node) -> void:
	repairers.erase(actor)
	_refresh_bar()


func on_interact_tick(actor: Node, delta: float) -> bool:
	if completed:
		return true
	if not repairers.has(actor):
		repairers.append(actor)
	_refresh_bar()

	# Working on it again stops the bleeding immediately.
	if regressing:
		regressing = false
		if animated != null:
			animated.speed_scale = 0.6 + 1.6 * progress

	var hands := repairers.size()
	var speed: float = COOP_SPEED[clampi(hands - 1, 0, COOP_SPEED.size() - 1)]
	var mult := 1.0
	if actor.has_method("get_perk_mods"):
		mult = float(actor.get_perk_mods().get("interact_mult", 1.0))
	if actor.get("held_item") == "toolbox":
		mult *= 1.35
	progress += (delta / GameConfig.GENERATOR_TIME) * speed * mult
	SaveData.add_bloodpoints("objective", int(GameConfig.BP_GENERATOR_TICK * delta * 10.0))

	_spawn_seed_check(actor, delta)

	if progress >= 1.0:
		progress = 1.0
		_complete()
		return true
	_update_bar()
	return false


var _next_skill_check := 6.0


func _spawn_seed_check(actor: Node, delta: float) -> void:
	_next_skill_check -= delta
	if _next_skill_check > 0.0:
		return
	_next_skill_check = randf_range(7.0, 16.0)
	if actor == null or not actor.has_method("request_skill_check"):
		return
	if completed:
		return
	actor.request_skill_check(self)


func _complete() -> void:
	if completed:
		return
	completed = true
	progress = 1.0
	regressing = false
	repairers.clear()
	if _bar_root != null:
		_bar_root.visible = false
	if animated != null:
		animated.pause()
	if _lamp != null:
		_lamp.color = Color(0.95, 0.85, 0.45)
		_lamp.energy = 1.0
	AudioDirector.play_at("gen_done", global_position, _active_camera())
	if _active_camera() != null and GameConfig.screen_shake:
		EventBus.camera_shake.emit(1.4, 0.25)
	set_process(true)
	EventBus.generator_completed.emit(0, GameConfig.GENERATORS_TOTAL)


func explode(fail_amount: float = 0.09, who: Node = null) -> void:
	# Technician: a failed check only blows the generator 25% of the time, and
	# never emits the loud "reveal" noise that normally gives away your position.
	var tech := who != null and who is Survivor and (who as Survivor).perk_mods.has("gen_scream_mult")
	if tech and randf() < 0.75:
		AudioDirector.play_at("gen_explode", global_position, _active_camera(), -8.0)
		return
	progress = maxf(0.0, progress - fail_amount)
	AudioDirector.play_at("gen_explode", global_position, _active_camera())
	if not tech:
		EventBus.noise_emitted.emit(global_position, 220.0, "generator_explode")
	var tween := create_tween()
	_lamp.color = Color(0.95, 0.35, 0.25)
	_lamp.energy = 1.6
	tween.tween_property(_lamp, "energy", 0.0 if completed == false else 1.0, 0.6)
	_update_bar()


func _refresh_bar() -> void:
	if _bar_root != null:
		_bar_root.visible = repairers.size() > 0 and not completed
	_update_bar()


func _update_bar() -> void:
	if _bar_fill == null:
		return
	_bar_fill.size = Vector2(28.0 * progress, 2)
	# A bleeding generator reads red, so both sides can tell at a glance that
	# nothing is being put back in.
	_bar_fill.color = Color(0.92, 0.28, 0.20) if regressing else Color(0.90, 0.75, 0.30)


func _process(delta: float) -> void:
	if completed:
		return

	if regressing:
		# -0.25 charges/s, where one charge is 1/GENERATOR_TIME of the bar.
		progress = maxf(0.0, progress -
				(GameConfig.GEN_REGRESS_CHARGES / GameConfig.GENERATOR_TIME) * delta)
		if progress <= 0.0:
			regressing = false
		if _bar_root != null:
			_bar_root.visible = true

	if animated != null:
		animated.speed_scale = 0.6 + 1.6 * progress
	if _lamp != null:
		if regressing:
			# Sparks: a hard flicker rather than the calm warm ramp.
			_lamp.color = Color(0.95, 0.28, 0.18)
			_lamp.energy = 0.35 + 0.30 * absf(sin(Time.get_ticks_msec() * 0.02))
		else:
			_lamp.energy = 0.15 + 0.45 * progress
			_lamp.color = Color(0.85, 0.72, 0.30).lerp(Color(0.95, 0.85, 0.50), progress)
	if _bar_root != null and _bar_root.visible:
		_update_bar()


func _active_camera() -> Camera2D:
	var vp := get_viewport()
	if vp == null:
		return null
	return vp.get_camera_2d()


func aura_visible_to(_actor: Node) -> bool:
	return completed
