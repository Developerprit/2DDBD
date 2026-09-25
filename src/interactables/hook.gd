class_name Hook
extends Interactable
## A sacrificial hook.
##
## Hook stages, mirroring the original:
##
##   NONE       free
##   FIRST      the first hooking. A 60 s timer, rescueable, and a single 4 %
##              self-unhook attempt that exists only on this stage.
##   STRUGGLE   reached when that timer runs out, or immediately when the victim is
##              hooked a second time. The bar only drains on its own -- the victim
##              has to fight the entity to hold ground until somebody comes.
##   a third hooking sacrifices immediately, with no timer at all.
##
## WHY THE STAGE LIVES HERE
## ------------------------
## It used to live on the survivor as `hook_stage`, driven by a `tick_hook()` that a
## state called every frame, while this class kept its own `stage` field that was set
## to FIRST on occupy and then never touched again. Two copies of one piece of state,
## and the copy that mattered was wrong in three ways:
##
##   * nothing ever reached STRUGGLE from this side, so a hook could not sacrifice
##     anyone by itself;
##   * the survivor always got `hook_count == 1 ? FIRST : STRUGGLE`, so a *third*
##     hooking just began another struggle phase instead of ending the trial;
##   * bots were floored at 0.25 struggle forever, so a hooked bot was immortal.
##
## The hook now owns the timer, the bar and the stage, and the survivor mirrors it.

## Named `victim` rather than `occupant` because Interactable already declares
## `occupant: Node` -- and a Node-typed field cannot be asked for hook_struggle_input()
## without a cast at every call site.
var victim: Survivor = null
var stage: int = Enums.HookStage.NONE
var timer := 0.0
var struggle := 1.0

## Repeat-hooking the same person on the same post counts as one stage further
## along. That is the original's rule, and it is what makes a killer rotate posts
## instead of camping one.
var last_victim: Survivor = null
## The 4 % self-unhook is one attempt per hooking, not a per-roll chance.
var self_unhook_spent := false

var _glow: PointLight2D


func _build() -> void:
	kind = Enums.InteractionKind.HOOK
	prompt_key = "act.unhook"
	interact_radius = 20.0
	super._build()

	sprite = Sprite2D.new()
	sprite.texture = AnimBuilder.prop_texture("hook")
	sprite.offset = Vector2(0, -14)
	add_child(sprite)

	# Slim: a fat post collider seals the whole tile and wedges anyone pathing past.
	add_blocker_circle(Vector2(0, -6), 3.5)
	set_process(false)


# ---------------------------------------------------------------------------
# Occupation and stages
# ---------------------------------------------------------------------------
## Hooks a survivor. The survivor has already incremented their own hook_count by
## the time we are called, so the stage follows from that count.
func occupy(sv: Survivor) -> void:
	victim = sv
	# Keep the base class bookkeeping honest -- other systems read these.
	occupant = sv
	occupied = true

	var on_same_hook := last_victim == sv
	last_victim = sv

	# Repeat-hooking the same post pushes this victim one stage further along.
	var effective: int = sv.hook_count + (1 if on_same_hook else 0)

	if effective >= 3:
		# Third hooking: the entity takes them. No timer, no rescue window.
		_set_stage(Enums.HookStage.SACRIFICED)
		var v := victim
		victim = null
		occupant = null
		if v != null and is_instance_valid(v):
			v.sacrifice()
		_release()
		return

	self_unhook_spent = false
	struggle = 1.0
	timer = GameConfig.HOOK_STAGE_TIME if effective == 1 else GameConfig.HOOK_STRUGGLE_TIME
	_set_stage(Enums.HookStage.FIRST if effective == 1 else Enums.HookStage.STRUGGLE)
	set_process(true)
	_ensure_glow()


func _set_stage(s: int) -> void:
	stage = s
	if victim == null or not is_instance_valid(victim):
		return
	match s:
		Enums.HookStage.FIRST:
			victim.hook_stage = 1
		Enums.HookStage.STRUGGLE:
			victim.hook_stage = 2
		_:
			victim.hook_stage = 0
	EventBus.survivor_hooked.emit(victim.survivor_id, victim.hook_stage, global_position)


func _process(delta: float) -> void:
	if _glow != null:
		_glow.energy = 0.35 + 0.2 * sin(Time.get_ticks_msec() / 260.0)
	if victim == null or not is_instance_valid(victim):
		return
	tick(delta)


