extends RefCounted
## Validated immutable runtime limits/ranges. Credentials and reward formulas stay elsewhere.
const DEFAULTS: Dictionary = {
	"version": 1,
	"inventory_bindings": 64,
	"wallet_accounts": 64,
	"master_grants": 64,
	"handoff_tickets": 1024,
	"handoff_ttl_ms": 30000,
	"handoff_ack_timeout_ms": 2000,
	"mob_aoi_enter_radius": 60,
	"mob_aoi_exit_radius": 72,
	"mob_aoi_cell_size": 32,
	"mob_position_interval_ms": 100,
	"party_reward_radius": 40,
	"chat_general_ms": 3000,
	"chat_trade_ms": 20000,
	"chat_light_count": 5,
	"chat_light_window_ms": 5000,
	"chat_flood_count": 12,
	"chat_flood_window_ms": 1000,
	"chat_local_radius": 40,
	"stats_attempts_per_second": 8,
}
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
	if limits.mob_aoi_exit_radius < limits.mob_aoi_enter_radius: return {"ok":false,"error":"runtime_mob_aoi_radius"}
	if limits.mob_position_interval_ms < 50 or limits.mob_position_interval_ms > 2000: return {"ok":false,"error":"runtime_mob_position_interval"}
	if limits.version!=1: return {"ok":false,"error":"runtime_version"}
	if limits.inventory_bindings<sessions or limits.wallet_accounts<sessions: return {"ok":false,"error":"runtime_session_capacity"}
	if limits.handoff_ack_timeout_ms>=limits.handoff_ttl_ms: return {"ok":false,"error":"runtime_ticket_deadline"}
	return {"ok":true,"settings":load("res://source/server/runtime/runtime_capacity_settings.gd").new(limits)}
