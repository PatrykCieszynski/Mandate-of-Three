class_name ExchangeUiAdapter
extends RefCounted
signal state_updated(snapshot: Dictionary)
var active := false
var _endpoint: MarketEndpoint3D
var _dispatcher: UiCommandDispatcher
var _session: UiCommandSession
var _tree: SceneTree
var _state: Dictionary={}
var _retry: Dictionary={}
var _busy := false
var _disposed := false
var journal = preload("res://source/client/ui_web/local_economy_journal.gd").new("exchange-","user://pending_exchange_commands")
var _context: Dictionary={}
var _journal_ready:=false
var _native:=false
var _capability_known:=false
const NATIVE_ACTIONS: Array[String]=["deposit","withdraw","order","cancel_order"]

static func valid_intent(body: Dictionary) -> bool:
	if body.size()!=2 or body.get("action") not in NATIVE_ACTIONS or not body.get("payload") is Dictionary: return false
	var p: Dictionary=body.payload.duplicate(true)
	p.command_id="exchange-"+"0".repeat(32)
	return MarketRequestRules.valid_command(body.action,p)

func accept_context(snapshot: Dictionary) -> void:
	if _disposed or not snapshot.get("ok",false): return
	var context: Dictionary=snapshot.get("economic_context",{})
	if context.is_empty() or context==_context: return
	if not _context.is_empty():
		_journal_ready=false
		return
	_context=context.duplicate(true)
	var restored: Dictionary=journal.configure(context)
	if not restored.ok or (not restored.entry.is_empty() and not valid_intent(restored.entry.payload)): return
	_journal_ready=true
	if not restored.entry.is_empty():
		_retry={"id":restored.entry.id,"action":restored.entry.payload.action,"payload":restored.entry.payload.payload.duplicate(true)}
		recover.call_deferred(false)

func attach(endpoint: MarketEndpoint3D,dispatcher: UiCommandDispatcher,session: UiCommandSession,tree: SceneTree) -> void:
	_endpoint=endpoint;_dispatcher=dispatcher;_session=session;_tree=tree
	for action: String in ["deposit","withdraw","order","cancel_order"]: dispatcher.register_command("exchange."+action,_valid.bind(action),_submit.bind(action))
	dispatcher.register_command("exchange.retry",func(p: Dictionary)->bool:return p.is_empty(),func(_p: Dictionary)->Dictionary:
		if _retry.is_empty(): return {"ok":false,"error":"no_pending_intent"}
		return await recover())
	dispatcher.register_command("exchange.close",func(p: Dictionary)->bool:return p.is_empty(),func(_p: Dictionary)->Dictionary:
		close();return {"ok":true})
	endpoint.exchange_state_changed.connect(publish)
	publish({})
static func _valid(p: Dictionary,action: String) -> bool: return MarketEndpoint3D.valid(action,p)
func _load() -> Dictionary:
	var id:=_session.begin()
	if id.is_empty(): return _session.closed_result()
	_endpoint.request_query.rpc_id(1,"exchange",{},id)
	var result:=await _session.wait(id,_tree)
	if not _disposed and result.get("ok",false): publish(result if result.has("assets") else _state)
	return result
func open() -> void:
	active=true
	if _retry.has("id"):
		await recover(false)
		if _disposed: return
		if not _retry.is_empty(): publish(_state);return
	var result:=await _load()
	if not _disposed and not result.ok: close()
func close() -> void:
	active=false;publish(_state)
func _submit(p: Dictionary,action: String) -> Dictionary:
	if _disposed: return _session.closed_result()
	if not _capability_known:
		var loaded:=await _load()
		if _disposed or not loaded.get("ok",false): return loaded
	if _native: return await _submit_native(p,action)
	if not _retry.is_empty() and _retry.payload.command_id!=p.command_id: return {"ok":false,"error":"resolve_unknown_command"}
	if _busy: return {"ok":false,"error":"pending"}
	_retry={"action":action,"payload":p.duplicate(true)};_busy=true;publish(_state)
	var id:=_session.begin()
	if id.is_empty(): _busy=false;return _session.closed_result()
	_endpoint.request_market.rpc_id(1,action,p,id)
	var result:=await _session.wait(id,_tree)
	_busy=false
	if result.ok or result.get("error","") not in ["timeout","ui_reload","disconnected","storage"]: _retry={}
	publish(_state)
	return result
