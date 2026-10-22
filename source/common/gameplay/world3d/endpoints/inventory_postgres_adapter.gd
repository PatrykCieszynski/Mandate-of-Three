extends RefCounted
## Map-local RPC correlation/publication only. Runtime owns session-qualified
## workflows; native stores own every transaction. No SQL or client identity here.
var _endpoint: InventoryEndpoint3D
var _runtime: RefCounted
var _pending: Dictionary={}
var _storage: RefCounted

func _init(endpoint: InventoryEndpoint3D, runtime: RefCounted) -> void:
	_endpoint=endpoint
	_runtime=runtime
	_runtime.snapshot_applied.connect(_snapshot)
	_runtime.operation_finished.connect(_finished)
	_runtime.recovery_failed.connect(_failed)
	_runtime.inventory_committed.connect(_committed)
	_runtime.ready_changed.connect(_ready_changed)
	_storage=_endpoint.services.storage_runtime()
	if _storage!=null:
		_storage.finished.connect(_storage_finished)
		_storage.committed.connect(_committed)

func dispose() -> void:
	_runtime.snapshot_applied.disconnect(_snapshot)
	_runtime.operation_finished.disconnect(_finished)
	_runtime.recovery_failed.disconnect(_failed)
	_runtime.inventory_committed.disconnect(_committed)
	_runtime.ready_changed.disconnect(_ready_changed)
	if _storage!=null:
		_storage.finished.disconnect(_storage_finished)
		_storage.committed.disconnect(_committed)
	_pending.clear()

func remove_peer(peer: int) -> void: _pending.erase(peer)

func initialize_peer(peer: int) -> void:
	var snapshot: Dictionary=_runtime.snapshot_for_peer(peer)
	if not snapshot.is_empty():
		_snapshot(peer,snapshot)
		if _runtime.mutations_allowed(peer): _endpoint.publish_prepared_inventory(peer)

func submit(peer: int, command: String, operation: String, action: String, uid: String, revision: int, position: int) -> void:
	if _pending.has(peer):
		_reply(peer,command,{"ok":false,"error":"operation_pending"})
		return
	if _endpoint.services.transfer_pending(peer):
		_reply(peer,command,{"ok":false,"error":"transfer_pending"})
		return
	var result: Dictionary=_runtime.submit(peer,operation,action,uid,revision,position)
	_capture(peer,command,operation,result)

func receipt(peer: int, command: String, operation: String) -> void:
	if _pending.has(peer):
		_reply(peer,command,{"ok":false,"error":"operation_pending"})
		return
	_capture(peer,command,operation,_runtime.request_outcome(peer,operation))

func storage_submit(peer: int, command: String, operation: String, body: Dictionary) -> void:
	if _pending.has(peer):
		_reply(peer,command,{"ok":false,"error":"operation_pending"})
		return
	if _storage==null:
		_reply(peer,command,{"ok":false,"error":"unsupported"})
		return
	if _endpoint.services.transfer_pending(peer):
		_reply(peer,command,{"ok":false,"error":"transfer_pending"})
		return
	_capture(peer,command,operation,_storage.transfer(peer,operation,body),"storage")

func storage_receipt(peer: int, command: String, operation: String) -> void:
	if _pending.has(peer):
		_reply(peer,command,{"ok":false,"error":"operation_pending"})
		return
	if _storage==null:
		_reply(peer,command,{"ok":false,"error":"unsupported"})
		return
	_capture(peer,command,operation,_storage.receipt(peer,operation),"storage")

func _capture(peer: int, command: String, operation: String, result: Dictionary, kind: String = "inventory") -> void:
	if result.queued:
		_pending[peer]={"command":command,"operation":operation,"kind":kind}
	else: _reply(peer,command,{"ok":false,"error":result.error})

func _owns(peer: int) -> bool:
	return _endpoint.has_inventory_peer(peer) and _runtime.status(peer)!="detached"

func _snapshot(peer: int, state: Dictionary) -> void:
	if not _owns(peer): return
	var snapshot:=state.duplicate(true)
	var marker: Dictionary=snapshot.item_state
	snapshot.economic_context={"authority_id":marker.authority_id,"account_id":marker.account_id,"character_id":marker.character_id}
	if _storage==null: snapshot.storage={"ok":false,"error":"unsupported","items":[]}
	_endpoint.prepare_inventory_snapshot(peer,snapshot)

func _ready_changed(peer: int, ready: bool) -> void:
	# Initial hydration precedes the PG readiness ACK. Do not invite the client's
	# automatic receipt lookup into that still-recovering lane. Command refresh
	# likewise publishes current state before its subsequent terminal response.
	if ready and _owns(peer): _endpoint.publish_prepared_inventory(peer)

func _committed(peer: int) -> void:
	if _owns(peer): _endpoint.publish_inventory_change(peer)

func _finished(peer: int, operation: String, result: Dictionary) -> void:
	_finish(peer,operation,result,"inventory")

func _storage_finished(peer: int, operation: String, result: Dictionary) -> void:
	_finish(peer,operation,result,"storage")

func _finish(peer: int, operation: String, result: Dictionary, kind: String) -> void:
	var pending: Dictionary=_pending.get(peer,{})
	if pending.is_empty() or pending.operation!=operation or pending.kind!=kind: return
	_pending.erase(peer)
	var response:=result.duplicate(true)
	# A known business outcome is final for this delivery (only Inventory also
	# persists rejections). Transport/recovery/missing receipts remain unresolved.
	if response.get("error","") not in ["unknown_command","storage","outcome_unknown","busy","unavailable","recovery_required","operation_pending","stale_session","session_required"]: response.terminal=true
	_reply(peer,pending.command,response)

func _failed(peer: int, reason: String) -> void:
	var pending: Dictionary=_pending.get(peer,{})
	if not pending.is_empty() and pending.kind=="storage": return # Storage owns its reconciliation/retry.
	_pending.erase(peer)
	if not pending.is_empty(): _reply(peer,pending.command,{"ok":false,"error":reason})

func _reply(peer: int, command: String, result: Dictionary) -> void:
	if not command.is_empty() and _owns(peer): _endpoint.receive_operation.rpc_id(peer,command,result)
