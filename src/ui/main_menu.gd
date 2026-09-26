extends CanvasLayer
## Main menu, loadout builder, settings, multiplayer lobby and the tutorial,
## all in one screen that swaps between Panels. Singletons keep the state
## (GameConfig / SaveData) so nothing is lost on switching tabs.

## NOTE: the order here MUST match the order the pages are added to page_root in
## _build(), because _show_page() addresses them by index.
enum Page { MAIN, LOADOUT, SETTINGS, MULTIPLAYER, TUTORIAL, CREDITS, BLOODWEB, SIDE }

var root: Control
var bg: Control
var page_root: Control
var theme_res: Theme
var title_label: Label
var subtitle_label: Label
var nav_box: VBoxContainer
var current: int = Page.MAIN

# loadout widgets
var perk_buttons: Array = []
var char_buttons: Array = []
var item_buttons: Array = []
var map_buttons: Array = []
var loadout_info: RichTextLabel
var addon_buttons: Array = []

# multiplayer widgets
var mp_mode := 0
var mp_status: Label
var offer_text: TextEdit
var answer_text: TextEdit
var signal_stage := 0

var _t := 0.0


func _ready() -> void:
	theme_res = UITheme.build()
	_build()
	EventBus.net_lobby_changed.connect(_on_lobby_changed)
	EventBus.net_peer_joined.connect(func(_id: int) -> void: _refresh_mp_status())
	EventBus.net_peer_left.connect(func(_id: int) -> void: _refresh_mp_status())
	GameConfig.player_role = GameConfig.player_role
	_show_page(Page.MAIN)

	# Debug hook for headless verification: open a specific page straight away.
	#   Game.exe -- --menu-side
	for arg in OS.get_cmdline_user_args():
		if arg == "--menu-side":
			_show_page(Page.SIDE)
			print("[menu] Side page opened; pages=%d visible_index=%d"
					% [page_root.get_child_count(), current])


func _process(delta: float) -> void:
	_t += delta
	if bg != null:
		bg.queue_redraw()


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------
func _build() -> void:
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = theme_res
	add_child(root)

	bg = Control.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.draw.connect(_draw_bg)
	root.add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	root.add_child(margin)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 26)
	margin.add_child(cols)

	# left: brand + nav
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(210, 0)
	left.add_theme_constant_override("separation", 3)
	cols.add_child(left)

	title_label = UITheme.heading("2DDBD", 46)
	left.add_child(title_label)

	subtitle_label = UITheme.dim(Locale.t("app.subtitle"), 10)
	subtitle_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	subtitle_label.custom_minimum_size = Vector2(200, 0)
	left.add_child(subtitle_label)

	left.add_child(_spacer(16))

	nav_box = VBoxContainer.new()
	nav_box.add_theme_constant_override("separation", 4)
	left.add_child(nav_box)
	_add_nav_button(Locale.t("menu.play"), func() -> void: _start_match())
	_add_nav_button(Locale.t("menu.side"), func() -> void: _show_page(Page.SIDE))
	_add_nav_button(Locale.t("menu.loadout"), func() -> void: _show_page(Page.LOADOUT))
	_add_nav_button(Locale.t("menu.bloodweb"), func() -> void: _show_page(Page.BLOODWEB))
	_add_nav_button(Locale.t("menu.multiplayer"), func() -> void: _show_page(Page.MULTIPLAYER))
	_add_nav_button(Locale.t("menu.settings"), func() -> void: _show_page(Page.SETTINGS))
	_add_nav_button(Locale.t("menu.tutorial"), func() -> void: _show_page(Page.TUTORIAL))
	_add_nav_button(Locale.t("menu.credits"), func() -> void: _show_page(Page.CREDITS))
	_add_nav_button(Locale.t("menu.quit"), func() -> void: SceneRouter.quit_game())

	# right: swappable page
	page_root = Control.new()
	page_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_child(page_root)

	_build_main_page()
	_build_loadout_page()
	_build_settings_page()
	_build_multiplayer_page()
	_build_tutorial_page()
	_build_credits_page()
	_build_bloodweb_page()
	_build_side_page()


func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