func publish(snapshot: Dictionary) -> void:
	if _disposed: return
	if snapshot.get("ok",false) and snapshot.has("assets"):
		_state=snapshot.duplicate(true)
		_native=snapshot.get("exchange_runtime",false)
		_capability_known=true
	if not active or _state.is_empty(): _dispatcher.set_domain("exchange",{"active":false});return
	var orders: Array=[]
	for row: Dictionary in _state.orders:
		orders.append({"id":row.order_id,"asset":row.base_asset,"side":row.side,"quantity":int(row.quantity),"remaining":int(row.remaining),"reserved":int(row.reserved_amount),"received":int(row.received),"priceNum":int(row.price_num),"priceDen":int(row.price_den),"revision":int(row.revision),"status":row.status})
	var depth: Array=[]
	for row: Dictionary in _state.depth: depth.append({"side":row.side,"asset":row.base_asset,"remaining":int(row.remaining),"priceNum":int(row.price_num),"priceDen":int(row.price_den)})
	var fills: Array=[]
	for row: Dictionary in _state.fills: fills.append({"id":int(row.fill_id),"asset":row.base_asset,"quantity":int(row.base_quantity),"yang":int(row.yang_amount)})
	var view: Dictionary={"active":true,"yang":int(_state.yang),"reservedYang":int(_state.reserved_yang),"assets":_state.assets,"orders":orders,"depth":depth,"fills":fills,"busy":_busy,"retryAvailable":not _retry.is_empty() and not _busy,"ledgerOnly":_state.get("ledger_only",false)}
	_dispatcher.set_domain("exchange",view);state_updated.emit(view)
func dispose() -> void:
	_disposed=true;active=false
	if is_instance_valid(_endpoint) and _endpoint.exchange_state_changed.is_connected(publish): _endpoint.exchange_state_changed.disconnect(publish)

func accept_wallet(snapshot: Dictionary) -> void:
	if _state.is_empty() or not snapshot.has("balance") or int(_state.yang)==int(snapshot.balance): return
	_state.yang=int(snapshot.balance);publish(_state)

func _send(action: String, payload: Dictionary) -> Dictionary:
	var id:=_session.begin()
	if id.is_empty(): return _session.closed_result()
	_endpoint.request_market.rpc_id(1,action,payload,id)
	return await _session.wait(id,_tree)

func _submit_native(payload: Dictionary, action: String) -> Dictionary:
	if action not in NATIVE_ACTIONS or (action in ["order","cancel_order"] and _state.get("ledger_only",true)): return {"ok":false,"error":"unsupported"}
	if not _journal_ready: return {"ok":false,"error":"journal_unavailable"}
	if _busy or not _retry.is_empty(): return {"ok":false,"error":"resolve_unknown_command"}
	var body:=payload.duplicate(true)
	body.erase("command_id")
	var saved: Dictionary={"action":action,"payload":body}
	if not valid_intent(saved): return {"ok":false,"error":"request"}
	var id: String="exchange-"+Crypto.new().generate_random_bytes(16).hex_encode()
	if not journal.save_pending(id,saved): return {"ok":false,"error":"journal_unavailable"}
	_retry={"id":id,"action":action,"payload":body}
	_busy=true
	publish(_state)
	body=body.duplicate(true)
	body.command_id=id
	return _finish_native(await _send(action,body))

func _finish_native(result: Dictionary) -> Dictionary:
	if _disposed: return result
	_busy=false
	if result.get("ok",false) or result.get("terminal",false):
		if not journal.clear_pending(_retry.id):
			publish(_state)
			return {"ok":false,"error":"journal_unavailable"}
		_retry={}
		publish(_state)
		return result
	publish(_state)
	return {"ok":false,"error":"exchange_pending"}

func recover(allow_execution: bool = true) -> Dictionary:
	if _disposed: return _session.closed_result()
	if _retry.is_empty(): return {"ok":false,"error":"no_pending_intent"}
	if not _retry.has("id"): return await _submit(_retry.payload,_retry.action)
	if _busy: return {"ok":false,"error":"exchange_pending"}
	if not _journal_ready: return {"ok":false,"error":"journal_unavailable"}
	_busy=true
	publish(_state)
	var result:=await _send("receipt",{"command_id":_retry.id})
	if _disposed: return result
	if result.get("error","")=="unknown_command" and allow_execution:
		var body: Dictionary=_retry.payload.duplicate(true)
		body.command_id=_retry.id
		result=await _send(_retry.action,body)
	return _finish_native(result)
