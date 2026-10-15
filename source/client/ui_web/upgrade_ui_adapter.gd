class_name UpgradeUiAdapter
extends RefCounted
## Upgrade commands and snapshot; NPC workflow is coordinated by composition.
var _endpoint: Upgrade3D
var _dispatcher: UiCommandDispatcher
var _session: UiCommandSession
var _tree: SceneTree
var _upgrade: Dictionary = {}
var _in_flight := false
var _disposed := false

func attach(endpoint: Upgrade3D, dispatcher: UiCommandDispatcher, session: UiCommandSession, tree: SceneTree) -> void:
	_endpoint = endpoint
	_dispatcher = dispatcher
	_session = session
	_tree = tree
	dispatcher.register_command("upgrade.select", valid_item, select_item)
	dispatcher.register_command("upgrade.execute", valid_item, func(p: Dictionary) -> Dictionary: return await _submit("upgrade", p))
	dispatcher.register_command("upgrade.retry", func(p: Dictionary) -> bool: return p.is_empty(), retry_upgrade)
	endpoint.state_changed.connect(publish)
	endpoint.operation_finished.connect(session.finish)
	publish(endpoint.state)

func dispose() -> void:
	_disposed = true
	if is_instance_valid(_endpoint):
		if _endpoint.state_changed.is_connected(publish): _endpoint.state_changed.disconnect(publish)
		if _endpoint.operation_finished.is_connected(_session.finish): _endpoint.operation_finished.disconnect(_session.finish)

func publish(snapshot: Dictionary) -> void:
	if _disposed: return
	var view := snapshot.duplicate(true)
	if view.get("active", false): view["upgradePending"] = not _upgrade.is_empty() and bool(_upgrade.uncertain)
	_dispatcher.set_domain("upgrade", view)

func select_item(payload: Dictionary) -> Dictionary:
	return await _submit("select", payload)

static func valid_item(p: Dictionary) -> bool:
	return p.size() == 4 and ItemUiAdapter.valid_item_identity(p) and NpcUiAdapter.valid_service({"npc_instance_id":p.get("npc_instance_id"),"service_id":p.get("service_id")})

func retry_upgrade(_payload: Dictionary = {}) -> Dictionary:
	if _upgrade.is_empty(): return {"ok":false,"error":"no_pending_upgrade"}
	return await _submit("upgrade", _upgrade.payload.duplicate(true))

func _submit(action: String, p: Dictionary) -> Dictionary:
	if _disposed: return _session.closed_result()
	if action == "upgrade":
		if _in_flight: return {"ok":false,"error":"too_fast"}
		if not _upgrade.is_empty() and _upgrade.payload != p: return {"ok":false,"error":"upgrade_pending"}
	var id: String = _session.begin()
	if id.is_empty(): return _session.closed_result()
	var operation_id := ""
	if action == "upgrade":
		if _upgrade.is_empty():
			_upgrade = {"id":"upgrade-" + Crypto.new().generate_random_bytes(16).hex_encode(),"payload":p.duplicate(true),"uncertain":false}
		operation_id = _upgrade.id
		_in_flight = true
	_endpoint.request_upgrade.rpc_id(1,action,p.npc_instance_id,p.service_id,p.id,int(p.revision),id,operation_id)
	var result := await _session.wait(id, _tree)
	if _disposed: return result
	if action == "upgrade":
		_in_flight = false
		if result.ok or result.get("error", "") in ["funds","material","stale","owner","placement","unsupported_item","upgrade_level","request"]:
			# Store rejection follows receipt lookup; a committed intent would replay success.
			_upgrade.clear()
		elif bool(_upgrade.uncertain) or result.get("error", "") in ["timeout","ui_reload","disconnected","storage"]:
			_upgrade.uncertain = true
			publish(_endpoint.state)
			return {"ok":false,"error":"upgrade_pending"}
		else:
			_upgrade.clear()
		publish(_endpoint.state)
	return result
