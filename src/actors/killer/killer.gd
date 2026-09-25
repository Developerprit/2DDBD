class_name Killer
extends CharacterBase
## The killer. Owns the attack pipeline, bloodlust, the carry/hook cycle, pallet
## breaking, window vaulting and the bear-trap power.

# --- perks / addons --------------------------------------------------------
var perks: Array = []
var addons: Array = []

# --- attack ----------------------------------------------------------------
var attack_cooldown := 0.0
var lunge_active := false
var blinding_time := 0.0
var _attack_hit_done := false

# --- bloodlust -------------------------------------------------------------
var bloodlust_tier := 0
var chase_accum := 0.0
var chase_target: Node = null
var _bloodlust_decay := 0.0

# --- carry / hook ----------------------------------------------------------
var carried: Survivor = null
var current_hook_target: Hook = null

# --- power: bear traps -----------------------------------------------------
var trap_stock := GameConfig.TRAP_START
var placed_traps: Array = []
var trap_on_ground: BearTrap = null

# --- misc ------------------------------------------------------------------
var speed_mult := 1.0
var is_carrying := false
var _last_seen := Vector2.ZERO
var _vision_target: Node = null
var terror_level := 0.0
var _detect_pulse := 0.0
var detected_recently := false
var _place_timer := 0.0

signal carrying_changed(survivor: Survivor)
signal power_state_changed(data: Dictionary)


func setup(p_team: int, sprite_set: String, p_name: String, pid: int, ai: bool,
		p_perks: Array, p_addons: Array) -> void:
	setup_base(p_team, sprite_set, true, p_name, pid, ai)
	char_id = sprite_set
	perks = p_perks.duplicate()
	addons = p_addons.duplicate()
	_rebuild_killer_mods()
	var cfg: Dictionary = GameConfig.killers.get(sprite_set, {})
	var power: Dictionary = cfg.get("power", {})
	trap_stock = int(power.get("start_traps", GameConfig.TRAP_START))
	if addons.has("trapper_sack"):
		trap_stock += 2
	_register_states()
	machine.change("move")


func _rebuild_killer_mods() -> void:
	perk_mods.clear()
	for pid in perks:
		var p: Dictionary = GameConfig.perks.get(pid, {})
		if p.is_empty() or str(p.get("side", "")) != "killer":
			continue
		var mods: Dictionary = p.get("mods", {})
		for k in mods.keys():
			perk_mods[k] = mods[k]
	for aid in addons:
		var cfg: Dictionary = GameConfig.killers.get(char_id, {})
		for a in cfg.get("addons", []):
			if str(a.get("id", "")) == aid:
				for k in a.get("mods", {}).keys():
					perk_mods[k] = a["mods"][k]
	# Perk "speed_mult" keys (No One Escapes Death) drive the killer's pace.
	for pid in perks:
		var p: Dictionary = GameConfig.perks.get(pid, {})
		var mods: Dictionary = p.get("mods", {})
		if str(p.get("side", "")) == "killer" and mods.has("speed_mult") \
				and bool(mods.get("exposed", 0)) :
			perk_mods["perk_speed_mult"] = float(mods["speed_mult"])


func _register_states() -> void:
	machine.register("move", MoveState.new(machine, self))
	machine.register("attack", AttackState.new(machine, self))
	machine.register("carry", CarryState.new(machine, self))
	machine.register("hooking", HookingState.new(machine, self))
	machine.register("break_pallet", BreakPalletState.new(machine, self))
	machine.register("vault", VaultState.new(machine, self))
	machine.register("place_trap", PlaceTrapState.new(machine, self))
	machine.register("stun", StunState.new(machine, self))


# ---------------------------------------------------------------------------
# Base overrides
# ---------------------------------------------------------------------------
func base_speed() -> float:
	var s := GameConfig.m(GameConfig.K_RUN)
	if is_carrying:
		s = GameConfig.m(GameConfig.K_CARRY)
	elif attack_cooldown > 0.0:
		s = GameConfig.m(GameConfig.K_COOLDOWN)
	elif bloodlust_tier > 0:
		s = GameConfig.m(float(GameConfig.K_BLOODLUST[bloodlust_tier - 1]))
	if perk_mods.has("perk_speed_mult"):
		s *= float(perk_mods["perk_speed_mult"])
	return s * speed_mult


