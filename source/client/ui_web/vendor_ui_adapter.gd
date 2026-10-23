extends RefCounted
## Client basket references and journal only. No valuation, recipe matching or RNG.
signal shown
const Journal = preload("res://source/client/ui_web/local_economy_journal.gd")
var journal=Journal.new("npc-sell-","user://pending_vendor_sales")
var _endpoint: Shop3D
var _dispatcher: UiCommandDispatcher
var _session: UiCommandSession
var _tree: SceneTree
var _context: Dictionary={}
var _owned: Dictionary={}
var _basket: Array=[]
var _quote: Dictionary={}
var _intent: Dictionary={}
var _npc: Dictionary={}
var _ready:=false
var _opened:=false
var _busy:=false
var _quoting:=false
var _disposed:=false
var _serial: int=0
var _error: String=""
var _rejection: String=""
var _outcome: String=""

func attach(endpoint: Shop3D, dispatcher: UiCommandDispatcher, session: UiCommandSession, tree: SceneTree) -> void:
	_endpoint=endpoint;_dispatcher=dispatcher;_session=session;_tree=tree
	endpoint.vendor_result.connect(session.finish)
	endpoint.state_changed.connect(accept_shop)
	dispatcher.register_command("vendor.open",_empty,func(_p: Dictionary)->Dictionary:return open())
	dispatcher.register_command("vendor.close",_empty,func(_p: Dictionary)->Dictionary:_opened=false;publish();return {"ok":true})
	dispatcher.register_command("vendor.edit",valid_edit,edit)
	dispatcher.register_command("vendor.refresh",_empty,func(_p: Dictionary)->Dictionary:return await refresh())
	dispatcher.register_command("vendor.confirm",_empty,func(_p: Dictionary)->Dictionary:return await confirm())
	dispatcher.register_command("vendor.recover",_empty,func(_p: Dictionary)->Dictionary:return await recover())
	publish()

static func _empty(p: Dictionary) -> bool: return p.is_empty()
static func valid_edit(p: Dictionary) -> bool:
	return p.size()==2 and p.get("id") is String and ItemInstance.valid_uid(p.id) and WebUiBridge.is_integer(p.get("amount")) and p.amount>=0 and p.amount<=200

static func valid_intent(p: Dictionary) -> bool:
	return p.size()==4 and NpcUiAdapter.valid_service({"npc_instance_id":p.get("npc_instance_id"),"service_id":p.get("service_id")}) and p.get("quote_id") is String and ItemInstance.valid_uid(p.quote_id) and not _restore_items(p.get("items")).is_empty()

static func _restore_items(values: Variant) -> Array:
	if not values is Array: return []
	var lines: Array=[]
	for value: Variant in values:
		if not value is Dictionary or value.size()!=3 or not value.get("revision") is String or not value.get("amount") is String or not value.revision.is_valid_int() or not value.amount.is_valid_int(): return []
		lines.append({"uid":value.get("uid"),"revision":int(value.revision),"amount":int(value.amount)})
	return VendorResolver.cart(lines)

func accept_inventory(snapshot: Dictionary) -> void:
	if _disposed: return
	_owned.clear()
	if not snapshot.get("ok",false): _quote.clear();_serial+=1;publish();return
	var context: Dictionary=snapshot.get("economic_context",{})
	if context!=_context:
		if not _context.is_empty(): _ready=false;_quote.clear();publish();return
		_context=context.duplicate(true)
		var restored: Dictionary=journal.configure(context)
		_ready=restored.ok and (restored.entry.is_empty() or valid_intent(restored.entry.payload))
		if not _ready: _error="journal_unavailable"
		if _ready and not restored.entry.is_empty():
			_intent=restored.entry.duplicate(true)
			_basket=_restore_items(_intent.payload.items)
			_npc={"npc_instance_id":_intent.payload.npc_instance_id,"service_id":_intent.payload.service_id}
			_opened=true;shown.emit()
			recover.call_deferred()
	for item: Dictionary in snapshot.get("items",[]):
		if item.get("location","")=="bag": _owned[str(item.uid)]=item.duplicate(true)
	if not _selection_current(): _quote.clear();_serial+=1
	publish()

