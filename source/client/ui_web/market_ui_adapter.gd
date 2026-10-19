class_name MarketUiAdapter
extends RefCounted
signal state_updated(snapshot: Dictionary)
var _endpoint: MarketEndpoint3D
var _dispatcher: UiCommandDispatcher
var _session: UiCommandSession
var _tree: SceneTree
var active := false
var _disposed := false
var journal = preload("res://source/client/ui_web/local_economy_journal.gd").new("shop-revenue-","user://pending_shop_revenue")
var _context: Dictionary = {}
var _journal_ready := false
var _revenue_intent := ""
var _revenue_busy := false
var _revenue_uncertain := false
const SellerActions: Array[String]=["list","edit","cancel","configure","claim"]
var seller_journal = preload("res://source/client/ui_web/local_economy_journal.gd").new("seller-","user://pending_seller_commands")
var _seller_intent: Dictionary={}
var _seller_ready:=false
var _seller_busy:=false
var _seller_enabled:=false
func attach(endpoint: MarketEndpoint3D, dispatcher: UiCommandDispatcher, session: UiCommandSession, tree: SceneTree) -> void:
	_endpoint = endpoint
	_dispatcher = dispatcher
	_session = session
	_tree = tree
	dispatcher.register_command("market.retry_seller",func(p: Dictionary)->bool:return p.is_empty(),func(_p: Dictionary)->Dictionary:return await retry_seller())
	dispatcher.register_command("market.collect_revenue",func(p: Dictionary)->bool:return p.is_empty(),func(_p: Dictionary)->Dictionary:return await collect_revenue())
	dispatcher.register_command("market.retry_revenue",func(p: Dictionary)->bool:return p.is_empty(),func(_p: Dictionary)->Dictionary:return await retry_revenue())
	for action: String in ["list","edit","cancel","claim","configure","receipt","buy"]:
		dispatcher.register_command("market."+action,_valid.bind(action),_submit.bind(action))
	dispatcher.register_command("market.close",func(p: Dictionary) -> bool: return p.is_empty(),func(_p: Dictionary) -> Dictionary:
		close()
		return {"ok":true})
	endpoint.state_changed.connect(publish)
	publish(endpoint.state)

func accept_context(snapshot: Dictionary) -> void:
	if _disposed or not snapshot.get("ok",false): return
	var context: Dictionary = snapshot.get("economic_context",{})
	if context.is_empty() or context==_context: return
	if not _context.is_empty():
		_journal_ready=false
		_seller_ready=false
		return
	_context=context.duplicate(true)
	var seller: Dictionary=seller_journal.configure(context)
	if seller.ok and (seller.entry.is_empty() or valid_seller_intent(seller.entry.payload)):
		_seller_ready=true
		if not seller.entry.is_empty():
			_seller_intent=seller.entry.duplicate(true)
			retry_seller.call_deferred(false)
	var restored: Dictionary = journal.configure(context)
	if not restored.ok or (not restored.entry.is_empty() and not restored.entry.payload.is_empty()): return
	_journal_ready=true
	if restored.entry.is_empty(): return
	_revenue_intent=restored.entry.id
	_revenue_uncertain=true
	publish(_endpoint.state)
	retry_revenue.call_deferred(false) # Discovery only. Explicit Retry may execute.

func _finish_revenue(result: Dictionary) -> Dictionary:
	if _disposed: return result
	_revenue_busy=false
	if result.ok or result.get("error","") in ["wallet_full","nothing_to_claim"]:
		if not journal.clear_pending(_revenue_intent):
			_revenue_uncertain=true
			publish(_endpoint.state)
			return {"ok":false,"error":"journal_unavailable"}
		_revenue_intent=""
		_revenue_uncertain=false
	else:
		_revenue_uncertain=true
	publish(_endpoint.state)
	return result if not _revenue_uncertain else {"ok":false,"error":"revenue_pending"}

func collect_revenue() -> Dictionary:
	if _disposed: return _session.closed_result()
	if not _journal_ready: return {"ok":false,"error":"journal_unavailable"}
	if _revenue_busy: return {"ok":false,"error":"too_fast"}
	if not _revenue_intent.is_empty(): return {"ok":false,"error":"revenue_pending"}
	var intention := "shop-revenue-"+Crypto.new().generate_random_bytes(16).hex_encode()
	if not journal.save_pending(intention,{}): return {"ok":false,"error":"journal_unavailable"}
	_revenue_intent=intention
	return await _execute_revenue()

func _execute_revenue() -> Dictionary:
	_revenue_busy=true
	publish(_endpoint.state)
	return _finish_revenue(await _submit({"command_id":_revenue_intent},"claim_revenue"))

func retry_revenue(allow_execution: bool = true) -> Dictionary:
	if _disposed: return _session.closed_result()
	if not _journal_ready: return {"ok":false,"error":"journal_unavailable"}
	if _revenue_intent.is_empty(): return {"ok":false,"error":"no_pending_revenue"}
	if _revenue_busy: return {"ok":false,"error":"too_fast"}
	_revenue_busy=true
	publish(_endpoint.state)
	var result := await _submit({"command_id":_revenue_intent},"receipt")
	if _disposed: return result
	if result.get("error","")=="unknown_command":
		if allow_execution: return await _execute_revenue()
		_revenue_busy=false
		_revenue_uncertain=true
		publish(_endpoint.state)
		return {"ok":false,"error":"revenue_pending"}
	return _finish_revenue(result)