func _add_nav_button(text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(190, 26)
	b.add_theme_font_size_override("font_size", 12)
	b.pressed.connect(func() -> void:
		AudioDirector.play("ui_click", -8.0)
		cb.call())
	b.mouse_entered.connect(func() -> void: AudioDirector.play("ui_hover", -18.0))
	nav_box.add_child(b)


func _panel(title: String) -> VBoxContainer:
	var p := PanelContainer.new()
	p.set_anchors_preset(Control.PRESET_FULL_RECT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(str(UITheme.palette()["panel"]))
	sb.bg_color.a = 0.92
	sb.border_color = Color(str(UITheme.palette()["line"]))
	sb.set_border_width_all(1)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	p.add_theme_stylebox_override("panel", sb)
	page_root.add_child(p)

	# Every page scrolls. Without this the loadout / settings / tutorial content
	# runs past the bottom of a normal-sized window and the lower buttons become
	# unreachable -- the panel clips them and there is no way to reach them.
	# Horizontal scrolling stays off because the rows below wrap instead.
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	p.add_child(scroll)

	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 8)
	scroll.add_child(v)

	var h := UITheme.heading(title, 16)
	h.add_theme_color_override("font_color", Color(str(UITheme.palette()["gold"])))
	v.add_child(h)
	return v


func _show_page(p: int) -> void:
	# Pages are addressed by index, so a mismatch between the Page enum and the
	# order pages were added to page_root would silently show the WRONG tab. Make it
	# loud instead of silent.
	if p < 0 or p >= page_root.get_child_count():
		push_error("_show_page(%d) out of range (%d pages) -- Page enum and the build order are out of sync"
				% [p, page_root.get_child_count()])
		return
	current = p
	for child in page_root.get_children():
		child.visible = false
	page_root.get_child(p).visible = true
	if p == Page.LOADOUT:
		_refresh_loadout()
	if p == Page.BLOODWEB:
		_refresh_bloodweb()
	if p == Page.MULTIPLAYER:
		_refresh_mp_status()
	if p == Page.SIDE:
		_refresh_side()
	if p == Page.MAIN:
		_update_role_hint()


# ---------------------------------------------------------------------------
# Background
# ---------------------------------------------------------------------------
func _draw_bg() -> void:
	var s := bg.size
	var p := UITheme.palette()
	bg.draw_rect(Rect2(Vector2.ZERO, s), Color(str(p["bg"])))

	# Slow drifting fog bands.
	for i in 5:
		var y := s.y * (0.15 + i * 0.16) + sin(_t * 0.18 + i) * 14.0
		var a := 0.030 + i * 0.006
		bg.draw_rect(Rect2(0, y, s.x, 34 + i * 8), Color(0.55, 0.58, 0.66, a))

	# Hook sigil watermark on the right.
	var cx := s.x * 0.72
	var cy := s.y * 0.45
	var bar := 7.0
	var col := Color(str(p["accent"]))
	col.a = 0.10
	bg.draw_rect(Rect2(cx - 78, cy - 74, 156, bar), col)
	for i in 4:
		bg.draw_rect(Rect2(cx - 58 + i * 38, cy - 74, bar * 0.8, 120 - i * 12), col)
	bg.draw_rect(Rect2(cx - bar * 0.5, cy - 74, bar, 160), col)
	for i in 9:
		var bx := (i - 3) * 7.0
		bg.draw_rect(Rect2(cx + bx, cy + 86 + absf(i - 4) * 7, bar, bar), col)

	bg.draw_rect(Rect2(0, 0, s.x, 2), Color(str(p["accent"])))


# ---------------------------------------------------------------------------
# Main page
# ---------------------------------------------------------------------------
var _main_page: VBoxContainer
## Side page widgets: the two side cards and the "now playing" readout.
var _side_buttons: Array = []
var _side_info: Label


func _build_main_page() -> void:
	_main_page = _panel(Locale.t("menu.play"))

	# The side is picked on its OWN page (nav entry "Side"), so the Play page only
	# reports the current pick and offers a shortcut to that page. It used to be a
	# pair of inline buttons, and for one build a permanent lock -- both are gone.
	var role_row := HBoxContainer.new()
	role_row.add_theme_constant_override("separation", 10)
	_main_page.add_child(role_row)

	var hint := UITheme.dim("", 10)
	hint.name = "RoleHint"
	role_row.add_child(hint)
	_main_page.set_meta("role_hint", hint)

	var pick := Button.new()
	pick.text = Locale.t("side.pick")
	pick.custom_minimum_size = Vector2(130, 28)
	pick.add_theme_font_size_override("font_size", 11)
	pick.pressed.connect(func() -> void:
		AudioDirector.play("ui_click", -8.0)
		_show_page(Page.SIDE))
	role_row.add_child(pick)

	_main_page.add_child(_spacer(10))

	var info := RichTextLabel.new()
	info.bbcode_enabled = true
	info.fit_content = true
	info.custom_minimum_size = Vector2(0, 150)
	info.text = "[color=#9aa1ab]%s[/color]" % Locale.t("tut.lore")
	_main_page.add_child(info)

	var lore := RichTextLabel.new()
	lore.bbcode_enabled = true
	lore.fit_content = true
	lore.custom_minimum_size = Vector2(0, 120)
	lore.text = "[i][color=#7d848e]%s[/color][/i]" % _lore_text()
	_main_page.add_child(lore)


func _lore_text() -> String:
	if Locale.current == "zh":
		return "浓雾吞没了这片土地，恶灵需要献祭。\n五台发电机，两扇大门，一个钩子。\n你会在雾中活下来，还是成为它的一部分？"
	return "The fog has swallowed this place, and the Entity is hungry.\nFive generators. Two gates. One hook.\nWill you survive the fog, or become part of it?"


## Display name of the character currently selected for the chosen side.
func _current_char_name() -> String:
	if GameConfig.player_role == Enums.Team.SURVIVOR:
		return Locale.t(str(GameConfig.survivors.get(GameConfig.selected_survivor,
				{}).get("name_key", "char.dwight")))
	return Locale.t(str(GameConfig.killers.get(GameConfig.selected_killer,
			{}).get("name_key", "char.trapper")))


func _update_role_hint() -> void:
	var hint := _main_page.get_meta("role_hint") as Label
	if hint == null:
		return
	var side := Locale.t("loadout.role.survivor") if GameConfig.player_role == Enums.Team.SURVIVOR \
			else Locale.t("loadout.role.killer")
	hint.text = "%s: %s  ·  %s" % [Locale.t("loadout.role"), side, _current_char_name()]


# ---------------------------------------------------------------------------
# Side page -- the survivor / killer picker, on its own tab
# ---------------------------------------------------------------------------
var _side_page: VBoxContainer


func _build_side_page() -> void:
	_side_page = _panel(Locale.t("side.title"))
	_side_page.add_theme_constant_override("separation", 8)

	var hint := UITheme.dim(Locale.t("side.hint"), 10)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(380, 0)
	_side_page.add_child(hint)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_side_page.add_child(row)

	for team in [Enums.Team.SURVIVOR, Enums.Team.KILLER]:
		var card := Button.new()
		card.custom_minimum_size = Vector2(180, 92)
		card.add_theme_font_size_override("font_size", 12)
		card.alignment = HORIZONTAL_ALIGNMENT_CENTER
		card.text = "%s\n\n%s" % [
				Locale.t("loadout.role.survivor" if team == Enums.Team.SURVIVOR
						else "loadout.role.killer"),
				Locale.t("side.survivor.desc" if team == Enums.Team.SURVIVOR
						else "side.killer.desc")]
		card.set_meta("team", team)
		card.pressed.connect(func() -> void:
			AudioDirector.play("ui_click", -8.0)
			GameConfig.player_role = team
			_refresh_side()
			# The loadout lists are side-dependent, so keep them in step.
			_refresh_loadout()
			_update_role_hint())
		row.add_child(card)
		_side_buttons.append(card)

	_side_page.add_child(_spacer(6))
	_side_info = UITheme.dim("", 11)
	_side_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_side_info.custom_minimum_size = Vector2(380, 0)
	_side_page.add_child(_side_info)
	_refresh_side()


func _refresh_side() -> void:
	var p := UITheme.palette()
	for b in _side_buttons:
		var card := b as Button
		if card == null or not is_instance_valid(card):
			continue
		var team := int(card.get_meta("team", -1))
		var on := team == GameConfig.player_role
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(str(p["accent_soft"])) if on else Color(str(p["panel_alt"]))
		sb.border_color = Color(str(p["gold"])) if on else Color(str(p["line"]))
		sb.set_border_width_all(2 if on else 1)
		sb.content_margin_left = 8
		sb.content_margin_right = 8
		sb.content_margin_top = 6
		sb.content_margin_bottom = 6
		card.add_theme_stylebox_override("normal", sb)
		card.add_theme_stylebox_override("hover", sb)
		card.add_theme_color_override("font_color",
				Color(str(p["gold"])) if on else Color(str(p["text_dim"])))
	if _side_info != null and is_instance_valid(_side_info):
		var side := Locale.t("loadout.role.survivor") if GameConfig.player_role == Enums.Team.SURVIVOR \
				else Locale.t("loadout.role.killer")
		_side_info.text = "%s: %s  ·  %s: %s   (%s)" % [
				Locale.t("loadout.role"), side,
				Locale.t("loadout.character"), _current_char_name(),
				Locale.t("side.switchable")]


func _start_match() -> void:
	AudioDirector.play("ui_click", -4.0)
	# Nothing about the side is persisted: it is chosen freely on the Side page and
	# defaults back to survivor on the next launch. An earlier build locked it after
	# the first trial, which was both wrong and impossible to undo from inside the
	# game -- so there is deliberately no stored state left to get stuck on.
	SaveData.save_all()
	GameConfig.set_meta("pending_seed", randi())
	SceneRouter.goto_match()


# ---------------------------------------------------------------------------
# Loadout page
# ---------------------------------------------------------------------------
var _loadout_page: VBoxContainer
var _char_row: HFlowContainer
var _perk_row: HFlowContainer
var _item_row: HFlowContainer
var _map_row: HFlowContainer


func _build_loadout_page() -> void:
	_loadout_page = _panel(Locale.t("menu.loadout"))
	var v := _loadout_page
	v.add_theme_constant_override("separation", 10)

	v.add_child(UITheme.dim(Locale.t("loadout.character"), 10))
	# HFlowContainer wraps onto the next line instead of pushing buttons past the
	# right edge -- 12 perks at 112 px each made a plain HBox roughly 1400 px wide.
	_char_row = HFlowContainer.new()
	_char_row.add_theme_constant_override("h_separation", 6)
	_char_row.add_theme_constant_override("v_separation", 6)
	v.add_child(_char_row)

	v.add_child(UITheme.dim(Locale.t("loadout.perks") + " · " + Locale.t("loadout.locked_hint"), 10))
	_perk_row = HFlowContainer.new()
	_perk_row.add_theme_constant_override("h_separation", 6)
	_perk_row.add_theme_constant_override("v_separation", 6)
	v.add_child(_perk_row)

	var item_label := UITheme.dim(Locale.t("loadout.item") + " / " + Locale.t("loadout.power"), 10)
	item_label.name = "ItemLabel"
	v.add_child(item_label)
	_item_row = HFlowContainer.new()
	_item_row.add_theme_constant_override("h_separation", 6)
	_item_row.add_theme_constant_override("v_separation", 6)
	v.add_child(_item_row)

	v.add_child(UITheme.dim(Locale.t("loadout.addons"), 10))
	var addon_row := HFlowContainer.new()
	addon_row.name = "AddonRow"
	addon_row.add_theme_constant_override("h_separation", 6)
	addon_row.add_theme_constant_override("v_separation", 6)
	v.add_child(addon_row)

	v.add_child(UITheme.dim(Locale.t("loadout.map"), 10))
	_map_row = HFlowContainer.new()
	_map_row.add_theme_constant_override("h_separation", 6)
	_map_row.add_theme_constant_override("v_separation", 6)
	v.add_child(_map_row)

	loadout_info = RichTextLabel.new()
	loadout_info.bbcode_enabled = true
	loadout_info.fit_content = true
	loadout_info.custom_minimum_size = Vector2(0, 90)
	v.add_child(loadout_info)


func _refresh_loadout() -> void:
	# Guard against a save that equipped something the player does not own (for
	# example after a character switch).
	var owner_id: String = GameConfig.selected_killer \
			if GameConfig.player_role == Enums.Team.KILLER else GameConfig.selected_survivor
	var owned := SaveData.unlocked_perk_ids(owner_id)
	var slots: Array = GameConfig.killer_perks \
			if GameConfig.player_role == Enums.Team.KILLER else GameConfig.survivor_perks
	slots.assign(slots.filter(func(pid: String) -> bool: return owned.has(pid)))
	_rebuild_char_row()
	_rebuild_perk_row()
	_rebuild_item_row()
	_rebuild_addon_row()
	_rebuild_map_row()
	_refresh_loadout_info()
	_update_role_hint()


func _clear(row: Node) -> void:
	for c in row.get_children():
		c.queue_free()


func _rebuild_char_row() -> void:
	_clear(_char_row)
	if GameConfig.player_role == Enums.Team.SURVIVOR:
		for cid in GameConfig.survivors.keys():
			var cfg: Dictionary = GameConfig.survivors[cid]
			_char_row.add_child(_char_card(cid, Locale.t(str(cfg["name_key"])),
					cfg.get("palette", {}), cid == GameConfig.selected_survivor,
					func() -> void:
						GameConfig.selected_survivor = cid
						_refresh_loadout()))
	else:
		for kid in GameConfig.killers.keys():
			var kcfg: Dictionary = GameConfig.killers[kid]
			_char_row.add_child(_char_card(kid, Locale.t(str(kcfg["name_key"])),
					{"top": "#4a5049", "skin": "#b8937a"}, kid == GameConfig.selected_killer,
					func() -> void:
						GameConfig.selected_killer = kid
						_refresh_loadout()))


func _char_card(id: String, label: String, palette: Dictionary, selected: bool,
		cb: Callable) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(86, 44)
	b.text = label
	b.add_theme_font_size_override("font_size", 10)
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var p := UITheme.palette()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(str(palette.get("top", p["panel_alt"])))
	sb.border_color = Color(str(p["gold"])) if selected else Color(str(p["line"]))
	sb.set_border_width_all(2 if selected else 1)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb)
	b.pressed.connect(func() -> void:
		AudioDirector.play("ui_click", -8.0)
		cb.call())
	return b


