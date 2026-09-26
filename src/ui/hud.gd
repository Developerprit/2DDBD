extends CanvasLayer
## HUD -- objectives, teammate status, interaction prompt, skill check dial,
## power/item readout and the terror indicator.
##
## Everything is built in code so the layout stays in one readable place and the
## theme can be swapped at runtime.

var mc: MatchController = null
var theme_res: Theme

# widgets
var root: Control
var gen_row: HBoxContainer
var gen_label: Label
var team_list: VBoxContainer
var prompt_box: PanelContainer
var prompt_label: Label
var prompt_bar: ProgressBar
var dial: Control
var killer_panel: PanelContainer
var power_label: Label
## Survivors with the Alert perk get a few seconds of killer position pings
## after the killer smashes a pallet. This is the expiry timestamp (ms).
var _alert_reveal_until := 0
var item_label: Label
var toast_box: VBoxContainer
var bloodlust_bar: ProgressBar
var bell_bar: ProgressBar
var map_overlay: Control
var fps_label: Label
var objective_hint: Label
var hook_label: Label
var perk_label: Label

var _toasts: Array = []
var _map_visible := false
var _last_prompt := ""

# --- heartbeat indicator ---------------------------------------------------
## Terror-radius heartbeat, bottom-left. The killer emits `terror_level` every
## frame (0 = out of radius, 1 = right on top of you); the indicator pulses at
## a rate and opacity driven by that level. Hidden for the killer's own view.
var heart_box: Control
var heart_label: Label
var _terror := 0.0
var _heart_phase := 0.0

# --- pause overlay ---------------------------------------------------------
var pause_root: Control
var paused := false
var bl_vignette: Control
var _vignette_tier := 0
var _instinct: KillerInstinct


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	theme_res = UITheme.build()
	_build()
	EventBus.toast.connect(_on_toast)
	EventBus.settings_changed.connect(_rebuild_theme)
	EventBus.killer_broke.connect(_on_killer_broke)
	EventBus.terror_level.connect(_on_terror_level)
	await get_tree().process_frame
	mc = MatchController.instance


func _rebuild_theme() -> void:
	theme_res = UITheme.build()
	if root != null:
		root.theme = theme_res


func _build() -> void:
	root = Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = theme_res
	add_child(root)

	_build_top_left()
	_build_top_right()
	_build_bottom_center()
	_build_dial()
	_build_killer_panel()
	_build_heartbeat()
	_build_toasts()
	_build_map_overlay()
	_build_pause_overlay()
	_build_bloodlust_vignette()
	_build_instinct()

	fps_label = UITheme.dim("", 9)
	fps_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	fps_label.position = Vector2(-60, 4)
	fps_label.visible = GameConfig.show_fps
	root.add_child(fps_label)


func _panel_style() -> StyleBoxFlat:
	var p := UITheme.palette()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(str(p["panel"]))
	sb.bg_color.a = 0.82
	sb.border_color = Color(str(p["line"]))
	sb.set_border_width_all(1)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	return sb


# ---------------------------------------------------------------------------
func _build_top_left() -> void:
	var box := VBoxContainer.new()
	box.position = Vector2(8, 6)
	box.add_theme_constant_override("separation", 4)
	root.add_child(box)

	gen_label = Label.new()
	gen_label.text = "GENERATORS 0 / 5"
	gen_label.add_theme_font_size_override("font_size", 12)
	gen_label.add_theme_color_override("font_color", UITheme.color("gold"))
	box.add_child(gen_label)

	gen_row = HBoxContainer.new()
	gen_row.add_theme_constant_override("separation", 3)
	box.add_child(gen_row)
	for i in GameConfig.GENERATORS_TOTAL:
		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(16, 6)
		dot.color = Color(str(UITheme.palette()["line"]))
		gen_row.add_child(dot)

	objective_hint = UITheme.dim("", 9)
	box.add_child(objective_hint)

	hook_label = Label.new()
	hook_label.text = "HOOKED 0 / 0"
	hook_label.add_theme_font_size_override("font_size", 11)
	hook_label.add_theme_color_override("font_color", UITheme.color("red"))
	box.add_child(hook_label)

	perk_label = UITheme.dim("", 9)
	box.add_child(perk_label)


