class_name MatchController
extends Node2D
## Owns one trial: builds the realm, spawns the five actors, runs the objective
## timers, provides pathfinding for the bots and decides when the match is over.

static var instance: MatchController = null

const LAYER_WORLD := 0b00001
const LAYER_SURVIVOR := 0b00010
const LAYER_KILLER := 0b00100
const LAYER_INTERACTABLE := 0b01000

# --- realm -----------------------------------------------------------------
var map_data: Dictionary = {}
var grid: PackedByteArray
var map_size := 80
var map_id := "macmillan"
var astar: AStarGrid2D
var tile_layer: TileMapLayer

# --- actors ----------------------------------------------------------------
var survivors: Array = []
var killer: Killer = null
var local_actor: Node = null
var player_role: int = Enums.Team.SURVIVOR

# --- world objects ---------------------------------------------------------
var generators: Array = []
var hooks: Array = []
var exit_gates: Array = []
var pallets: Array = []
var windows: Array = []
var lockers: Array = []
var chests: Array = []
var hatch_node: Hatch = null
var world_root: Node2D

# --- match state -----------------------------------------------------------
var exit_powered := false
var generators_done := 0
var escaped_count := 0
var sacrificed_count := 0
var match_phase: int = Enums.MatchPhase.PREP
var elapsed := 0.0
var finished := false
var summary: Dictionary = {}

var camera: Camera2D
var hud: Node = null

var _shake_time := 0.0
var _shake_strength := 0.0
var _cam_pos := Vector2.ZERO
var _pending_local_first_frame := true


func _ready() -> void:
	instance = self
	add_to_group("match")
	EventBus.generator_completed.connect(_on_generator_completed)
	EventBus.camera_shake.connect(_on_shake)
	_begin()


func _exit_tree() -> void:
	if instance == self:
		instance = null


# ---------------------------------------------------------------------------
# Boot
# ---------------------------------------------------------------------------
func _begin() -> void:
	var seed_value: int = int(GameConfig.get_meta("pending_seed", randi()))
	if NetBridge.pending_match.has("seed"):
		seed_value = int(NetBridge.pending_match["seed"])
	map_id = GameConfig.selected_map
	if map_id == "auto" or not GameConfig.maps.has(map_id):
		var keys := GameConfig.maps.keys()
		map_id = keys[randi() % keys.size()] if not keys.is_empty() else "macmillan"
	if NetBridge.pending_match.has("map") and str(NetBridge.pending_match["map"]) != "auto":
		map_id = str(NetBridge.pending_match["map"])

	player_role = GameConfig.player_role

	# Debug switches, passed after `--` on the command line:
	#   --as-killer      start the trial as the killer
	#   --as-survivor    force the survivor role
	#   --map <id>       force a specific realm
	#   --debug-match    log objective progress every few seconds (useful for
	#                    headless soak tests)
	for arg in OS.get_cmdline_user_args():
		match arg:
			"--as-killer":
				player_role = Enums.Team.KILLER
			"--as-survivor":
				player_role = Enums.Team.SURVIVOR
			"--debug-match":
				_debug_match = true
	var uargs := OS.get_cmdline_user_args()
	for i in uargs.size():
		if uargs[i] == "--map" and i + 1 < uargs.size():
			map_id = uargs[i + 1]
	GameConfig.player_role = player_role

	_build_realm(seed_value)
	_spawn_actors()
	_setup_camera()
	AudioDirector.start_ambient()
	AudioDirector.play_music("music_calm", -14.0)
	match_phase = Enums.MatchPhase.EARLY
	EventBus.match_started.emit(player_role, GameConfig.selected_killer, map_id)


func _build_realm(seed_value: int) -> void:
	map_data = MapGenerator.generate(seed_value, map_id)
	map_size = int(map_data["size"])
	grid = map_data["grid"]

	world_root = Node2D.new()
	world_root.name = "World"
	add_child(world_root)

	_build_ground()
	_build_tiles()
	_build_astar()
	_instantiate_objects()


