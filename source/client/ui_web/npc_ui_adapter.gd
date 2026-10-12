class_name NpcUiAdapter
extends RefCounted
## NPC context/commands only. Cross-domain interaction belongs to composition.
signal context_updated(snapshot: Dictionary)
var _endpoint: NpcInteraction3D
var _dispatcher: UiCommandDispatcher
var _session: UiCommandSession
var _tree: SceneTree

func attach(endpoint: NpcInteraction3D, dispatcher: UiCommandDispatcher, session: UiCommandSession, tree: SceneTree) -> void:
	_endpoint = endpoint
	_dispatcher = dispatcher
	_session = session
	_tree = tree
	dispatcher.register_command("npc.interact", valid_npc, func(p: Dictionary) -> Dictionary: return await interact(p.npc_instance_id))
	dispatcher.register_command("npc.select_service", valid_service, func(p: Dictionary) -> Dictionary: return await select_service(p.npc_instance_id, p.service_id))
	dispatcher.register_command("npc.close", func(p: Dictionary) -> bool: return p.is_empty(), func(_p: Dictionary) -> Dictionary: return await _submit("close"))
	dispatcher.register_command("npc.clear_service", func(p: Dictionary) -> bool: return p.is_empty(), func(_p: Dictionary) -> Dictionary: return await _submit("clear_service"))
	endpoint.state_changed.connect(publish)
	endpoint.operation_finished.connect(session.finish)
	publish(endpoint.state)

func dispose() -> void:
	if is_instance_valid(_endpoint):
		if _endpoint.state_changed.is_connected(publish): _endpoint.state_changed.disconnect(publish)
		if _endpoint.operation_finished.is_connected(_session.finish): _endpoint.operation_finished.disconnect(_session.finish)

func state() -> Dictionary:
	return _endpoint.state

func publish(snapshot: Dictionary) -> void:
	_dispatcher.set_domain("npc", snapshot)
	context_updated.emit(snapshot)

func interact(instance_id: String) -> Dictionary:
	return await _submit("interact", instance_id)

func select_service(instance_id: String, service_id: String) -> Dictionary:
	return await _submit("select", instance_id, service_id)

static func valid_npc(p: Dictionary) -> bool:
	return p.size() == 1 and p.get("npc_instance_id") is String and NeutralNpc3D.valid_instance_id(p.npc_instance_id)

static func valid_service(p: Dictionary) -> bool:
	return p.size() == 2 and p.get("npc_instance_id") is String and NeutralNpc3D.valid_instance_id(p.npc_instance_id) and p.get("service_id") is String and GameplayContentId.valid(StringName(p.service_id))

func _submit(action: String, instance_id: String = "", service_id: String = "") -> Dictionary:
	var id: String = _session.begin()
	if id.is_empty(): return _session.closed_result()
	_endpoint.request_interaction.rpc_id(1, action, instance_id, service_id, id)
	return await _session.wait(id, _tree)



