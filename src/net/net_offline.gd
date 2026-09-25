class_name NetOffline
extends NetBase
## NetOffline -- everything runs on one machine, AI fills the free seats.
## It reports itself as "server" so gameplay code takes the authoritative path
## without any special-casing.

func _init() -> void:
	kind = Kind.OFFLINE
	is_active = true


func is_server() -> bool:
	return true


func local_id() -> int:
	return 1
