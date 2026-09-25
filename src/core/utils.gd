class_name Utils
extends RefCounted
## Small stateless helpers shared across the project.

const DIRS8 := [
	Vector2(-1, -1), Vector2(0, -1), Vector2(1, -1),
	Vector2(-1, 0), Vector2(1, 0),
	Vector2(-1, 1), Vector2(0, 1), Vector2(1, 1),
]

const DIRS4 := [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)]


static func facing_from_vector(v: Vector2) -> int:
	if absf(v.x) >= absf(v.y):
		return Enums.Facing.RIGHT if v.x >= 0.0 else Enums.Facing.LEFT
	return Enums.Facing.DOWN if v.y >= 0.0 else Enums.Facing.UP


static func facing_suffix(f: int) -> String:
	match f:
		Enums.Facing.UP: return "up"
		Enums.Facing.DOWN: return "down"
		_: return "side"


static func facing_flip(f: int) -> bool:
	return f == Enums.Facing.LEFT


## Angle (radians) a facing points at, used for vision cones.
static func facing_angle(f: int) -> float:
	match f:
		Enums.Facing.UP: return -PI / 2.0
		Enums.Facing.DOWN: return PI / 2.0
		Enums.Facing.LEFT: return PI
		_: return 0.0


static func tile_of(p: Vector2) -> Vector2i:
	return Vector2i(int(floor(p.x / GameConfig.TILE)), int(floor(p.y / GameConfig.TILE)))


static func tile_center(t: Vector2i) -> Vector2:
	return Vector2(t.x * GameConfig.TILE + GameConfig.TILE * 0.5,
			t.y * GameConfig.TILE + GameConfig.TILE * 0.5)


static func format_time(seconds: float) -> String:
	var s := int(maxf(0.0, seconds))
	return "%d:%02d" % [s / 60, s % 60]


static func health_color(h: int) -> Color:
	match h:
		Enums.Health.HEALTHY: return Color(0.55, 0.82, 0.55)
		Enums.Health.INJURED: return Color(0.85, 0.72, 0.35)
		Enums.Health.DOWNED: return Color(0.85, 0.42, 0.32)
		Enums.Health.DYING: return Color(0.80, 0.28, 0.24)
		Enums.Health.HOOKED: return Color(0.88, 0.20, 0.20)
		Enums.Health.ESCAPED: return Color(0.45, 0.75, 0.95)
		Enums.Health.DEAD: return Color(0.35, 0.33, 0.36)
	return Color.WHITE


static func health_key(h: int) -> String:
	return "state." + Enums.health_to_string(h)


## Shortest signed angular difference, radians.
static func angle_delta(a: float, b: float) -> float:
	var d := fmod(b - a + PI, TAU)
	if d < 0.0:
		d += TAU
	return d - PI


static func in_cone(origin: Vector2, facing_rad: float, half_angle: float,
		target: Vector2, radius: float) -> bool:
	var to_target := target - origin
	var dist := to_target.length()
	if dist > radius:
		return false
	if dist < 1.0:
		return true
	return absf(angle_delta(facing_rad, to_target.angle())) <= half_angle


## Deterministic shuffle so the same seed always produces the same map.
static func seeded_shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


static func points_on_line(a: Vector2, b: Vector2, step: float = 8.0) -> Array:
	var out: Array = []
	var d := a.distance_to(b)
	if d < 0.01:
		return [a]
	var n := int(d / step)
	for i in range(n + 1):
		out.append(a.lerp(b, float(i) / float(n)))
	return out