func current_speed() -> float:
	if stun_time > 0.0 or blinding_time > 0.0:
		return 0.0
	return base_speed() * speed_scale * slow_scale


func _physics_process(delta: float) -> void:
	if is_ai:
		_ai_think(delta)
	else:
		_read_input()
	_update_power(delta)
	_update_terror(delta)
	if attack_cooldown > 0.0:
		attack_cooldown -= delta
	if blinding_time > 0.0:
		blinding_time -= delta
	_update_bloodlust(delta)


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
	gait = Enums.Gait.RUN

	if Input.is_action_just_pressed("attack"):
		request_attack()
	if Input.is_action_just_pressed("use_power"):
		request_power()
	if Input.is_action_just_pressed("interact") and not is_carrying:
		_try_traverse()
	if Input.is_action_just_pressed("interact"):
		_interact_pressed()


func _interact_pressed() -> void:
	if is_carrying:
		hook_carried()
		return
	# Standing over a downed survivor picks them up; otherwise vault a window
	# or break a pallet in front of the killer.
	if try_pickup():
		return
	var w := _nearest_vaultable_window()
	if w != null:
		if machine.has_state("vault"):
			machine.force("vault", {"target": w, "time": w.vault_time(self)})
		return
	var p := nearest_breakable_pallet()
	if p != null and machine.has_state("break_pallet"):
		machine.force("break_pallet", {"target": p})


func _nearest_vaultable_window() -> WindowVault:
	var best: WindowVault = null
	var best_d := GameConfig.TILE * 1.8
	for n in get_tree().get_nodes_in_group("interactable"):
		var w := n as WindowVault
		if w == null:
			continue
		var d := global_position.distance_to(w.global_position)
		if d < best_d:
			best_d = d
			best = w
	return best


func _update_animation() -> void:
	if is_carrying:
		var suffix := Utils.facing_suffix(facing)
		play_if_different("carry_%s" % suffix)
		if sprite != null:
			sprite.flip_h = Utils.facing_flip(facing)
		return
	super._update_animation()


func _handle_footsteps(delta: float, moving: bool) -> void:
	if not moving:
		return
	_footstep_timer -= delta
	if _footstep_timer > 0.0:
		return
	_footstep_timer = 0.38
	var cam := get_viewport().get_camera_2d() if get_viewport() != null else null
	AudioDirector.play_at("footstep_dirt", global_position, cam, -6.0, 0.78)


# ---------------------------------------------------------------------------
# Terror radius
# ---------------------------------------------------------------------------
func _update_terror(_delta: float) -> void:
	var cfg: Dictionary = GameConfig.killers.get(char_id, {})
	var radius := float(cfg.get("terror_radius", 32.0)) * GameConfig.TILE
	var local_player: Node = null
	for s in get_tree().get_nodes_in_group("survivor"):
		var sv := s as Survivor
		if sv == null or not is_instance_valid(sv):
			continue
		if sv.health == Enums.Health.ESCAPED or sv.health == Enums.Health.DEAD:
			continue
		var d := global_position.distance_to(sv.global_position)
		if not sv.is_ai:
			local_player = sv
			var level := clampf(1.0 - d / radius, 0.0, 1.0)
			EventBus.terror_level.emit(level)
	# Whispers-style detection pulse.
	if perk_mods.has("detect_radius"):
		_detect_pulse -= _delta
		if _detect_pulse <= 0.0:
			_detect_pulse = 1.5
			detected_recently = _any_survivor_within(float(perk_mods["detect_radius"]) * GameConfig.TILE)


func _any_survivor_within(radius: float) -> bool:
	for s in get_tree().get_nodes_in_group("survivor"):
		var sv := s as Survivor
		if sv == null or sv.health in [Enums.Health.ESCAPED, Enums.Health.DEAD]:
			continue
		if global_position.distance_to(sv.global_position) < radius:
			return true
	return false


