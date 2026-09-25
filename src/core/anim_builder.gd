class_name AnimBuilder
extends RefCounted
## Builds SpriteFrames resources from the generated pixel-art atlases.
##
## The atlas layout is produced by tools/gen_sprites.py and described in
## src/data/sprite_manifest.json. Every row is one animation laid out left to
## right; this class slices them into AtlasTexture frames.

const MANIFEST_PATH := "res://src/data/sprite_manifest.json"
const SURVIVOR_DIR := "res://assets/sprites/survivor/survivor_%s.png"
const KILLER_DIR := "res://assets/sprites/killer/killer_%s.png"

## Which game-level animations exist for each facing suffix.
const SURVIVOR_ANIM_NAMES := {
	"idle": "idle_%s",
	"walk": "walk_%s",
	"run": "run_%s",
	"crouch_idle": "crouch_%s",
	"crouch_run": "crouchwalk_%s",
	"vault": "vault_%s",
}

const KILLER_ANIM_NAMES := {
	"idle": "idle_%s",
	"walk": "walk_%s",
	"chase": "chase_%s",
	"attack": "attack_%s",
}

static var _manifest: Dictionary = {}


static func manifest() -> Dictionary:
	if _manifest.is_empty() and FileAccess.file_exists(MANIFEST_PATH):
		var f := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			f.close()
			if typeof(parsed) == TYPE_DICTIONARY:
				_manifest = parsed
	return _manifest


static func _atlas_texture(sprite_set: String) -> Texture2D:
	var path := KILLER_DIR % sprite_set if _is_killer else SURVIVOR_DIR % sprite_set
	if not ResourceLoader.exists(path):
		push_warning("AnimBuilder: missing atlas %s" % path)
		return null
	return load(path) as Texture2D


static func _find_row(rows: Array, anim_name: String) -> Dictionary:
	for r in rows:
		var row: Dictionary = r
		if str(row.get("anim", "")) == anim_name:
			return row
	return {}


static func _add_anim(sf: SpriteFrames, rows: Array, anim_name: String, row_name: String,
		fps: float, loop: bool) -> void:
	var row := _find_row(rows, row_name)
	if row.is_empty():
		return
	if not sf.has_animation(anim_name):
		sf.add_animation(anim_name)
	sf.set_animation_speed(anim_name, fps)
	sf.set_animation_loop(anim_name, loop)
	var frames := int(row.get("frames", 1))
	var row_index := int(row.get("row", 0))
	var tex := _atlas_texture(_current_set)
	if tex == null:
		return
	for i in frames:
		var at := AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2(i * _frame_w, row_index * _frame_h, _frame_w, _frame_h)
		at.filter_clip = true
		sf.add_frame(anim_name, at)


static var _current_set := ""
static var _frame_w := 16
static var _frame_h := 22
static var _is_killer := false


