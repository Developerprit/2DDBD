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
	# A vault is invisible in a headless log unless we count it, and "cannot
	# vault" was the reported bug -- so count it and print it.
	EventBus.survivor_state_changed.connect(_on_survivor_state)
	_begin()


func _on_survivor_state(_id: int, state: String) -> void:
	if state == "vault":
		_vault_counter += 1


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
			"--dump-map":
				_dump_map = true
			"--test-vault":
				_test_vault = true
			"--test-pallet":
				_test_pallet = true
			"--test-kick":
				_test_kick = true
			"--test-instinct":
				_test_instinct = true
			"--test-release":
				_test_release = true
			"--test-wraith":
				_test_wraith = true
				GameConfig.selected_killer = "wraith"
				_killer_forced = true
			"--test-lunge":
				_test_lunge = true
				GameConfig.selected_killer = "trapper"
				_killer_forced = true
			"--test-ai":
				_test_ai = true
				GameConfig.selected_killer = "trapper"
				_killer_forced = true
			"--test-perks":
				_test_perks = true
			"--test-skillcheck":
				_test_skillcheck = true
			"--no-random-char":
				_no_random_chars = true
	var uargs := OS.get_cmdline_user_args()
	for i in uargs.size():
		if uargs[i] == "--map" and i + 1 < uargs.size():
			map_id = uargs[i + 1]
		if uargs[i] == "--seed" and i + 1 < uargs.size():
			seed_value = int(uargs[i + 1])
		if uargs[i] == "--killer" and i + 1 < uargs.size():
			GameConfig.selected_killer = uargs[i + 1]
			_killer_forced = true
		if uargs[i] == "--survivor" and i + 1 < uargs.size():
			GameConfig.selected_survivor = uargs[i + 1]
	GameConfig.player_role = player_role

	# Headless tests are written from the SURVIVOR's point of view and need the killer
	# to be a bot. The save can now permanently lock the player's side, so a test run
	# must never inherit it -- otherwise "the killer is local (no brain)" starts
	# failing purely because the person at the keyboard played a killer match.
	if _test_vault or _test_pallet or _test_kick or _test_instinct or _test_release \
			or _test_wraith or _test_lunge or _test_ai or _test_perks or _test_skillcheck:
		player_role = Enums.Team.SURVIVOR
		GameConfig.player_role = player_role

	_build_realm(seed_value)
	# Layout inspection tool: render the realm to a PNG and print a readability
	# report, then bail out. Never runs during a real match.
	if _dump_map:
		_dump_map_now()
		return
	_spawn_actors()
	# End-to-end vault check: drive a survivor through a real vault and verify the
	# displacement actually crosses the obstacle. The geometry self-check in MapDump
	# tests the maths; this tests that the maths survives the trip through the state
	# machine, the collision body and the destination snap.
	if _test_vault:
		_run_vault_test()
		return
	if _test_pallet:
		_run_pallet_test()
		return
	if _test_kick:
		_run_kick_test()
		return
	if _test_instinct:
		_run_instinct_test()
		return
	if _test_release:
		_run_release_test()
		return
	if _test_wraith:
		_run_wraith_test()
		return
	if _test_lunge:
		_run_lunge_test()
		return
	if _test_ai:
		_run_ai_test()
		return
	if _test_perks:
		_run_perks_test()
		return
	if _test_skillcheck:
		_run_skillcheck_test()
		return
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

	_build_ambient()
	_build_ground()
	_build_tiles()
	_build_astar()
	_instantiate_objects()


func _build_ambient() -> void:
	# Ambient darkness is half of the vision-occlusion system. Walls carry light
	# occluders (baked into the TileSet) and every character carries a
	# PointLight2D with shadows on, so anything behind a wall genuinely falls
	# dark instead of being drawn on top of it.
	var cm := CanvasModulate.new()
	cm.name = "AmbientDarkness"
	# Slightly warm rather than blue: a cool tint on top of an already dark scene
	# reads as murky, which buries the terrain further.
	cm.color = Color(GameConfig.AMBIENT_DARKNESS + 0.03, GameConfig.AMBIENT_DARKNESS,
			GameConfig.AMBIENT_DARKNESS)
	add_child(cm)


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


## Atlas coordinates of a tile by name, with a safe fallback.
func _wall_coords(name: String, cols: int) -> Vector2i:
	var idx := AnimBuilder.tile_index(name)
	if idx < 0:
		idx = maxi(0, AnimBuilder.tile_index("wall_brick"))
	return Vector2i(idx % cols, idx / cols)


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
	# Every wall variant needs the collider and the light occluder, or the top and
	# bottom pieces of a thick wall would be walk-through.
	var wall_names: Array = []
	for m in ["brick", "wood", "rock"]:
		wall_names.append_array(["wall_%s" % m, "wall_%s_top" % m, "wall_%s_bot" % m])
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
	var material := "brick"
	match style:
		"wood", "fence": material = "wood"
		"rock", "wreck": material = "rock"

	var floor_names := ["grass", "grass_dark", "dirt", "mud", "gravel", "concrete"]
	var floor_indices: Array = []
	for fn in floor_names:
		var fi := AnimBuilder.tile_index(fn)
		if fi >= 0:
			floor_indices.append(fi)
	if floor_indices.is_empty():
		floor_indices = [0]

	# Ground variants come from the realm's noise field, not from a per-tile roll:
	# independent rolls made the floor look like static, because no patch of the
	# same ground was ever wider than a single tile.
	var ground: PackedByteArray = map_data.get("ground", PackedByteArray())
	var wall_mid := _wall_coords("wall_%s" % material, cols)
	var wall_top := _wall_coords("wall_%s_top" % material, cols)
	var wall_bot := _wall_coords("wall_%s_bot" % material, cols)

	for y in map_size:
		for x in map_size:
			var v := MapGenerator.at(grid, map_size, x, y)
			if v == MapGenerator.F_WALL:
				# The lit edge belongs to the wall tile open to the sky, the shadow
				# to the one open at its foot. A one-tile-thick wall is open on both
				# sides and takes the lit edge, which is what keeps a thin wall
				# reading as a wall.
				var open_above := MapGenerator.at(grid, map_size, x, y - 1) == MapGenerator.F_FLOOR
				var open_below := MapGenerator.at(grid, map_size, x, y + 1) == MapGenerator.F_FLOOR
				var coords := wall_mid
				if open_above:
					coords = wall_top
				elif open_below:
					coords = wall_bot
				tile_layer.set_cell(Vector2i(x, y), 0, coords)
			else:
				var gi := 0
				if not ground.is_empty() and y * map_size + x < ground.size():
					gi = int(ground[y * map_size + x])
				gi = clampi(gi, 0, floor_indices.size() - 1)
				var pick: int = floor_indices[gi]
				tile_layer.set_cell(Vector2i(x, y), 0, Vector2i(pick % cols, pick / cols))


