class_name KillerInstinct
extends Control
## Killer Instinct — the orange "spiderweb" reveal from the original.
##
## An earlier version of this file pointed at four things: hooked survivors, the
## open hatch, powered gates and any generator with progress on it. Two of those
## were actively wrong. In the original, Killer Instinct reveals *Survivors only*,
## and only for as long as a Killer Power has flushed them out — it is explicitly
## not aura reading (a locker does not hide you from it, but a locker does not
## trigger it either). Marking generators told the killer exactly which of five
## generators was being worked on, and marking the hatch handed over the one thing
## survivors are meant to have to search for. Both destroyed the whole stealth
## half of the game.
##
## So the rules here are:
##   * survivors only, never an object
##   * only survivors a power just revealed (Killer.instinct_reveal)
##   * following them while the reveal lasts, through walls and lockers
##
## Navigation is the minimap's job, not this control's.

const MARGIN := 34.0

var _pulse := 0.0
var _triggers := 0
var _flash := 0.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)


func _process(delta: float) -> void:
	_pulse += delta
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta)
	# Nothing to do, and nothing to draw, unless the local player is the killer.
	var k := _local_killer()
	if k == null:
		visible = false
		return
	visible = true
	# A fresh reveal snaps the whole overlay to full strength, so a trigger is felt
	# rather than having to be noticed.
	if k.instinct_trigger_count != _triggers:
		_triggers = k.instinct_trigger_count
		_flash = 0.45
	queue_redraw()


func _local_killer() -> Killer:
	var mc := MatchController.instance
	if mc == null or mc.local_actor == null or not is_instance_valid(mc.local_actor):
		return null
	if not mc.local_actor.is_in_group("killer"):
		return null
	return mc.local_actor as Killer


func _draw() -> void:
	var k := _local_killer()
	if k == null:
		return
	var cam := get_viewport().get_camera_2d()
	if cam == null:
		return

	var vp := get_viewport_rect().size
	# World -> screen. Godot 4 removed Camera2D.unproject_position() (that was a
	# Godot 3 API); the viewport's canvas transform is the replacement, and it is
	# what maps world space onto the CanvasLayer this Control draws in.
	var canvas_xform := get_viewport().get_canvas_transform()
	for sv in k.instinct_active():
		var who := sv as Node2D
		if who == null or not is_instance_valid(who):
			continue
		var sp: Vector2 = canvas_xform * who.global_position
		var inside := sp.x > MARGIN and sp.y > MARGIN \
				and sp.x < vp.x - MARGIN and sp.y < vp.y - MARGIN
		if inside:
			_draw_web(sp)
		else:
			var dist_m := k.global_position.distance_to(who.global_position) \
					/ float(GameConfig.TILE)
			_draw_edge_arrow(sp, vp, dist_m)


## The pulsating orange spiderweb, drawn on the survivor herself. Nested hexagons
## with spokes, which is what makes it read as a *marker* rather than as a UI icon
## floating somewhere near the target.
func _draw_web(sp: Vector2) -> void:
	var boost := 1.0 + _flash * 1.6
	var r := 15.0 + 2.0 * sin(_pulse * 6.0)
	var col := Color(1.0, 0.44, 0.06)

	for i in 3:
		var rr := r * (0.44 + 0.28 * float(i))
		var pts := PackedVector2Array()
		for n in 6:
			var a := TAU * float(n) / 6.0 + _pulse * 0.55
			pts.append(sp + Vector2(cos(a), sin(a)) * rr)
		pts.append(pts[0])
		draw_polyline(pts, Color(col.r, col.g, col.b,
				(0.26 + 0.14 * float(2 - i)) * minf(1.0, boost)), 1.6, true)

	for n in 6:
		var a := TAU * float(n) / 6.0 + _pulse * 0.55
		draw_line(sp, sp + Vector2(cos(a), sin(a)) * r,
				Color(col.r, col.g, col.b, 0.34 * minf(1.0, boost)), 1.2, true)

	draw_arc(sp, r + 3.0, 0.0, TAU, 22,
			Color(col.r, col.g, col.b, 0.55 * minf(1.0, boost)), 1.6, true)


## A revealed survivor off screen: an arrow pinned to the safe rectangle, pointing
## at them, with the distance in metres underneath.
func _draw_edge_arrow(sp: Vector2, vp: Vector2, dist_m: float) -> void:
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
	var col := Color(1.0, 0.44, 0.06, pulse)
	var tip := edge + dir * 12.0
	var l := edge + dir.rotated(2.3) * 9.0
	var r := edge + dir.rotated(-2.3) * 9.0
	draw_colored_polygon(PackedVector2Array([tip, l, r]), col)
	draw_arc(edge, 6.0, 0.0, TAU, 14, Color(col.r, col.g, col.b, col.a * 0.35), 1.0)

	# Distance, so the arrow is actionable rather than just a direction.
	var f := get_theme_default_font()
	if f != null:
		var label := "%dm" % int(round(dist_m))
		var text_size := f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 9)
		var anchor := edge - dir * 16.0 - Vector2(text_size.x * 0.5, -text_size.y * 0.25)
		draw_string(f, anchor, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 9,
				Color(col.r, col.g, col.b, col.a * 0.9))
