class_name SurvivorBrain
extends RefCounted
## Bot survivor decision making.
##
## Priorities, highest first:
##   1. flee the killer when he is near or has line of sight
##   2. rescue a hooked teammate when healthy
##   3. heal when injured (self-care / medkit)
##   4. repair the nearest unfinished generator
##
## Movement uses the match's shared AStarGrid2D, so bots path around walls
## instead of grinding into them.

var s: Survivor
var path: Array = []
var path_index := 0
var repath_timer := 0.0
var goal := Vector2.ZERO
var goal_kind := "idle"
var target_generator: Generator = null
var flee_timer := 0.0
var reaction_timer := 0.0
var _wander := Vector2.ZERO

const REPATH_INTERVAL := 0.9
const ARRIVE_DIST := 12.0


var _anchor_pos := Vector2.ZERO
var _anchor_time := 0.0
var _unstick_count := 0

## The loop we have committed to, and for how much longer we are running it.
## Committing is what makes orbiting work at all: re-picking the nearest spot every
## frame made the bot oscillate between two of them, which from the outside is
## indistinguishable from standing still.
var _loop_spot := Vector2.ZERO
var _loop_timer := 0.0
## Which way the bot runs around a loop obstacle. Picked once and then kept, so it
## commits to a direction instead of jittering between the two.
var _orbit_sign := 1.0
## Debug counters.
static var rotations := 0


func _init(survivor: Survivor) -> void:
	s = survivor


func dispose() -> void:
	s = null
	path.clear()
	target_generator = null


func think(delta: float) -> void:
	if MatchController.instance == null:
		return
	repath_timer -= delta
	reaction_timer -= delta
	_loop_timer = maxf(0.0, _loop_timer - delta)
	_update_stuck(delta)

	match s.health:
		Enums.Health.DOWNED, Enums.Health.DYING:
			_do_down_state(delta)
			return
		Enums.Health.HOOKED, Enums.Health.DEAD, Enums.Health.ESCAPED:
			s.move_input = Vector2.ZERO
			return

	# The danger check has to run even while we are mid-interaction. This is the
	# second half of the "bot never lets go of the generator" bug: the first fix
	# made _set_goal() release the interaction, but think() bailed out before the
	# danger check whenever the machine was inside `interact` -- so the release
	# code was unreachable exactly when it mattered. A killer walking up on a
	# repairing bot must interrupt the repair.
	var info := _killer_danger()
	if info["danger"]:
		_set_goal("flee")
		flee_timer = 4.0
		_maybe_drop_pallet(info["dist"])
		_choose_flee_point()
		_follow_path(delta)
		return

	if s.machine.current_name != "move":
		return

	_decide(delta)
	_follow_path(delta)


## Killer proximity / line-of-sight evaluation, shared by the interrupt path
## above and the normal decision pass.
func _killer_danger() -> Dictionary:
	var killer := _killer()
	var killer_dist := 1e9
	if killer != null:
		killer_dist = s.global_position.distance_to(killer.global_position)

	var danger := false
	var stealth := false
	# A cloaked Wraith is invisible beyond 20 m and only a faint shimmer within.
	# Ignore him completely until he is close enough to actually be perceived --
	# this is what makes his approach unseen.
	if killer != null and killer.has_method("is_cloaked") and killer.is_cloaked() \
			and killer.char_id == "wraith":
		stealth = true
		danger = killer_dist < GameConfig.WRAITH_CLOAK_VIS_RANGE * GameConfig.TILE
	else:
		danger = killer_dist < GameConfig.TILE * 9.0
		if killer != null and killer.has_method("is_looking_at") and killer.is_looking_at(s):
			danger = true
		if killer_dist < GameConfig.TILE * 6.0:
			danger = true

	# The red stain means "he is looking exactly here". Standing in it is how you
	# get hit, so it is a danger signal even when he is far away -- and unlike
	# plain proximity it tells us which way to break out. A cloaked Wraith casts
	# no stain, so this branch is skipped while he is stealthed.
	_stain_evade = false
	if not stealth and killer != null:
		var in_stain: bool = killer.has_method("is_in_red_stain") \
				and killer.is_in_red_stain(s.global_position)
		# Being *looked at* from further out carries the same information as the
		# stain -- he is committed in this direction -- so it earns the same
		# sideways escape.
		var watched: bool = killer.has_method("is_looking_at") \
				and killer.is_looking_at(s) and killer_dist < GameConfig.TILE * 10.0
		if in_stain or watched:
			_stain_evade = true
			danger = true
	return {"danger": danger, "dist": killer_dist}