func _build_astar() -> void:
	astar = AStarGrid2D.new()
	astar.region = Rect2i(0, 0, map_size, map_size)
	astar.cell_size = Vector2i(GameConfig.TILE, GameConfig.TILE)
	# ONLY_IF_NO_OBSTACLES: a diagonal step is only allowed when BOTH orthogonal
	# neighbours are walkable. AT_LEAST_ONE_WALKABLE let paths cut across wall
	# corners, and a body with a 4.5-5.5 px radius wedged on that corner every
	# time -- the "bots grind into walls" report.
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.update()
	for y in map_size:
		for x in map_size:
			if MapGenerator.at(grid, map_size, x, y) == MapGenerator.F_WALL:
				astar.set_point_solid(Vector2i(x, y), true)

	# A window is a hole in a wall: the tile keeps its collider (you vault it,
	# you do not walk through it), but the pathfinder must treat it as passable
	# or every bot routes around it and vaulting never happens. The weight is
	# deliberately heavy so a window is only taken when it clearly saves ground.
	for entry in map_data.get("windows", []):
		var cell := Utils.tile_of(entry["pos"])
		if cell.x < 0 or cell.y < 0 or cell.x >= map_size or cell.y >= map_size:
			continue
		astar.set_point_solid(cell, false)
		astar.set_point_weight_scale(cell, 1.8)


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

	# Per-match random line-up for the BOTS. The human plays the character they
	# picked in the loadout -- slot 0 used to be a random draw like the rest, so the
	# player's own choice was silently ignored and they spawned as someone random.
	var surv_pool: Array = GameConfig.survivors.keys()
	var local_is_survivor := player_role == Enums.Team.SURVIVOR
	var roster: Array = []
	if _no_random_chars:
		# Deterministic line-up for tests: the human's pick first, then the pool in
		# roster order, so nothing depends on the RNG.
		var first: String = GameConfig.selected_survivor if local_is_survivor \
				else str(surv_pool[0])
		roster.append(first)
		for cid in surv_pool:
			if roster.size() >= 4:
				break
			if str(cid) != first:
				roster.append(cid)
	else:
		for i in 4:
			roster.append(surv_pool[randi() % surv_pool.size()])
		if local_is_survivor:
			roster[0] = GameConfig.selected_survivor

	# The killer is a random draw too -- unless a test/--killer override pinned one,
	# or the human is the killer, in which case their pick must be honoured.
	var killer_pool: Array = GameConfig.killers.keys()
	if not _killer_forced and player_role != Enums.Team.KILLER:
		GameConfig.selected_killer = killer_pool[randi() % killer_pool.size()]

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


## Strips anything the character has not actually unlocked, so a stale loadout or a
## hand-edited save can never field a perk the bloodweb never granted.
func _filter_unlocked(perks: Array, cid: String) -> Array:
	var owned := SaveData.unlocked_perk_ids(cid)
	var out: Array = []
	for pid in perks:
		if owned.has(pid):
			out.append(pid)
	return out


func _pick_survivor_perks(cid: String, is_local: bool) -> Array:
	if is_local:
		return _filter_unlocked(GameConfig.survivor_perks, cid)
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
		return _filter_unlocked(GameConfig.killer_perks, GameConfig.selected_killer)
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
var _dump_map := false
var _test_vault := false
var _test_pallet := false
var _test_kick := false
var _test_instinct := false
var _test_release := false
var _test_wraith := false
var _test_lunge := false
var _test_ai := false
var _test_perks := false
var _test_skillcheck := false
var _killer_forced := false
var _no_random_chars := false
var _vault_counter := 0
var _web_checked := false


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
	_update_occlusion()


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


## Fades any enemy that has a wall between them and the local player. This is
## the gameplay-facing half of line of sight: the AI already refuses to see
## through walls, and now the player cannot either.
func _update_occlusion() -> void:
	if local_actor == null or not (local_actor is CharacterBase):
		return
	var viewer := local_actor as CharacterBase
	var viewer_pos := viewer.global_position
	for n in get_tree().get_nodes_in_group("character"):
		var cb := n as CharacterBase
		if cb == null or not is_instance_valid(cb) or cb == viewer:
			continue
		# Teammates are hidden too: line of sight is symmetric, and being able to
		# watch a teammate through a wall would leak exactly the information the
		# occlusion system exists to withhold.
		if cb.health == Enums.Health.ESCAPED or cb.health == Enums.Health.DEAD:
			continue
		var blocked := viewer.blocked_by_wall(viewer_pos, cb.global_position)
		# A survivor hiding in a locker is simply not visible.
		if cb is Survivor and (cb as Survivor).is_hidden():
			blocked = true
		cb.set_obscured(blocked)


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


## Drives one real vault end to end and reports whether the survivor ended up on the
## far side of the obstacle.
##
## The MapDump geometry check exercises landing_point() directly; this exercises it
## through the whole path -- state machine, destination snap, collision body -- which
## is where a correct-looking number can still turn into "the player was pushed
## backwards".
func _run_vault_test() -> void:
	if windows.is_empty():
		print("[vault-test] no windows on this realm")
		get_tree().quit()
		return
	var w: WindowVault = windows[0]
	var sv: Survivor = null
	for s in survivors:
		if s is Survivor:
			sv = s
			break
	if sv == null:
		print("[vault-test] no survivor")
		get_tree().quit()
		return

	var normal := Vector2(-w.direction.y, w.direction.x)
	var start: Vector2 = w.global_position + normal * GameConfig.TILE * 1.2
	sv.global_position = start
	sv.velocity = Vector2.ZERO
	var expected: Vector2 = w.landing_point(start)
	print("[vault-test] window=%s dir=%s" % [w.global_position, w.direction])
	print("[vault-test] start=%s landing_point=%s" % [start, expected])

	sv._begin_vault(w, expected, 0.4)
	var frames := 0
	while frames < 180:
		await get_tree().physics_frame
		frames += 1
		if sv.machine.current_name != "vault":
			break

	var finish: Vector2 = sv.global_position
	var side_before := signf((start - w.global_position).dot(normal))
	var side_after := signf((finish - w.global_position).dot(normal))
	var travelled := start.distance_to(finish) / float(GameConfig.TILE)
	# Crossed means: opposite side, clear of the obstacle, and we moved. The landing
	# is snapped to a whole tile, so "one tile past" is a legitimate result and the
	# bound has to tolerate the quantisation (it is exactly 1.0, not strictly over).
	var crossed := not is_equal_approx(side_after, side_before) \
			and absf((finish - w.global_position).dot(normal)) >= GameConfig.TILE * 0.9 \
			and travelled > 1.0
	print("[vault-test] end=%s moved=%.2f tiles side %.0f -> %.0f  %s"
			% [finish, travelled, side_before, side_after,
			"PASS" if crossed else "FAIL"])
	get_tree().quit()


