class_name KillerBrain
extends RefCounted
## Bot killer decision making.
##
##   PATROL  walk between objectives on the map
##   CHASE   a survivor is visible (or was seen very recently) -> close in
##   SEARCH  lost the target, sweep the last known area
##   CARRY   walking a downed survivor to the nearest free hook
##
## Uses the match AStarGrid2D for movement so the killer never grinds into a
## wall the way naive steering would.

## Priority order, highest first:
##   CHASE   a survivor is in actual line of sight -- nothing beats this
##   SCRATCH fresh scratch marks within 16 m: someone went this way *just now*
##   SEARCH  sweep the last known position after losing the trail
##   PATROL  walk the objectives when the map has gone quiet
enum Mode { PATROL, CHASE, SEARCH, CARRY, SCRATCH }

var k: Killer
var mode: int = Mode.PATROL
var path: Array = []
var path_index := 0
var repath_timer := 0.0
var goal := Vector2.ZERO
var patrol_point := Vector2.ZERO
var patrol_timer := 0.0
var last_seen := Vector2.ZERO
var search_timer := 0.0
var target: Survivor = null

# Stuck watchdog: if the killer barely moves for a second he is grinding against
# geometry (a corner, a dropped pallet, a wall), so the path is thrown away and
# a fresh goal is picked instead of standing there forever.
var _anchor_pos := Vector2.ZERO
var _anchor_time := 0.0
var _patrol_hold := 0.0
var _unstick_count := 0

## Debug counter: how often the killer switched to following scratch marks.
static var scratch_follows := 0
## Debug counter: generators the bot has damaged.
static var gens_kicked := 0
## Seconds until the Wraith may ring the bell again (see the bell block in think()).
var _bell_wait := 0.0

## Debug counter: how often the killer cut across a loop instead of tracing it.
static var loop_cuts := 0
## Debug counters for the Wraith bell. `bell_rings` counts every channel started and
## `bell_cloaks` how many of those were re-cloaks, so a soak can prove the bot is no
## longer spamming the bell.
static var bell_rings := 0
static var bell_cloaks := 0
static var last_mode := 0

## Minimum seconds between two bell decisions. Long enough that cloaking and
## uncloaking can never trade places back and forth across a chase.
const BELL_COOLDOWN := 9.0
const REPATH_INTERVAL := 0.7
## Swing trigger distance. Sits just inside the attack's own reach (2.9 m) so the
## windup cannot be walked out of before the hit frame.
const ATTACK_RANGE := 2.6 * 16.0


func _init(killer: Killer) -> void:
	k = killer


## Breaks the brain <-> actor reference cycle so the match scene tears down
## cleanly instead of leaking ObjectDB instances.
func dispose() -> void:
	k = null
	path.clear()
	target = null


## True when any living survivor is within `radius` px. The bell logic uses it so
## the Wraith never re-cloaks right in front of somebody.
func _any_survivor_within(radius: float) -> bool:
	var mc := MatchController.instance
	if mc == null:
		return false
	for s in mc.survivors:
		var sv := s as Survivor
		if sv == null or not is_instance_valid(sv):
			continue
		if sv.health == Enums.Health.DEAD or sv.health == Enums.Health.ESCAPED:
			continue
		if k.global_position.distance_to(sv.global_position) <= radius:
			return true
	return false


