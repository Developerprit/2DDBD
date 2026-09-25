class_name SkillCheck
extends RefCounted
## The generator/heal skill check (QTE).
##
## A needle sweeps clockwise around a dial. The player presses the action key
## inside the good band for a normal hit, or inside the small great band for a
## perfect one. Missing blows the generator up and makes noise.

var active := false
var value := 0.0            ## 0..1 around the dial
var speed := 0.55           ## dial fraction per second
var great_center := 0.5
var great_half := 0.032
var good_half := 0.105
var resolved := -1          ## -1 pending, 0 miss, 1 good, 2 great
var start_delay := 0.0      ## tiny grace period before the needle is live
var on_resolve: Callable = Callable()
var large_zone_bonus := 1.0


func begin(rng: RandomNumberGenerator, difficulty: float = 1.0,
		zone_bonus: float = 1.0) -> void:
	active = true
	resolved = -1
	value = 0.0
	start_delay = 0.10
	large_zone_bonus = zone_bonus
	# Never spawn the band right at the start of the sweep.
	great_center = rng.randf_range(0.18, 0.92)
	great_half = clampf(0.032 / difficulty * zone_bonus, 0.02, 0.09)
	good_half = clampf(0.105 / difficulty * zone_bonus, 0.045, 0.22)
	speed = randf_range(0.42, 0.78) * difficulty


func update(delta: float) -> void:
	if not active:
		return
	if start_delay > 0.0:
		start_delay -= delta
		return
	value += speed * delta
	if value >= 1.0:
		# Ran all the way around without a press: counts as a miss.
		_resolve(0)


## Grade the current needle position.
func press() -> int:
	if not active or start_delay > 0.0:
		return -1
	var d := absf(value - great_center)
	if d <= great_half:
		_resolve(2)
		return 2
	if d <= good_half:
		_resolve(1)
		return 1
	_resolve(0)
	return 0


func miss_outside() -> void:
	if active:
		_resolve(0)


func _resolve(grade: int) -> void:
	active = false
	resolved = grade
	if on_resolve.is_valid():
		on_resolve.call(grade)


func abort() -> void:
	active = false
	resolved = -1


func great_ratio() -> float:
	return clampf(great_half / 0.5, 0.0, 1.0)


func good_ratio() -> float:
	return clampf(good_half / 0.5, 0.0, 1.0)
