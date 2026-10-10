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
	check(persisted(db,a) == 1500 and persisted(db,b) == 1500, "new characters receive starting Yang")
	check(WalletStoreSqlite.new(db).load_wallet(a).balance == 1500, "reloading does not repeat starting grant")
	check(db.query("DROP TABLE wallets;"), "v13 fixture")
	check(db.query("UPDATE meta SET value='13' WHERE key='schema_version';"), "v13 marker")
	WorldSchema.ensure_schema(db)
	check(db.query("SELECT value FROM meta WHERE key='schema_version';") and int(db.query_result[0].value) == 16, "wallet migration v14")
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
	test_purchase_contract(db, c)
	db.close_db()
	if not failed:
		print("WALLET_OK: RAM income, dirty delta batch, critical spend rollback/commit, offline save, relog and crash window")
		get_tree().quit()

# Transaction contract fixture with a server-defined item and test cost. Real
# Shop validates its offer/price inside this transaction and publishes RAM after commit.
func purchase_fixture(db: SQLite, owner: int, pending: int, cost: int, requested: int = -1) -> Dictionary:
	var items := ItemStoreSqlite.new(db)
	var wallets := WalletStoreSqlite.new(db)
	var item: ItemInstance = ItemInstance.create(ItemDefinitions.IRON_SWORD, owner, [])
	if not db.query("BEGIN IMMEDIATE;"): return {"ok": false, "error": "storage"}
	var result: Dictionary = items.resolve_inventory_position(owner, ItemDefinitions.IRON_SWORD.inventory_height, requested)
	if result.ok:
		var position: int = result.position
		result = wallets.spend_in_transaction(owner, pending, cost)
		if result.ok:
			var receiving: Dictionary = items.receive_item_in_transaction(item, position)
			if not receiving.ok: result = receiving
	if not result.ok:
		db.query("ROLLBACK;")
		return result
	if not db.query("COMMIT;"):
		db.query("ROLLBACK;")
		return {"ok": false, "error": "storage"}
	return result

func test_purchase_contract(db: SQLite, owner: int) -> void:
	var items := ItemStoreSqlite.new(db)
	check(db.query_with_bindings("UPDATE wallets SET yang=100 WHERE character_id=?;", [owner]), "purchase wallet fixture")
	check(items.resolve_inventory_position(owner, 2, 40).error == "request", "exact footprint cannot cross page")
	check(items.resolve_inventory_position(owner, 1, -2).error == "request", "invalid requested sentinel")
	check(purchase_fixture(db, owner, 30, 50, 10).ok, "purchase item and pending-income spend commit")
	var before: Dictionary = items.inventory(owner)
	check(before.items.size() == 1 and before.items[0].bag_position == 10 and persisted(db, owner) == 80, "exact purchase and wallet committed together")
	check(purchase_fixture(db, owner, 30, 50, 10).error == "occupied" and persisted(db, owner) == 80 and items.inventory(owner) == before, "exact occupied never falls back or charges")
	check(db.query("CREATE TEMP TRIGGER fail_purchase BEFORE INSERT ON item_placements BEGIN SELECT RAISE(ABORT,'purchase placement failure'); END;"), "fault after wallet deduction and item creation")
	check(not purchase_fixture(db, owner, 30, 50).ok and persisted(db, owner) == 80 and items.inventory(owner) == before, "item write failure rolls back charge pending income and item")
	check(db.query_with_bindings("SELECT COUNT(*) AS n FROM item_instances WHERE owner_character_id=?;", [owner]) and int(db.query_result[0].n) == 1, "failed purchase leaves no orphan item instance")
	check(db.query("DROP TRIGGER fail_purchase;"), "remove purchase fault")
	check(purchase_fixture(db, owner, 0, 81).error == "funds" and items.inventory(owner) == before and persisted(db, owner) == 80, "insufficient funds cannot create item")
	check(purchase_fixture(db, owner, 0, 20).ok and persisted(db, owner) == 60, "automatic receiving commits")
	check(items.inventory(owner).items[0].bag_position == 0, "automatic receiving first fitting cell")
	# Exhaust fitting 1x2 footprints, including fragmented last rows.
	for attempt: int in InventoryGrid.CAPACITY:
		var filler: ItemInstance = ItemInstance.create(ItemDefinitions.IRON_SWORD, owner, [])
		check(db.query("BEGIN IMMEDIATE;"), "fill transaction")
		var receiving: Dictionary = items.receive_item_in_transaction(filler)
		if not receiving.ok:
			check(receiving.error == "inventory_full", "only capacity terminates fill")
			db.query("ROLLBACK;")
			break
		check(db.query("COMMIT;"), "fill capacity")
	before = items.inventory(owner)
	check(db.query("CREATE TEMP TRIGGER reject_full_charge BEFORE UPDATE ON wallets BEGIN SELECT RAISE(ABORT,'capacity must precede wallet writes'); END;"), "detect wallet write before full check")
	check(purchase_fixture(db, owner, 30, 20).error == "inventory_full", "capacity rejects before any wallet write")
	check(db.query("DROP TRIGGER reject_full_charge;"), "remove capacity ordering fault")
	check(persisted(db, owner) == 60 and items.inventory(owner) == before, "full purchase never charges or creates item")
	check(db.close_db() and db.open_db() and persisted(db, owner) == 60 and items.inventory(owner) == before, "purchase durable after reopen")
