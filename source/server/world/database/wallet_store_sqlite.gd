class_name WalletStoreSqlite
extends RefCounted
## Fungible Yang only. Unique items keep their own immediate transactions.
const MAX_YANG: int = 9000000000000000
var db: SqliteSoci

func _init(database: SqliteSoci) -> void:
	db = database

static func ensure_schema(database: SqliteSoci) -> bool:
	return database.query("CREATE TABLE IF NOT EXISTS wallets (character_id INTEGER PRIMARY KEY NOT NULL, yang INTEGER NOT NULL DEFAULT 0 CHECK(typeof(yang)='integer' AND yang>=0 AND yang<=9000000000000000));")

## Run offline before economic actions, using a full trusted Master manifest.
static func migrate_accounts(database: SqliteSoci, master_ids: Dictionary) -> Dictionary:
	var audit := WorldStoreSqlite.new(database).audit_account_identities(master_ids)
	if not audit.ok or not audit.orphaned.is_empty() or not audit.mismatched.is_empty(): return {"ok":false,"error":"identity","audit":audit}
	if not database.query("SELECT value FROM meta WHERE key='schema_version';"): return {"ok":false,"error":"storage"}
	if int(database.query_result[0].value) >= 18:
		return {"ok":true,"already_migrated":true} if preload("res://source/server/world/database/wallet_state_sqlite.gd").ensure_schema(database) else {"ok":false,"error":"wallet_revision_migration"}
	if not database.query("BEGIN IMMEDIATE;"): return {"ok":false,"error":"storage"}
	var store := WorldStoreSqlite.new(database)
	audit = store.audit_account_identities(master_ids)
	if not audit.ok or not audit.orphaned.is_empty() or not audit.mismatched.is_empty():
		database.query("ROLLBACK;")
		return {"ok":false,"error":"identity","audit":audit}
	for name: String in audit.unbound:
		var id := int(master_ids[name])
		if id <= 0 or not database.query_with_bindings("UPDATE accounts SET master_account_id=? WHERE account_name=? AND master_account_id IS NULL;",[id,name]):
			database.query("ROLLBACK;")
			return {"ok":false,"error":"identity"}
	if not database.query("SELECT w.character_id FROM wallets w LEFT JOIN players p ON p.player_id=w.character_id WHERE p.player_id IS NULL LIMIT 1;") or not database.query_result.is_empty():
		database.query("ROLLBACK;")
		return {"ok":false,"error":"orphan_wallet"}
	var statements: Array[String] = [
		"CREATE TABLE account_wallets (account_id INTEGER PRIMARY KEY NOT NULL REFERENCES accounts(master_account_id), yang INTEGER NOT NULL DEFAULT 0 CHECK(typeof(yang)='integer' AND yang>=0 AND yang<=9000000000000000));",
		"INSERT INTO account_wallets(account_id,yang) SELECT a.master_account_id,COALESCE(SUM(w.yang),0) FROM players p JOIN accounts a ON a.account_name=p.account_name LEFT JOIN wallets w ON w.character_id=p.player_id GROUP BY a.master_account_id;",
		"DROP TABLE wallets;",
		"INSERT OR REPLACE INTO meta(key,value) VALUES('schema_version','18');", "COMMIT;"
	]
	for statement: String in statements:
		if not database.query(statement):
			database.query("ROLLBACK;")
			return {"ok":false,"error":"storage_or_overflow"}
	return {"ok":true,"already_migrated":false} if preload("res://source/server/world/database/wallet_state_sqlite.gd").ensure_schema(database) else {"ok":false,"error":"wallet_revision_migration"}

func load_wallet(owner_id: int) -> Dictionary:
	return _state_result(owner_id)

func _state_result(account_id: int, applied_pending: int = 0) -> Dictionary:
	var state: Dictionary = preload("res://source/server/world/database/wallet_state_sqlite.gd").read(db,account_id,applied_pending)
	if state.has("error"): return state
	return {"ok":true,"balance":state.balance,"reserved_yang":state.reserved_yang,"wallet_state":state}

