class_name NetBase
extends Node
## Abstract network backend. Three concrete implementations exist:
##   NetOffline  -- single machine, AI fills the remaining seats
##   NetEnet     -- LAN host-authoritative using ENetMultiplayerPeer
##   NetWebRTC   -- server-less P2P using WebRTCMultiplayerPeer + manual
##                  offer/answer text exchange (copied by the player)
##
## Every backend speaks the same small surface so gameplay code never branches
## on transport.

enum Kind { OFFLINE, LAN, P2P }

var kind: int = Kind.OFFLINE
var peers: Array[int] = []
var lobby: Dictionary = {}          ## peer_id -> {"role": int, "char": String, "ready": bool}
var is_active := false
var last_error := ""


func host(_port: int) -> Error:
	return ERR_UNAVAILABLE


func join(_address: String, _port: int) -> Error:
	return ERR_UNAVAILABLE


func shutdown() -> void:
	is_active = false
	peers.clear()
	lobby.clear()


func is_server() -> bool:
	return false


func local_id() -> int:
	return 1


## Called once per frame by NetBridge.
func tick(_delta: float) -> void:
	pass

# ---------------------------------------------------------------------------
# RPC surface -- implemented by concrete backends. Gameplay calls these
# through NetBridge and they become no-ops in offline play.
# ---------------------------------------------------------------------------

func rpc_register_player(_peer: int, _role: int, _char_id: String) -> void:
	pass


func rpc_set_ready(_peer: int, _ready: bool) -> void:
	pass


func rpc_start_match(_seed: int, _map_id: String, _killer_id: String) -> void:
	pass


func rpc_input(_peer: int, _move: Vector2, _gait: int, _action: String, _tick_no: int) -> void:
	pass


func rpc_state(_peer: int, _data: Dictionary) -> void:
	pass


func rpc_interact(_peer: int, _node_path: String, _kind: int) -> void:
	pass