func _rebuild_perk_row() -> void:
	_clear(_perk_row)
	var side := "survivor" if GameConfig.player_role == Enums.Team.SURVIVOR else "killer"
	var selected: Array = GameConfig.survivor_perks if side == "survivor" else GameConfig.killer_perks
	var owner_id: String = GameConfig.selected_killer if side == "killer" \
			else GameConfig.selected_survivor
	var owned := SaveData.unlocked_perk_ids(owner_id)

	for pid in GameConfig.perks.keys():
		var perk: Dictionary = GameConfig.perks[pid]
		if str(perk.get("side", "")) != side:
			continue
		# Perks are progression now: anything not granted by the Bloodweb (or a
		# character's signature) stays locked and unselectable.
		var unlocked: bool = owned.has(pid)
		var b := Button.new()
		var nm: Dictionary = perk.get("name", {})
		b.text = str(nm.get(Locale.current, nm.get("en", pid)))
		b.custom_minimum_size = Vector2(112, 26)
		b.add_theme_font_size_override("font_size", 10)
		b.tooltip_text = str(perk.get("desc", {}).get(Locale.current, "")) if unlocked \
				else Locale.t("bloodweb.title") + " — " + str(nm.get(Locale.current, pid))
		b.disabled = not unlocked
		if not unlocked and selected.has(pid):
			selected.erase(pid)
		var on := selected.has(pid)
		var p := UITheme.palette()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(str(p["accent_soft"])) if on else Color(str(p["panel_alt"]))
		sb.border_color = Color(str(p["gold"])) if on else Color(str(p["line"]))
		sb.set_border_width_all(1)
		sb.content_margin_left = 5
		sb.content_margin_right = 5
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("hover", sb)
		b.pressed.connect(func() -> void:
			AudioDirector.play("ui_click", -10.0)
			if selected.has(pid):
				selected.erase(pid)
			elif selected.size() < 4:
				selected.append(pid)
			_refresh_loadout())
		_perk_row.add_child(b)


