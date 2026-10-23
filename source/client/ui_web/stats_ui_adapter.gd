extends RefCounted
## Presentation and durable client intent only. World owns all stat decisions.
const Journal = preload("res://source/client/ui_web/local_economy_journal.gd")
var journal = Journal.new("stats-", "user://pending_stats")
var request: Callable = func(type: StringName, payload: Dictionary) -> Array: return await Client.request_data_await(type,payload)
var _dispatcher: UiCommandDispatcher
var _context: Dictionary = {}
var _pending: Dictionary = {}
var _stats: Dictionary = {}
var _vitals: Dictionary = {}
var opened := false
var _ready := false
var _busy := false
var _loading := false
var _disposed := false
var _serial := 0
var _elapsed := 0.0
var _error := ""

func attach(dispatcher: UiCommandDispatcher) -> void:
	_dispatcher=dispatcher
	dispatcher.register_command("stats.spend",valid_spend,_spend)
	dispatcher.register_command("stats.retry",func(p: Dictionary)->bool:return p.is_empty(),func(_p: Dictionary)->Dictionary:return await retry())
	dispatcher.register_command("stats.refresh",func(p: Dictionary)->bool:return p.is_empty(),func(_p: Dictionary)->Dictionary:await refresh();return {"ok":_error.is_empty(),"error":_error})
	dispatcher.register_command("stats.close",func(p: Dictionary)->bool:return p.is_empty(),func(_p: Dictionary)->Dictionary:opened=false;publish();return {"ok":true})
	publish()

static func valid_spend(p: Dictionary) -> bool:
	return p.size()==1 and p.get("attribute") is String and p.attribute in ["STR","DEX","VIT","INT"]

func accept_context(snapshot: Dictionary) -> void:
	if _disposed or not snapshot.get("ok",false): return
	var context: Dictionary=snapshot.get("economic_context",{})
	if context.is_empty() or context==_context: return
	if not _context.is_empty():
		_ready=false;_serial+=1;_stats.clear();_error="session";publish();return
	_context=context.duplicate(true)
	var restored: Dictionary=journal.configure(context)
	_ready=restored.ok and (restored.entry.is_empty() or valid_spend(restored.entry.payload))
	if _ready: _pending=restored.entry.duplicate(true)
	else: _error="journal"
	publish()
	if opened: refresh()

func toggle() -> void:
	opened=not opened;publish()
	if opened: refresh()

func tick(delta: float) -> void:
	if not opened or _disposed: return
	_elapsed+=delta
	if _elapsed>=1.0:
		_elapsed=0;refresh()

func accept_vitals(snapshot: Dictionary) -> void:
	var peer: int=Client.get_multiplayer().get_unique_id() if Client.get_multiplayer().has_multiplayer_peer() else 0
	var health: Dictionary=snapshot.get("health",{})
	var next: Dictionary={"hp":int(health.get(peer,0)),"mp":float(snapshot.get("vitals",{}).get("mana",0))}
	if next==_vitals: return
	_vitals=next
	if opened: publish()

func refresh() -> void:
	if _disposed or not _ready or _busy or _loading: return
	_loading=true
	var serial: int=_serial
	var response: Array=await request.call(&"attribute.get",{})
	_loading=false
	if _disposed or serial!=_serial: return
	if response[1]==DataRequest.Error.OK and response[0].get("ok",false):
		_stats=response[0].stats.duplicate(true);_error=""
	else: _error=str(response[0].get("error","timeout"))
	publish()

func _spend(payload: Dictionary) -> Dictionary:
	if _disposed or not _ready: return {"ok":false,"error":"unavailable"}
	if _busy: return {"ok":false,"error":"busy"}
	if not _pending.is_empty(): return {"ok":false,"error":"stats_pending"}
	var id: String="stats-"+Crypto.new().generate_random_bytes(16).hex_encode()
	if not journal.save_pending(id,payload): return {"ok":false,"error":"journal"}
	_pending={"id":id,"payload":payload.duplicate(true)}
	return await retry()

func retry() -> Dictionary:
	if _disposed or not _ready or _busy or _pending.is_empty(): return {"ok":false,"error":"unavailable"}
	_busy=true;_serial+=1;_error="";publish()
	var payload: Dictionary=_pending.payload.duplicate(true);payload.command_id=_pending.id
	var serial: int=_serial
	var response: Array=await request.call(&"attribute.spend",payload)
	if _disposed or serial!=_serial: return {"ok":false,"error":"teardown"}
	_busy=false
	var result: Dictionary=response[0]
	var terminal: bool=response[1]==DataRequest.Error.OK and (result.get("ok",false) or result.get("error","") in ["points","stale","payload","command_conflict"])
	if terminal:
		if result.get("ok",false): _stats=result.stats.duplicate(true)
		if journal.clear_pending(_pending.id): _pending.clear()
		else: _error="journal"
	if not result.get("ok",false): _error=str(result.get("error","timeout"))
	publish()
	return {"ok":terminal and result.get("ok",false) and _error.is_empty(),"error":_error}

func publish() -> void:
	if _disposed or not is_instance_valid(_dispatcher): return
	# Decimal strings preserve counters above JavaScript's safe integer range.
	var value: Dictionary={"opened":opened,"ready":not _stats.is_empty(),"busy":_busy,"pending":not _pending.is_empty(),"pending_attribute":str(_pending.get("payload",{}).get("attribute","")),"error":_error,"vitals":_vitals.duplicate(true)}
	if not _stats.is_empty():
		var data: Dictionary=_stats.duplicate(true)
		for key: String in ["revision","available_points","available_skill_points","level","experience","xp_to_next"]: data[key]=str(int(data[key]))
		for key: String in ["STR","DEX","VIT","INT"]: data.attributes[key]=str(int(data.attributes.get(key,0)))
		data.xp_fraction=clampf(float(_stats.experience)/maxf(1,float(_stats.xp_to_next)),0,1)
		value.data=data
	_dispatcher.set_domain("stats",value)

func dispose() -> void:
	_disposed=true;_serial+=1
