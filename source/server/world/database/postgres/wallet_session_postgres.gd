extends RefCounted
## Session-qualified, receipted batches. One worker owns the whole transaction.
## A batch is a captured RAM income prefix, not a receipt for each ground drop.
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
var db: Object
var commands: RefCounted
var committed:=false
var receipt_replay:=false

func _init(database: Object) -> void:
	db=database
	commands=Commands.new(db)

func snapshot(context: Dictionary) -> Dictionary:
	var begun:=Sessions.new(db).begin_context(context)
	if not begun.ok: return begun
	var result: Dictionary=Wallet.new(db).load_wallet(context.account_id)
	if not result.ok: return commands.rollback(str(result.error))
	if db.commit(): return result
	db.close()
	return {"ok":false,"error":"outcome_unknown","outcome_unknown":true}

func batch(context: Dictionary, issuer: int, operation_id: String, income: int, cost: int) -> Dictionary:
	if issuer<=0 or not Commands.valid_id(operation_id) or income<0 or income>Wallet.MAX_YANG or cost<0 or cost>Wallet.MAX_YANG or (income==0 and cost==0): return {"ok":false,"error":"request"}
	var safe:=context.duplicate(true)
	var result: Dictionary=commands.run_with_retry(func() -> Dictionary: return _batch(safe,issuer,operation_id,income,cost))
	committed=commands.committed
	receipt_replay=commands.receipt_replay
	return result

func _batch(context: Dictionary, issuer: int, operation_id: String, income: int, cost: int) -> Dictionary:
	var begun:=Sessions.new(db).begin_context(context)
	if not begun.ok: return begun
	# Current account authority may recover a prefix captured by an earlier alt.
	# The original issuer/body stays fixed; the caller cannot retarget a receipt.
	if not commands.admit_in_transaction(issuer,operation_id,"wallet_batch",[str(issuer),str(income),str(cost)],context.account_id): return commands.cached
	var result: Dictionary
	if cost>0:
		result=Wallet.new(db).spend_in_transaction(context.account_id,income,cost)
	else:
		result=Wallet.new(db).credit_in_transaction(context.account_id,0,income)
	if not result.ok: return commands.rollback(str(result.error))
	result.wallet_state.pending_applied=income
	return commands.commit({"ok":true,"wallet_states":[result.wallet_state]})
