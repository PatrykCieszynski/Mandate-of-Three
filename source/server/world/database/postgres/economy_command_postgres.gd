extends RefCounted
## PostgreSQL command/receipt ownership, by composition. One native session owns
## read/validate/mutation/receipt/COMMIT; no arbitrary async statement dispatch.
const Codec = preload("res://source/server/world/database/economy_receipt_codec.gd")
var db: Object
var account_id: int
var character_id: int
var cached: Dictionary={}
var committed:=false
var receipt_replay:=false
const MAX_TRANSACTION_ATTEMPTS: int=3
# Internal proof from this owner's last successful statement-failure rollback.
# Never populate from COMMIT, caller text or a previous attempt.
var _rolled_back_sqlstate: String=""
var _commit_attempted: bool=false
var rejected: MarketRejectedCommands
var _command: String
var _kind: String
var _request: String

func _init(database: Object, rejected_commands: MarketRejectedCommands = null) -> void:
	db=database
	rejected=rejected_commands

static func valid_id(value: String) -> bool:
	if value.is_empty() or value.length()>96: return false
	for character: String in value:
		if not "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-:".contains(character): return false
	return true

func begin(owner: int, command: String, kind: String, args: Array, shared_account: bool = false, counterparty: int = 0) -> bool:
	committed=false
	receipt_replay=false
	cached={}
	if not valid_id(command):
		cached={"ok":false,"error":"request"}
		return false
	if db.in_transaction() or not db.begin():
		cached={"ok":false,"error":"storage"}
		return false
	_commit_attempted=false
	# Shared Storage must serialize BEFORE receipt lookup as well as capacity:
	# two alts using one command ID must observe replay/conflict, not a PK error.
	var locked_account: int=0
	if shared_account:
		var scope: Dictionary=db.query("SELECT account_id FROM economy.characters WHERE character_id=:id;",{"id":owner})
		if not scope.ok or scope.rows.is_empty():
			cached=rollback("storage" if not scope.ok else "owner")
			return false
		locked_account=int(scope.rows[0].account_id)
		# Shop settlement locks both account domains in ascending order BEFORE
		# character/receipt/capacity. Reciprocal purchases cannot invert locks.
		# counterparty is a server-resolved hint; the store rechecks it under lock.
		var accounts: Array[int]=[locked_account]
		if counterparty>0 and counterparty!=locked_account: accounts.append(counterparty)
		accounts.sort()
		for account: int in accounts:
			var admission: Dictionary=db.query("SELECT account_id FROM economy.accounts WHERE account_id=:account FOR NO KEY UPDATE;",{"account":account})
			if not admission.ok or admission.rows.is_empty():
				cached=rollback("storage")
				return false
	return admit_in_transaction(owner,command,kind,args,locked_account)

## Internal composition for an explicitly owned transaction (Exchange pair plus
## sorted participant accounts). Caller must have acquired account admission;
## this method then owns character/receipt checks and terminal rollback/commit.
## Ordinary begin() still refuses a caller's existing transaction.
func admit_in_transaction(owner: int, command: String, kind: String, args: Array, expected_account: int) -> bool:
	_commit_attempted=false
	committed=false
	receipt_replay=false
	cached={}
	if not db.in_transaction():
		cached={"ok":false,"error":"transaction"}
		return false
	if not valid_id(command):
		cached=rollback("request")
		return false
	# Serialize character capacity/commands without blocking FK KEY SHARE checks
	# on an alt's provenance while that alt waits for shared Storage admission.
	var result: Dictionary=db.query("SELECT account_id FROM economy.characters WHERE character_id=:id FOR NO KEY UPDATE;",{"id":owner})
	if not result.ok or result.rows.is_empty():
		cached=rollback("storage" if not result.ok else "owner")
		return false
	if expected_account>0 and expected_account!=int(result.rows[0].account_id):
		cached=rollback("storage")
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
	if result.rows.is_empty():
		if rejected==null: return true
		cached=rejected.lookup(account_id,_command,_kind,_request)
		if cached.is_empty(): return true
		if not db.rollback():
			db.close()
			cached={"ok":false,"error":"storage"}
		return false
	var row: Dictionary=result.rows[0]
	cached=decode(str(row.result_json)) if row.kind==kind and row.request_json==_request else {"ok":false,"error":"command_conflict"}
	receipt_replay=bool(cached.get("ok",false))
	if not db.rollback():
		db.close()
		cached={"ok":false,"error":"storage"}
		receipt_replay=false
	return false