func tick(delta: float) -> void:
	match stage:
		Enums.HookStage.FIRST:
			timer -= delta
			if timer <= 0.0:
				_enter_struggle()
		Enums.HookStage.STRUGGLE:
			# The bar only ever drains by itself. Whatever the victim puts in is
			# what keeps them alive until a rescue arrives.
			struggle -= delta / GameConfig.HOOK_STRUGGLE_TIME
			struggle += victim.hook_struggle_input(delta)
			struggle = clampf(struggle, 0.0, 1.0)
			victim.struggle_value = struggle      # mirrored for the HUD
			EventBus.survivor_interact_progress.emit(victim.survivor_id,
					Enums.InteractionKind.HOOKED_SELF, struggle)
			if struggle <= 0.0:
				_sacrifice()


func _enter_struggle() -> void:
	timer = GameConfig.HOOK_STRUGGLE_TIME
	struggle = 1.0
	_set_stage(Enums.HookStage.STRUGGLE)
	EventBus.toast.emit(Locale.t("fb.hooked_struggle"), Color(0.9, 0.35, 0.30))
	if victim != null and is_instance_valid(victim):
		var cam: Camera2D = victim._camera() if victim.has_method("_camera") else null
		AudioDirector.play_at("mori", global_position, cam, -8.0)
		victim.play_anim("struggle", true)


func _sacrifice() -> void:
	var v := victim
	victim = null
	occupant = null
	_set_stage(Enums.HookStage.SACRIFICED)
	if v != null and is_instance_valid(v):
		v.sacrifice()
	_release()


func _release() -> void:
	occupied = false
	if _glow != null:
		_glow.queue_free()
		_glow = null
	set_process(false)


func free_hook() -> void:
	victim = null
	occupant = null
	stage = Enums.HookStage.NONE
	struggle = 1.0
	_release()


func is_free() -> bool:
	return victim == null or not is_instance_valid(victim)


# ---------------------------------------------------------------------------
# Interaction
# ---------------------------------------------------------------------------
func can_interact(actor: Node) -> bool:
	if victim == null or not is_instance_valid(victim):
		return false
	if not actor.is_in_group("survivor"):
		return false
	if actor == victim:
		# The self-unhook gamble is only offered on a first hooking -- the original
		# removes it entirely afterwards -- and only once per hooking.
		return stage == Enums.HookStage.FIRST and not self_unhook_spent
	return actor.health == Enums.Health.HEALTHY or actor.health == Enums.Health.INJURED


func prompt(actor: Node) -> String:
	if actor == victim:
		return Locale.t("act.self_unhook")
	return Locale.t("act.unhook")


func hold_interact() -> bool:
	return true


func interact_time(actor: Node) -> float:
	if actor == victim:
		return GameConfig.S_SELF_UNHOOK_ATTEMPT
	return GameConfig.UNHOOK_TIME


func on_interact_tick(actor: Node, _delta: float) -> bool:
	if victim == null or not is_instance_valid(victim):
		return true
	if actor == victim:
		# Resolved on completion as a single dice roll, not per tick.
		return false
	return false


func on_interact_complete(actor: Node) -> void:
	if victim == null or not is_instance_valid(victim):
		return

	if actor == victim:
		# One attempt, resolved on completion, and failing is final: the original
		# does not let you keep rolling 4 % until it lands.
		self_unhook_spent = true
		if randf() < GameConfig.S_SELF_UNHOOK_CHANCE:
			var self_v := victim
			free_hook()
			self_v.on_unhooked(self, true)
		else:
			EventBus.toast.emit(Locale.t("fb.skillcheck_miss"), Color(0.85, 0.4, 0.35))
		return

	var v := victim
	free_hook()
	v.on_unhooked(self, false)
	SaveData.add_bloodpoints("altruism", GameConfig.BP_UNHOOK)


func _ensure_glow() -> void:
	if _glow != null:
		return
	_glow = PointLight2D.new()
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 0.9, 0.85, 0.55))
	grad.set_color(1, Color(1, 0.4, 0.3, 0.0))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.width = 64
	gt.height = 64
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	_glow.texture = gt
	_glow.energy = 0.5
	_glow.texture_scale = 1.1
	_glow.position = Vector2(0, -14)
	add_child(_glow)