func is_looking_at(target: Node) -> bool:
	if target == null:
		return false
	return can_see(target, GameConfig.KILLER_VISION_RANGE, GameConfig.KILLER_VISION_FOV_DEG)


func nearest_visible_survivor(include_hidden := false) -> Node:
	var best: Node = null
	var best_d := 1e9
	for s in get_tree().get_nodes_in_group("survivor"):
		var sv := s as Survivor
		if sv == null or not is_instance_valid(sv):
			continue
		# HOOKED survivors are already resolved: chasing one parks the killer
		# beside the hook swinging at a target he cannot hit.
		if sv.health in [Enums.Health.ESCAPED, Enums.Health.DEAD, Enums.Health.HOOKED]:
			continue
		if not include_hidden and sv.is_hidden():
			continue
		var d := global_position.distance_to(sv.global_position)
		if d > GameConfig.KILLER_VISION_RANGE * 1.35:
			continue
		if not can_see(sv, GameConfig.KILLER_VISION_RANGE, GameConfig.KILLER_VISION_FOV_DEG):
			continue
		# Crouching survivors are harder to notice at range.
		if sv.gait == Enums.Gait.CROUCH and d > GameConfig.KILLER_VISION_RANGE * 0.55:
			continue
		if d < best_d:
			best_d = d
			best = sv
	return best


# ---------------------------------------------------------------------------
# Bloodlust
# ---------------------------------------------------------------------------
func _update_bloodlust(delta: float) -> void:
	var visible := nearest_visible_survivor()
	if visible != null:
		if chase_target != visible:
			chase_target = visible
			chase_accum = 0.0
			if bloodlust_tier != 0:
				_set_bloodlust(0)
		chase_accum += delta
		_bloodlust_decay = 0.0
	else:
		_bloodlust_decay += delta
		if _bloodlust_decay > GameConfig.BLOODLUST_RESET:
			chase_target = null
			chase_accum = 0.0
			if bloodlust_tier != 0:
				_set_bloodlust(0)

	var tier := 0
	for i in GameConfig.BLOODLUST_TIERS.size():
		if chase_accum >= float(GameConfig.BLOODLUST_TIERS[i]):
			tier = i + 1
	if tier != bloodlust_tier:
		_set_bloodlust(tier)


func _set_bloodlust(t: int) -> void:
	bloodlust_tier = t
	EventBus.bloodlust_changed.emit(t)
	if t > 0:
		AudioDirector.play("bloodlust", -14.0)
		EventBus.toast.emit("%s %d" % [Locale.t("hud.bloodlust"), t], Color(0.85, 0.40, 0.32))


# ---------------------------------------------------------------------------
# Attack
# ---------------------------------------------------------------------------
## Interact key while not carrying someone: vault a window, hop a standing
## pallet, or start breaking a dropped one.
func _try_traverse() -> void:
	if machine.current_name != "move":
		return
	var w := _nearest_window()
	if w != null:
		end_carry_anim()
		machine.force("vault", {"target": w, "time": w.vault_time(self),
				"end": w.landing_point(global_position)})
		return
	var standing := _nearest_pallet_in_state(Pallet.State.STANDING)
	if standing != null:
		machine.force("vault", {"target": standing, "time": standing.vault_time(self),
				"end": standing.landing_point(global_position)})
		return
	var dropped := nearest_breakable_pallet()
	if dropped != null:
		machine.force("break_pallet", {"target": dropped})


func end_carry_anim() -> void:
	pass


func _nearest_window() -> WindowVault:
	var best: WindowVault = null
	var best_d := GameConfig.TILE * 1.9
	for n in get_tree().get_nodes_in_group("interactable"):
		var w := n as WindowVault
		if w == null or w.broken:
			continue
		var d := global_position.distance_to(w.global_position)
		if d < best_d:
			best_d = d
			best = w
	return best


