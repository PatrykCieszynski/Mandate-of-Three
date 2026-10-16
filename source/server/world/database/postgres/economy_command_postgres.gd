extends RefCounted
## PostgreSQL command/receipt ownership, by composition. One native session owns
## read/validate/mutation/receipt/COMMIT; no arbitrary async statement dispatch.
const Codec = preload("res://source/server/world/database/economy_receipt_codec.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
var db: Object
var account_id: int
var character_id: int
var cached: Dictionary={}
var committed:=false
var receipt_replay:=false
var _command: String
var _kind: String
var _request: String

func _init(database: Object) -> void:
	db=database

static func valid_id(value: String) -> bool:
	if value.is_empty() or value.length()>96: return false
	for character: String in value:
		if not "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-:".contains(character): return false
	return true

func begin(owner: int, command: String, kind: String, args: Array) -> bool:
	committed=false
	receipt_replay=false
	cached={}
	if not valid_id(command):
		cached={"ok":false,"error":"request"}
		return false
	if db.in_transaction() or not db.begin():
		cached={"ok":false,"error":"storage"}
		return false
	var result: Dictionary=db.query("SELECT account_id FROM economy.characters WHERE character_id=:id FOR UPDATE;",{"id":owner})
	if not result.ok or result.rows.is_empty():
		cached=rollback("storage" if not result.ok else "owner")
		return false
	account_id=int(result.rows[0].account_id)
	character_id=owner
	_command=command
	_kind=kind
	_request=JSON.stringify(args)
	result=db.query("SELECT kind,request_json,result_json FROM economy.market_commands WHERE account_id=:account AND command_id=:command;",{"account":account_id,"command":_command})
	if not result.ok:
		cached=rollback("storage")
		return false
	if result.rows.is_empty(): return true
	var row: Dictionary=result.rows[0]
	cached=decode(str(row.result_json)) if row.kind==kind and row.request_json==_request else {"ok":false,"error":"command_conflict"}
	receipt_replay=bool(cached.get("ok",false))
	if not db.rollback():
		db.close()
		cached={"ok":false,"error":"storage"}
		receipt_replay=false
	return false

func rollback(error: String) -> Dictionary:
	if not db.rollback():
		db.close()
		return {"ok":false,"error":"storage"}
	return {"ok":false,"error":error}

func commit(result: Dictionary) -> Dictionary:
	if not result.ok: return rollback(str(result.get("error","storage")))
	result=result.duplicate(true)
	result.item_state=Items.new(db).read_state(character_id)
	if result.item_state.is_empty(): return rollback("storage")
	var written: Dictionary=db.execute("INSERT INTO economy.market_commands(account_id,command_id,character_id,kind,request_json,result_json) VALUES(:account,:command,:character,:kind,:request,:result);",{"account":account_id,"command":_command,"character":character_id,"kind":_kind,"request":_request,"result":Codec.encode_result(result)})
	if not written.ok: return rollback("storage")
	if not db.commit():
		db.close()
		return {"ok":false,"error":"outcome_unknown","outcome_unknown":true}
	committed=true
	return result

static func decode(json: String) -> Dictionary:
	var result: Dictionary=Codec.decode_result(json)
	for field: String in ["revision","position","shop_id","price","balance"]:
		if result.has(field): result[field]=int(result[field])
	return result