func checkpoint(deltas: Dictionary) -> Dictionary:
	if deltas.is_empty(): return {"ok": true, "balances": {}}
	if not db.query("BEGIN IMMEDIATE;"): return {"ok": false, "error": "storage"}
	var balances: Dictionary = {}
	var states: Array = []
	for owner_id: int in deltas:
		var result: Dictionary = _apply_income(owner_id, int(deltas[owner_id]))
		if not result.ok: return _rollback(str(result.error))
		balances[owner_id] = result.balance
		var state: Dictionary = result.wallet_state
		state.pending_applied = int(deltas[owner_id])
		states.append(state)
	if not db.query("COMMIT;"): return _rollback("storage")
	return {"ok": true, "balances": balances,"wallet_states":states}

func spend(owner_id: int, pending_income: int, cost: int) -> Dictionary:
	if cost <= 0 or cost > MAX_YANG: return {"ok": false, "error": "request"}
	if not db.query("BEGIN IMMEDIATE;"): return {"ok": false, "error": "storage"}
	var result: Dictionary = spend_in_transaction(owner_id, pending_income, cost)
	if not result.ok: return _rollback(str(result.error))
	if not db.query("COMMIT;"): return _rollback("storage")
	return result

## Caller owns the transaction, including capacity, offer validation and item
## mutation. Never call spend() followed by a separate item transaction for Shop.
## Runtime balance/pending income must only change after the caller commits.
func spend_in_transaction(owner_id: int, pending_income: int, cost: int) -> Dictionary:
	if cost <= 0 or cost > MAX_YANG: return {"ok": false, "error": "request"}
	var income: Dictionary = _apply_income(owner_id, pending_income)
	if not income.ok: return income
	if int(income.balance)-int(income.reserved_yang)<cost: return {"ok":false,"error":"funds"}
	if not db.query_with_bindings("UPDATE account_wallets SET yang=yang-? WHERE account_id=? AND yang>=?;", [cost, owner_id, cost]):
		return {"ok": false, "error": "storage"}
	if not db.query("SELECT changes() AS n;"): return {"ok": false, "error": "storage"}
	if int(db.query_result[0].n) != 1: return {"ok": false, "error": "funds"}
	return _state_result(owner_id,pending_income)

func _apply_income(owner_id: int, amount: int) -> Dictionary:
	if amount < 0 or amount > MAX_YANG: return {"ok": false, "error": "request"}
	if not db.query_with_bindings("UPDATE account_wallets SET yang=yang+? WHERE account_id=?;", [amount, owner_id]):
		return {"ok": false, "error": "storage"}
	if not db.query("SELECT changes() AS n;"): return {"ok": false, "error": "storage"}
	if int(db.query_result[0].n) != 1: return {"ok": false, "error": "owner"}
	return _state_result(owner_id)

func _rollback(reason: String) -> Dictionary:
	db.query("ROLLBACK;")
	return {"ok": false, "error": reason}

## Critical account credit, including explicit Shop revenue collection. The caller
## owns the transaction; player sales themselves credit separate Shop revenue.
func credit_in_transaction(account_id: int, pending_income: int, amount: int) -> Dictionary:
	if amount <= 0 or pending_income < 0 or amount > MAX_YANG-pending_income: return {"ok":false,"error":"request"}
	var result := _apply_income(account_id,pending_income+amount)
	if result.ok: result.wallet_state.pending_applied = pending_income
	return result

func credit(account_id: int, pending_income: int, amount: int) -> Dictionary:
	if not db.query("BEGIN IMMEDIATE;"): return {"ok":false,"error":"storage"}
	var result := credit_in_transaction(account_id,pending_income,amount)
	if not result.ok: return _rollback(str(result.error))
	if not db.query("COMMIT;"): return _rollback("storage")
	return result
