extends RefCounted
const Contract = preload("res://source/common/gameplay/trade/player_trade_contract.gd")
const Journal = preload("res://source/client/ui_web/local_economy_journal.gd")
var journal=Journal.new("trade-","user://pending_player_trades")
var _endpoint: Node
var _dispatcher: UiCommandDispatcher
var _session: UiCommandSession
var _tree: SceneTree
var _opened:=false
var _scope: Dictionary={}
var _intent: Dictionary={}
var _journal_ready:=false
var _error: String=""
func attach(endpoint: Node, dispatcher: UiCommandDispatcher, session: UiCommandSession, tree: SceneTree) -> void:
	_endpoint=endpoint;_dispatcher=dispatcher;_session=session;_tree=tree
	dispatcher.register_command("trade.command",_valid_ui,_submit)
	dispatcher.register_command("trade.close",func(p: Dictionary)->bool:return p.is_empty(),func(_p: Dictionary)->Dictionary:_opened=false;publish(endpoint.state);return {"ok":true})
	endpoint.state_changed.connect(publish)
	endpoint.operation_finished.connect(session.finish)
	publish(endpoint.state)
static func _normalize(p: Dictionary) -> Dictionary:
	var value:=p.duplicate(true)
	for key: String in ["target","version"]:
		if value.has(key) and WebUiBridge.is_integer(value[key]): value[key]=int(value[key])
	return value
static func _valid_ui(p: Dictionary) -> bool: return Contract.valid(_normalize(p))
func accept_inventory(snapshot: Dictionary) -> void:
	var scope: Dictionary=snapshot.get("item_state",{})
	var identity: Dictionary={}
	for key: String in ["authority_id","account_id","character_id"]: identity[key]=scope.get(key)
	if identity==_scope: return
	_scope=identity;_intent={}
	var restored: Dictionary=journal.configure(identity)
	_journal_ready=restored.ok
	if restored.ok and not restored.entry.is_empty():
		_intent=restored.entry;_opened=true
		_recover.call_deferred()
	publish(_endpoint.state)
func _recover() -> void:
	if not _intent.is_empty(): await _submit({"action":"recover","trade_id":_intent.id})
func publish(snapshot: Dictionary) -> void:
	if snapshot.is_empty(): return
	if snapshot.get("id","")!=_endpoint.get_meta("last_trade_id","") and snapshot.get("phase","") in ["invited","offer"]: _opened=true
	_endpoint.set_meta("last_trade_id",snapshot.get("id",""))
	if not _intent.is_empty() and snapshot.get("id","")==_intent.id and snapshot.get("phase","") not in ["invited","offer","settling","paused","reconcile","unavailable"]:
		if journal.clear_pending(_intent.id): _intent={};_error=""
		else: _error="journal_unavailable"
	var value:=snapshot.duplicate(true)
	for offer: Dictionary in value.get("offers",[]):
		for item: Dictionary in offer.items:
			item.tooltip=ItemUiAdapter.tooltip_details(item.get("details",{}));item.erase("details")
	value.opened=_opened;value.pending=not _intent.is_empty();value.recover_id=_intent.get("id","");value.client_error=_error
	_dispatcher.set_domain("trade",value)
func toggle() -> void: _opened=not _opened;publish(_endpoint.state)
func _submit(raw: Dictionary) -> Dictionary:
	var payload:=_normalize(raw)
	if not Contract.valid(payload): return {"ok":false,"error":"payload"}
	if payload.action=="invite" and not _intent.is_empty(): return {"ok":false,"error":"recovery_required"}
	if payload.action=="confirm":
		if not _journal_ready: return {"ok":false,"error":"journal_unavailable"}
		if not _intent.is_empty() and _intent.id!=payload.trade_id: return {"ok":false,"error":"recovery_required"}
		if _intent.is_empty():
			if not journal.save_pending(payload.trade_id,{"trade_id":payload.trade_id}): return {"ok":false,"error":"journal_unavailable"}
			_intent={"id":payload.trade_id,"payload":{"trade_id":payload.trade_id}}
	var id: String=_session.begin()
	if id.is_empty(): return _session.closed_result()
	_endpoint.request.rpc_id(1,id,payload)
	var result: Dictionary=await _session.wait(id,_tree)
	if not result.get("ok",false): _error=str(result.get("error","request"))
	publish(_endpoint.state)
	return result
func dispose() -> void:
	if not is_instance_valid(_endpoint): return
	if _endpoint.state_changed.is_connected(publish): _endpoint.state_changed.disconnect(publish)
	if _endpoint.operation_finished.is_connected(_session.finish): _endpoint.operation_finished.disconnect(_session.finish)
