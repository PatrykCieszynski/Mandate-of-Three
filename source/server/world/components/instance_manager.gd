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
const CHANNEL_CHOICE_TIMEOUT_MS: int = 30000

var loading_instances: Dictionary[String, ServerInstance]
@export var realm_id: StringName = &"local"
@export var host_id: StringName = &"local-world"
@export_range(1, 64) var max_host_instances: int = 8
var provision_budget := preload("res://source/server/world/components/instance_provision_budget.gd").new()
const MapIdentity = preload("res://source/common/gameplay/maps/instance/map_instance_identity.gd")
var instance_collection: Dictionary[String, InstanceResource]
var default_instance: InstanceResource
## Bounded by current sessions; expiry cannot be renewed before transport teardown.
var _rejected_entries: Dictionary[int, PlayerResource] = {}
var _last_legacy_unload_ms: int = 0
var _channel_choices: Dictionary[int, Dictionary] = {}
var _channel_request_ids: Dictionary[int, int] = {}
var transfers := preload("res://source/server/world/components/local_channel_transfer.gd").new(self)

@export var world_server: WorldServer


func _physics_process(_delta: float) -> void:
	if world_server == null:
		return
	transfers.tick()
	provision_budget.record(
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Time.get_ticks_msec()
	)


func start_instance_manager() -> void:
	ServerInstance.world_server = world_server
	
	setup_global_commands_and_roles()

	set_instance_collection.call_deferred()
	world_server.multiplayer_api.peer_connected.connect(_on_peer_connected)
	world_server.multiplayer_api.peer_disconnected.connect(_release_pending_peer)

	# Expiry is checked at join too; this sweep reclaims clients that never join.
	var timer: Timer = Timer.new()
	timer.wait_time = 1.0

	timer.autostart = true
	timer.timeout.connect(maintain_instances)
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
	var session: PlayerResource = world_server.connected_players.get(peer_id)
	if not _is_current_session(peer_id, session) or find_instance_for_peer(peer_id) != null:
		return
	for instance: ServerInstance in _all_instances():
		if instance.awaiting_peers.has(peer_id):
			if not has_valid_entry(instance, peer_id, session):
				_reject_initial_entry(peer_id, session, "entry_expired")
			return # Trusted routing may already have assigned a private run.
	if _channel_choices.get(peer_id, {}).get("session") != session:
		_channel_choices[peer_id] = {"session": session, "expires_at_ms": Time.get_ticks_msec() + CHANNEL_CHOICE_TIMEOUT_MS}
		_channel_request_ids.erase(peer_id)
	receive_channels.rpc_id(peer_id, 0, public_channels(peer_id))


func public_channels(peer_id: int) -> Dictionary:
	if not _is_current_session(peer_id, world_server.connected_players.get(peer_id)):
		return {"ok": false, "error": "session"}
	var resource := default_instance
	var joined := find_instance_for_peer(peer_id)
	if joined!=null: resource=joined.instance_resource
	if resource == null:
		return {"ok": false, "error": "map_unavailable"}
	var channels: Array = []
	for instance: ServerInstance in _instances_for(resource):
		if instance.access_policy != ServerInstance.AccessPolicy.PUBLIC:
			continue
		if instance.get_parent() != self and loading_instances.get(str(instance.name)) != instance:
			continue
		var state := "available" if instance.is_node_ready() else "loading"
		if instance.admission_state != ServerInstance.AdmissionState.ACCEPTING:
			state = "draining"
		elif instance.population() >= resource.max_players:
			state = "full"
		channels.append({"channel_id": int(instance.identity.channel_id), "state": state,
			"population": instance.population(), "capacity": resource.max_players})
	return {"ok": true, "map_id": str(resource.resolved_map_id()), "channels": channels}


func _admit_channel_request(peer_id: int, request_id: int) -> bool:
	if not _is_current_session(peer_id, world_server.connected_players.get(peer_id)):
		return false
	if request_id <= _channel_request_ids.get(peer_id, 0) or request_id > 2147483647:
		return false
	_channel_request_ids[peer_id] = request_id # Deduplicate before rate-limit responses.
	return true


