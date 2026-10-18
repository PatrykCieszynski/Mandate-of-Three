extends RefCounted
## Inventory-only durable admission/recovery. Trusted server caller; session
## authorization is not inferred from supplied character IDs.
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const MAX_PENDING_PER_ACCOUNT: int=8
const MAX_PAGE: int=100
var db: Object
var committed:=false
var receipt_replay:=false

func _init(database: Object) -> void: db=database

func admit(character: int, operation_id: String, action: String, uid: String, revision: int, position: int) -> Dictionary:
	return _admission(character,operation_id,action,uid,revision,position,{})

func admit_session(context: Dictionary, operation_id: String, action: String, uid: String, revision: int, position: int) -> Dictionary:
	return _admission(int(context.get("character",0)),operation_id,action,uid,revision,position,context.duplicate(true))

func _admission(character: int, operation_id: String, action: String, uid: String, revision: int, position: int, context: Dictionary) -> Dictionary:
	committed=false
	receipt_replay=false
	if not Items.valid_inventory_request(action,uid,revision,position): return {"ok":false,"error":"request"}
	var transaction:=Commands.new(db)
	return transaction.run_with_retry(_admit_once.bind(character,operation_id,action,uid,revision,position,transaction,context))

func _admit_once(character: int, operation_id: String, action: String, uid: String, revision: int, position: int, transaction: RefCounted, context: Dictionary) -> Dictionary:
	var args: Array=[character,action,uid,revision,position]
	if not transaction.begin_inventory_session(character,operation_id,args,context):
		if transaction.cached.get("error","") in ["operation_pending"]: return outcome(character,operation_id)
		if transaction.cached.get("ok",false): return {"ok":true,"state":"committed","operation_id":operation_id,"result":transaction.cached,"replayed":true}
		if transaction.cached.get("error","") not in ["command_conflict","storage","stale_session","session_required","recovery_required"]:
			var prior:=outcome(character,operation_id)
			if prior.get("state","")=="rejected": return prior
		return transaction.cached
	var count: Dictionary=db.query("SELECT COUNT(*) AS n FROM economy.inventory_intents WHERE account_id=:account AND state='pending';",{"account":transaction.account_id})
	if not count.ok: return transaction.rollback("storage")
	if int(count.rows[0].n)>=MAX_PENDING_PER_ACCOUNT: return transaction.rollback("busy")
	var added: Dictionary=db.execute("INSERT INTO economy.inventory_intents(account_id,operation_id,character_id,action,item_uid,expected_revision,position,request_json) VALUES(:account,:command,:character,:action,:uid,:revision,:position,:request);",{"account":transaction.account_id,"command":operation_id,"character":character,"action":action,"uid":uid,"revision":revision,"position":position,"request":JSON.stringify(args)})
	if not added.ok: return transaction.rollback("storage")
	var result: Dictionary=transaction.commit_inventory_admission()
	if result.ok: result.operation_id=operation_id
	return result

## Session-scoped recovery may finish the account's earlier alt commands, but
## always under their ORIGINAL issuing character, never retargeting the item.
func resume_session(context: Dictionary, operation_id: String) -> Dictionary:
	var loaded:=_session_load(context,operation_id)
	if not loaded.ok: return loaded
	return execute(int(loaded.row.character_id),operation_id)

func outcome_session(context: Dictionary, operation_id: String) -> Dictionary:
	var loaded:=_session_load(context,operation_id)
	return _view(loaded.row) if loaded.ok else loaded

func _session_load(context: Dictionary, operation_id: String) -> Dictionary:
	if not Commands.valid_id(operation_id): return {"ok":false,"error":"request"}
	var begun:=Sessions.new(db).begin_context(context)
	if not begun.ok: return begun
	var found: Dictionary=db.query("SELECT * FROM economy.inventory_intents WHERE account_id=:account AND operation_id=:command;",{"account":context.account_id,"command":operation_id})
	if not found.ok: return _session_rollback("storage")
	if found.rows.is_empty(): return _session_rollback("unknown_command")
	return _session_commit({"ok":true,"row":found.rows[0]})

