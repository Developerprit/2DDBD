class_name UITheme
extends RefCounted
## Builds the interface Theme at runtime from a compact palette.
##
## Two palettes ship: a dark one (default, matching the game's horror tone) and
## a light one, switchable in Settings and persisted through SaveData.

const DARK := {
	"bg": "#0d0f12",
	"panel": "#15181d",
	"panel_alt": "#1c2027",
	"line": "#2a2f38",
	"text": "#e6e3dc",
	"text_dim": "#9aa1ab",
	"accent": "#c8543a",
	"accent_soft": "#8f3a28",
	"gold": "#d8a848",
	"good": "#6fae72",
	"bad": "#b8433a",
	"info": "#6f93b8",
}

const LIGHT := {
	"bg": "#efece5",
	"panel": "#faf8f3",
	"panel_alt": "#e6e2d9",
	"line": "#c9c3b6",
	"text": "#1b1d21",
	"text_dim": "#5d646d",
	"accent": "#a83f2a",
	"accent_soft": "#c56a52",
	"gold": "#a3761f",
	"good": "#3f7a45",
	"bad": "#a33028",
	"info": "#3d6288",
}


static func palette(theme_name: String = "") -> Dictionary:
	var name := theme_name if theme_name != "" else GameConfig.ui_theme
	return LIGHT if name == "light" else DARK


static func color(key: String) -> Color:
	return Color(str(palette().get(key, "#ffffff")))


static func c(hexv: String) -> Color:
	return Color(hexv)


## The game's bitmap font, with a CJK face chained behind it.
##
## The pixel font covers printable ASCII only -- 95 glyphs is the whole point of a
## bitmap face at this size. Chinese UI text therefore has to come from somewhere,
## and naming the system CJK fonts beats bundling a ~20 MB TTF into the repository.
##
## Note that assigning `fallbacks` *replaces* the engine's implicit fallback chain:
## pointing it at ThemeDB.fallback_font is not enough, because that face has no CJK
## either and every Chinese glyph renders as a tofu box. It has to be a SystemFont.
static func pixel_font() -> Font:
	var path := "res://assets/fonts/pixel_font.fnt"
	if not ResourceLoader.exists(path):
		return ThemeDB.fallback_font
	var f: FontFile = load(path)
	if f == null:
		return ThemeDB.fallback_font

	var cjk := SystemFont.new()
	cjk.font_names = PackedStringArray([
		"Microsoft YaHei", "微软雅黑",
		"SimHei", "黑体",
		"Noto Sans CJK SC", "Source Han Sans SC",
		"PingFang SC", "WenQuanYi Micro Hei",
		"sans-serif",
	])
	f.fallbacks = [cjk]
	return f


static func build(theme_name: String = "") -> Theme:
	var p := palette(theme_name)
	var t := Theme.new()

	# ---- defaults ----
	t.default_font = pixel_font()
	t.default_font_size = 11

	# ---- Button ----
	var btn_normal := _box(Color(str(p["panel_alt"])), Color(str(p["line"])))
	t.set_stylebox("normal", "Button", btn_normal)
	t.set_stylebox("hover", "Button", _box(Color(str(p["accent_soft"])).darkened(0.25), Color(str(p["accent"]))))
	t.set_stylebox("pressed", "Button", _box(Color(str(p["accent"])).darkened(0.35), Color(str(p["accent"]))))
	t.set_stylebox("focus", "Button", _box(Color(0, 0, 0, 0), Color(str(p["accent"]))))
	t.set_stylebox("disabled", "Button", _box(Color(str(p["panel"])), Color(str(p["line"])).darkened(0.3)))
	t.set_color("font_color", "Button", Color(str(p["text"])))
	t.set_color("font_hover_color", "Button", Color(str(p["text"])))
	t.set_color("font_pressed_color", "Button", Color(str(p["bg"])))
	t.set_color("font_disabled_color", "Button", Color(str(p["text_dim"])).darkened(0.2))
	t.set_constant("h_separation", "Button", 6)
	t.set_constant("outline_size", "Button", 0)

	# ---- Panel ----
	t.set_stylebox("panel", "Panel", _box(Color(str(p["panel"])), Color(str(p["line"]))))
	t.set_stylebox("panel", "PanelContainer", _box(Color(str(p["panel"])), Color(str(p["line"]))))

	# ---- Labels ----
	t.set_color("font_color", "Label", Color(str(p["text"])))
	for cls in ["RichTextLabel"]:
		t.set_color("default_color", cls, Color(str(p["text"])))

	# ---- ProgressBar ----
	t.set_stylebox("background", "ProgressBar", _box(Color(str(p["panel"])), Color(str(p["line"])), 1, 0))
	t.set_stylebox("fill", "ProgressBar", _box(Color(str(p["accent"])), Color(0, 0, 0, 0), 0, 0))
	t.set_color("font_color", "ProgressBar", Color(str(p["text"])))

	# ---- Slider ----
	t.set_stylebox("slider", "HSlider", _box(Color(str(p["panel"])), Color(str(p["line"])), 2, 1))
	t.set_stylebox("grabber_area", "HSlider", _box(Color(str(p["accent"])), Color(0, 0, 0, 0), 2, 1))
	t.set_stylebox("grabber_area_highlight", "HSlider", _box(Color(str(p["accent"])).lightened(0.2), Color(0, 0, 0, 0), 2, 1))

	# ---- CheckBox / OptionButton ----
	t.set_color("font_color", "CheckBox", Color(str(p["text"])))
	t.set_color("font_color", "OptionButton", Color(str(p["text"])))
	t.set_stylebox("normal", "OptionButton", btn_normal)
	t.set_stylebox("hover", "OptionButton", _box(Color(str(p["panel_alt"])).lightened(0.1), Color(str(p["accent"]))))
	t.set_stylebox("pressed", "OptionButton", _box(Color(str(p["accent"])).darkened(0.3), Color(str(p["accent"]))))
	t.set_color("font_color", "OptionButton", Color(str(p["text"])))

	# ---- ScrollContainer ----
	t.set_stylebox("panel", "ScrollContainer", _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 0))

	# ---- TabContainer ----
	t.set_stylebox("panel", "TabContainer", _box(Color(str(p["panel"])), Color(str(p["line"]))))
	t.set_color("font_selected_color", "TabContainer", Color(str(p["text"])))
	t.set_color("font_unselected_color", "TabContainer", Color(str(p["text_dim"])))

	return t


static func _box(bg: Color, border: Color, border_width: int = 1, radius: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_width)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	return sb


static func flat(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	return sb


static func heading(text: String, size: int = 22) -> Label:
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(str(palette()["text"])))
	l.add_theme_constant_override("outline_size", 0)
	return l


static func dim(text: String, size: int = 10) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(str(palette()["text_dim"])))
	return l