# ---------------------------------------------------------------------------
# Decisions
# ---------------------------------------------------------------------------
## Switching goals has to be *acted on*, not just decided.
##
## This is the "bots never let go of the generator" bug: the decision layer set
## goal_kind to flee while the state machine was still sitting in `interact`, and
## InteractState ignores move_input entirely. So a bot cheerfully kept repairing
## with the killer standing on top of it. Anything that changes what the bot is
## doing has to leave the interaction first.
func _set_goal(kind: String) -> void:
	if goal_kind == kind:
		return
	_release_interaction()
	goal_kind = kind


func _release_interaction() -> void:
	if s == null or s.machine == null:
		return
	# Only `interact` needs interrupting: `vault` is finite and self-terminating.
	if s.machine.current_name == "interact":
		s.end_interaction()
		if s.machine.has_state("move"):
			s.machine.change("move")


func _decide(delta: float) -> void:
	# Danger is handled in think() before this runs, so this pass only ever sees
	# a calm killer. `killer_dist` is still needed here: healing next to where he
	# was last seen is how bots die.
	var killer := _killer()
	var killer_dist := 1e9
	if killer != null:
		killer_dist = s.global_position.distance_to(killer.global_position)

	if flee_timer > 0.0:
		flee_timer -= delta
		if goal_kind == "flee":
			return

	# Rescue: hooked teammates first, then downed ones.
	if s.health == Enums.Health.HEALTHY:
		var hooked := _find_hooked_teammate()
		if hooked != null:
			_set_goal("rescue")
			goal = hooked.global_position
			if s.global_position.distance_to(goal) < GameConfig.TILE * 1.4:
				s.interact_target = hooked.current_hook
				if s.interact_target != null and s.interact_target.can_interact(s):
					s.machine.change("interact", {"target": s.interact_target})
			return
		var downed := _find_downed_teammate()
		if downed != null:
			_set_goal("revive")
			goal = downed.global_position
			if s.global_position.distance_to(goal) < GameConfig.TILE * 1.3:
				s.move_input = Vector2.ZERO
				_revive_progress += delta
				EventBus.survivor_interact_progress.emit(s.survivor_id,
						Enums.InteractionKind.REVIVE,
						clampf(_revive_progress / GameConfig.REVIVE_TIME, 0.0, 1.0))
				if _revive_progress >= GameConfig.REVIVE_TIME:
					_revive_progress = 0.0
					downed.revive()
					SaveData.add_bloodpoints("altruism", GameConfig.BP_HEAL_OTHER)
			else:
				_revive_progress = 0.0
			return

	# Self heal when hurt and the killer is not around.
	if s.health == Enums.Health.INJURED and killer_dist > GameConfig.TERROR_RADIUS * 0.9:
		var can_heal := s.item_kind == "medkit" and s.item_charges > 0.0
		if can_heal or int(s.perk_mods.get("allow_self_heal", 0)) == 1:
			var gen := _nearest_generator(s.global_position)
			if gen != null:
				_set_goal("heal")
				goal = gen.global_position + Vector2(GameConfig.TILE * 1.6, GameConfig.TILE * 1.6)
				if s.global_position.distance_to(gen.global_position) < GameConfig.TILE * 2.0:
					s.interact_target = _make_heal_stub()
					_start_self_heal()
				return

	# Default: repair.
	var gen2 := _nearest_generator(s.global_position)
	if gen2 != null:
		_set_goal("repair")
		target_generator = gen2
		goal = gen2.global_position
		if s.global_position.distance_to(gen2.global_position) < GameConfig.TILE * 1.5:
			s.interact_target = gen2
			if gen2.can_interact(s):
				s.machine.change("interact", {"target": gen2})
		return

	_set_goal("idle")
	goal = s.global_position


