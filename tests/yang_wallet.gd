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
	check(db.query_with_bindings("SELECT yang FROM account_wallets WHERE account_id=(SELECT a.master_account_id FROM accounts a JOIN players p ON p.account_name=a.account_name WHERE p.player_id=?);", [owner]), "read balance")
	return int(db.query_result[0].yang)

func _ready() -> void:
	test_account_migration()
	var db := SQLite.new()
	db.path = "res://.godot/verification/yang-wallet-%s.db" % Crypto.new().generate_random_bytes(8).hex_encode()
	check(db.open_db(), "open")
	WorldSchema.ensure_schema(db)
	var store := WorldStoreSqlite.new(db)
	var a: int = EconomyFixture.create_character(store,"yang_a", {"name": "A", "skin": 1})
	var b: int = EconomyFixture.create_character(store,"yang_b", {"name": "B", "skin": 1})
	var c: int = EconomyFixture.create_character(store,"yang_c", {"name": "C", "skin": 1})
	check(persisted(db,a) == 1500 and persisted(db,b) == 1500, "new characters receive starting Yang")
	var alt: int = EconomyFixture.create_character(store,"yang_a",{"name":"Alt","skin":1})
	check(persisted(db,alt)==1500,"creating an alt does not grant extra Yang")
	check(WalletStoreSqlite.new(db).load_wallet(store.resolve_account_id(a)).balance == 1500, "reloading does not repeat starting grant")
	check(db.query_with_bindings("UPDATE account_wallets SET yang=100000 WHERE account_id=?;",[store.resolve_account_id(a)]),"seed first account")
	check(db.query_with_bindings("UPDATE account_wallets SET yang=40000 WHERE account_id=?;",[store.resolve_account_id(b)]),"seed second account")
	check(db.query_with_bindings("UPDATE account_wallets SET yang=0 WHERE account_id=?;",[store.resolve_account_id(c)]),"explicit zero fixture")
	var persistence := WorldDatabase.new()
	persistence.db = db
	persistence.store = store
	var wallets := CountingWalletStore.new(db)
	persistence.wallet_store = wallets
	add_child(persistence)
	persistence.set_process(false)
	EconomyFixture.prepare(persistence)
	check(persistence.load_wallet(a) and persistence.load_wallet(b) and persistence.load_wallet(c), "load and lazy initialize")
	check(not persistence.load_wallet(999999), "cannot create wallet without character")
	for amount: int in [30,42,18]: check(persistence.add_yang(a, amount), "runtime income")
	check(persistence.wallet_balance(a) == 100090 and persistence.runtime_wallets[persistence.wallet_account_id(a)].pending_currency_delta == 90, "RAM aggregates income")
	check(persistence.load_wallet(alt) and persistence.wallet_balance(alt)==100090,"alt shares authoritative account RAM")
	check(persisted(db,a) == 100000 and wallets.batches == 0 and wallets.spends == 0, "no per-pickup writes")
	persistence._process(29.0)
	check(wallets.batches == 0, "no early checkpoint")
	persistence._process(1.0)
	check(wallets.batches == 1 and wallets.writes == 1 and persisted(db,a) == 100090 and persistence.dirty_wallet.is_empty(), "30s saves only dirty delta")
	persistence._process(30.0)
	check(wallets.batches == 1, "clean checkpoint has no transaction")
	check(persistence.add_yang(a,10) and persistence.add_yang(b,30000), "pending income before critical spend")
	check(db.query("CREATE TEMP TRIGGER fail_spend BEFORE UPDATE ON account_wallets WHEN NEW.yang<OLD.yang BEGIN SELECT RAISE(ABORT,'intentional spend failure'); END;"), "fail spend after income application")
	check(not persistence.spend_yang(b,50000).ok, "spend failure")
	check(persisted(db,b) == 40000 and persistence.wallet_balance(b) == 70000 and persistence.runtime_wallets[persistence.wallet_account_id(b)].pending_currency_delta == 30000 and persistence.dirty_wallet.has(persistence.wallet_account_id(b)), "rollback keeps DB and pending income")
	check(db.query("DROP TRIGGER fail_spend;"), "remove fault")
	check(persistence.spend_yang(b,50000).ok and persisted(db,b) == 20000 and persistence.wallet_balance(b) == 20000 and persistence.runtime_wallets[persistence.wallet_account_id(b)].pending_currency_delta == 0 and not persistence.dirty_wallet.has(persistence.wallet_account_id(b)), "40000 + pending 30000 - 50000 atomic commit")
	check(not persistence.spend_yang(b,20001).ok and persisted(db,b) == 20000 and wallets.spends == 2, "RAM affordability rejects before SQL")
	check(persistence.add_yang(b,25), "new pending")
	check(db.query("CREATE TEMP TRIGGER fail_batch BEFORE UPDATE ON account_wallets WHEN NEW.account_id=%d BEGIN SELECT RAISE(ABORT,'intentional wallet checkpoint failure'); END;" % store.resolve_account_id(b)), "fail batch second row")
	check(not persistence.flush_wallet(), "checkpoint failure returned")
	check(persisted(db,a) == 100090 and persisted(db,b) == 20000 and persistence.dirty_wallet.size() == 2, "whole dirty batch rolled back")
	persistence.release_wallet(b)
	check(persistence.runtime_wallets.has(persistence.wallet_account_id(b)) and persistence.load_wallet(b) and persistence.wallet_balance(b) == 20025, "failed disconnect retains authoritative wallet for relog")
	check(db.query("DROP TRIGGER fail_batch;"), "remove batch fault")
	# Prove a delta write preserves an independently changed durable balance.
	check(db.query_with_bindings("UPDATE account_wallets SET yang=yang+7 WHERE account_id=(SELECT a.master_account_id FROM accounts a JOIN players p ON p.account_name=a.account_name WHERE p.player_id=?);",[a]), "durable delta fixture")
	check(persistence.save_all_connected({}) == 0, "shutdown flushes offline dirty wallets")
	check(persisted(db,a) == 100107 and persisted(db,b) == 20025 and persistence.dirty_wallet.is_empty(), "delta rather than stale snapshot and no duplicate spend income")
	persistence.release_wallet(b)
	check(not persistence.runtime_wallets.has(persistence.wallet_account_id(b)) and persistence.load_wallet(b) and persistence.wallet_balance(b) == 20025, "relog reloads wallet")
	check(not persistence.add_yang(a,-1) and not persistence.add_yang(a,WalletStoreSqlite.MAX_YANG), "income validation and overflow cap")
	check(persistence.add_yang(c,30), "crash-window income")
	persistence.runtime_wallets.erase(persistence.wallet_account_id(c))
	persistence.dirty_wallet.erase(persistence.wallet_account_id(c))
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
		result = wallets.spend_in_transaction(WorldStoreSqlite.new(db).resolve_account_id(owner), pending, cost)
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
	check(db.query_with_bindings("UPDATE account_wallets SET yang=100 WHERE account_id=(SELECT a.master_account_id FROM accounts a JOIN players p ON p.account_name=a.account_name WHERE p.player_id=?);", [owner]), "purchase wallet fixture")
	check(items.resolve_inventory_position(owner, 2, 40).error == "request", "exact footprint cannot cross page")
	check(items.resolve_inventory_position(owner, 1, -2).error == "request", "invalid requested sentinel")
	check(purchase_fixture(db, owner, 30, 50, 10).ok, "purchase item and pending-income spend commit")
	var before: Dictionary = items.inventory(owner)
	check(before.items.size() == 1 and before.items[0].bag_position == 10 and persisted(db, owner) == 80, "exact purchase and wallet committed together")
	check(purchase_fixture(db, owner, 30, 50, 10).error == "occupied" and persisted(db, owner) == 80 and items.inventory(owner) == before, "exact occupied never falls back or charges")
	check(db.query("CREATE TEMP TRIGGER fail_purchase BEFORE INSERT ON item_custody BEGIN SELECT RAISE(ABORT,'purchase placement failure'); END;"), "fault after wallet deduction and item creation")
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
	check(db.query("CREATE TEMP TRIGGER reject_full_charge BEFORE UPDATE ON account_wallets BEGIN SELECT RAISE(ABORT,'capacity must precede wallet writes'); END;"), "detect wallet write before full check")
	check(purchase_fixture(db, owner, 30, 20).error == "inventory_full", "capacity rejects before any wallet write")
	check(db.query("DROP TRIGGER reject_full_charge;"), "remove capacity ordering fault")
	check(persisted(db, owner) == 60 and items.inventory(owner) == before, "full purchase never charges or creates item")
	check(db.close_db() and db.open_db() and persisted(db, owner) == 60 and items.inventory(owner) == before, "purchase durable after reopen")