func _build_ground() -> void:
	# A flat backdrop in the realm's ground colour, cheaper than tiling the
	# whole map and it hides the void beyond the border.
	var cfg: Dictionary = map_data.get("cfg", {})
	var pal: Dictionary = cfg.get("palette", {})
	var rect := ColorRect.new()
	rect.color = Color(str(pal.get("ground", "#2a2a24")))
	rect.size = Vector2(GameConfig.MAP_SIZE, GameConfig.MAP_SIZE)
	rect.z_index = -100
	world_root.add_child(rect)


func _build_tiles() -> void:
	var tex := AnimBuilder.tile_atlas()
	if tex == null:
		return
	var ts := TileSet.new()
	ts.tile_size = Vector2i(GameConfig.TILE, GameConfig.TILE)
	ts.add_physics_layer()
	ts.set_physics_layer_collision_layer(0, LAYER_WORLD)
	ts.set_physics_layer_collision_mask(0, 0)
	ts.add_occlusion_layer()

	var src := TileSetAtlasSource.new()
	src.texture = tex
	src.texture_region_size = Vector2i(GameConfig.TILE, GameConfig.TILE)
	var cols := 8
	var rows := maxi(1, int(tex.get_height() / GameConfig.TILE))
	for y in rows:
		for x in cols:
			src.create_tile(Vector2i(x, y))

	# IMPORTANT: register the source with the TileSet *before* touching TileData.
	# Collision polygons and occluders belong to the TileSet's layers, so TileData
	# can only resolve them once the source is owned by a TileSet.
	ts.add_source(src, 0)

	# Inset the wall collider by 1 px: the tiles still render 16x16, but a
	# slightly slimmer collider stops 1-tile corridors from being unpassable for
	# a circle-shaped body.
	var half := GameConfig.TILE / 2.0 - 1.0
	var poly := PackedVector2Array([
		Vector2(-half, -half), Vector2(half, -half),
		Vector2(half, half), Vector2(-half, half),
	])
	var wall_names := ["wall_brick", "wall_wood", "wall_rock"]
	for wn in wall_names:
		var idx := AnimBuilder.tile_index(wn)
		if idx < 0:
			continue
		var coords := Vector2i(idx % cols, idx / cols)
		var td := src.get_tile_data(coords, 0)
		if td == null:
			continue
		td.set_collision_polygons_count(0, 1)
		td.set_collision_polygon_points(0, 0, poly)
		var occ := OccluderPolygon2D.new()
		occ.polygon = poly
		occ.closed = true
		td.set_occluder(0, occ)

	tile_layer = TileMapLayer.new()
	tile_layer.name = "Terrain"
	tile_layer.tile_set = ts
	tile_layer.z_index = -50
	world_root.add_child(tile_layer)

	var cfg: Dictionary = map_data.get("cfg", {})
	var style := str(cfg.get("wall_style", "brick"))
	var wall_name := "wall_brick"
	match style:
		"wood", "fence": wall_name = "wall_wood"
		"rock": wall_name = "wall_rock"
		"wreck": wall_name = "wall_rock"
	var wall_idx := AnimBuilder.tile_index(wall_name)
	if wall_idx < 0:
		wall_idx = 0
	var wall_coords := Vector2i(wall_idx % cols, wall_idx / cols)

	var floor_names := ["grass", "grass_dark", "dirt", "mud", "gravel", "concrete"]
	var floor_indices: Array = []
	for fn in floor_names:
		var fi := AnimBuilder.tile_index(fn)
		if fi >= 0:
			floor_indices.append(fi)
	if floor_indices.is_empty():
		floor_indices = [0]

	var rng := RandomNumberGenerator.new()
	rng.seed = int(map_data.get("seed", 1))

	for y in map_size:
		for x in map_size:
			var v := MapGenerator.at(grid, map_size, x, y)
			if v == MapGenerator.F_WALL:
				tile_layer.set_cell(Vector2i(x, y), 0, wall_coords)
			else:
				var pick: int = floor_indices[rng.randi_range(0, floor_indices.size() - 1)]
				tile_layer.set_cell(Vector2i(x, y), 0, Vector2i(pick % cols, pick / cols))