func accept_shop(snapshot: Dictionary) -> void:
	if _disposed: return
	if snapshot.get("active",false):
		var next: Dictionary={"npc_instance_id":snapshot.npcInstanceId,"service_id":snapshot.serviceId}
		if _intent.is_empty() and next!=_npc:
			_npc=next;_basket.clear();_quote.clear();_quoting=false;_error="";_outcome="";_serial+=1
	elif _intent.is_empty():
		_opened=false;_basket.clear();_quote.clear();_quoting=false;_serial+=1
	publish()

func open() -> Dictionary:
	if not _intent.is_empty(): _opened=true;shown.emit();publish();return {"ok":true}
	if not _endpoint.state.get("active",false): return {"ok":false,"error":"no_interaction"}
	accept_shop(_endpoint.state);_opened=true;shown.emit();publish();return {"ok":true}

func _selection_current() -> bool:
	for line: Dictionary in _basket:
		var item: Dictionary=_owned.get(line.uid,{})
		if item.is_empty() or item.revision!=line.revision or item.amount<line.amount: return false
	return true

func edit(p: Dictionary) -> Dictionary:
	if not _ready or not _opened or not _intent.is_empty() or _busy: return {"ok":false,"error":"sale_pending"}
	var next:=_basket.filter(func(line: Dictionary)->bool:return line.uid!=p.id)
	if int(p.amount)>0:
		var item: Dictionary=_owned.get(p.id,{})
		if item.is_empty() or item.amount<int(p.amount): return {"ok":false,"error":"unavailable"}
		next.append({"uid":p.id,"revision":int(item.revision),"amount":int(p.amount)})
	if not next.is_empty() and VendorResolver.cart(next).is_empty(): return {"ok":false,"error":"basket_limit"}
	_basket=next;_quote.clear();_quoting=false;_error="";_outcome="";_serial+=1;publish()
	_debounce.call_deferred(_serial)
	return {"ok":true}

func _debounce(serial: int) -> void:
	await _tree.create_timer(0.2).timeout
	if not _disposed and serial==_serial and not _basket.is_empty(): await refresh()

func _request(action: String, payload: Dictionary, npc: Dictionary) -> Dictionary:
	var id:=_session.begin()
	if id.is_empty(): return _session.closed_result()
	_endpoint.request_vendor.rpc_id(1,action,npc.get("npc_instance_id",""),npc.get("service_id",""),payload,id)
	return await _session.wait(id,_tree)

func refresh() -> Dictionary:
	if _disposed or not _ready or not _opened or _busy or _quoting or not _intent.is_empty() or _basket.is_empty(): return {"ok":false,"error":"unavailable"}
	if not _selection_current(): _error="stale";publish();return {"ok":false,"error":"stale"}
	var serial:=_serial
	_quoting=true;_quote.clear();publish()
	var result:=await _request("quote",{"items":_basket.duplicate(true)},_npc)
	if _disposed or serial!=_serial: return result
	_quoting=false
	if result.get("ok",false): _quote=result.duplicate(true);_error=""
	else: _error=str(result.get("error","storage"))
	publish();return result

func _release() -> bool:
	if not journal.clear_pending(_intent.id): _error="journal_unavailable";publish();return false
	_intent.clear();return true

