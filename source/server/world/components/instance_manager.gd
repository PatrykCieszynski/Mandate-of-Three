class_name InstanceManagerServer
extends SubViewportContainer


const INSTANCE_COLLECTION_PATH: String = "res://source/common/gameplay/maps/instance/instance_collection/"
const GLOBAL_COMMANDS_PATH: String = "res://source/server/world/components/chat_command/global_commands/"
## Name of the InstanceResource used as the jail. Create a .tres with
## instance_name = "jail" to enable the jail system.
const JAIL_INSTANCE_NAME: String = "jail"
## Production First Region entry/recall resource.
const RECALL_INSTANCE_NAME: String = "FirstRegion"
const DEFAULT_INSTANCE_NAME: String = "FirstRegion"

var loading_instances: Dictionary[String, ServerInstance]
@export var realm_id: StringName = &"local"
@export var host_id: StringName = &"local-world"
const MapIdentity = preload("res://source/common/gameplay/maps/instance/map_instance_identity.gd")
var instance_collection: Dictionary[String, InstanceResource]
var default_instance: InstanceResource

@export var world_server: WorldServer


func start_instance_manager() -> void:
	ServerInstance.world_server = world_server
	
	setup_global_commands_and_roles()

	set_instance_collection.call_deferred()
	world_server.multiplayer_api.peer_connected.connect(_on_peer_connected)

	# Timer which will call unload_unused_instances
	var timer: Timer = Timer.new()
	timer.wait_time = 20.0 # 20.0 is for testing, consider increasing it

	timer.autostart = true
	timer.timeout.connect(unload_unused_instances)
	add_sibling(timer)



func setup_global_commands_and_roles() -> void:
	var files: PackedStringArray = FileUtils.get_all_file_at(GLOBAL_COMMANDS_PATH, "*.gd")
	if files.is_empty():
		return
	
	var commands := ServerInstance.global_chat_commands
	for file_path: String in files:
		var command = load(file_path).new()
		commands.set(command.command_name, command)

	var roles := ServerInstance.global_role_definitions
	for role: String in roles:
		var role_data: Dictionary = roles[role]
		var role_commands: Array
		
		for command_name: String in commands:
			var command = commands[command_name]
			if command.command_priority <= role_data.get("priority", 0):
				role_commands.append(command_name)

		role_data['commands'] = role_commands


@rpc("authority", "call_remote", "reliable", 0)
func charge_new_instance(_map_path: String, _instance_id: String, _identity: Dictionary = {}) -> void:
	pass


## Every login uses the technical map; no Ekonia tutorial/hub routing.
func _on_peer_connected(peer_id: int) -> void:
	var admitted: PlayerResource = world_server.connected_players.get(peer_id)
	if admitted == null or admitted.current_peer_id != peer_id or world_server.player_id_to_peer_id.get(admitted.player_id, 0) != peer_id:
		return
	if find_instance_for_peer(peer_id)!=null: return
	if default_instance == null:
		push_error("No technical default instance configured.")
		return
	# Duplicate connection notifications must not reserve/spawn a second actor.
	for existing: ServerInstance in _instances_for(default_instance):
		if existing.connected_peers.has(peer_id): return
		if existing.awaiting_peers.has(peer_id):
			if existing.awaiting_peers[peer_id].get("session")==admitted: return
			existing.awaiting_peers.erase(peer_id)
	var instance := select_entry_instance(default_instance)
	if instance == null:
		push_error("Could not create the technical default instance.")
		return
	instance.awaiting_peers[peer_id] = {"session":admitted}
	if instance.is_node_ready():
		_publish_entry(peer_id,admitted,instance)
	else:
		instance.ready.connect(_publish_entry.bind(peer_id,admitted,instance),CONNECT_ONE_SHOT)

func _publish_entry(peer_id: int, admitted: PlayerResource, instance: ServerInstance) -> void:
	if not is_instance_valid(instance): return
	if world_server.connected_players.get(peer_id)!=admitted or admitted.current_peer_id!=peer_id or world_server.player_id_to_peer_id.get(admitted.player_id,0)!=peer_id:
		if instance.awaiting_peers.get(peer_id,{}).get("session")==admitted: instance.awaiting_peers.erase(peer_id)
		return
	if instance.awaiting_peers.get(peer_id,{}).get("session")==admitted:
		charge_new_instance.rpc_id(peer_id,instance.instance_resource.map_path,str(instance.name),instance.identity)

func _instances_for(resource: InstanceResource) -> Array[ServerInstance]:
	var result: Array[ServerInstance] = []
	for instance: ServerInstance in loading_instances.values():
		if is_instance_valid(instance) and instance.instance_resource==resource and not instance.is_queued_for_deletion(): result.append(instance)
	for instance: ServerInstance in resource.charged_instances:
		if is_instance_valid(instance) and not instance.is_queued_for_deletion() and not result.has(instance): result.append(instance)
	result.sort_custom(func(a: ServerInstance,b: ServerInstance)->bool:return int(a.identity.get("channel_id",0))<int(b.identity.get("channel_id",0)))
	return result