func _build_astar() -> void:
	astar = AStarGrid2D.new()
	astar.region = Rect2i(0, 0, map_size, map_size)
	astar.cell_size = Vector2i(GameConfig.TILE, GameConfig.TILE)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_AT_LEAST_ONE_WALKABLE
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.update()
	for y in map_size:
		for x in map_size:
			if MapGenerator.at(grid, map_size, x, y) == MapGenerator.F_WALL:
				astar.set_point_solid(Vector2i(x, y), true)


func _instantiate_objects() -> void:
	# --- generators ---
	var i := 0
	for pos in map_data.get("generators", []):
		var g := Generator.new()
		g.index = i
		world_root.add_child(g)
		g.global_position = pos
		generators.append(g)
		i += 1

	# --- hooks ---
	for pos in map_data.get("hooks", []):
		var h := Hook.new()
		world_root.add_child(h)
		h.global_position = pos
		hooks.append(h)

	# --- pallets ---
	for entry in map_data.get("pallets", []):
		var p := Pallet.new()
		p.direction = entry.get("dir", Vector2.RIGHT)
		world_root.add_child(p)
		p.global_position = entry["pos"]
		pallets.append(p)

	# --- windows ---
	for entry in map_data.get("windows", []):
		var w := WindowVault.new()
		w.direction = entry.get("dir", Vector2.RIGHT)
		world_root.add_child(w)
		w.global_position = entry["pos"]
		windows.append(w)

	# --- lockers ---
	for pos in map_data.get("lockers", []):
		var l := Locker.new()
		world_root.add_child(l)
		l.global_position = pos
		lockers.append(l)

	# --- chests ---
	for pos in map_data.get("chests", []):
		var c := Chest.new()
		world_root.add_child(c)
		c.global_position = pos
		chests.append(c)

	# --- exit gates ---
	var gate_id := 0
	for entry in map_data.get("gates", []):
		var e := ExitGate.new()
		e.gate_id = gate_id
		e.inward = entry.get("dir", Vector2.RIGHT)
		world_root.add_child(e)
		e.global_position = entry["pos"]
		exit_gates.append(e)
		gate_id += 1

	# --- hatch ---
	hatch_node = Hatch.new()
	world_root.add_child(hatch_node)
	hatch_node.global_position = map_data.get("hatch", Vector2.ZERO)


func _spawn_actors() -> void:
	var spawns: Dictionary = map_data.get("spawns", {})
	var surv_points: Array = spawns.get("survivors", [])
	var killer_point: Vector2 = spawns.get("killer", Vector2(GameConfig.MAP_SIZE * 0.5, 50))

	var roster := ["dwight", "meg", "claudette", "jake"]
	var player_char := GameConfig.selected_survivor
	if player_role == Enums.Team.SURVIVOR:
		roster.erase(player_char)
		roster.insert(0, player_char)

	var idx := 0
	for i in 4:
		var sid := i + 1
		var cid: String = roster[i] if i < roster.size() else "dwight"
		var is_local := player_role == Enums.Team.SURVIVOR and i == 0
		var name_key := str(GameConfig.survivors.get(cid, {}).get("name_key", "char.dwight"))
		var sv := Survivor.new()
		world_root.add_child(sv)
		var perks := _pick_survivor_perks(cid, is_local)
		sv.setup(Enums.Team.SURVIVOR, cid, Locale.t(name_key), sid, not is_local,
				perks, _random_item() if not is_local else _player_item())
		sv.survivor_id = sid
		sv.brain = SurvivorBrain.new(sv) if not is_local else null
		var p: Vector2 = surv_points[i] if i < surv_points.size() else Vector2.ZERO
		sv.global_position = p
		survivors.append(sv)
		if is_local:
			local_actor = sv
		EventBus.survivor_spawned.emit(sv)
		idx += 1

	var is_killer_local := player_role == Enums.Team.KILLER
	var kcfg: Dictionary = GameConfig.killers.get(GameConfig.selected_killer, {})
	killer = Killer.new()
	world_root.add_child(killer)
	killer.setup(Enums.Team.KILLER, GameConfig.selected_killer,
			Locale.t(str(kcfg.get("name_key", "char.trapper"))), 0,
			not is_killer_local, _pick_killer_perks(is_killer_local), [])
	killer.global_position = killer_point
	if is_killer_local:
		local_actor = killer
	EventBus.killer_spawned.emit(killer)


