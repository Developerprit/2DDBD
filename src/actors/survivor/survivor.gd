class_name Survivor
extends CharacterBase
## A survivor. Owns the health ladder, the interaction pipeline, the skill check,
## the hook cycle, item usage and every animation state.

# --- identity --------------------------------------------------------------
var survivor_id := 0
var personal_perk := ""
var pal_id := "dwight"

# --- interaction pipeline --------------------------------------------------
var interact_target: Interactable = null
var interact_progress := 0.0
var interact_time_needed := 1.0
var interact_kind: int = Enums.InteractionKind.NONE
var interact_locked := false
var _scan_timer := 0.0

# --- skill check -----------------------------------------------------------
var skill := SkillCheck.new()
var skill_on_generator: Node = null
var great_checks := 0

# --- health / hooks --------------------------------------------------------
var hook_stage := 0
var hook_count := 0
var hook_timer := 0.0
var current_hook: Hook = null
var downed_timer := 0.0
var bleedout_timer := 0.0
var struggle_value := 0.0

# --- other actors ----------------------------------------------------------
var hidden_locker: Locker = null
var trap: BearTrap = null
var carrier: Node = null
var being_healed_by: Node = null
var heal_target: Node = null
var heal_progress := 0.0
var rescue_target: Node = null
var revive_target: Node = null
var wiggle := 0.0
var escaped := false

# --- perks / items ---------------------------------------------------------
var perks: Array = []
var perk_cooldowns: Dictionary = {}
var item_kind := ""
var item_charges := 0.0
var item_addons: Array = []

# --- chase bookkeeping -----------------------------------------------------
var in_chase := false
var chase_timer := 0.0

var _killer_near_alert := 0.0
var _spine_chill := false
var brain: SurvivorBrain = null

signal escaped_signal(survivor: Survivor)


func setup(p_team: int, sprite_set: String, p_name: String, pid: int, ai: bool,
		p_perks: Array, p_item: String) -> void:
	setup_base(p_team, sprite_set, false, p_name, pid, ai)
	pal_id = sprite_set
	perks = p_perks.duplicate()
	item_kind = p_item
	if item_kind != "" and GameConfig.items.has(item_kind):
		item_charges = float(GameConfig.items[item_kind].get("charges", 10.0))
	_rebuild_perk_mods()
	_register_states()
	var cfg: Dictionary = GameConfig.survivors.get(sprite_set, {})
	personal_perk = str(cfg.get("personal_perk", ""))
	if personal_perk != "" and not perks.has(personal_perk):
		perks.append(personal_perk)
	_rebuild_perk_mods()


func _rebuild_perk_mods() -> void:
	perk_mods.clear()
	for pid in perks:
		var p: Dictionary = GameConfig.perks.get(pid, {})
		if p.is_empty():
			continue
		var side := str(p.get("side", "survivor"))
		if side != "survivor":
			continue
		var mods: Dictionary = p.get("mods", {})
		for k in mods.keys():
			match k:
				"interact_mult", "heal_speed", "aura_allies":
					perk_mods[k] = float(perk_mods.get(k, 1.0)) * float(mods[k]) \
							if k != "aura_allies" else float(mods[k])
				"crouch_mult":
					perk_mods[k] = float(mods[k])
				"allow_self_heal":
					perk_mods[k] = 1
				_:
					perk_mods[k] = mods[k]


func _register_states() -> void:
	machine.register("move", MoveState.new(machine, self))
	machine.register("interact", InteractState.new(machine, self))
	machine.register("vault", VaultState.new(machine, self))
	machine.register("locker", LockerState.new(machine, self))
	machine.register("trapped", TrappedState.new(machine, self))
	machine.register("downed", DownedState.new(machine, self))
	machine.register("dying", DyingState.new(machine, self))
	machine.register("hooked", HookedState.new(machine, self))
	machine.register("carried", CarriedState.new(machine, self))
	machine.register("escaped", EscapedState.new(machine, self))
	machine.register("dead", DeadState.new(machine, self))
	machine.change("move")


func _ready() -> void:
	pass


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if is_ai:
		if brain == null and machine != null:
			brain = SurvivorBrain.new(self)
		if brain != null:
			brain.think(delta)
		_scan_timer -= delta
		if _scan_timer <= 0.0:
			_scan_timer = 0.12
			_scan_interactables()
		tick_trails(delta)
		_update_perk_timers(delta)
		return

	_read_input()
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = 0.10
		_scan_interactables()
	tick_trails(delta)
	_update_perk_timers(delta)


