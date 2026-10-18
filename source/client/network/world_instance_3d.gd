class_name WorldInstanceClient3D
extends Node
## The 3D world is a pure session container. Legacy InstanceClient RPC,
## Player and Map2D behavior is intentionally not inherited.

var identity: Dictionary = {}

## Keep the network signature aligned with the server's disabled compatibility
## RPC while clients migrate; 3D joins exclusively through GameWorld.join_world.
@rpc("any_peer", "call_remote", "reliable", 0)
func ready_to_enter_instance() -> void:
	pass