func _start_self_heal() -> void:
	# Self-heal uses the same interaction pipeline but without a world object,
	# so we drive the progress directly.
	var needed := GameConfig.HEAL_SELF_TIME
	if s.item_kind == "medkit":
		needed /= 1.5
	needed /= float(s.perk_mods.get("heal_speed", 1.0))
	s.interact_progress += get_process_delta() / needed
	if s.item_kind == "medkit":
		s.item_charges = maxf(0.0, s.item_charges - get_process_delta() * 1.2)
	EventBus.survivor_interact_progress.emit(s.survivor_id,
			Enums.InteractionKind.HEAL_SELF, clampf(s.interact_progress, 0.0, 1.0))
	if s.interact_progress >= 1.0:
		s.interact_progress = 0.0
		s.heal(1.0)
		AudioDirector.play_at("heal_done", s.global_position, _camera(), -8.0)


var _last_think_time := 0.0


func get_process_delta() -> float:
	var now := Time.get_ticks_msec() / 1000.0
	var d := clampf(now - _last_think_time, 0.0, 0.1)
	_last_think_time = now
	return d


func _make_heal_stub() -> Interactable:
	return null


func _do_down_state(delta: float) -> void:
	var killer := _killer()
	if killer == null:
		s.move_input = Vector2.ZERO
		return
	var away: Vector2 = s.global_position - (killer as Node2D).global_position.normalized()
	s.move_input = away
	s.gait = Enums.Gait.CRAWL


## Slams down an upright pallet when the killer is closing and we are standing in one.
##
## Two conditions, both necessary: he has to be close enough that the board will
## actually buy time, and we have to be *on* the pallet (the drop is instant, it is
## not a "run to the pallet first" action -- that would just feed the killer a free
## hit). Anything further out is a pallet saved for later.
##
## The threshold is 2.6 tiles, not 5. Dropping the moment the killer is vaguely
## nearby is the most expensive mistake available here: a board that does not
## actually separate the two of you has been thrown away, and there is no second
## one at that loop. Holding it while you run the loop first -- 拉扯 -- is what
## forces him to commit before you commit.
func _maybe_drop_pallet(killer_dist: float) -> void:
	if killer_dist > GameConfig.TILE * 2.6:
		return
	var best: Pallet = null
	var best_d := GameConfig.TILE * 1.7
	for n in s.get_tree().get_nodes_in_group("interactable"):
		var p := n as Pallet
		if p == null or not is_instance_valid(p) or p.state != Pallet.State.STANDING:
			continue
		var d := s.global_position.distance_to(p.global_position)
		if d < best_d:
			best_d = d
			best = p
	if best == null:
		return
	best.drop(s)


func _choose_flee_point() -> void:
	var killer := _killer()
	if killer == null:
		goal = _random_point_near(s.global_position, GameConfig.TILE * 10.0)
		return

	# Standing in the red stain: running along the beam keeps us in front of him
	# the whole time. Break perpendicular to it so we leave the cone sideways --
	# that is the move a real survivor makes.
	if _stain_evade:
		var kc := killer as CharacterBase
		if kc != null:
			var perp := Vector2(cos(kc.facing_rad + PI * 0.5),
					sin(kc.facing_rad + PI * 0.5))
			if perp.dot(s.global_position - kc.global_position) < 0.0:
				perp = -perp
			goal = s.global_position + perp * GameConfig.TILE * 12.0
			return
	var away: Vector2 = s.global_position - (killer as Node2D).global_position
	if away.length() < 1.0:
		away = Vector2.RIGHT
	away = away.normalized()

	# Prefer a nearby vault point, and *orbit* it rather than parking on it.
	#
	# This is the whole difference between a chase that lasts twenty seconds and one
	# that lasts two. A survivor cannot outrun the killer -- he is faster -- so the
	# only thing that buys time is making him turn. Running to a pallet and then
	# standing beside it, which is what the bots used to do, achieves nothing at all.
	var killer_pos := (killer as Node2D).global_position

	# 转点: if he has already taken the short side of the loop we are running, the
	# loop is dead and circling it is how you walk into the weapon. Abandon it and
	# rotate to a different one.
	if _loop_timer > 0.0 and _loop_compromised(killer_pos):
		_loop_timer = 0.0
		rotations += 1

	if _loop_timer > 0.0 and _loop_spot != Vector2.ZERO:
		goal = _orbit(_loop_spot, killer_pos)
		return

	var loop_spot := _pick_loop_spot(killer_pos, away)
	if loop_spot != Vector2.ZERO:
		_loop_spot = loop_spot
		# Long enough to actually complete a rotation; short enough that a bad
		# choice does not cost the whole chase.
		_loop_timer = 3.5
		goal = _orbit(loop_spot, killer_pos)
		return
	goal = s.global_position + away * GameConfig.TILE * 12.0