func _read_input() -> void:
	var v := Vector2.ZERO
	if Input.is_action_pressed("move_up"):
		v.y -= 1.0
	if Input.is_action_pressed("move_down"):
		v.y += 1.0
	if Input.is_action_pressed("move_left"):
		v.x -= 1.0
	if Input.is_action_pressed("move_right"):
		v.x += 1.0
	move_input = v

	var want_crouch := Input.is_action_pressed("crouch")
	if machine.current_name in ["move", "interact"]:
		if want_crouch:
			gait = Enums.Gait.CROUCH
		elif Input.is_action_pressed("walk"):
			gait = Enums.Gait.WALK
		else:
			gait = Enums.Gait.RUN

	if Input.is_action_just_pressed("interact"):
		_on_action_pressed()
	if Input.is_action_just_released("interact"):
		_on_action_released()
	if Input.is_action_just_pressed("use_item"):
		use_item()


## Hands a vault over to the dedicated movement state.
func _begin_vault(target: Node, end_pos: Vector2, duration: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	# An overshoot can land inside a wall, so pull the destination back onto a
	# walkable tile before committing to it.
	var mc := MatchController.instance
	if mc != null:
		var cell := mc.nearest_open_cell(Utils.tile_of(end_pos))
		if cell.x >= 0 and Utils.tile_center(cell).distance_to(end_pos) <= GameConfig.TILE * 3.0:
			end_pos = Utils.tile_center(cell)
	end_interaction()
	if machine.has_state("vault"):
		machine.force("vault", {"target": target, "end": end_pos, "time": duration})


func _on_action_pressed() -> void:
	# Skill check has priority over everything else.
	if skill.active:
		var grade := skill.press()
		_resolve_skill_check(grade)
		return
	if machine.current_name == "hooked":
		pass
	if machine.current_name == "move":
		_try_start_interaction()


func _on_action_released() -> void:
	if machine.current_name == "interact":
		cancel_interaction()


func _unhandled_input(event: InputEvent) -> void:
	if is_ai:
		return
	if event.is_action_pressed("crouch") and machine.current_name == "move":
		gait = Enums.Gait.CROUCH


# ---------------------------------------------------------------------------
# Interaction scanning
# ---------------------------------------------------------------------------
func _scan_interactables() -> void:
	if machine.current_name != "move":
		return
	var best: Interactable = null
	var best_score := -1.0
	for n in get_tree().get_nodes_in_group("interactable"):
		var it := n as Interactable
		if it == null or not is_instance_valid(it):
			continue
		var d := it.global_position.distance_to(global_position)
		if d > it.interact_radius + GameConfig.TILE:
			continue
		if not it.can_interact(self):
			continue
		# Prefer anything closer, but a hook holding a teammate wins ties.
		var score := 1.0 - d / (it.interact_radius + GameConfig.TILE)
		if it is Hook and (it as Hook).occupied_by != null:
			score += 0.5
		if score > best_score:
			best_score = score
			best = it
	interact_target = best


func nearby_interactable() -> Interactable:
	return interact_target


func _try_start_interaction() -> void:
	if interact_target == null or not is_instance_valid(interact_target):
		return
	var it := interact_target
	if not it.can_interact(self):
		return

	# Vaulting is a movement action, not a hold-to-progress interaction. If we
	# let it fall through to the generic pipeline it plays the sound, resolves
	# instantly and moves nobody -- which is exactly the "cannot vault" bug.
	if it is WindowVault:
		_begin_vault(it, (it as WindowVault).landing_point(global_position),
				(it as WindowVault).vault_time(self))
		return
	if it is Pallet:
		var p := it as Pallet
		if p.state == Pallet.State.STANDING:
			# Slamming the pallet down is instant; the survivor stays put.
			p.drop()
			return
		if p.state == Pallet.State.DROPPED:
			_begin_vault(p, p.landing_point(global_position), p.vault_time(self))
			return
		return

	machine.change("interact", {"target": it})


# ---------------------------------------------------------------------------
# Interaction lifecycle
# ---------------------------------------------------------------------------
func begin_interaction(it: Interactable) -> void:
	interact_target = it
	interact_kind = it.kind
	interact_time_needed = maxf(0.01, it.interact_time(self))
	interact_progress = 0.0
	lock_facing(true)
	face_towards(it.world_center())
	it.on_interact_start(self)
	if it is Generator:
		skill_on_generator = it
	if not it.hold_interact():
		# Instant interactions resolve on the same frame.
		it.on_interact_complete(self)
		end_interaction()


func tick_interaction(delta: float) -> bool:
	if interact_target == null or not is_instance_valid(interact_target):
		end_interaction()
		return true
	var it := interact_target
	if not it.can_interact(self):
		end_interaction()
		return true

	# Progress bar driven by time, with a perk/heal speed multiplier where it
	# makes sense.
	var mult := 1.0
	match it.kind:
		Enums.InteractionKind.GENERATOR:
			mult = float(perk_mods.get("interact_mult", 1.0))
		Enums.InteractionKind.HEAL_SELF, Enums.InteractionKind.HEAL_OTHER:
			mult = float(perk_mods.get("heal_speed", 1.0))
			if item_kind == "medkit" and item_charges > 0.0:
				mult *= 1.5
		_:
			pass
	if it.kind == Enums.InteractionKind.HEAL_SELF and not _can_self_heal():
		end_interaction()
		return true

	var done := it.on_interact_tick(self, delta)
	interact_progress = clampf(interact_progress + (delta / interact_time_needed) * mult,
			0.0, 1.0)
	EventBus.survivor_interact_progress.emit(survivor_id, it.kind, interact_progress)
	if done or interact_progress >= 1.0:
		it.on_interact_complete(self)
		end_interaction()
		return true
	return false


func cancel_interaction() -> void:
	if interact_target != null and is_instance_valid(interact_target):
		interact_target.on_interact_cancel(self)
	skill.abort()
	end_interaction()


func end_interaction() -> void:
	if interact_target != null and is_instance_valid(interact_target):
		interact_target.on_interact_cancel(self)
		interact_target = null
	interact_progress = 0.0
	interact_kind = Enums.InteractionKind.NONE
	skill_on_generator = null
	lock_facing(false)
	EventBus.survivor_interact_cancelled.emit(survivor_id)
	if machine.current_name == "interact":
		machine.change("move")


func _can_self_heal() -> bool:
	if health != Enums.Health.INJURED:
		return false
	if item_kind == "medkit" and item_charges > 0.0:
		return true
	return int(perk_mods.get("allow_self_heal", 0)) == 1


# ---------------------------------------------------------------------------
# Skill checks
# ---------------------------------------------------------------------------
func request_skill_check(source: Node) -> void:
	if skill.active:
		return
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var zone_bonus := 1.0
	if item_kind == "toolbox":
		zone_bonus *= 1.3
	skill.begin(rng, GameConfig.bot_difficulty if is_ai else 1.0, zone_bonus)
	skill_on_generator = source
	skill.on_resolve = _resolve_skill_check
	AudioDirector.play("skillcheck_appear", -6.0)
	EventBus.skill_check_started.emit(survivor_id, skill.great_ratio(),
			skill.good_ratio(), skill.speed)


func _resolve_skill_check(grade: int) -> void:
	if grade < 0:
		return
	EventBus.skill_check_resolved.emit(survivor_id, grade)
	match grade:
		2:
			great_checks += 1
			SaveData.add_bloodpoints("objective", GameConfig.BP_SKILLCHECK_GREAT)
			AudioDirector.play("skillcheck_great", -4.0)
			if skill_on_generator is Generator:
				(skill_on_generator as Generator).progress = minf(1.0,
						(skill_on_generator as Generator).progress + 0.01)
		1:
			SaveData.add_bloodpoints("objective", GameConfig.BP_SKILLCHECK_GOOD)
			AudioDirector.play("skillcheck_good", -6.0)
		0:
			AudioDirector.play("skillcheck_miss", -2.0)
			if skill_on_generator is Generator:
				(skill_on_generator as Generator).explode()
			EventBus.toast.emit(Locale.t("fb.generator_exploded"), Color(0.9, 0.45, 0.35))
			if machine.current_name == "interact":
				cancel_interaction()
	skill_on_generator = null


func _process_skill(delta: float) -> void:
	if skill.active:
		skill.update(delta)


func _process(delta: float) -> void:
	_process_skill(delta)
	_update_chase(delta)
	_update_health_timers(delta)
	if skill.active and is_ai:
		_ai_press_skill_check()


func _ai_press_skill_check() -> void:
	# Bots aim for the great band but are not perfect.
	var err := (1.0 - clampf(GameConfig.bot_difficulty, 0.4, 1.6)) * 0.05
	var window := skill.great_half + err
	if absf(skill.value - skill.great_center) <= window:
		var grade := skill.press()
		if grade >= 0:
			_resolve_skill_check(grade)


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------
func _update_health_timers(delta: float) -> void:
	match health:
		Enums.Health.DOWNED:
			bleedout_timer += delta
			if bleedout_timer >= GameConfig.BLEEDOUT_TIME:
				die("bleedout")
		Enums.Health.HOOKED:
			pass
		_:
			bleedout_timer = 0.0


func take_hit(from_killer: Node, is_lunge := false) -> void:
	if invulnerable_time > 0.0:
		return
	if endurance_time > 0.0 and health == Enums.Health.INJURED:
		# Endurance lets a survivor survive one lethal hit.
		endurance_time = 0.0
		return
	match health:
		Enums.Health.HEALTHY:
			set_health(Enums.Health.INJURED)
			AudioDirector.play_at("scream_f" if pal_id in ["meg", "claudette"] else "scream_m",
					global_position, _camera(), -4.0)
			_notify_hit(from_killer)
		Enums.Health.INJURED:
			set_health(Enums.Health.DOWNED)
			downed_timer = 0.0
			AudioDirector.play_at("hit_heavy", global_position, _camera(), -2.0)
			if machine.has_state("downed"):
				machine.force("downed")
			_notify_hit(from_killer)
		Enums.Health.DOWNED:
			set_health(Enums.Health.DYING)
			if machine.has_state("dying"):
				machine.force("dying")
		_:
			pass
	EventBus.survivor_health_changed.emit(survivor_id, health)


func _notify_hit(killer: Node) -> void:
	SaveData.add_bloodpoints("survival", 200)
	if GameConfig.screen_shake and not is_ai:
		EventBus.camera_shake.emit(2.2, 0.35)
	EventBus.noise_emitted.emit(global_position, 260.0, "scream")
	if killer != null and killer.has_method("on_hit_landed"):
		killer.on_hit_landed(self)


func heal(amount_ratio: float) -> void:
	if health == Enums.Health.INJURED:
		set_health(Enums.Health.HEALTHY)
	elif health == Enums.Health.DOWNED:
		set_health(Enums.Health.INJURED)
	elif health == Enums.Health.DYING:
		set_health(Enums.Health.INJURED)


func revive() -> void:
	if health == Enums.Health.DOWNED or health == Enums.Health.DYING:
		set_health(Enums.Health.INJURED)


func _camera() -> Camera2D:
	var vp := get_viewport()
	return vp.get_camera_2d() if vp != null else null


# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------
func hook_on(hook: Hook, killer: Node) -> void:
	if hook == null:
		return
	current_hook = hook
	hook_count += 1
	hook_stage = 1 if hook_count == 1 else 2
	hook_timer = GameConfig.HOOK_STAGE_TIME
	struggle_value = 1.0
	hook.occupy(self)
	global_position = hook.global_position + Vector2(0, 4)
	set_health(Enums.Health.HOOKED)
	AudioDirector.play_at("hook", global_position, _camera())
	if GameConfig.screen_shake and not is_ai:
		EventBus.camera_shake.emit(1.8, 0.4)
	EventBus.survivor_hooked.emit(survivor_id, hook_stage, hook.global_position)
	SaveData.add_bloodpoints("sacrifice", GameConfig.BP_HOOK)
	if killer != null and killer.has_method("on_hook_complete"):
		killer.on_hook_complete(self, hook)
	if machine.has_state("hooked"):
		machine.force("hooked")


func tick_hook(delta: float) -> void:
	if health != Enums.Health.HOOKED:
		return
	hook_timer -= delta
	if hook_stage == 1:
		if hook_timer <= 0.0:
			_enter_struggle_phase()
	else:
		# Struggle phase: the player must mash to keep the entity at bay.
		struggle_value -= delta / GameConfig.HOOK_STRUGGLE_TIME
		if is_ai:
			struggle_value = maxf(struggle_value, 0.35 + sin(Time.get_ticks_msec() / 400.0) * 0.1)
		if not is_ai and Input.is_action_pressed("interact"):
			struggle_value = minf(1.0, struggle_value + delta * 0.22)
		EventBus.survivor_interact_progress.emit(survivor_id,
				Enums.InteractionKind.HOOKED_SELF, clampf(struggle_value, 0.0, 1.0))
		if struggle_value <= 0.0:
			sacrifice()


func _enter_struggle_phase() -> void:
	hook_stage = 2
	hook_timer = GameConfig.HOOK_STRUGGLE_TIME
	struggle_value = 1.0
	EventBus.survivor_hooked.emit(survivor_id, 2, global_position)
	EventBus.toast.emit(Locale.t("fb.hooked_struggle"), Color(0.9, 0.35, 0.30))
	AudioDirector.play_at("mori", global_position, _camera(), -8.0)


func on_unhooked(hook: Hook, by_self: bool) -> void:
	if hook != null:
		hook.free_hook()
	current_hook = null
	hook_timer = 0.0
	struggle_value = 1.0
	set_health(Enums.Health.INJURED)
	global_position += Vector2(randf_range(-10, 10), randf_range(6, 14))
	EventBus.survivor_unhooked.emit(survivor_id)
	if machine.has_state("move"):
		machine.force("move")
	if not by_self:
		endurance_time = maxf(endurance_time,
				float(perk_mods.get("endurance", 0.0)))


func sacrifice() -> void:
	AudioDirector.play_at("sacrifice", global_position, _camera(), -2.0)
	if current_hook != null and is_instance_valid(current_hook):
		current_hook.free_hook()
	current_hook = null
	die("sacrificed")
	SaveData.add_bloodpoints("sacrifice", GameConfig.BP_SACRIFICE)
	EventBus.survivor_died.emit(survivor_id)


func die(reason: String) -> void:
	set_health(Enums.Health.DEAD)
	SaveData.stats["survivor_deaths"] = int(SaveData.stats.get("survivor_deaths", 0)) + 1
	if machine.has_state("dead"):
		machine.force("dead")
	EventBus.survivor_died.emit(survivor_id)
	if MatchController.instance != null:
		MatchController.instance.on_survivor_out(self, false)


func on_grabbed_from_locker(killer: Node) -> void:
	if hidden_locker != null:
		hidden_locker.hidden_occupant = null
		hidden_locker = null
	AudioDirector.play_at("locker_grab", global_position, _camera())
	if machine.has_state("carried"):
		machine.force("carried")
	begin_carried(killer)


func on_trap_escaped(injured: bool) -> void:
	trap = null
	snared = false
	if injured and GameConfig.TRAP_INJURE_ON_ESCAPE and health == Enums.Health.HEALTHY:
		set_health(Enums.Health.INJURED)
	if machine.has_state("move"):
		machine.force("move")


func on_trap_failed_escape(_t: BearTrap) -> void:
	EventBus.toast.emit(Locale.t("fb.trapped"), Color(0.9, 0.4, 0.35))


func escape_through_hatch() -> void:
	escaped = true
	set_health(Enums.Health.ESCAPED)
	SaveData.add_bloodpoints("survival", GameConfig.BP_ESCAPE)
	EventBus.survivor_escaped.emit(survivor_id)
	escaped_signal.emit(self)
	if machine.has_state("escaped"):
		machine.force("escaped")
	if MatchController.instance != null:
		MatchController.instance.on_survivor_out(self, true)


func escape_through_gate() -> void:
	if escaped:
		return
	escape_through_hatch()


# ---------------------------------------------------------------------------
# Carrying / wiggle
# ---------------------------------------------------------------------------
func begin_carried(killer: Node) -> void:
	carrier = killer
	global_position = killer.global_position + Vector2(0, -6)
	wiggle = 0.0
	if shape != null:
		shape.disabled = true
	if machine.has_state("carried"):
		machine.force("carried")


func tick_carried(delta: float) -> void:
	if carrier == null or not is_instance_valid(carrier):
		return
	global_position = carrier.global_position + Vector2(0, -8)
	facing = Enums.Facing.RIGHT
	if is_ai:
		wiggle += delta * 0.055 * clampf(GameConfig.bot_difficulty, 0.5, 1.4)
	elif Input.is_action_pressed("interact"):
		wiggle += delta * 0.11
	EventBus.survivor_interact_progress.emit(survivor_id, Enums.InteractionKind.GRAB_CARRY,
			clampf(wiggle, 0.0, 1.0))
	if wiggle >= 1.0:
		drop_from_carrier(true)


func drop_from_carrier(stunned_killer: bool) -> void:
	# Cache the carrier first: apply_stun() re-enters drop_carried() on the
	# killer, which calls back into here and would otherwise clear `carrier`
	# while we are still using it.
	var k := carrier
	carrier = null
	wiggle = 0.0
	if k != null and is_instance_valid(k):
		global_position = (k as Node2D).global_position + Vector2(randf_range(-14, 14), 12)
		if k.has_method("on_carry_ended"):
			k.on_carry_ended(self)
		if stunned_killer and k.has_method("apply_stun"):
			k.apply_stun(3.0)
	if shape != null:
		shape.disabled = false
	set_health(Enums.Health.DOWNED)
	if machine.has_state("downed"):
		machine.force("downed")


# ---------------------------------------------------------------------------
# Items & perks
# ---------------------------------------------------------------------------
func give_item(id: String) -> void:
	item_kind = id
	var cfg: Dictionary = GameConfig.items.get(id, {})
	item_charges = float(cfg.get("charges", 10.0))


func use_item() -> void:
	if item_kind == "" or item_charges <= 0.0:
		return
	match item_kind:
		"flashlight":
			_flashlight_beam()
		"medkit":
			if health == Enums.Health.INJURED or health == Enums.Health.DOWNED:
				heal(1.0)
			item_charges -= 4.0
			AudioDirector.play("heal_done", -6.0)
		"toolbox":
			pass
		"map":
			pass


func _flashlight_beam() -> void:
	item_charges -= 2.0
	var killer := _nearest_killer()
	if killer == null:
		return
	if Utils.in_cone(global_position, facing_rad, deg_to_rad(16.0),
			killer.global_position, 120.0):
		if killer.has_method("apply_blind"):
			killer.apply_blind(2.0)
			SaveData.add_bloodpoints("altruism", 300)


func _nearest_killer() -> Node:
	var best: Node = null
	var best_d := 1e9
	for k in get_tree().get_nodes_in_group("killer"):
		if not is_instance_valid(k):
			continue
		var d := global_position.distance_to(k.global_position)
		if d < best_d and d < 160.0:
			best_d = d
			best = k
	return best


func _update_perk_timers(delta: float) -> void:
	for k in perk_cooldowns.keys():
		perk_cooldowns[k] = maxf(0.0, float(perk_cooldowns[k]) - delta)
	_apply_passive_perks(delta)


func _apply_passive_perks(delta: float) -> void:
	# Urban Evasion: crouch faster.
	if perk_mods.has("crouch_mult") and gait == Enums.Gait.CROUCH:
		speed_scale = float(perk_mods["crouch_mult"])
	else:
		speed_scale = 1.0
	# Resilience: faster interactions while injured.
	if perk_mods.has("interact_mult") and health != Enums.Health.HEALTHY:
		pass
	# Adrenaline fires once when the last generator is done.
	if perk_mods.has("instant_heal") and MatchController.instance != null \
			and MatchController.instance.exit_powered and not perk_cooldowns.has("adrenaline_used"):
		perk_cooldowns["adrenaline_used"] = 1.0
		heal(1.0)
		speed_scale = float(perk_mods.get("speed_mult", 1.5))
		get_tree().create_timer(float(perk_mods.get("duration", 5.0))).timeout.connect(
				func() -> void: speed_scale = 1.0)
	# Spine Chill / Whispers style proximity warning.
	var k := _nearest_killer()
	if k != null:
		var d := global_position.distance_to(k.global_position)
		var radius := float(perk_mods.get("warn_radius", 0.0)) * GameConfig.TILE
		_spine_chill = radius > 0.0 and d < radius and k.has_method("is_looking_at") \
				and k.is_looking_at(self)
	else:
		_spine_chill = false


func notify_vaulted(_w: WindowVault) -> void:
	if perk_mods.has("speed_mult") and str(perk_mods.get("source", "")) != "sprint":
		pass


func on_enter_locker(l: Locker) -> void:
	hidden_locker = l
	if machine.has_state("locker"):
		machine.force("locker")


func on_exit_locker() -> void:
	hidden_locker = null
	if machine.has_state("move"):
		machine.force("move")


# ---------------------------------------------------------------------------
# Chase tracking
# ---------------------------------------------------------------------------
func _update_chase(delta: float) -> void:
	var k := _nearest_killer()
	if k == null:
		if in_chase:
			chase_timer -= delta
			if chase_timer <= 0.0:
				in_chase = false
				EventBus.chase_ended.emit(survivor_id)
		return
	var d := global_position.distance_to(k.global_position)
	var chased := d < GameConfig.TERROR_RADIUS * 0.9
	if chased:
		chase_timer = 3.5
		if not in_chase:
			in_chase = true
			SaveData.add_bloodpoints("survival", 100)
			EventBus.chase_started.emit(survivor_id)
			if perk_mods.has("speed_mult") and not perk_cooldowns.has("sprint_burst"):
				perk_cooldowns["sprint_burst"] = float(perk_mods.get("cooldown", 40.0))
				speed_scale = float(perk_mods["speed_mult"])
				get_tree().create_timer(float(perk_mods.get("duration", 3.0))).timeout.connect(
						func() -> void: speed_scale = 1.0)
	elif in_chase:
		chase_timer -= delta
		if chase_timer <= 0.0:
			in_chase = false
			EventBus.chase_ended.emit(survivor_id)


func is_hidden() -> bool:
	return hidden_locker != null


func is_visible_to_killer() -> bool:
	if hidden_locker != null:
		return false
	return health != Enums.Health.DEAD


# ---------------------------------------------------------------------------
# States
# ---------------------------------------------------------------------------
class MoveState:
	extends StateMachine.State

	func enter(_msg: Dictionary = {}) -> void:
		var s := actor as Survivor
		if s.sprite != null:
			s.sprite.self_modulate = Color.WHITE

	func physics(delta: float) -> void:
		var s := actor as Survivor
		s.apply_movement(delta)

	func update(delta: float) -> void:
		var s := actor as Survivor
		# Auto-stand from a crouch-blocked state if the survivor is trapped.
		if s.snared:
			s.snared = false


class InteractState:
	extends StateMachine.State

	var _started := false

	func enter(msg: Dictionary = {}) -> void:
		var s := actor as Survivor
		var it: Interactable = msg.get("target", s.interact_target)
		if it == null:
			machine.change("move")
			return
		s.begin_interaction(it)
		_started = true

	func exit() -> void:
		var s := actor as Survivor
		s.skill.abort()
		s.lock_facing(false)

	func physics(delta: float) -> void:
		var s := actor as Survivor
		s.move_input = Vector2.ZERO
		s.apply_movement(delta)

	func update(delta: float) -> void:
		var s := actor as Survivor
		if s.interact_target == null:
			machine.change("move")
			return
		s.tick_interaction(delta)
		var t: Interactable = s.interact_target
		if t == null:
			return
		if t is Generator:
			s.play_anim("repair")
		elif t.kind == Enums.InteractionKind.HEAL_SELF or t.kind == Enums.InteractionKind.HEAL_OTHER:
			s.play_anim("heal")
		elif t is Chest:
			s.play_anim("heal")

	func can_transition_to(_to: String) -> bool:
		return true


class VaultState:
	extends StateMachine.State

	var _timer := 0.0
	var _target: Node = null
	var _start_pos := Vector2.ZERO
	var _end_pos := Vector2.ZERO
	var _total := 0.5

	func enter(msg: Dictionary = {}) -> void:
		var s := actor as Survivor
		_target = msg.get("target", null)
		_total = maxf(0.08, float(msg.get("time", 0.5)))
		_timer = 0.0
		_start_pos = s.global_position
		_end_pos = msg.get("end", s.global_position)
		s.move_input = Vector2.ZERO
		s.velocity = Vector2.ZERO
		if _end_pos.distance_to(_start_pos) > 1.0:
			s.set_facing_from(_end_pos - _start_pos)
		s.play_anim("vault_%s" % Utils.facing_suffix(s.facing), true)
		s.lock_facing(true)
		s.interact_target = null
		if _target != null and is_instance_valid(_target) and _target.has_method("on_interact_start"):
			_target.on_interact_start(s)

	func exit() -> void:
		var s := actor as Survivor
		s.lock_facing(false)

	func physics(_delta: float) -> void:
		# Driven entirely by update(); applying movement here would fight the
		# interpolation and shove the survivor back into the obstacle.
		pass

	func update(delta: float) -> void:
		var s := actor as Survivor
		_timer += delta
		var t := clampf(_timer / _total, 0.0, 1.0)
		s.global_position = _start_pos.lerp(_end_pos, ease(t, 0.4))
		if t >= 1.0:
			if _target is WindowVault and s.has_method("notify_vaulted"):
				s.notify_vaulted(_target as WindowVault)
			if _target is Pallet and s.has_method("notify_vaulted"):
				s.notify_vaulted(null)
			machine.change("move")


class LockerState:
	extends StateMachine.State

	func enter(_msg: Dictionary = {}) -> void:
		var s := actor as Survivor
		s.velocity = Vector2.ZERO
		s.play_anim("idle_%s" % Utils.facing_suffix(s.facing))
		if s.sprite != null:
			s.sprite.visible = false

	func exit() -> void:
		var s := actor as Survivor
		if s.sprite != null:
			s.sprite.visible = true

	func physics(_delta: float) -> void:
		var s := actor as Survivor
		s.velocity = Vector2.ZERO
		if s.hidden_locker != null and is_instance_valid(s.hidden_locker):
			s.global_position = s.hidden_locker.global_position

	func update(_delta: float) -> void:
		var s := actor as Survivor
		if s.hidden_locker == null or not is_instance_valid(s.hidden_locker):
			machine.change("move")


class TrappedState:
	extends StateMachine.State

	func enter(_msg: Dictionary = {}) -> void:
		var s := actor as Survivor
		s.snared = true
		s.move_input = Vector2.ZERO
		s.velocity = Vector2.ZERO

	func exit() -> void:
		(actor as Survivor).snared = false

	func physics(delta: float) -> void:
		var s := actor as Survivor
		s.move_input = Vector2.ZERO
		s.apply_movement(delta)

	func update(delta: float) -> void:
		var s := actor as Survivor
		if s.trap == null or not is_instance_valid(s.trap) or not s.trap.snapped:
			machine.change("move")
			return
		if s.trap.can_interact(s):
			s.interact_target = s.trap
		# Bots free themselves automatically after a moment.
		if s.is_ai:
			s._ai_trap_timer += delta
			if s._ai_trap_timer > 1.6:
				s._ai_trap_timer = 0.0
				s.trap.on_interact_complete(s)


class DownedState:
	extends StateMachine.State

	func enter(_msg: Dictionary = {}) -> void:
		var s := actor as Survivor
		s.gait = Enums.Gait.CRAWL
		s.play_anim("downed")

	func exit() -> void:
		var s := actor as Survivor
		s.gait = Enums.Gait.RUN

	func physics(delta: float) -> void:
		var s := actor as Survivor
		s.gait = Enums.Gait.CRAWL
		if s.is_ai:
			s.apply_movement(delta)
			return
		s.apply_movement(delta)

	func update(_delta: float) -> void:
		var s := actor as Survivor
		s.play_anim("downed")
		if s.health == Enums.Health.INJURED or s.health == Enums.Health.HEALTHY:
			machine.change("move")


class DyingState:
	extends StateMachine.State

	func enter(_msg: Dictionary = {}) -> void:
		var s := actor as Survivor
		s.velocity = Vector2.ZERO
		s.snared = true
		s.play_anim("downed")

	func exit() -> void:
		(actor as Survivor).snared = false

	func physics(delta: float) -> void:
		var s := actor as Survivor
		s.move_input = Vector2.ZERO
		s.apply_movement(delta)

	func update(_delta: float) -> void:
		var s := actor as Survivor
		if s.health != Enums.Health.DYING:
			if s.health == Enums.Health.HOOKED:
				return
			machine.change("move")


class HookedState:
	extends StateMachine.State

	func enter(_msg: Dictionary = {}) -> void:
		var s := actor as Survivor
		s.velocity = Vector2.ZERO
		s.move_input = Vector2.ZERO
		if s.shape != null:
			s.shape.disabled = true
		s.play_anim("hooked")
		AudioDirector.hooked_loop(true)

	func exit() -> void:
		var s := actor as Survivor
		if s.shape != null:
			s.shape.disabled = false
		AudioDirector.hooked_loop(false)

	func physics(_delta: float) -> void:
		var s := actor as Survivor
		s.velocity = Vector2.ZERO
		if s.current_hook != null and is_instance_valid(s.current_hook):
			s.global_position = s.current_hook.global_position + Vector2(0, 4)

	func update(delta: float) -> void:
		var s := actor as Survivor
		s.tick_hook(delta)
		if s.hook_stage == 2:
			s.play_anim("struggle")
		else:
			s.play_anim("hooked")


class CarriedState:
	extends StateMachine.State

	func enter(_msg: Dictionary = {}) -> void:
		var s := actor as Survivor
		s.play_anim("carried")

	func exit() -> void:
		pass

	func physics(_delta: float) -> void:
		var s := actor as Survivor
		s.tick_carried(_delta)

	func update(_delta: float) -> void:
		var s := actor as Survivor
		if s.carrier == null or not is_instance_valid(s.carrier):
			if s.health != Enums.Health.HOOKED:
				machine.change("downed")


class EscapedState:
	extends StateMachine.State

	func enter(_msg: Dictionary = {}) -> void:
		var s := actor as Survivor
		s.velocity = Vector2.ZERO
		s.collision_layer = 0
		s.collision_mask = 0
		if s.sprite != null:
			s.sprite.modulate = Color(0.7, 0.75, 0.8, 0.55)
		var tw := s.create_tween()
		tw.tween_property(s, "scale", Vector2(0.4, 0.4), 0.6)
		tw.tween_callback(s.queue_free)

	func physics(_delta: float) -> void:
		pass


class DeadState:
	extends StateMachine.State

	func enter(_msg: Dictionary = {}) -> void:
		var s := actor as Survivor
		s.velocity = Vector2.ZERO
		s.move_input = Vector2.ZERO
		s.collision_layer = 0
		s.collision_mask = 0
		s.play_anim("dead")
		if s.sprite != null:
			s.sprite.modulate = Color(0.55, 0.5, 0.55, 0.7)

	func physics(_delta: float) -> void:
		pass


var _ai_trap_timer := 0.0


func on_state_changed(from: String, to: String) -> void:
	EventBus.survivor_state_changed.emit(survivor_id, to)


func _exit_tree() -> void:
	if brain != null:
		brain.dispose()
		brain = null
