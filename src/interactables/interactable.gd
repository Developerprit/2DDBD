class_name Interactable
extends Node2D
## Base class for everything a character can walk up to and hold a button on:
## generators, hooks, pallets, windows, lockers, the hatch, exit gates, chests
## and bear traps.
##
## Subclasses override the small hooks below; the interaction *pipeline*
## (find target -> hold -> progress -> complete / cancel) lives in
## SurvivorInteractState and KillerInteractState so both teams share the code.

signal progress_changed(ratio: float)
signal interaction_completed(actor: Node)

var kind: int = Enums.InteractionKind.NONE
var prompt_key: String = "act.repair"
var blocking: bool = true
var interact_radius: float = 22.0
var occupied: bool = false
var occupant: Node = null

var body: StaticBody2D
var sprite: Sprite2D
var animated: AnimatedSprite2D
var extras: Node2D


func _ready() -> void:
	add_to_group("interactable")
	_build()


func _build() -> void:
	extras = Node2D.new()
	extras.name = "Extras"
	add_child(extras)
	if blocking:
		body = StaticBody2D.new()
		body.name = "Body"
		body.collision_layer = 0b1000          # layer 4: interactable
		body.collision_mask = 0
		add_child(body)


func add_blocker(offset: Vector2, size: Vector2) -> void:
	if body == null:
		return
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	shape.shape = rect
	shape.position = offset
	body.add_child(shape)


func add_blocker_circle(offset: Vector2, radius: float) -> void:
	if body == null:
		return
	var shape := CollisionShape2D.new()
	var c := CircleShape2D.new()
	c.radius = radius
	shape.shape = c
	shape.position = offset
	body.add_child(shape)


# ---------------------------------------------------------------------------
# Overridable interface
# ---------------------------------------------------------------------------
func can_interact(_actor: Node) -> bool:
	return false


func prompt(_actor: Node) -> String:
	return Locale.t(prompt_key)


func interact_time(_actor: Node) -> float:
	return 1.0


func hold_interact() -> bool:
	## true  -> must be held (progress bar)
	## false -> single press
	return true


func on_interact_start(_actor: Node) -> void:
	pass


## Return true when the interaction finishes this frame.
func on_interact_tick(_actor: Node, _delta: float) -> bool:
	return true


func on_interact_cancel(_actor: Node) -> void:
	pass


func on_interact_complete(actor: Node) -> void:
	interaction_completed.emit(actor)


## Highlight used by the AI and by the local prompt UI.
func is_available() -> bool:
	return not occupied


func world_center() -> Vector2:
	return global_position


func distance_to_actor(actor: Node) -> float:
	if actor == null or not is_instance_valid(actor):
		return 1e9
	return global_position.distance_to(actor.global_position)