func _build_top_right() -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.position = Vector2(-190, 6)
	panel.custom_minimum_size = Vector2(182, 0)
	root.add_child(panel)

	team_list = VBoxContainer.new()
	team_list.add_theme_constant_override("separation", 2)
	panel.add_child(team_list)


func _build_bottom_center() -> void:
	prompt_box = PanelContainer.new()
	prompt_box.add_theme_stylebox_override("panel", _panel_style())
	prompt_box.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	prompt_box.position = Vector2(-110, -70)
	prompt_box.custom_minimum_size = Vector2(220, 0)
	prompt_box.visible = false
	root.add_child(prompt_box)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	prompt_box.add_child(v)

	prompt_label = Label.new()
	prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt_label.add_theme_font_size_override("font_size", 11)
	v.add_child(prompt_label)

	prompt_bar = ProgressBar.new()
	prompt_bar.custom_minimum_size = Vector2(200, 6)
	prompt_bar.show_percentage = false
	v.add_child(prompt_bar)


func _build_dial() -> void:
	dial = Control.new()
	dial.name = "SkillCheckDial"
	dial.custom_minimum_size = Vector2(90, 90)
	dial.size = Vector2(90, 90)
	dial.set_anchors_preset(Control.PRESET_CENTER)
	dial.position = Vector2(-45, -80)
	dial.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.visible = false
	dial.draw.connect(_draw_dial)
	root.add_child(dial)


func _build_killer_panel() -> void:
	killer_panel = PanelContainer.new()
	killer_panel.add_theme_stylebox_override("panel", _panel_style())
	killer_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	killer_panel.position = Vector2(8, -56)
	killer_panel.visible = false
	root.add_child(killer_panel)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	killer_panel.add_child(v)

	power_label = Label.new()
	power_label.add_theme_font_size_override("font_size", 11)
	v.add_child(power_label)

	bloodlust_bar = ProgressBar.new()
	bloodlust_bar.custom_minimum_size = Vector2(140, 5)
	bloodlust_bar.show_percentage = false
	bloodlust_bar.max_value = 3
	v.add_child(bloodlust_bar)

	## Wraith bell channel (cloak / uncloak). Hidden unless the bell is ringing.
	bell_bar = ProgressBar.new()
	bell_bar.custom_minimum_size = Vector2(140, 5)
	bell_bar.show_percentage = false
	bell_bar.max_value = 1.0
	bell_bar.visible = false
	v.add_child(bell_bar)

	item_label = Label.new()
	item_label.add_theme_font_size_override("font_size", 10)
	item_label.add_theme_color_override("font_color", UITheme.color("text_dim"))
	v.add_child(item_label)


## Terror-radius heartbeat, bottom-left. Survivors only: the killer always hears
## his own heartbeat, so showing it to him would be noise. Sits above the killer
## power panel's anchor so the two never overlap.
func _build_heartbeat() -> void:
	heart_box = Control.new()
	heart_box.name = "Heartbeat"
	heart_box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	heart_box.position = Vector2(8, -116)
	heart_box.custom_minimum_size = Vector2(170, 44)
	heart_box.size = Vector2(170, 44)
	heart_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	heart_box.visible = false
	heart_box.draw.connect(_draw_heartbeat)
	root.add_child(heart_box)

	heart_label = Label.new()
	heart_label.position = Vector2(32, 13)
	heart_label.add_theme_font_size_override("font_size", 11)
	heart_box.add_child(heart_label)