func _nearest_pallet_in_state(st: int) -> Pallet:
	var best: Pallet = null
	var best_d := GameConfig.TILE * 1.9
	for n in get_tree().get_nodes_in_group("interactable"):
		var p := n as Pallet
		if p == null or p.state != st:
			continue
		var d := global_position.distance_to(p.global_position)
		if d < best_d:
			best_d = d
			best = p
	return best


func request_attack() -> void:
	if machine.current_name in ["attack", "stun", "hooking", "break_pallet", "vault", "carry"]:
		return
	if attack_cooldown > 0.0 or blinding_time > 0.0:
		return
	# A carry swing is a lunge that drops the victim instead.
	machine.change("attack")


func lunge_request() -> bool:
	return false


func perform_attack(is_lunge := false) -> void:
	_attack_hit_done = false
	var cfg: Dictionary = GameConfig.killers.get(char_id, {})
	var atk: Dictionary = cfg.get("attack", {})
	var range_px := float(atk.get("range", GameConfig.K_ATTACK_RANGE)) * GameConfig.TILE
	var arc := deg_to_rad(float(atk.get("arc_deg", GameConfig.K_ATTACK_ARC_DEG)))
	if is_lunge:
		range_px *= 1.5

	var hits: Array = []
	for s in get_tree().get_nodes_in_group("survivor"):
		var sv := s as Survivor
		if sv == null or not is_instance_valid(sv):
			continue
		if sv.health in [Enums.Health.ESCAPED, Enums.Health.DEAD, Enums.Health.HOOKED]:
			continue
		if sv.is_hidden():
			continue
		var to := sv.global_position - global_position
		if to.length() > range_px:
			continue
		if absf(Utils.angle_delta(facing_rad, to.angle())) > arc * 0.5:
			continue
		if blocked_by_wall(global_position, sv.global_position):
			continue
		hits.append(sv)

	if hits.is_empty():
		# Whiff: shorter cooldown, and Unrelenting shaves it further.
		var cd := GameConfig.K_ATTACK_COOLDOWN_TIME * 0.75
		if perk_mods.has("miss_recover"):
			cd *= float(perk_mods["miss_recover"])
		attack_cooldown = cd
		SaveData.add_bloodpoints("sacrifice", 0)
		return

	hits.sort_custom(func(a, b):
		return global_position.distance_to(a.global_position) < global_position.distance_to(b.global_position))
	var victim: Survivor = hits[0]
	SaveData.add_bloodpoints("sacrifice", GameConfig.BP_HIT if victim.health == Enums.Health.HEALTHY else GameConfig.BP_DOWN)
	EventBus.killer_hit_survivor.emit(0, victim.survivor_id, victim.health == Enums.Health.HEALTHY)
	var was_healthy := victim.health == Enums.Health.HEALTHY
	victim.take_hit(self, is_lunge)
	AudioDirector.play_at("hit", victim.global_position, _camera(), -2.0)
	if GameConfig.screen_shake and not is_ai:
		EventBus.camera_shake.emit(2.6 if was_healthy else 3.4, 0.3)
	attack_cooldown = GameConfig.K_ATTACK_COOLDOWN_TIME
	_bloodlust_decay = 0.0
	chase_accum = 0.0
	_set_bloodlust(0)


func on_hit_landed(_victim: Node) -> void:
	pass


func apply_stun(seconds: float) -> void:
	var s := seconds
	if perk_mods.has("stun_resist"):
		s *= (1.0 - float(perk_mods["stun_resist"]))
	if is_carrying and carried != null:
		drop_carried()
	stun_time = maxf(stun_time, s)
	if machine.has_state("stun"):
		machine.force("stun")


func apply_blind(seconds: float) -> void:
	blinding_time = maxf(blinding_time, seconds)
	if sprite != null:
		sprite.modulate = Color(2.0, 2.0, 2.0)
	var tw := create_tween()
	tw.tween_property(sprite, "modulate", Color.WHITE, seconds)
	AudioDirector.play_at("hit", global_position, _camera(), -10.0)


# ---------------------------------------------------------------------------
# Carry / hook
# ---------------------------------------------------------------------------
func try_pickup() -> bool:
	if is_carrying:
		return false
	var target := _find_pickup_target()
	if target == null:
		return false
	start_carry(target)
	return true


