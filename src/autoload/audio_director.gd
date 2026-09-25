extends Node
## AudioDirector -- owns the mixer, one-shot SFX pool and the dynamic
## heartbeat / chase music that reacts to the terror radius.
##
## Audio files are synthesised offline by tools/gen_audio.py and imported as
## res://assets/audio/*.wav. A missing file degrades silently to no sound so a
## stripped build still runs.

const AUDIO_DIR := "res://assets/audio/"

enum Bus { MASTER, SFX, MUSIC, AMBIENT }

var _pool: Array[AudioStreamPlayer] = []
var _pool_index := 0
const POOL_SIZE := 24

var _music_player: AudioStreamPlayer
var _ambient_player: AudioStreamPlayer
var _heart_player: AudioStreamPlayer
var _streams: Dictionary = {}
var _heartbeat_level := 0.0
var _heartbeat_phase := 0.0
var _heartbeat_bpm := 55.0
var _hooked_player: AudioStreamPlayer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_buses()

	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_pool.append(p)

	_music_player = AudioStreamPlayer.new()
	_music_player.bus = "Music"
	add_child(_music_player)

	_ambient_player = AudioStreamPlayer.new()
	_ambient_player.bus = "Ambient"
	add_child(_ambient_player)

	_heart_player = AudioStreamPlayer.new()
	_heart_player.bus = "SFX"
	add_child(_heart_player)

	_hooked_player = AudioStreamPlayer.new()
	_hooked_player.bus = "SFX"
	add_child(_hooked_player)

	_preload_streams()
	_apply_volumes()
	EventBus.settings_changed.connect(_apply_volumes)
	EventBus.terror_level.connect(set_terror_level)


func _ensure_buses() -> void:
	for entry in [["SFX", Bus.SFX], ["Music", Bus.MUSIC], ["Ambient", Bus.AMBIENT]]:
		var name: String = entry[0]
		if AudioServer.get_bus_index(name) == -1:
			AudioServer.add_bus()
			var idx := AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, name)
			AudioServer.set_bus_send(idx, "Master")


func _apply_volumes() -> void:
	_set_bus_db("Master", GameConfig.master_volume)
	_set_bus_db("SFX", GameConfig.sfx_volume)
	_set_bus_db("Music", GameConfig.music_volume)
	_set_bus_db("Ambient", GameConfig.master_volume)


func _set_bus_db(bus_name: String, linear: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	AudioServer.set_bus_mute(idx, linear <= 0.001)
	AudioServer.set_bus_volume_db(idx, linear_to_db(clampf(linear, 0.0001, 1.0)))


func _preload_streams() -> void:
	var names := [
		"heartbeat", "heartbeat_fast", "gen_loop", "gen_done", "gen_explode",
		"skillcheck_appear", "skillcheck_good", "skillcheck_great", "skillcheck_miss",
		"hit", "hit_heavy", "scream_m", "scream_f", "hook", "unhook", "sacrifice",
		"pallet_drop", "pallet_break", "pallet_stun", "vault", "window_break",
		"locker_enter", "locker_exit", "locker_grab",
		"gate_switch", "gate_open", "hatch_open", "hatch_enter",
		"trap_place", "trap_snap", "trap_escape", "chest_open",
		"footstep_grass", "footstep_wood", "footstep_dirt",
		"heal_loop", "heal_done", "ui_click", "ui_hover", "ui_back", "ui_error",
		"tier_up", "bloodlust", "chase_start", "chase_end", "mori",
		"ambient_wind", "ambient_drone", "music_menu", "music_chase", "music_calm",
	]
	for n in names:
		var path: String = AUDIO_DIR + str(n) + ".wav"
		if ResourceLoader.exists(path):
			_streams[n] = load(path)


func has_sound(name: String) -> bool:
	return _streams.has(name)


## Fire-and-forget positional-free SFX on the pooled players.
func play(name: String, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	if not _streams.has(name):
		return
	var p := _pool[_pool_index]
	_pool_index = (_pool_index + 1) % POOL_SIZE
	p.stream = _streams[name]
	p.volume_db = volume_db
	p.pitch_scale = pitch
	p.play()


func play_at(name: String, pos: Vector2, camera: Camera2D, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	if not _streams.has(name) or camera == null:
		play(name, volume_db, pitch)
		return
	# Cheap 2D falloff: distance from the camera centre drives volume.
	var dist := camera.global_position.distance_to(pos)
	var falloff := clampf(1.0 - dist / (GameConfig.TERROR_RADIUS * 1.6), 0.0, 1.0)
	if falloff <= 0.02:
		return
	play(name, volume_db + linear_to_db(falloff), pitch)


func play_loop(name: String, on_player: AudioStreamPlayer) -> void:
	if not _streams.has(name):
		return
	var s: AudioStream = _streams[name]
	if s is AudioStreamWAV:
		s.loop_mode = AudioStreamWAV.LOOP_FORWARD
	on_player.stream = s
	on_player.play()


func start_ambient() -> void:
	if _ambient_player.playing:
		return
	_ambient_player.volume_db = -8.0
	play_loop("ambient_wind", _ambient_player)


func stop_ambient() -> void:
	_ambient_player.stop()


func play_music(name: String, volume_db: float = -6.0) -> void:
	if not _streams.has(name):
		_music_player.stop()
		return
	if _music_player.stream == _streams[name] and _music_player.playing:
		return
	_music_player.volume_db = volume_db
	play_loop(name, _music_player)


func stop_music() -> void:
	_music_player.stop()


# ---------------------------------------------------------------------------
# Dynamic heartbeat driven by the terror radius (0..1)
# ---------------------------------------------------------------------------
func set_terror_level(level: float) -> void:
	_heartbeat_level = clampf(level, 0.0, 1.0)
	if _heartbeat_level <= 0.01:
		if _heart_player.playing:
			_heart_player.stop()
		return
	_heartbeat_bpm = lerpf(52.0, 140.0, _heartbeat_level)
	_heart_player.volume_db = lerpf(-22.0, -4.0, _heartbeat_level)


func _process(delta: float) -> void:
	if _heartbeat_level <= 0.01:
		return
	_heartbeat_phase += delta * _heartbeat_bpm / 60.0
	if _heartbeat_phase >= 1.0:
		_heartbeat_phase -= 1.0
		var snd := "heartbeat" if _heartbeat_level < 0.5 else "heartbeat_fast"
		if _streams.has(snd):
			_heart_player.stream = _streams[snd]
			_heart_player.pitch_scale = lerpf(0.95, 1.25, _heartbeat_level)
			_heart_player.play()


func hooked_loop(on: bool) -> void:
	if on:
		if not _hooked_player.playing:
			play_loop("heal_loop", _hooked_player)
			_hooked_player.volume_db = -20.0
	else:
		_hooked_player.stop()
