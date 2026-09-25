class_name MapGenerator
extends RefCounted
## Deterministic procedural level generation.
##
## Produces a tile grid plus every objective and prop placement so that the same
## seed always rebuilds the exact same realm. Layout language borrows from Dead
## by Daylight: a large open field punctuated by solid obstacle clusters, with
## generator / hook / pallet / window loops spread out so every corner of the map
## has something to run around.

const F_FLOOR := 0
const F_WALL := 1

const GENERATOR_CLEARANCE := 2   ## tiles of free space around a generator
const MIN_GENERATOR_DIST := 14.0 ## tile distance between generators

const HOOK_MIN_DIST := 9.0
const PALLET_MIN_DIST := 3.5


static func generate(seed_value: int, map_id: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var cfg := _config_for(map_id)
	var n: int = int(cfg.get("tiles", 80))

	var grid := _blank(n)
	_border(grid, n, 2)
	_carve_landmarks(grid, n, rng, cfg)
	_scatter_obstacles(grid, n, rng, cfg)
	_seal_unreachable(grid, n)

	var result := {
		"size": n,
		"grid": grid,
		"map_id": map_id,
		"cfg": cfg,
		"seed": seed_value,
	}

	# ---- objectives -------------------------------------------------------
	var generators := _place_spread(grid, n, rng, GameConfig.GENERATORS_TOTAL,
			GENERATOR_CLEARANCE, MIN_GENERATOR_DIST)
	result["generators"] = generators

	var gate_spots := _place_gates(grid, n, rng)
	result["gates"] = gate_spots

	# ---- loops: pallets + windows near obstacle clusters -------------------
	var clusters := _find_clusters(grid, n, rng)
	var pallets: Array = []
	var windows: Array = []
	_place_loops(grid, n, rng, clusters, int(cfg.get("pallet_count", 12)),
			int(cfg.get("window_count", 10)), pallets, windows)
	result["pallets"] = pallets
	result["windows"] = windows

	# ---- hooks: spread like a loose grid so no area is hookless -----------
	result["hooks"] = _place_hooks(grid, n, rng, generators)

	# ---- lockers + chests -------------------------------------------------
	result["lockers"] = _place_spread(grid, n, rng, int(cfg.get("locker_count", 6)), 1, 4.0)
	result["chests"] = _place_spread(grid, n, rng, int(cfg.get("chest_count", 3)), 1, 6.0)

	# ---- hatch ------------------------------------------------------------
	result["hatch"] = _pick_far_floor(grid, n, rng, generators)

	# ---- spawns -----------------------------------------------------------
	result["spawns"] = _place_spawns(grid, n, rng, generators, gate_spots)
	return result


# ---------------------------------------------------------------------------
# Terrain
# ---------------------------------------------------------------------------
static func _config_for(map_id: String) -> Dictionary:
	if GameConfig.maps.has(map_id):
		return GameConfig.maps[map_id]
	var keys := GameConfig.maps.keys()
	if keys.is_empty():
		return {"tiles": 80, "pallet_count": 12, "window_count": 10,
				"locker_count": 6, "chest_count": 3, "wall_density": 0.2}
	return GameConfig.maps[keys[0]]


static func _blank(n: int) -> PackedByteArray:
	var g := PackedByteArray()
	g.resize(n * n)
	g.fill(F_FLOOR)
	return g


static func at(g: PackedByteArray, n: int, x: int, y: int) -> int:
	if x < 0 or y < 0 or x >= n or y >= n:
		return F_WALL
	return g[y * n + x]


static func set_at(g: PackedByteArray, n: int, x: int, y: int, v: int) -> void:
	if x < 0 or y < 0 or x >= n or y >= n:
		return
	g[y * n + x] = v


static func _border(g: PackedByteArray, n: int, thickness: int) -> void:
	for t in thickness:
		for i in n:
			set_at(g, n, i, t, F_WALL)
			set_at(g, n, i, n - 1 - t, F_WALL)
			set_at(g, n, t, i, F_WALL)
			set_at(g, n, n - 1 - t, i, F_WALL)


static func _rect(g: PackedByteArray, n: int, x0: int, y0: int, w: int, h: int, v: int) -> void:
	for y in range(y0, y0 + h):
		for x in range(x0, x0 + w):
			set_at(g, n, x, y, v)


static func _carve_landmarks(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		cfg: Dictionary) -> void:
	## A handful of walled compounds that act as visual anchors and safe-ish loops.
	var count := rng.randi_range(3, 5)
	var placed: Array = []
	for _i in count:
		var w := rng.randi_range(9, 16)
		var h := rng.randi_range(9, 16)
		var x := rng.randi_range(4, n - w - 5)
		var y := rng.randi_range(4, n - h - 5)
		var r := Rect2i(x, y, w, h)
		var ok := true
		for other in placed:
			if r.grow(4).intersects(other):
				ok = false
				break
		if not ok:
			continue
		placed.append(r)

		# wall ring
		for xx in range(x, x + w + 1):
			set_at(g, n, xx, y, F_WALL)
			set_at(g, n, xx, y + h, F_WALL)
		for yy in range(y, y + h + 1):
			set_at(g, n, x, yy, F_WALL)
			set_at(g, n, x + w, yy, F_WALL)

		# doorways (2 wide) on two opposing sides
		_rect(g, n, x + w / 2, y, 2, 1, F_FLOOR)
		_rect(g, n, x + w / 2, y + h, 2, 1, F_FLOOR)
		if rng.randf() < 0.6:
			_rect(g, n, x, y + h / 2, 1, 2, F_FLOOR)
		if rng.randf() < 0.6:
			_rect(g, n, x + w, y + h / 2, 1, 2, F_FLOOR)

		# interior clutter keeps the compound interesting to loop through
		for _k in rng.randi_range(2, 5):
			var iw := rng.randi_range(1, 3)
			var ih := rng.randi_range(1, 3)
			var ix := rng.randi_range(x + 2, x + w - iw - 2)
			var iy := rng.randi_range(y + 2, y + h - ih - 2)
			_rect(g, n, ix, iy, iw, ih, F_WALL)


static func _scatter_obstacles(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		cfg: Dictionary) -> void:
	var density := float(cfg.get("wall_density", 0.2))
	var tries := int(n * n * density * 0.06)
	for _i in tries:
		var x := rng.randi_range(4, n - 5)
		var y := rng.randi_range(4, n - 5)
		if at(g, n, x, y) == F_WALL:
			continue
		# keep a breathing gap around existing walls
		var crowded := false
		for oy in range(-2, 3):
			for ox in range(-2, 3):
				if at(g, n, x + ox, y + oy) == F_WALL:
					crowded = true
					break
			if crowded:
				break
		if crowded:
			continue
		match rng.randi_range(0, 3):
			0:
				set_at(g, n, x, y, F_WALL)
			1:
				_rect(g, n, x, y, 2, 2, F_WALL)
			_:
				_rect(g, n, x, y, rng.randi_range(1, 3), rng.randi_range(1, 2), F_WALL)


static func _seal_unreachable(g: PackedByteArray, n: int) -> void:
	## Any pocket the survivors cannot walk to becomes solid so nothing gets stuck.
	var seen := PackedByteArray()
	seen.resize(n * n)
	seen.fill(0)
	var start := Vector2i(-1, -1)
	var done := false
	for r in range(0, n):
		for a in range(-r, r + 1):
			var cands := [
				Vector2i(n / 2 + a, n / 2 + r), Vector2i(n / 2 + a, n / 2 - r),
				Vector2i(n / 2 + r, n / 2 + a), Vector2i(n / 2 - r, n / 2 + a),
			]
			for cand in cands:
				if cand.x > 1 and cand.y > 1 and cand.x < n - 2 and cand.y < n - 2 \
						and at(g, n, cand.x, cand.y) == F_FLOOR:
					start = cand
					done = true
					break
			if done:
				break
		if done:
			break
	if start.x < 0:
		return

	var queue: Array[Vector2i] = [start]
	seen[start.y * n + start.x] = 1
	while not queue.is_empty():
		var c: Vector2i = queue.pop_back()
		for d in Utils.DIRS4:
			var nx := c.x + int(d.x)
			var ny := c.y + int(d.y)
			if nx < 0 or ny < 0 or nx >= n or ny >= n:
				continue
			if seen[ny * n + nx] == 1:
				continue
			if at(g, n, nx, ny) == F_WALL:
				continue
			seen[ny * n + nx] = 1
			queue.append(Vector2i(nx, ny))

	for y in n:
		for x in n:
			if at(g, n, x, y) == F_FLOOR and seen[y * n + x] == 0:
				set_at(g, n, x, y, F_WALL)


# ---------------------------------------------------------------------------
# Placement helpers
# ---------------------------------------------------------------------------
static func _free(g: PackedByteArray, n: int, x: int, y: int, margin: int) -> bool:
	for oy in range(-margin, margin + 1):
		for ox in range(-margin, margin + 1):
			if at(g, n, x + ox, y + oy) != F_FLOOR:
				return false
	return true


static func _place_spread(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		count: int, margin: int, min_dist: float) -> Array:
	var placed: Array = []
	var guard := 0
	while placed.size() < count and guard < 20000:
		guard += 1
		var x := rng.randi_range(5, n - 6)
		var y := rng.randi_range(5, n - 6)
		if not _free(g, n, x, y, margin):
			continue
		var p := Utils.tile_center(Vector2i(x, y))
		var too_close := false
		for q in placed:
			if p.distance_to(q) < min_dist * GameConfig.TILE:
				too_close = true
				break
		if too_close:
			continue
		placed.append(p)
	return placed


static func _place_hooks(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		generators: Array) -> Array:
	## Hooks cover the whole map on a jittered grid, biased away from generators.
	var hooks: Array = []
	var step := 13
	var y := 6
	while y < n - 6:
		var x := 6
		while x < n - 6:
			var jx := x + rng.randi_range(-3, 3)
			var jy := y + rng.randi_range(-3, 3)
			if jx > 4 and jy > 4 and jx < n - 5 and jy < n - 5 and _free(g, n, jx, jy, 1):
				var p := Utils.tile_center(Vector2i(jx, jy))
				var ok := true
				for q in hooks:
					if p.distance_to(q) < HOOK_MIN_DIST * GameConfig.TILE * 0.6:
						ok = false
						break
				if ok:
					hooks.append(p)
			x += step
		y += step
	return hooks


static func _find_clusters(g: PackedByteArray, n: int, rng: RandomNumberGenerator) -> Array:
	## Pick wall borders that look like good loop anchors (a wall with open sides).
	var out: Array = []
	for _i in int(n * n * 0.05):
		var x := rng.randi_range(6, n - 7)
		var y := rng.randi_range(6, n - 7)
		if at(g, n, x, y) != F_WALL:
			continue
		if _free(g, n, x, y, 0):
			continue
		# count open neighbours in the 5x5 ring
		var open_sides := 0
		for d in Utils.DIRS4:
			var nx := x + int(d.x) * 2
			var ny := y + int(d.y) * 2
			if at(g, n, nx, ny) == F_FLOOR:
				open_sides += 1
		if open_sides >= 2:
			out.append(Vector2i(x, y))
	return out


static func _place_loops(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		clusters: Array, pallet_count: int, window_count: int,
		pallets: Array, windows: Array) -> void:
	Utils.seeded_shuffle(clusters, rng)
	var pool: Array = clusters.duplicate()
	var pi := 0
	while pallets.size() < pallet_count and pi < pool.size():
		var c: Vector2i = pool[pi]
		pi += 1
		# a pallet sits on the open tile facing a wall, forming a vault line
		var opts: Array = []
		for d in Utils.DIRS4:
			var nx := c.x + int(d.x)
			var ny := c.y + int(d.y)
			var bx := c.x + int(d.x) * 2
			var by := c.y + int(d.y) * 2
			if at(g, n, nx, ny) == F_FLOOR and at(g, n, bx, by) == F_FLOOR:
				opts.append(Vector2(d.x, d.y))
		if opts.is_empty():
			continue
		var dir: Vector2 = opts[rng.randi_range(0, opts.size() - 1)]
		var p := Utils.tile_center(c) + Vector2(dir.x, dir.y) * GameConfig.TILE * 0.5
		var ok := true
		for q in pallets:
			if p.distance_to(q.get("pos", Vector2.ZERO)) < PALLET_MIN_DIST * GameConfig.TILE:
				ok = false
				break
		if ok:
			pallets.append({"pos": p, "dir": dir})

	pi = 0
	var attempts := 0
	while windows.size() < window_count and attempts < pool.size() * 2:
		attempts += 1
		var c: Vector2i = pool[rng.randi_range(0, pool.size() - 1)]
		if at(g, n, c.x, c.y) != F_WALL:
			continue
		# a window is a hole punched through a 1-tile-thick wall
		var horizontal := at(g, n, c.x - 1, c.y) == F_WALL and at(g, n, c.x + 1, c.y) == F_WALL
		var vertical := at(g, n, c.x, c.y - 1) == F_WALL and at(g, n, c.x, c.y + 1) == F_WALL
		if not horizontal and not vertical:
			continue
		var p := Utils.tile_center(c)
		var dup := false
		for q in windows:
			if p.distance_to(q.get("pos", Vector2.ZERO)) < 3.0 * GameConfig.TILE:
				dup = true
				break
		if dup:
			continue
		if horizontal:
			# wall runs east-west, the window is crossed going north-south
			if at(g, n, c.x, c.y - 1) != F_FLOOR and at(g, n, c.x, c.y + 1) != F_FLOOR:
				continue
			windows.append({"pos": p, "dir": Vector2(0, 1)})
		else:
			if at(g, n, c.x - 1, c.y) != F_FLOOR and at(g, n, c.x + 1, c.y) != F_FLOOR:
				continue
			windows.append({"pos": p, "dir": Vector2(1, 0)})


static func _place_gates(g: PackedByteArray, n: int, rng: RandomNumberGenerator) -> Array:
	## Two exit gates carved into opposite edges of the realm.
	var gates: Array = []
	var mid := n / 2
	var pairs := [
		[Vector2i(0, mid + rng.randi_range(-12, 12)), Vector2(1, 0)],
		[Vector2i(n - 1, mid + rng.randi_range(-12, 12)), Vector2(-1, 0)],
	]
	var chosen := [pairs[0], pairs[1]]
	if rng.randf() < 0.5:
		chosen = [pairs[1], pairs[0]]
	for entry in chosen:
		var cell: Vector2i = entry[0]
		var inward: Vector2 = entry[1]
		# clear a corridor so the gateway is reachable and visible
		for k in range(0, 5):
			var cx := cell.x + int(inward.x) * k
			var cy := cell.y + int(inward.y) * k
			for oy in range(-3, 4):
				for ox in range(-3, 4):
					set_at(g, n, cx + ox, cy + oy, F_FLOOR)
		set_at(g, n, cell.x, cell.y, F_FLOOR)
		var gate_pos := Vector2(cell.x * GameConfig.TILE, cell.y * GameConfig.TILE) \
				+ Vector2(GameConfig.TILE * 0.5, GameConfig.TILE * 0.5)
		gates.append({"pos": gate_pos, "dir": inward})
	return gates


static func _pick_far_floor(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		generators: Array) -> Vector2:
	var best := Vector2.ZERO
	var best_score := -1.0
	for _i in 400:
		var x := rng.randi_range(5, n - 6)
		var y := rng.randi_range(5, n - 6)
		if not _free(g, n, x, y, 1):
			continue
		var p := Utils.tile_center(Vector2i(x, y))
		var score := 1e9
		for gpos in generators:
			score = minf(score, p.distance_to(gpos))
		if score > best_score:
			best_score = score
			best = p
	return best


static func _place_spawns(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		generators: Array, gates: Array) -> Dictionary:
	var survivor_spawns: Array = []
	var guard := 0
	while survivor_spawns.size() < 4 and guard < 8000:
		guard += 1
		var x := rng.randi_range(6, n - 7)
		var y := rng.randi_range(6, n - 7)
		if not _free(g, n, x, y, 1):
			continue
		var p := Utils.tile_center(Vector2i(x, y))
		var ok := true
		for q in survivor_spawns:
			if p.distance_to(q) < 12.0 * GameConfig.TILE:
				ok = false
				break
		if not ok:
			continue
		for gg in generators:
			if p.distance_to(gg) < 6.0 * GameConfig.TILE:
				ok = false
				break
		if ok:
			survivor_spawns.append(p)
	while survivor_spawns.size() < 4:
		survivor_spawns.append(Vector2(n * GameConfig.TILE * 0.5, n * GameConfig.TILE * 0.5))

	# killer spawns far from every survivor, biased to a different quadrant
	var killer := Vector2.ZERO
	var best := -1.0
	for _i in 600:
		var x := rng.randi_range(5, n - 6)
		var y := rng.randi_range(5, n - 6)
		if not _free(g, n, x, y, 1):
			continue
		var p := Utils.tile_center(Vector2i(x, y))
		var score := 1e9
		for s in survivor_spawns:
			score = minf(score, p.distance_to(s))
		if score > best:
			best = score
			killer = p
	if killer == Vector2.ZERO:
		killer = survivor_spawns[0] + Vector2(20 * GameConfig.TILE, 20 * GameConfig.TILE)

	return {"killer": killer, "survivors": survivor_spawns}