func think(delta: float) -> void:
	if MatchController.instance == null:
		return
	repath_timer -= delta
	patrol_timer -= delta
	search_timer -= delta
	_update_stuck(delta)

	if k.machine.current_name in ["attack", "stun", "hooking", "vault", "place_trap", "break_pallet", "bell"]:
		k.move_input = Vector2.ZERO
		return

	if k.is_carrying and k.carried != null:
		_mode_carry(delta)
		return

	# Priority 1: a survivor we can see always wins.
	var seen := k.nearest_visible_survivor()
	# Priority 2: the freshest trail within 16 m.
	var trail := _scratch_lead(GameConfig.SCRATCH_FOLLOW_RADIUS)

	if seen != null:
		target = seen
		last_seen = seen.global_position
		mode = Mode.CHASE
		search_timer = 6.0
	elif mode == Mode.CHASE:
		# Just lost sight of him -- the trail is the best lead we have.
		if search_timer <= 0.0:
			mode = Mode.PATROL
		else:
			mode = Mode.SCRATCH if trail != Vector2.ZERO else Mode.SEARCH
	elif mode == Mode.SCRATCH:
		if trail == Vector2.ZERO:
			mode = Mode.SEARCH if search_timer > 0.0 else Mode.PATROL
	elif mode == Mode.SEARCH and search_timer <= 0.0:
		mode = Mode.PATROL if trail == Vector2.ZERO else Mode.SCRATCH
	elif mode == Mode.PATROL and trail != Vector2.ZERO:
		mode = Mode.SCRATCH

	if mode != last_mode:
		if mode == Mode.SCRATCH:
			scratch_follows += 1
		last_mode = mode

	# Wraith bell. The old version rang whenever `mode != CHASE`, so every flicker
	# between PATROL and SCRATCH re-cloaked and the bot spent the match ringing
	# instead of playing. Two rules fix that:
	#   * cloak again only when the map is genuinely quiet (PATROL, nobody near);
	#   * uncloak only with a victim at mid range AND line of sight, so the 3 s
	#     channel finishes roughly as the chase closes instead of telegraphing it.
	# A cooldown then guarantees the two rules cannot ping-pong.
	if k.char_id == "wraith":
		if _bell_wait > 0.0:
			_bell_wait -= delta
		if _bell_wait <= 0.0 and not k._bell_active and k.machine.current_name == "move":
			if k.is_cloaked():
				var reach_ok := target != null and is_instance_valid(target) \
						and k.global_position.distance_to(target.global_position) \
								< GameConfig.TILE * 8.0 \
						and not k.blocked_by_wall(k.global_position, target.global_position)
				if mode == Mode.CHASE and reach_ok:
					k.request_power()
					bell_rings += 1
					_bell_wait = BELL_COOLDOWN
			elif mode == Mode.PATROL and seen == null \
					and not _any_survivor_within(GameConfig.TILE * 14.0):
				k.request_power()
				bell_rings += 1
				bell_cloaks += 1
				_bell_wait = BELL_COOLDOWN

	match mode:
		Mode.CHASE:
			_mode_chase(delta)
		Mode.SCRATCH:
			_mode_scratch(delta)
		Mode.SEARCH:
			_mode_search(delta)
		_:
			_mode_patrol(delta)


