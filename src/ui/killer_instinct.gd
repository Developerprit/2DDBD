class_name KillerInstinct
extends Control
## Objective pointers for the killer, drawn over the HUD.
##
## The original gives the killer a pull toward "something is happening over there".
## Without it a human has no way to know which of five generators is being worked on,
## and a trial degenerates into wandering. The bots get that information from their
## decision layer; this hands the same information to the player, as arrows pinned to
## the edge of the screen.
##
## Only the killer gets these. A survivor's entire game is *not* knowing where the
## killer and the objectives stand, so this must never be shown to them.
##
## Target priority, highest first:
##   1. a survivor on a hook           (the only thing that can end a trial)
##   2. the open hatch                 (a free escape, gone the moment they take it)
##   3. powered exit gates
##   4. generators somebody is working (weighted by how far along they are)

const MARGIN := 34.0
const MAX_TARGETS := 6

var _pulse := 0.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)


func _process(delta: float) -> void:
	_pulse += delta
	# Nothing to do, and nothing to draw, unless the local player is the killer.
	var mc := MatchController.instance
	var is_killer := mc != null and mc.local_actor != null \
			and is_instance_valid(mc.local_actor) and mc.local_actor.is_in_group("killer")
	visible = is_killer
	if is_killer:
		queue_redraw()


func _draw() -> void:
	var mc := MatchController.instance
	if mc == null or mc.local_actor == null or not is_instance_valid(mc.local_actor):
		return
	var cam := get_viewport().get_camera_2d()
	if cam == null:
		return

	var vp := get_viewport_rect().size
	# World -> screen. Godot 4 removed Camera2D.unproject_position() (that was a
	# Godot 3 API); the viewport's canvas transform is the replacement, and it is
	# what maps world space onto the CanvasLayer this Control draws in.
	var canvas_xform := get_viewport().get_canvas_transform()
	for t in _targets(mc):
		var sp: Vector2 = canvas_xform * (t["pos"] as Vector2)
		var col: Color = t["color"]
		var size: float = float(t.get("size", 1.0))
		var inside := sp.x > MARGIN and sp.y > MARGIN \
				and sp.x < vp.x - MARGIN and sp.y < vp.y - MARGIN
		if inside:
			_draw_marker(sp, col, size)
		else:
			# `local_actor` is an untyped Node, so the geometry has to be read
			# through a Node2D cast or GDScript cannot infer the float.
			var who := mc.local_actor as Node2D
			var dist_m := 0.0
			if who != null:
				dist_m = who.global_position.distance_to(t["pos"]) / float(GameConfig.TILE)
			_draw_edge_arrow(sp, vp, col, dist_m)


func _targets(mc: MatchController) -> Array:
	var out: Array = []

	# 1. Someone on a hook.
	for sv in mc.survivors:
		if not is_instance_valid(sv):
			continue
		if sv.health == Enums.Health.HOOKED:
			out.append({"pos": sv.global_position, "color": Color(0.92, 0.24, 0.22),
					"pri": 100.0, "size": 1.35})

	# 2. The hatch, once it is open: a free escape the killer must contest now.
	if mc.hatch_node != null and is_instance_valid(mc.hatch_node) and mc.hatch_node.is_open:
		out.append({"pos": mc.hatch_node.global_position, "color": Color(0.80, 0.42, 0.95),
				"pri": 90.0, "size": 1.2})

	# 3. Powered gates.
	if mc.exit_powered:
		for e in mc.exit_gates:
			if is_instance_valid(e):
				out.append({"pos": e.global_position, "color": Color(0.36, 0.90, 0.46),
						"pri": 72.0, "size": 1.1})

	# 4. Generators with progress on them. This is the one that matters most in
	#    practice: progress is invisible from across the realm, and it is the whole
	#    reason to walk somewhere.
	for g in mc.generators:
		if not is_instance_valid(g) or g.completed:
			continue
		var p: float = clampf(g.progress, 0.0, 1.0)
		if p < 0.04:
			continue
		out.append({"pos": g.global_position, "color": Color(0.98, 0.78, 0.26),
				"pri": 40.0 + p * 40.0, "size": 0.6 + p * 1.1})

	out.sort_custom(func(a, b) -> bool: return float(a["pri"]) > float(b["pri"]))
	return out.slice(0, MAX_TARGETS)


## A target that is already on screen: a diamond, so it reads as "here" rather than
## as another thing to walk to.
func _draw_marker(sp: Vector2, col: Color, scale: float) -> void:
	var r := 4.0 * scale
	var c := Color(col.r, col.g, col.b, 0.55 + 0.25 * sin(_pulse * 4.0) * 0.5 + 0.2)
	draw_colored_polygon(PackedVector2Array([
		sp + Vector2(0, -r), sp + Vector2(r, 0),
		sp + Vector2(0, r), sp + Vector2(-r, 0)]), c)
	draw_arc(sp, r + 4.0, 0.0, TAU, 16, Color(c.r, c.g, c.b, 0.28), 1.0)


## A target off screen: an arrow pinned to the safe rectangle, pointing at it, with
## the distance in metres underneath.
func _draw_edge_arrow(sp: Vector2, vp: Vector2, col: Color, dist_m: float) -> void:
	var center := vp * 0.5
	var dir := sp - center
	if dir.length() < 1.0:
		return
	dir = dir.normalized()

	# Slide along the ray from the screen centre until it meets the safe rectangle.
	var t := 1e9
	if absf(dir.x) > 0.001:
		t = minf(t, (center.x - MARGIN) / absf(dir.x))
	if absf(dir.y) > 0.001:
		t = minf(t, (center.y - MARGIN) / absf(dir.y))
	var edge := center + dir * t

	var pulse := 0.78 + 0.22 * sin(_pulse * 5.0)
	var c := Color(col.r, col.g, col.b, col.a * pulse)
	var tip := edge + dir * 12.0
	var l := edge + dir.rotated(2.3) * 9.0
	var r := edge + dir.rotated(-2.3) * 9.0
	draw_colored_polygon(PackedVector2Array([tip, l, r]), c)
	draw_arc(edge, 6.0, 0.0, TAU, 14, Color(c.r, c.g, c.b, c.a * 0.35), 1.0)

	# Distance, so the arrow is actionable rather than just a direction.
	var f := get_theme_default_font()
	if f != null:
		var label := "%dm" % int(round(dist_m))
		var text_size := f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 9)
		var anchor := edge - dir * 16.0 - Vector2(text_size.x * 0.5, -text_size.y * 0.25)
		draw_string(f, anchor, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 9,
				Color(c.r, c.g, c.b, c.a * 0.9))