func _draw_heartbeat() -> void:
	if _terror <= 0.0:
		return
	# Pulse: a quick systole followed by a softer echo, rate driven by proximity.
	var beat := fmod(_heart_phase, 1.0)
	var pulse := pow(maxf(0.0, 1.0 - beat * 2.2), 2.0) \
			+ 0.45 * pow(maxf(0.0, 1.0 - absf(beat - 0.32) * 4.0), 2.0)
	var a := clampf(_terror * 1.5, 0.0, 1.0)
	var c := Color(0.88, 0.16, 0.14, (0.30 + 0.55 * pulse) * a)
	var c2 := Color(c.r, c.g, c.b, c.a * 0.30)
	heart_box.draw_circle(Vector2(15, 21), 5.5 + 3.0 * pulse, c)
	heart_box.draw_circle(Vector2(15, 21), 10.5 + 4.0 * pulse, c2)


## Objective pointers, killer only. Added first so it sits *under* the HUD panels:
## the arrows live along the screen edges, which is exactly where the panels are.
func _build_instinct() -> void:
	_instinct = KillerInstinct.new()
	_instinct.name = "KillerInstinct"
	root.add_child(_instinct)
	root.move_child(_instinct, 0)


func _build_toasts() -> void:
	toast_box = VBoxContainer.new()
	toast_box.set_anchors_preset(Control.PRESET_CENTER_TOP)
	toast_box.position = Vector2(-140, 40)
	toast_box.custom_minimum_size = Vector2(280, 0)
	toast_box.alignment = BoxContainer.ALIGNMENT_CENTER
	toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(toast_box)


func _build_map_overlay() -> void:
	map_overlay = Control.new()
	map_overlay.name = "MapOverlay"
	map_overlay.set_anchors_preset(Control.PRESET_CENTER)
	map_overlay.custom_minimum_size = Vector2(240, 240)
	map_overlay.size = Vector2(240, 240)
	map_overlay.position = Vector2(-120, -120)
	map_overlay.visible = false
	map_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_overlay.draw.connect(_draw_map)
	root.add_child(map_overlay)


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------
func _draw_dial() -> void:
	var s := dial.size
	var c := s * 0.5
	var r := minf(s.x, s.y) * 0.5 - 4.0

	# Track
	dial.draw_arc(c, r, 0.0, TAU, 48, Color(0.1, 0.11, 0.13, 0.85), 6.0, true)

	var sv := _local_survivor()
	if sv == null or not sv.skill.active:
		return
	var sk := sv.skill

	# Good band
	var g0 := (sk.great_center - sk.good_half) * TAU - PI * 0.5
	var g1 := (sk.great_center + sk.good_half) * TAU - PI * 0.5
	dial.draw_arc(c, r, g0, g1, 32, Color(0.62, 0.66, 0.70, 0.95), 6.0, true)

	# Great band
	var t0 := (sk.great_center - sk.great_half) * TAU - PI * 0.5
	var t1 := (sk.great_center + sk.great_half) * TAU - PI * 0.5
	dial.draw_arc(c, r, t0, t1, 32, Color(0.95, 0.82, 0.38, 1.0), 6.0, true)

	# Needle
	var a := sk.value * TAU - PI * 0.5
	var dir := Vector2(cos(a), sin(a))
	dial.draw_line(c + dir * (r - 9.0), c + dir * (r + 5.0), Color(0.95, 0.95, 0.95), 2.0, true)
	dial.draw_circle(c + dir * (r - 9.0), 2.0, Color(0.95, 0.95, 0.95))


