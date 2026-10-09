extends Node
var failed: bool = false
class CountingWalletStore extends WalletStoreSqlite:
	var batches: int = 0
	var writes: int = 0
	var spends: int = 0
	func checkpoint(deltas: Dictionary) -> Dictionary:
		batches += 1
		writes += deltas.size()
		return super.checkpoint(deltas)
	func spend(owner_id: int, pending_income: int, cost: int) -> Dictionary:
		spends += 1
		return super.spend(owner_id, pending_income, cost)

func check(ok: bool, message: String) -> void:
	if not ok:
		failed = true
		push_error("WALLET_FAILED: " + message)
		get_tree().quit(1)

func persisted(db: SQLite, owner: int) -> int:
	check(db.query_with_bindings("SELECT yang FROM wallets WHERE character_id=?;", [owner]), "read balance")
	return int(db.query_result[0].yang)

func _ready() -> void:
	var db := SQLite.new()
	db.path = "res://.godot/verification/yang-wallet-%s.db" % Crypto.new().generate_random_bytes(8).hex_encode()
	check(db.open_db(), "open")
	WorldSchema.ensure_schema(db)
	var store := WorldStoreSqlite.new(db)
	var a: int = store.create_player_character("yang_a", {"name": "A", "skin": 1})
	var b: int = store.create_player_character("yang_b", {"name": "B", "skin": 1})
	var c: int = store.create_player_character("yang_c", {"name": "C", "skin": 1})
	check(db.query("DROP TABLE wallets;"), "v13 fixture")
	check(db.query("UPDATE meta SET value='13' WHERE key='schema_version';"), "v13 marker")
	WorldSchema.ensure_schema(db)
	check(db.query("SELECT value FROM meta WHERE key='schema_version';") and int(db.query_result[0].value) == 15, "wallet migration v14")
	check(db.query_with_bindings("INSERT INTO wallets VALUES(?,100000),(?,40000);", [a,b]), "initial balances")
	var persistence := WorldDatabase.new()
	persistence.db = db
	persistence.store = store
	var wallets := CountingWalletStore.new(db)
	persistence.wallet_store = wallets
	add_child(persistence)
	persistence.set_process(false)
	check(persistence.load_wallet(a) and persistence.load_wallet(b) and persistence.load_wallet(c), "load and lazy initialize")
	check(not persistence.load_wallet(999999), "cannot create wallet without character")
	for amount: int in [30,42,18]: check(persistence.add_yang(a, amount), "runtime income")
	check(persistence.wallet_balance(a) == 100090 and persistence.runtime_wallets[a].pending_currency_delta == 90, "RAM aggregates income")
	check(persisted(db,a) == 100000 and wallets.batches == 0 and wallets.spends == 0, "no per-pickup writes")
	persistence._process(29.0)
	check(wallets.batches == 0, "no early checkpoint")
	persistence._process(1.0)
	check(wallets.batches == 1 and wallets.writes == 1 and persisted(db,a) == 100090 and persistence.dirty_wallet.is_empty(), "30s saves only dirty delta")
	persistence._process(30.0)
	check(wallets.batches == 1, "clean checkpoint has no transaction")
	check(persistence.add_yang(a,10) and persistence.add_yang(b,30000), "pending income before critical spend")
	check(db.query("CREATE TEMP TRIGGER fail_spend BEFORE UPDATE ON wallets WHEN NEW.yang<OLD.yang BEGIN SELECT RAISE(ABORT,'intentional spend failure'); END;"), "fail spend after income application")
	check(not persistence.spend_yang(b,50000).ok, "spend failure")
	check(persisted(db,b) == 40000 and persistence.wallet_balance(b) == 70000 and persistence.runtime_wallets[b].pending_currency_delta == 30000 and persistence.dirty_wallet.has(b), "rollback keeps DB and pending income")
	check(db.query("DROP TRIGGER fail_spend;"), "remove fault")
	check(persistence.spend_yang(b,50000).ok and persisted(db,b) == 20000 and persistence.wallet_balance(b) == 20000 and persistence.runtime_wallets[b].pending_currency_delta == 0 and not persistence.dirty_wallet.has(b), "40000 + pending 30000 - 50000 atomic commit")
	check(not persistence.spend_yang(b,20001).ok and persisted(db,b) == 20000 and wallets.spends == 2, "RAM affordability rejects before SQL")
	check(persistence.add_yang(b,25), "new pending")
	check(db.query("CREATE TEMP TRIGGER fail_batch BEFORE UPDATE ON wallets WHEN NEW.character_id=%d BEGIN SELECT RAISE(ABORT,'intentional wallet checkpoint failure'); END;" % b), "fail batch second row")
	check(not persistence.flush_wallet(), "checkpoint failure returned")
	check(persisted(db,a) == 100090 and persisted(db,b) == 20000 and persistence.dirty_wallet.size() == 2, "whole dirty batch rolled back")
	persistence.release_wallet(b)
	check(persistence.runtime_wallets.has(b) and persistence.load_wallet(b) and persistence.wallet_balance(b) == 20025, "failed disconnect retains authoritative wallet for relog")
	check(db.query("DROP TRIGGER fail_batch;"), "remove batch fault")
	# Prove a delta write preserves an independently changed durable balance.
	check(db.query_with_bindings("UPDATE wallets SET yang=yang+7 WHERE character_id=?;",[a]), "durable delta fixture")
	check(persistence.save_all_connected({}) == 0, "shutdown flushes offline dirty wallets")
	check(persisted(db,a) == 100107 and persisted(db,b) == 20025 and persistence.dirty_wallet.is_empty(), "delta rather than stale snapshot and no duplicate spend income")
	persistence.release_wallet(b)
	check(not persistence.runtime_wallets.has(b) and persistence.load_wallet(b) and persistence.wallet_balance(b) == 20025, "relog reloads wallet")
	check(not persistence.add_yang(a,-1) and not persistence.add_yang(a,WalletStoreSqlite.MAX_YANG), "income validation and overflow cap")
	check(persistence.add_yang(c,30), "crash-window income")
	persistence.runtime_wallets.erase(c)
	persistence.dirty_wallet.erase(c)
	check(persistence.load_wallet(c) and persistence.wallet_balance(c) == 0, "crash restores checkpoint without ground receipt replay")
	check(db.close_db() and db.open_db() and persisted(db,b) == 20025, "reopen durable balance")
	db.close_db()
	if not failed:
		print("WALLET_OK: RAM income, dirty delta batch, critical spend rollback/commit, offline save, relog and crash window")
		get_tree().quit()