func _rebuild_item_row() -> void:
	_clear(_item_row)
	if GameConfig.player_role == Enums.Team.SURVIVOR:
		_add_select_button(_item_row, Locale.t("common.none"), GameConfig.selected_item == "",
				func() -> void:
					GameConfig.selected_item = ""
					_refresh_loadout())
		for iid in GameConfig.items.keys():
			var cfg: Dictionary = GameConfig.items[iid]
			var nm: Dictionary = cfg.get("name", {})
			_add_select_button(_item_row, str(nm.get(Locale.current, iid)),
					GameConfig.selected_item == str(iid),
					func() -> void:
						GameConfig.selected_item = iid
						_refresh_loadout())
	else:
		var kcfg: Dictionary = GameConfig.killers.get(GameConfig.selected_killer, {})
		var power: Dictionary = kcfg.get("power", {})
		var nmk := str(power.get("name_key", "power.bear_trap"))
		_add_select_button(_item_row, Locale.t(nmk), true, func() -> void: pass)


func _rebuild_addon_row() -> void:
	var row := _loadout_page.find_child("AddonRow", true, false) as HFlowContainer
	if row == null:
		return
	_clear(row)
	if GameConfig.player_role == Enums.Team.SURVIVOR:
		if GameConfig.selected_item == "" or not GameConfig.items.has(GameConfig.selected_item):
			row.add_child(UITheme.dim("—", 10))
			return
		for a in GameConfig.items[GameConfig.selected_item].get("addons", []):
			var nm: Dictionary = a.get("name", {})
			var on: bool = GameConfig.selected_addons.has(str(a["id"]))
			_add_select_button(row, str(nm.get(Locale.current, a["id"])), on,
					func() -> void:
						var aid := str(a["id"])
						if GameConfig.selected_addons.has(aid):
							GameConfig.selected_addons.erase(aid)
						elif GameConfig.selected_addons.size() < 2:
							GameConfig.selected_addons.append(aid)
						_refresh_loadout())
	else:
		var kcfg: Dictionary = GameConfig.killers.get(GameConfig.selected_killer, {})
		for a in kcfg.get("addons", []):
			var nm2: Dictionary = a.get("name", {})
			var on2: bool = GameConfig.selected_addons.has(str(a["id"]))
			_add_select_button(row, str(nm2.get(Locale.current, a["id"])), on2,
					func() -> void:
						var aid2 := str(a["id"])
						if GameConfig.selected_addons.has(aid2):
							GameConfig.selected_addons.erase(aid2)
						elif GameConfig.selected_addons.size() < 2:
							GameConfig.selected_addons.append(aid2)
						_refresh_loadout())
		if kcfg.get("addons", []).is_empty():
			row.add_child(UITheme.dim("—", 10))


func _rebuild_map_row() -> void:
	_clear(_map_row)
	_add_select_button(_map_row, Locale.t("loadout.map.auto"), GameConfig.selected_map == "auto",
			func() -> void:
				GameConfig.selected_map = "auto"
				_refresh_loadout())
	for mid in GameConfig.maps.keys():
		var cfg: Dictionary = GameConfig.maps[mid]
		_add_select_button(_map_row, Locale.t(str(cfg["name_key"])),
				GameConfig.selected_map == str(mid),
				func() -> void:
					GameConfig.selected_map = mid
					_refresh_loadout())


func _add_select_button(row: Node, text: String, selected: bool, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(94, 24)
	b.add_theme_font_size_override("font_size", 10)
	var p := UITheme.palette()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(str(p["accent_soft"])) if selected else Color(str(p["panel_alt"]))
	sb.border_color = Color(str(p["gold"])) if selected else Color(str(p["line"]))
	sb.set_border_width_all(1)
	sb.content_margin_left = 4
	sb.content_margin_right = 4
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb)
	b.pressed.connect(func() -> void:
		AudioDirector.play("ui_click", -10.0)
		cb.call())
	row.add_child(b)
	return b


