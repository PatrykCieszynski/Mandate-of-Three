extends RefCounted
## Validated immutable startup budgets. Credentials and gameplay rules stay elsewhere.
const DEFAULTS: Dictionary={"version":1,"inventory_bindings":64,"wallet_accounts":64,"master_grants":64,"handoff_tickets":1024,"handoff_ttl_ms":30000,"handoff_ack_timeout_ms":2000}
var _limits: Dictionary

func _init(limits: Dictionary) -> void:
	_limits=limits.duplicate(true)
	_limits.make_read_only()

func value(key: String) -> int: return _limits[key]

static func load_config(path: String, role: String) -> Dictionary:
	var config:=ConfigFile.new()
	if config.load(path)!=OK: return {"ok":false,"error":"runtime_config"}
	var raw: Dictionary={}
	for key: String in config.get_section_keys("runtime") if config.has_section("runtime") else PackedStringArray():
		raw[key]=config.get_value("runtime",key)
	return resolve(raw,config.get_value("world-server","max_players",64) if role=="world" else 64)

static func resolve(raw: Dictionary, sessions: Variant = 64) -> Dictionary:
	var limits:=DEFAULTS.duplicate()
	for key: Variant in raw:
		if not DEFAULTS.has(key): return {"ok":false,"error":"unknown_runtime_key:"+str(key)}
		limits[key]=raw[key]
	limits.world_sessions=sessions
	for key: String in limits:
		if not limits[key] is int: return {"ok":false,"error":"runtime_integer:"+key}
		var maximum: int=300000 if key=="handoff_ttl_ms" else 30000 if key=="handoff_ack_timeout_ms" else 65536
		var minimum: int=1000 if key=="handoff_ttl_ms" else 100 if key=="handoff_ack_timeout_ms" else 1
		if limits[key]<minimum or limits[key]>maximum: return {"ok":false,"error":"runtime_range:"+key}
	if limits.version!=1: return {"ok":false,"error":"runtime_version"}
	if limits.inventory_bindings<sessions or limits.wallet_accounts<sessions: return {"ok":false,"error":"runtime_session_capacity"}
	if limits.handoff_ack_timeout_ms>=limits.handoff_ttl_ms: return {"ok":false,"error":"runtime_ticket_deadline"}
	return {"ok":true,"settings":load("res://source/server/runtime/runtime_capacity_settings.gd").new(limits)}