static func build(sprite_set: String, is_killer: bool) -> SpriteFrames:
	_current_set = sprite_set
	_is_killer = is_killer
	_frame_w = 24 if is_killer else 16
	_frame_h = 30 if is_killer else 22
	var sf := SpriteFrames.new()
	if sf.has_animation("default"):
		sf.remove_animation("default")

	var rows: Array = []
	for entry in manifest().get("characters", []):
		var m: Dictionary = entry
		if int(m.get("frame_w", 0)) == _frame_w:
			rows = m.get("rows", [])
			break
	if rows.is_empty():
		# Fallback so the game still runs before assets are generated.
		sf.add_animation("idle_down")
		sf.add_frame("idle_down", PlaceholderTexture2D.new())
		return sf

	var table := KILLER_ANIM_NAMES if is_killer else SURVIVOR_ANIM_NAMES
	for gait in table.keys():
		var pattern: String = table[gait]
		for suffix in ["down", "up", "side"]:
			var row_name: String = pattern % suffix
			var fps := 6.0
			if gait in ["run", "chase"]:
				fps = 12.0
			elif gait in ["walk", "crouch_run"]:
				fps = 8.0
			elif gait in ["vault", "attack"]:
				fps = 14.0
			_add_anim(sf, rows, "%s_%s" % [gait, suffix], row_name, fps,
					gait not in ["vault", "attack"])

	# Single-part animations have no facing variants.
	_add_anim(sf, rows, "repair", "repair", 5.0, true)
	_add_anim(sf, rows, "heal", "heal", 5.0, true)
	_add_anim(sf, rows, "downed", "downed", 2.0, true)
	_add_anim(sf, rows, "hooked", "hooked", 2.0, true)
	_add_anim(sf, rows, "struggle", "struggle", 6.0, true)
	_add_anim(sf, rows, "carried", "carried", 6.0, true)
	_add_anim(sf, rows, "dead", "dead", 2.0, true)
	_add_anim(sf, rows, "stun", "stun", 4.0, true)
	_add_anim(sf, rows, "place", "place_down", 6.0, true)
	_add_anim(sf, rows, "pickup", "pickup_side", 6.0, true)
	_add_anim(sf, rows, "hooking", "hooking_down", 6.0, false)
	_add_anim(sf, rows, "lunge", "lunge_down", 15.0, false)
	_add_anim(sf, rows, "carry_side", "carry_side", 6.0, true)

	if not sf.has_animation("idle_down"):
		# Last-resort fallback: reuse whatever exists so nothing crashes.
		var names := sf.get_animation_names()
		if names.is_empty():
			sf.add_animation("idle_down")
			sf.add_frame("idle_down", PlaceholderTexture2D.new())
		else:
			sf.add_animation("idle_down")
			for fr in sf.get_frame_count(names[0]):
				sf.add_frame("idle_down", sf.get_frame_texture(names[0], fr))
	return sf


## Convenience helper for the many UI places that need a prop icon.
static func prop_texture(name: String) -> Texture2D:
	var path := "res://assets/sprites/props/%s.png" % name
	return load(path) if ResourceLoader.exists(path) else null


## Slice a single-row strip PNG (frames laid out left to right) into SpriteFrames.
static func strip(path: String, frame_w: int, frame_h: int, fps: float = 6.0,
		loop: bool = true) -> SpriteFrames:
	var sf := SpriteFrames.new()
	if sf.has_animation("default"):
		sf.remove_animation("default")
	sf.add_animation("anim")
	sf.set_animation_speed("anim", fps)
	sf.set_animation_loop("anim", loop)
	if not ResourceLoader.exists(path):
		sf.add_frame("anim", PlaceholderTexture2D.new())
		return sf
	var tex := load(path) as Texture2D
	var count := maxi(1, int(tex.get_width() / frame_w))
	for i in count:
		var at := AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2(i * frame_w, 0, frame_w, frame_h)
		at.filter_clip = true
		sf.add_frame("anim", at)
	return sf


static func icon_atlas() -> Texture2D:
	var path := "res://assets/sprites/ui/icons.png"
	return load(path) if ResourceLoader.exists(path) else null


static func tile_atlas() -> Texture2D:
	var path := "res://assets/sprites/tiles/tiles.png"
	return load(path) if ResourceLoader.exists(path) else null


static func icon(name: String) -> AtlasTexture:
	var m: Dictionary = manifest().get("atlases", {}).get("icons", {})
	var names: Array = m.get("names", [])
	var idx := names.find(name)
	if idx < 0:
		return null
	var tex := icon_atlas()
	if tex == null:
		return null
	var cols := int(m.get("cols", 8))
	var fw := int(m.get("frame_w", 16))
	var at := AtlasTexture.new()
	at.atlas = tex
	at.region = Rect2((idx % cols) * fw, (idx / cols) * fw, fw, fw)
	return at


static func tile_index(name: String) -> int:
	var m: Dictionary = manifest().get("atlases", {}).get("tiles", {})
	var names: Array = m.get("names", [])
	return names.find(name)
