class_name MapDump
extends RefCounted
## Development tool: renders a generated realm to a PNG so the layout can
## actually be looked at, and prints a readability report to stdout.
##
## Reachable from the command line with:
##     Godot --headless res://scenes/match.tscn -- --dump-map [--map <id>]
##
## This exists because "the map feels wrong" is impossible to act on from
## code alone -- you have to see the thing.

const CELL := 6  ## pixels per tile in the dump


static func render(map_data: Dictionary, mc: MatchController, path: String) -> void:
	var n := int(map_data["size"])
	var grid: PackedByteArray = map_data["grid"]
	var cfg: Dictionary = map_data.get("cfg", {})
	var pal: Dictionary = cfg.get("palette", {})

	var img := Image.create(n * CELL, n * CELL, false, Image.FORMAT_RGBA8)

	var floor_col := Color(str(pal.get("ground2", "#33332a")))
	var wall_col := Color(str(pal.get("wall", "#16150f")))
	var detail_col := Color(str(pal.get("detail", "#5a4a30")))

	# --- terrain -----------------------------------------------------------
	# Shaded by the same noise field the renderer uses, so the preview shows the
	# ground patches rather than hiding them under per-tile noise.
	var ground: PackedByteArray = map_data.get("ground", PackedByteArray())
	for y in n:
		for x in n:
			var col := floor_col
			if grid[y * n + x] == MapGenerator.F_WALL:
				col = wall_col
			else:
				var gi := 0
				if not ground.is_empty() and y * n + x < ground.size():
					gi = int(ground[y * n + x])
				col = floor_col.lerp(detail_col, float(gi) / 5.0 * 0.55)
			_fill(img, x * CELL, y * CELL, col)

	# --- the killer shack, outlined ----------------------------------------
	# It is the one structure whose *shape* matters (one door, one window beside
	# it, empty inside), so the preview frames the building itself. Without this a
	# 9x9 empty square is easy to mistake for a compound in a 512 px thumbnail.
	for r in map_data.get("shacks", []):
		var rect: Rect2i = r
		var col := Color(1.0, 0.36, 0.08)
		for k in rect.size.x:
			_px(img, (rect.position.x + k) * CELL, rect.position.y * CELL, col)
			_px(img, (rect.position.x + k) * CELL,
					(rect.position.y + rect.size.y) * CELL - 1, col)
		for k in rect.size.y:
			_px(img, rect.position.x * CELL, (rect.position.y + k) * CELL, col)
			_px(img, (rect.position.x + rect.size.x) * CELL - 1,
					(rect.position.y + k) * CELL, col)

	# --- helpers -----------------------------------------------------------
	var put := func(pos: Vector2, col: Color, r: int) -> void:
		var tx := int(pos.x / GameConfig.TILE)
		var ty := int(pos.y / GameConfig.TILE)
		for oy in range(-r, r + 1):
			for ox in range(-r, r + 1):
				if ox * ox + oy * oy > r * r + 1:
					continue
				_px(img, tx * CELL + CELL / 2 + ox, ty * CELL + CELL / 2 + oy, col)

	# --- objectives (big, so distribution is obvious) ----------------------
	for g in map_data.get("generators", []):
		put.call(g, Color(1.0, 0.82, 0.20), 3)
	for h in map_data.get("hooks", []):
		put.call(h, Color(0.80, 0.16, 0.16), 2)
	for g in map_data.get("gates", []):
		put.call(g["pos"], Color(0.30, 0.95, 0.40), 4)
	put.call(map_data.get("hatch", Vector2.ZERO), Color(0.85, 0.30, 0.90), 3)
	for p in map_data.get("pallets", []):
		put.call(p["pos"], Color(0.35, 0.75, 1.0), 2)
	for w in map_data.get("windows", []):
		put.call(w["pos"], Color(0.95, 0.98, 1.0), 2)
	for l in map_data.get("lockers", []):
		put.call(l, Color(0.70, 0.55, 0.95), 2)
	for c in map_data.get("chests", []):
		put.call(c, Color(1.0, 0.55, 0.15), 2)

	var spawns: Dictionary = map_data.get("spawns", {})
	for s in spawns.get("survivors", []):
		put.call(s, Color(0.85, 0.85, 0.85), 2)
	put.call(spawns.get("killer", Vector2.ZERO), Color(0.45, 0.10, 0.10), 3)

	img.save_png(path)
	print("[dump] wrote %s (%dx%d)" % [path, img.get_width(), img.get_height()])


