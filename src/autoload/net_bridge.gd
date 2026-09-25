extends Node
## NetBridge -- the one object gameplay code talks to about networking.
## It owns whichever NetBase backend is active and republishes its events as
## plain signals so nothing else imports a transport class.

signal remote_state_received(peer: int, data: Dictionary)
signal remote_input_received(peer: int, move: Vector2, gait: int, action: String, tick_no: int)
signal match_start_signal()

var backend: NetBase
var pending_match: Dictionary = {}
var server_clock := 0.0
var tick_no := 0
var _last_input_sent := 0.0
const INPUT_SEND_INTERVAL := 0.05    ## 20 Hz uplink

## Latest known authoritative transform per peer, used for interpolation.
var remote_transforms: Dictionary = {}   ## peer -> {pos, vel, gait, state, time}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	use_offline()


func use_offline() -> void:
	_swap(NetOffline.new())
	GameConfig.net_mode = Enums.NetMode.OFFLINE


func use_lan() -> void:
	_swap(NetEnet.new())
	GameConfig.net_mode = Enums.NetMode.LAN


func use_p2p() -> void:
	_swap(NetWebRTC.new())
	GameConfig.net_mode = Enums.NetMode.P2P


## Swaps the active transport. Backends are Nodes so they can own a
## MultiplayerAPI, therefore they must live in the tree.
func _swap(next: NetBase) -> void:
	if backend != null and is_instance_valid(backend):
		backend.shutdown()
		if backend.get_parent() == self:
			remove_child(backend)
		backend.queue_free()
	backend = next
	if next.get_parent() == null:
		add_child(next)


func boss() -> NetBase:
	return backend


func is_online() -> bool:
	return backend != null and backend.kind != NetBase.Kind.OFFLINE


func is_server() -> bool:
	return backend == null or backend.is_server()


func local_id() -> int:
	return 1 if backend == null else backend.local_id()


func peers() -> Array:
	return [] if backend == null else backend.peers


func lobby() -> Dictionary:
	return {} if backend == null else backend.lobby


func host(port: int) -> Error:
	if backend == null:
		use_offline()
	return backend.host(port)


func join(address: String, port: int) -> Error:
	if backend == null:
		use_offline()
	return backend.join(address, port)


func disconnect_now() -> void:
	if backend != null:
		backend.shutdown()
	use_offline()


func _process(delta: float) -> void:
	if backend == null or not is_online():
		return
	server_clock += delta
	backend.tick(delta)
	_prune_remote()


func _prune_remote() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var dead: Array = []
	for peer in remote_transforms.keys():
		if now - float(remote_transforms[peer].get("time", now)) > 2.0:
			dead.append(peer)
	for d in dead:
		remote_transforms.erase(d)


## Called by the local actor each frame. Rate-limited to 20 Hz.
func send_input(move: Vector2, gait: int, action: String) -> void:
	if backend == null or not is_online() or is_server():
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_input_sent < INPUT_SEND_INTERVAL:
		return
	_last_input_sent = now
	tick_no += 1
	backend.rpc_input(local_id(), move, gait, action, tick_no)


## Called by the authority each network tick.
func broadcast_state(peer: int, data: Dictionary) -> void:
	if backend == null or not is_online() or not is_server():
		return
	data["time"] = Time.get_ticks_msec() / 1000.0
	backend.rpc_state(peer, data)


func push_remote_state(peer: int, data: Dictionary) -> void:
	remote_transforms[peer] = data
	remote_state_received.emit(peer, data)


## Linear interpolation sample for a remote peer's position.
func sample_remote(peer: int, fallback: Vector2) -> Vector2:
	if not remote_transforms.has(peer):
		return fallback
	var d: Dictionary = remote_transforms[peer]
	return d.get("pos", fallback)