func _refresh_loadout_info() -> void:
	if loadout_info == null:
		return
	var s := ""
	if GameConfig.player_role == Enums.Team.KILLER:
		var cfg: Dictionary = GameConfig.killers.get(GameConfig.selected_killer, {})
		var power: Dictionary = cfg.get("power", {})
		s += "[color=#d8a848]%s[/color]\n" % Locale.t(str(cfg.get("name_key", "char.trapper")))
		s += "[color=#9aa1ab]%s[/color]\n" % Locale.t(str(power.get("desc_key", "")))
		s += "SPEED %.1f m/s   ·   %s %.0f m\n" % [
			float(cfg.get("move_speed", 4.6)), Locale.t("loadout.stats.terror"),
			float(cfg.get("terror_radius", 32.0)),
		]
	else:
		var scfg: Dictionary = GameConfig.survivors.get(GameConfig.selected_survivor, {})
		s += "[color=#d8a848]%s — %s[/color]\n" % [
			Locale.t(str(scfg.get("name_key", "char.dwight"))),
			str(scfg.get("title", {}).get(Locale.current, "")),
		]
		s += "[color=#9aa1ab]%s[/color]\n" % str(scfg.get("bio", {}).get(Locale.current, ""))
		s += "SPEED 4.0 m/s   ·   %s 4\n" % Locale.t("loadout.perks")
		if GameConfig.selected_item != "":
			s += "%s: %s\n" % [Locale.t("loadout.item"),
					Locale.t(str(GameConfig.items.get(GameConfig.selected_item, {}).get("name", {}).get(Locale.current, "")))]
	loadout_info.text = s


# ---------------------------------------------------------------------------
# Settings page
# ---------------------------------------------------------------------------
func _build_settings_page() -> void:
	var v := _panel(Locale.t("settings.title"))

	# Language
	var lang_row := HBoxContainer.new()
	lang_row.add_theme_constant_override("separation", 8)
	lang_row.add_child(_fixed_label(Locale.t("settings.language"), 120))
	lang_row.add_child(_option(["中文", "English"],
			["zh", "en"].find(GameConfig.language),
			func(i: int) -> void:
				Locale.set_language(["zh", "en"][i])
				SaveData.save_all()
				_rebuild_all_text()))
	v.add_child(lang_row)

	# Theme
	var theme_row := HBoxContainer.new()
	theme_row.add_theme_constant_override("separation", 8)
	theme_row.add_child(_fixed_label(Locale.t("settings.theme"), 120))
	theme_row.add_child(_option([Locale.t("settings.theme.dark"), Locale.t("settings.theme.light")],
			0 if GameConfig.ui_theme == "dark" else 1,
			func(i: int) -> void:
				GameConfig.ui_theme = "dark" if i == 0 else "light"
				theme_res = UITheme.build()
				root.theme = theme_res
				bg.queue_redraw()
				EventBus.settings_changed.emit()
				SaveData.save_all()))
	v.add_child(theme_row)

	v.add_child(_slider_row(Locale.t("settings.master"),
			GameConfig.master_volume, func(val: float) -> void:
				GameConfig.master_volume = val
				EventBus.settings_changed.emit()
				SaveData.save_all()))
	v.add_child(_slider_row(Locale.t("settings.sfx"),
			GameConfig.sfx_volume, func(val: float) -> void:
				GameConfig.sfx_volume = val
				EventBus.settings_changed.emit()
				SaveData.save_all()))
	v.add_child(_slider_row(Locale.t("settings.music"),
			GameConfig.music_volume, func(val: float) -> void:
				GameConfig.music_volume = val
				EventBus.settings_changed.emit()
				SaveData.save_all()))

	var diff_row := HBoxContainer.new()
	diff_row.add_theme_constant_override("separation", 8)
	diff_row.add_child(_fixed_label(Locale.t("settings.bot_difficulty"), 120))
	diff_row.add_child(_option([
			Locale.t("settings.difficulty.easy"),
			Locale.t("settings.difficulty.normal"),
			Locale.t("settings.difficulty.hard"),
			Locale.t("settings.difficulty.nightmare")],
			[0.7, 1.0, 1.25, 1.5].find(GameConfig.bot_difficulty),
			func(i: int) -> void:
				GameConfig.bot_difficulty = [0.7, 1.0, 1.25, 1.5][i]
				SaveData.save_all()))
	v.add_child(diff_row)

	v.add_child(_check_row(Locale.t("settings.fps"), GameConfig.show_fps,
			func(on: bool) -> void:
				GameConfig.show_fps = on
				SaveData.save_all()))
	v.add_child(_check_row(Locale.t("settings.shake"), GameConfig.screen_shake,
			func(on: bool) -> void:
				GameConfig.screen_shake = on
				SaveData.save_all()))
	v.add_child(_check_row(Locale.t("settings.pixel_snap"), GameConfig.pixel_snap,
			func(on: bool) -> void:
				GameConfig.pixel_snap = on
				SaveData.save_all()))

	var wallet := RichTextLabel.new()
	wallet.bbcode_enabled = true
	wallet.fit_content = true
	wallet.custom_minimum_size = Vector2(0, 60)
	v.add_child(wallet)
	wallet.name = "Wallet"
	wallet.text = "[color=#9aa1ab]%s: %d · matches %d · escapes %d · sacrifices %d[/color]" % [
		Locale.t("result.total"), int(SaveData.wallet.get("total", 0)),
		int(SaveData.stats.get("matches", 0)),
		int(SaveData.stats.get("survivor_escapes", 0)),
		int(SaveData.stats.get("killer_sacrifices", 0))]


func _fixed_label(text: String, width: int) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(width, 0)
	l.add_theme_font_size_override("font_size", 10)
	return l


func _option(items: Array, selected: int, cb: Callable) -> OptionButton:
	var o := OptionButton.new()
	for it in items:
		o.add_item(str(it))
	o.selected = clampi(selected, 0, items.size() - 1)
	o.custom_minimum_size = Vector2(140, 24)
	o.add_theme_font_size_override("font_size", 10)
	o.item_selected.connect(func(i: int) -> void:
		AudioDirector.play("ui_click", -10.0)
		cb.call(i))
	return o