static func _fill(img: Image, x0: int, y0: int, col: Color) -> void:
	for y in range(y0, y0 + CELL):
		for x in range(x0, x0 + CELL):
			img.set_pixel(x, y, col)


static func _px(img: Image, x: int, y: int, col: Color) -> void:
	if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
		return
	img.set_pixel(x, y, col)


# ---------------------------------------------------------------------------
# Readability report
# ---------------------------------------------------------------------------
static func report(map_data: Dictionary, mc: MatchController) -> void:
	var n := int(map_data["size"])
	var grid: PackedByteArray = map_data["grid"]

	var walls := 0
	for v in grid:
		if v == MapGenerator.F_WALL:
			walls += 1
	var open_ratio := 1.0 - float(walls) / float(n * n)

	# Walkable area actually reachable from the survivors' spawn corner.
	var seen := _flood(grid, n)
	var reachable := 0
	for v in seen:
		if v == 1:
			reachable += 1

	var gens: Array = map_data.get("generators", [])
	var hooks: Array = map_data.get("hooks", [])
	var loops: int = (map_data.get("pallets", []) as Array).size() \
			+ (map_data.get("windows", []) as Array).size()

	print("[map] %s  %dx%d  open=%.1f%%  reachable=%.1f%%" % [map_data.get("map_id", "?"),
			n, n, open_ratio * 100.0, float(reachable) / float(n * n) * 100.0])
	# Plot census. A realm wants exactly one main building and exactly one shack;
	# both are gameplay guarantees, so they get counted rather than eyeballed.
	var kinds2: Array = map_data.get("kinds", [])
	if not kinds2.is_empty():
		var labels := [
			["main", MapGenerator.K_MAIN], ["shack", MapGenerator.K_SHACK],
			["compound", MapGenerator.K_COMPOUND], ["gym", MapGenerator.K_GYM],
			["shed", MapGenerator.K_SHED], ["yard", MapGenerator.K_YARD],
			["open", MapGenerator.K_OPEN],
		]
		var census: Array = []
		for pair in labels:
			var c := 0
			for v in kinds2:
				if int(v) == int(pair[1]):
					c += 1
			census.append("%s=%d" % [pair[0], c])
		print("[map] plots: %s" % ", ".join(census))

	print("[map] shack: %s" % _check_shack(map_data))

	print("[map] generators=%d hooks=%d loops=%d (pallet+window) lockers=%d chests=%d gates=%d"
			% [gens.size(), hooks.size(), loops, map_data.get("lockers", []).size(),
			map_data.get("chests", []).size(), map_data.get("gates", []).size()])

	# Every objective must be walkable and reachable, or the match is a lottery.
	var bad := 0
	# Third field marks objects that legitimately live *inside* a wall tile.
	var entries: Array = []
	for g in gens:
		entries.append(["generator", g, false])
	for h in hooks:
		entries.append(["hook", h, false])
	for p in map_data.get("pallets", []):
		entries.append(["pallet", p["pos"], false])
	for w in map_data.get("windows", []):
		entries.append(["window", w["pos"], true])
	for l in map_data.get("lockers", []):
		entries.append(["locker", l, false])
	for c in map_data.get("chests", []):
		entries.append(["chest", c, false])
	for s in map_data.get("spawns", {}).get("survivors", []):
		entries.append(["spawn", s, false])
	entries.append(["hatch", map_data.get("hatch", Vector2.ZERO), false])
	for e in map_data.get("gates", []):
		entries.append(["gate", e["pos"], false])

	var unreachable: Dictionary = {}
	for e in entries:
		var cell := Utils.tile_of(e[1])
		var ok := false
		if bool(e[2]):
			# A window is punched through a wall, so its own tile is solid by design.
			# What has to hold is that at least two flanks are reachable floor -- that
			# is what the actor vaults between.
			var flanks := 0
			for d in Utils.DIRS4:
				var nx := cell.x + int(d.x)
				var ny := cell.y + int(d.y)
				if nx < 0 or ny < 0 or nx >= n or ny >= n:
					continue
				if grid[ny * n + nx] == MapGenerator.F_FLOOR and seen[ny * n + nx] == 1:
					flanks += 1
			ok = flanks >= 2
		else:
			ok = cell.x >= 0 and cell.y >= 0 and cell.x < n and cell.y < n \
					and grid[cell.y * n + cell.x] == MapGenerator.F_FLOOR \
					and seen[cell.y * n + cell.x] == 1
		if not ok:
			bad += 1
			unreachable[str(e[0])] = int(unreachable.get(str(e[0]), 0)) + 1
	print("[map] unreachable objects: %d %s" % [bad, unreachable if bad > 0 else ""])

	# Generator spacing: too tight and the killer can defend everything at once.
	var min_gen := 1e9
	for i in gens.size():
		for j in range(i + 1, gens.size()):
			min_gen = minf(min_gen, gens[i].distance_to(gens[j]) / GameConfig.TILE)
	print("[map] closest generator pair: %.1f tiles" % min_gen)

	# Hook coverage: the distance from every generator to its nearest hook.
	var worst_hook := 0.0
	for g in gens:
		var d := 1e9
		for h in hooks:
			d = minf(d, g.distance_to(h) / GameConfig.TILE)
		worst_hook = maxf(worst_hook, d)
	print("[map] worst generator->nearest hook: %.1f tiles" % worst_hook)

	# Dead ends: walkable tiles with only one walkable neighbour. A map that is
	# mostly dead ends plays badly -- nothing to loop.
	var dead_ends := 0
	var corridors := 0
	for y in range(1, n - 1):
		for x in range(1, n - 1):
			if grid[y * n + x] != MapGenerator.F_FLOOR:
				continue
			var open := 0
			for d in Utils.DIRS4:
				if grid[(y + int(d.y)) * n + (x + int(d.x))] == MapGenerator.F_FLOOR:
					open += 1
			if open <= 1:
				dead_ends += 1
			elif open == 2:
				corridors += 1
	print("[map] dead ends=%d  corridor tiles=%d  (%.1f%% / %.1f%%)"
			% [dead_ends, corridors,
			float(dead_ends) / float(n * n) * 100.0, float(corridors) / float(n * n) * 100.0])

	# Openness: the mean distance from a walkable tile to the nearest wall. This is
	# the metric that actually tracks "the map feels empty" -- raw open-percentage
	# does not, because a building is hollow and its floor is still walkable.
	var dist := _wall_distance(grid, n)
	var total := 0.0
	var count := 0
	var worst := 0
	for y in n:
		for x in n:
			if grid[y * n + x] != MapGenerator.F_FLOOR or seen[y * n + x] != 1:
				continue
			var d := dist[y * n + x]
			total += float(d)
			count += 1
			worst = maxi(worst, d)
	if count > 0:
		print("[map] openness: mean wall distance %.1f tiles (max %d) over %d walkable tiles"
				% [total / float(count), worst, count])

	_report_vault_geometry(map_data)


