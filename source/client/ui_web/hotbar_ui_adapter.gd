extends RefCounted
## Character-local preferences and presentation; activation reuses Inventory receipts.
var bindings := HotbarBindings.new()
var directory := "user://hotbar_bindings"
var activate_item: Callable
var _dispatcher: UiCommandDispatcher
var _context: Dictionary={}
var _path := ""
var _owned: Dictionary={}
var _presented: Dictionary={}
var _vitals: Dictionary={"ready":false,"hp":0,"max_hp":0,"mp":0.0,"max_mp":0.0,"level":"1"}
var _ready := false
var _busy := false
var _disposed := false
var _error := ""

func attach(dispatcher: UiCommandDispatcher, activate: Callable) -> void:
	_dispatcher=dispatcher;activate_item=activate
	dispatcher.register_command("hotbar.assign",func(p: Dictionary)->bool:return valid_slot(p,2) and p.get("id") is String and ItemInstance.valid_uid(p.id),_assign)
	dispatcher.register_command("hotbar.clear",func(p: Dictionary)->bool:return valid_slot(p,1),_clear)
	dispatcher.register_command("hotbar.activate",func(p: Dictionary)->bool:return valid_slot(p,1),func(p: Dictionary)->Dictionary:return await activate_slot(int(p.slot)))
	publish()

static func valid_slot(p: Dictionary, size: int) -> bool:
	return p.size()==size and WebUiBridge.is_integer(p.get("slot")) and p.slot>=0 and p.slot<HotbarBindings.SLOT_COUNT

func accept_inventory(snapshot: Dictionary) -> void:
	if _disposed: return
	if not snapshot.get("ok",false):
		_owned.clear();_error="inventory_unavailable";publish();return
	var context: Dictionary=snapshot.get("economic_context",{})
	if context!=_context:
		_ready=false;_owned.clear();bindings=HotbarBindings.new();_context=context.duplicate(true)
		if ItemInstance.valid_uid(str(context.get("authority_id",""))) and int(context.get("account_id",0))>0 and int(context.get("character_id",0))>0:
			var scope: String=("%s:%d:%d" % [context.authority_id,int(context.account_id),int(context.character_id)]).sha256_text()
			_path=ProjectSettings.globalize_path(directory).path_join(scope+".json")
			_ready=DirAccess.make_dir_recursive_absolute(_path.get_base_dir())==OK
			if _ready and FileAccess.file_exists(_path):
				var file:=FileAccess.open(_path,FileAccess.READ)
				if file==null or file.get_length()>8192: _ready=false
				else:
					var parser:=JSON.new()
					_ready=parser.parse(file.get_as_text())==OK
					if _ready: _ready=parser.data is Array and bindings.load_bindings(parser.data)
		_error="" if _ready else "preferences"
	if _ready and _error=="inventory_unavailable": _error=""
	_owned.clear();_presented.clear()
	for item: Dictionary in snapshot.get("items",[]):
		var model: Dictionary=ItemUiAdapter.item_model(item)
		_presented[str(item.uid)]=model
		if item.get("location","")=="bag": _owned[str(item.uid)]=model
	for item: Dictionary in snapshot.get("storage",{}).get("items",[]):
		_presented[str(item.uid)]=ItemUiAdapter.item_model(item)
	publish()

func _save() -> bool:
	if not _ready: return false
	var file:=FileAccess.open(_path+".tmp",FileAccess.WRITE)
	if file==null: return false
	file.store_string(JSON.stringify(bindings.snapshot()));file.flush()
	var ok: bool=file.get_error()==OK
	file.close()
	return ok and DirAccess.rename_absolute(_path+".tmp",_path)==OK

func _assign(p: Dictionary) -> Dictionary:
	if _disposed or not _ready or not _owned.has(p.id): return {"ok":false,"error":"unavailable"}
	return _change(int(p.slot),str(p.id))

func _clear(p: Dictionary) -> Dictionary:
	if _disposed or not _ready: return {"ok":false,"error":"unavailable"}
	return _change(int(p.slot),"")

func _change(slot: int, uid: String) -> Dictionary:
	var before: Array=bindings.snapshot()
	if uid.is_empty(): bindings.clear(slot)
	else: bindings.assign_item(slot,uid)
	var saved: bool=_save()
	if not saved: bindings.load_bindings(before)
	_error="" if saved else "preferences"
	publish();return {"ok":saved,"error":_error}

func activate_slot(slot: int) -> Dictionary:
	if _disposed or not _ready or _busy: return {"ok":false,"error":"unavailable"}
	var binding: Dictionary=bindings.resolve(slot,_owned,{})
	if binding.is_empty(): return {"ok":false,"error":"unavailable"}
	var item: Dictionary=_owned[binding.id]
	_busy=true;_error="";publish()
	# Current revision, never a revision stored with the preference or supplied by JS.
	var result: Dictionary=await activate_item.call({"id":binding.id,"revision":int(item.revision)})
	if _disposed: return result
	_busy=false;_error="" if result.ok else str(result.get("error","request"));publish()
	return {"ok":bool(result.ok),"error":_error}

func accept_combat(snapshot: Dictionary, peer: int) -> void:
	if _disposed: return
	var health: Dictionary=snapshot.get("health",{})
	var next: Dictionary={"ready":health.has(peer),"hp":maxi(0,int(health.get(peer,0))),"max_hp":maxi(0,int(snapshot.get("max_health",{}).get(peer,0))),"mp":maxf(0,float(snapshot.get("vitals",{}).get("mana",0))),"max_mp":maxf(0,float(snapshot.get("vitals",{}).get("max_mana",0))),"level":str(int(snapshot.get("progression",{}).get("level",1)))}
	if next!=_vitals: _vitals=next;publish()

func publish() -> void:
	if _disposed or not is_instance_valid(_dispatcher): return
	var slots: Array=[]
	for i: int in HotbarBindings.SLOT_COUNT:
		var binding: Dictionary=bindings.binding(i)
		if binding.is_empty(): slots.append({});continue
		var item: Dictionary=_presented.get(binding.id,{})
		slots.append({"id":str(binding.id),"name":str(item.get("name","Unavailable item")),"icon_id":str(item.get("icon_id","")),"quantity":int(item.get("quantity",0)),"available":_owned.has(binding.id)})
	_dispatcher.set_domain("hotbar",{"slots":slots,"vitals":_vitals.duplicate(true),"busy":_busy,"ready":_ready,"error":_error})

func dispose() -> void:
	_disposed=true