func select_entry_instance(resource: InstanceResource) -> ServerInstance:
	var selected: ServerInstance
	var population := 2147483647
	for instance: ServerInstance in _instances_for(resource):
		var count := instance.connected_peers.size()+instance.awaiting_peers.size()
		if count<population:
			selected=instance
			population=count
	return charge_instance(resource) if selected==null else selected


func _on_player_entered_warper(player: Player, current_instance: ServerInstance, warper: Warper) -> void:
	# Jailed players can't traverse warpers — that's the whole point of jail.
	# We notify them once per attempt so they know it's intentional.
	if JailList.is_jailed(player.player_resource.account_name):
		world_server.chat_service.push_system_to_player(
			current_instance, player.player_resource.player_id,
			"You are jailed and cannot leave this area."
		)
		return

	var instance_index: int = -1 # Will be useful later
	var target_instance: ServerInstance
	var instance_resource: InstanceResource = warper.target_instance
	if not instance_resource:
		return

	if instance_resource.can_join_instance(player, instance_index):
		target_instance = instance_resource.get_instance()
		if target_instance:
			player_switch_instance(target_instance, warper.target_id, player, current_instance)
		else:
			queue_charge_instance(
				instance_resource,
				player_switch_instance.bind(warper.target_id, player, current_instance)
			)
	else:
		return


## Recall travel: send the peer to the town hub (RECALL_INSTANCE_NAME) at its
## default spawn (index 0). A faithful copy of send_player_to_jail — resolve the
## current instance authoritatively, charge the hub if it isn't live yet, then
## switch. Rolling our own current-instance lookup is what crashed recall before.
func recall_player(peer_id: int) -> void:
	var res: InstanceResource = instance_collection.get(RECALL_INSTANCE_NAME, null)
	if res == null:
		return
	var current_inst: ServerInstance = find_instance_for_peer(peer_id)
	if current_inst == null:
		return
	var player: Player = current_inst.get_player(peer_id)
	if player == null:
		return
	# Already in the hub — recall still yanks you to its spawn point (the hub is a
	# big map), via the same same-instance teleport /goto uses.
	if current_inst.instance_resource == res:
		teleport_peer_to(peer_id, current_inst, current_inst.instance_map.get_spawn_position(0))
		return
	if res.charged_instances.is_empty():
		queue_charge_instance(res, player_switch_instance.bind(0, player, current_inst))
	else:
		player_switch_instance(res.get_instance(), 0, player, current_inst)


func queue_charge_instance(instance_resource: InstanceResource, callback: Callable) -> void:
	for pending: ServerInstance in loading_instances.values():
		if pending.instance_resource==instance_resource:
			pending.ready.connect(callback.bind(pending),CONNECT_ONE_SHOT)
			return
	var new_instance: ServerInstance = prepare_instance(instance_resource)
	if new_instance==null: return
	new_instance.ready.connect(callback.bind(new_instance), CONNECT_ONE_SHOT)
	add_child(new_instance, true)


func player_switch_instance(
	target_instance: ServerInstance,
	warper_target_id: int,
	player: Player,
	current_instance: ServerInstance,
) -> void:
	var peer_id: int = player.name.to_int()
	if not world_server.database.flush_character(player.player_resource.player_id):
		push_error("Instance transfer cancelled: character checkpoints could not be saved.")
		return
	if current_instance.connected_peers.has(peer_id):
		current_instance.despawn_player(peer_id, false)
	else:
		return
	# Leaving a dungeon run drops this peer from its group.
	DungeonService.on_player_left(peer_id, current_instance)
	charge_new_instance.rpc_id(
		peer_id,
		target_instance.instance_resource.map_path,
		target_instance.name
	)
	target_instance.awaiting_peers[peer_id] = {
		"player": player,
		"target_id": warper_target_id
	}


func charge_instance(instance_resource: InstanceResource, channel_id: int = 0) -> ServerInstance:
	if channel_id>0:
		for existing: ServerInstance in _instances_for(instance_resource):
			if int(existing.identity.get("channel_id",0))==channel_id: return existing
	var new_instance: ServerInstance = prepare_instance(instance_resource,channel_id)
	if new_instance==null: return null
	add_child.call_deferred(new_instance, true)
	return new_instance


func prepare_instance(instance_resource: InstanceResource, channel_id: int = 0) -> ServerInstance:
	if instance_resource==null or not ResourceLoader.exists(instance_resource.map_path):
		push_error("Cannot load map instance: missing map resource")
		return null
	var instance: ServerInstance = ServerInstance.new()
	if instance_resource.use_3d:
		instance.free()
		instance = preload("res://source/server/world/components/world_instance_3d.gd").new()
	if instance_resource.use_3d and channel_id==0:
		channel_id=1
		for existing: ServerInstance in _instances_for(instance_resource): channel_id=maxi(channel_id,int(existing.identity.get("channel_id",0))+1)
	instance.identity=MapIdentity.create(realm_id,instance_resource.resolved_map_id(),host_id,channel_id)
	if not MapIdentity.valid(instance.identity):
		instance.free()
		push_error("Invalid map instance identity configuration")
		return null
	instance.name = instance.identity.instance_id
	loading_instances[str(instance.name)] = instance
	instance.instance_resource = instance_resource
	instance.tree_exiting.connect(func()->void:
		loading_instances.erase(str(instance.name))
		instance_resource.charged_instances.erase(instance),CONNECT_ONE_SHOT)
	instance.player_entered_warper.connect(_on_player_entered_warper)
	instance.ready.connect(
		func():
			loading_instances.erase(str(instance.name))
			instance_resource.charged_instances.append(instance),
		CONNECT_ONE_SHOT
	)
	instance.load_map(instance_resource.map_path)
	if instance_resource.use_3d and instance.get_node_or_null("GameWorld")==null:
		loading_instances.erase(str(instance.name))
		instance.free()
		return null
	return instance