## Vault geometry. Every vault point is checked from both sides: the landing point
## must be on the OPPOSITE side of the obstacle from where the actor came, and far
## enough past it to have actually cleared it.
##
## This exists because the side term in landing_point() was once added instead of
## subtracted. The only symptom was a player pressing vault and being shoved one step
## backwards, which no other check in this file could have caught.
static func _report_vault_geometry(map_data: Dictionary) -> void:
	var total := 0
	var bad := 0
	for entry in map_data.get("windows", []):
		total += 1
		if not _check_vault(entry["pos"], entry["dir"], true):
			bad += 1
	for entry in map_data.get("pallets", []):
		total += 1
		if not _check_vault(entry["pos"], entry["dir"], false):
			bad += 1
	print("[map] vault landing: %d/%d correct%s" % [total - bad, total,
			"" if bad == 0 else "   <-- BROKEN"])


## The killer shack's value is entirely in its shape, and a shape is exactly the
## kind of thing that silently rots as the generator is edited, so it is asserted:
##   * exactly one shack
##   * exactly one window, and it is on a wall adjacent to the door (never opposite,
##     which would turn the loop into a straight line)
##   * a pallet across the doorway
##   * a completely empty interior
static func _check_shack(map_data: Dictionary) -> String:
	var shacks: Array = map_data.get("shacks", [])
	var n := int(map_data["size"])
	var grid: PackedByteArray = map_data["grid"]
	if shacks.is_empty():
		return "NONE  <-- BROKEN"
	if shacks.size() > 1:
		return "%d shacks  <-- BROKEN" % shacks.size()

	var rect: Rect2i = shacks[0]
	var wins := 0
	var win_cell := Vector2i(-1, -1)
	for w in map_data.get("windows", []):
		var c := Utils.tile_of(w["pos"])
		if rect.has_point(c):
			wins += 1
			win_cell = c
	var pals := 0
	var pal_cell := Vector2i(-1, -1)
	for p in map_data.get("pallets", []):
		var c := Utils.tile_of(p["pos"])
		if rect.has_point(c):
			pals += 1
			pal_cell = c

	# Count the openings in the wall ring itself.
	var openings := 0
	var openings_at: Array = []
	for x in range(rect.position.x, rect.position.x + rect.size.x):
		for y in [rect.position.y, rect.position.y + rect.size.y - 1]:
			if MapGenerator.at(grid, n, x, y) != MapGenerator.F_WALL:
				openings += 1
				openings_at.append(Vector2i(x, y))
	for y in range(rect.position.y + 1, rect.position.y + rect.size.y - 1):
		for x in [rect.position.x, rect.position.x + rect.size.x - 1]:
			if MapGenerator.at(grid, n, x, y) != MapGenerator.F_WALL:
				openings += 1
				openings_at.append(Vector2i(x, y))

	# Interior must be entirely walkable.
	var solid_inside := 0
	for y in range(rect.position.y + 1, rect.position.y + rect.size.y - 1):
		for x in range(rect.position.x + 1, rect.position.x + rect.size.x - 1):
			if MapGenerator.at(grid, n, x, y) == MapGenerator.F_WALL:
				solid_inside += 1

	# A window is punched INTO a solid wall tile -- it is not a hole in the grid,
	# it is a tile you vault. So the ring must have exactly one grid opening (the
	# door), and the window tile must still read as a wall.
	var win_is_wall := MapGenerator.at(grid, n, win_cell.x, win_cell.y) \
			== MapGenerator.F_WALL

	# The window must be adjacent to the door, not opposite it. "Adjacent" is
	# judged on which wall each sits on: the two walls must be perpendicular.
	var door_cell: Vector2i = openings_at[0] if not openings_at.is_empty() else pal_cell
	var door_wall := -1
	if door_cell.x == rect.position.x:
		door_wall = 3
	elif door_cell.x == rect.position.x + rect.size.x - 1:
		door_wall = 1
	elif door_cell.y == rect.position.y:
		door_wall = 0
	elif door_cell.y == rect.position.y + rect.size.y - 1:
		door_wall = 2
	var win_wall := -1
	if win_cell.x == rect.position.x:
		win_wall = 3
	elif win_cell.x == rect.position.x + rect.size.x - 1:
		win_wall = 1
	elif win_cell.y == rect.position.y:
		win_wall = 0
	elif win_cell.y == rect.position.y + rect.size.y - 1:
		win_wall = 2
	var adjacent := door_wall >= 0 and win_wall >= 0 and (door_wall % 2) != (win_wall % 2)

	var ok: bool = wins == 1 and pals == 1 and solid_inside == 0 \
			and openings == 1 and win_is_wall and adjacent
	return "%dx%d at %s  windows=%d(on wall=%s) pallets=%d door/ring openings=%d interior solid=%d window-wall=%s  %s" \
			% [rect.size.x, rect.size.y, str(rect.position), wins, str(win_is_wall),
			pals, openings, solid_inside, "adjacent" if adjacent else "OPPOSITE/BAD",
			"PASS" if ok else "FAIL"]