func open() -> Dictionary:
	if _disposed: return _session.closed_result()
	active = true
	# Reopening must repair the existing lane, not enqueue an unrelated view that
	# its unresolved mutation would reject. Discovery never executes a saved body.
	if not _seller_intent.is_empty():
		var recovery:=await retry_seller(false)
		if _disposed: return recovery
		if not _seller_intent.is_empty():
			publish(_endpoint.state)
			return {"ok":true} if _endpoint.state.get("ok",false) else recovery
	var result := await _submit({},"open")
	if not _disposed and not result.ok: close()
	return result
func close() -> void:
	active = false
	publish(_endpoint.state)
static func _valid(payload: Dictionary, action: String) -> bool:
	return MarketEndpoint3D.valid(action,payload)

func _submit(payload: Dictionary, action: String) -> Dictionary:
	if _seller_enabled and action in SellerActions: return await _submit_seller(payload,action)
	return await _send(payload,action)

func _send(payload: Dictionary, action: String) -> Dictionary:
	var id := _session.begin()
	if id.is_empty(): return _session.closed_result()
	_endpoint.request_market.rpc_id(1,action,payload,id)
	return await _session.wait(id,_tree)
func publish(snapshot: Dictionary) -> void:
	if _disposed: return
	if snapshot.get("seller_runtime",false): _seller_enabled=true
	if not active or not snapshot.get("ok",false):
		_dispatcher.set_domain("market",{"active":false})
		return
	var offers: Array = []
	for offer: Dictionary in snapshot.offers:
		var item := ItemUiAdapter.item_model(offer.item)
		item.merge({"x":int(offer.position)%5,"y":int(offer.position)/5,"page":0})
		offers.append({"id":offer.offer_id,"revision":int(offer.revision),"price":offer.price,"item":item})
	var claims: Array = []
	for item: Dictionary in snapshot.claims.slice(0,20): claims.append(ItemUiAdapter.item_model(item))
	var view := {"active":true,"shopId":int(snapshot.shop_id),"name":snapshot.name,"status":snapshot.status,"revision":int(snapshot.revision),"columns":5,"rows":8,"offers":offers,"claims":claims,"claimableYang":str(snapshot.get("claimable_yang","0")),"revenuePending":_revenue_uncertain,"revenueBusy":_revenue_busy}
	view.sellerPending=not _seller_intent.is_empty()
	view.sellerBusy=_seller_busy
	_dispatcher.set_domain("market",view)
	state_updated.emit(view)
func dispose() -> void:
	_disposed=true;active=false
	if is_instance_valid(_endpoint):
		if _endpoint.state_changed.is_connected(publish): _endpoint.state_changed.disconnect(publish)

static func valid_seller_intent(intent: Dictionary) -> bool:
	if intent.size()!=2 or intent.get("action") not in SellerActions or not intent.get("payload") is Dictionary: return false
	var body: Dictionary=intent.payload.duplicate(true)
	body.command_id="seller-"+"0".repeat(32)
	return MarketRequestRules.valid_command(intent.action,body)

func _submit_seller(payload: Dictionary, action: String) -> Dictionary:
	if _disposed: return _session.closed_result()
	if not _seller_ready: return {"ok":false,"error":"journal_unavailable"}
	if _seller_busy: return {"ok":false,"error":"seller_pending"}
	var body:=payload.duplicate(true)
	body.erase("command_id") # Browser IDs are not durable native journal identity.
	var intention: Dictionary={"action":action,"payload":body}
	if not valid_seller_intent(intention): return {"ok":false,"error":"request"}
	if not _seller_intent.is_empty() and _seller_intent.payload!=intention: return {"ok":false,"error":"seller_pending"}
	if _seller_intent.is_empty():
		var operation: String="seller-"+Crypto.new().generate_random_bytes(16).hex_encode()
		if not seller_journal.save_pending(operation,intention): return {"ok":false,"error":"journal_unavailable"}
		_seller_intent={"id":operation,"payload":intention}
	_seller_busy=true
	publish(_endpoint.state)
	body.command_id=_seller_intent.id
	return _finish_seller(await _send(body,action))

func _finish_seller(result: Dictionary) -> Dictionary:
	if _disposed: return result
	_seller_busy=false
	if result.get("ok",false) or result.get("terminal",false):
		if not seller_journal.clear_pending(_seller_intent.id):
			publish(_endpoint.state)
			return {"ok":false,"error":"journal_unavailable"}
		_seller_intent={}
		publish(_endpoint.state)
		return result
	publish(_endpoint.state)
	return {"ok":false,"error":"seller_pending"}

func retry_seller(allow_execution: bool = true) -> Dictionary:
	if _disposed: return _session.closed_result()
	if not _seller_ready: return {"ok":false,"error":"journal_unavailable"}
	if _seller_intent.is_empty(): return {"ok":false,"error":"no_pending_seller"}
	if _seller_busy: return {"ok":false,"error":"seller_pending"}
	_seller_busy=true
	publish(_endpoint.state)
	var result:=await _send({"command_id":_seller_intent.id},"receipt")
	if _disposed: return result
	if result.get("error","")=="unknown_command" and allow_execution:
		_seller_busy=false
		return await _submit_seller(_seller_intent.payload.payload.duplicate(true),_seller_intent.payload.action)
	return _finish_seller(result)
