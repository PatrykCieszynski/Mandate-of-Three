extends RefCounted
## Consumable selection is presentation. The server rereads both UID revisions.
const Rules=preload("res://source/common/gameplay/items/crafting/crafting_rules.gd")
const Journal=preload("res://source/client/ui_web/local_economy_journal.gd")
var journal=Journal.new("craft-","user://pending_crafting")
var _endpoint: InventoryEndpoint3D
var _dispatcher: UiCommandDispatcher
var _session: UiCommandSession
var _tree: SceneTree
var _context: Dictionary={}
var _inventory: Dictionary={}
var _intent: Dictionary={}
var _currency: Dictionary={}
var _ready:=false
var _busy:=false
var _opened:=false
var _disposed:=false
func attach(endpoint: InventoryEndpoint3D, dispatcher: UiCommandDispatcher, session: UiCommandSession, tree: SceneTree) -> void:
	_endpoint=endpoint;_dispatcher=dispatcher;_session=session;_tree=tree
	dispatcher.register_command("craft.execute",ItemUiAdapter.valid_equipment,_execute)
	dispatcher.register_command("craft.retry",func(p: Dictionary)->bool:return p.is_empty(),func(_p: Dictionary)->Dictionary:return await _retry(true))
	dispatcher.register_command("craft.close",func(p: Dictionary)->bool:return p.is_empty(),func(_p: Dictionary)->Dictionary:_opened=false;publish();return {"ok":true})
	endpoint.state_changed.connect(accept_inventory)
	accept_inventory(endpoint.state)
func dispose() -> void:
	_disposed=true
	if is_instance_valid(_endpoint) and _endpoint.state_changed.is_connected(accept_inventory): _endpoint.state_changed.disconnect(accept_inventory)
func open(payload: Dictionary) -> void:
	for item: Dictionary in _inventory.get("items",[]):
		if item.uid==payload.id and item.revision==payload.revision and Rules.CURRENCIES.has(str(item.definition_id)):
			_currency=item.duplicate(true);_opened=true;publish();return
func accept_inventory(snapshot: Dictionary) -> void:
	if _disposed or not snapshot.get("ok",false): return
	_inventory=snapshot.duplicate(true)
	var context: Dictionary=snapshot.get("economic_context",{})
	if not context.is_empty() and _context.is_empty():
		_context=context.duplicate(true)
		var restored: Dictionary=journal.configure(context)
		_ready=restored.ok
		if _ready and not restored.entry.is_empty():
			var saved: Dictionary=restored.entry.payload
			if saved.size()!=4 or not ItemInstance.valid_uid(str(saved.get("uid",""))) or not ItemInstance.valid_uid(str(saved.get("currency_uid",""))) or not WebUiBridge.is_integer(saved.get("revision")) or not WebUiBridge.is_integer(saved.get("currency_revision")) or saved.revision<0 or saved.currency_revision<0:
				_ready=false;return
			saved.revision=int(saved.revision);saved.currency_revision=int(saved.currency_revision)
		if _ready and not restored.entry.is_empty():
			_intent=restored.entry.duplicate(true);_opened=true
			_retry.call_deferred(false)
	elif not context.is_empty() and context!=_context: _ready=false
	if not _currency.is_empty():
		var current: Array=_inventory.get("items",[]).filter(func(i: Dictionary)->bool:return i.uid==_currency.uid)
		_currency={} if current.is_empty() else current[0].duplicate(true)
	publish()
func publish() -> void:
	if _disposed: return
	var targets: Array=[]
	for item: Dictionary in _inventory.get("items",[]):
		var definition:=ItemDefinitions.get_definition(StringName(item.definition_id))
		if item.location=="bag" and definition!=null and not definition.affix_family.is_empty(): targets.append(ItemUiAdapter.item_model(item))
	var currency: String=str(_currency.get("definition_id",""))
	_dispatcher.set_domain("craft",{"active":_opened,"pending":not _intent.is_empty(),"busy":_busy,"currency":ItemUiAdapter.item_model(_currency) if not _currency.is_empty() else {},"effect":str(Rules.CURRENCIES.get(currency,{}).get("effect","Recover the pending result before crafting again.")),"targets":targets})
func _execute(payload: Dictionary) -> Dictionary:
	if _disposed or not _ready: return {"ok":false,"error":"journal_unavailable"}
	if _busy: return {"ok":false,"error":"too_fast"}
	if not _intent.is_empty(): return {"ok":false,"error":"craft_pending"}
	if _currency.is_empty(): return {"ok":false,"error":"material"}
	var body: Dictionary={"uid":payload.id,"revision":int(payload.revision),"currency_uid":_currency.uid,"currency_revision":int(_currency.revision)}
	var operation: String="craft-"+Crypto.new().generate_random_bytes(16).hex_encode()
	if not journal.save_pending(operation,body): _ready=false;return {"ok":false,"error":"journal_unavailable"}
	_intent={"id":operation,"payload":body}
	return await _send("execute",body)
func _retry(execute_if_absent: bool) -> Dictionary:
	if _disposed or not _ready or _intent.is_empty(): return {"ok":false,"error":"no_pending_craft"}
	if _busy: return {"ok":false,"error":"too_fast"}
	var result:=await _send("receipt",{})
	if result.get("error","")=="unknown_command" and execute_if_absent and not _intent.is_empty(): return await _send("execute",_intent.payload)
	return result
func _send(action: String, body: Dictionary) -> Dictionary:
	var id:=_session.begin()
	if id.is_empty(): return _session.closed_result()
	_busy=true;publish()
	_endpoint.request_craft.rpc_id(1,action,body,id,_intent.id)
	var result:=await _session.wait(id,_tree)
	if _disposed: return result
	_busy=false
	if result.get("ok",false) or (action=="execute" and result.get("error","") in ["request","owner","stale","material","rarity","affix_capacity","unsupported_item","invalid_affixes","insufficient_pool"]):
		if journal.clear_pending(_intent.id): _intent.clear()
		else: result={"ok":false,"error":"journal_unavailable"}
	publish()
	return result
