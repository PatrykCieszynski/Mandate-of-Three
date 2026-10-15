extends RefCounted
signal recovery_needed
const LocalJournal = preload("res://source/client/ui_web/local_economy_journal.gd")
var journal = LocalJournal.new("storage-","user://pending_storage_commands")
var _endpoint: InventoryEndpoint3D
var _dispatcher: UiCommandDispatcher
var _session: UiCommandSession
var _tree: SceneTree
var _storage_open: Callable
var _context: Dictionary = {}
var _journal_ready := false
var _intent: Dictionary = {}
var _in_flight := false
var _disposed := false
var _owns_result_connection := false

func attach(endpoint: InventoryEndpoint3D, dispatcher: UiCommandDispatcher, session: UiCommandSession, tree: SceneTree, storage_open: Callable) -> void:
	_endpoint = endpoint
	_dispatcher = dispatcher
	_session = session
	_tree = tree
	_storage_open = storage_open
	dispatcher.register_command("storage.transfer",ItemUiAdapter.valid_storage,transfer)
	dispatcher.register_command("storage.retry",func(p: Dictionary) -> bool: return p.is_empty(),retry_storage)
	endpoint.state_changed.connect(publish)
	# Composition shares one transport session with Inventory, not two signal owners.
	if not endpoint.operation_finished.is_connected(session.finish):
		endpoint.operation_finished.connect(session.finish)
		_owns_result_connection = true
	publish(endpoint.state)

func dispose() -> void:
	_disposed = true
	if is_instance_valid(_endpoint):
		if _endpoint.state_changed.is_connected(publish): _endpoint.state_changed.disconnect(publish)
		if _owns_result_connection and _endpoint.operation_finished.is_connected(_session.finish): _endpoint.operation_finished.disconnect(_session.finish)
	_storage_open = Callable()

func publish(snapshot: Dictionary) -> void:
	if _disposed or not snapshot.get("ok",false): return
	accept_context(snapshot)
	var storage: Dictionary = snapshot.get("storage",{})
	if not storage.get("ok",false): return
	var stored: Array = []
	for item: Dictionary in storage.items:
		var position := int(item.bag_position)
		var display := ItemUiAdapter.item_model(item)
		display.merge({"x":position % 15,"y":(position % 135)/15,"page":position/135})
		stored.append(display)
	_dispatcher.set_domain("storage",{"columns":15,"rows":9,"pages":2,"items":stored,"recoveryPending":not _intent.is_empty() and bool(_intent.uncertain)})

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
	if not restored.entry.is_empty() and not ItemUiAdapter.valid_storage(restored.entry.payload): return
	_journal_ready = true
	if restored.entry.is_empty(): return
	_intent = restored.entry.duplicate(true)
	_intent.uncertain = true
	recovery_needed.emit()
	_retry.call_deferred(false)

func _retain() -> void:
	_intent.uncertain = true
	publish(_endpoint.state)
	recovery_needed.emit()

func _release() -> bool:
	if not journal.clear_pending(_intent.id):
		_retain()
		return false
	_intent.clear()
	return true

func retry_storage(_payload: Dictionary = {}) -> Dictionary:
	return await _retry(true)

func _retry(allow_execution: bool) -> Dictionary:
	if _disposed: return _session.closed_result()
	if not _journal_ready: return {"ok":false,"error":"journal_unavailable"}
	if _intent.is_empty(): return {"ok":false,"error":"no_pending_storage"}
	if _in_flight: return {"ok":false,"error":"too_fast"}
	var id := _session.begin()
	if id.is_empty(): return _session.closed_result()
	_in_flight = true
	_endpoint.request_storage_receipt.rpc_id(1,_intent.id,id)
	var result := await _session.wait(id,_tree)
	if _disposed: return result
	_in_flight = false
	if result.ok:
		if not _release(): return {"ok":false,"error":"journal_unavailable"}
		publish(_endpoint.state)
		return result
	if result.get("error","") == "unknown_command" and allow_execution:
		return await transfer(_intent.payload.duplicate(true))
	_retain()
	return {"ok":false,"error":"storage_pending"}

func transfer(payload: Dictionary) -> Dictionary:
	if _disposed: return _session.closed_result()
	# UX guard only, as before. World alone decides account access/custody.
	if not _storage_open.call(): return {"ok":false,"error":"closed"}
	if not _journal_ready: return {"ok":false,"error":"journal_unavailable"}
	if _in_flight: return {"ok":false,"error":"too_fast"}
	if not ItemUiAdapter.valid_storage(payload): return {"ok":false,"error":"request"}
	if not _intent.is_empty() and _intent.payload != payload: return {"ok":false,"error":"storage_pending"}
	if _intent.is_empty():
		var operation_id := "storage-" + Crypto.new().generate_random_bytes(16).hex_encode()
		if not journal.save_pending(operation_id,payload):
			_journal_ready = false
			return {"ok":false,"error":"journal_unavailable"}
		_intent = {"id":operation_id,"payload":payload.duplicate(true),"uncertain":false}
	var id := _session.begin()
	if id.is_empty(): return _session.closed_result()
	_in_flight = true
	_endpoint.request_storage.rpc_id(1,payload.id,int(payload.revision),payload.from,payload.to,int(payload.x),int(payload.y),int(payload.page),payload.quick,id,_intent.id)
	var result := await _session.wait(id,_tree)
	if _disposed: return result
	_in_flight = false
	if result.ok or result.get("error","") in ["stale","owner","request","occupied","full","placement","invalid_item","unknown_definition"]:
		if not _release(): return {"ok":false,"error":"journal_unavailable"}
	else:
		_retain()
		return {"ok":false,"error":"storage_pending"}
	publish(_endpoint.state)
	return result
