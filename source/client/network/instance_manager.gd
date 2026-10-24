class_name InstanceManagerClient
extends Node


signal instance_changed(instance: WorldInstanceClient3D)
signal channels_changed(catalogue: Dictionary)
signal channel_selection_finished(result: Dictionary)
signal transfer_changed(result: Dictionary)


var current_instance: WorldInstanceClient3D
var auto_select_channel: bool = true
var channels: Dictionary = {}
var _next_channel_request: int = 1
var _catalogue_request: int = 0
var _selection_request: int = 0
var transfer: Dictionary = {"phase":"idle"}


func reset_channel_flow() -> void:
	channels = {}
	transfer = {"phase":"idle"}
	_catalogue_request = 0
	_selection_request = 0
	_next_channel_request = 1


func refresh_channels() -> void:
	_catalogue_request = _next_channel_request
	_next_channel_request += 1
	request_channels.rpc_id(1, _catalogue_request)


func select_initial_channel(channel_id: int) -> void:
	if current_instance != null: return
	_selection_request = _next_channel_request
	_next_channel_request += 1
	request_initial_channel.rpc_id(1, _selection_request, channel_id)


func channel_transfer(action: String, channel_id: int = 0) -> void:
	var request_id := _next_channel_request
	_next_channel_request+=1
	request_transfer.rpc_id(1,request_id,action,channel_id,int(transfer.get("attempt",0)),int(transfer.get("epoch",0)))


@rpc("any_peer", "call_remote", "reliable", 0)
func request_transfer(_request_id: int, _action: String, _channel: int, _attempt: int, _epoch: int) -> void: pass


@rpc("authority", "call_remote", "reliable", 0)
func receive_transfer(_request_id: int, result: Dictionary) -> void:
	var incoming: Dictionary = result.get("transfer",{})
	if int(incoming.get("attempt",0))<int(transfer.get("attempt",0)): return
	transfer=incoming.duplicate(true)
	transfer_changed.emit(result)


@rpc("any_peer", "call_remote", "reliable", 0)
func request_channels(_request_id: int) -> void: pass


@rpc("any_peer", "call_remote", "reliable", 0)
func request_initial_channel(_request_id: int, _channel_id: int) -> void: pass


@rpc("authority", "call_remote", "reliable", 0)
func receive_channels(request_id: int, result: Dictionary) -> void:
	if request_id != _catalogue_request: return
	channels = result.duplicate(true)
	channels_changed.emit(channels)
	if current_instance==null and auto_select_channel and result.get("ok", false) and _selection_request == 0:
		select_initial_channel(0)


@rpc("authority", "call_remote", "reliable", 0)
func receive_channel_selection(request_id: int, result: Dictionary) -> void:
	if request_id != _selection_request or current_instance != null: return
	channel_selection_finished.emit(result)


func _ready() -> void:
	pass


## Free the live world before returning to the
## gateway. The instance lives under persistent Client; GameWorld owns its UI.
## Scene reload alone does not free the world. Transition calls this first.
func teardown() -> void:
	reset_channel_flow()
	auto_select_channel = true
	if current_instance and is_instance_valid(current_instance):
		current_instance.queue_free()
	current_instance = null
	ClientState.menu_open = false


@rpc("authority", "call_remote", "reliable", 0)
func charge_new_instance(map_path: String, instance_id: String, identity: Dictionary = {}) -> void:
	if not identity.is_empty() and (not preload("res://source/common/gameplay/maps/instance/map_instance_identity.gd").valid(identity) or identity.instance_id!=instance_id):
		push_error("Invalid map instance identity")
		return
	if is_instance_valid(current_instance) and str(current_instance.name) == instance_id:
		return # A replayed accepted assignment must not recreate the map.
	# Positional banners (sealed portal / level warning) are about the map we're
	# LEAVING — kill them so they never follow the player into the next biome.
	Announcer.dismiss_positional()
	var scene: PackedScene = load(map_path)
	if scene == null:
		push_error("Could not load instance map: " + map_path)
		return
	var loaded_map: Node = scene.instantiate()
	if not loaded_map is GameWorld3D:
		push_error("Unsupported non-3D instance map: " + map_path)
		if loaded_map != null:
			loaded_map.free()
		return
	_charge_3d_instance(loaded_map as GameWorld3D, instance_id, identity)


func _charge_3d_instance(map: Node3D, instance_id: String, identity: Dictionary = {}) -> void:
	if current_instance != null:
		current_instance.queue_free()
	ClientState.menu_open = false
	var instance: WorldInstanceClient3D = preload("res://source/client/network/world_instance_3d.gd").new()
	instance.name = instance_id
	instance.identity=identity.duplicate(true)
	current_instance = instance
	instance.add_child(map)
	add_child(instance, true)
	instance_changed.emit(instance)
	
