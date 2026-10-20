extends RefCounted
## Map-local RPC admission/correlation and current-account presentation only.
var _endpoint: MarketEndpoint3D
var _runtime: RefCounted
var _pending: Dictionary={}
var _queries: Dictionary={}
var _disposed:=false
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")

func _init(endpoint: MarketEndpoint3D, runtime: RefCounted) -> void:
	_endpoint=endpoint
	_runtime=runtime
	_runtime.finished.connect(_finished)
	_runtime.snapshot_applied.connect(_snapshot)
	_runtime.committed.connect(_committed)

func dispose() -> void:
	_disposed=true
	_runtime.finished.disconnect(_finished)
	_runtime.snapshot_applied.disconnect(_snapshot)
	_runtime.committed.disconnect(_committed)
	_pending.clear()
	_queries.clear()

func remove_peer(peer: int) -> void:
	_pending.erase(peer)
	_queries.erase(peer)

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
	return not _disposed and is_instance_valid(_endpoint) and is_instance_valid(_endpoint.get_parent()) and _endpoint.get_parent().characters.has(peer) and _endpoint.services.inventory_runtime().status(peer)!="detached"

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
	if response.get("error","") not in ["storage","outcome_unknown","unknown_command","busy","unavailable","operation_pending","recovery_required","session_required","stale_session","participants_changed","participant_busy"]: response.terminal=true
	if pending.get("query",false):
		query_reply(peer,pending.id,response)
	else: _reply(peer,pending.id,response)

func _reply(peer: int, id: String, result: Dictionary) -> void:
	if _owns(peer): _endpoint.receive_operation.rpc_id(peer,id,result)

## Reserve IDs before endpoint rate/validation errors. Terminal history is bounded;
## active native keys remain reserved even after their timeout history is evicted.
func admit_query(peer: int, id: String) -> bool:
	if not _owns(peer): return false
	var context: Dictionary=_endpoint.services.inventory_runtime().context_for_peer(peer)
	var history: Dictionary=_queries.get(peer,{})
	if history.is_empty() or not Sessions.same_context(history.context,context):
		history={"context":context,"ids":{}}
		_queries[peer]=history
	if history.ids.has(id): return false
	if _runtime.auction!=null and _runtime.auction.has_pending(_query_key(peer,id,context)): return false
	if history.ids.size()>=64:
		for previous: String in history.ids.keys():
			if not history.ids[previous]: history.ids.erase(previous);break
		if history.ids.size()>=64: return false
	history.ids[id]=true
	return true

func _query_key(peer: int, id: String, context: Dictionary) -> String:
	return "%s:%s:%s:%s:%s" % [get_instance_id(),peer,context.get("account_id",0),context.get("epoch",0),id]

func _query_current(peer: int, context: Dictionary) -> bool:
	return _owns(peer) and Sessions.same_context(context,_endpoint.services.inventory_runtime().context_for_peer(peer))

func query_reply(peer: int, id: String, result: Dictionary) -> void:
	var history: Dictionary=_queries.get(peer,{})
	if history.is_empty() or not history.ids.get(id,false) or not _query_current(peer,history.context): return
	history.ids[id]=false
	_endpoint.receive_query.rpc_id(peer,id,result)

func _public_reply(result: Dictionary, peer: int, id: String) -> void: query_reply(peer,id,result)

func query(peer: int, action: String, body: Dictionary, id: String) -> void:
	if not _owns(peer): return
	if not MarketEndpoint3D.valid_query(action,body):
		query_reply(peer,id,{"ok":false,"error":"request"});return
	if action in ["catalog","search"]:
		if _runtime.auction==null:
			query_reply(peer,id,{"ok":false,"error":"unsupported"});return
		if action=="catalog":
			query_reply(peer,id,MarketSearchSqlite.catalog(body.query));return
		var context: Dictionary=_queries[peer].context
		_runtime.auction.submit(peer,_query_key(peer,id,context),body,_public_reply.bind(peer,id),_query_current.bind(peer,context))
		return
	if _pending.has(peer):
		query_reply(peer,id,{"ok":false,"error":"operation_pending"});return
	var queued: Dictionary={"queued":false,"error":"unsupported"}
	if action=="exchange": queued=_runtime.open_exchange(peer)
	elif action=="visit": queued=_runtime.visit(peer,int(body.shop_id))
	if queued.queued: _pending[peer]={"id":id,"operation":"","query":true}
	else: query_reply(peer,id,{"ok":false,"error":queued.error})