## Asserts the three pallet states are actually three different objects: an upright
## board must not be solid, a dropped one must be, and each has to draw its own
## sprite.
##
## Both of these were broken at once and reported as a single confusing symptom --
## "an undropped pallet blocks me, and a dropped one looks smashed" -- so they get a
## check that cannot silently regress.
func _run_pallet_test() -> void:
	if pallets.is_empty():
		print("[pallet-test] no pallets on this realm")
		get_tree().quit()
		return
	var p: Pallet = pallets[0]
	var cases := [
		[Pallet.State.STANDING, "pallet", false],
		[Pallet.State.DROPPED, "pallet_dropped", true],
		[Pallet.State.BROKEN, "pallet_broken", false],
	]
	var names := ["STANDING", "DROPPED", "BROKEN"]
	var seen: Dictionary = {}
	var all_ok := true

	for i in cases.size():
		var st: int = cases[i][0]
		var want_tex: String = cases[i][1]
		var want_solid: bool = cases[i][2]
		p.state = st
		p._refresh()
		await get_tree().physics_frame

		var solids := 0
		if p.body != null:
			for c in p.body.get_children():
				if c is CollisionShape2D and not c.is_queued_for_deletion():
					solids += 1
		var tex := ""
		if p.sprite != null and p.sprite.texture != null:
			tex = p.sprite.texture.resource_path.get_file().get_basename()

		var solid_ok := (solids > 0) == want_solid
		var tex_ok := tex == want_tex
		if not (solid_ok and tex_ok):
			all_ok = false
		seen[tex] = true
		print("[pallet-test] %-8s colliders=%d (want %s)  sprite=%s (want %s)  %s"
				% [names[i], solids, "solid" if want_solid else "none",
				tex, want_tex, "PASS" if solid_ok and tex_ok else "FAIL"])

	var distinct := seen.size() == 3
	print("[pallet-test] distinct sprites: %d/3  %s"
			% [seen.size(), "PASS" if distinct else "FAIL"])
	print("[pallet-test] RESULT: %s" % ("PASS" if all_ok and distinct else "FAIL"))
	get_tree().quit()


## Generator damage. The original's numbers are: 1.8 s, -5% instantly, then
## -0.25 charges/s until a survivor works on it again, 8 regression events max.
func _run_kick_test() -> void:
	if generators.is_empty():
		print("[kick-test] no generators on this realm")
		get_tree().quit()
		return
	if killer == null or not is_instance_valid(killer):
		print("[kick-test] no killer")
		get_tree().quit()
		return

	var all_ok := true
	var g: Generator = generators[0]
	g.completed = false
	g.regression_events = 0
	g.regressing = false
	g.progress = 0.50
	var before := g.progress

	# --- 1. a kick costs exactly 5% and starts the bleed --------------------
	g.damage_by_killer(killer)
	var lost := before - g.progress
	var ok1: bool = is_equal_approx(lost, GameConfig.GEN_DAMAGE_LOSS) and g.regressing 			and g.regression_events == 1
	all_ok = all_ok and ok1
	print("[kick-test] loss=%.3f (want %.3f)  regressing=%s  events=%d  %s"
			% [lost, GameConfig.GEN_DAMAGE_LOSS, str(g.regressing), g.regression_events,
			"PASS" if ok1 else "FAIL"])

	# --- 2. it bleeds on its own -------------------------------------------
	var p1 := g.progress
	for i in 30:
		await get_tree().physics_frame
	var p2 := g.progress
	var ok2: bool = p2 < p1 - 0.001 and g.regressing
	all_ok = all_ok and ok2
	print("[kick-test] bleed %.4f -> %.4f over 30 frames  %s"
			% [p1, p2, "PASS" if ok2 else "FAIL"])

	# --- 3. a survivor working on it stops the bleed ------------------------
	var sv: Survivor = null
	for s in survivors:
		if is_instance_valid(s) and s.health == Enums.Health.HEALTHY:
			sv = s
			break
	if sv != null:
		g.on_interact_tick(sv, 0.016)
	var ok3: bool = not g.regressing or sv == null
	all_ok = all_ok and ok3
	print("[kick-test] repair stops regression=%s  %s"
			% [str(not g.regressing), "PASS" if ok3 else "FAIL"])

	# --- 4. the regression event cap actually caps --------------------------
	g.progress = 0.80
	g.completed = false
	while g.regression_events < GameConfig.GEN_REGRESSION_LIMIT:
		var was := g.regression_events
		g.damage_by_killer(killer)
		if g.regression_events == was:
			break
	var at_cap: bool = not g.can_be_kicked_by(killer)
	var nine: int = g.regression_events
	g.damage_by_killer(killer)
	var ok4: bool = at_cap and g.regression_events == nine 			and nine == GameConfig.GEN_REGRESSION_LIMIT
	all_ok = all_ok and ok4
	print("[kick-test] cap reached at %d events, 9th rejected=%s  %s"
			% [nine, str(g.regression_events == nine), "PASS" if ok4 else "FAIL"])

	# --- 5. finished and untouched generators refuse a kick ----------------
	var g2: Generator = generators[mini(1, generators.size() - 1)]
	g2.completed = true
	var ok5a: bool = not g2.can_be_kicked_by(killer)
	g2.completed = false
	g2.progress = 0.0
	g2.regression_events = 0
	var ok5b: bool = not g2.can_be_kicked_by(killer)
	var ok5: bool = ok5a and ok5b
	all_ok = all_ok and ok5
	print("[kick-test] finished rejected=%s  untouched rejected=%s  %s"
			% [str(ok5a), str(ok5b), "PASS" if ok5 else "FAIL"])

	print("[kick-test] RESULT: %s" % ("PASS" if all_ok else "FAIL"))
	get_tree().quit()


