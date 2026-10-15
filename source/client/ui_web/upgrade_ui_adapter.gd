class_name UpgradeUiAdapter
extends RefCounted
## Upgrade commands and snapshot; NPC workflow is coordinated by composition.
var _endpoint: Upgrade3D
var _dispatcher: UiCommandDispatcher
var _session: UiCommandSession
var _tree: SceneTree
const LocalJournal = preload("res://source/client/ui_web/local_economy_journal.gd")
var journal = LocalJournal.new("upgrade-","user://pending_upgrades")
var _context: Dictionary = {}
var _journal_ready := false
var _recovery_hidden := false
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
	dispatcher.register_command("upgrade.dismiss_recovery", func(p: Dictionary) -> bool: return p.is_empty(), func(_p: Dictionary) -> Dictionary:
		_recovery_hidden = true
		publish(_endpoint.state)
		return {"ok":true})
	endpoint.state_changed.connect(publish)
	endpoint.operation_finished.connect(session.finish)
	publish(endpoint.state)

func accept_context(snapshot: Dictionary) -> void:
	if _disposed or not snapshot.get("ok",false): return
	var context: Dictionary = snapshot.get("economic_context",{})
	if context.is_empty() or context == _context: return
	if not _context.is_empty():
		_journal_ready = false
		return
	_context = context.duplicate(true)
	var restored: Dictionary = journal.configure(context)
	if not restored.ok: return
	if not restored.entry.is_empty() and not valid_item(restored.entry.payload): return
	_journal_ready = true
	if restored.entry.is_empty(): return
	_upgrade = restored.entry.duplicate(true)
	_upgrade.uncertain = true
	publish(_endpoint.state)
	_retry.call_deferred(false) # Restart discovery never executes a mutation.

func _release_upgrade() -> bool:
	if not journal.clear_pending(_upgrade.id):
		_upgrade.uncertain = true
		publish(_endpoint.state)
		return false
	_upgrade.clear()
	return true

func dispose() -> void:
	_disposed = true
	if is_instance_valid(_endpoint):
		if _endpoint.state_changed.is_connected(publish): _endpoint.state_changed.disconnect(publish)
		if _endpoint.operation_finished.is_connected(_session.finish): _endpoint.operation_finished.disconnect(_session.finish)

func publish(snapshot: Dictionary) -> void:
	if _disposed: return
	var view := snapshot.duplicate(true)
	var unresolved := not _upgrade.is_empty() and bool(_upgrade.uncertain)
	if view.get("active",false): _recovery_hidden = false
	if view.get("active",false) or (unresolved and not _recovery_hidden): view["upgradePending"] = unresolved
	_dispatcher.set_domain("upgrade", view)

func select_item(payload: Dictionary) -> Dictionary:
	return await _submit("select", payload)

static func valid_item(p: Dictionary) -> bool:
	return p.size() == 4 and ItemUiAdapter.valid_item_identity(p) and NpcUiAdapter.valid_service({"npc_instance_id":p.get("npc_instance_id"),"service_id":p.get("service_id")})

func retry_upgrade(_payload: Dictionary = {}) -> Dictionary:
	return await _retry(true)

func _retry(allow_execution: bool) -> Dictionary:
	if _disposed: return _session.closed_result()
	if not _journal_ready: return {"ok":false,"error":"journal_unavailable"}
	if _upgrade.is_empty(): return {"ok":false,"error":"no_pending_upgrade"}
	if _in_flight: return {"ok":false,"error":"too_fast"}
	var id := _session.begin()
	if id.is_empty(): return _session.closed_result()
	_in_flight = true
	_endpoint.request_upgrade.rpc_id(1,"receipt","","","",0,id,_upgrade.id)
	var result := await _session.wait(id,_tree)
	if _disposed: return result
	_in_flight = false
	if result.ok:
		if not _release_upgrade(): return {"ok":false,"error":"journal_unavailable"}
		publish(_endpoint.state)
		return result
	if result.get("error","") == "unknown_command" and allow_execution:
		return await _submit("upgrade",_upgrade.payload.duplicate(true))
	_upgrade.uncertain = true
	publish(_endpoint.state)
	return {"ok":false,"error":"upgrade_pending"}

func _submit(action: String, p: Dictionary) -> Dictionary:
	if _disposed: return _session.closed_result()
	if action == "upgrade":
		if not _journal_ready: return {"ok":false,"error":"journal_unavailable"}
		if _in_flight: return {"ok":false,"error":"too_fast"}
		if not _upgrade.is_empty() and _upgrade.payload != p: return {"ok":false,"error":"upgrade_pending"}
	if action == "upgrade" and _upgrade.is_empty():
		var intention := "upgrade-" + Crypto.new().generate_random_bytes(16).hex_encode()
		if not journal.save_pending(intention,p):
			_journal_ready = false
			return {"ok":false,"error":"journal_unavailable"}
		_upgrade = {"id":intention,"payload":p.duplicate(true),"uncertain":false}
	var id: String = _session.begin()
	if id.is_empty(): return _session.closed_result()
	var operation_id := ""
	if action == "upgrade":
		operation_id = _upgrade.id
		_in_flight = true
	_endpoint.request_upgrade.rpc_id(1,action,p.npc_instance_id,p.service_id,p.id,int(p.revision),id,operation_id)
	var result := await _session.wait(id, _tree)
	if _disposed: return result
	if action == "upgrade":
		_in_flight = false
		if result.ok or result.get("error", "") in ["funds","material","stale","owner","placement","unsupported_item","upgrade_level","request"]:
			# Store rejection follows receipt lookup; a committed intent would replay success.
			if not _release_upgrade(): return {"ok":false,"error":"journal_unavailable"}
		elif bool(_upgrade.uncertain) or result.get("error", "") in ["timeout","ui_reload","disconnected","storage"]:
			_upgrade.uncertain = true
			publish(_endpoint.state)
			return {"ok":false,"error":"upgrade_pending"}
		else:
			if not _release_upgrade(): return {"ok":false,"error":"journal_unavailable"}
		publish(_endpoint.state)
	return result
