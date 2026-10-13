class_name MarketUiAdapter
extends RefCounted
signal state_updated(snapshot: Dictionary)
var _endpoint: MarketEndpoint3D
var _dispatcher: UiCommandDispatcher
var _session: UiCommandSession
var _tree: SceneTree
var active := false
func attach(endpoint: MarketEndpoint3D, dispatcher: UiCommandDispatcher, session: UiCommandSession, tree: SceneTree) -> void:
	_endpoint = endpoint
	_dispatcher = dispatcher
	_session = session
	_tree = tree
	for action: String in ["list","edit","cancel","claim","configure","receipt","buy"]:
		dispatcher.register_command("market."+action,_valid.bind(action),_submit.bind(action))
	dispatcher.register_command("market.close",func(p: Dictionary) -> bool: return p.is_empty(),func(_p: Dictionary) -> Dictionary:
		close()
		return {"ok":true})
	endpoint.state_changed.connect(publish)
	endpoint.operation_finished.connect(session.finish)
	publish(endpoint.state)

func open() -> Dictionary:
	active = true
	var result := await _submit({},"open")
	if not result.ok: close()
	return result
func close() -> void:
	active = false
	publish(_endpoint.state)
static func _valid(payload: Dictionary, action: String) -> bool:
	return MarketEndpoint3D.valid(action,payload)

func _submit(payload: Dictionary, action: String) -> Dictionary:
	var id := _session.begin()
	if id.is_empty(): return _session.closed_result()
	_endpoint.request_market.rpc_id(1,action,payload,id)
	return await _session.wait(id,_tree)
func publish(snapshot: Dictionary) -> void:
	if not active or not snapshot.get("ok",false):
		_dispatcher.set_domain("market",{"active":false})
		return
	var offers: Array = []
	for offer: Dictionary in snapshot.offers:
		var item := ItemUiAdapter.item_model(offer.item)
		item.merge({"x":int(offer.position)%5,"y":int(offer.position)/5,"page":0})
		offers.append({"id":offer.offer_id,"revision":int(offer.revision),"price":int(offer.price),"item":item})
	var claims: Array = []
	for item: Dictionary in snapshot.claims.slice(0,20): claims.append(ItemUiAdapter.item_model(item))
	var view := {"active":true,"shopId":int(snapshot.shop_id),"name":snapshot.name,"status":snapshot.status,"revision":int(snapshot.revision),"columns":5,"rows":8,"offers":offers,"claims":claims}
	_dispatcher.set_domain("market",view)
	state_updated.emit(view)
func dispose() -> void:
	if is_instance_valid(_endpoint):
		if _endpoint.state_changed.is_connected(publish): _endpoint.state_changed.disconnect(publish)
		if _endpoint.operation_finished.is_connected(_session.finish): _endpoint.operation_finished.disconnect(_session.finish)
