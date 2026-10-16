class_name EconomyCommandSqlite
extends RefCounted
## Explicit SQLite command boundary shared by composition, not a database interface.
## Caller writes domain data between begin and commit on this same connection.
var db: SQLite
var account_id := 0
var _character_id := 0
var _command := ""
var _kind := ""
var _request := ""
var cached: Dictionary = {}
var committed := false
# Last native COMMIT wall time, separate from validation/receipt work. Diagnostic
# only; never included in receipts or used to decide transaction success.
var commit_usec := 0
var rejected: MarketRejectedCommands
func _init(database: SQLite, rejected_commands: MarketRejectedCommands = null) -> void:
	db = database
	rejected = rejected_commands if rejected_commands!=null else MarketRejectedCommands.new()

func rollback(error: String) -> Dictionary:
	db.query("ROLLBACK;")
	return {"ok":false,"error":error}

func begin(character_id: int, command_id: String, kind: String, args: Array) -> bool:
	committed = false
	commit_usec = 0
	cached = {}
	var valid_command := not command_id.is_empty() and command_id.length()<=96
	for character: String in command_id:
		if not "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-:".contains(character): valid_command = false
	if not valid_command:
		cached = {"ok":false,"error":"request"}
		return false
	if not db.query("BEGIN IMMEDIATE;"):
		cached = {"ok":false,"error":"storage"}
		return false
	account_id = WorldStoreSqlite.new(db).resolve_account_id(character_id)
	if account_id <= 0:
		cached = rollback("owner")
		return false
	_character_id = character_id
	_command = command_id
	_kind = kind
	_request = JSON.stringify(args)
	if not db.query_with_bindings("SELECT kind,request_json,result_json FROM market_commands WHERE account_id=? AND command_id=?;",[account_id,_command]):
		cached = rollback("storage")
		return false
	if not db.query_result.is_empty():
		var row: Dictionary = db.query_result[0]
		cached = decode_result(row.result_json) if row.kind==kind and row.request_json==_request else {"ok":false,"error":"command_conflict"}
		for field: String in ["revision","position","shop_id","price","balance"]:
			if cached.has(field): cached[field] = int(cached[field])
		db.query("ROLLBACK;")
		return false
	cached = rejected.lookup(account_id,_command,_kind,_request)
	if not cached.is_empty():
		db.query("ROLLBACK;")
		return false
	return true

func commit(result: Dictionary) -> Dictionary:
	if not result.ok:
		# Validation may have made provisional writes; none survive a rejection.
		if not db.query("ROLLBACK;"): return {"ok":false,"error":"storage"}
		rejected.remember(account_id,_command,_kind,_request,result)
		return result
	# Capture the watermark before receipt+COMMIT, never reconstruct it on replay.
	result = result.duplicate(true)
	result["item_state"] = preload("res://source/server/world/database/item_state_revision_sqlite.gd").read(db,_character_id)
	if result.item_state.is_empty(): return rollback("storage")
	if not db.query_with_bindings("INSERT INTO market_commands(account_id,command_id,kind,request_json,result_json) VALUES(?,?,?,?,?);",[account_id,_command,_kind,_request,_encode_result(result)]): return rollback("storage")
	var started := Time.get_ticks_usec()
	var success := db.query("COMMIT;")
	commit_usec = Time.get_ticks_usec() - started
	if not success: return rollback("storage")
	committed = true
	return result

func receipt(character_id: int, command_id: String) -> Dictionary:
	var receipt_account := WorldStoreSqlite.new(db).resolve_account_id(character_id)
	if receipt_account <= 0: return {"ok":false,"error":"owner"}
	if not db.query_with_bindings("SELECT result_json FROM market_commands WHERE account_id=? AND command_id=?;",[receipt_account,command_id]): return {"ok":false,"error":"storage"}
	if db.query_result.is_empty():
		var cached:=rejected.receipt(receipt_account,command_id)
		return cached if not cached.is_empty() else {"ok":false,"error":"unknown_command"}
	return decode_result(db.query_result[0].result_json)

# JSON numbers are floats in Godot. Decimal strings preserve the full integer
# watermark in durable receipts; native RPCs and application results remain ints.
static func _encode_result(result: Dictionary) -> String:
	var stored := result.duplicate(true)
	if stored.has("claimed"): stored.claimed=str(stored.claimed)
	if stored.has("item_state"):
		for field: String in ["account_id","character_id","revision"]: stored.item_state[field]=str(stored.item_state[field])
	for state: Dictionary in stored.get("wallet_states",[]):
		for field: String in ["account_id","revision","balance","reserved_yang","pending_applied"]: state[field]=str(state[field])
	return JSON.stringify(stored)

static func decode_result(json: String) -> Dictionary:
	var result: Variant = JSON.parse_string(json)
	if not result is Dictionary: return {"ok":false,"error":"storage"}
	if result.has("claimed"):
		if not result.claimed is String or not result.claimed.is_valid_int(): return {"ok":false,"error":"storage"}
		result.claimed=int(result.claimed)
	if result.has("item_state"):
		if not result.item_state is Dictionary: return {"ok":false,"error":"storage"}
		for field: String in ["account_id","character_id","revision"]:
			var value: Variant = result.item_state.get(field)
			if not value is String or not value.is_valid_int(): return {"ok":false,"error":"storage"}
			result.item_state[field]=int(value)
	if result.has("wallet_states") and not result.wallet_states is Array: return {"ok":false,"error":"storage"}
	for state: Variant in result.get("wallet_states",[]):
		if not state is Dictionary: return {"ok":false,"error":"storage"}
		if not state.has("revision"): continue # Pre-feature receipt.
		for field: String in ["account_id","revision","balance","reserved_yang","pending_applied"]:
			var value: Variant = state.get(field)
			if not value is String or not value.is_valid_int(): return {"ok":false,"error":"storage"}
			state[field]=int(value)
	return result