func _find_pickup_target() -> Survivor:
	var best: Survivor = null
	var best_d := 1e9
	for s in get_tree().get_nodes_in_group("survivor"):
		var sv := s as Survivor
		if sv == null or not is_instance_valid(sv):
			continue
		if sv.health != Enums.Health.DOWNED and sv.health != Enums.Health.DYING:
			continue
		var d := global_position.distance_to(sv.global_position)
		if d < GameConfig.TILE * 1.8 and d < best_d:
			best_d = d
			best = sv
	return best


## Public probe used by the HUD to decide whether to show the pickup prompt.
func find_pickup_probe() -> Survivor:
	if is_carrying:
		return null
	return _find_pickup_target()


func start_carry(sv: Survivor) -> void:
	if carried != null:
		return
	carried = sv
	is_carrying = true
	sv.begin_carried(self)
	carrying_changed.emit(sv)
	audio_pickup()
	if machine.has_state("carry"):
		machine.force("carry")


func audio_pickup() -> void:
	AudioDirector.play_at("locker_enter", global_position, _camera(), -12.0)


func drop_carried() -> void:
	if carried == null:
		return
	var sv := carried
	carried = null
	is_carrying = false
	sv.drop_from_carrier(false)
	carrying_changed.emit(null)
	if machine.has_state("move"):
		machine.force("move")


func on_carry_ended(_sv: Survivor) -> void:
	carried = null
	is_carrying = false


func nearest_free_hook() -> Hook:
	var best: Hook = null
	var best_score := -1e9
	for n in get_tree().get_nodes_in_group("interactable"):
		var h := n as Hook
		if h == null or not h.is_free():
			continue
		var d := global_position.distance_to(h.global_position)
		if d > GameConfig.TILE * 48.0:
			continue
		# Prefer unused hooks so every hook on the map gets spent first, and
		# keep the score strictly distance-dominated so we always walk to the
		# closest usable hook instead of wandering.
		var score := -d + (3.0 * GameConfig.TILE if not h.used else 0.0)
		if score > best_score:
			best_score = score
			best = h
	return best


func hook_carried() -> bool:
	if carried == null:
		return false
	var h := nearest_free_hook()
	if h == null:
		return false
	current_hook_target = h
	if machine.has_state("hooking"):
		machine.force("hooking")
	return true


func on_hook_complete(_sv: Survivor, _h: Hook) -> void:
	carried = null
	is_carrying = false
	current_hook_target = null
	carrying_changed.emit(null)


# ---------------------------------------------------------------------------
# Power: bear traps
# ---------------------------------------------------------------------------
func request_power() -> void:
	if machine.current_name in ["attack", "stun", "carry", "hooking", "vault"]:
		return
	var existing := _nearest_own_trap()
	if existing != null and existing.can_be_picked_up_by(self):
		machine.change("place_trap", {"mode": "pickup", "trap": existing})
		return
	if trap_stock <= 0:
		EventBus.toast.emit(Locale.t("power.bear_trap") + " — 0", Color(0.8, 0.5, 0.35))
		return
	machine.change("place_trap", {"mode": "place"})


func _nearest_own_trap() -> BearTrap:
	var best: BearTrap = null
	var best_d := GameConfig.TILE * 2.2
	for t in placed_traps:
		if not is_instance_valid(t):
			continue
		var bt := t as BearTrap
		if bt == null or bt.snapped:
			continue
		var d := global_position.distance_to(bt.global_position)
		if d < best_d:
			best_d = d
			best = bt
	return best


func place_trap() -> BearTrap:
	var max_traps := int(GameConfig.killers.get(char_id, {}).get("power", {}).get("max_traps", GameConfig.TRAP_MAX))
	if placed_traps.size() >= max_traps:
		# Recycle the oldest one.
		var oldest: BearTrap = placed_traps.pop_front()
		if is_instance_valid(oldest) and not oldest.snapped:
			oldest.queue_free()
	var bt := BearTrap.new()
	bt.owner_killer = self
	bt.armed = true
	bt.stealth = perk_mods.has("stealth")
	var parent := get_parent()
	if parent != null:
		parent.add_child(bt)
		bt.global_position = global_position + Vector2(0, 6)
	placed_traps.append(bt)
	trap_stock -= 1
	AudioDirector.play_at("trap_place", global_position, _camera(), -4.0)
	power_state_changed.emit({"trap_stock": trap_stock})
	return bt