func _draw_map() -> void:
	if mc == null:
		return
	var s := map_overlay.size
	var scale_f := s.x / float(GameConfig.MAP_SIZE)
	map_overlay.draw_rect(Rect2(Vector2.ZERO, s), Color(0.05, 0.06, 0.08, 0.88))

	# Walls
	if mc.grid.size() > 0:
		var step := 4
		var y := 0
		while y < mc.map_size:
			var x := 0
			while x < mc.map_size:
				if MapGenerator.at(mc.grid, mc.map_size, x, y) == MapGenerator.F_WALL:
					map_overlay.draw_rect(Rect2(
						Vector2(x, y) * GameConfig.TILE * scale_f,
						Vector2(step, step) * GameConfig.TILE * scale_f), Color(0.35, 0.37, 0.42))
				x += step
			y += step

	for entry in mc.objective_positions():
		var p: Vector2 = entry["pos"] * scale_f
		var col := Color(0.85, 0.72, 0.32)
		match str(entry["kind"]):
			"generator":
				col = Color(0.35, 0.72, 0.42) if entry["done"] else Color(0.85, 0.72, 0.32)
			"hook":
				col = Color(0.55, 0.35, 0.32)
			"gate":
				col = Color(0.42, 0.62, 0.85)
			"hatch":
				col = Color(0.55, 0.82, 0.95)
		map_overlay.draw_circle(p, 3.0, col)

	for sv in mc.survivors:
		if not is_instance_valid(sv) or sv.health == Enums.Health.DEAD:
			continue
		map_overlay.draw_circle(sv.global_position * scale_f, 3.0, Utils.health_color(sv.health))

	if mc.killer != null and is_instance_valid(mc.killer):
		var kp: Vector2 = mc.killer.global_position * scale_f
		if mc.player_role == Enums.Team.KILLER:
			map_overlay.draw_circle(kp, 4.0, Color(0.85, 0.25, 0.2))
		else:
			var kk := mc.killer as Killer
			# A cloaked Wraith is invisible on the survivor's minimap entirely.
			if kk != null and kk.is_cloaked():
				pass
			elif _alert_active() and Time.get_ticks_msec() < _alert_reveal_until:
				# Alert: the killer just smashed something nearby, ping his spot.
				map_overlay.draw_circle(kp, 4.0, Color(0.95, 0.55, 0.2, 0.9))
			else:
				# Survivors only see the killer when he is close enough to hear.
				var d := _player_pos().distance_to(mc.killer.global_position)
				if d < GameConfig.TERROR_RADIUS * 0.8:
					map_overlay.draw_circle(kp, 4.0, Color(0.85, 0.25, 0.2, 0.85))


# ---------------------------------------------------------------------------
# Runtime updates
# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	if mc == null:
		mc = MatchController.instance
		if mc == null:
			return
	_sync_generators()
	_sync_team()
	_sync_prompt()
	_sync_dial()
	_sync_killer_panel()
	_sync_heartbeat(delta)
	_sync_map()
	_sync_hooks()
	_sync_perks()
	if fps_label != null and GameConfig.show_fps:
		fps_label.text = "%d fps" % int(Engine.get_frames_per_second())


func _player_pos() -> Vector2:
	if mc.local_actor != null and is_instance_valid(mc.local_actor):
		return mc.local_actor.global_position
	return Vector2.ZERO


## True when the local player is a survivor carrying the Alert perk.
func _alert_active() -> bool:
	var sv := _local_survivor()
	if sv == null:
		return false
	return sv.perk_mods.has("alert_reveal_time")


## Alert perk: when the killer smashes a pallet, survivors who run Alert get a
## few seconds of his position painted on the minimap.
func _on_killer_broke(_pos: Vector2) -> void:
	if mc == null or mc.player_role != Enums.Team.SURVIVOR:
		return
	var sv := _local_survivor()
	if sv == null or not sv.perk_mods.has("alert_reveal_time"):
		return
	_alert_reveal_until = Time.get_ticks_msec() + int(float(sv.perk_mods["alert_reveal_time"]) * 1000.0)
	EventBus.toast.emit(Locale.t("fb.killer_broke"), Color(0.95, 0.55, 0.2))


func _local_survivor() -> Survivor:
	if mc == null:
		return null
	if mc.player_role == Enums.Team.KILLER:
		return null
	var s := mc.local_actor as Survivor
	if s == null or not is_instance_valid(s):
		return null
	if s.health in [Enums.Health.ESCAPED, Enums.Health.DEAD]:
		return null
	return s


