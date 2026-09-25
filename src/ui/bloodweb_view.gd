class_name BloodwebView
extends VBoxContainer
## Renders one character's Bloodweb: a ring of purchasable nodes around a
## central sigil, with the tier, the wallet and the advance gate along the edges.
##
## The graph is regenerated from (char_id, tier) every time, so this view only
## has to ask SaveData which node ids are already taken.

signal changed

const RING_RADIUS := [96.0, 158.0]
const NODE_SIZE := Vector2(96, 38)

var char_id := ""
var is_killer := false

var nodes: Array = []

var _head: Label
var _wallet: Label
var _hint: Label
var _canvas: Control
var _buttons: Array = []
var _advance: Button
var _detail: RichTextLabel
var _built := false


func _init() -> void:
	add_theme_constant_override("separation", 8)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _ready() -> void:
	_ensure_built()


func _ensure_built() -> void:
	if _built:
		return
	_built = true
	_build()


func _build() -> void:
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 16)
	add_child(top)

	_head = UITheme.heading("", 15)
	_head.add_theme_color_override("font_color", Color(str(UITheme.palette()["gold"])))
	top.add_child(_head)

	_wallet = Label.new()
	_wallet.add_theme_font_size_override("font_size", 12)
	_wallet.add_theme_color_override("font_color", Color(str(UITheme.palette()["accent"])))
	top.add_child(_wallet)

	_hint = UITheme.dim("", 10)
	_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	top.add_child(_hint)

	# The ring. Nodes are real Buttons parented to this Control so hit-testing
	# and keyboard focus come for free.
	_canvas = Control.new()
	_canvas.custom_minimum_size = Vector2(0, 380)
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.draw.connect(_draw_web)
	_canvas.resized.connect(_relayout)
	add_child(_canvas)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	add_child(bottom)

	_advance = Button.new()
	_advance.custom_minimum_size = Vector2(190, 30)
	_advance.add_theme_font_size_override("font_size", 12)
	_advance.pressed.connect(_on_advance)
	bottom.add_child(_advance)

	_detail = RichTextLabel.new()
	_detail.bbcode_enabled = true
	_detail.fit_content = true
	_detail.scroll_active = false
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.custom_minimum_size = Vector2(0, 44)
	bottom.add_child(_detail)


# ---------------------------------------------------------------------------
func open(p_char_id: String, p_is_killer: bool) -> void:
	char_id = p_char_id
	is_killer = p_is_killer
	if not is_inside_tree():
		await ready
	_ensure_built()
	_refresh()


func _refresh() -> void:
	if char_id == "" or _canvas == null:
		return
	var tier := SaveData.web_tier(char_id)
	nodes = Bloodweb.nodes_for(char_id, is_killer, tier)

	_rebuild_buttons()

	var nm: Dictionary = (GameConfig.killers if is_killer else GameConfig.survivors) \
			.get(char_id, {}).get("name_key", "")
	_head.text = "%s · %s %d" % [Locale.t(str(nm)), Locale.t("bloodweb.tier"), tier]
	_wallet.text = "%s  %d" % [Locale.t("bloodweb.points"), int(SaveData.wallet.get("total", 0))]

	var taken := 0
	for n in nodes:
		if SaveData.is_node_taken(char_id, str(n["id"])):
			taken += 1
	var goal := Bloodweb.advance_goal(nodes.size())
	_hint.text = "%s  %d / %d" % [Locale.t("bloodweb.progress"), taken, goal]

	var ready_to_advance := taken >= goal
	_advance.disabled = not ready_to_advance
	_advance.text = Locale.t("bloodweb.advance")

	_detail.text = "[color=#9aa1ab]%s[/color]" % (
			Locale.t("bloodweb.ready") if ready_to_advance
			else Locale.t("bloodweb.need_more") % [goal - taken])
	_canvas.queue_redraw()
	_relayout()


func _rebuild_buttons() -> void:
	for b in _buttons:
		if is_instance_valid(b):
			b.queue_free()
	_buttons.clear()

	for i in nodes.size():
		var n: Dictionary = nodes[i]
		var b := Button.new()
		b.custom_minimum_size = NODE_SIZE
		b.size = NODE_SIZE
		b.add_theme_font_size_override("font_size", 10)
		b.tooltip_text = _node_tooltip(n)
		b.clip_text = true
		_style_node_button(b, n)
		b.pressed.connect(_on_node_pressed.bind(i))
		_canvas.add_child(b)
		_buttons.append(b)


func _style_node_button(b: Button, n: Dictionary) -> void:
	var p := UITheme.palette()
	var taken: bool = SaveData.is_node_taken(char_id, str(n["id"]))
	var col := _kind_color(int(n["kind"]))

	var sb := StyleBoxFlat.new()
	if taken:
		# Claimed nodes read as spent: dim, thin border, no fill.
		sb.bg_color = Color(str(p["panel"]))
		sb.border_color = Color(col).darkened(0.55)
	else:
		sb.bg_color = Color(str(p["panel_alt"]))
		sb.border_color = col
	sb.set_border_width_all(2 if not taken else 1)
	sb.content_margin_left = 4
	sb.content_margin_right = 4
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb)
	b.add_theme_stylebox_override("pressed", sb)
	b.add_theme_color_override("font_color",
			Color(str(p["text_dim"])) if taken else Color(col).lightened(0.35))
	b.text = _node_label(n) if not taken else "· " + _node_label(n)


func _kind_color(kind: int) -> Color:
	match kind:
		Bloodweb.Kind.PERK:
			return UITheme.color("gold")
		Bloodweb.Kind.ITEM:
			return UITheme.color("good")
		Bloodweb.Kind.ADDON:
			return Color("#b08a5a")
	return UITheme.color("accent")