func pickup_trap(bt: BearTrap) -> void:
	if bt == null or not is_instance_valid(bt):
		return
	placed_traps.erase(bt)
	bt.queue_free()
	trap_stock += 1
	AudioDirector.play_at("trap_place", global_position, _camera(), -8.0)
	power_state_changed.emit({"trap_stock": trap_stock})


func _update_power(_delta: float) -> void:
	# Traps trigger when an unsnared survivor walks over them.
	for t in placed_traps.duplicate():
		if not is_instance_valid(t):
			placed_traps.erase(t)
			continue
		var bt := t as BearTrap
		if bt == null or bt.snapped:
			continue
		for s in get_tree().get_nodes_in_group("survivor"):
			var sv := s as Survivor
			if sv == null or not is_instance_valid(sv):
				continue
			if sv.health in [Enums.Health.ESCAPED, Enums.Health.DEAD, Enums.Health.HOOKED]:
				continue
			if sv.snared:
				continue
			if sv.global_position.distance_to(bt.global_position) < GameConfig.TRAP_RADIUS + 4.0:
				bt.snap_on(sv, self)
				sv.trap = bt
				sv.snared = true
				if sv.machine.has_state("trapped"):
					sv.machine.force("trapped")
				EventBus.toast.emit(Locale.t("fb.trapped"),
						Color(0.9, 0.4, 0.35) if not sv.is_ai else Color(0.6, 0.6, 0.6))


# ---------------------------------------------------------------------------
# Pallet / vault helpers
# ---------------------------------------------------------------------------
func nearest_breakable_pallet() -> Pallet:
	var best: Pallet = null
	var best_d := GameConfig.TILE * 1.6
	for n in get_tree().get_nodes_in_group("interactable"):
		var p := n as Pallet
		if p == null or p.state != Pallet.State.DROPPED:
			continue
		var d := global_position.distance_to(p.global_position)
		if d < best_d:
			best_d = d
			best = p
	return best


func pallet_break_time() -> float:
	var t := GameConfig.K_PALLET_BREAK_TIME
	if perk_mods.has("pallet_break_mult"):
		t /= float(perk_mods["pallet_break_mult"])
	return t


func _camera() -> Camera2D:
	var vp := get_viewport()
	return vp.get_camera_2d() if vp != null else null


# ---------------------------------------------------------------------------
# AI hooks (implemented in killer_brain.gd, kept as virtuals here)
# ---------------------------------------------------------------------------
func _ai_think(delta: float) -> void:
	if brain == null:
		brain = KillerBrain.new(self)
	brain.think(delta)


var brain: KillerBrain = null


func on_state_changed(_from: String, to: String) -> void:
	if to == "stun":
		play_anim("stun", true)


func _exit_tree() -> void:
	if brain != null:
		brain.dispose()
		brain = null


# ---------------------------------------------------------------------------
# States
# ---------------------------------------------------------------------------
class MoveState:
	extends StateMachine.State

	func enter(_msg: Dictionary = {}) -> void:
		var k := actor as Killer
		if k.sprite != null:
			k.sprite.modulate = Color.WHITE

	func physics(delta: float) -> void:
		var k := actor as Killer
		if k.blinding_time > 0.0:
			k.move_input = Vector2.ZERO
		k.apply_movement(delta)

	func update(_delta: float) -> void:
		var k := actor as Killer
		if k.is_ai:
			return
		if k.try_pickup():
			machine.change("carry")