## The loop he has cut: he is on the same side of it as we are, and close enough
## that the next rotation would run us straight into him.
func _loop_compromised(killer_pos: Vector2) -> bool:
	var d := killer_pos.distance_to(_loop_spot)
	if d > GameConfig.TILE * 7.0:
		return false
	var to_us := s.global_position - _loop_spot
	var to_him := killer_pos - _loop_spot
	if to_us.length() < 1.0 or to_him.length() < 1.0:
		return false
	return to_us.normalized().dot(to_him.normalized()) > 0.25


## Picks the next loop to run. Excludes the one we are leaving, so a rotation is an
## actual rotation and not a re-selection of the same tile.
func _pick_loop_spot(killer_pos: Vector2, away: Vector2) -> Vector2:
	var best := Vector2.ZERO
	var best_score := -1e9
	for n in s.get_tree().get_nodes_in_group("interactable"):
		var it := n as Interactable
		if it == null or not is_instance_valid(it):
			continue
		if it is Pallet and (it as Pallet).state == Pallet.State.BROKEN:
			continue
		if not (it is Pallet or it is WindowVault):
			continue
		var pos := it.global_position
		if pos.distance_to(_loop_spot) < GameConfig.TILE * 2.0:
			continue
		var d := s.global_position.distance_to(pos)
		if d > GameConfig.TILE * 18.0:
			continue
		# Must not be towards the killer: running at him to reach a loop is not a
		# rotation, it is a mistake.
		var towards := (pos - s.global_position).normalized()
		if towards.dot(away) < 0.1:
			continue
		# Prefer loops he is far from, and prefer a different *kind* of loop than
		# the one being abandoned so the next rotation cannot be predicted.
		var score := 40.0 - d * 0.08
		score += minf(24.0, killer_pos.distance_to(pos) / GameConfig.TILE)
		if it is WindowVault and _loop_spot != Vector2.ZERO:
			score += 6.0
		if score > best_score:
			best_score = score
			best = pos
	return best


## A point on a circle around a loop spot: on the far side of it from the killer, and
## offset along the tangent so the bot keeps moving around the obstacle instead of
## standing on the spot facing him.
func _orbit(spot: Vector2, killer_pos: Vector2) -> Vector2:
	var radius := GameConfig.TILE * 2.4
	var away_v := spot - killer_pos
	if away_v.length() < 1.0:
		away_v = Vector2.RIGHT
	away_v = away_v.normalized()
	if is_zero_approx(_orbit_sign):
		_orbit_sign = -1.0 if randf() < 0.5 else 1.0
	var tangent := Vector2(-away_v.y, away_v.x)
	return spot + away_v * radius + tangent * (_orbit_sign * radius * 1.3)


func _random_point_near(from: Vector2, radius: float) -> Vector2:
	var a := randf() * TAU
	return from + Vector2(cos(a), sin(a)) * radius


func _killer() -> Node:
	var best: Node = null
	var best_d := 1e9
	for k in s.get_tree().get_nodes_in_group("killer"):
		if not is_instance_valid(k):
			continue
		var d := s.global_position.distance_to(k.global_position)
		if d < best_d:
			best_d = d
			best = k
	return best


var _revive_progress := 0.0
## Set while we are standing in the killer's red stain, so the flee direction
## can be chosen to break out of the cone rather than run along it.
var _stain_evade := false