func rollback(error: String) -> Dictionary:
	_rolled_back_sqlstate=""
	var details: Dictionary={}
	if not _commit_attempted and error=="storage" and db.in_transaction() and db.has_method("get_last_error_details"):
		details=db.get_last_error_details()
	if not db.rollback():
		db.close()
		return {"ok":false,"error":"storage"}
	if details.get("error_backend","")=="postgresql" and details.get("sqlstate","") in ["40001","40P01"]:
		_rolled_back_sqlstate=str(details.sqlstate)
	return {"ok":false,"error":error}

## Opt-in owner for receipted use cases only. The callable must restart the whole
## operation (including identity/receipt/selection/capacity), keeping original ID
## and pending prefix. No yields, connection pool or statement-level retry.
func run_with_retry(operation: Callable) -> Dictionary:
	committed=false
	receipt_replay=false
	_rolled_back_sqlstate=""
	if db.in_transaction(): return {"ok":false,"error":"storage"}
	_commit_attempted=false
	var result: Dictionary={"ok":false,"error":"storage"}
	for attempt: int in MAX_TRANSACTION_ATTEMPTS:
		_rolled_back_sqlstate=""
		result=operation.call()
		if result.get("ok",false) or result.get("outcome_unknown",false): return result
		if _commit_attempted: return result
		if _rolled_back_sqlstate not in ["40001","40P01"] or db.in_transaction() or not db.is_open(): return result
	return result

func commit(result: Dictionary) -> Dictionary:
	if not result.ok:
		if not db.rollback():
			db.close()
			return {"ok":false,"error":"storage"}
		if rejected!=null: rejected.remember(account_id,_command,_kind,_request,result)
		return result
	result=result.duplicate(true)
	result.item_state=read_state(db,character_id)
	if result.item_state.is_empty(): return rollback("storage")
	var stored:=result.duplicate(true)
	for field: String in ["revision","position","shop_id","price","balance","buyer_account","seller_account","buyer_balance","amount","remaining","refunded"]:
		if stored.has(field): stored[field]=str(stored[field])
	if stored.has("affected_accounts"):
		stored.affected_accounts=stored.affected_accounts.map(func(account: Variant) -> String: return str(account))
	var written: Dictionary=db.execute("INSERT INTO economy.market_commands(account_id,command_id,character_id,kind,request_json,result_json) VALUES(:account,:command,:character,:kind,:request,:result);",{"account":account_id,"command":_command,"character":character_id,"kind":_kind,"request":_request,"result":Codec.encode_result(stored)})
	if not written.ok: return rollback("storage")
	_commit_attempted=true
	if not db.commit():
		db.close()
		return {"ok":false,"error":"outcome_unknown","outcome_unknown":true}
	committed=true
	return result

static func read_state(database: Object, owner: int) -> Dictionary:
	var result: Dictionary=database.query("SELECT c.account_id,COALESCE(r.revision,0) AS revision,m.value AS authority_id FROM economy.characters c LEFT JOIN economy.account_item_revisions r ON r.account_id=c.account_id JOIN economy.meta m ON m.key='economy_authority_id' WHERE c.character_id=:id;",{"id":owner})
	if not result.ok or result.rows.is_empty(): return {}
	var row: Dictionary=result.rows[0]
	return {"authority_id":str(row.authority_id),"account_id":int(row.account_id),"character_id":owner,"revision":int(row.revision)}

static func decode(json: String) -> Dictionary:
	var result: Dictionary=Codec.decode_result(json)
	for field: String in ["revision","position","shop_id","price","balance","buyer_account","seller_account","buyer_balance","amount","remaining","refunded"]:
		if result.has(field): result[field]=int(result[field])
	if result.has("affected_accounts"):
		result.affected_accounts=result.affected_accounts.map(func(account: Variant) -> int: return int(account))
	return result