class AttackState:
	extends StateMachine.State

	var _phase := 0
	var _timer := 0.0
	var _windup := 0.35
	var _hit_delay := 0.15

	func enter(_msg: Dictionary = {}) -> void:
		var k := actor as Killer
		var cfg: Dictionary = GameConfig.killers.get(k.char_id, {})
		var atk: Dictionary = cfg.get("attack", {})
		_windup = float(atk.get("windup", GameConfig.K_ATTACK_WINDUP))
		_hit_delay = float(atk.get("weapon_hit_delay", 0.15))
		_phase = 0
		_timer = 0.0
		k.move_input = Vector2.ZERO
		k.play_anim("attack_%s" % Utils.facing_suffix(k.facing), true)
		EventBus.killer_attack.emit(true)
		AudioDirector.play_at("chase_start", k.global_position, k._camera(), -18.0)

	func physics(delta: float) -> void:
		var k := actor as Killer
		# A lunge carries the killer forward during the swing.
		if _phase == 1 and k.wish_dir.length() > 0.1:
			k.velocity = k.wish_dir * GameConfig.m(GameConfig.K_LUNGE) * 0.7
			k.move_and_slide()
			k._post_move(delta)
		else:
			k.move_input = Vector2.ZERO
			k.apply_movement(delta)

	func update(delta: float) -> void:
		var k := actor as Killer
		_timer += delta
		match _phase:
			0:
				if _timer >= _windup:
					_phase = 1
					_timer = 0.0
					k.perform_attack(false)
			1:
				if _timer >= _hit_delay:
					_phase = 2
					_timer = 0.0
			2:
				if _timer >= 0.55:
					machine.change("move")


class CarryState:
	extends StateMachine.State

	func enter(_msg: Dictionary = {}) -> void:
		var k := actor as Killer
		k.is_carrying = true
		k.speed_scale = 1.0

	func physics(delta: float) -> void:
		var k := actor as Killer
		if k.carried == null or not is_instance_valid(k.carried):
			machine.change("move")
			return
		k.apply_movement(delta)
		k.carried.global_position = k.global_position + Vector2(0, -8)

	func update(_delta: float) -> void:
		var k := actor as Killer
		if k.is_ai:
			return
		# Drop with the power key, hook with the action key.
		if Input.is_action_just_pressed("use_power"):
			k.drop_carried()
		elif Input.is_action_just_pressed("interact"):
			k.hook_carried()


class HookingState:
	extends StateMachine.State

	var _timer := 0.0
	var _done := false

	func enter(_msg: Dictionary = {}) -> void:
		var k := actor as Killer
		_timer = 0.0
		_done = false
		k.move_input = Vector2.ZERO
		k.play_anim("hooking_down", true)
		AudioDirector.play_at("hook", k.global_position, k._camera(), -6.0)

	func physics(delta: float) -> void:
		var k := actor as Killer
		k.move_input = Vector2.ZERO
		k.apply_movement(delta)
		if k.carried != null and is_instance_valid(k.carried) \
				and k.current_hook_target != null and is_instance_valid(k.current_hook_target):
			k.carried.global_position = k.current_hook_target.global_position + Vector2(0, -10)

	func update(delta: float) -> void:
		var k := actor as Killer
		_timer += delta
		if _timer < 1.1 or _done:
			if _timer > 2.4:
				machine.change("move")
			return
		_done = true
		if k.carried != null and is_instance_valid(k.carried) \
				and k.current_hook_target != null and is_instance_valid(k.current_hook_target):
			var victim := k.carried
			var hook := k.current_hook_target
			k.on_hook_complete(victim, hook)
			victim.hook_on(hook, k)
		machine.change("move")


class BreakPalletState:
	extends StateMachine.State

	var _target: Pallet = null
	var _timer := 0.0
	var _total := 2.6

	func enter(msg: Dictionary = {}) -> void:
		var k := actor as Killer
		_target = msg.get("target", k.nearest_breakable_pallet())
		_total = k.pallet_break_time()
		_timer = 0.0
		k.move_input = Vector2.ZERO
		k.velocity = Vector2.ZERO
		if _target != null:
			k.face_towards(_target.global_position)
		k.play_anim("attack_%s" % Utils.facing_suffix(k.facing), true)

	func physics(delta: float) -> void:
		var k := actor as Killer
		k.move_input = Vector2.ZERO
		k.apply_movement(delta)

	func update(delta: float) -> void:
		var k := actor as Killer
		if _target == null or not is_instance_valid(_target):
			machine.change("move")
			return
		_timer += delta
		if fmod(_timer, 0.5) < delta:
			AudioDirector.play_at("pallet_drop", _target.global_position, k._camera(), -12.0)
		if _timer >= _total:
			_target.on_broken_by_killer(k)
			SaveData.add_bloodpoints("sacrifice", 200)
			machine.change("move")