func _node_label(n: Dictionary) -> String:
	var p: Dictionary = n["payload"]
	match int(n["kind"]):
		Bloodweb.Kind.PERK:
			return _name_of(GameConfig.perks, str(p.get("perk", "")))
		Bloodweb.Kind.ITEM:
			if p.has("item"):
				return _name_of(GameConfig.items, str(p["item"]))
			return _addon_name(str(p.get("addon", "")))
		Bloodweb.Kind.ADDON:
			return _addon_name(str(p.get("addon", "")))
	return "+%d BP" % int(p.get("bp", 0))


func _name_of(table: Dictionary, id: String) -> String:
	if id == "" or not table.has(id):
		return "—"
	var nm: Dictionary = table[id].get("name", {})
	return str(nm.get(Locale.current, nm.get("en", id)))


func _addon_name(id: String) -> String:
	if id == "":
		return "—"
	for table in [GameConfig.items, GameConfig.killers]:
		for key in table.keys():
			for a in table[key].get("addons", []):
				if str(a.get("id", "")) == id:
					var nm: Dictionary = a.get("name", {})
					return str(nm.get(Locale.current, nm.get("en", id)))
	return id


func _node_tooltip(n: Dictionary) -> String:
	var p: Dictionary = n["payload"]
	var lines := [_node_label(n), "%s %d" % [Locale.t("bloodweb.cost"), int(n["cost"])]]
	if int(n["kind"]) == Bloodweb.Kind.PERK and p.has("perk"):
		var desc: Dictionary = GameConfig.perks.get(str(p["perk"]), {}).get("desc", {})
		lines.append(str(desc.get(Locale.current, "")))
	return "\n".join(lines)


# ---------------------------------------------------------------------------
func _relayout() -> void:
	if _canvas == null:
		return
	var c := _canvas.size * 0.5
	var max_r := maxf(60.0, minf(_canvas.size.x, _canvas.size.y) * 0.42)
	for i in _buttons.size():
		var b: Button = _buttons[i]
		if not is_instance_valid(b):
			continue
		var n: Dictionary = nodes[i]
		var r: float = minf(RING_RADIUS[clampi(int(n["ring"]), 0, RING_RADIUS.size() - 1)], max_r)
		var dir := Vector2(cos(float(n["angle"])), sin(float(n["angle"])))
		b.position = c + dir * r - NODE_SIZE * 0.5
	_canvas.queue_redraw()


func _draw_web() -> void:
	var c := _canvas.size * 0.5
	var p := UITheme.palette()
	var max_r := maxf(60.0, minf(_canvas.size.x, _canvas.size.y) * 0.42)

	# Concentric guides plus the sigil at the centre.
	for i in RING_RADIUS.size():
		_canvas.draw_arc(c, minf(RING_RADIUS[i], max_r), 0.0, TAU, 64,
				Color(str(p["line"])), 1.0, true)
	_canvas.draw_arc(c, 26.0, 0.0, TAU, 32, Color(str(p["accent"])), 2.0, true)
	_canvas.draw_line(c + Vector2(-14, 0), c + Vector2(14, 0), Color(str(p["accent"])), 2.0)
	_canvas.draw_line(c + Vector2(0, -14), c + Vector2(0, 14), Color(str(p["accent"])), 2.0)

	for i in nodes.size():
		var n: Dictionary = nodes[i]
		var taken: bool = SaveData.is_node_taken(char_id, str(n["id"]))
		var r: float = minf(RING_RADIUS[clampi(int(n["ring"]), 0, RING_RADIUS.size() - 1)], max_r)
		var dir := Vector2(cos(float(n["angle"])), sin(float(n["angle"])))
		var col := _kind_color(int(n["kind"]))
		col.a = 0.75 if taken else 0.28
		_canvas.draw_line(c, c + dir * r, col, 1.0, true)


# ---------------------------------------------------------------------------
func _on_node_pressed(idx: int) -> void:
	if idx < 0 or idx >= nodes.size():
		return
	var n: Dictionary = nodes[idx]
	if SaveData.is_node_taken(char_id, str(n["id"])):
		return
	if not SaveData.take_node(char_id, str(n["id"]), int(n["cost"])):
		AudioDirector.play("ui_error", -6.0)
		EventBus.toast.emit(Locale.t("bloodweb.insufficient"), Color(0.9, 0.4, 0.35))
		return
	_apply_reward(n)
	AudioDirector.play("tier_up", -5.0)
	_refresh()
	changed.emit()


func _apply_reward(n: Dictionary) -> void:
	var p: Dictionary = n["payload"]
	var gold := UITheme.color("gold")
	if p.has("perk"):
		SaveData.grant_unlock(char_id, "perk:" + str(p["perk"]))
		EventBus.toast.emit("%s — %s" % [Locale.t("bloodweb.unlocked"), _node_label(n)], gold)
	elif p.has("item"):
		SaveData.grant_unlock(char_id, "item:" + str(p["item"]))
		EventBus.toast.emit("%s — %s" % [Locale.t("bloodweb.unlocked"), _node_label(n)], gold)
	elif p.has("addon"):
		SaveData.grant_unlock(char_id, "addon:" + str(p["addon"]))
		EventBus.toast.emit("%s — %s" % [Locale.t("bloodweb.unlocked"), _node_label(n)], gold)
	elif p.has("bp"):
		SaveData.add_bloodpoints("objective", int(p["bp"]))
		EventBus.toast.emit("+%d BP" % int(p["bp"]), gold)
	SaveData.save_all()


func _on_advance() -> void:
	if SaveData.advance_web(char_id):
		AudioDirector.play("tier_up", -4.0)
		SaveData.add_bloodpoints("objective", 1500)
		_refresh()
		changed.emit()
	else:
		AudioDirector.play("ui_error", -6.0)
