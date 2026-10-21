extends RefCounted
## PostgreSQL wallet primitives. Runtime uses WalletSession's session/receipt
## boundary, never these unreceipted standalone writes. One caller/thread owns
## this synchronous native SOCI session for the ENTIRE transaction. Never yield
## an open transaction or distribute its statements across async dispatchers.
const MAX_YANG: int = 9000000000000000
var db: Object

func _init(database: Object) -> void:
	db = database

## Only a trusted server identity bootstrap may call this. An alt uses the same
## Master account ID. ON CONFLICT must never reset funds or repeat a starter grant.
func initialize_account(account_id: int) -> Dictionary:
	if account_id <= 0: return {"ok":false,"error":"owner"}
	if not _begin(): return {"ok":false,"error":"storage"}
	if not db.execute("INSERT INTO economy.accounts(account_id) VALUES(:id) ON CONFLICT DO NOTHING;", {"id":account_id}).ok:
		return _rollback("storage")
	if not db.execute("INSERT INTO economy.account_wallets(account_id) VALUES(:id) ON CONFLICT DO NOTHING;", {"id":account_id}).ok:
		return _rollback("storage")
	return _finish(load_wallet(account_id))

func load_wallet(account_id: int) -> Dictionary:
	return _state_result(account_id)

func checkpoint(deltas: Dictionary) -> Dictionary:
	if deltas.is_empty(): return {"ok":true,"balances":{}}
	if not _begin(): return {"ok":false,"error":"storage"}
	var balances: Dictionary = {}
	var states: Array = []
	# Admit every account before touching wallets, in the same order as Shop
	# settlement/Exchange. Sorting wallet updates alone is insufficient: a match
	# may flush taker's wallet before maker's while holding both account locks.
	var accounts: Array = deltas.keys()
	accounts.sort()
	for account_id: int in accounts:
		var admitted: Dictionary=db.query("SELECT account_id FROM economy.accounts WHERE account_id=:account FOR NO KEY UPDATE;",{"account":account_id})
		if not admitted.ok: return _rollback("storage")
		if admitted.rows.is_empty(): return _rollback("owner")
	for account_id: int in accounts:
		var result := _apply_income(account_id, int(deltas[account_id]))
		if not result.ok: return _rollback(str(result.error))
		balances[account_id] = result.balance
		var state: Dictionary = result.wallet_state
		state.pending_applied = int(deltas[account_id])
		states.append(state)
	return _finish({"ok":true,"balances":balances,"wallet_states":states})

func spend(account_id: int, pending_income: int, cost: int) -> Dictionary:
	if cost <= 0 or cost > MAX_YANG: return {"ok":false,"error":"request"}
	if not _begin(): return {"ok":false,"error":"storage"}
	return _finish(spend_in_transaction(account_id, pending_income, cost))

## The caller owns BEGIN/COMMIT, including future item/receipt mutations.
func spend_in_transaction(account_id: int, pending_income: int, cost: int) -> Dictionary:
	if not db.in_transaction(): return {"ok":false,"error":"transaction"}
	if cost <= 0 or cost > MAX_YANG: return {"ok":false,"error":"request"}
	var income := _apply_income(account_id, pending_income)
	if not income.ok: return income
	if int(income.balance)-int(income.reserved_yang)<cost: return {"ok":false,"error":"funds"}
	var result: Dictionary = db.execute("UPDATE economy.account_wallets SET yang=yang-:cost WHERE account_id=:id AND yang-reserved_yang>=:cost;", {"id":account_id,"cost":cost})
	if not result.ok: return {"ok":false,"error":"storage"}
	if int(result.affected_rows)!=1: return {"ok":false,"error":"funds"}
	return _state_result(account_id, pending_income)

func credit(account_id: int, pending_income: int, amount: int) -> Dictionary:
	if not _begin(): return {"ok":false,"error":"storage"}
	return _finish(credit_in_transaction(account_id, pending_income, amount))

func credit_in_transaction(account_id: int, pending_income: int, amount: int) -> Dictionary:
	if not db.in_transaction(): return {"ok":false,"error":"transaction"}
	if amount <= 0 or pending_income < 0 or amount > MAX_YANG-pending_income: return {"ok":false,"error":"request"}
	var result := _apply_income(account_id, pending_income+amount)
	if result.ok: result.wallet_state.pending_applied = pending_income
	return result

func _apply_income(account_id: int, amount: int) -> Dictionary:
	if amount < 0 or amount > MAX_YANG: return {"ok":false,"error":"request"}
	var result: Dictionary = db.execute("UPDATE economy.account_wallets SET yang=yang+:amount WHERE account_id=:id;", {"id":account_id,"amount":amount})
	if not result.ok: return {"ok":false,"error":"storage"}
	if int(result.affected_rows)!=1: return {"ok":false,"error":"owner"}
	return _state_result(account_id)

func _state_result(account_id: int, applied_pending: int = 0) -> Dictionary:
	var result: Dictionary = db.query("SELECT w.yang,w.reserved_yang,w.wallet_revision,m.value AS authority_id FROM economy.account_wallets w JOIN economy.meta m ON m.key='economy_authority_id' WHERE account_id=:id;", {"id":account_id})
	if not result.ok: return {"ok":false,"error":"storage"}
	if result.rows.is_empty(): return {"ok":false,"error":"owner"}
	var row: Dictionary = result.rows[0]
	var state := {"authority_id":str(row.authority_id),"account_id":account_id,"revision":int(row.wallet_revision),"balance":int(row.yang),"reserved_yang":int(row.reserved_yang),"pending_applied":applied_pending}
	return {"ok":true,"balance":state.balance,"reserved_yang":state.reserved_yang,"wallet_state":state}

func _begin() -> bool:
	# Never accidentally commit/rollback the caller's existing transaction.
	return not db.in_transaction() and db.begin()

func _rollback(reason: String) -> Dictionary:
	if not db.rollback():
		db.close()
	return {"ok":false,"error":reason}

func _finish(result: Dictionary) -> Dictionary:
	if not result.ok: return _rollback(str(result.error))
	if db.commit(): return result
	# A failed COMMIT is not evidence of failure. No blind retry of a spend or
	# grinding delta. Runtime uses wallet_session_postgres.gd for fenced receipts.
	db.close()
	return {"ok":false,"error":"outcome_unknown","outcome_unknown":true}
