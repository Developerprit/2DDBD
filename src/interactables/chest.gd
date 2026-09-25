class_name Chest
extends Interactable
## A supply chest. Searching it grants a random item.

var searched := false
var looted_item: String = ""
var _lid: Sprite2D


func _build() -> void:
	kind = Enums.InteractionKind.CHEST
	prompt_key = "act.search_chest"
	interact_radius = 20.0
	super._build()

	sprite = Sprite2D.new()
	sprite.texture = AnimBuilder.prop_texture("chest")
	add_child(sprite)
	add_blocker(Vector2.ZERO, Vector2(12, 10))


func can_interact(actor: Node) -> bool:
	return not searched and actor.is_in_group("survivor")


func prompt(_actor: Node) -> String:
	return Locale.t("act.search_chest")


func hold_interact() -> bool:
	return true


func interact_time(_actor: Node) -> float:
	return 15.0


func on_interact_start(_actor: Node) -> void:
	AudioDirector.play_at("chest_open", global_position, _camera())


func on_interact_complete(actor: Node) -> void:
	if searched:
		return
	searched = true
	AudioDirector.play_at("chest_open", global_position, _camera())
	var pool := ["medkit", "flashlight", "toolbox", "map"]
	looted_item = pool[randi() % pool.size()]
	if actor.has_method("give_item"):
		actor.give_item(looted_item)
	if sprite != null:
		sprite.modulate = Color(0.75, 0.75, 0.75)


func _camera() -> Camera2D:
	var vp := get_viewport()
	return vp.get_camera_2d() if vp != null else null
