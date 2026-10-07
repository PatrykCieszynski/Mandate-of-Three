extends ServerInstance
## Session adapter: preserves the authenticated instance lifecycle, bypassing
## legacy Player/Map/weapon/status systems until their domains are rebuilt.

var map_3d: SpikeWorld3D

func load_map(map_path: String) -> void:
	own_world_3d = true
	var scene: PackedScene = load(map_path)
	map_3d = scene.instantiate() as SpikeWorld3D
	add_child(map_3d)

func _ready() -> void:
	world_server.multiplayer_api.peer_disconnected.connect(map_3d.remove_peer)

@rpc("any_peer", "call_remote", "reliable", 0)
func ready_to_enter_instance() -> void:
	# The 3D map has its own authenticated join endpoint. Old 2D clients must
	# not enter the legacy spawn path with a missing Map2D.
	pass