func _sync_generators() -> void:
	if mc == null:
		return
	gen_label.text = "%s %d / %d" % [Locale.t("hud.generators").to_upper(),
			mc.generators_done, GameConfig.GENERATORS_TOTAL]
	var i := 0
	for child in gen_row.get_children():
		var dot := child as ColorRect
		if dot == null:
			continue
		dot.color = Color(str(UITheme.palette()["gold"])) if i < mc.generators_done \
				else Color(str(UITheme.palette()["line"]))
		i += 1
	if mc.exit_powered:
		objective_hint.text = Locale.t("hud.gate_powered")
	elif mc.hatch_node != null and mc.hatch_node.is_open:
		objective_hint.text = Locale.t("hud.hatch_open")
	else:
		objective_hint.text = ""


func _sync_team() -> void:
	if mc == null:
		return
	var kids := team_list.get_children()
	while kids.size() < mc.survivors.size():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(5, 9)
		row.add_child(dot)
		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 10)
		row.add_child(lbl)
		team_list.add_child(row)
		kids = team_list.get_children()

	var i := 0
	for sv in mc.survivors:
		if i >= kids.size():
			break
		var row := kids[i] as HBoxContainer
		var dot := row.get_child(0) as ColorRect
		var lbl := row.get_child(1) as Label
		var col := Utils.health_color(sv.health)
		dot.color = col
		var tag := ""
		if not sv.is_ai:
			tag = " ★"
		lbl.text = "%s — %s%s" % [sv.display_name, Locale.t(Utils.health_key(sv.health)), tag]
		lbl.add_theme_color_override("font_color", col)
		i += 1


func _sync_prompt() -> void:
	var sv := _local_survivor()
	if sv == null:
		prompt_box.visible = false
		return
	# A live skill check (calibration) takes priority: tell the player which key to
	# press. The dial already shows the band, this adds the missing key hint.
	if sv.skill.active:
		prompt_box.visible = true
		prompt_label.text = "%s  %s" % [Locale.t("act.calibrate"), Locale.t("hint.press")]
		prompt_bar.visible = false
		return
	var text := ""
	var ratio := 0.0
	var show_bar := false

	match sv.machine.current_name:
		"hooked":
			# Which hooking this is decides what comes next, so it is worth showing:
			# stage 1 is a rescue window, stage 2 is a fight, and a third is final.
			var nth := "%d/3" % mini(sv.hook_count, 3)
			if sv.hook_stage == 2:
				text = "%s  %s  %s" % [Locale.t("act.struggle"), nth, Locale.t("hint.mash")]
				show_bar = true
			else:
				text = "%s  %s  %s" % [Locale.t("act.self_unhook"), nth, Locale.t("hint.press")]
			ratio = clampf(sv.struggle_value, 0.0, 1.0)
		"locker":
			text = Locale.t("hint.exit_locker")
			show_bar = false
		"carried":
			text = Locale.t("act.wiggle")
			ratio = clampf(sv.wiggle, 0.0, 1.0)
			show_bar = true
		"interact":
			var it := sv.interact_target
			if it != null:
				text = it.prompt(sv)
				ratio = clampf(sv.interact_progress, 0.0, 1.0)
				show_bar = it.hold_interact()
		"trapped":
			text = Locale.t("act.escape_trap")
		_:
			if sv.interact_target != null and is_instance_valid(sv.interact_target):
				text = "%s: %s" % [Locale.t("hint.press"), sv.interact_target.prompt(sv)]
	if text == "" and mc != null and mc.player_role == Enums.Team.KILLER:
		var k := mc.local_actor as Killer
		if k != null:
			if k.is_carrying:
				text = "%s: %s / %s" % [Locale.t("hint.press"), Locale.t("act.hook"), Locale.t("act.pickup")]
			elif k.find_pickup_probe() != null:
				text = "%s: %s" % [Locale.t("hint.press"), Locale.t("act.pickup")]
			elif k.nearest_kickable_generator() != null:
				text = "%s: %s" % [Locale.t("hint.press"), Locale.t("act.damage_gen")]

	prompt_box.visible = text != ""
	if text != "":
		if prompt_label.text != text:
			prompt_label.text = text
		prompt_bar.visible = show_bar
		if show_bar:
			prompt_bar.value = ratio * 100.0