# New contract: sum old wallets once, share account state, reject orphan/overflow,
# preserve pending income across critical online/offline credits and reentry.
func test_account_migration() -> void:
	var db := SQLite.new()
	db.path = "res://.godot/verification/yang-wallet-migration-%s.db" % Crypto.new().generate_random_bytes(8).hex_encode()
	assert(db.open_db())
	WorldSchema.ensure_schema(db)
	var store := WorldStoreSqlite.new(db)
	assert(db.query("INSERT INTO accounts(account_name) VALUES('alpha'),('beta');"))
	for id: int in 4:
		var player := PlayerResource.new()
		player.init(id+1,"alpha" if id<2 else "beta","Legacy"+str(id),1)
		store.save_player(player)
	assert(db.query("INSERT INTO wallets(character_id,yang) VALUES(1,100000),(2,20000),(3,700),(4,300);"))
	assert(not WalletStoreSqlite.migrate_accounts(db,{"alpha":21}).ok,"missing Master mapping is never guessed")
	var master := {"alpha":21,"beta":22}
	assert(db.query("CREATE TRIGGER reject_v18 BEFORE INSERT ON meta WHEN NEW.value='18' BEGIN SELECT RAISE(ABORT,'migration commit fault'); END;"))
	assert(not WalletStoreSqlite.migrate_accounts(db,master).ok)
	assert(db.query("SELECT COUNT(*) AS n FROM wallets;") and db.query_result[0].n==4,"rollback preserves all legacy balances")
	assert(db.query("SELECT COUNT(*) AS n FROM accounts WHERE master_account_id IS NOT NULL;") and db.query_result[0].n==0,"rollback preserves unbound identities")
	assert(db.query("DROP TRIGGER reject_v18; UPDATE wallets SET yang=9000000000000000 WHERE character_id=1;"))
	assert(not WalletStoreSqlite.migrate_accounts(db,master).ok,"account sum above cap rejects the entire migration")
	assert(db.query("UPDATE wallets SET yang=100000 WHERE character_id=1;"))
	assert(WalletStoreSqlite.migrate_accounts(db,master).ok)
	assert(WalletStoreSqlite.migrate_accounts(db,master).already_migrated)
	assert(db.close_db() and db.open_db())
	WorldSchema.ensure_schema(db)
	assert(WalletStoreSqlite.migrate_accounts(db,master).already_migrated)
	assert(db.query("SELECT SUM(yang) AS total FROM account_wallets;") and db.query_result[0].total==121000,"migration conserves total Yang exactly once")
	assert(db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='wallets';") and db.query_result.is_empty(),"no second wallet authority")
	var persistence := WorldDatabase.new()
	persistence.db = db
	persistence.store = store
	persistence.wallet_store = WalletStoreSqlite.new(db)
	assert(persistence.prepare_account_wallets(master).ok)
	assert(persistence.load_wallet(1) and persistence.load_wallet(2) and persistence.load_wallet(3))
	assert(persistence.runtime_wallets.size()==2 and persistence.runtime_wallets.has(21) and not persistence.runtime_wallets.has(1),"RAM keys are Master IDs, not character IDs")
	assert(persistence.wallet_balance(1)==120000 and persistence.wallet_balance(2)==120000 and persistence.wallet_balance(3)==1000)
	assert(persistence.add_yang(1,100) and persistence.wallet_balance(2)==120100)
	assert(persistence.credit_account(21,200).ok,"critical online credit incorporates pending income atomically")
	assert(persistence.wallet_balance(2)==120300 and persistence.flush_wallet() and persistence.wallet_balance(3)==1000)
	assert(persistence.spend_yang(2,70).ok and persistence.wallet_balance(1)==120230,"another alt spends the same wallet")
	assert(persistence.add_yang(2,20) and persistence.flush_character(2))
	persistence.release_wallet(2)
	assert(persistence.credit_account(21,200).ok,"offline seller credit updates SQL without resurrecting stale RAM")
	assert(persistence.load_wallet(1) and persistence.wallet_balance(1)==120450)
	assert(persistence.add_yang(1,50))
	assert(db.query("CREATE TEMP TRIGGER fail_account_credit BEFORE UPDATE ON account_wallets BEGIN SELECT RAISE(ABORT,'credit fault'); END;"))
	assert(not persistence.credit_account(21,100).ok and persistence.wallet_balance(2)==120500,"failed credit retains pending RAM unchanged")
	assert(db.query("DROP TRIGGER fail_account_credit;"))
	assert(persistence.flush_wallet(1))
	assert(db.query("PRAGMA query_only=ON;") and WalletStoreSqlite.migrate_accounts(db,master).already_migrated,"completed migration can be checked on read-only DB")
	persistence.db = null
	persistence.free()
	assert(db.close_db())
	DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path))
