extends RefCounted
## Map-local RPC admission/correlation and current-account presentation only.
var _endpoint: MarketEndpoint3D
var _runtime: RefCounted
var _pending: Dictionary={}

func _init(endpoint: MarketEndpoint3D, runtime: RefCounted) -> void:
	_endpoint=endpoint
	_runtime=runtime
	_runtime.finished.connect(_finished)
	_runtime.snapshot_applied.connect(_snapshot)
	_runtime.committed.connect(_committed)

func dispose() -> void:
	_runtime.finished.disconnect(_finished)
	_runtime.snapshot_applied.disconnect(_snapshot)
	_runtime.committed.disconnect(_committed)
	_pending.clear()

func remove_peer(peer: int) -> void: _pending.erase(peer)

func pending(peer: int, id: String) -> bool:
	return _pending.has(peer) and _pending[peer].id==id

func request(peer: int, action: String, body: Dictionary, id: String) -> void:
	if not _owns(peer): return
	if _pending.has(peer):
		if _pending[peer].id==id: return
		_reply(peer,id,{"ok":false,"error":"operation_pending"})
		return
	if not MarketRequestRules.valid_command(action,body):
		_reply(peer,id,{"ok":false,"error":"request"})
		return
	if action not in ["open","receipt"] and _endpoint.services.transfer_pending(peer):
		_reply(peer,id,{"ok":false,"error":"transfer_pending"})
		return
	var queued: Dictionary
	if action=="open": queued=_runtime.open(peer)
	elif action=="receipt": queued=_runtime.receipt(peer,body.command_id)
	else: queued=_runtime.submit(peer,action,body)
	if queued.queued: _pending[peer]={"id":id,"operation":body.get("command_id",""),"query":false}
	else: _reply(peer,id,{"ok":false,"error":queued.error})

func _owns(peer: int) -> bool:
	return _endpoint.get_parent().characters.has(peer) and _endpoint.services.inventory_runtime().status(peer)!="detached"

func _snapshot(peer: int, snapshot: Dictionary) -> void:
	if _owns(peer):
		_endpoint.receive_state.rpc_id(peer,snapshot)
		if snapshot.has("exchange"): _endpoint.receive_exchange_state.rpc_id(peer,snapshot.exchange)

func _committed(peer: int, action: String) -> void:
	if action in ["list","cancel","claim","buy","deposit","withdraw"] and _owns(peer): _endpoint.get_parent().inventory_endpoint.publish_inventory_change(peer)

func _finished(peer: int, operation: String, result: Dictionary) -> void:
	var pending: Dictionary=_pending.get(peer,{})
	if pending.is_empty() or (not pending.operation.is_empty() and pending.operation!=operation): return
	_pending.erase(peer)
	var response:=result.duplicate(true)
	if response.get("error","") not in ["storage","outcome_unknown","unknown_command","busy","unavailable","operation_pending","recovery_required","session_required","stale_session"]: response.terminal=true
	if pending.get("query",false):
		if _owns(peer): _endpoint.receive_query.rpc_id(peer,pending.id,response)
	else: _reply(peer,pending.id,response)

func _reply(peer: int, id: String, result: Dictionary) -> void:
	if _owns(peer): _endpoint.receive_operation.rpc_id(peer,id,result)

func query(peer: int, action: String, body: Dictionary, id: String) -> void:
	if not _owns(peer): return
	if _pending.has(peer):
		if _pending[peer].id!=id: _endpoint.receive_query.rpc_id(peer,id,{"ok":false,"error":"operation_pending"})
		return
	var queued: Dictionary={"queued":false,"error":"unsupported"}
	if action=="exchange" and body.is_empty(): queued=_runtime.open_exchange(peer)
	elif action=="visit" and MarketEndpoint3D.valid_query(action,body): queued=_runtime.visit(peer,int(body.shop_id))
	if queued.queued: _pending[peer]={"id":id,"operation":"","query":true}
	else: _endpoint.receive_query.rpc_id(peer,id,{"ok":false,"error":queued.error})