## Killer Instinct. It must only ever yield survivors -- never a generator, the
## hatch or a gate -- and only for as long as a power says so.
func _run_instinct_test() -> void:
	if killer == null or not is_instance_valid(killer):
		print("[instinct-test] no killer")
		get_tree().quit()
		return
	if survivors.is_empty():
		print("[instinct-test] no survivors")
		get_tree().quit()
		return

	var all_ok := true

	# --- 1. nothing is revealed before a power triggers it -----------------
	var ok1: bool = killer.instinct_active().is_empty()
	all_ok = all_ok and ok1
	print("[instinct-test] silent until triggered=%s  %s"
			% [str(ok1), "PASS" if ok1 else "FAIL"])

	# --- 2. revealing one survivor yields exactly that survivor -----------
	var far: Survivor = null
	for s in survivors:
		if is_instance_valid(s) and s.health == Enums.Health.HEALTHY:
			far = s
			break
	if far != null:
		killer.instinct_reveal(far, 2.0)
	var active := killer.instinct_active()
	var only_survivors := true
	for n in active:
		var sv := n as Node
		if sv == null or not sv.is_in_group("survivor"):
			only_survivors = false
	var ok2: bool = active.size() == 1 and active[0] == far and only_survivors
	all_ok = all_ok and ok2
	print("[instinct-test] revealed=%d, all survivors=%s  %s"
			% [active.size(), str(only_survivors), "PASS" if ok2 else "FAIL"])

	# --- 3. anything that is not a live survivor is refused ---------------
	var dead: Survivor = null
	for s in survivors:
		if is_instance_valid(s) and s != far:
			dead = s
			break
	var ok3 := true
	if dead != null:
		var was: int = killer.instinct_active().size()
		dead.health = Enums.Health.DEAD
		killer.instinct_reveal(dead, 5.0)
		ok3 = killer.instinct_active().size() == was
		dead.health = Enums.Health.HEALTHY
	all_ok = all_ok and ok3
	print("[instinct-test] dead survivor refused=%s  %s"
			% [str(ok3), "PASS" if ok3 else "FAIL"])

	# --- 4. placing a trap flushes out only those actually in range -------
	for n in killer.instinct_active():
		killer._instinct.clear()
		break
	var near: Survivor = survivors[0] as Survivor
	var keep := near.global_position
	near.global_position = killer.global_position + Vector2(GameConfig.TILE * 3.0, 0)
	for s2 in survivors:
		if s2 == near or not is_instance_valid(s2):
			continue
		s2.global_position = killer.global_position + Vector2(0, GameConfig.TILE * 40.0)
	killer.place_trap()
	var got := killer.instinct_active()
	var ok4: bool = got.size() == 1 and got[0] == near
	for n in got:
		if not (n as Node).is_in_group("survivor"):
			ok4 = false
	all_ok = all_ok and ok4
	print("[instinct-test] trap placement revealed %d (want 1, the one in range)  %s"
			% [got.size(), "PASS" if ok4 else "FAIL"])
	near.global_position = keep

	# --- 5. a blown calibration reveals the survivor ----------------------
	# The user's spec: exactly three things may trigger instinct, and this is the
	# first of them. It was missing entirely before.
	killer._instinct.clear()
	var blower: Survivor = survivors[0] as Survivor
	blower.health = Enums.Health.HEALTHY
	blower._resolve_skill_check(0)
	var after_fail := killer.instinct_active()
	var ok5: bool = after_fail.size() == 1 and after_fail[0] == blower
	all_ok = all_ok and ok5
	print("[instinct-test] blown calibration revealed %d (want 1, the survivor)  %s"
			% [after_fail.size(), "PASS" if ok5 else "FAIL"])

	# --- 6. vaulting terrain within range with NO line of sight reveals ----
	killer._instinct.clear()
	var vaulter: Survivor = survivors[0] as Survivor
	var hid_spot := Vector2.INF
	for rad in [4, 5, 6, 7, 8, 9, 10]:
		for ang in 16:
			var p: Vector2 = killer.global_position + Vector2.RIGHT.rotated(
					TAU * float(ang) / 16.0) * GameConfig.TILE * float(rad)
			if is_walkable(p) and killer.blocked_by_wall(killer.global_position, p):
				hid_spot = p
				break
		if hid_spot != Vector2.INF:
			break
	if hid_spot == Vector2.INF:
		print("[instinct-test] no hidden spot on this realm -- vault check SKIPPED")
	else:
		vaulter.global_position = hid_spot
		vaulter.notify_vaulted(null)
		var after_vault := killer.instinct_active()
		var ok6: bool = after_vault.size() == 1 and after_vault[0] == vaulter
		all_ok = all_ok and ok6
		print("[instinct-test] hidden vault revealed %d (want 1, the vaulter)  %s"
				% [after_vault.size(), "PASS" if ok6 else "FAIL"])
		# …but a vault well out of range must stay silent.
		killer._instinct.clear()
		vaulter.global_position = killer.global_position + Vector2(
				GameConfig.TILE * (GameConfig.KI_VAULT_RANGE + 6.0), 0)
		vaulter.notify_vaulted(null)
		var ok7: bool = killer.instinct_active().is_empty()
		all_ok = all_ok and ok7
		print("[instinct-test] far vault stayed silent=%s  %s"
				% [str(ok7), "PASS" if ok7 else "FAIL"])

	print("[instinct-test] RESULT: %s" % ("PASS" if all_ok else "FAIL"))
	get_tree().quit()