@rpc("any_peer", "call_remote", "reliable", 0)
func request_channels(request_id: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not _admit_channel_request(peer_id, request_id): return
	if not RateLimiter.check(peer_id, &"instance.channels", 8, 1000):
		receive_channels.rpc_id(peer_id, request_id, {"ok": false, "error": "rate_limited"})
		return
	receive_channels.rpc_id(peer_id, request_id, public_channels(peer_id))


func choose_initial_channel(peer_id: int, channel_id: int) -> Dictionary:
	var session: PlayerResource = world_server.connected_players.get(peer_id)
	if not _is_current_session(peer_id, session): return {"ok": false, "error": "session"}
	if find_instance_for_peer(peer_id) != null: return {"ok": false, "error": "already_joined"}
	if default_instance == null: return {"ok": false, "error": "map_unavailable"}
	if channel_id < 0: return {"ok": false, "error": "channel_unavailable"}
	for pending: ServerInstance in _all_instances():
		if pending.awaiting_peers.has(peer_id):
			if pending.awaiting_peers[peer_id].get("initial_channel", -1) != channel_id:
				return {"ok": false, "error": "already_selected"}
			if not has_valid_entry(pending, peer_id, session): return {"ok": false, "error": "entry_expired"}
			return {"ok": true, "instance": pending, "duplicate": true}
	var choice: Dictionary = _channel_choices.get(peer_id, {})
	if choice.get("session") != session or int(choice.get("expires_at_ms", 0)) <= Time.get_ticks_msec():
		return {"ok": false, "error": "choice_expired"}
	var target: ServerInstance
	if channel_id > 0:
		for instance: ServerInstance in _instances_for(default_instance):
			if instance.get_parent() != self and loading_instances.get(str(instance.name)) != instance:
				continue
			if instance.access_policy == ServerInstance.AccessPolicy.PUBLIC and int(instance.identity.channel_id) == channel_id:
				target = instance
				break
		if target == null or not target.accepts_reservation(): return {"ok": false, "error": "channel_unavailable"}
	var result := reserve_entry(peer_id, default_instance, target)
	if result.ok:
		result.instance.awaiting_peers[peer_id]["initial_channel"] = channel_id
		_channel_choices.erase(peer_id)
	return result


@rpc("any_peer", "call_remote", "reliable", 0)
func request_initial_channel(request_id: int, channel_id: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not _admit_channel_request(peer_id, request_id): return
	if not RateLimiter.check(peer_id, &"instance.channels", 8, 1000):
		receive_channel_selection.rpc_id(peer_id, request_id, {"ok": false, "error": "rate_limited"})
		return
	var result := choose_initial_channel(peer_id, channel_id)
	# Never serialize server objects or the private pending/session record.
	receive_channel_selection.rpc_id(peer_id, request_id, {"ok": result.ok, "error": result.get("error", "")})
	if result.ok:
		if result.get("duplicate", false):
			if result.instance.is_node_ready(): _publish_entry(peer_id, world_server.connected_players[peer_id], result.instance)
		else:
			_start_entry_publication(peer_id, result.instance)
	elif result.get("error") == "choice_expired" or (channel_id == 0 and result.get("error") == "map_unavailable"):
		_reject_initial_entry(peer_id, world_server.connected_players.get(peer_id), result.error)


@rpc("authority", "call_remote", "reliable", 0)
func receive_channels(_request_id: int, _result: Dictionary) -> void: pass


@rpc("authority", "call_remote", "reliable", 0)
func receive_channel_selection(_request_id: int, _result: Dictionary) -> void: pass


@rpc("any_peer", "call_remote", "reliable", 0)
func request_transfer(request_id: int, action: String, channel: int, attempt: int, epoch: int) -> void:
	var peer := multiplayer.get_remote_sender_id()
	if not _admit_channel_request(peer,request_id): return
	if not RateLimiter.check(peer,&"instance.channels",8,1000):
		receive_transfer.rpc_id(peer,request_id,{"ok":false,"error":"rate_limited","transfer":transfers.snapshot(peer)})
		return
	var result: Dictionary
	match action:
		"start": result=transfers.start(peer,channel)
		"cancel": result=transfers.cancel(peer,attempt,epoch)
		"status": result={"ok":true}
		_: result={"ok":false,"error":"request"}
	result["transfer"]=transfers.snapshot(peer)
	receive_transfer.rpc_id(peer,request_id,result)


@rpc("authority", "call_remote", "reliable", 0)
func receive_transfer(_request_id: int, _result: Dictionary) -> void: pass


## Called by trusted initial-entry routing only, never directly by an RPC.
func admit_peer(peer_id: int, resource: InstanceResource, target: ServerInstance = null) -> Dictionary:
	var result := reserve_entry(peer_id, resource, target)
	if not result.ok:
		return result
	if result.get("duplicate", false):
		return result
	_start_entry_publication(peer_id, result.instance)
	return result


func _start_entry_publication(peer_id: int, instance: ServerInstance) -> void:
	var admitted: PlayerResource = world_server.connected_players.get(peer_id)
	if instance.is_node_ready():
		_publish_entry(peer_id, admitted, instance)
	else:
		instance.ready.connect(_publish_entry.bind(peer_id, admitted, instance), CONNECT_ONE_SHOT)


## One synchronous admission boundary: validate, select, then reserve before yield.
func reserve_entry(peer_id: int, resource: InstanceResource, target: ServerInstance = null) -> Dictionary:
	var admitted: PlayerResource = world_server.connected_players.get(peer_id)
	if not _is_current_session(peer_id, admitted):
		return {"ok": false, "error": "session"}
	if _rejected_entries.get(peer_id) == admitted:
		return {"ok": false, "error": "entry_expired"}
	var joined := find_instance_for_peer(peer_id)
	if joined != null:
		if target != null and target != joined:
			return {"ok": false, "error": "already_joined"}
		return {"ok": true, "instance": joined, "duplicate": true}
	if resource == null:
		return {"ok": false, "error": "map_unavailable"}
	for existing: ServerInstance in _all_instances():
		if existing.awaiting_peers.has(peer_id):
			if has_valid_entry(existing, peer_id, admitted):
				if target != null and target != existing:
					return {"ok": false, "error": "entry_pending"}
				return {"ok": true, "instance": existing, "duplicate": true}
			# A duplicate at the deadline must fail, never renew its lease.
			if existing.awaiting_peers[peer_id].get("session") == admitted:
				return {"ok": false, "error": "entry_expired"}
			existing.awaiting_peers.erase(peer_id)
	var instance := target
	if target != null:
		if not _instances_for(resource).has(target) or not target.instance_resource.use_3d:
			return {"ok": false, "error": "map_unavailable"}
		if target.get_parent() != self and loading_instances.get(str(target.name)) != target:
			return {"ok": false, "error": "map_unavailable"}
		if not target.allows_character(admitted.player_id):
			return {"ok": false, "error": "access_denied"}
		if not target.accepts_reservation():
			return {"ok": false, "error": "map_unavailable"}
	else:
		instance = select_entry_instance(resource)
	if instance == null:
		return {"ok": false, "error": "map_unavailable"}
	instance.awaiting_peers[peer_id] = {
		"session": admitted,
		"expires_at_ms": Time.get_ticks_msec() + int(resource.entry_timeout_seconds * 1000.0),
	}
	instance.idle_since_ms = -1
	_channel_choices.erase(peer_id) # Any accepted server assignment ends initial choice.
	return {"ok": true, "instance": instance}


func _is_current_session(peer_id: int, session: PlayerResource) -> bool:
	return (
		peer_id > 1 and session != null and session.player_id > 0
		and world_server.connected_players.get(peer_id) == session
		and session.current_peer_id == peer_id
		and world_server.player_id_to_peer_id.get(session.player_id, 0) == peer_id
	)


func has_valid_entry(instance: ServerInstance, peer_id: int, session: PlayerResource) -> bool:
	var pending: Dictionary = instance.awaiting_peers.get(peer_id, {})
	return (
		not instance.is_queued_for_deletion() and _is_current_session(peer_id, session)
		and pending.get("session") == session
		and instance.allows_character(session.player_id)
		and (not instance.instance_resource.use_3d
			or int(pending.get("expires_at_ms", 0)) > Time.get_ticks_msec())
	)


func _reject_initial_entry(peer_id: int, session: PlayerResource, reason: String) -> void:
	if not _is_current_session(peer_id, session):
		return
	_rejected_entries[peer_id] = session
	print("MAP_ENTRY_REJECTED: ", peer_id, " ", reason)
	# Disconnect uses the normal session/checkpoint cleanup, not a partial logout.
	if world_server.multiplayer_api.get_peers().has(peer_id):
		world_server.multiplayer_api.multiplayer_peer.disconnect_peer(peer_id)


func _all_instances() -> Array[ServerInstance]:
	var result: Array[ServerInstance] = []
	for instance: ServerInstance in loading_instances.values():
		if is_instance_valid(instance) and not result.has(instance):
			result.append(instance)
	for child: Node in get_children():
		if child is ServerInstance and not result.has(child):
			result.append(child)
	return result


func _release_pending_peer(peer_id: int) -> void:
	transfers.release_peer(peer_id)
	_channel_choices.erase(peer_id)
	_channel_request_ids.erase(peer_id)
	_rejected_entries.erase(peer_id)
	for instance: ServerInstance in _all_instances():
		instance.awaiting_peers.erase(peer_id)


func begin_draining(instance: ServerInstance) -> bool:
	if not is_instance_valid(instance) or instance.get_parent() != self:
		return false
	if not instance.instance_resource.use_3d or instance.is_queued_for_deletion():
		return false
	instance.admission_state = ServerInstance.AdmissionState.DRAINING
	return true


func maintain_instances() -> void:
	var now := Time.get_ticks_msec()
	for peer_id: int in _channel_choices.keys():
		var choice: Dictionary = _channel_choices[peer_id]
		if int(choice.expires_at_ms) <= now or not _is_current_session(peer_id, choice.session):
			_channel_choices.erase(peer_id)
			_reject_initial_entry(peer_id, choice.session, "choice_expired")
	for instance: ServerInstance in _all_instances():
		if instance.is_queued_for_deletion() or not instance.instance_resource.use_3d:
			continue
		for peer_id: int in instance.awaiting_peers.keys():
			var session: PlayerResource = instance.awaiting_peers[peer_id].get("session")
			if has_valid_entry(instance, peer_id, session):
				continue
			instance.awaiting_peers.erase(peer_id)
			_reject_initial_entry(peer_id, session, "entry_expired")
		if instance.population() > 0:
			instance.idle_since_ms = -1
			continue
		if instance.idle_since_ms < 0:
			instance.idle_since_ms = now
		var resource := instance.instance_resource
		var draining := instance.admission_state == ServerInstance.AdmissionState.DRAINING
		if not draining:
			if resource.load_at_startup and instance.access_policy == ServerInstance.AccessPolicy.PUBLIC and not instance.is_overflow_copy:
				continue
			if now - instance.opened_at_ms < int(resource.minimum_lifetime_seconds * 1000.0):
				continue
			if now - instance.idle_since_ms < int(resource.idle_timeout_seconds * 1000.0):
				continue
		# No admission can race this retirement on the main thread.
		instance.admission_state = ServerInstance.AdmissionState.DRAINING
		instance.queue_free()
	# Preserve the old 20-second cleanup cadence for unrelated legacy 2D maps.
	if now - _last_legacy_unload_ms >= 20000:
		_last_legacy_unload_ms = now
		unload_unused_instances()

func _publish_entry(peer_id: int, admitted: PlayerResource, instance: ServerInstance) -> void:
	if not is_instance_valid(instance):
		return
	if not has_valid_entry(instance, peer_id, admitted):
		if instance.awaiting_peers.get(peer_id, {}).get("session") == admitted:
			instance.awaiting_peers.erase(peer_id)
		_reject_initial_entry(peer_id, admitted, "entry_expired")
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
	var instances: Array[ServerInstance] = []
	for candidate: ServerInstance in _instances_for(resource):
		if candidate.access_policy == ServerInstance.AccessPolicy.PUBLIC:
			instances.append(candidate)
	for instance: ServerInstance in instances:
		if resource.use_3d and not instance.accepts_reservation():
			continue
		var count := instance.population()
		if count<population:
			selected=instance
			population=count
	if selected != null:
		return selected
	if instances.is_empty():
		# An empty host can bootstrap; a busy host must not bypass the CPU guard
		# by asking for a map that currently has only private/no public copies.
		if resource.use_3d and not _all_instances().is_empty() and not provision_budget.has_headroom(Time.get_ticks_msec()):
			return null
		return charge_instance(resource)
	# Grow only a full accepting set. Draining is an explicit retirement decision.
	if not resource.use_3d or instances.size() >= resource.max_public_copies:
		return null
	for instance: ServerInstance in instances:
		if instance.admission_state != ServerInstance.AdmissionState.ACCEPTING:
			return null
	if not provision_budget.has_headroom(Time.get_ticks_msec()):
		return null
	var overflow := charge_instance(resource)
	if overflow != null:
		overflow.is_overflow_copy = true
	return overflow


## Loaded public routing only. Never use InstanceResource array order as access.
func find_public_instance(resource: InstanceResource) -> ServerInstance:
	if resource == null:
		return null
	for instance: ServerInstance in _instances_for(resource):
		if instance.get_parent() != self or not instance.is_node_ready():
			continue
		if instance.access_policy != ServerInstance.AccessPolicy.PUBLIC:
			continue
		if instance.admission_state != ServerInstance.AdmissionState.ACCEPTING:
			continue
		if resource.use_3d and not instance.accepts_reservation():
			continue
		return instance
	return null


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
		target_instance = find_public_instance(instance_resource)
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
	var target := find_public_instance(res)
	if target == null:
		queue_charge_instance(res, player_switch_instance.bind(0, player, current_inst))
	else:
		player_switch_instance(target, 0, player, current_inst)


func queue_charge_instance(instance_resource: InstanceResource, callback: Callable) -> void:
	for pending: ServerInstance in loading_instances.values():
		if pending.instance_resource==instance_resource and pending.access_policy == ServerInstance.AccessPolicy.PUBLIC and pending.admission_state == ServerInstance.AdmissionState.ACCEPTING and not pending.is_queued_for_deletion():
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
) -> bool:
	if not _can_legacy_transfer(target_instance, player, current_instance):
		return false
	var peer_id: int = player.name.to_int()
	if not world_server.database.flush_character(player.player_resource.player_id):
		push_error("Instance transfer cancelled: character checkpoints could not be saved.")
		return false
	if current_instance.connected_peers.has(peer_id):
		current_instance.despawn_player(peer_id, false)
	else:
		return false
	# Leaving a dungeon run drops this peer from its group.
	DungeonService.on_player_left(peer_id, current_instance)
	charge_new_instance.rpc_id(
		peer_id,
		target_instance.instance_resource.map_path,
		target_instance.name
	)
	target_instance.awaiting_peers[peer_id] = {
		"player": player,
		"session": player.player_resource,
		"target_id": warper_target_id
	}
	return true


## Legacy Player/Map handoff is not the future 3D transfer state machine.
## Reject unsupported or inaccessible targets before checkpoint or despawn.
func _can_legacy_transfer(target: ServerInstance, player: Player, source: ServerInstance) -> bool:
	if not is_instance_valid(target) or not is_instance_valid(source) or not is_instance_valid(player):
		return false
	if target.get_parent() != self or source.get_parent() != self or not target.is_node_ready():
		return false
	if target.is_queued_for_deletion() or source.is_queued_for_deletion():
		return false
	if target.instance_resource == null or source.instance_resource == null:
		return false
	if target.instance_resource.use_3d or source.instance_resource.use_3d:
		return false
	if target.access_policy != ServerInstance.AccessPolicy.PUBLIC or target.admission_state != ServerInstance.AdmissionState.ACCEPTING:
		return false
	var peer_id := str(player.name).to_int()
	if not _is_current_session(peer_id, player.player_resource) or source.get_player(peer_id) != player or not source.connected_peers.has(peer_id):
		return false
	if target != source and (target.connected_peers.has(peer_id) or target.awaiting_peers.has(peer_id)):
		return false
	return target.instance_resource.can_join_instance(player)


func charge_instance(instance_resource: InstanceResource, channel_id: int = 0) -> ServerInstance:
	if channel_id>0:
		for existing: ServerInstance in _instances_for(instance_resource):
			if int(existing.identity.get("channel_id",0))==channel_id: return existing
	var new_instance: ServerInstance = prepare_instance(instance_resource,channel_id)
	if new_instance==null: return null
	add_child.call_deferred(new_instance, true)
	return new_instance


## A private run uses the same map runtime, never a public channel slot.
func charge_reserved_instance(instance_resource: InstanceResource, character_ids: PackedInt64Array) -> ServerInstance:
	var instance := prepare_instance(instance_resource, 0, ServerInstance.AccessPolicy.RESERVED, character_ids)
	if instance != null:
		add_child.call_deferred(instance, true)
	return instance


func prepare_instance(instance_resource: InstanceResource, channel_id: int = 0,
	access_policy: ServerInstance.AccessPolicy = ServerInstance.AccessPolicy.PUBLIC,
	character_ids: PackedInt64Array = PackedInt64Array()) -> ServerInstance:
	if access_policy not in [ServerInstance.AccessPolicy.PUBLIC, ServerInstance.AccessPolicy.RESERVED]:
		return null
	if access_policy == ServerInstance.AccessPolicy.RESERVED:
		if instance_resource == null or not instance_resource.use_3d or channel_id != 0 or character_ids.is_empty():
			return null
		for character_id: int in character_ids:
			if character_id <= 0:
				return null
	elif not character_ids.is_empty():
		return null
	if instance_resource==null or not ResourceLoader.exists(instance_resource.map_path):
		push_error("Cannot load map instance: missing map resource")
		return null
	if _all_instances().size() >= max_host_instances:
		return null
	if instance_resource.use_3d and access_policy == ServerInstance.AccessPolicy.PUBLIC:
		var copies := 0
		for existing: ServerInstance in _all_instances():
			if existing.instance_resource == instance_resource and existing.access_policy == ServerInstance.AccessPolicy.PUBLIC:
				copies += 1
		if copies >= instance_resource.max_public_copies:
			return null
	var instance: ServerInstance = ServerInstance.new()
	if instance_resource.use_3d:
		instance.free()
		instance = preload("res://source/server/world/components/world_instance_3d.gd").new()
	instance.access_policy = access_policy
	instance.allowed_character_ids = character_ids.duplicate()
	if instance_resource.use_3d and channel_id==0 and access_policy == ServerInstance.AccessPolicy.PUBLIC:
		channel_id=1
		for existing: ServerInstance in _instances_for(instance_resource): channel_id=maxi(channel_id,int(existing.identity.get("channel_id",0))+1)
	instance.identity=MapIdentity.create(realm_id,instance_resource.resolved_map_id(),host_id,channel_id)
	if not MapIdentity.valid(instance.identity):
		instance.free()
		push_error("Invalid map instance identity configuration")
		return null
	instance.name = instance.identity.instance_id
	instance.opened_at_ms=Time.get_ticks_msec()
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
	provision_budget.reset(Time.get_ticks_msec())
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
		if instance_resource.use_3d and instance_resource.load_at_startup and instance_resource.startup_copies > instance_resource.max_public_copies:
			push_error("Map startup copies exceed its public instance limit: " + str(instance_resource.instance_name))
			continue
		if instance_resource.load_at_startup:
			for copy: int in (instance_resource.startup_copies if instance_resource.use_3d else 1):
				charge_instance(instance_resource,copy+1 if instance_resource.use_3d else 0)
		if instance_resource.instance_name == DEFAULT_INSTANCE_NAME:
			default_instance = instance_resource
		instance_collection.set(instance_resource.instance_name, instance_resource)


func unload_unused_instances() -> void:
	for child: Node in get_children():
		if not child is ServerInstance: continue
		var instance := child as ServerInstance
		if instance.instance_resource.use_3d: continue # Managed by the bounded lifecycle above.
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

	var target := find_public_instance(jail_res)
	if target == null:
		queue_charge_instance(
			jail_res,
			player_switch_instance.bind(0, player, current_inst)
		)
	else:
		return player_switch_instance(target, 0, player, current_inst)
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

	if not _can_legacy_transfer(dest_instance, player, current_inst):
		return false
	if not world_server.database.flush_character(player.player_resource.player_id):
		return false
	current_inst.despawn_player(peer_id, false)
	charge_new_instance.rpc_id(peer_id, dest_instance.instance_resource.map_path, dest_instance.name)
	dest_instance.awaiting_peers[peer_id] = {"player": player, "session": player.player_resource, "target_position": dest_position}
	return true
