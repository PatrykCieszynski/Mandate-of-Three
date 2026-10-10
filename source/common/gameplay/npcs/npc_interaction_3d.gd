class_name NpcInteraction3D
extends Node
## Map-scoped authoritative context. Service domains call resolve_npc_service again
## at execution time; opening/selecting a service never authorizes a later spend.
signal context_changed(peer_id: int)
signal state_changed(snapshot: Dictionary)
signal operation_finished(command_id: String, result: Dictionary)
var state: Dictionary = {"active":false}
var actors: Dictionary[String, NeutralNpc3D] = {}
var contexts: Dictionary[int, NpcInteractionContext] = {}
var _world: Node3D
var _last_request: Dictionary[int, Dictionary] = {}
var _observed: Dictionary[int, Dictionary] = {}
var _published: Dictionary[int, Dictionary] = {}
var _check_elapsed: float = 0.0

func _ready() -> void:
	_world = get_parent()

func register_actor(actor: NeutralNpc3D) -> bool:
	if not NeutralNpc3D.valid_instance_id(actor.instance_id) or actors.has(actor.instance_id) or actor.get_parent() != _world or actor.definition == null or NpcDefinitions.get_definition(actor.definition.definition_id) == null or not actor.definition.validation_errors().is_empty(): return false
	actors[actor.instance_id] = actor
	actor.tree_exiting.connect(func() -> void: remove_actor(actor.instance_id))
	return true

func remove_actor(instance_id: String) -> void:
	actors.erase(instance_id)
	for peer_id: int in contexts.keys():
		if contexts[peer_id].npc_instance_id == instance_id:
			close_for_peer(peer_id)
			_publish(peer_id)

func _validate_actor(peer_id: int, instance_id: String) -> Dictionary:
	if not _world.characters.has(peer_id): return {"ok":false, "error":"unknown_player"}
	var actor: NeutralNpc3D = actors.get(instance_id)
	if not is_instance_valid(actor) or actor.get_parent() != _world: return {"ok":false, "error":"unknown_npc"}
	if not actor.interactable: return {"ok":false, "error":"not_interactable"}
	if actor.definition == null or NpcDefinitions.get_definition(actor.definition.definition_id) == null or not actor.definition.validation_errors().is_empty(): return {"ok":false, "error":"invalid_definition"}
	var body: Node3D = _world.characters[peer_id]
	if not is_instance_valid(body) or body.get_parent() != _world: return {"ok":false, "error":"wrong_world"}
	if not actor.global_position.is_finite() or not body.global_position.is_finite() or body.global_position.distance_to(actor.global_position) > actor.definition.interaction_radius: return {"ok":false, "error":"out_of_range"}
	return {"ok":true, "actor":actor}

func interact_for_peer(peer_id: int, instance_id: String) -> Dictionary:
	var result: Dictionary = _validate_actor(peer_id, instance_id)
	if not result.ok:
		close_for_peer(peer_id)
		return {"ok":false, "error":result.error}
	var actor: NeutralNpc3D = result.actor
	contexts[peer_id] = NpcInteractionContext.new(instance_id, actor.definition.definition_id)
	return {"ok":true}

func resolve_npc_service(peer_id: int, instance_id: String, service_id: StringName, expected_kind: NpcServiceDefinition.Kind) -> Dictionary:
	var context: NpcInteractionContext = contexts.get(peer_id)
	if context == null or context.npc_instance_id != instance_id: return {"ok":false, "error":"no_interaction"}
	var result: Dictionary = _validate_actor(peer_id, instance_id)
	if not result.ok: return result
	var actor: NeutralNpc3D = result.actor
	if context.npc_definition_id != actor.definition.definition_id: return {"ok":false, "error":"stale_context"}
	var service: NpcServiceDefinition = actor.definition.get_service(service_id)
	if service == null: return {"ok":false, "error":"unknown_service"}
	if service.kind != expected_kind: return {"ok":false, "error":"wrong_service_kind"}
	if not actor.service_enabled(service_id): return {"ok":false, "error":"service_disabled"}
	return {"ok":true, "service":service, "content_ref":service.content_ref}

func select_for_peer(peer_id: int, instance_id: String, service_id: StringName) -> Dictionary:
	var actor: NeutralNpc3D = actors.get(instance_id)
	var service: NpcServiceDefinition = actor.definition.get_service(service_id) if is_instance_valid(actor) and actor.definition != null else null
	if service == null: return {"ok":false, "error":"unknown_service"}
	var result: Dictionary = resolve_npc_service(peer_id, instance_id, service_id, service.kind)
	if not result.ok: return {"ok":false, "error":result.error}
	contexts[peer_id].selected_service_id = service_id
	return {"ok":true}