# ---------------------------------------------------------------------------
func _mode_chase(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		mode = Mode.SEARCH
		return
	var dist := k.global_position.distance_to(target.global_position)

	# Downed survivors get picked up instead of hit again.
	if target.health == Enums.Health.DOWNED and dist < GameConfig.TILE * 1.4:
		if k.try_pickup():
			mode = Mode.CARRY
			return

	# Swing when the target is in reach. A Quick Attack covers ~2.6 m; a Lunge
	# Attack flings the killer forward at 1.5x and reaches ~5+ m, so we use it to
	# catch a survivor who is just out of quick-attack range. We always turn to
	# face the target first -- swinging while looking the wrong way was the main
	# reason the bots whiffed every other chase.
	if k.attack_cooldown <= 0.0 and k.machine.current_name == "move" \
			and not k.blocked_by_wall(k.global_position, target.global_position):
		var to_t := (target.global_position - k.global_position).angle()
		var facing_ok := absf(Utils.angle_delta(k.facing_rad, to_t)) < deg_to_rad(35.0)
		if dist < ATTACK_RANGE:
			if facing_ok:
				k.machine.force("attack", {"lunge": false})
				return
			k.face_towards(target.global_position)
		elif dist < GameConfig.TILE * 5.2:
			if facing_ok:
				k.machine.force("attack", {"lunge": true})
				return
			k.face_towards(target.global_position)

	# Lead the target. Walking to where they *are* loses ground permanently against
	# anyone running in a straight line, because they keep moving while you close --
	# which is why the bots would trail a metre behind for an entire chase and only
	# ever land a hit when the survivor ran into a wall.
	var eta := dist / maxf(1.0, GameConfig.m(GameConfig.K_RUN))
	goal = target.global_position + target.velocity * eta * 0.6

	# Cutting the loop. Tracing a survivor around a window or a pallet is a losing
	# race: he is turning tighter than you and every lap costs you the same distance
	# you just made up. If he is looping something and you are on the same side of
	# that obstacle as he is, walk to where he will *come out* instead.
	if dist < GameConfig.TILE * 12.0:
		var cut := _loop_cut(target.global_position)
		if cut != Vector2.ZERO:
			goal = cut
			loop_cuts += 1

	_follow(delta)

	# Trapper drops a trap on the path when the chase is not going anywhere.
	if k.char_id == "trapper" and k.trap_stock > 0 and dist > GameConfig.TILE * 6.0 \
			and randf() < 0.002:
		if k.machine.has_state("place_trap"):
			k.machine.force("place_trap", {"mode": "place"})


## The mirror of the target through the loop obstacle they are using. Walking to
## that point meets them as they come round, which is shorter than following; if it
## is not shorter (they are on the far side already), returns ZERO and the chase
## carries on normally.
func _loop_cut(target_pos: Vector2) -> Vector2:
	var mc := MatchController.instance
	if mc == null:
		return Vector2.ZERO
	var loop := Vector2.ZERO
	var best_d := GameConfig.TILE * 7.0
	for n in k.get_tree().get_nodes_in_group("interactable"):
		var it := n as Interactable
		if it == null or not is_instance_valid(it):
			continue
		if it is Pallet and (it as Pallet).state == Pallet.State.BROKEN:
			continue
		if not (it is Pallet or it is WindowVault):
			continue
		var d := target_pos.distance_to(it.global_position)
		if d < best_d:
			best_d = d
			loop = it.global_position
	if loop == Vector2.ZERO:
		return Vector2.ZERO

	# Only cut when we are on the same side of the obstacle as the survivor. If he
	# is already on the far side, mirroring would send us backwards.
	var side_target := (target_pos - loop).normalized()
	var side_us := (k.global_position - loop).normalized()
	if side_target.dot(side_us) < 0.25:
		return Vector2.ZERO

	var mirror := loop * 2.0 - target_pos
	# Sanity: the cut has to be reachable and not meaningfully longer than following.
	if mirror.distance_to(k.global_position) > 			target_pos.distance_to(k.global_position) * 1.15:
		return Vector2.ZERO
	# And it has to be walkable, or the pathfinder sends us round the world.
	var cell := mc.nearest_open_cell(Utils.tile_of(mirror))
	if cell.x < 0:
		return Vector2.ZERO
	return Utils.tile_center(cell)


## Walks the freshest scratch trail. Scratch marks only live for ten seconds,
## so anything inside 16 m is genuinely recent -- this is what turns "he ran off
## somewhere" into an actual pursuit.
func _mode_scratch(delta: float) -> void:
	if _try_kick():
		return
	var lead := _scratch_lead(GameConfig.SCRATCH_FOLLOW_RADIUS)
	if lead == Vector2.ZERO:
		mode = Mode.SEARCH
		return
	# Only re-anchor when the lead actually moves, otherwise the target thrashes
	# between neighbouring prints and pathing never settles.
	if goal.distance_to(lead) > GameConfig.TILE:
		goal = lead
		path.clear()
		repath_timer = 0.0
	_follow(delta)


## Returns a point *past* the freshest scratch marks inside `radius`, so the
## killer keeps moving along the trail instead of stopping on the last print.
## Vector2.ZERO means nothing fresh is in range.
func _scratch_lead(radius: float) -> Vector2:
	var marks: Array = []
	var now := Time.get_ticks_msec()
	for n in k.get_tree().get_nodes_in_group("scratch_mark"):
		var n2 := n as Node2D
		if n2 == null or not is_instance_valid(n2):
			continue
		if k.global_position.distance_to(n2.global_position) > radius:
			continue
		marks.append({"pos": n2.global_position, "age": now - int(n2.get_meta("born", 0))})
	if marks.is_empty():
		return Vector2.ZERO

	marks.sort_custom(func(a, b) -> bool: return int(a["age"]) < int(b["age"]))
	var newest: Vector2 = marks[0]["pos"]
	if marks.size() == 1:
		return newest

	# Use an older print to recover the direction of travel, then extrapolate.
	var older: Vector2 = marks[mini(3, marks.size() - 1)]["pos"]
	var dir := newest - older
	if dir.length() < 1.0:
		return newest
	return newest + dir.normalized() * GameConfig.TILE * 6.0


func _mode_carry(_delta: float) -> void:
	var hooked_free := k.nearest_free_hook()
	if hooked_free == null:
		# Nowhere to hang them: drop and resume the hunt.
		k.drop_carried()
		mode = Mode.PATROL
		return
	goal = hooked_free.global_position
	var d := k.global_position.distance_to(goal)
	if d < GameConfig.TILE * 1.2:
		k.current_hook_target = hooked_free
		if k.machine.has_state("hooking"):
			k.machine.force("hooking")
		return
	_follow(_delta)


func _mode_search(delta: float) -> void:
	goal = last_seen
	var d := k.global_position.distance_to(goal)
	if d < GameConfig.TILE * 2.5:
		# Sweep outward from the last known position, but not more than once a
		# second or the goal thrashes and pathing never settles.
		_patrol_hold -= delta
		if _patrol_hold <= 0.0:
			_patrol_hold = 1.2
			last_seen += Vector2(randf_range(-1, 1), randf_range(-1, 1)).normalized() \
					* GameConfig.TILE * 8.0
			path.clear()
	_follow(delta)


## Damages a generator the bot is standing next to. Kicking is free pressure and
## the bot never did it at all, which meant a survivor tapping a generator had
## effectively finished it.
func _try_kick() -> bool:
	if k.is_carrying or k.machine.current_name != "move":
		return false
	# A cloaked Wraith cannot interact with the world; uncloaking here would just
	# fight the brain's own "cloak while roaming" rule, so the kick simply waits
	# until the next uncloaked window.
	if k.char_id == "wraith" and k.is_cloaked():
		return false
	if not k.machine.has_state("damage_gen"):
		return false
	for n in k.get_tree().get_nodes_in_group("interactable"):
		var g := n as Generator
		if g == null or not is_instance_valid(g) or not g.can_be_kicked_by(k):
			continue
		# Below ~12% it is not worth 1.8 seconds of standing still.
		if g.progress < 0.12:
			continue
		if k.global_position.distance_to(g.global_position) > GameConfig.TILE * 1.4:
			continue
		gens_kicked += 1
		k.machine.force("damage_gen", {"target": g})
		return true
	return false


func _mode_patrol(delta: float) -> void:
	if _try_kick():
		return
	_patrol_hold -= delta
	if _patrol_hold <= 0.0:
		_patrol_hold = randf_range(6.0, 11.0)
		patrol_point = _pick_patrol_point()
		path.clear()
		repath_timer = 0.0
	goal = patrol_point
	_follow(delta)


## Measures *net* displacement over a 1.5 s window. Per-frame movement is a bad
## signal (a bot can jitter 0.7 px forever between two path cells) and
## distance-to-goal resets whenever the goal is re-picked, so neither caught the
## real freezes. Net drift does.
func _update_stuck(delta: float) -> void:
	_anchor_time += delta
	if _anchor_time < 1.5:
		return
	var net := k.global_position.distance_to(_anchor_pos)
	_anchor_pos = k.global_position
	_anchor_time = 0.0
	if net > 12.0:
		_unstick_count = 0
		return
	if k.machine.current_name not in ["move", "carry", "attack"]:
		return

	# Frozen: throw the plan away and take a decisive side-step. The new target
	# is written to patrol_point (not goal) because _mode_patrol reassigns goal
	# on the same frame and would otherwise undo the recovery.
	path.clear()
	path_index = 0
	repath_timer = 0.0
	var heading := goal - k.global_position
	if heading.length() < 1.0:
		heading = Vector2.RIGHT
	var perp := Vector2(-heading.y, heading.x).normalized()
	if randf() < 0.5:
		perp = -perp
	patrol_point = k.global_position + perp * GameConfig.TILE * 7.0
	last_seen = patrol_point
	goal = patrol_point
	_patrol_hold = 3.5
	mode = Mode.PATROL
	# Walking into a wall while carrying someone should release the victim
	# rather than stall the whole trial.
	if k.is_carrying and randf() < 0.4:
		k.drop_carried()

	# Escalation: a bot wedged *inside* a prop collider cannot walk out of it
	# no matter how many side-steps we try, so on the third consecutive failure
	# we snap it to the nearest walkable cell.
	_unstick_count += 1
	if _unstick_count >= 3:
		_unstick_count = 0
		var mc := MatchController.instance
		if mc != null:
			var cell := _safe_escape_cell(mc)
			if cell.x >= 0:
				k.global_position = Utils.tile_center(cell)
				k.velocity = Vector2.ZERO
				path.clear()
				path_index = 0
				repath_timer = 0.0
				_anchor_pos = k.global_position


## Finds a walkable cell that is definitely *not* the one we are stuck on --
## teleporting to our own tile just drops us back inside the same prop collider.
func _safe_escape_cell(mc: MatchController) -> Vector2i:
	var here := Utils.tile_of(k.global_position)
	var probes := [
		Vector2i(2, 0), Vector2i(-2, 0), Vector2i(0, 2), Vector2i(0, -2),
		Vector2i(3, 3), Vector2i(-3, 3), Vector2i(3, -3), Vector2i(-3, -3),
		Vector2i(4, 0), Vector2i(0, 4), Vector2i(-4, 0), Vector2i(0, -4),
	]
	for d in probes:
		var c := mc.nearest_open_cell(here + d)
		if c.x >= 0 and c != here and c.distance_to(Vector2(here)) <= 6.0:
			return c
	return Vector2i(-1, -1)


func _pick_patrol_point() -> Vector2:
	var mc := MatchController.instance
	var candidates: Array = []
	for n in k.get_tree().get_nodes_in_group("interactable"):
		if n is Generator:
			var g := n as Generator
			if not g.completed:
				candidates.append(g.global_position)
			elif randf() < 0.3:
				candidates.append(g.global_position)
		elif n is Hook:
			candidates.append((n as Hook).global_position)
	if candidates.is_empty() or mc == null:
		return Vector2(randf_range(80, GameConfig.MAP_SIZE - 80),
				randf_range(80, GameConfig.MAP_SIZE - 80))
	candidates.shuffle()
	var target: Vector2 = candidates[0]
	# Aim at open ground *beside* the objective: generators and hooks have solid
	# colliders, so pathing straight onto them wedges the killer against them.
	var cell := mc.nearest_open_cell(Utils.tile_of(target))
	if cell.x < 0:
		return target
	var jitter := Vector2(randf_range(-3, 3), randf_range(-3, 3)) * GameConfig.TILE
	return Utils.tile_center(cell) + jitter


# ---------------------------------------------------------------------------
func _follow(delta: float) -> void:
	var mc := MatchController.instance
	if mc == null:
		return
	if path.is_empty() or repath_timer <= 0.0:
		repath_timer = REPATH_INTERVAL
		path = mc.find_path(k.global_position, goal)
		path_index = 0
	if path.is_empty():
		k.move_input = (goal - k.global_position).normalized()
		k.gait = Enums.Gait.RUN
		return

	while path_index < path.size() and \
			k.global_position.distance_to(path[path_index]) < GameConfig.TILE * 0.5:
		path_index += 1
	if path_index >= path.size():
		k.move_input = Vector2.ZERO
		return

	var next: Vector2 = path[path_index]
	var dir := (next - k.global_position).normalized()

	# Vault a window if the path goes through one. It costs the killer 1.5 s,
	# which is exactly the trade-off survivors exploit when they loop a window.
	var w := k._nearest_vaultable_window()
	if w != null and w.global_position.distance_to(k.global_position + dir * GameConfig.TILE * 0.9) \
			<= GameConfig.TILE * 0.9:
		if k.machine.has_state("vault"):
			k.machine.force("vault", {"target": w, "time": w.vault_time(k),
					"end": w.landing_point(k.global_position)})
		return

	k.move_input = dir
	k.gait = Enums.Gait.RUN

	# Break a pallet only when the path genuinely runs into it. The test used to be
	# "is a dropped pallet within 1.1 tiles", so the killer would stop and spend 2.6 s
	# smashing a board that merely happened to be nearby -- while his target kept
	# running. Now the board has to be ahead of him, along the direction he is moving.
	var p := k.nearest_breakable_pallet()
	if p != null and p.global_position.distance_to(k.global_position + dir * GameConfig.TILE) \
			<= GameConfig.TILE * 0.9:
		if k.machine.has_state("break_pallet"):
			k.machine.force("break_pallet", {"target": p})
		return