## Debug counters. Vaulting is invisible in a headless soak test unless it is
## counted, and "cannot vault" was the reported bug.
static var probe_hits := 0
static var vault_attempts := 0


func _find_downed_teammate() -> Survivor:
	var best: Survivor = null
	var best_d := 1e9
	for n in s.get_tree().get_nodes_in_group("survivor"):
		var sv := n as Survivor
		if sv == null or sv == s or not is_instance_valid(sv):
			continue
		if sv.health != Enums.Health.DOWNED and sv.health != Enums.Health.DYING:
			continue
		var d := s.global_position.distance_to(sv.global_position)
		if d < best_d:
			best_d = d
			best = sv
	return best


func _find_hooked_teammate() -> Survivor:
	for n in s.get_tree().get_nodes_in_group("survivor"):
		var sv := n as Survivor
		if sv == null or sv == s or not is_instance_valid(sv):
			continue
		if sv.health == Enums.Health.HOOKED and not sv.is_ai:
			pass
		if sv.health == Enums.Health.HOOKED:
			return sv
	return null


## Picks a generator to work on.
##
## Not simply the nearest one. With five machines to finish and four survivors, two
## bots converging on the same generator wastes one of them entirely -- and the reason
## survivors lose is running out of time. A machine a teammate is already on is heavily
## discounted, and progress already banked is worth a small detour.
func _nearest_generator(from: Vector2) -> Generator:
	var best: Generator = null
	var best_score := -1e9
	for n in s.get_tree().get_nodes_in_group("interactable"):
		var g := n as Generator
		if g == null or g.completed:
			continue
		var d := from.distance_to(g.global_position)
		var score := -d
		if _workers_on(g) > 0:
			score -= GameConfig.TILE * 20.0
		# A machine that is nearly done is the best target: finishing one beats
		# starting another, and it is the one the killer is about to come and defend.
		score += clampf(g.progress, 0.0, 1.0) * GameConfig.TILE * 8.0
		if score > best_score:
			best_score = score
			best = g
	return best


## How many *other* survivors are currently working this generator.
func _workers_on(g: Generator) -> int:
	var count := 0
	for n in s.get_tree().get_nodes_in_group("survivor"):
		var other := n as Survivor
		if other == null or other == s or not is_instance_valid(other):
			continue
		if other.interact_target == g:
			count += 1
	return count


# ---------------------------------------------------------------------------
# Path following
# ---------------------------------------------------------------------------
## Net-displacement watchdog: a bot jittering between two path cells moves a
## fraction of a pixel every frame but never actually goes anywhere, so we
## measure how far it has drifted over a 1.5 s window instead.
func _update_stuck(delta: float) -> void:
	if s.machine.current_name != "move":
		_anchor_time = 0.0
		return
	_anchor_time += delta
	if _anchor_time < 1.5:
		return
	var net := s.global_position.distance_to(_anchor_pos)
	_anchor_pos = s.global_position
	_anchor_time = 0.0
	if net > 12.0:
		_unstick_count = 0
		return
	path.clear()
	path_index = 0
	repath_timer = 0.0
	var heading := goal - s.global_position
	if heading.length() < 1.0:
		heading = Vector2.RIGHT
	var perp := Vector2(-heading.y, heading.x).normalized()
	if randf() < 0.5:
		perp = -perp
	goal = s.global_position + perp * GameConfig.TILE * 5.0
	_unstick_count += 1
	if _unstick_count >= 3:
		_unstick_count = 0
		var mc := MatchController.instance
		if mc != null:
			var here := Utils.tile_of(s.global_position)
			for d in [Vector2i(2, 0), Vector2i(-2, 0), Vector2i(0, 2), Vector2i(0, -2),
					Vector2i(3, 3), Vector2i(-3, 3)]:
				var cell := mc.nearest_open_cell(here + d)
				if cell.x >= 0 and cell != here:
					s.global_position = Utils.tile_center(cell)
					break
				s.velocity = Vector2.ZERO
				path.clear()
				_anchor_pos = s.global_position