func clear_service_for_peer(peer_id: int) -> Dictionary:
	var context: NpcInteractionContext = contexts.get(peer_id)
	if context == null: return {"ok":false, "error":"no_interaction"}
	var valid: Dictionary = _validate_actor(peer_id, context.npc_instance_id)
	if not valid.ok: return {"ok":false, "error":valid.error}
	context.selected_service_id = &""
	return {"ok":true}

func close_for_peer(peer_id: int) -> void:
	contexts.erase(peer_id)

func remove_peer(peer_id: int) -> void:
	close_for_peer(peer_id)
	_last_request.erase(peer_id)
	_observed.erase(peer_id)
	_published.erase(peer_id)

func snapshot_for_peer(peer_id: int) -> Dictionary:
	var context: NpcInteractionContext = contexts.get(peer_id)
	if context == null: return {"active":false}
	var result: Dictionary = _validate_actor(peer_id, context.npc_instance_id)
	if not result.ok or context.npc_definition_id != result.actor.definition.definition_id:
		close_for_peer(peer_id)
		return {"active":false}
	var actor: NeutralNpc3D = result.actor
	var services: Array[Dictionary] = []
	for service: NpcServiceDefinition in actor.definition.ordered_services():
		services.append({"id":str(service.service_id), "kind":int(service.kind), "label":service.label, "iconId":str(service.icon_id), "enabled":actor.service_enabled(service.service_id)})
	if context.selected_service_id != &"" and (actor.definition.get_service(context.selected_service_id) == null or not actor.service_enabled(context.selected_service_id)): context.selected_service_id = &""
	return {"active":true, "npcInstanceId":context.npc_instance_id, "npcDefinitionId":str(context.npc_definition_id), "name":actor.definition.display_name, "services":services, "selectedServiceId":str(context.selected_service_id)}

@rpc("any_peer", "call_remote", "reliable", 1)
func request_interaction(action: String, instance_id: String, service_id: String, command_id: String) -> void:
	if not GameMode.is_world_server() or command_id.length() > 80 or instance_id.length() > 80 or service_id.length() > 64: return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if not _world.characters.has(peer_id): return
	var result: Dictionary
	var now: int = Time.get_ticks_msec()
	var action_times: Dictionary = _last_request.get(peer_id, {})
	if action in ["interact", "select"] and now - action_times.get(action, -1000) < 100:
		result = {"ok":false, "error":"too_fast"}
	else:
		if action in ["interact", "select"]:
			action_times[action] = now
			_last_request[peer_id] = action_times
		match action:
			"interact": result = interact_for_peer(peer_id, instance_id)
			"select": result = select_for_peer(peer_id, instance_id, StringName(service_id))
			"clear_service": result = clear_service_for_peer(peer_id)
			"close":
				close_for_peer(peer_id)
				result = {"ok":true}
			_: result = {"ok":false, "error":"invalid_action"}
	_publish(peer_id)
	if command_id != "": receive_operation.rpc_id(peer_id, command_id, result)

func _publish(peer_id: int) -> void:
	var snapshot: Dictionary = snapshot_for_peer(peer_id)
	# Local change notifications are independent of network availability/delivery.
	if _observed.get(peer_id, {"active":false}) != snapshot:
		_observed[peer_id] = snapshot.duplicate(true)
		context_changed.emit(peer_id)
	if GameMode.is_world_server() and _world.characters.has(peer_id) and multiplayer.has_multiplayer_peer():
		if _published.get(peer_id, {}) != snapshot:
			_published[peer_id] = snapshot.duplicate(true)
			receive_interaction.rpc_id(peer_id, snapshot)

@rpc("authority", "call_remote", "reliable", 1)
func receive_interaction(snapshot: Dictionary) -> void:
	if GameMode.is_world_server(): return
	state = snapshot.duplicate(true)
	state_changed.emit(state)

@rpc("authority", "call_remote", "reliable", 1)
func receive_operation(command_id: String, result: Dictionary) -> void:
	if not GameMode.is_world_server(): operation_finished.emit(command_id, result)

func _physics_process(delta: float) -> void:
	if not GameMode.is_world_server(): return
	_check_elapsed += delta
	if _check_elapsed < 0.25: return
	_check_elapsed = 0.0
	for peer_id: int in contexts.keys():
		_publish(peer_id)

func _exit_tree() -> void:
	contexts.clear()
	actors.clear()
	_last_request.clear()
	_observed.clear()
	_published.clear()