func _pick_survivor_perks(cid: String, is_local: bool) -> Array:
	if is_local:
		return GameConfig.survivor_perks.duplicate()
	# Bots get a sensible loadout drawn from the pool.
	var pool: Array = []
	for pid in GameConfig.perks.keys():
		var p: Dictionary = GameConfig.perks[pid]
		if str(p.get("side", "")) == "survivor":
			pool.append(pid)
	pool.shuffle()
	var out: Array = []
	var personal := str(GameConfig.survivors.get(cid, {}).get("personal_perk", ""))
	if personal != "":
		out.append(personal)
	for pid2 in pool:
		if out.size() >= 4:
			break
		if pid2 != personal:
			out.append(pid2)
	return out


func _pick_killer_perks(_is_local: bool) -> Array:
	if _is_local:
		return GameConfig.killer_perks.duplicate()
	var pool: Array = []
	for pid in GameConfig.perks.keys():
		var p: Dictionary = GameConfig.perks[pid]
		if str(p.get("side", "")) == "killer":
			pool.append(pid)
	pool.shuffle()
	return pool.slice(0, 4)


func _random_item() -> String:
	var pool := ["medkit", "flashlight", "toolbox", "map", ""]
	return pool[randi() % pool.size()]


func _player_item() -> String:
	return GameConfig.selected_item


func _setup_camera() -> void:
	camera = Camera2D.new()
	camera.name = "MainCamera"
	camera.zoom = Vector2(GameConfig.CAMERA_ZOOM, GameConfig.CAMERA_ZOOM)
	camera.position_smoothing_enabled = true
	camera.position_smoothing_speed = 8.0
	camera.limit_left = 0
	camera.limit_top = 0
	camera.limit_right = GameConfig.MAP_SIZE
	camera.limit_bottom = GameConfig.MAP_SIZE
	add_child(camera)
	if local_actor != null:
		camera.global_position = local_actor.global_position
		camera.make_current()

	var hud_scene := "res://scenes/hud.tscn"
	if ResourceLoader.exists(hud_scene):
		hud = load(hud_scene).instantiate()
		add_child(hud)


# ---------------------------------------------------------------------------
# Pathfinding
# ---------------------------------------------------------------------------
func find_path(from: Vector2, to: Vector2) -> Array:
	if astar == null:
		return []
	var a := _nearest_open_cell(Utils.tile_of(from))
	var b := _nearest_open_cell(Utils.tile_of(to))
	if a.x < 0 or b.x < 0:
		return []
	var raw := astar.get_point_path(a, b)
	var out: Array = []
	for p in raw:
		out.append(p + Vector2(GameConfig.TILE * 0.5, GameConfig.TILE * 0.5))
	return out


func nearest_open_cell(cell: Vector2i) -> Vector2i:
	return _nearest_open_cell(cell)


func _nearest_open_cell(cell: Vector2i) -> Vector2i:
	cell.x = clampi(cell.x, 0, map_size - 1)
	cell.y = clampi(cell.y, 0, map_size - 1)
	if not astar.is_point_solid(cell):
		return cell
	for r in range(1, 6):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var c := Vector2i(cell.x + dx, cell.y + dy)
				if c.x < 0 or c.y < 0 or c.x >= map_size or c.y >= map_size:
					continue
				if not astar.is_point_solid(c):
					return c
	return Vector2i(-1, -1)