func _slider_row(label: String, value: float, cb: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(_fixed_label(label, 120))
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.05
	s.value = value
	s.custom_minimum_size = Vector2(160, 18)
	var val_label := UITheme.dim("%d%%" % int(value * 100), 10)
	val_label.custom_minimum_size = Vector2(34, 0)
	s.value_changed.connect(func(v: float) -> void:
		val_label.text = "%d%%" % int(v * 100)
		cb.call(v))
	row.add_child(s)
	row.add_child(val_label)
	return row


func _check_row(label: String, value: bool, cb: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(_fixed_label(label, 120))
	var c := CheckBox.new()
	c.button_pressed = value
	c.add_theme_font_size_override("font_size", 10)
	c.toggled.connect(func(on: bool) -> void:
		AudioDirector.play("ui_click", -12.0)
		cb.call(on))
	row.add_child(c)
	return row


func _rebuild_all_text() -> void:
	# Rebuild the whole screen so a language switch takes effect everywhere.
	# Children are detached immediately (not queued) so _build can reuse indices.
	for c in root.get_children():
		root.remove_child(c)
		c.queue_free()
	_build()
	_show_page(current)


# ---------------------------------------------------------------------------
# Multiplayer page
# ---------------------------------------------------------------------------
func _build_multiplayer_page() -> void:
	var v := _panel(Locale.t("mp.title"))

	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 8)
	mode_row.add_child(_fixed_label(Locale.t("mp.mode"), 90))
	mode_row.add_child(_option([
			Locale.t("mp.mode.offline"),
			Locale.t("mp.mode.lan"),
			Locale.t("mp.mode.p2p")],
			mp_mode,
			func(i: int) -> void:
				mp_mode = i
				GameConfig.net_mode = [Enums.NetMode.OFFLINE, Enums.NetMode.LAN, Enums.NetMode.P2P][i]
				NetBridge.use_offline()
				_refresh_mp_status()))
	v.add_child(mode_row)

	mp_status = UITheme.dim(Locale.t("mp.disconnected"), 10)
	v.add_child(mp_status)

	# --- LAN ---
	var lan := VBoxContainer.new()
	lan.name = "LanBox"
	lan.add_theme_constant_override("separation", 6)
	v.add_child(lan)

	var ip_row := HBoxContainer.new()
	ip_row.add_theme_constant_override("separation", 8)
	ip_row.add_child(_fixed_label(Locale.t("mp.ip"), 90))
	var ip_edit := LineEdit.new()
	ip_edit.text = "127.0.0.1"
	ip_edit.custom_minimum_size = Vector2(140, 24)
	ip_edit.add_theme_font_size_override("font_size", 10)
	ip_row.add_child(ip_edit)

	var port_edit := LineEdit.new()
	port_edit.text = "27015"
	port_edit.custom_minimum_size = Vector2(70, 24)
	port_edit.add_theme_font_size_override("font_size", 10)
	ip_row.add_child(port_edit)
	lan.add_child(ip_row)

	var btn_row := HFlowContainer.new()
	btn_row.add_theme_constant_override("h_separation", 8)
	btn_row.add_theme_constant_override("v_separation", 6)
	var host_btn := Button.new()
	host_btn.text = Locale.t("mp.host")
	host_btn.custom_minimum_size = Vector2(120, 26)
	host_btn.add_theme_font_size_override("font_size", 11)
	host_btn.pressed.connect(func() -> void:
		NetBridge.use_lan()
		var err := NetBridge.host(int(port_edit.text))
		mp_status.text = "LAN host: %s" % ("OK" if err == OK else "FAILED %d" % err)
		_refresh_mp_status())
	btn_row.add_child(host_btn)

	var join_btn := Button.new()
	join_btn.text = Locale.t("mp.join")
	join_btn.custom_minimum_size = Vector2(120, 26)
	join_btn.add_theme_font_size_override("font_size", 11)
	join_btn.pressed.connect(func() -> void:
		NetBridge.use_lan()
		var err := NetBridge.join(ip_edit.text, int(port_edit.text))
		mp_status.text = "LAN join: %s" % ("OK" if err == OK else "FAILED %d" % err))
	btn_row.add_child(join_btn)
	lan.add_child(btn_row)

	# --- P2P (server-less) ---
	var p2p := VBoxContainer.new()
	p2p.name = "P2PBox"
	p2p.add_theme_constant_override("separation", 6)
	v.add_child(p2p)

	var p2p_hint := UITheme.dim(Locale.t("mp.mode.p2p"), 10)
	p2p_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	p2p_hint.custom_minimum_size = Vector2(360, 0)
	p2p.add_child(p2p_hint)

	offer_text = TextEdit.new()
	offer_text.custom_minimum_size = Vector2(360, 56)
	offer_text.add_theme_font_size_override("font_size", 9)
	offer_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	offer_text.placeholder_text = Locale.t("mp.signal_local")
	p2p.add_child(offer_text)

	var p2p_btns := HFlowContainer.new()
	p2p_btns.add_theme_constant_override("h_separation", 6)
	p2p_btns.add_theme_constant_override("v_separation", 6)

	var gen_btn := Button.new()
	gen_btn.text = Locale.t("mp.signal_generate")
	gen_btn.custom_minimum_size = Vector2(130, 24)
	gen_btn.add_theme_font_size_override("font_size", 10)
	gen_btn.pressed.connect(_on_generate_offer)
	p2p_btns.add_child(gen_btn)

	var acc_btn := Button.new()
	acc_btn.text = Locale.t("mp.signal_accept")
	acc_btn.custom_minimum_size = Vector2(130, 24)
	acc_btn.add_theme_font_size_override("font_size", 10)
	acc_btn.pressed.connect(_on_accept_offer)
	p2p_btns.add_child(acc_btn)

	var fin_btn := Button.new()
	fin_btn.text = Locale.t("mp.signal_finish")
	fin_btn.custom_minimum_size = Vector2(130, 24)
	fin_btn.add_theme_font_size_override("font_size", 10)
	fin_btn.pressed.connect(_on_finish_handshake)
	p2p_btns.add_child(fin_btn)
	p2p.add_child(p2p_btns)

	var start_btn := Button.new()
	start_btn.text = Locale.t("mp.start")
	start_btn.custom_minimum_size = Vector2(160, 28)
	start_btn.add_theme_font_size_override("font_size", 11)
	start_btn.pressed.connect(func() -> void:
		var b := NetBridge.boss()
		b.rpc_start_match(randi(), GameConfig.selected_map, GameConfig.selected_killer)
		NetBridge.pending_match = {"seed": randi(), "map": GameConfig.selected_map,
				"killer": GameConfig.selected_killer}
		_start_match())
	v.add_child(start_btn)

	lan.visible = true
	p2p.visible = true
	_update_mp_boxes(lan, p2p)


func _update_mp_boxes(lan: Node, p2p: Node) -> void:
	lan.visible = mp_mode == 1
	p2p.visible = mp_mode == 2


# --- P2P handshake callbacks (kept as named functions: GDScript cannot parse a
# --- multi-line lambda containing an if/else) -------------------------------
func _on_generate_offer() -> void:
	NetBridge.use_p2p()
	var b := NetBridge.boss()
	if not (b is NetWebRTC):
		return
	var offer: String = (b as NetWebRTC).create_offer()
	offer_text.text = offer
	mp_status.text = "OFFER ready — send it to the other player"
	signal_stage = 1


func _on_accept_offer() -> void:
	NetBridge.use_p2p()
	var b := NetBridge.boss()
	if not (b is NetWebRTC):
		return
	if (b as NetWebRTC).accept_offer(offer_text.text):
		offer_text.text = (b as NetWebRTC).local_description()
		mp_status.text = "ANSWER ready — send it back"
		signal_stage = 2
	else:
		mp_status.text = "bad offer"


func _on_finish_handshake() -> void:
	var b := NetBridge.boss()
	if not (b is NetWebRTC):
		return
	if (b as NetWebRTC).finish_handshake(offer_text.text):
		mp_status.text = Locale.t("mp.connected")


func _refresh_mp_status() -> void:
	if mp_status == null:
		return
	var lan := _multiplayer_page_box("LanBox")
	var p2p := _multiplayer_page_box("P2PBox")
	if lan != null and p2p != null:
		_update_mp_boxes(lan, p2p)
	if mp_mode == 0:
		mp_status.text = "%s — %s" % [Locale.t("mp.mode.offline"), Locale.t("mp.disconnected")]
	else:
		var b := NetBridge.boss()
		var n: int = b.lobby.size() if b != null else 0
		mp_status.text = "%s · peers %d · %s" % [
			Locale.t("mp.lobby"), n,
			Locale.t("mp.connected") if NetBridge.is_online() else Locale.t("mp.disconnected")]


func _multiplayer_page_box(name: String) -> Node:
	if page_root == null:
		return null
	var page := page_root.get_child(Page.MULTIPLAYER)
	return page.find_child(name, true, false)


func _on_lobby_changed(lobby: Dictionary) -> void:
	if mp_status != null:
		mp_status.text = "%s — %d" % [Locale.t("mp.lobby"), lobby.size()]


# ---------------------------------------------------------------------------
# Tutorial + credits
# ---------------------------------------------------------------------------
func _build_tutorial_page() -> void:
	var v := _panel(Locale.t("tut.title"))
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	# A RichTextLabel reports a minimum height of ZERO by default, so a page whose
	# only real child is the text collapsed down to just its heading and read as
	# "no content at all". fit_content makes the label claim its full text height
	# and the page finally renders (the ScrollContainer in _panel handles overflow).
	r.fit_content = true
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.custom_minimum_size = Vector2(0, 300)
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(r)
	r.text = _tutorial_text()


func _tutorial_text() -> String:
	var gold := "[color=#d8a848]"
	var dim := "[color=#9aa1ab]"
	var end := "[/color]"
	if Locale.current == "zh":
		return "\n".join(PackedStringArray([
			"%s%s%s" % [gold, Locale.t("tut.survivor"), end],
			dim + "目标：修复 5 台发电机 → 拉下出口大门开关 → 逃出去。",
			"长按 E = 交互（修机 / 治疗 / 救人 / 抱人 / 放板）。",
			"空格 = 校准：修机时出现的检定圈，指针扫过金色区=完美、灰色区=不错，落空=发电机爆炸。",
			"空格 = 被挂钩时挣扎、被扛起时扭动（连打）。",
			"F = 使用道具（医疗包可自救）；受伤后也可找队友治疗。",
			"被夹住时按 E 挣脱（16%）；木板放倒可阻挡杀手；窗户是逃跑的好伙伴。",
			"只剩你一人时地窖开启，跳进去立刻逃脱。" + end,
			"",
			gold + Locale.t("tut.killer") + end,
			dim + "目标：在逃生者逃出去之前击倒他们，挂上钩子献祭。",
			"左键 = 挥刀（有后摇；按住可突刺，射程更远）。右键 = 力量。",
			"靠近倒地的逃生者按 E 抱起，扛着时再按 E 挂钩。",
			"木板挡路时站着长按 E 踩碎（2.6 秒）；窗户杀手翻越更慢（1.5 秒），绕窗是逃生者的核心技巧。",
			"幽灵 · 哀嚎之铃：按住右键敲钟，1.5 秒隐身 / 2.5 秒显形。敲钟时移速降到 1.0 但可继续走动，松开右键即可中断。",
			"隐身时没有心跳与红痕，20m 外对逃生者完全不可见（你自己始终看得见自己）；仍可交互（翻窗/踩板/踢机/挂钩），且交互速度 +4%，但无法挥刀。" + end,
			"",
			gold + "键盘总览" + end,
			dim + "WASD 移动 · Shift 行走 · Ctrl 蹲伏 · E 交互(长按) · 空格 校准/挣扎 · 左键 攻击 · 右键 力量 · F 道具 · Tab 小地图 · Esc 暂停" + end,
		]))
	return "\n".join(PackedStringArray([
		"%s%s%s" % [gold, Locale.t("tut.survivor"), end],
		dim + "OBJECTIVE: repair 5 generators, pull an exit gate lever, get out.",
		"HOLD E to interact (repair / heal / unhook / pick up / drop a pallet).",
		"SPACE is the skill check: tap inside the gold band for a perfect, the grey band for a good - missing blows the generator.",
		"SPACE also mashes a struggle (on a hook) and a wiggle (while carried).",
		"F uses your item (a med-kit heals you); a teammate can also heal you.",
		"Step in a bear trap and press E to free yourself (16%). Drop pallets to block, loop windows to survive.",
		"When you are the last one standing the hatch opens - jump in for an instant escape." + end,
		"",
		gold + Locale.t("tut.killer") + end,
		dim + "OBJECTIVE: down survivors and sacrifice them before they escape.",
		"LEFT CLICK swings (long recovery); HOLD it to lunge for extra reach. RIGHT CLICK is your power.",
		"Standing over a downed survivor, press E to pick them up; press E again while carrying to hook them.",
		"HOLD E on a dropped pallet to break it. You vault windows slowly (1.5 s) - that is why survivors loop them.",
		"WRAITH - Wailing Bell: HOLD right click to ring, 1.5 s to cloak / 2.5 s to uncloak. While ringing you crawl at 1.0 m/s but keep walking freely, and letting go of right click cancels the ring.",
		"Cloaked you make no heartbeat and no red stain and survivors cannot see you past 20 m (you always see yourself); you may still interact - vault, break, kick, hook - 4% faster, but you cannot swing." + end,
		"",
		gold + "KEYS" + end,
		dim + "WASD move · Shift walk · Ctrl crouch · E interact (hold) · Space skill check / struggle · LMB attack · RMB power · F item · Tab minimap · Esc pause" + end,
	]))


# ---------------------------------------------------------------------------
# Bloodweb page
# ---------------------------------------------------------------------------
var _bloodweb_page: VBoxContainer
var _bloodweb_view: BloodwebView
var _web_row: HFlowContainer


func _build_bloodweb_page() -> void:
	_bloodweb_page = _panel(Locale.t("menu.bloodweb"))

	var hint := UITheme.dim(Locale.t("bloodweb.hint"), 10)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(360, 0)
	_bloodweb_page.add_child(hint)

	# Character picker. Rebuilt on every visit because it depends on the
	# currently selected side (survivor roster vs killer roster).
	_web_row = HFlowContainer.new()
	_web_row.name = "WebCharRow"
	_web_row.add_theme_constant_override("h_separation", 6)
	_web_row.add_theme_constant_override("v_separation", 6)
	_bloodweb_page.add_child(_web_row)

	_bloodweb_view = BloodwebView.new()
	_bloodweb_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_bloodweb_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Claiming a perk must immediately show up in the loadout screen.
	_bloodweb_view.changed.connect(_refresh_loadout)
	_bloodweb_page.add_child(_bloodweb_view)


func _refresh_bloodweb() -> void:
	if _bloodweb_view == null:
		return
	var killer_side := GameConfig.player_role == Enums.Team.KILLER
	for c in _web_row.get_children():
		_web_row.remove_child(c)
		c.queue_free()

	var roster: Dictionary = GameConfig.killers if killer_side else GameConfig.survivors
	for cid in roster.keys():
		var cfg: Dictionary = roster[cid]
		var b := Button.new()
		b.text = Locale.t(str(cfg.get("name_key", cid)))
		b.custom_minimum_size = Vector2(100, 24)
		b.add_theme_font_size_override("font_size", 10)
		var picked: bool = cid == (GameConfig.selected_killer if killer_side
				else GameConfig.selected_survivor)
		var p := UITheme.palette()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(str(p["accent_soft"])) if picked else Color(str(p["panel_alt"]))
		sb.border_color = Color(str(p["gold"])) if picked else Color(str(p["line"]))
		sb.set_border_width_all(1)
		sb.content_margin_left = 4
		sb.content_margin_right = 4
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("hover", sb)
		b.pressed.connect(func() -> void:
			AudioDirector.play("ui_click", -10.0)
			if killer_side:
				GameConfig.selected_killer = cid
			else:
				GameConfig.selected_survivor = cid
			_refresh_bloodweb())
		_web_row.add_child(b)

	var current: String = GameConfig.selected_killer if killer_side else GameConfig.selected_survivor
	_bloodweb_view.open(current, killer_side)


func _build_credits_page() -> void:
	var v := _panel(Locale.t("menu.credits"))
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	# Same fix as the tutorial page: without fit_content a text-only page has a
	# minimum height of 0 and renders as an empty panel.
	r.fit_content = true
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.custom_minimum_size = Vector2(0, 300)
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(r)
	if Locale.current == "zh":
		r.text = "[color=#d8a848]2DDBD[/color]\n\n" + \
				"一款 2D 俯视角像素风非对称生存恐怖游戏，致敬《Dead by Daylight》。\n\n" + \
				"[color=#9aa1ab]引擎：Godot 4.5.1 (GDScript)\n" + \
				"美术：100% 由 tools/gen_sprites.py 程序化生成的 SVG / PNG 像素画\n" + \
				"音效：100% 由 tools/gen_audio.py 程序化合成\n" + \
				"地图：程序化生成 + A* 网格寻路\n\n" + \
				"本项目为非商业粉丝致敬作品。《Dead by Daylight》及其角色、商标归 Behaviour Interactive 所有。\n" + \
				"项目内未使用任何原作素材文件。[/color]"
	else:
		r.text = "[color=#d8a848]2DDBD[/color]\n\n" + \
				"A top-down 2D pixel asymmetric horror game, a tribute to Dead by Daylight.\n\n" + \
				"[color=#9aa1ab]Engine: Godot 4.5.1 (GDScript)\n" + \
				"Art: 100%% procedurally generated SVG / PNG pixel art by tools/gen_sprites.py\n" + \
				"Audio: 100%% synthesised by tools/gen_audio.py\n" + \
				"Levels: procedural generation + A* grid pathfinding\n\n" + \
				"This is a non-commercial fan tribute. Dead by Daylight and its characters are\n" + \
				"trademarks of Behaviour Interactive. No original assets are included.[/color]"