class VaultState:
	extends StateMachine.State

	var _timer := 0.0
	var _total := 1.5
	var _start := Vector2.ZERO
	var _end := Vector2.ZERO

	var _target: Node = null

	func enter(msg: Dictionary = {}) -> void:
		var k := actor as Killer
		_target = msg.get("target", null)
		_total = maxf(0.1, float(msg.get("time", 1.5)))
		_start = k.global_position
		if _target is WindowVault:
			_end = (_target as WindowVault).landing_point(_start)
		elif _target is Pallet:
			_end = (_target as Pallet).landing_point(_start)
		else:
			_end = _start
		_timer = 0.0
		k.move_input = Vector2.ZERO
		k.velocity = Vector2.ZERO
		if _end.distance_to(_start) > 1.0:
			k.set_facing_from(_end - _start)
		k.play_anim("vault_%s" % Utils.facing_suffix(k.facing), true)

	func physics(_delta: float) -> void:
		pass

	func update(delta: float) -> void:
		var k := actor as Killer
		_timer += delta
		var t := clampf(_timer / _total, 0.0, 1.0)
		k.global_position = _start.lerp(_end, ease(t, 0.4))
		if t >= 1.0:
			if _target != null and is_instance_valid(_target) and _target.has_method("on_interact_start"):
				_target.on_interact_start(k)
			machine.change("move")


class PlaceTrapState:
	extends StateMachine.State

	var _timer := 0.0
	var _mode := "place"
	var _trap: BearTrap = null

	func enter(msg: Dictionary = {}) -> void:
		var k := actor as Killer
		_mode = str(msg.get("mode", "place"))
		_trap = msg.get("trap", null)
		_timer = 0.0
		k.move_input = Vector2.ZERO
		k.velocity = Vector2.ZERO
		k.play_anim("place_down", true)

	func physics(delta: float) -> void:
		var k := actor as Killer
		k.move_input = Vector2.ZERO
		k.apply_movement(delta)

	func update(delta: float) -> void:
		var k := actor as Killer
		_timer += delta
		var total := GameConfig.TRAP_PLACE_TIME if _mode == "place" else GameConfig.TRAP_PICKUP_TIME
		if k.perk_mods.has("place_speed"):
			total /= (1.0 + float(k.perk_mods["place_speed"]))
		if _timer >= total:
			if _mode == "place":
				k.place_trap()
			else:
				k.pickup_trap(_trap)
			# Trapper cannot vault large windows while holding a trap; nothing
			# to model here, just return to the chase.
			machine.change("move")


class StunState:
	extends StateMachine.State

	var _was_carrying := false

	func enter(_msg: Dictionary = {}) -> void:
		var k := actor as Killer
		_was_carrying = k.is_carrying
		k.move_input = Vector2.ZERO
		k.velocity = Vector2.ZERO
		k.play_anim("stun", true)
		if k.sprite != null:
			k.sprite.modulate = Color(1.4, 1.0, 1.0)

	func exit() -> void:
		var k := actor as Killer
		if k.sprite != null:
			k.sprite.modulate = Color.WHITE

	func physics(delta: float) -> void:
		var k := actor as Killer
		# Routed through apply_movement so CharacterBase._post_move runs and
		# actually ticks stun_time down; current_speed() is 0 while stunned so
		# the killer stays put.
		k.move_input = Vector2.ZERO
		k.apply_movement(delta)

	func update(_delta: float) -> void:
		var k := actor as Killer
		if k.stun_time <= 0.0:
			machine.change("carry" if k.is_carrying else "move")