func is_walkable(world_pos: Vector2) -> bool:
	if astar == null:
		return true
	var c := Utils.tile_of(world_pos)
	if c.x < 0 or c.y < 0 or c.x >= map_size or c.y >= map_size:
		return false
	return not astar.is_point_solid(c)


# ---------------------------------------------------------------------------
# Objectives
# ---------------------------------------------------------------------------
func _on_generator_completed(_count: int, _total: int) -> void:
	generators_done = min(GameConfig.GENERATORS_TOTAL, generators_done + 1)
	SaveData.add_bloodpoints("objective", GameConfig.BP_GENERATOR_DONE)
	SaveData.stats["generators_repaired"] = int(SaveData.stats.get("generators_repaired", 0)) + 1
	# NOTE: do NOT re-emit generator_completed here -- this handler *is* the
	# listener, and re-emitting recurses until the stack overflows. The HUD reads
	# generators_done from this controller directly.
	EventBus.toast.emit("%s %d/%d" % [Locale.t("hud.generators"), generators_done,
			GameConfig.GENERATORS_TOTAL], Color(0.95, 0.80, 0.35))
	if generators_done >= GameConfig.GENERATORS_TOTAL:
		_power_gates()


func _power_gates() -> void:
	if exit_powered:
		return
	exit_powered = true
	EventBus.generators_powered.emit()
	EventBus.toast.emit(Locale.t("hud.gate_powered"), Color(0.95, 0.80, 0.35))
	AudioDirector.play("gate_switch", -6.0)
	match_phase = Enums.MatchPhase.LATE
	EventBus.match_phase_changed.emit(match_phase)
	# Bitter Murmur style perk: reveal survivors near the finished generator.
	if killer != null and killer.perk_mods.has("reveal_time"):
		for sv in survivors:
			if sv.health == Enums.Health.HEALTHY or sv.health == Enums.Health.INJURED:
				EventBus.survivor_revealed.emit(sv.survivor_id, sv.global_position, "generator")


func alive_survivors() -> int:
	var n := 0
	for sv in survivors:
		if sv.health != Enums.Health.ESCAPED and sv.health != Enums.Health.DEAD:
			n += 1
	return n


func on_survivor_out(sv: Survivor, escaped: bool) -> void:
	if escaped:
		escaped_count += 1
	else:
		sacrificed_count += 1
	_check_hatch()
	_check_end()


func _check_hatch() -> void:
	if hatch_node == null or hatch_node.is_open:
		return
	if alive_survivors() <= GameConfig.HATCH_REVEAL_REMAINING:
		hatch_node.open_hatch()
		AudioDirector.play("hatch_open", -6.0)


# ---------------------------------------------------------------------------
# End conditions
# ---------------------------------------------------------------------------
func _check_end() -> void:
	if finished:
		return
	if alive_survivors() > 0:
		return
	# Everyone is out: whoever got through a gate or the hatch wins the trial.
	if escaped_count > 0:
		end_match(Enums.MatchResult.SURVIVOR_WIN)
	else:
		end_match(Enums.MatchResult.KILLER_WIN)


func end_match(result: int) -> void:
	if finished and summary.size() > 0:
		return
	finished = true
	match_phase = Enums.MatchPhase.ENDED
	summary = {
		"generators": generators_done,
		"escaped": escaped_count,
		"sacrificed": sacrificed_count,
		"great_skillchecks": _count_great_checks(),
		"time": elapsed,
		"map": map_id,
		"role": player_role,
	}
	SaveData.commit_match(player_role, summary)
	EventBus.match_ended.emit(result, summary)
	EventBus.match_phase_changed.emit(match_phase)
	AudioDirector.stop_music()
	await get_tree().create_timer(2.4).timeout
	SceneRouter.goto_results(result, summary)


func _count_great_checks() -> int:
	var n := 0
	for sv in survivors:
		n += sv.great_checks
	return n


func _check_escape_win() -> void:
	_check_end()


# ---------------------------------------------------------------------------
# Frame
# ---------------------------------------------------------------------------
var _debug_match := false
var _debug_timer := 0.0


