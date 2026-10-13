class_name WalletStoreSqlite
extends RefCounted
## Fungible Yang only. Unique items keep their own immediate transactions.
const MAX_YANG: int = 9000000000000000
var db: SQLite

func _init(database: SQLite) -> void:
	db = database

static func ensure_schema(database: SQLite) -> bool:
	return database.query("CREATE TABLE IF NOT EXISTS wallets (character_id INTEGER PRIMARY KEY NOT NULL, yang INTEGER NOT NULL DEFAULT 0 CHECK(typeof(yang)='integer' AND yang>=0 AND yang<=9000000000000000));")

## Run offline before economic actions, using a full trusted Master manifest.
static func migrate_accounts(database: SQLite, master_ids: Dictionary) -> Dictionary:
	var audit := WorldStoreSqlite.new(database).audit_account_identities(master_ids)
	if not audit.ok or not audit.orphaned.is_empty() or not audit.mismatched.is_empty(): return {"ok":false,"error":"identity","audit":audit}
	if not database.query("SELECT value FROM meta WHERE key='schema_version';"): return {"ok":false,"error":"storage"}
	if int(database.query_result[0].value) >= 18: return {"ok":true,"already_migrated":true}
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
	return {"ok":true,"already_migrated":false}

func load_wallet(owner_id: int) -> Dictionary:
	if not db.query_with_bindings("SELECT * FROM account_wallets WHERE account_id=?;", [owner_id]):
		return {"ok": false, "error": "storage"}
	if db.query_result.is_empty(): return {"ok": false, "error": "owner"}
	return {"ok": true, "balance": int(db.query_result[0].yang),"reserved_yang":int(db.query_result[0].get("reserved_yang",0))}

func checkpoint(deltas: Dictionary) -> Dictionary:
	if deltas.is_empty(): return {"ok": true, "balances": {}}
	if not db.query("BEGIN IMMEDIATE;"): return {"ok": false, "error": "storage"}
	var balances: Dictionary = {}
	for owner_id: int in deltas:
		var result: Dictionary = _apply_income(owner_id, int(deltas[owner_id]))
		if not result.ok: return _rollback(str(result.error))
		balances[owner_id] = result.balance
	if not db.query("COMMIT;"): return _rollback("storage")
	return {"ok": true, "balances": balances}

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
	return {"ok": true, "balance": int(income.balance) - cost}

func _apply_income(owner_id: int, amount: int) -> Dictionary:
	if amount < 0 or amount > MAX_YANG: return {"ok": false, "error": "request"}
	if not db.query_with_bindings("UPDATE account_wallets SET yang=yang+? WHERE account_id=?;", [amount, owner_id]):
		return {"ok": false, "error": "storage"}
	if not db.query("SELECT changes() AS n;"): return {"ok": false, "error": "storage"}
	if int(db.query_result[0].n) != 1: return {"ok": false, "error": "owner"}
	if not db.query_with_bindings("SELECT * FROM account_wallets WHERE account_id=?;", [owner_id]):
		return {"ok": false, "error": "storage"}
	return {"ok": true, "balance": int(db.query_result[0].yang),"reserved_yang":int(db.query_result[0].get("reserved_yang",0))}

func _rollback(reason: String) -> Dictionary:
	db.query("ROLLBACK;")
	return {"ok": false, "error": reason}

## Critical account credit. A future item sale must call this inside its own transaction.
func credit_in_transaction(account_id: int, pending_income: int, amount: int) -> Dictionary:
	if amount <= 0 or pending_income < 0 or amount > MAX_YANG-pending_income: return {"ok":false,"error":"request"}
	return _apply_income(account_id,pending_income+amount)

func credit(account_id: int, pending_income: int, amount: int) -> Dictionary:
	if not db.query("BEGIN IMMEDIATE;"): return {"ok":false,"error":"storage"}
	var result := credit_in_transaction(account_id,pending_income,amount)
	if not result.ok: return _rollback(str(result.error))
	if not db.query("COMMIT;"): return _rollback("storage")
	return result
