class_name InstanceManagerClient
extends Node


signal instance_changed(instance: InstanceClient)


var current_instance: InstanceClient


func _ready() -> void:
	pass


## Free the live world and clear InstanceClient statics before returning to the
## gateway. The instance lives under persistent Client; GameWorld owns its UI.
## Scene reload alone does not free the world. Transition calls this first.
func teardown() -> void:
	if current_instance and is_instance_valid(current_instance):
		current_instance.queue_free()
	current_instance = null
	InstanceClient.current = null
	InstanceClient.local_player = null
	ClientState.local_player = null
	ClientState.menu_open = false


@rpc("authority", "call_remote", "reliable", 0)
func charge_new_instance(map_path: String, instance_id: String, identity: Dictionary = {}) -> void:
	if not identity.is_empty() and (not preload("res://source/common/gameplay/maps/instance/map_instance_identity.gd").valid(identity) or identity.instance_id!=instance_id):
		push_error("Invalid map instance identity")
		return
	# Positional banners (sealed portal / level warning) are about the map we're
	# LEAVING — kill them so they never follow the player into the next biome.
	Announcer.dismiss_positional()
	var scene: PackedScene = load(map_path)
	if scene == null:
		push_error("Could not load instance map: " + map_path)
		return
	var loaded_map: Node = scene.instantiate()
	if loaded_map is GameWorld3D:
		_charge_3d_instance(loaded_map, instance_id, identity)
		return
	var new_instance: InstanceClient = InstanceClient.new()
	new_instance.name = instance_id
	new_instance.identity=identity.duplicate(true)
	
	print("Loading new map: %s." % map_path)
	var map: Map = loaded_map as Map
	if not map:
		loaded_map.free()
		new_instance.free()
		return
	new_instance.instance_map = map
	
	map.ready.connect(
		new_instance.ready_to_enter_instance.rpc_id.bind(1),
		CONNECT_ONE_SHOT
	)
	map.ready.connect(
		instance_changed.emit.bind(new_instance),
		CONNECT_ONE_SHOT
	)
	# First-visit region banner (client-only cosmetic; no-op for known/unlisted maps).
	map.ready.connect(
		ZoneDiscovery.on_map_loaded.bind(map_path),
		CONNECT_ONE_SHOT
	)
	
	if current_instance:
		if current_instance.local_player:
			current_instance.instance_map.remove_child(current_instance.local_player)
			#current_instance.local_player.reparent(new_instance, false)
		current_instance.queue_free()
	current_instance = new_instance

	new_instance.add_child(map, true)
	add_child(new_instance, true)
	


func _charge_3d_instance(map: Node3D, instance_id: String, identity: Dictionary = {}) -> void:
	if current_instance != null:
		current_instance.queue_free()
	InstanceClient.local_player = null
	ClientState.local_player = null
	ClientState.menu_open = false
	var instance: InstanceClient = preload("res://source/client/network/world_instance_3d.gd").new()
	instance.name = instance_id
	instance.identity=identity.duplicate(true)
	current_instance = instance
	instance.add_child(map)
	add_child(instance, true)
	instance_changed.emit(instance)
	