func _sync_hooks() -> void:
	if mc == null or hook_label == null:
		return
	if mc.player_role != Enums.Team.SURVIVOR:
		hook_label.visible = false
		return
	hook_label.visible = true
	var hooked := 0
	var dead := 0
	var total := mc.survivors.size()
	for sv in mc.survivors:
		if not is_instance_valid(sv):
			continue
		if sv.health == Enums.Health.HOOKED:
			hooked += 1
		elif sv.health == Enums.Health.DEAD:
			dead += 1
	hook_label.text = "%s %d / %d  ·  %s %d" % [Locale.t("hud.hooked"),
			hooked, total, Locale.t("hud.dead"), dead]


func _sync_perks() -> void:
	if mc == null or perk_label == null:
		return
	var a = mc.local_actor
	if a == null or not is_instance_valid(a) or not ("perks" in a):
		perk_label.visible = false
		return
	var names := []
	for pid in a.perks:
		var p: Dictionary = GameConfig.perks.get(pid, {})
		if p.is_empty():
			continue
		var nm: Dictionary = p.get("name", {})
		names.append(str(nm.get("zh", pid)))
	perk_label.visible = names.size() > 0
	if names.size() > 0:
		perk_label.text = "%s: %s" % [Locale.t("hud.perks"), " · ".join(names)]


func _sync_dial() -> void:
	var sv := _local_survivor()
	var show := sv != null and sv.skill.active
	if dial.visible != show:
		dial.visible = show
	if show:
		dial.queue_redraw()
	elif dial.visible:
		dial.queue_redraw()


## A red bleed around the screen edges while Bloodlust is active. The tier bar
## in the corner is easy to miss mid-chase; the vignette is not.
func _build_bloodlust_vignette() -> void:
	bl_vignette = Control.new()
	bl_vignette.name = "BloodlustVignette"
	bl_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	bl_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bl_vignette.visible = false
	bl_vignette.draw.connect(_draw_vignette)
	root.add_child(bl_vignette)


func _draw_vignette() -> void:
	var s := bl_vignette.size
	var steps := 10
	for i in steps:
		var t := float(i) / float(steps)
		var a := (0.075 + 0.02 * float(_vignette_tier)) * pow(1.0 - t, 1.7)
		var col := Color(0.60, 0.05, 0.04, a)
		var w := 130.0 * (1.0 - t)
		bl_vignette.draw_rect(Rect2(0, 0, s.x, w * 0.42), col)
		bl_vignette.draw_rect(Rect2(0, s.y - w * 0.42, s.x, w * 0.42), col)
		bl_vignette.draw_rect(Rect2(0, 0, w * 0.55, s.y), col)
		bl_vignette.draw_rect(Rect2(s.x - w * 0.55, 0, w * 0.55, s.y), col)


func _sync_killer_panel() -> void:
	if mc == null:
		return
	var is_killer := mc.player_role == Enums.Team.KILLER
	killer_panel.visible = is_killer
	if not is_killer:
		return
	var k := mc.local_actor as Killer
	if k == null:
		return
	if k.char_id == "wraith":
		if k._bell_active:
			var pct := clampf(k._bell_progress / k._bell_duration, 0.0, 1.0)
			power_label.text = "%s — %s" % [Locale.t("power.bell"),
					Locale.t("power.bell.ringing")]
			bell_bar.visible = true
			bell_bar.value = pct * 100.0
		else:
			power_label.text = "%s: %s" % [Locale.t("power.bell"),
					Locale.t("power.bell.cloaked" if k.cloaked else "power.bell.uncloaked")]
			bell_bar.visible = false
	else:
		power_label.text = "%s: %d" % [Locale.t("power.bear_trap"), k.trap_stock]
		bell_bar.visible = false
	bloodlust_bar.value = k.bloodlust_tier
	if bl_vignette != null:
		var show := k.bloodlust_tier > 0
		bl_vignette.visible = show
		if show:
			_vignette_tier = k.bloodlust_tier
			bl_vignette.queue_redraw()
	if k.held_item == "" and k.is_carrying:
		item_label.text = Locale.t("act.hook")
	elif k.attack_cooldown > 0.0:
		item_label.text = "%.1fs" % k.attack_cooldown
	else:
		item_label.text = ""


