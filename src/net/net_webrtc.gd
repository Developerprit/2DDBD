class_name NetWebRTC
extends NetBase
## NetWebRTC -- server-less peer-to-peer play.
##
## There is no signalling server: the two players copy/paste two short blocks of
## text (an SDP offer and an SDP answer) through any channel they already have
## (chat, mail, messenger). Everything after that is a direct WebRTC data
## channel between the two machines.
##
## Handshake, in order:
##   1. Host presses "Generate Offer"      -> gets OFFER text  -> sends to client
##   2. Client pastes OFFER, presses Accept -> gets ANSWER text -> sends to host
##   3. Host pastes ANSWER, presses Finish -> channel opens
##
## The host is authoritative, exactly like NetEnet, so gameplay code is shared.

const STUN_SERVERS := [
	{"urls": ["stun:stun.l.google.com:19302"]},
	{"urls": ["stun:stun1.l.google.com:19302"]},
]

enum Phase { IDLE, OFFER_READY, ANSWER_READY, CONNECTED, FAILED }

var phase: int = Phase.IDLE
var _mp: WebRTCMultiplayerPeer
var _conn: WebRTCPeerConnection
var _is_host := false
var _pending_answer := ""
var _gather_frames := 0
var _channel_ready := false


func _init() -> void:
	kind = Kind.P2P


func _make_connection() -> WebRTCPeerConnection:
	var c := WebRTCPeerConnection.new()
	c.initialize({"iceServers": STUN_SERVERS})
	c.session_description_created.connect(_on_session_description)
	c.ice_candidate_created.connect(_on_ice_candidate)
	return c


# ---------------------------------------------------------------------------
# Host side
# ---------------------------------------------------------------------------
func create_offer() -> String:
	_is_host = true
	_conn = _make_connection()
	_conn.create_offer()
	# Pump the connection until ICE gathering settles. This is synchronous-ish
	# polling because the whole thing happens inside a single editor/UI request.
	var guard := 0
	while _conn.get_local_description() == "" and guard < 600:
		_conn.poll()
		OS.delay_msec(4)
		guard += 1
	var desc: String = _conn.get_local_description()
	phase = Phase.OFFER_READY if desc != "" else Phase.FAILED
	if desc == "":
		last_error = "offer generation failed"
	return desc


func accept_offer(offer_text: String) -> bool:
	_is_host = false
	_conn = _make_connection()
	var err := _conn.set_remote_description("offer", offer_text.strip_edges())
	if err != OK:
		last_error = "bad offer (%d)" % err
		phase = Phase.FAILED
		return false
	_conn.create_answer()
	var guard := 0
	while _conn.get_local_description() == "" and guard < 600:
		_conn.poll()
		OS.delay_msec(4)
		guard += 1
	if _conn.get_local_description() == "":
		last_error = "answer generation failed"
		phase = Phase.FAILED
		return false
	phase = Phase.ANSWER_READY
	return true


func local_description() -> String:
	if _conn == null:
		return ""
	return _conn.get_local_description()


func finish_handshake(remote_text: String) -> bool:
	if _conn == null:
		return false
	var err := _conn.set_remote_description("answer", remote_text.strip_edges())
	if err != OK:
		last_error = "bad answer (%d)" % err
		phase = Phase.FAILED
		return false

	_mp = WebRTCMultiplayerPeer.new()
	if _is_host:
		err = _mp.create_server()
	else:
		err = _mp.create_client(1)
	if err != OK:
		last_error = "WebRTCMultiplayerPeer init failed (%d)" % err
		phase = Phase.FAILED
		return false

	_mp.add_peer(_conn, 2 if _is_host else 1)
	multiplayer.multiplayer_peer = _mp
	is_active = true
	phase = Phase.CONNECTED
	if _is_host:
		peers = [1, 2]
		lobby = {1: {"role": -1, "char": "", "ready": false}, 2: {"role": -1, "char": "", "ready": false}}
	else:
		peers = [1]
		lobby = {1: {"role": -1, "char": "", "ready": false}}

	var mp := multiplayer
	if not mp.peer_connected.is_connected(_on_peer_connected):
		mp.peer_connected.connect(_on_peer_connected)
		mp.peer_disconnected.connect(_on_peer_disconnected)
	EventBus.net_lobby_changed.emit(lobby)
	return true


func _on_peer_connected(id: int) -> void:
	_channel_ready = true
	if not peers.has(id):
		peers.append(id)
	if not lobby.has(id):
		lobby[id] = {"role": -1, "char": "", "ready": false}
	EventBus.net_peer_joined.emit(id)
	EventBus.net_lobby_changed.emit(lobby)
	EventBus.toast.emit(Locale.t("mp.connected"), Color(0.45, 0.85, 0.45))


func _on_peer_disconnected(id: int) -> void:
	peers.erase(id)
	lobby.erase(id)
	EventBus.net_peer_left.emit(id)


func _on_session_description(type: String, sdp: String) -> void:
	if _conn == null:
		return
	_conn.set_local_description(type, sdp)


func _on_ice_candidate(media: String, index: int, name: String) -> void:
	if _conn != null:
		_conn.add_ice_candidate(media, index, name)


func tick(_delta: float) -> void:
	if _conn != null and phase != Phase.CONNECTED:
		_conn.poll()


func shutdown() -> void:
	if _conn != null:
		_conn.close()
	_conn = null
	_mp = null
	multiplayer.multiplayer_peer = null
	phase = Phase.IDLE
	_channel_ready = false
	super.shutdown()


func is_server() -> bool:
	return _is_host


func local_id() -> int:
	return multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 1


func is_connected_now() -> bool:
	return phase == Phase.CONNECTED and _channel_ready


# ---------------------------------------------------------------------------
# RPC surface (identical semantics to NetEnet)
# ---------------------------------------------------------------------------
func rpc_register_player(peer: int, role: int, char_id: String) -> void:
	lobby[peer] = {"role": role, "char": char_id, "ready": false}
	if is_active:
		_lobby_rpc.rpc(peer, role, char_id)


func rpc_set_ready(peer: int, ready: bool) -> void:
	if lobby.has(peer):
		lobby[peer]["ready"] = ready
	if is_active:
		_ready_rpc.rpc(peer, ready)


func rpc_start_match(seed_value: int, map_id: String, killer_id: String) -> void:
	if is_active:
		_start_rpc.rpc(seed_value, map_id, killer_id)


func rpc_state(peer: int, data: Dictionary) -> void:
	if is_active:
		_state_rpc.rpc(peer, data)


func rpc_input(peer: int, move: Vector2, gait: int, action: String, tick_no: int) -> void:
	if is_active and not _is_host:
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