func _process(delta: float) -> void:
	if finished:
		return
	elapsed += delta
	if _debug_match:
		_debug_timer -= delta
		if _debug_timer <= 0.0:
			_debug_timer = 5.0
			_debug_log()
	_update_phase()
	_update_camera(delta)
	_update_local_vision()


func _update_phase() -> void:
	var phase := match_phase
	if generators_done >= GameConfig.GENERATORS_TOTAL:
		phase = Enums.MatchPhase.LATE
	elif generators_done >= 3:
		phase = Enums.MatchPhase.MID
	elif elapsed > 30.0:
		phase = Enums.MatchPhase.EARLY
	if phase != match_phase:
		match_phase = phase
		EventBus.match_phase_changed.emit(phase)
		if phase == Enums.MatchPhase.MID:
			AudioDirector.play_music("music_calm", -18.0)


func _update_camera(delta: float) -> void:
	if camera == null or local_actor == null or not is_instance_valid(local_actor):
		return
	_cam_pos = local_actor.global_position
	# Look slightly ahead of the survivor's movement so chases read better.
	if local_actor is CharacterBase:
		var cb := local_actor as CharacterBase
		_cam_pos += cb.wish_dir * 14.0
	if player_role == Enums.Team.SURVIVOR and killer != null and is_instance_valid(killer):
		var d := camera.global_position.distance_to(killer.global_position)
		var target_zoom := 1.0 + clampf((GameConfig.TERROR_RADIUS - d) / GameConfig.TERROR_RADIUS, 0.0, 1.0) * 0.06
		camera.zoom = camera.zoom.lerp(Vector2(target_zoom, target_zoom), delta * 2.0)

	if _shake_time > 0.0:
		_shake_time -= delta
		var s := _shake_strength * (0.4 + 0.6 * sin(_shake_time * 60.0))
		camera.global_position = _cam_pos + Vector2(randf_range(-s, s), randf_range(-s, s))
	else:
		camera.global_position = camera.global_position.lerp(_cam_pos, clampf(delta * 10.0, 0.0, 1.0))


func _update_local_vision() -> void:
	if local_actor == null or not (local_actor is CharacterBase):
		return
	var cb := local_actor as CharacterBase
	if cb.light == null:
		return
	if cb.team == Enums.Team.SURVIVOR:
		cb.light.energy = 0.30
	else:
		cb.light.energy = 0.14


func _on_shake(strength: float, duration: float) -> void:
	_shake_strength = maxf(_shake_strength, strength)
	_shake_time = maxf(_shake_time, duration)


## Debug helper used by the in-game map overlay.
func objective_positions() -> Array:
	var out: Array = []
	for g in generators:
		out.append({"pos": g.global_position, "done": g.completed, "kind": "generator"})
	for h in hooks:
		out.append({"pos": h.global_position, "done": h.is_free(), "kind": "hook"})
	for e in exit_gates:
		out.append({"pos": e.global_position, "done": e.opened, "kind": "gate"})
	if hatch_node != null and hatch_node.is_open:
		out.append({"pos": hatch_node.global_position, "done": true, "kind": "hatch"})
	return out


func _debug_log() -> void:
	"""Headless soak-test instrumentation: prints enough to prove the match is
	actually progressing (bots repairing, the killer hunting, the hook cycle)."""
	var parts: Array = []
	for sv in survivors:
		parts.append("%s=%s/h%d%s" % [sv.char_id, Enums.health_to_string(sv.health),
				sv.hook_count, "/AI" if sv.is_ai else "/P"])
	var kpos := Vector2.ZERO
	var kstate := "-"
	if killer != null and is_instance_valid(killer):
		kpos = killer.global_position
		kstate = killer.machine.current_name
	print("[match t=%5.1f] gens=%d/%d powered=%s escaped=%d dead=%d killer=%s@%s | %s"
			% [elapsed, generators_done, GameConfig.GENERATORS_TOTAL, exit_powered,
			escaped_count, sacrificed_count, kstate, kpos, ", ".join(parts)])
