class_name WalletStoreSqlite
extends RefCounted
## Fungible Yang only. Unique items keep their own immediate transactions.
const MAX_YANG: int = 9000000000000000
var db: SQLite

func _init(database: SQLite) -> void:
	db = database

static func ensure_schema(database: SQLite) -> bool:
	return database.query("CREATE TABLE IF NOT EXISTS wallets (character_id INTEGER PRIMARY KEY NOT NULL, yang INTEGER NOT NULL DEFAULT 0 CHECK(typeof(yang)='integer' AND yang>=0 AND yang<=9000000000000000));")

func load_wallet(owner_id: int) -> Dictionary:
	# Lazy initialization supports both existing and newly created characters.
	if not db.query_with_bindings("INSERT OR IGNORE INTO wallets(character_id,yang) SELECT player_id,0 FROM players WHERE player_id=?;", [owner_id]):
		return {"ok": false, "error": "storage"}
	if not db.query_with_bindings("SELECT yang FROM wallets WHERE character_id=?;", [owner_id]):
		return {"ok": false, "error": "storage"}
	if db.query_result.is_empty(): return {"ok": false, "error": "owner"}
	return {"ok": true, "balance": int(db.query_result[0].yang)}

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
	if not db.query_with_bindings("UPDATE wallets SET yang=yang-? WHERE character_id=? AND yang>=?;", [cost, owner_id, cost]):
		return {"ok": false, "error": "storage"}
	if not db.query("SELECT changes() AS n;"): return {"ok": false, "error": "storage"}
	if int(db.query_result[0].n) != 1: return {"ok": false, "error": "funds"}
	return {"ok": true, "balance": int(income.balance) - cost}

func _apply_income(owner_id: int, amount: int) -> Dictionary:
	if amount < 0 or amount > MAX_YANG: return {"ok": false, "error": "request"}
	if not db.query_with_bindings("UPDATE wallets SET yang=yang+? WHERE character_id=?;", [amount, owner_id]):
		return {"ok": false, "error": "storage"}
	if not db.query("SELECT changes() AS n;"): return {"ok": false, "error": "storage"}
	if int(db.query_result[0].n) != 1: return {"ok": false, "error": "owner"}
	if not db.query_with_bindings("SELECT yang FROM wallets WHERE character_id=?;", [owner_id]):
		return {"ok": false, "error": "storage"}
	return {"ok": true, "balance": int(db.query_result[0].yang)}

func _rollback(reason: String) -> Dictionary:
	db.query("ROLLBACK;")
	return {"ok": false, "error": reason}