func _follow_path(delta: float) -> void:
	var mc := MatchController.instance
	if mc == null:
		s.move_input = Vector2.ZERO
		return

	if repath_timer <= 0.0 or path.is_empty():
		repath_timer = REPATH_INTERVAL
		path = mc.find_path(s.global_position, goal)
		path_index = 0

	if path.is_empty():
		# No path: fall back to steering straight at the goal.
		var aim := (goal - s.global_position).normalized()
		if s.machine.current_name == "move" and _try_vault_ahead(aim):
			return
		s.move_input = aim
		return

	while path_index < path.size() and \
			s.global_position.distance_to(path[path_index]) < GameConfig.TILE * 0.55:
		path_index += 1

	if path_index >= path.size():
		s.move_input = Vector2.ZERO
		# Small idle jitter so bots do not stand perfectly still.
		if goal_kind == "idle" and randf() < 0.01:
			s.move_input = Vector2(randf_range(-1, 1), randf_range(-1, 1)).normalized()
		return

	var next: Vector2 = path[path_index]
	var dir := (next - s.global_position).normalized()

	# If the next step is straight into a vaultable obstacle, vault it.
	if s.machine.current_name == "move" and _try_vault_ahead(dir):
		return
	# A little separation so a pack of bots does not stack.
	var sep := Vector2.ZERO
	for n in s.get_tree().get_nodes_in_group("survivor"):
		var other := n as Survivor
		if other == null or other == s or not is_instance_valid(other):
			continue
		var d := s.global_position.distance_to(other.global_position)
		if d < 10.0 and d > 0.1:
			sep += (s.global_position - other.global_position) / d
	s.move_input = (dir + sep * 0.6).normalized()

	# Gait: run by default; drop to a walk only when we are deliberately trying
	# to stay quiet near the killer. The old code rolled for a random CROUCH every
	# repath (0.9 s), which made bots squat and stand for no reason -- crouch is now
	# a real stealth choice the bot makes, not a dice roll.
	var k := _killer()
	var quiet := k != null and s.global_position.distance_to(k.global_position) < GameConfig.TILE * 18.0
	if goal_kind == "flee" or not quiet:
		s.gait = Enums.Gait.RUN
	else:
		s.gait = Enums.Gait.WALK


## Vaults a window or dropped pallet that is directly between the survivor and
## where they are heading.
##
## The first version probed a point 1.1 tiles ahead and asked whether an obstacle
## happened to sit near it. That almost never fired for two reasons: the path
## already steers around the window, so the probe never lands on it, and the
## "is it closer to the goal" test rejected anything that would first take us
## sideways. Measuring the real distance to the obstacle and requiring only that
## it lies in the direction of travel fixes both.
func _try_vault_ahead(dir: Vector2) -> bool:
	if dir.length() < 0.05:
		return false
	for n in s.get_tree().get_nodes_in_group("interactable"):
		var it := n as Interactable
		if it == null or not is_instance_valid(it):
			continue

		var end := Vector2.ZERO
		var dur := 0.0
		if it is WindowVault:
			end = (it as WindowVault).landing_point(s.global_position)
			dur = (it as WindowVault).vault_time(s)
		elif it is Pallet and (it as Pallet).state == Pallet.State.DROPPED:
			end = (it as Pallet).landing_point(s.global_position)
			dur = (it as Pallet).vault_time(s)
		else:
			continue

		var to_obstacle := it.global_position - s.global_position
		var dist := to_obstacle.length()
		if dist > GameConfig.TILE * 1.7 or dist < 1.0:
			continue
		# It must lie roughly where we are already going.
		if to_obstacle.normalized().dot(dir) < 0.25:
			continue
		# And it must actually gain us ground -- unless we are fleeing, in which
		# case anything between us and the killer is worth taking.
		if goal_kind != "flee" and end.distance_to(goal) > \
				s.global_position.distance_to(goal) + GameConfig.TILE:
			continue

		probe_hits += 1
		vault_attempts += 1
		s._begin_vault(it, end, dur)
		return true
	return false


func _camera() -> Camera2D:
	var vp := s.get_viewport()
	return vp.get_camera_2d() if vp != null else null
