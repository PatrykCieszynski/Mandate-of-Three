extends RefCounted
## Map-local correlation/publication shared only by NPC Shop and Upgrade.
var _endpoint: Node
var _runtime: RefCounted
var _kind: String
var _pending: Dictionary={}

func _init(endpoint: Node, runtime: RefCounted, kind: String) -> void:
	_endpoint=endpoint
	_runtime=runtime
	_kind=kind
	_runtime.finished.connect(_finished)
	_runtime.committed.connect(_committed)

func dispose() -> void:
	_runtime.finished.disconnect(_finished)
	_runtime.committed.disconnect(_committed)
	_pending.clear()

func remove_peer(peer: int) -> void: _pending.erase(peer)

func buy(peer: int, command: String, operation: String, shop: ShopDefinition, offer: StringName, position: int) -> void:
	_capture(peer,command,operation,_runtime.buy(peer,operation,shop,offer,position))

func upgrade(peer: int, command: String, operation: String, recipe: UpgradeDefinition, uid: String, revision: int) -> void:
	_capture(peer,command,operation,_runtime.upgrade(peer,operation,recipe,uid,revision))

func receipt(peer: int, command: String, operation: String) -> void:
	_capture(peer,command,operation,_runtime.receipt(peer,_kind,operation))

func busy(peer: int) -> bool: return _pending.has(peer)

func _capture(peer: int, command: String, operation: String, queued: Dictionary) -> void:
	if queued.queued: _pending[peer]={"command":command,"operation":operation}
	else: _reply(peer,command,{"ok":false,"error":queued.error})

func _owns(peer: int) -> bool:
	return is_instance_valid(_endpoint) and _endpoint.get_parent().characters.has(peer) and _endpoint.services.player_for_peer(peer)!=null and _endpoint.services.inventory_runtime()!=null and _endpoint.services.inventory_runtime().status(peer)!="detached"

func _finished(peer: int, kind: String, operation: String, result: Dictionary) -> void:
	if kind!=_kind: return
	var pending: Dictionary=_pending.get(peer,{})
	if pending.is_empty() or pending.operation!=operation: return
	_pending.erase(peer)
	if _kind=="upgrade": _endpoint.publish(peer)
	else: _endpoint._publish(peer)
	_reply(peer,pending.command,result)

func _committed(peer: int, kind: String) -> void:
	if kind!=_kind or not _owns(peer): return
	_endpoint.get_parent().inventory_endpoint.publish_inventory_change(peer)
	_endpoint.get_parent().currency_endpoint.resynchronize(peer)

func _reply(peer: int, command: String, result: Dictionary) -> void:
	if command.is_empty() or not _owns(peer): return
	var error: String=str(result.get("error","storage"))
	# Existing client journals retain uncertainty on 'storage'. A volatile busy/
	# queued/recovery result must never look like a definitive rejected purchase.
	if error in ["operation_pending","recovery_required","stale_session","session_required","outcome_unknown","unavailable","busy"]: error="storage"
	_endpoint.receive_operation.rpc_id(peer,command,{"ok":true} if result.get("ok",false) else {"ok":false,"error":error})
