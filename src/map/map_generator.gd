class_name MapGenerator
extends RefCounted
## Deterministic procedural level generation, structure-first.
##
## WHY THIS WAS REWRITTEN
## ----------------------
## The previous generator scattered random wall blobs across an open field. Measured
## on 6 seeds it produced realms that were 85% open floor with 0.3-0.6% corridor
## tiles, zero dead ends, and 11-17 pallets/windows sitting inside sealed pockets the
## player could never reach. That reads as "noise on a plane", not as a place: there
## is nothing to loop around, so every chase is a straight line, and a sixth of the
## vault points on the map are decorative.
##
## This version plans the realm the way the original's levels are actually laid out:
##
##   1. PLAN     the 80x80 grid is divided into 5x5 plots of 16x16 tiles, and each
##               plot is assigned a blueprint (main building / compound / jungle gym
##               / shed / open ground).
##   2. BUILD    each plot is constructed from that blueprint -- real wall rings with
##               doorways cut on purpose, an interior ring corridor to loop through,
##               windows punched through the outer wall only where both sides are
##               confirmed walkable.
##   3. DRESS    open ground gets cover *clusters* (L-shapes, short runs, 2x2 blocks)
##               rather than uniformly scattered noise.
##   4. PLACE    objectives are then sited against the structures: generators hug
##               building walls, hooks sit on open intersections, and every pallet
##               and window comes out of step 2 -- so they are reachable by
##               construction rather than by luck.
##
## GEOMETRY CONVENTION (important, and the source of two real bugs in the old code)
## -------------------------------------------------------------------------------
## `dir` / `direction` on a pallet or a window always means **the axis the obstacle
## runs along** -- i.e. the line of the wall or the span of the pallet. The direction
## of travel *across* it is therefore the perpendicular, which is what
## `landing_point()` computes:
##
##     normal = Vector2(-direction.y, direction.x)      # across, not along
##
## The old generator emitted a horizontal wall's window with direction (0,1), which
## put the landing point *along* the wall instead of through it, and gave pallets the
## direction of travel instead of the span -- so pallets were rotated 90 degrees and
## lay along the corridor instead of blocking it.

const F_FLOOR := 0
const F_WALL := 1

# --- plot planning ---------------------------------------------------------
const SECTION := 16          ## tiles per plot; 80 / 16 = a 5x5 grid
const K_OPEN := 0
const K_MAIN := 1            ## one per realm: the big loop
const K_COMPOUND := 2        ## mid-size building with a ring corridor
const K_GYM := 3             ## outdoor U-shaped wall with a pallet in the mouth
const K_SHED := 4            ## small one-room hut with one door and one window
const K_YARD := 5            ## dense outdoor cover: fence runs, blocks, corridors
const K_SHACK := 6           ## the killer shack: one door, one window beside it, a
                             ## pallet in the doorway and an empty interior -- the
                             ## single strongest loop the realm can offer

# --- placement rules -------------------------------------------------------
const GENERATOR_CLEARANCE := 2
const MIN_GENERATOR_DIST := 15.0
const HOOK_COUNT := 12       ## the original uses 12; 25 was absurd
const HOOK_MIN_DIST := 11.0
const PALLET_MIN_DIST := 2.5
## Gate vestibule size. The exit gate carves a real interior room this many tiles
## deep and this many tiles either side of centre -- a one-body corridor is not
## somewhere a survivor can stage, and the lever deserves open ground.
const GATE_ROOM_DEPTH := 6
const GATE_ROOM_HALF := 2

## How many floor variants the realm draws from. The tile atlas supplies six.
const GROUND_VARIANTS := 6