## Exercises the real landing_point() on a throwaway instance rather than re-deriving
## the maths here, so the test cannot drift away from the code it is testing.
static func _check_vault(pos: Vector2, dir: Vector2, is_window: bool) -> bool:
	var normal := Vector2(-dir.y, dir.x)
	for s in [-1.0, 1.0]:
		var from: Vector2 = pos + normal * s * GameConfig.TILE * 1.2
		var landing: Vector2
		if is_window:
			var w := WindowVault.new()
			w.direction = dir
			w.global_position = pos
			landing = w.landing_point(from)
			w.free()
		else:
			var pl := Pallet.new()
			pl.direction = dir
			pl.global_position = pos
			landing = pl.landing_point(from)
			pl.free()
		# Must end up opposite the side we approached from...
		if not is_equal_approx(signf((landing - pos).dot(normal)), -s):
			return false
		# ...and more than one tile past the obstacle's line, or we never cleared it.
		if absf((landing - pos).dot(normal)) < GameConfig.TILE * 1.5:
			return false
	return true


static func _flood(grid: PackedByteArray, n: int) -> PackedByteArray:
	var seen := PackedByteArray()
	seen.resize(n * n)
	seen.fill(0)
	# start from the first floor tile of the map's interior
	var start := Vector2i(-1, -1)
	for y in n:
		for x in n:
			if grid[y * n + x] == MapGenerator.F_FLOOR:
				start = Vector2i(x, y)
				break
		if start.x >= 0:
			break
	if start.x < 0:
		return seen
	var queue: Array[Vector2i] = [start]
	seen[start.y * n + start.x] = 1
	while not queue.is_empty():
		var c: Vector2i = queue.pop_back()
		for d in Utils.DIRS4:
			var nx := c.x + int(d.x)
			var ny := c.y + int(d.y)
			if nx < 0 or ny < 0 or nx >= n or ny >= n:
				continue
			if seen[ny * n + nx] == 1 or grid[ny * n + nx] == MapGenerator.F_WALL:
				continue
			seen[ny * n + nx] = 1
			queue.append(Vector2i(nx, ny))
	return seen


## Multi-source BFS out from every wall tile: the result is, for each tile, how far
## it is from the nearest cover.
static func _wall_distance(grid: PackedByteArray, n: int) -> PackedInt32Array:
	var dist := PackedInt32Array()
	dist.resize(n * n)
	dist.fill(-1)
	var queue: Array[Vector2i] = []
	for y in n:
		for x in n:
			if grid[y * n + x] == MapGenerator.F_WALL:
				dist[y * n + x] = 0
				queue.append(Vector2i(x, y))
	var head := 0
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		var d := dist[c.y * n + c.x]
		for dir in Utils.DIRS4:
			var nx := c.x + int(dir.x)
			var ny := c.y + int(dir.y)
			if nx < 0 or ny < 0 or nx >= n or ny >= n:
				continue
			if dist[ny * n + nx] != -1:
				continue
			dist[ny * n + nx] = d + 1
			queue.append(Vector2i(nx, ny))
	return dist