## The "bot never lets go of the generator" bug, as an assertion.
##
## A bot is parked on a generator and left to commit to the repair; the killer is
## then teleported on top of it. The bot must leave the interact state within a
## second. This is invisible from a screenshot and was reported twice -- the first
## fix (release-on-goal-change) was unreachable because think() bailed out before
## the danger check while inside `interact`.
func _run_release_test() -> void:
	var bot: Survivor = null
	for s in survivors:
		if is_instance_valid(s) and (s as Survivor).is_ai \
				and (s as Survivor).health == Enums.Health.HEALTHY:
			bot = s
			break
	var gen: Generator = null
	for n in get_tree().get_nodes_in_group("interactable"):
		var g := n as Generator
		if g != null and not g.completed:
			gen = g
			break
	if bot == null or gen == null or killer == null:
		print("[release-test] missing bot / generator / killer  FAIL")
		get_tree().quit()
		return

	# Park the bot on the machine, the killer as far away as the realm allows.
	var bot_home := gen.global_position + Vector2(GameConfig.TILE, 0)
	bot.global_position = bot_home
	bot.velocity = Vector2.ZERO
	killer.global_position = Vector2(GameConfig.TILE * 4.0, GameConfig.TILE * 4.0)

	var frames := 0
	while frames < 360:
		await get_tree().physics_frame
		frames += 1
		if bot.machine.current_name == "interact":
			break
	if bot.machine.current_name != "interact":
		print("[release-test] bot never started repairing (state=%s)  FAIL"
				% bot.machine.current_name)
		get_tree().quit()
		return
	print("[release-test] bot repairing after %.1fs" % (float(frames) / 60.0))

	# Killer on top of the bot. The danger check has to interrupt the repair.
	killer.global_position = bot.global_position + Vector2(GameConfig.TILE * 1.2, 0)
	frames = 0
	while frames < 120:
		await get_tree().physics_frame
		frames += 1
		if bot.machine.current_name != "interact":
			break
	var released: bool = bot.machine.current_name != "interact"
	print("[release-test] killer adjacent -> bot state=%s after %.2fs  %s"
			% [bot.machine.current_name, float(frames) / 60.0,
			"PASS" if released else "FAIL"])
	get_tree().quit()


