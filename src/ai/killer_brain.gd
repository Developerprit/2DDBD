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

enum Mode { PATROL, CHASE, SEARCH, CARRY }

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

const REPATH_INTERVAL := 0.7
const ATTACK_RANGE := 2.0 * 16.0


func _init(killer: Killer) -> void:
	k = killer


## Breaks the brain <-> actor reference cycle so the match scene tears down
## cleanly instead of leaking ObjectDB instances.
func dispose() -> void:
	k = null
	path.clear()
	target = null


func think(delta: float) -> void:
	if MatchController.instance == null:
		return
	repath_timer -= delta
	patrol_timer -= delta
	search_timer -= delta
	_update_stuck(delta)

	if k.machine.current_name in ["attack", "stun", "hooking", "vault", "place_trap", "break_pallet"]:
		k.move_input = Vector2.ZERO
		return

	if k.is_carrying and k.carried != null:
		_mode_carry(delta)
		return

	var seen := k.nearest_visible_survivor()
	if seen != null:
		target = seen
		last_seen = seen.global_position
		mode = Mode.CHASE
		search_timer = 6.0
	elif mode == Mode.CHASE:
		mode = Mode.SEARCH if search_timer > 0.0 else Mode.PATROL
	elif mode == Mode.SEARCH and search_timer <= 0.0:
		mode = Mode.PATROL

	match mode:
		Mode.CHASE:
			_mode_chase(delta)
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

	# In range and facing roughly the right way -> swing.
	if dist < ATTACK_RANGE and k.attack_cooldown <= 0.0 \
			and k.machine.has_state("attack") and k.machine.current_name != "attack" \
			and not k.blocked_by_wall(k.global_position, target.global_position):
		k.machine.force("attack")
		return

	goal = target.global_position
	_follow(delta)

	# Trapper drops a trap on the path when the chase is not going anywhere.
	if k.char_id == "trapper" and k.trap_stock > 0 and dist > GameConfig.TILE * 6.0 \
			and randf() < 0.002:
		if k.machine.has_state("place_trap"):
			k.machine.force("place_trap", {"mode": "place"})


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


func _mode_patrol(delta: float) -> void:
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

	# Automatic pallet breaking and window vaulting when the path is blocked.
	var p := k.nearest_breakable_pallet()
	if p != null and k.global_position.distance_to(p.global_position) < GameConfig.TILE * 1.1:
		if k.machine.has_state("break_pallet"):
			k.machine.force("break_pallet", {"target": p})
		return