func snapshot_session(context: Dictionary) -> Dictionary:
	var begun:=Sessions.new(db).begin_context(context)
	if not begun.ok: return begun
	var snapshot:=Items.new(db).inventory(int(context.character))
	if not snapshot.ok: return _session_rollback(str(snapshot.error))
	return _session_commit(snapshot)

func discover_session(context: Dictionary, after: int = 0, limit: int = 50) -> Dictionary:
	if after<0 or limit<1 or limit>MAX_PAGE: return {"ok":false,"error":"request"}
	var begun:=Sessions.new(db).begin_context(context)
	if not begun.ok: return begun
	var found: Dictionary=db.query("SELECT * FROM economy.inventory_intents WHERE account_id=:account AND sequence>:after ORDER BY sequence LIMIT :limit;",{"account":context.account_id,"after":after,"limit":limit+1},limit+1)
	if not found.ok or found.truncated: return _session_rollback("storage")
	var rows: Array=found.rows.slice(0,limit)
	return _session_commit({"ok":true,"operations":rows.map(_view),"more":found.rows.size()>limit,"cursor":after if rows.is_empty() else int(rows.back().sequence)})

func _session_commit(result: Dictionary) -> Dictionary:
	if not db.commit():
		db.close()
		return {"ok":false,"error":"outcome_unknown","outcome_unknown":true}
	return result

func _session_rollback(reason: String) -> Dictionary:
	if not db.rollback(): db.close()
	return {"ok":false,"error":reason}

func execute(character: int, operation_id: String) -> Dictionary:
	committed=false
	receipt_replay=false
	var loaded:=_load(character,operation_id)
	if not loaded.ok: return loaded
	var body: Dictionary=loaded.row
	if body.state=="terminal":
		receipt_replay=true
		return _view(body)
	var items:=Items.new(db)
	var result:=items.execute_inventory_intent(character,operation_id,body)
	committed=items.committed
	receipt_replay=items.receipt_replay
	if result.get("outcome_unknown",false): return result
	if result.get("error","")=="storage": return result # durable intent remains pending
	return outcome(character,operation_id)

func outcome(character: int, operation_id: String) -> Dictionary:
	var loaded:=_load(character,operation_id)
	return _view(loaded.row) if loaded.ok else loaded

func _load(character: int, operation_id: String) -> Dictionary:
	if not Commands.valid_id(operation_id) or character<=0: return {"ok":false,"error":"request"}
	var found: Dictionary=db.query("SELECT i.* FROM economy.inventory_intents i JOIN economy.characters c ON c.account_id=i.account_id AND c.character_id=i.character_id WHERE i.character_id=:character AND i.operation_id=:command;",{"character":character,"command":operation_id})
	if not found.ok: return {"ok":false,"error":"storage"}
	if found.rows.is_empty(): return {"ok":false,"error":"unknown_command"}
	return {"ok":true,"row":found.rows[0]}

func discover(character: int, after: int = 0, limit: int = 50) -> Dictionary:
	if character<=0 or after<0 or limit<1 or limit>MAX_PAGE: return {"ok":false,"error":"request"}
	var found: Dictionary=db.query("SELECT i.* FROM economy.inventory_intents i JOIN economy.characters c ON c.account_id=i.account_id AND c.character_id=i.character_id WHERE i.character_id=:character AND i.sequence>:after ORDER BY i.sequence LIMIT :limit;",{"character":character,"after":after,"limit":limit+1},limit+1)
	if not found.ok or found.truncated: return {"ok":false,"error":"storage"}
	var more: bool=found.rows.size()>limit
	var rows: Array=found.rows.slice(0,limit)
	return {"ok":true,"operations":rows.map(_view),"more":more,"cursor":after if rows.is_empty() else int(rows.back().sequence)}

func _view(row: Dictionary) -> Dictionary:
	var result: Dictionary={"ok":true,"operation_id":str(row.operation_id),"character":int(row.character_id),"action":str(row.action),"uid":str(row.item_uid),"revision":int(row.expected_revision),"position":int(row.position),"sequence":int(row.sequence),"state":"pending"}
	if row.state=="terminal":
		result.result=Commands.decode(str(row.result_json))
		if result.result.get("error","") in ["storage","outcome_unknown"]: return {"ok":false,"error":"storage"}
		result.state="committed" if result.result.get("ok",false) else "rejected"
	return result