static func generate(seed_value: int, map_id: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	# Mix the realm id into the trial seed. Without this every realm drew the same
	# plot plan -- a side-by-side dump of all five maps showed identical openness,
	# generator spacing and corridor counts, i.e. the same place in different paint.
	rng.seed = seed_value ^ (hash(map_id) * 2654435761)

	var cfg := _config_for(map_id)
	var n: int = int(cfg.get("tiles", 80))
	var cols: int = maxi(3, n / SECTION)
	var rows: int = maxi(3, n / SECTION)

	var grid := _blank(n)
	_border(grid, n, 2)

	# ---- 1. plan the plots ------------------------------------------------
	var kinds := _plan_sections(cols, rows, rng, cfg.get("layout", {}))

	# ---- 2. build them ----------------------------------------------------
	var windows: Array = []
	var pallets: Array = []
	var buildings: Array = []      ## Rect2i footprints, used to site generators
	var lockers: Array = []
	var chests: Array = []
	var shacks: Array = []         ## the killer shack's footprint, checked by MapDump

	for sy in rows:
		for sx in cols:
			var kind: int = kinds[sy * cols + sx]
			match kind:
				K_MAIN:
					_build_main(grid, n, rng, sx * SECTION, sy * SECTION,
							windows, pallets, buildings, lockers)
				K_COMPOUND:
					_build_compound(grid, n, rng, sx * SECTION, sy * SECTION,
							windows, pallets, buildings, lockers)
				K_GYM:
					_build_gym(grid, n, rng, sx * SECTION, sy * SECTION,
							windows, pallets, buildings, lockers)
				K_SHED:
					_build_shed(grid, n, rng, sx * SECTION, sy * SECTION,
							windows, pallets, buildings, lockers)
				K_SHACK:
					_build_shack(grid, n, rng, sx * SECTION, sy * SECTION,
							windows, pallets, buildings, lockers, shacks)
				K_YARD:
					_build_open_ground(grid, n, rng, sx * SECTION, sy * SECTION,
							buildings, true)
				_:
					_build_open_ground(grid, n, rng, sx * SECTION, sy * SECTION,
							buildings, false)

	# Anything the survivors cannot walk to becomes solid. With structured plots this
	# should now be almost a no-op -- the previous generator leaned on it heavily.
	_seal_unreachable(grid, n)

	var result := {
		"size": n,
		"grid": grid,
		"ground": _build_ground_field(n, seed_value),
		"map_id": map_id,
		"cfg": cfg,
		"seed": seed_value,
		"kinds": kinds,
		"cols": cols,
		"shacks": shacks,
	}

	# ---- 3. objectives, sited against the structures ----------------------
	result["generators"] = _place_generators(grid, n, rng, buildings)
	result["gates"] = _place_gates(grid, n, rng, kinds, cols, rows)

	# ---- 4. loops ---------------------------------------------------------
	# Pallet/window *spots* come from the blueprints (verified walkable on both
	# sides). All that is left is to drop the ones that ended up crowded together.
	result["pallets"] = _thin(pallets, PALLET_MIN_DIST, rng)
	result["windows"] = _thin(windows, 3.0, rng)

	# Top up with outdoor pallets if the realm came out short, using genuine
	# pinch points (a wall stub with open floor on both sides).
	var want_pallets := int(cfg.get("pallet_count", 16))
	_add_outdoor_pallets(grid, n, rng, result["pallets"], want_pallets)

	result["hooks"] = _place_hooks(grid, n, rng, result["generators"])
	result["lockers"] = _place_against(grid, n, rng, lockers,
			int(cfg.get("locker_count", 6)))
	result["chests"] = _place_spread(grid, n, rng, int(cfg.get("chest_count", 3)), 1, 6.0)
	result["hatch"] = _pick_far_floor(grid, n, rng, result["generators"])
	result["spawns"] = _place_spawns(grid, n, rng, result["generators"], result["gates"])
	return result


# ---------------------------------------------------------------------------
# 1. Plot planning
# ---------------------------------------------------------------------------
static func _plan_sections(cols: int, rows: int, rng: RandomNumberGenerator,
		layout: Dictionary) -> Array:
	## Assigns a blueprint to every plot on the grid. The distribution is
	## deliberately lopsided -- a realm wants one landmark, a handful of buildings,
	## and enough open ground that crossing it is a real risk.
	var kinds: Array = []
	kinds.resize(cols * rows)
	kinds.fill(K_OPEN)

	var all: Array = []
	for y in rows:
		for x in cols:
			all.append(Vector2i(x, y))
	if all.is_empty():
		return kinds

	# --- the main building -------------------------------------------------
	var main_cell: Vector2i = all[rng.randi_range(0, all.size() - 1)]
	kinds[main_cell.y * cols + main_cell.x] = K_MAIN
	all.erase(main_cell)
	Utils.seeded_shuffle(all, rng)

	# --- the killer shack --------------------------------------------------
	# Always exactly one. It is the realm's second landmark and the place survivors
	# will run to when a chase goes bad, so the map is better off guaranteeing it
	# than leaving it to chance.
	var shack_cell := Vector2i(-1, -1)
	for c in all:
		if _plot_is_free(kinds, cols, rows, c, [K_MAIN], true):
			shack_cell = c
			break
	if shack_cell.x >= 0:
		kinds[shack_cell.y * cols + shack_cell.x] = K_SHACK

	# --- mid-size compounds ------------------------------------------------
	# Compounds are the backbone of the realm, so they get placed first and are
	# kept off each other's corners -- two big buildings sharing a diagonal leave
	# no corridor between them at all.
	var lc: Array = layout.get("compounds", [4, 6])
	var lg: Array = layout.get("gyms", [5, 7])
	var ls: Array = layout.get("sheds", [4, 6])

	var ci := 0
	var compounds := rng.randi_range(int(lc[0]), int(lc[1]))
	while compounds > 0 and ci < all.size():
		var c: Vector2i = all[ci]
		ci += 1
		if not _plot_is_free(kinds, cols, rows, c, [K_MAIN, K_COMPOUND], true):
			continue
		kinds[c.y * cols + c.x] = K_COMPOUND
		compounds -= 1

	# --- outdoor gyms ------------------------------------------------------
	# `ci` has to be rewound. The passes below used to carry on from wherever the
	# compound pass stopped, which was already at the end of `all` -- so gyms and
	# sheds were never placed at all (a plot census read gym=0, shed=0 on every
	# seed). Each pass now rescans from the top and simply skips plots that are
	# already taken, which is also the order the priorities were meant to express.
	ci = 0
	var gyms := rng.randi_range(int(lg[0]), int(lg[1]))
	while gyms > 0 and ci < all.size():
		var c: Vector2i = all[ci]
		ci += 1
		if not _plot_is_free(kinds, cols, rows, c, [K_MAIN], false):
			continue
		kinds[c.y * cols + c.x] = K_GYM
		gyms -= 1

	# --- sheds -------------------------------------------------------------
	ci = 0
	var sheds := rng.randi_range(int(ls[0]), int(ls[1]))
	while sheds > 0 and ci < all.size():
		var c: Vector2i = all[ci]
		ci += 1
		if not _plot_is_free(kinds, cols, rows, c, [K_MAIN], false):
			continue
		kinds[c.y * cols + c.x] = K_SHED
		sheds -= 1

	# --- yards -------------------------------------------------------------
	# Whatever is left over is not left empty. A realm that is 84% bare floor reads
	# as noise on a plane: there is no cover to break a sight line and no fence line
	# to run along, so every chase is a straight line. Half the remaining plots get
	# a dense field of orthogonal cover instead.
	var yard_chance := float(layout.get("yards", 0.72))
	for c in all:
		var ci2: int = c.y * cols + c.x
		if kinds[ci2] != K_OPEN:
			continue
		if rng.randf() < yard_chance:
			kinds[ci2] = K_YARD

	return kinds


static func _inside(c: Vector2i, cols: int, rows: int) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < cols and c.y < rows


static func _plot_is_free(kinds: Array, cols: int, rows: int, c: Vector2i,
		avoid: Array, diagonal: bool) -> bool:
	if not _inside(c, cols, rows) or kinds[c.y * cols + c.x] != K_OPEN:
		return false
	var dirs: Array = Utils.DIRS8 if diagonal else Utils.DIRS4
	for d in dirs:
		var nb := c + Vector2i(int(d.x), int(d.y))
		if not _inside(nb, cols, rows):
			continue
		if avoid.has(int(kinds[nb.y * cols + nb.x])):
			return false
	return true


# ---------------------------------------------------------------------------
# 2. Blueprints
# ---------------------------------------------------------------------------

## One per realm. A 14x14 wall ring with an interior ring corridor: survivors get a
## full loop around the outside, a second loop inside, three ways in, and two windows
## to cut through when a door is blocked.
static func _build_main(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		sx: int, sy: int, windows: Array, pallets: Array, buildings: Array,
		lockers: Array) -> void:
	# 13x13 leaves two tiles of corridor on every side of the plot, and the clamp
	# keeps it clear of the realm's border wall.
	var w := 13
	var h := 13
	var x0 := clampi(sx + rng.randi_range(1, 2), 2, n - w - 2)
	var y0 := clampi(sy + rng.randi_range(1, 2), 2, n - h - 2)
	_wall_ring(g, n, x0, y0, w, h)

	var doors: Array = []
	_cut_doors(g, n, rng, x0, y0, w, h, 3, doors)

	# Interior ring corridor: an inner box three tiles in, with gaps so you can
	# cross from the outer ring into the core and back without leaving the building.
	var ix := x0 + 3
	var iy := y0 + 3
	var iw := w - 6
	var ih := h - 6
	_wall_ring(g, n, ix, iy, iw, ih)
	for _k in 3:
		_gap_in_ring(g, n, rng, ix, iy, iw, ih)

	# A couple of pillars in the core, never big enough to seal it.
	_rect(g, n, ix + 2, iy + 2, 2, 2, F_WALL)

	# Two windows through the outer wall, on sides that have no door.
	_cut_windows(g, n, rng, x0, y0, w, h, doors, 2, windows)

	# One pallet in a doorway -- the front door can be slammed shut.
	if not doors.is_empty():
		var d: Dictionary = doors[rng.randi_range(0, doors.size() - 1)]
		pallets.append({"pos": d["pos"], "dir": d["axis"]})

	buildings.append(Rect2i(x0, y0, w, h))
	_inner_lockers(g, n, rng, ix, iy, iw, ih, lockers, 2)


## A mid-size building with a partition down the middle: two rooms, several doors,
## one window, and a full corridor around the outside.
static func _build_compound(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		sx: int, sy: int, windows: Array, pallets: Array, buildings: Array,
		lockers: Array) -> void:
	var w := rng.randi_range(10, 12)
	var h := rng.randi_range(10, 12)
	var x0 := clampi(sx + rng.randi_range(2, SECTION - w - 2), 2, n - w - 2)
	var y0 := clampi(sy + rng.randi_range(2, SECTION - h - 2), 2, n - h - 2)
	_wall_ring(g, n, x0, y0, w, h)

	var doors: Array = []
	_cut_doors(g, n, rng, x0, y0, w, h, rng.randi_range(2, 3), doors)

	# A partition with a wide gap, so the interior is two rooms you can cut through.
	if rng.randf() < 0.5:
		var px := x0 + w / 2
		for k in range(2, h - 2):
			set_at(g, n, px, y0 + k, F_WALL)
		var gap := rng.randi_range(3, h - 5)
		for k in range(gap, mini(gap + 2, h - 2)):
			set_at(g, n, px, y0 + k, F_FLOOR)
	else:
		var py := y0 + h / 2
		for k in range(2, w - 2):
			set_at(g, n, x0 + k, py, F_WALL)
		var gap := rng.randi_range(3, w - 5)
		for k in range(gap, mini(gap + 2, w - 2)):
			set_at(g, n, x0 + k, py, F_FLOOR)

	# One pillar, kept off-centre and small.
	_rect(g, n, x0 + rng.randi_range(3, w - 5), y0 + rng.randi_range(3, h - 5), 2, 2, F_WALL)

	_cut_windows(g, n, rng, x0, y0, w, h, doors, rng.randi_range(1, 2), windows)
	if not doors.is_empty():
		var d: Dictionary = doors[rng.randi_range(0, doors.size() - 1)]
		pallets.append({"pos": d["pos"], "dir": d["axis"]})

	buildings.append(Rect2i(x0, y0, w, h))
	_inner_lockers(g, n, rng, x0 + 1, y0 + 1, w - 2, h - 2, lockers, 1)


## The killer shack.
##
## The shape is the whole point, so none of it is randomised beyond where it sits
## and which way it faces:
##   * one door, one window, and the window is on a wall *adjacent* to the door --
##     adjacent produces a loop (vault out of the window, run the outside of the
##     building, come back in through the door, slam the pallet), whereas opposite
##     produces a straight line the killer simply walks down
##   * the interior is entirely empty, so the loop is about the walls, not furniture
##   * a pallet across the doorway, which is the shack pallet players fight over
static func _build_shack(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		sx: int, sy: int, windows: Array, pallets: Array, buildings: Array,
		lockers: Array, shacks: Array) -> void:
	var w := 9
	var h := 9
	var x0 := clampi(sx + rng.randi_range(3, maxi(3, SECTION - w - 3)), 2, n - w - 2)
	var y0 := clampi(sy + rng.randi_range(3, maxi(3, SECTION - h - 3)), 2, n - h - 2)
	_wall_ring(g, n, x0, y0, w, h)

	# --- the door ----------------------------------------------------------
	# Centred on its wall rather than random along it: a corner-adjacent door would
	# shorten the outside run and weaken the loop.
	var side := rng.randi_range(0, 3)
	var door_cell := Vector2i.ZERO
	var door_axis := Vector2(1, 0)
	match side:
		0:  # north
			door_cell = Vector2i(x0 + w / 2, y0)
			door_axis = Vector2(1, 0)
		1:  # east
			door_cell = Vector2i(x0 + w - 1, y0 + h / 2)
			door_axis = Vector2(0, 1)
		2:  # south
			door_cell = Vector2i(x0 + w / 2, y0 + h - 1)
			door_axis = Vector2(1, 0)
		_:  # west
			door_cell = Vector2i(x0, y0 + h / 2)
			door_axis = Vector2(0, 1)
	_clear(g, n, door_cell.x, door_cell.y, 1, 1)
	pallets.append({"pos": Utils.tile_center(door_cell), "dir": door_axis})

	# --- the window, on a wall next to the door ----------------------------
	var win_side := (side + (1 if rng.randf() < 0.5 else 3)) % 4
	var win_cell := Vector2i.ZERO
	var win_axis := Vector2(1, 0)
	var ok := false
	match win_side:
		0:
			win_cell = Vector2i(x0 + w / 2, y0)
			win_axis = Vector2(1, 0)
			ok = at(g, n, win_cell.x, win_cell.y - 1) == F_FLOOR \
					and at(g, n, win_cell.x, win_cell.y + 1) == F_FLOOR
		1:
			win_cell = Vector2i(x0 + w - 1, y0 + h / 2)
			win_axis = Vector2(0, 1)
			ok = at(g, n, win_cell.x - 1, win_cell.y) == F_FLOOR \
					and at(g, n, win_cell.x + 1, win_cell.y) == F_FLOOR
		2:
			win_cell = Vector2i(x0 + w / 2, y0 + h - 1)
			win_axis = Vector2(1, 0)
			ok = at(g, n, win_cell.x, win_cell.y - 1) == F_FLOOR \
					and at(g, n, win_cell.x, win_cell.y + 1) == F_FLOOR
		_:
			win_cell = Vector2i(x0, y0 + h / 2)
			win_axis = Vector2(0, 1)
			ok = at(g, n, win_cell.x - 1, win_cell.y) == F_FLOOR \
					and at(g, n, win_cell.x + 1, win_cell.y) == F_FLOOR
	if ok:
		windows.append({"pos": Utils.tile_center(win_cell), "dir": win_axis})

	buildings.append(Rect2i(x0, y0, w, h))
	shacks.append(Rect2i(x0, y0, w, h))
	# One locker, tucked against a wall: the shack is somewhere you hide *and*
	# somewhere you loop, and those are different decisions.
	_inner_lockers(g, n, rng, x0 + 1, y0 + 1, w - 2, h - 2, lockers, 1)


## An outdoor U-shaped wall (the original's "jungle gym"): three sides closed, the
## mouth sealed by a pallet. Survivors loop the inside and vault the window when the
## pallet is gone.
static func _build_gym(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		sx: int, sy: int, windows: Array, pallets: Array, buildings: Array,
		lockers: Array) -> void:
	var w := rng.randi_range(7, 10)
	var h := rng.randi_range(5, 7)
	var x0 := clampi(sx + rng.randi_range(3, SECTION - w - 3), 2, n - w - 2)
	var y0 := clampi(sy + rng.randi_range(3, SECTION - h - 3), 2, n - h - 2)

	# Top wall, plus the two side walls.
	for k in w:
		set_at(g, n, x0 + k, y0, F_WALL)
	for k in h:
		set_at(g, n, x0, y0 + k, F_WALL)
		set_at(g, n, x0 + w - 1, y0 + k, F_WALL)

	# Two stubs pinch the mouth down to a three-tile opening.
	var mouth := x0 + w / 2
	set_at(g, n, mouth - 2, y0 + h - 1, F_WALL)
	set_at(g, n, mouth + 2, y0 + h - 1, F_WALL)
	# The pallet spans the middle of that opening. `dir` is the span axis, so it runs
	# east-west and blocks north-south travel -- which is the way in.
	pallets.append({"pos": Utils.tile_center(Vector2i(mouth, y0 + h - 1)),
			"dir": Vector2(1, 0)})

	# A window through one side wall, in the middle where both sides are walkable.
	var side := rng.randi_range(0, 1)
	var wx := x0 if side == 0 else x0 + w - 1
	var wy := y0 + h / 2
	if at(g, n, wx - 1, wy) == F_FLOOR and at(g, n, wx + 1, wy) == F_FLOOR:
		windows.append({"pos": Utils.tile_center(Vector2i(wx, wy)), "dir": Vector2(0, 1)})

	buildings.append(Rect2i(x0, y0, w, h))
	if rng.randf() < 0.6:
		lockers.append(Utils.tile_center(Vector2i(x0 + 1, y0 + h - 2)))


## A one-room hut: one door, one window, somewhere to hide.
static func _build_shed(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		sx: int, sy: int, windows: Array, pallets: Array, buildings: Array,
		lockers: Array) -> void:
	var w := rng.randi_range(6, 8)
	var h := rng.randi_range(6, 8)
	var x0 := sx + rng.randi_range(3, SECTION - w - 3)
	var y0 := sy + rng.randi_range(3, SECTION - h - 3)
	if x0 + w >= n - 2 or y0 + h >= n - 2:
		return
	_wall_ring(g, n, x0, y0, w, h)

	var doors: Array = []
	_cut_doors(g, n, rng, x0, y0, w, h, 1, doors)
	_cut_windows(g, n, rng, x0, y0, w, h, doors, 1, windows)

	buildings.append(Rect2i(x0, y0, w, h))
	if rng.randf() < 0.7:
		lockers.append(Utils.tile_center(Vector2i(x0 + 1, y0 + 1)))


## Open ground is not empty ground. Every plot gets cover clusters; a "dense" plot --
## a yard -- gets a lot of them, and those are what turn the middle of a realm from a
## field you sprint across into ground you have to actually navigate.
static func _build_open_ground(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		sx: int, sy: int, buildings: Array, dense: bool) -> void:
	var clusters := rng.randi_range(6, 9) if dense else rng.randi_range(3, 4)
	var placed: Array = []
	var guard := 0
	while placed.size() < clusters and guard < 140:
		guard += 1
		# Start points stay clear of the plot edge so a yard can never fuse with
		# whatever the neighbouring plot built -- fusing is how corridors get sealed.
		var cx := sx + rng.randi_range(2, SECTION - 8)
		var cy := sy + rng.randi_range(2, SECTION - 8)
		var ok := true
		for p in placed:
			if absi(int(p.x) - cx) < 3 and absi(int(p.y) - cy) < 3:
				ok = false
				break
		if not ok:
			continue
		placed.append(Vector2i(cx, cy))
		_cover_cluster(g, n, rng, cx, cy)


## A single piece of cover. Every shape is orthogonal on purpose: cover that reads as
## a fence line or a collapsed wall is legible at a glance, which is exactly what a
## chase needs. Randomly rotated blocks just look like noise.
static func _cover_cluster(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		cx: int, cy: int) -> void:
	match rng.randi_range(0, 4):
		0:  # L-shaped cover -- two walls meeting, a classic juke corner
			var la := rng.randi_range(2, 4)
			var lb := rng.randi_range(2, 4)
			for k in la:
				set_at(g, n, cx + k, cy, F_WALL)
			for k in lb:
				set_at(g, n, cx, cy + k, F_WALL)
		1:  # a fence run to break a sight line
			var ln := rng.randi_range(3, 6)
			if rng.randf() < 0.5:
				for k in ln:
					set_at(g, n, cx + k, cy, F_WALL)
			else:
				for k in ln:
					set_at(g, n, cx, cy + k, F_WALL)
		2:  # a solid block
			_rect(g, n, cx, cy, 2, 2, F_WALL)
		3:  # parallel pair: a two-tile corridor you can actually run down
			var ln2 := rng.randi_range(3, 5)
			for k in ln2:
				set_at(g, n, cx + k, cy, F_WALL)
				set_at(g, n, cx + k, cy + 3, F_WALL)
		_:  # a fence with a gap in the middle -- a natural vault point
			var ln3 := rng.randi_range(4, 6)
			var hole := ln3 / 2
			for k in ln3:
				if k != hole:
					set_at(g, n, cx + k, cy, F_WALL)


# ---------------------------------------------------------------------------
# Wall construction helpers
# ---------------------------------------------------------------------------
static func _wall_ring(g: PackedByteArray, n: int, x0: int, y0: int, w: int, h: int) -> void:
	for x in range(x0, x0 + w):
		set_at(g, n, x, y0, F_WALL)
		set_at(g, n, x, y0 + h - 1, F_WALL)
	for y in range(y0, y0 + h):
		set_at(g, n, x0, y, F_WALL)
		set_at(g, n, x0 + w - 1, y, F_WALL)


## Opens `count` doorways on randomly chosen sides of a wall ring.
## Each entry handed back is {"pos": Vector2, "axis": Vector2} where `axis` is the
## wall's own direction -- which is exactly what a pallet wants for its `direction`.
static func _cut_doors(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		x0: int, y0: int, w: int, h: int, count: int, doors: Array) -> void:
	if w < 6 or h < 6:
		return
	var sides := [0, 1, 2, 3]
	Utils.seeded_shuffle(sides, rng)
	for i in mini(count, 4):
		match int(sides[i]):
			0:  # north
				var dx := x0 + rng.randi_range(2, w - 4)
				_clear(g, n, dx, y0, 2, 1)
				doors.append({"pos": Utils.tile_center(Vector2i(dx, y0)), "axis": Vector2(1, 0)})
			1:  # east
				var dy := y0 + rng.randi_range(2, h - 4)
				_clear(g, n, x0 + w - 1, dy, 1, 2)
				doors.append({"pos": Utils.tile_center(Vector2i(x0 + w - 1, dy)),
						"axis": Vector2(0, 1)})
			2:  # south
				var dx2 := x0 + rng.randi_range(2, w - 4)
				_clear(g, n, dx2, y0 + h - 1, 2, 1)
				doors.append({"pos": Utils.tile_center(Vector2i(dx2, y0 + h - 1)),
						"axis": Vector2(1, 0)})
			_:  # west
				var dy2 := y0 + rng.randi_range(2, h - 4)
				_clear(g, n, x0, dy2, 1, 2)
				doors.append({"pos": Utils.tile_center(Vector2i(x0, dy2)),
						"axis": Vector2(0, 1)})


## Punches windows through the outer wall. A window is only created where BOTH sides
## of that wall tile are confirmed walkable -- that is what makes the old generator's
## unreachable windows impossible now.
##
## `dir` is the wall's own axis (horizontal wall -> (1,0)), so `landing_point()`'s
## perpendicular lands the actor on the far side of the wall.
static func _cut_windows(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		x0: int, y0: int, w: int, h: int, doors: Array, count: int, windows: Array) -> void:
	if w < 7 or h < 7:
		return
	# Sides that already carry a door are less interesting to also put a window in.
	var blocked: Array = []
	for d in doors:
		var c := Utils.tile_of(d["pos"])
		if c.y == y0:
			blocked.append(0)
		elif c.x == x0 + w - 1:
			blocked.append(1)
		elif c.y == y0 + h - 1:
			blocked.append(2)
		elif c.x == x0:
			blocked.append(3)

	var sides := [0, 1, 2, 3]
	Utils.seeded_shuffle(sides, rng)
	var made := 0
	for s in sides:
		if made >= count:
			break
		if blocked.has(s):
			continue
		var ok := false
		var cell := Vector2i.ZERO
		var axis := Vector2.ONE
		match int(s):
			0:  # north wall, span runs east-west
				cell = Vector2i(x0 + w / 2, y0)
				axis = Vector2(1, 0)
				ok = at(g, n, cell.x, cell.y - 1) == F_FLOOR \
						and at(g, n, cell.x, cell.y + 1) == F_FLOOR
			1:  # east wall, span runs north-south
				cell = Vector2i(x0 + w - 1, y0 + h / 2)
				axis = Vector2(0, 1)
				ok = at(g, n, cell.x - 1, cell.y) == F_FLOOR \
						and at(g, n, cell.x + 1, cell.y) == F_FLOOR
			2:  # south wall
				cell = Vector2i(x0 + w / 2, y0 + h - 1)
				axis = Vector2(1, 0)
				ok = at(g, n, cell.x, cell.y - 1) == F_FLOOR \
						and at(g, n, cell.x, cell.y + 1) == F_FLOOR
			_:  # west wall
				cell = Vector2i(x0, y0 + h / 2)
				axis = Vector2(0, 1)
				ok = at(g, n, cell.x - 1, cell.y) == F_FLOOR \
						and at(g, n, cell.x + 1, cell.y) == F_FLOOR
		if not ok:
			continue
		# Keep windows off the realm's corners: a window carved into the very edge
		# tile reads as a hole in the border wall and can strand a vault in geometry.
		if cell.x <= 3 or cell.y <= 3 or cell.x >= n - 4 or cell.y >= n - 4:
			continue
		windows.append({"pos": Utils.tile_center(cell), "dir": axis})
		made += 1


## Opens a gap somewhere along one side of an interior wall ring.
static func _gap_in_ring(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		ix: int, iy: int, iw: int, ih: int) -> void:
	match rng.randi_range(0, 3):
		0:
			_clear(g, n, ix + rng.randi_range(2, iw - 4), iy, 2, 1)
		1:
			_clear(g, n, ix + iw - 1, iy + rng.randi_range(2, ih - 4), 1, 2)
		2:
			_clear(g, n, ix + rng.randi_range(2, iw - 4), iy + ih - 1, 2, 1)
		_:
			_clear(g, n, ix, iy + rng.randi_range(2, ih - 4), 1, 2)


static func _clear(g: PackedByteArray, n: int, x: int, y: int, w: int, h: int) -> void:
	_rect(g, n, x, y, w, h, F_FLOOR)


## Places lockers inside a structure, so hiding places live where you would hide.
static func _inner_lockers(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		x0: int, y0: int, w: int, h: int, lockers: Array, count: int) -> void:
	var guard := 0
	var made := 0
	while made < count and guard < 60:
		guard += 1
		var x := x0 + rng.randi_range(1, maxi(1, w - 2))
		var y := y0 + rng.randi_range(1, maxi(1, h - 2))
		if not _free(g, n, x, y, 1):
			continue
		lockers.append(Utils.tile_center(Vector2i(x, y)))
		made += 1


## Per-tile floor variant index, from a value-noise field.
##
## The renderer used to roll a fresh random variant for every tile, which turns the
## whole realm into television static -- no patch of ground is ever bigger than one
## tile. Sampling smooth noise instead makes like ground clump into patches several
## tiles across, which is what actually reads as terrain.
##
## The curve is biased towards variant 0 so the realm still has a dominant ground
## colour with the others appearing as patches on top of it.
static func _build_ground_field(n: int, seed_value: int) -> PackedByteArray:
	var nz := FastNoiseLite.new()
	nz.seed = seed_value
	nz.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	nz.frequency = 0.026
	nz.fractal_octaves = 3
	nz.fractal_gain = 0.5

	var out := PackedByteArray()
	out.resize(n * n)
	for y in n:
		for x in n:
			var v := nz.get_noise_2d(float(x), float(y))     # -1..1
			var t := clampf((v + 1.0) * 0.5, 0.0, 0.9999)
			t = pow(t, 1.6)
			out[y * n + x] = int(t * float(GROUND_VARIANTS))
	return out


# ---------------------------------------------------------------------------
# Terrain primitives
# ---------------------------------------------------------------------------
static func _config_for(map_id: String) -> Dictionary:
	if GameConfig.maps.has(map_id):
		return GameConfig.maps[map_id]
	var keys := GameConfig.maps.keys()
	if keys.is_empty():
		return {"tiles": 80, "pallet_count": 12, "window_count": 10,
				"locker_count": 6, "chest_count": 3}
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


static func _seal_unreachable(g: PackedByteArray, n: int) -> void:
	## Any pocket the survivors cannot walk to becomes solid so nothing gets stuck.
	##
	## The keep-set is the LARGEST connected floor region, not "the first floor tile
	## scanning row-major". Starting from the first tile used to land inside a stray
	## pocket behind a building on some seeds, the flood never reached the main area,
	## and the seal pass entombed the entire realm in walls (measured: 79.7% open
	## before the seal, 0.1% after).
	var seen := PackedByteArray()
	seen.resize(n * n)
	seen.fill(0)
	var best: Array[Vector2i] = []     ## cells of the largest region found so far
	var queue: Array[Vector2i] = []
	var cur: Array[Vector2i] = []
	for y in n:
		for x in n:
			var idx := y * n + x
			if g[idx] != F_FLOOR or seen[idx] == 1:
				continue
			# Flood this whole pocket, remembering its cells.
			cur.clear()
			queue.clear()
			queue.append(Vector2i(x, y))
			seen[idx] = 1
			while not queue.is_empty():
				var c: Vector2i = queue.pop_back()
				cur.append(c)
				for d in Utils.DIRS4:
					var nx := c.x + int(d.x)
					var ny := c.y + int(d.y)
					if nx < 0 or ny < 0 or nx >= n or ny >= n:
						continue
					var nidx := ny * n + nx
					if seen[nidx] == 1 or g[nidx] != F_FLOOR:
						continue
					seen[nidx] = 1
					queue.append(Vector2i(nx, ny))
			if cur.size() > best.size():
				best = cur.duplicate()

	# Everything outside the largest walkable region is entombed.
	var keep := PackedByteArray()
	keep.resize(n * n)
	keep.fill(0)
	for c in best:
		keep[c.y * n + c.x] = 1
	for y in n:
		for x in n:
			var idx := y * n + x
			if g[idx] == F_FLOOR and keep[idx] == 0:
				g[idx] = F_WALL


# ---------------------------------------------------------------------------
# Placement helpers
# ---------------------------------------------------------------------------
static func _free(g: PackedByteArray, n: int, x: int, y: int, margin: int) -> bool:
	for oy in range(-margin, margin + 1):
		for ox in range(-margin, margin + 1):
			if at(g, n, x + ox, y + oy) != F_FLOOR:
				return false
	return true


## Drops loop spots that landed too close to another of the same kind.
static func _thin(spots: Array, min_dist: float, rng: RandomNumberGenerator) -> Array:
	var out: Array = []
	var pool := spots.duplicate()
	Utils.seeded_shuffle(pool, rng)
	for s in pool:
		var p: Vector2 = s["pos"]
		var ok := true
		for q in out:
			if p.distance_to(q["pos"]) < min_dist * GameConfig.TILE:
				ok = false
				break
		if ok:
			out.append(s)
	return out


## Distance from a point to the nearest building footprint, in pixels.
static func _dist_to_buildings(p: Vector2, buildings: Array) -> float:
	var best := 1e9
	for r in buildings:
		var rect: Rect2i = r
		var a := Vector2(rect.position) * GameConfig.TILE
		var b := Vector2(rect.position + rect.size) * GameConfig.TILE
		var dx := maxf(maxf(a.x - p.x, 0.0), p.x - b.x)
		var dy := maxf(maxf(a.y - p.y, 0.0), p.y - b.y)
		best = minf(best, sqrt(dx * dx + dy * dy))
	return best


## Generators hug building walls, spread evenly, and never share a corner of the map.
static func _place_generators(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		buildings: Array) -> Array:
	var out: Array = []
	while out.size() < GameConfig.GENERATORS_TOTAL:
		var best := Vector2.ZERO
		var best_score := -1e9
		for _t in 240:
			var x := rng.randi_range(5, n - 6)
			var y := rng.randi_range(5, n - 6)
			if not _free(g, n, x, y, GENERATOR_CLEARANCE):
				continue
			var p := Utils.tile_center(Vector2i(x, y))
			var too_close := false
			for q in out:
				if p.distance_to(q) < MIN_GENERATOR_DIST * GameConfig.TILE:
					too_close = true
					break
			if too_close:
				continue
			# Hug the structure at roughly three tiles out: close enough to read as
			# "the generator by the shack", far enough that the wall is not in the
			# way of the repair animation.
			var d := _dist_to_buildings(p, buildings) / GameConfig.TILE
			var score := 0.0
			if d >= 1.0 and d <= 9.0:
				score = 20.0 - absf(d - 3.0) * 2.0
			else:
				score = -d
			score += rng.randf() * 2.0
			if score > best_score:
				best_score = score
				best = p
		if best_score <= -1e8:
			# Nothing scored at all: the map is too tight, give up gracefully.
			break
		out.append(best)
	return out


## Outdoor pallets at genuine pinch points: a wall stub with open floor on both ends.
static func _add_outdoor_pallets(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		spots: Array, want: int) -> void:
	if spots.size() >= want:
		return
	var cands: Array = []
	# Keep pallets off the realm's corners and away from the border wall: a board
	# jammed into a corner reads as a decoration, not a loop, and a board that
	# touches the border can seal a dead-end pocket.
	for y in range(8, n - 8):
		for x in range(8, n - 8):
			# The pallet goes on a walkable tile that is pinched between walls, so
			# dropping it actually seals a passage. `dir` is the pallet's span, which
			# is the axis of the walls flanking it.
			if at(g, n, x, y) != F_FLOOR:
				continue
			if at(g, n, x - 1, y) == F_WALL and at(g, n, x + 1, y) == F_WALL \
					and at(g, n, x, y - 1) == F_FLOOR and at(g, n, x, y + 1) == F_FLOOR:
				cands.append({"pos": Utils.tile_center(Vector2i(x, y)), "dir": Vector2(1, 0)})
			elif at(g, n, x, y - 1) == F_WALL and at(g, n, x, y + 1) == F_WALL \
					and at(g, n, x - 1, y) == F_FLOOR and at(g, n, x + 1, y) == F_FLOOR:
				cands.append({"pos": Utils.tile_center(Vector2i(x, y)), "dir": Vector2(0, 1)})
	Utils.seeded_shuffle(cands, rng)
	for c in cands:
		if spots.size() >= want:
			break
		var ok := true
		for s in spots:
			if c["pos"].distance_to(s["pos"]) < PALLET_MIN_DIST * GameConfig.TILE:
				ok = false
				break
		if ok:
			spots.append(c)


## Hooks on open intersections: the most connected tiles on the map, spread out.
static func _place_hooks(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		generators: Array) -> Array:
	var cands: Array = []
	for y in range(6, n - 6):
		for x in range(6, n - 6):
			if not _free(g, n, x, y, 2):
				continue
			var open := 0
			for oy in range(-2, 3):
				for ox in range(-2, 3):
					if at(g, n, x + ox, y + oy) == F_FLOOR:
						open += 1
			cands.append({"p": Utils.tile_center(Vector2i(x, y)), "open": open})
	# Busiest crossings first, so hooks end up where chases actually happen.
	cands.sort_custom(func(a, b) -> bool: return int(a["open"]) > int(b["open"]))

	for min_dist in [HOOK_MIN_DIST, HOOK_MIN_DIST * 0.75, HOOK_MIN_DIST * 0.55]:
		var out: Array = []
		# Guarantee coverage: seed one hook near every generator before spreading
		# the rest. Without this pass the hooks all clustered on the busiest
		# crossings and some generators ended up 30+ tiles from the nearest hook,
		# which makes the whole sacrifice loop unplayable on that side of the map.
		for gpos in generators:
			if out.size() >= HOOK_COUNT:
				break
			var best := Vector2.ZERO
			var best_score := -1e9
			for c in cands:
				var d: float = c["p"].distance_to(gpos) / GameConfig.TILE
				if d < 4.0 or d > 13.0:
					continue
				var score := -absf(d - 8.0) * 2.0 + float(c["open"]) * 0.2
				for h in out:
					score -= maxf(0.0, 12.0 - c["p"].distance_to(h) / GameConfig.TILE) * 3.0
				if score > best_score:
					best_score = score
					best = c["p"]
			if best_score > -1e8:
				out.append(best)
		for c in cands:
			if out.size() >= HOOK_COUNT:
				break
			var ok := true
			for h in out:
				if c["p"].distance_to(h) < min_dist * GameConfig.TILE:
					ok = false
					break
			if ok:
				out.append(c["p"])
		if out.size() >= HOOK_COUNT:
			return out
	return cands.slice(0, HOOK_COUNT).map(func(c: Dictionary) -> Vector2: return c["p"])


## Lockers that came out of the blueprints, padded out to the realm's quota.
static func _place_against(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		from_blueprints: Array, want: int) -> Array:
	var out: Array = []
	for p in from_blueprints:
		var c := Utils.tile_of(p)
		if _free(g, n, c.x, c.y, 1):
			out.append(p)
	if out.size() >= want:
		return out.slice(0, want)
	for p in _place_spread(g, n, rng, want - out.size(), 1, 5.0):
		out.append(p)
	return out


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


## Two gates carved into opposite edges, placed on whichever stretch of that edge is
## actually open ground -- the old version blindly carved a 7x7 hole and could punch
## straight through a building.
static func _place_gates(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		kinds: Array, cols: int, rows: int) -> Array:
	var gates: Array = []
	var mid := n / 2
	var used_y: Array = []

	for side in [0, 1]:
		var best_y := mid
		var best_score := -1e9
		for _t in 120:
			var y := mid + rng.randi_range(-(n / 2 - 8), (n / 2 - 8))
			var score := 0.0
			# Score the interior strip in front of the gate: it must be open.
			for dy in range(-GATE_ROOM_HALF, GATE_ROOM_HALF + 1):
				for dx in range(1, GATE_ROOM_DEPTH + 2):
					var xx := (1 + dx) if side == 0 else (n - 2 - dx)
					if at(g, n, xx, y + dy) == F_FLOOR:
						score += 1.0
			for uy in used_y:
				score -= maxf(0.0, 40.0 - absf(float(y - uy))) * 0.3
			if score > best_score:
				best_score = score
				best_y = y
		used_y.append(best_y)

		var cx := 1 if side == 0 else n - 2
		var inward := Vector2(1, 0) if side == 0 else Vector2(-1, 0)
		# Carve a real gate vestibule: the doorway itself, then an interior room of
		# GATE_ROOM_DEPTH tiles reaching GATE_ROOM_HALF tiles either side of centre.
		# The old version only widened a 3-tile slot, which left survivors nowhere
		# to stage and the lever sitting in a one-body corridor.
		_rect(g, n, cx - 1, best_y - 1, 3, 3, F_FLOOR)
		for k in range(1, GATE_ROOM_DEPTH + 1):
			var ax := cx + int(inward.x) * k
			# Never carve the border wall itself (x = 0 / n-1).
			var x0 := maxi(1, ax - GATE_ROOM_HALF)
			var x1 := mini(n - 2, ax + GATE_ROOM_HALF)
			_rect(g, n, x0, best_y - GATE_ROOM_HALF, x1 - x0 + 1,
					GATE_ROOM_HALF * 2 + 1, F_FLOOR)
		set_at(g, n, cx, best_y, F_FLOOR)
		gates.append({
			"pos": Utils.tile_center(Vector2i(cx, best_y)),
			"dir": inward,
		})
	return gates


static func _pick_far_floor(g: PackedByteArray, n: int, rng: RandomNumberGenerator,
		generators: Array) -> Vector2:
	var best := Vector2.ZERO
	var best_score := -1.0
	for _i in 600:
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

	# The killer starts as far from the group as the realm allows.
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
