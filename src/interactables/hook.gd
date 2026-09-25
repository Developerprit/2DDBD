class_name Hook
extends Interactable
## A sacrificial hook. Survivors hang here in up to three stages.

var occupied_by: Node = null
var used: bool = false           ## used hooks are skipped by auto-hook targeting
var stage: int = Enums.HookStage.NONE

var _chain: Line2D
var _glow: PointLight2D


func _build() -> void:
	kind = Enums.InteractionKind.HOOK
	prompt_key = "act.unhook"
	interact_radius = 20.0
	super._build()

	sprite = Sprite2D.new()
	sprite.texture = AnimBuilder.prop_texture("hook")
	sprite.offset = Vector2(0, -14)
	add_child(sprite)

	# Slim: a fat post collider seals the whole tile and wedges anyone pathing past.
	add_blocker_circle(Vector2(0, -6), 3.5)
	set_process(false)


func can_interact(actor: Node) -> bool:
	if occupied_by == null or not is_instance_valid(occupied_by):
		return false
	if not actor.is_in_group("survivor"):
		return false
	if actor == occupied_by:
		return true   ## self-unhook attempt
	return actor.health == Enums.Health.HEALTHY or actor.health == Enums.Health.INJURED


func prompt(actor: Node) -> String:
	if actor == occupied_by:
		return Locale.t("act.self_unhook")
	return Locale.t("act.unhook")


func hold_interact() -> bool:
	return true


func interact_time(actor: Node) -> float:
	if actor == occupied_by:
		return GameConfig.S_SELF_UNHOOK_ATTEMPT
	return GameConfig.UNHOOK_TIME


func on_interact_tick(actor: Node, delta: float) -> bool:
	if occupied_by == null or not is_instance_valid(occupied_by):
		return true
	if actor == occupied_by:
		# Self-unhook is a dice roll resolved on completion, not per tick.
		return false
	return false


func on_interact_complete(actor: Node) -> void:
	if occupied_by == null or not is_instance_valid(occupied_by):
		return
	if actor == occupied_by:
		if randf() < GameConfig.S_SELF_UNHOOK_CHANCE:
			occupied_by.on_unhooked(self, true)
			free_hook()
		else:
			EventBus.toast.emit(Locale.t("fb.skillcheck_miss"), Color(0.85, 0.4, 0.35))
		return
	occupied_by.on_unhooked(self, false)
	SaveData.add_bloodpoints("altruism", GameConfig.BP_UNHOOK)
	free_hook()


func occupy(victim: Node) -> void:
	occupied_by = victim
	used = true
	stage = Enums.HookStage.FIRST
	set_process(true)
	if _glow == null:
		_glow = PointLight2D.new()
		var grad := Gradient.new()
		grad.set_color(0, Color(1, 0.9, 0.85, 0.55))
		grad.set_color(1, Color(1, 0.4, 0.3, 0.0))
		var gt := GradientTexture2D.new()
		gt.gradient = grad
		gt.width = 64
		gt.height = 64
		gt.fill = GradientTexture2D.FILL_RADIAL
		gt.fill_from = Vector2(0.5, 0.5)
		gt.fill_to = Vector2(1.0, 0.5)
		_glow.texture = gt
		_glow.energy = 0.5
		_glow.texture_scale = 1.1
		_glow.position = Vector2(0, -14)
		add_child(_glow)


func free_hook() -> void:
	occupied_by = null
	stage = Enums.HookStage.NONE
	if _glow != null:
		_glow.queue_free()
		_glow = null
	set_process(false)


func is_free() -> bool:
	return occupied_by == null or not is_instance_valid(occupied_by)


func _process(_delta: float) -> void:
	if _glow != null:
		_glow.energy = 0.35 + 0.2 * sin(Time.get_ticks_msec() / 260.0)
