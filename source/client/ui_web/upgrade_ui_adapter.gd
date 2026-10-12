class_name UpgradeUiAdapter
extends RefCounted
## Upgrade commands and snapshot; NPC workflow is coordinated by composition.
var _endpoint: Upgrade3D
var _dispatcher: UiCommandDispatcher
var _session: UiCommandSession
var _tree: SceneTree

func attach(endpoint: Upgrade3D, dispatcher: UiCommandDispatcher, session: UiCommandSession, tree: SceneTree) -> void:
	_endpoint = endpoint
	_dispatcher = dispatcher
	_session = session
	_tree = tree
	dispatcher.register_command("upgrade.select", valid_item, select_item)
	dispatcher.register_command("upgrade.execute", valid_item, func(p: Dictionary) -> Dictionary: return await _submit("upgrade", p))
	endpoint.state_changed.connect(publish)
	endpoint.operation_finished.connect(session.finish)
	publish(endpoint.state)

func dispose() -> void:
	if is_instance_valid(_endpoint):
		if _endpoint.state_changed.is_connected(publish): _endpoint.state_changed.disconnect(publish)
		if _endpoint.operation_finished.is_connected(_session.finish): _endpoint.operation_finished.disconnect(_session.finish)

func publish(snapshot: Dictionary) -> void:
	_dispatcher.set_domain("upgrade", snapshot)

func select_item(payload: Dictionary) -> Dictionary:
	return await _submit("select", payload)

static func valid_item(p: Dictionary) -> bool:
	return p.size() == 4 and ItemUiAdapter.valid_item_identity(p) and NpcUiAdapter.valid_service({"npc_instance_id":p.get("npc_instance_id"),"service_id":p.get("service_id")})

func _submit(action: String, p: Dictionary) -> Dictionary:
	var id: String = _session.begin()
	if id.is_empty(): return _session.closed_result()
	_endpoint.request_upgrade.rpc_id(1,action,p.npc_instance_id,p.service_id,p.id,int(p.revision),id)
	return await _session.wait(id, _tree)