## Wraith "Wailing Bell" assertion test. Drives the real bell channel and proves
## every number in the user's spec: 1.5 s to ENTER cloak, 2.5 s to EXIT, 5.0 m/s
## while cloaked, a 150% burst for 1 s on materialising, and the distance-based
## stealth (invisible past 20 m, faint shimmer within).
func _run_wraith_test() -> void:
	if killer == null or not is_instance_valid(killer):
		print("[wraith-test] no killer  FAIL"); get_tree().quit(); return
	if killer.char_id != "wraith":
		print("[wraith-test] killer is '%s', not wraith  FAIL" % killer.char_id); get_tree().quit(); return
	# Isolate the killer: no brain, so it won't auto-uncloak on its own and we
	# can measure the cloaked state the instant the bell finishes.
	killer.is_ai = false
	if killer.brain != null:
		killer.brain = null
	var ok := true
	var F := 60  # fixed-fps rate

	# --- 1. Bell ENTER: 2.5 s channel, then cloaked, speed 5.0 m/s ----------
	killer.cloaked = false
	killer.attack_cooldown = 0.0
	killer.request_power()
	var entered_bell := killer.machine.current_name == "bell"
	print("[wraith-test] bell-enter state=%s  %s" % [killer.machine.current_name, "PASS" if entered_bell else "FAIL"])
	ok = ok and entered_bell
	var f := 0
	while f < F * 4 and not killer.cloaked:
		await get_tree().physics_frame
		f += 1
	await get_tree().physics_frame
	var want_in := GameConfig.WRAITH_BELL_CLOAK_TIME
	var bell_in := killer.cloaked and f >= int(F * want_in - 0.4 * F) and f <= int(F * want_in + 0.4 * F)
	print("[wraith-test] cloaked after %d frames (~%.2fs, want ~%.1fs)  %s"
			% [f, float(f) / F, want_in, "PASS" if bell_in else "FAIL"])
	ok = ok and bell_in
	var cloak_speed := killer.base_speed()
	var want_cloak := GameConfig.m(GameConfig.WRAITH_CLOAK_CLOAKED_SPEED)
	var speed_ok := absf(cloak_speed - want_cloak) < 1.5
	print("[wraith-test] cloaked speed=%.1f want=%.1f  %s" % [cloak_speed, want_cloak, "PASS" if speed_ok else "FAIL"])
	ok = ok and speed_ok

	# --- 2. Distance-based stealth (player POV): 0 beyond 20 m, shimmer <20 --
	var sv: Survivor = survivors[0] if not survivors.is_empty() else null
	if sv != null:
		sv.is_ai = false  # the stealth rule keys off the (human) local survivor
		killer.cloaked = true
		sv.global_position = killer.global_position + Vector2(GameConfig.TILE * 30, 0)  # 30 m
		var a_far := killer._cloak_target_alpha()
		sv.global_position = killer.global_position + Vector2(GameConfig.TILE * 10, 0)  # 10 m
		var a_near := killer._cloak_target_alpha()
		var far_ok := is_equal_approx(a_far, 0.0)
		var near_ok := absf(a_near - GameConfig.WRAITH_CLOAK_SEMI_ALPHA) < 0.01
		print("[wraith-test] alpha >20m=%.2f (want 0.00)  %s | <20m=%.2f (want %.2f)  %s"
			% [a_far, "PASS" if far_ok else "FAIL", a_near, GameConfig.WRAITH_CLOAK_SEMI_ALPHA, "PASS" if near_ok else "FAIL"])
		ok = ok and far_ok and near_ok
		sv.is_ai = true
		killer.cloaked = false

	# --- 3. Bell EXIT: 3.0 s channel, uncloak grants 150% haste for 1 s -----
	killer.cloaked = true
	killer.attack_cooldown = 0.0
	killer.request_power()
	f = 0
	while f < F * 4 and killer.cloaked:
		await get_tree().physics_frame
		f += 1
	await get_tree().physics_frame
	var want_out := GameConfig.WRAITH_BELL_UNCLOAK_TIME
	var uncloak_time_ok := (not killer.cloaked) and f >= int(F * want_out - 0.4 * F) and f <= int(F * want_out + 0.4 * F)
	print("[wraith-test] uncloaked after %d frames (~%.2fs, want ~%.1fs)  %s"
			% [f, float(f) / F, want_out, "PASS" if uncloak_time_ok else "FAIL"])
	ok = ok and uncloak_time_ok
	var haste_speed := killer.base_speed()
	var want_haste := GameConfig.m(GameConfig.K_RUN) * GameConfig.WRAITH_UNCLOAK_HASTE_MULT
	var haste_ok := absf(haste_speed - want_haste) < 1.5
	print("[wraith-test] uncloak haste speed=%.1f want=%.1f  %s" % [haste_speed, want_haste, "PASS" if haste_ok else "FAIL"])
	ok = ok and haste_ok
	# The burst must decay after ~1 s back to the normal 4.6 m/s run.
	f = 0
	while f < int(F * 1.3):
		await get_tree().physics_frame
		f += 1
	var after_speed := killer.base_speed()
	var decay_ok := absf(after_speed - GameConfig.m(GameConfig.K_RUN)) < 1.5
	print("[wraith-test] speed after haste=%.1f want=%.1f  %s" % [after_speed, GameConfig.m(GameConfig.K_RUN), "PASS" if decay_ok else "FAIL"])
	ok = ok and decay_ok

	# --- 4. Cloak interaction bonus: a cloaked Wraith may interact at all, and does
	# it 4% faster. Both halves matter -- the old code refused to interact at all
	# while cloaked and made you ring the bell first.
	killer.cloaked = true
	var m_cloak := killer.interaction_speed_mult()
	var t_cloak := GameConfig.K_WINDOW_VAULT_TIME / m_cloak
	killer.cloaked = false
	var m_open := killer.interaction_speed_mult()
	var t_open := GameConfig.K_WINDOW_VAULT_TIME / m_open
	var mult_ok := absf(m_cloak - GameConfig.WRAITH_CLOAK_INTERACT_SPEED) < 0.001 \
			and absf(m_open - 1.0) < 0.001
	var faster := t_cloak < t_open
	print("[wraith-test] cloak interact mult=%.2f (open %.2f) vault %.2fs -> %.2fs  %s"
			% [m_cloak, m_open, t_open, t_cloak,
			"PASS" if (mult_ok and faster) else "FAIL"])
	ok = ok and mult_ok and faster

	# ...and a cloaked Wraith can actually COMPLETE an interaction, not just be
	# awarded a multiplier. Park a body next to him and pick it up while cloaked.
	var body: Survivor = survivors[0] if not survivors.is_empty() else null
	if body != null:
		killer.cloaked = true
		body.set_health(Enums.Health.DOWNED)
		body.global_position = killer.global_position + Vector2(GameConfig.TILE, 0)
		var picked := killer.try_pickup()
		var carry_ok := picked and killer.is_carrying
		print("[wraith-test] cloaked pickup=%s carrying=%s  %s"
				% [str(picked), str(killer.is_carrying), "PASS" if carry_ok else "FAIL"])
		ok = ok and carry_ok
		killer.drop_carried()
		killer.cloaked = false

	print("[wraith-test] RESULT: %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit()


## Bot calibration sanity check. Bots do not read the dial, so the ONLY thing that
## decides their outcome is the fumble roll -- assert both outcomes really occur at
## roughly the configured rate rather than trusting the code by eye.
func _run_skillcheck_test() -> void:
	var sv: Survivor = null
	for s in survivors:
		if is_instance_valid(s) and (s as Survivor).is_ai:
			sv = s
			break
	if sv == null:
		print("[skillcheck-test] no bot survivor  FAIL"); get_tree().quit(); return

	# Resolving a check awards bloodpoints; snapshot and restore so a test run can
	# never inflate the player's wallet.
	var wallet_before: Dictionary = SaveData.wallet.duplicate()
	var counts := {0: 0, 1: 0, 2: 0}
	var tally := func(_id: int, grade: int) -> void:
		counts[grade] = int(counts.get(grade, 0)) + 1
	EventBus.skill_check_resolved.connect(tally)

	var trials := 800
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in trials:
		sv.skill.begin(rng, 1.0, 1.0)
		# Park the needle past the zone so the bot commits on this call.
		sv.skill.value = 1.0
		sv._ai_press_skill_check()
	EventBus.skill_check_resolved.disconnect(tally)
	SaveData.wallet = wallet_before

	var fails := int(counts.get(0, 0))
	var greats := int(counts.get(2, 0))
	var goods := int(counts.get(1, 0))
	var rate := float(fails) / float(trials)
	var want := GameConfig.AI_SKILLCHECK_FAIL_CHANCE
	# 800 trials at p=0.2: a +-6 point window is about 4 sigma, so this will not flake.
	var rate_ok := absf(rate - want) <= 0.06
	var both := fails > 0 and greats > 0 and goods == 0
	print("[skillcheck-test] %d trials -> fail=%d (%.1f%%, want %.0f%%) great=%d good=%d"
			% [trials, fails, rate * 100.0, want * 100.0, greats, goods])
	print("[skillcheck-test] rate ok=%s  both outcomes seen=%s  %s"
			% [str(rate_ok), str(both), "PASS" if (rate_ok and both) else "FAIL"])
	print("[skillcheck-test] RESULT: %s" % ("PASS" if (rate_ok and both) else "FAIL"))
	get_tree().quit()


## Perk-system sanity check for the "three exclusives / teachable at 60 / shared
## perks come from the bloodweb" rules.
func _run_perks_test() -> void:
	var ok := true

	# 1. Every character owns exactly three exclusive perks.
	for cid in GameConfig.survivors.keys():
		var n := Bloodweb.exclusive_perks_for(cid).size()
		ok = ok and n == 3
		print("[perks-test] survivor %-9s exclusives=%d (want 3)  %s"
			% [cid, n, "PASS" if n == 3 else "FAIL"])
	for cid in GameConfig.killers.keys():
		var n2 := Bloodweb.exclusive_perks_for(cid).size()
		ok = ok and n2 == 3
		print("[perks-test] killer   %-9s exclusives=%d (want 3)  %s"
			% [cid, n2, "PASS" if n2 == 3 else "FAIL"])

	# 2. A fresh character has its own exclusives and nothing else -- no free
	#    generic perks, no other character's perks.
	var fid := "meg"
	var fresh := SaveData.unlocked_perk_ids(fid)
	var only_own := fresh.size() == 3
	for pid in fresh:
		if str(GameConfig.perks[pid].get("owner", "")) != fid:
			only_own = false
	ok = ok and only_own
	print("[perks-test] fresh %s unlocked=%s (want its own 3)  %s"
		% [fid, str(fresh), "PASS" if only_own else "FAIL"])

	# 3. Reaching TEACHABLE_TIER with one character hands its three exclusives to
	#    the rest of the same side. The save is restored before we leave.
	var d := SaveData.web_state("dwight")
	var saved_tier := int(d.get("tier", 1))
	d["tier"] = Bloodweb.TEACHABLE_TIER
	var after := SaveData.unlocked_perk_ids(fid)
	var gained := 0
	for pid2 in Bloodweb.exclusive_perks_for("dwight"):
		if after.has(pid2):
			gained += 1
	d["tier"] = saved_tier
	var teach_ok := gained == 3
	ok = ok and teach_ok
	print("[perks-test] dwight@%d teaches %d/3 to %s  %s"
		% [Bloodweb.TEACHABLE_TIER, gained, fid, "PASS" if teach_ok else "FAIL"])

	# 4. The bloodweb pool is the shared pool only: exclusives are never sold.
	var pool: Array = Bloodweb.perk_pool(false)
	var pool_ok := pool.size() > 0
	for pid3 in pool:
		if str(GameConfig.perks[pid3].get("owner", "")) != "":
			pool_ok = false
	ok = ok and pool_ok
	print("[perks-test] survivor bloodweb pool=%d ownerless-only=%s  %s"
		% [pool.size(), str(pool_ok), "PASS" if pool_ok else "FAIL"])

	print("[perks-test] RESULT: %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit()


## True when a body of `margin` radius can travel from `from` along `delta` without
## scraping a wall. Samples the swept corridor on both sides of the centre line so
## a spot that merely grazes a corner is rejected before it can flake the test.
func _has_clear_corridor(from: Vector2, delta: Vector2, margin: float) -> bool:
	var steps := 8
	var side := Vector2(-delta.y, delta.x).normalized() * margin
	for i in steps + 1:
		var t := float(i) / float(steps)
		var p := from + delta * t
		if killer.blocked_by_wall(p, p + side) or killer.blocked_by_wall(p - side, p):
			return false
	return true


## Lunge vs Quick attack. A quick swing only reaches the base 2.9 tiles; a lunge
## multiplies reach by 1.5 AND dashes the killer forward, so from the same mid
## range a quick whiffs while a lunge connects -- and the lunge physically moves
## the killer toward the survivor.
func _run_lunge_test() -> void:
	if killer == null or not is_instance_valid(killer):
		print("[lunge-test] no killer  FAIL"); get_tree().quit(); return
	if killer.char_id == "wraith":
		print("[lunge-test] wraith cannot swing while cloaked  FAIL"); get_tree().quit(); return
	killer.is_ai = false
	if killer.brain != null:
		killer.brain = null
	var ok := true
	var D := 3.75  # tiles -> 60 px, between quick (2.9) and lunge (4.35) reach
	var sv: Survivor = survivors[0] if not survivors.is_empty() else null
	if sv == null:
		print("[lunge-test] no survivor  FAIL"); get_tree().quit(); return
	sv.is_ai = false  # keep it parked

	# Gather candidate firing lines and try them until the lunge actually connects.
	# A wall ray cannot see props (crates, rocks, cars) which still block a dash,
	# and the killer's body has a radius, so predicting every obstacle from
	# geometry alone is unreliable and made this test flaky. Trying real spots is
	# not: a QUICK attack that connects at this range would be a genuine logic
	# failure, so that is asserted once, on the first candidate.
	var candidates: Array = []
	for s in survivors:
		candidates.append(s.global_position)
	candidates.append(killer.global_position)
	for gy in range(5, map_size - 5, 4):
		for gx in range(5, map_size - 5, 4):
			var cell := Vector2i(gx, gy)
			if nearest_open_cell(cell) == cell:
				candidates.append(Utils.tile_center(cell))

	var quick_miss := true
	var quick_done := false
	var base := Vector2.ZERO
	var target := Vector2.ZERO
	var lunge_hit := false
	var f := 0
	for c in candidates:
		if not _has_clear_corridor(c, Vector2(GameConfig.TILE * D, 0), 14.0):
			continue
		var tgt: Vector2 = c + Vector2(GameConfig.TILE * D, 0)

		# Quick attack from this range must MISS (checked once).
		if not quick_done:
			quick_done = true
			sv.health = Enums.Health.HEALTHY
			killer.global_position = c
			sv.global_position = tgt
			killer.face_towards(tgt)
			killer.attack_cooldown = 0.0
			killer.machine.force("attack", {"lunge": false})
			var fq := 0
			while fq < 120 and killer.machine.current_name == "attack":
				await get_tree().physics_frame
				fq += 1
			await get_tree().physics_frame
			quick_miss = sv.health == Enums.Health.HEALTHY
			print("[lunge-test] quick @%.1fm -> %s (want HEALTHY/MISS)  %s"
				% [D, Enums.health_to_string(sv.health), "PASS" if quick_miss else "FAIL"])
			ok = ok and quick_miss
			if not quick_miss:
				break

		# Lunge attack from the same range must HIT.
		sv.health = Enums.Health.HEALTHY
		killer.global_position = c
		sv.global_position = tgt
		killer.face_towards(tgt)
		killer.attack_cooldown = 0.0
		killer.machine.force("attack", {"lunge": true})
		f = 0
		while f < 120 and killer.machine.current_name == "attack":
			await get_tree().physics_frame
			f += 1
		await get_tree().physics_frame
		if sv.health != Enums.Health.HEALTHY:
			lunge_hit = true
			base = c
			target = tgt
			break
	print("[lunge-test] lunge @%.1fm -> %s (want INJURED/HIT)  %s"
		% [D, Enums.health_to_string(sv.health), "PASS" if lunge_hit else "FAIL"])
	ok = ok and lunge_hit
	if not lunge_hit:
		print("[lunge-test] RESULT: FAIL")
		get_tree().quit()
		return
	if not quick_done:
		print("[lunge-test] no clear firing line found  FAIL")
		get_tree().quit()
		return

	# A lunge also drives the killer FORWARD (the dash).
	sv.health = Enums.Health.HEALTHY
	killer.global_position = base
	sv.global_position = target
	killer.face_towards(target)
	killer.attack_cooldown = 0.0
	var start_pos := killer.global_position
	killer.machine.force("attack", {"lunge": true})
	f = 0
	while f < 120 and killer.machine.current_name == "attack":
		await get_tree().physics_frame
		f += 1
	await get_tree().physics_frame
	var dash := killer.global_position.distance_to(start_pos)
	var dashed := dash > GameConfig.TILE * 1.0
	print("[lunge-test] lunge forward displacement=%.1fpx (want > %d)  %s"
		% [dash, GameConfig.TILE, "PASS" if dashed else "FAIL"])
	ok = ok and dashed

	print("[lunge-test] RESULT: %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit()


## Killer-AI sanity check. The old brain whiffed because it swung without facing
## the target. This parks one survivor in front of an AI killer and asserts that
## (a) the killer actually commits to a swing, (b) it faces the victim (within the
## 35 deg swing arc) the whole time it is swinging, and (c) it connects.
func _run_ai_test() -> void:
	if killer == null or not is_instance_valid(killer):
		print("[ai-test] no killer  FAIL"); get_tree().quit(); return
	if not killer.is_ai:
		print("[ai-test] killer is local (no brain); run with --as-survivor  FAIL"); get_tree().quit(); return
	var ok := true
	var victim: Survivor = null
	for s in survivors:
		if is_instance_valid(s):
			victim = s
			break
	if victim == null:
		print("[ai-test] no survivor  FAIL"); get_tree().quit(); return
	victim.is_ai = false  # park it in front of the killer

	# Candidate firing lines: actor positions plus a sweep of open floor. The bot has
	# to PATH to the parked victim, so a spot whose straight line merely tests clear
	# can still be a dead end behind a prop. Trying a few keeps the test from
	# flaking on map geometry instead of failing for a real reason.
	var candidates: Array = []
	for s in survivors:
		candidates.append(s.global_position)
	candidates.append(killer.global_position)
	for gy in range(5, map_size - 5, 6):
		for gx in range(5, map_size - 5, 6):
			var cell := Vector2i(gx, gy)
			if nearest_open_cell(cell) == cell:
				candidates.append(Utils.tile_center(cell))

	var saw_attack := false
	var hit := false
	# Facing error of the attempt that actually landed the hit. The swing arc is 35
	# deg, so a well-aimed bot sits near zero; 45 is the "it is clearly facing the
	# victim, not swinging backwards" bar.
	var hit_err := 1e9
	var attempts := 0
	for c in candidates:
		if attempts >= 3:
			break
		if not _has_clear_corridor(c, Vector2(GameConfig.TILE * 4.0, 0), 14.0):
			continue
		attempts += 1
		killer.global_position = c
		victim.global_position = c + Vector2(GameConfig.TILE * 4.0, 0)
		killer.face_towards(victim.global_position)
		for s2 in survivors:
			if s2 != victim and is_instance_valid(s2):
				s2.global_position = c + Vector2(0, GameConfig.TILE * 40.0)
		var attempt_err := 0.0
		var f := 0
		var limit := 60 * 8  # 8 s
		while f < limit:
			await get_tree().physics_frame
			f += 1
			if killer.machine.current_name == "attack":
				saw_attack = true
				var to := victim.global_position - killer.global_position
				if to.length() > 1.0:
					var err := absf(Utils.angle_delta(killer.facing_rad, to.angle()))
					attempt_err = maxf(attempt_err, err)
			if victim.health != Enums.Health.HEALTHY:
				break
		hit = victim.health != Enums.Health.HEALTHY
		print("[ai-test] try %d at %s attack=%s facing=%.1f deg downed_in=%.1fs"
			% [attempts, str(c.round()), str(saw_attack), rad_to_deg(attempt_err), float(f) / 60.0])
		if hit:
			hit_err = attempt_err
			if attempt_err < deg_to_rad(45.0) + 0.01:
				break
		victim.health = Enums.Health.HEALTHY

	if attempts == 0:
		print("[ai-test] no open LOS spot found  FAIL"); get_tree().quit(); return
	var faced_ok := saw_attack and hit_err < deg_to_rad(45.0) + 0.01
	print("[ai-test] entered attack=%s  facing err on hit=%.1f deg (want <45)  %s"
		% [str(saw_attack), rad_to_deg(hit_err), "PASS" if faced_ok else "FAIL"])
	print("[ai-test] survivor downed/injured=%s  %s" % [str(hit), "PASS" if hit else "FAIL"])
	ok = ok and saw_attack and hit and faced_ok
	print("[ai-test] RESULT: %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit()


func _dump_map_now() -> void:
	var dir := "user://"
	MapDump.report(map_data, self)
	var out := OS.get_environment("DUMP_OUT")
	if out == "":
		out = "res://build"
	DirAccess.make_dir_recursive_absolute(out)
	# Render the *current* (requested) seed too, for debugging seed-specific bugs.
	MapDump.render(map_data, self, "%s/debug_%s_%d.png" % [out, map_id, int(GameConfig.get_meta("pending_seed", 0))])
	for i in 6:
		var s := (i * 7919) + 13
		var md := MapGenerator.generate(s, map_id)
		MapDump.report(md, self)
		var nm := "%s/map_%s_%d.png" % [out, map_id, s]
		MapDump.render(md, self, nm)
	print("[dump] done")
	get_tree().quit()


## How many generators are currently bleeding progress, i.e. that the killer has
## damaged and nobody has touched since.
func _regressing_gens() -> int:
	var n := 0
	for g in generators:
		if is_instance_valid(g) and g.regressing:
			n += 1
	return n


func _debug_log() -> void:
	"""Headless soak-test instrumentation: prints enough to prove the match is
	actually progressing (bots repairing, the killer hunting, the hook cycle)."""
	var parts: Array = []
	# How many pallets have been spent. This is the clearest single signal that the
	# survivor bots have learned to use them at all -- before this they left every
	# single board standing for the entire trial.
	var spent := 0
	for pl in pallets:
		if is_instance_valid(pl) and (pl as Pallet).state != Pallet.State.STANDING:
			spent += 1
	parts.append("pallets=%d/%d" % [spent, pallets.size()])
	for sv in survivors:
		# Include the state machine name: it is the only way to see from a log
		# whether vaulting / repair / carry are actually firing.
		# Hook stage matters for reading a soak test: at a glance you can tell a
		# rescue window (s1) from a fight (s2) from a survivor who has been taken.
		var hook_note := ""
		if sv.current_hook != null and is_instance_valid(sv.current_hook):
			hook_note = "/s%d" % int(sv.current_hook.stage)
		parts.append("%s=%s/%s/h%d%s" % [sv.char_id, Enums.health_to_string(sv.health),
				sv.machine.current_name, sv.hook_count, hook_note])
	parts.append("ai: vaults=%d/scratch=%d/kicks=%d/regress=%d/loopcut=%d/rotate=%d/KI=%d/bell=%d/cloak=%d/bellwalk=%d"
			% [_vault_counter, KillerBrain.scratch_follows, KillerBrain.gens_kicked,
			_regressing_gens(), KillerBrain.loop_cuts, SurvivorBrain.rotations,
			killer.instinct_active().size() if killer != null else -1,
			KillerBrain.bell_rings, KillerBrain.bell_cloaks,
			KillerBrain.bell_move_frames])
	var kpos := Vector2.ZERO
	var kstate := "-"
	if killer != null and is_instance_valid(killer):
		kpos = killer.global_position
		kstate = killer.machine.current_name
	print("[match t=%5.1f] gens=%d/%d powered=%s escaped=%d dead=%d killer=%s@%s | %s"
			% [elapsed, generators_done, GameConfig.GENERATORS_TOTAL, exit_powered,
			escaped_count, sacrificed_count, kstate, kpos, ", ".join(parts)])