func _sync_map() -> void:
	if Input.is_action_just_pressed("toggle_map"):
		_map_visible = not _map_visible
		map_overlay.visible = _map_visible
		map_overlay.queue_redraw()
	if _map_visible:
		map_overlay.queue_redraw()


## Terror level arrives from the killer every physics frame. Only survivors get
## the indicator: to the killer his own heartbeat is meaningless noise.
func _on_terror_level(level: float) -> void:
	_terror = clampf(level, 0.0, 1.0)


func _sync_heartbeat(delta: float) -> void:
	if heart_box == null:
		return
	var show := mc != null and mc.player_role == Enums.Team.SURVIVOR and _terror > 0.01
	if heart_box.visible != show:
		heart_box.visible = show
	if not show:
		return
	# Cloak of the Wraith already drives terror to 0, so a hidden heart here is
	# automatic. Rate and opacity climb as he closes in.
	_heart_phase = fmod(_heart_phase + delta * (0.9 + _terror * 2.4), 1.0)
	var d := (1.0 - _terror) * GameConfig.TERROR_RADIUS / GameConfig.TILE
	heart_label.text = "%s  %d%s" % [Locale.t("hud.heartbeat"), int(round(d)),
			Locale.t("unit.meters")]
	heart_label.add_theme_color_override("font_color",
			Color(0.95, 0.45, 0.40, 0.45 + 0.55 * _terror))
	heart_box.queue_redraw()


# ---------------------------------------------------------------------------
func _on_toast(text: String, color: Color) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_box.add_child(l)
	var tw := l.create_tween()
	tw.tween_interval(1.6)
	tw.tween_property(l, "modulate:a", 0.0, 0.6)
	tw.tween_callback(l.queue_free)


# ---------------------------------------------------------------------------
# Pause overlay
# ---------------------------------------------------------------------------
func _build_pause_overlay() -> void:
	pause_root = Control.new()
	pause_root.name = "PauseOverlay"
	pause_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_root.visible = false
	pause_root.theme = theme_res
	root.add_child(pause_root)

	var veil := ColorRect.new()
	veil.color = Color(0.02, 0.025, 0.03, 0.85)
	veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_root.add_child(veil)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.position = Vector2(-120, -80)
	box.custom_minimum_size = Vector2(240, 0)
	box.add_theme_constant_override("separation", 7)
	pause_root.add_child(box)

	var title := UITheme.heading("PAUSED", 24)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var hint := UITheme.dim("%s  ·  %s" % [Locale.t("hint.press") + " Esc",
			Locale.t("menu.settings") + " / " + Locale.t("menu.back_to_menu")], 10)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(hint)

	box.add_child(_pause_button(Locale.t("menu.resume"), func() -> void: _toggle_pause(false)))
	box.add_child(_pause_button(Locale.t("menu.settings"), func() -> void:
		# Leaving the trial is the honest way to reach full settings: the panel
		# lives in the main menu, so we return there rather than duplicating it.
		get_tree().paused = false
		SceneRouter.goto_menu()))
	box.add_child(_pause_button(Locale.t("menu.back_to_menu"), func() -> void:
		get_tree().paused = false
		SceneRouter.goto_menu()))
	box.add_child(_pause_button(Locale.t("menu.quit"), func() -> void:
		SceneRouter.quit_game()))


func _pause_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(240, 28)
	b.add_theme_font_size_override("font_size", 12)
	b.pressed.connect(func() -> void:
		AudioDirector.play("ui_click", -8.0)
		cb.call())
	return b


func _toggle_pause(force: int = -1) -> void:
	paused = force == 1 if force >= 0 else not paused
	pause_root.visible = paused
	get_tree().paused = paused
	root.mouse_filter = Control.MOUSE_FILTER_STOP if paused else Control.MOUSE_FILTER_IGNORE


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		_toggle_pause()
		get_viewport().set_input_as_handled()
