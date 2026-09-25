class_name NetEnet
extends NetBase
## NetEnet -- LAN play. Host is authoritative; clients upload input only.
## Uses Godot's high level ENetMultiplayerPeer which already handles
## connection, channels and RPC routing.

const DEFAULT_PORT := 27015
const MAX_PEERS := 5

var _peer: ENetMultiplayerPeer
var _server_mode := false


func _init() -> void:
	kind = Kind.LAN


func host(port: int) -> Error:
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port if port > 0 else DEFAULT_PORT, MAX_PEERS - 1)
	if err != OK:
		last_error = "create_server failed (%d)" % err
		return err
	multiplayer.multiplayer_peer = _peer
	_server_mode = true
	is_active = true
	_bind_signals()
	peers = [1]
	lobby[1] = {"role": -1, "char": "", "ready": false}
	EventBus.net_lobby_changed.emit(lobby)
	return OK


func join(address: String, port: int) -> Error:
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(address, port if port > 0 else DEFAULT_PORT)
	if err != OK:
		last_error = "create_client failed (%d)" % err
		return err
	multiplayer.multiplayer_peer = _peer
	_server_mode = false
	is_active = true
	_bind_signals()
	return OK


func _bind_signals() -> void:
	var mp := multiplayer
	if not mp.peer_connected.is_connected(_on_peer_connected):
		mp.peer_connected.connect(_on_peer_connected)
		mp.peer_disconnected.connect(_on_peer_disconnected)
		mp.connected_to_server.connect(_on_connected_ok)
		mp.connection_failed.connect(_on_connection_failed)
		mp.server_disconnected.connect(_on_server_disconnected)


func _on_peer_connected(id: int) -> void:
	if not peers.has(id):
		peers.append(id)
	if not lobby.has(id):
		lobby[id] = {"role": -1, "char": "", "ready": false}
	EventBus.net_peer_joined.emit(id)
	EventBus.net_lobby_changed.emit(lobby)


func _on_peer_disconnected(id: int) -> void:
	peers.erase(id)
	lobby.erase(id)
	EventBus.net_peer_left.emit(id)
	EventBus.net_lobby_changed.emit(lobby)


func _on_connected_ok() -> void:
	is_active = true
	EventBus.toast.emit(Locale.t("mp.connected"), Color(0.45, 0.85, 0.45))


func _on_connection_failed() -> void:
	is_active = false
	last_error = "connection failed"
	EventBus.toast.emit(Locale.t("mp.disconnected"), Color(0.9, 0.34, 0.28))


func _on_server_disconnected() -> void:
	is_active = false
	EventBus.toast.emit(Locale.t("mp.disconnected"), Color(0.9, 0.34, 0.28))


func shutdown() -> void:
	if _peer != null:
		_peer.close()
	multiplayer.multiplayer_peer = null
	_peer = null
	super.shutdown()


func is_server() -> bool:
	return _server_mode


func local_id() -> int:
	return multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 1


func rpc_register_player(peer: int, role: int, char_id: String) -> void:
	lobby[peer] = {"role": role, "char": char_id, "ready": false}
	_lobby_rpc.rpc(peer, role, char_id)


func rpc_set_ready(peer: int, ready: bool) -> void:
	if lobby.has(peer):
		lobby[peer]["ready"] = ready
	_ready_rpc.rpc(peer, ready)


func rpc_start_match(seed_value: int, map_id: String, killer_id: String) -> void:
	_start_rpc.rpc(seed_value, map_id, killer_id)


func rpc_state(peer: int, data: Dictionary) -> void:
	_state_rpc.rpc(peer, data)


func rpc_input(peer: int, move: Vector2, gait: int, action: String, tick_no: int) -> void:
	if _server_mode:
		return
	_input_rpc.rpc_id(1, peer, move, gait, action, tick_no)


@rpc("any_peer", "call_remote", "reliable")
func _lobby_rpc(peer: int, role: int, char_id: String) -> void:
	lobby[peer] = {"role": role, "char": char_id, "ready": false}
	EventBus.net_lobby_changed.emit(lobby)


@rpc("any_peer", "call_remote", "reliable")
func _ready_rpc(peer: int, ready: bool) -> void:
	if lobby.has(peer):
		lobby[peer]["ready"] = ready
	EventBus.net_lobby_changed.emit(lobby)


@rpc("any_peer", "call_remote", "reliable")
func _start_rpc(seed_value: int, map_id: String, killer_id: String) -> void:
	NetBridge.pending_match = {"seed": seed_value, "map": map_id, "killer": killer_id}
	NetBridge.match_start_signal.emit()


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _state_rpc(peer: int, data: Dictionary) -> void:
	NetBridge.remote_state_received.emit(peer, data)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _input_rpc(peer: int, move: Vector2, gait: int, action: String, tick_no: int) -> void:
	NetBridge.remote_input_received.emit(peer, move, gait, action, tick_no)