func set_instance_collection() -> void:
	for file_path: String in FileUtils.get_all_file_at(INSTANCE_COLLECTION_PATH, "*.tres"):
		if not file_path.ends_with(".tres"):
			continue
		# No type hint: in exports the custom-class loader isn't guaranteed
		# registered by the time this scan runs, so the hint "InstanceResource"
		# trips the resource loader. Load as untyped Resource and let the
		# embedded script class be resolved at assignment.
		var loaded: Resource = ResourceLoader.load(file_path)
		if loaded == null or not (loaded is InstanceResource):
			continue
		var instance_resource: InstanceResource = loaded
		if instance_resource.load_at_startup:
			for copy: int in (instance_resource.startup_copies if instance_resource.use_3d else 1):
				charge_instance(instance_resource,copy+1 if instance_resource.use_3d else 0)
		if instance_resource.instance_name == DEFAULT_INSTANCE_NAME:
			default_instance = instance_resource
		instance_collection.set(instance_resource.instance_name, instance_resource)


func unload_unused_instances() -> void:
	print("Checking unload_unused_instances")
	for instance: ServerInstance in get_children():
		if instance.instance_resource.load_at_startup:
			continue
		if instance.connected_peers or not instance.awaiting_peers.is_empty():
			continue
		instance.instance_resource.charged_instances.erase(instance)
		instance.queue_free()


func get_instance_server_by_id(id: String) -> ServerInstance:
	# IDs name direct instance children. Never interpret client input as NodePath
	# (ancestor traversal, absolute paths, unique-name aliases or subresources).
	for child: Node in get_children():
		if child is ServerInstance and str(child.name) == id:
			return child as ServerInstance
	return null


## Look up which ServerInstance a peer is currently in. O(instances) but
## instance counts are small (a few dozen at most), so this is fine for
## staff commands.
func find_instance_for_peer(peer_id: int) -> ServerInstance:
	for res: InstanceResource in instance_collection.values():
		for inst: ServerInstance in res.charged_instances:
			if inst.connected_peers.has(peer_id):
				return inst
	return null


## Move an online player straight to the jail instance. Mirrors the warper
## handler: synchronous switch if jail is already charged, else queue until
## the instance is ready. Silently no-ops if the jail map isn't authored yet.
## Returns true if a teleport was scheduled.
func send_player_to_jail(peer_id: int) -> bool:
	var jail_res: InstanceResource = instance_collection.get(JAIL_INSTANCE_NAME, null)
	if jail_res == null:
		push_warning("send_player_to_jail: no '%s' instance in collection." % JAIL_INSTANCE_NAME)
		return false

	var current_inst: ServerInstance = find_instance_for_peer(peer_id)
	if current_inst == null:
		return false
	var player: Player = current_inst.get_player(peer_id)
	if player == null:
		return false

	# Already in jail — nothing to do.
	if current_inst.instance_resource == jail_res:
		return false

	if jail_res.charged_instances.is_empty():
		queue_charge_instance(
			jail_res,
			player_switch_instance.bind(0, player, current_inst)
		)
	else:
		player_switch_instance(jail_res.get_instance(), 0, player, current_inst)
	return true


## Teleport an online player to an absolute position, in their current instance
## or another one. Used by /goto and /summon. Returns true if scheduled.
##
## Same instance: move server-side state (so other viewers see it) AND push an
## explicit teleport to the moved client — its LocalPlayer owns its position, so
## a state delta alone won't move it (it'd overwrite next input frame).
## Cross instance: despawn here and respawn at the position over there; the fresh
## spawn places the LocalPlayer correctly with no extra push.
func teleport_peer_to(peer_id: int, dest_instance: ServerInstance, dest_position: Vector2) -> bool:
	if dest_instance == null:
		return false
	var current_inst: ServerInstance = find_instance_for_peer(peer_id)
	if current_inst == null:
		return false
	var player: Player = current_inst.get_player(peer_id)
	if player == null:
		return false

	if current_inst == dest_instance:
		player.mark_just_teleported()
		player.state_synchronizer.set_by_path(^":position", dest_position)
		world_server.data_push.rpc_id(peer_id, &"player.teleport", {"position": dest_position})
		return true

	current_inst.despawn_player(peer_id, false)
	charge_new_instance.rpc_id(peer_id, dest_instance.instance_resource.map_path, dest_instance.name)
	dest_instance.awaiting_peers[peer_id] = {"player": player, "target_position": dest_position}
	return true
