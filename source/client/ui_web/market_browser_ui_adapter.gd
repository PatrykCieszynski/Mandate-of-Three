class_name MarketBrowserUiAdapter
extends RefCounted
var active := false
var _endpoint: MarketEndpoint3D
var _dispatcher: UiCommandDispatcher
var _session: UiCommandSession
var _tree: SceneTree
var _view := {"active":false,"catalog":[],"stats":{},"results":[],"cursor":"","shop":{},"highlight":"","error":""}
var _generations := {}
var _epoch := 0
func attach(endpoint: MarketEndpoint3D,dispatcher: UiCommandDispatcher,session: UiCommandSession,tree: SceneTree) -> void:
	_endpoint=endpoint;_dispatcher=dispatcher;_session=session;_tree=tree
	for action: String in ["catalog","search","visit"]: dispatcher.register_command("market.browser."+action,_valid.bind(action),_query.bind(action))
	dispatcher.register_command("market.browser.close",func(p: Dictionary)->bool:return p.is_empty(),func(_p: Dictionary)->Dictionary:
		close();return {"ok":true})
	endpoint.query_finished.connect(session.finish)
	publish()
static func _valid(p: Dictionary,action: String) -> bool:
	if action=="visit": return p.size()==2 and p.has_all(["shop_id","offer_id"]) and MarketEndpoint3D.valid_query("visit",{"shop_id":p.shop_id}) and p.offer_id is String and (p.offer_id.is_empty() or ItemInstance.valid_uid(p.offer_id))
	return MarketEndpoint3D.valid_query(action,p)
func open() -> void:
	active=true;publish();await _query({"query":""},"catalog")
func close() -> void:
	active=false;_epoch+=1;_generations.clear();publish()
func publish() -> void:
	_view.active=active
	_dispatcher.set_domain("market_browser",_view if active else {"active":false})
func _query(payload: Dictionary,action: String) -> Dictionary:
	if not active: return {"ok":false,"error":"closed"}
	var epoch:=_epoch
	var generation:=int(_generations.get(action,0))+1;_generations[action]=generation
	var id:=_session.begin()
	if id.is_empty(): return _session.closed_result()
	_endpoint.request_query.rpc_id(1,action,{"shop_id":int(payload.shop_id)} if action=="visit" else payload,id)
	var result:=await _session.wait(id,_tree)
	if not active or epoch!=_epoch or int(_generations.get(action,0))!=generation: return {"ok":false,"error":"superseded"}
	_view.error="" if result.ok else str(result.error)
	if result.ok:
		match action:
			"catalog": _view.catalog=result.items;_view.stats=result.stats
			"search":
				_view.results=[];_view.cursor=result.next_cursor
				for row: Dictionary in result.results: _view.results.append({"offerId":row.offer_id,"shopId":int(row.shop_id),"shopName":row.shop_name,"revision":int(row.revision),"price":int(row.price),"item":ItemUiAdapter.item_model(row.item)})
			"visit":
				_view.highlight=payload.offer_id
				var offers: Array=[]
				for row: Dictionary in result.offers:
					var item:=ItemUiAdapter.item_model(row.item);item.merge({"x":int(row.position)%5,"y":int(row.position)/5,"page":0})
					offers.append({"id":row.offer_id,"revision":int(row.revision),"price":int(row.price),"item":item})
				_view.shop={"active":true,"shopId":int(result.shop_id),"name":result.name,"status":result.status,"revision":int(result.revision),"columns":5,"rows":8,"offers":offers,"claims":[]}
	elif action=="visit": _view.shop={};_view.highlight=""
	publish()
	return {"ok":true} if result.ok else {"ok":false,"error":result.error}
func refresh_shop() -> void:
	if active and not _view.shop.is_empty(): await _query({"shop_id":_view.shop.shopId,"offer_id":_view.highlight},"visit")
func dispose() -> void:
	if is_instance_valid(_endpoint) and _endpoint.query_finished.is_connected(_session.finish): _endpoint.query_finished.disconnect(_session.finish)
