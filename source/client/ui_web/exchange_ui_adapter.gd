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
func attach(endpoint: MarketEndpoint3D,dispatcher: UiCommandDispatcher,session: UiCommandSession,tree: SceneTree) -> void:
	_endpoint=endpoint;_dispatcher=dispatcher;_session=session;_tree=tree
	for action: String in ["deposit","withdraw","order","cancel_order"]: dispatcher.register_command("exchange."+action,_valid.bind(action),_submit.bind(action))
	dispatcher.register_command("exchange.retry",func(p: Dictionary)->bool:return p.is_empty(),func(_p: Dictionary)->Dictionary:
		if _retry.is_empty(): return {"ok":false,"error":"no_pending_intent"}
		return await _submit(_retry.payload,_retry.action))
	dispatcher.register_command("exchange.close",func(p: Dictionary)->bool:return p.is_empty(),func(_p: Dictionary)->Dictionary:
		close();return {"ok":true})
	endpoint.exchange_state_changed.connect(publish)
	publish({})
static func _valid(p: Dictionary,action: String) -> bool: return MarketEndpoint3D.valid(action,p)
func open() -> void:
	active=true
	var id:=_session.begin()
	if id.is_empty(): return
	_endpoint.request_query.rpc_id(1,"exchange",{},id)
	var result:=await _session.wait(id,_tree)
	if result.ok: publish(result)
	else: close()
func close() -> void:
	active=false;publish(_state)
func _submit(p: Dictionary,action: String) -> Dictionary:
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
	if snapshot.get("ok",false): _state=snapshot.duplicate(true)
	if not active or _state.is_empty(): _dispatcher.set_domain("exchange",{"active":false});return
	var orders: Array=[]
	for row: Dictionary in _state.orders:
		orders.append({"id":row.order_id,"asset":row.base_asset,"side":row.side,"quantity":int(row.quantity),"remaining":int(row.remaining),"reserved":int(row.reserved_amount),"received":int(row.received),"priceNum":int(row.price_num),"priceDen":int(row.price_den),"revision":int(row.revision),"status":row.status})
	var depth: Array=[]
	for row: Dictionary in _state.depth: depth.append({"side":row.side,"asset":row.base_asset,"remaining":int(row.remaining),"priceNum":int(row.price_num),"priceDen":int(row.price_den)})
	var fills: Array=[]
	for row: Dictionary in _state.fills: fills.append({"id":int(row.fill_id),"asset":row.base_asset,"quantity":int(row.base_quantity),"yang":int(row.yang_amount)})
	var view: Dictionary={"active":true,"yang":int(_state.yang),"reservedYang":int(_state.reserved_yang),"assets":_state.assets,"orders":orders,"depth":depth,"fills":fills,"busy":_busy,"retryAvailable":not _retry.is_empty() and not _busy}
	_dispatcher.set_domain("exchange",view);state_updated.emit(view)
func dispose() -> void:
	_disposed=true;active=false
	if is_instance_valid(_endpoint) and _endpoint.exchange_state_changed.is_connected(publish): _endpoint.exchange_state_changed.disconnect(publish)

func accept_wallet(snapshot: Dictionary) -> void:
	if _state.is_empty() or not snapshot.has("balance") or int(_state.yang)==int(snapshot.balance): return
	_state.yang=int(snapshot.balance);publish(_state)
