class_name RedStain
extends Node2D
## The killer's red stain: a red cone of light cast on the ground in the
## direction he is facing.
##
## This is one of Dead by Daylight's most important readability tools. Survivors
## cannot see the killer's body through a wall, but they *can* watch the stain
## sweep across the ground -- which is how you know he is about to come around
## the corner and which way he is committing. It also gives the killer away when
## he is looking straight at you from a distance.
##
## Drawn as a vertex-coloured triangle fan so the cone fades with distance
## instead of ending in a hard bright edge.

const SEGMENTS := 18

var range_px := 160.0
var half_angle := 0.42          ## ~24 degrees either side of forward
var intensity := 1.0            ## scaled up by Bloodlust tiers
var _tier := 0
var _pulse := 0.0


func _ready() -> void:
	# Below the characters (0) but above the terrain (-50): the stain is on the
	# floor, not on top of the killer.
	z_index = -10
	set_process(true)


func configure(range_tiles: float, angle_deg: float) -> void:
	range_px = range_tiles * GameConfig.TILE
	half_angle = deg_to_rad(angle_deg) * 0.5
	queue_redraw()


## Called by the killer every frame. `tier` is the Bloodlust level (0..3).
func set_direction(rad: float, tier: int) -> void:
	rotation = rad
	if tier != _tier:
		_tier = tier
		queue_redraw()


func _process(delta: float) -> void:
	# A slow throb so the stain reads as alive rather than as a static decal.
	_pulse += delta
	queue_redraw()


func _draw() -> void:
	var heat := float(_tier)
	var base := Color(0.88, 0.11, 0.08)
	if _tier > 0:
		# Bloodlust darkens and thickens the stain.
		base = base.lerp(Color(0.55, 0.04, 0.03), minf(1.0, heat / 3.0))
	var outer_a := (0.26 + 0.07 * heat) * intensity
	var inner_a := (0.40 + 0.12 * heat) * intensity
	var throb := 1.0 + 0.06 * sin(_pulse * 3.4)

	var pts := PackedVector2Array()
	var cols := PackedColorArray()

	var c_in := base
	c_in.a = inner_a
	pts.append(Vector2.ZERO)
	cols.append(c_in)

	for i in SEGMENTS + 1:
		var a := lerpf(-half_angle, half_angle, float(i) / float(SEGMENTS))
		pts.append(Vector2(cos(a), sin(a)) * range_px * throb)
		# Fade out along the length, and slightly at the cone's edges.
		var edge := 1.0 - absf(float(i) / float(SEGMENTS) - 0.5) * 0.9
		var c_out := base
		c_out.a = outer_a * edge * 0.35
		cols.append(c_out)

	draw_polygon(pts, cols)

	# A brighter spine down the middle: this is the part survivors read as
	# "he is looking exactly this way".
	var c_spine := base
	c_spine.a = inner_a * 0.55
	draw_line(Vector2(6, 0), Vector2(range_px * 0.82 * throb, 0), c_spine, 2.0, true)