func confirm() -> Dictionary:
	if _disposed or not _ready: return {"ok":false,"error":"journal_unavailable"}
	if _busy or not _intent.is_empty(): return {"ok":false,"error":"sale_pending"}
	if _quote.is_empty() or not _selection_current() or int(Time.get_unix_time_from_system())>=int(_quote.expires_at): return {"ok":false,"error":"quote_expired"}
	var payload: Dictionary={"npc_instance_id":_npc.npc_instance_id,"service_id":_npc.service_id,"quote_id":_quote.quote_id,"items":_basket.map(func(line: Dictionary)->Dictionary:return {"uid":line.uid,"revision":str(line.revision),"amount":str(line.amount)})}
	var id: String="npc-sell-"+Crypto.new().generate_random_bytes(16).hex_encode()
	if not journal.save_pending(id,payload): _ready=false;_error="journal_unavailable";publish();return {"ok":false,"error":_error}
	_intent={"id":id,"payload":payload};_busy=true;_serial+=1;_quoting=false;publish()
	var result:=await _request("sell",{"quote_id":payload.quote_id,"command_id":id},_npc)
	if _disposed: return result
	_busy=false;_quote.clear()
	if result.get("ok",false): return _success(result)
	# Even a pre-store authorization failure on a later attempt cannot disprove
	# an earlier commit. Read the receipt before releasing this economic identity.
	_rejection=str(result.get("error","storage"));_error="sale_pending";publish();return {"ok":false,"error":_error}

func _success(result: Dictionary) -> Dictionary:
	if not _release(): return {"ok":false,"error":"journal_unavailable"}
	_basket.clear();_quote.clear();_error=""
	_outcome="Sold for %s Yang." % str(result.get("yang","0"))
	var counts: Dictionary={}
	for reward: Dictionary in result.get("rewards",[]):
		var key: String=str(reward.get("definition_id",""))
		counts[key]=int(counts.get(key,0))+int(reward.get("amount",1))
	for key: String in counts:
		var definition:=ItemDefinitions.get_definition(StringName(key))
		_outcome+=" Received %s ×%d." % [definition.item_name if definition!=null else "item",int(counts[key])]
	publish();return {"ok":true}

func recover() -> Dictionary:
	if _disposed or not _ready or _busy or _intent.is_empty(): return {"ok":false,"error":"unavailable"}
	_busy=true;publish()
	var result:=await _request("receipt",{"command_id":_intent.id},{})
	if _disposed: return result
	_busy=false
	if result.get("ok",false): return _success(result)
	if result.get("error","")=="unknown_command":
		if not _release(): return {"ok":false,"error":"journal_unavailable"}
		_quote.clear();_error=_rejection if _rejection in ["overflow","inventory_full","unsellable","stale","quote_expired","quote_stale","out_of_range","no_interaction"] else "not_committed" # Explicit fresh quote/confirmation only.
	else: _error="sale_pending"
	publish();return {"ok":false,"error":_error}

func is_open() -> bool: return _opened

func tick(_delta: float) -> void:
	if not _quote.is_empty() and int(Time.get_unix_time_from_system())>=int(_quote.expires_at):
		_quote.clear();_error="quote_expired";publish()

func publish() -> void:
	if _disposed or not is_instance_valid(_dispatcher): return
	var items: Array=[]
	for line: Dictionary in _basket:
		var raw: Dictionary=_owned.get(line.uid,{})
		var model: Dictionary=ItemUiAdapter.item_model(raw) if not raw.is_empty() else {"id":line.uid,"revision":line.revision,"name":"Pending item","icon_id":"","height":1,"quantity":line.amount}
		model.quantity=line.amount
		model["available"]=not raw.is_empty() and raw.revision==line.revision and raw.amount>=line.amount
		model["maximum"]=mini(200,int(raw.get("amount",line.amount)))
		items.append(model)
	_dispatcher.set_domain("vendor",{"active":_opened,"ready":_ready,"busy":_busy,"quoting":_quoting,"pending":not _intent.is_empty(),"items":items,"quote":{} if _quote.is_empty() else {"yang":str(_quote.yang),"rewards":_quote.rewards,"expires_at":_quote.expires_at},"error":_error,"outcome":_outcome})

func dispose() -> void:
	_disposed=true;_serial+=1
	if is_instance_valid(_endpoint):
		if _endpoint.vendor_result.is_connected(_session.finish): _endpoint.vendor_result.disconnect(_session.finish)
		if _endpoint.state_changed.is_connected(accept_shop): _endpoint.state_changed.disconnect(accept_shop)
