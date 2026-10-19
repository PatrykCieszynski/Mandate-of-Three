extends RefCounted
## One worker session owns account-first custody/footprint/receipt transactions.
## Lookup can recover an original alt's result, never retarget its mutation.
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Storage = preload("res://source/server/world/database/postgres/account_storage_postgres.gd")
var db: Object
var committed:=false
var receipt_replay:=false

func _init(database: Object) -> void: db=database

static func valid_body(body: Dictionary) -> bool:
	return body.size()==5 and body.has_all(["uid","revision","source","destination","position"]) and body.uid is String and ItemInstance.valid_uid(body.uid) and body.revision is int and body.revision>=0 and body.source in ["inventory","storage"] and body.destination in ["inventory","storage"] and not (body.source=="inventory" and body.destination=="inventory") and body.position is int and body.position>=-1

func execute(context: Dictionary, id: String, body: Dictionary) -> Dictionary:
	if not valid_body(body): return {"ok":false,"error":"request"}
	var store:=Storage.new(db)
	store.authorize_session(context)
	var result:=store.transfer_command(context.character,body.uid,body.revision,body.source,body.destination,body.position,id)
	committed=store.committed
	receipt_replay=store.receipt_replay
	return result

func receipt(context: Dictionary, issuer: int, id: String) -> Dictionary:
	if issuer<=0 or not Commands.valid_id(id): return {"ok":false,"error":"request"}
	var begun:=Sessions.new(db).begin_context(context)
	if not begun.ok: return begun
	var found: Dictionary=db.query("SELECT result_json FROM economy.market_commands WHERE account_id=:account AND character_id=:issuer AND command_id=:id AND kind='storage';",{"account":context.account_id,"issuer":issuer,"id":id})
	if not found.ok:
		if not db.rollback(): db.close()
		return {"ok":false,"error":"storage"}
	var result: Dictionary={"ok":false,"error":"unknown_command"} if found.rows.is_empty() else Commands.decode(str(found.rows[0].result_json))
	if not db.commit():
		db.close()
		return {"ok":false,"error":"outcome_unknown","outcome_unknown":true}
	receipt_replay=result.get("ok",false)
	return result
