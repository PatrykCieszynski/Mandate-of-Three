extends Node
var failed: bool = false
func check(ok: bool, message: String) -> void:
	if not ok:
		failed = true
		push_error("SHOP_FAILED: " + message)
		get_tree().quit(1)
func balance(db: SQLite, owner: int) -> int:
	check(db.query_with_bindings("SELECT yang FROM wallets WHERE character_id=?;",[owner]), "balance query")
	return int(db.query_result[0].yang)
func _ready() -> void:
	var shop: ShopDefinition = ShopDefinitions.BLACKSMITH_WEAPONS
	var offer: ShopOfferDefinition = shop.offers[0]
	var bad: ShopOfferDefinition = offer.duplicate(true)
	bad.price = 0
	check("invalid_price" in bad.validation_errors(), "free offers rejected")
	bad.price = offer.price
	bad.quantity = ItemDefinitions.IRON_SWORD.stack_limit + 1
	check("invalid_quantity" in bad.validation_errors(), "offer cannot exceed stack limit")
	var db := SQLite.new()
	db.path = "res://.godot/verification/shop-purchase-%s.db" % Crypto.new().generate_random_bytes(8).hex_encode()
	check(db.open_db(), "open fixture")
	WorldSchema.ensure_schema(db)
	var persistence := WorldDatabase.new()
	persistence.db = db
	persistence.store = WorldStoreSqlite.new(db)
	persistence.item_store = ItemStoreSqlite.new(db)
	persistence.wallet_store = WalletStoreSqlite.new(db)
	var owner: int = persistence.store.create_player_character("shop_fixture", {"name":"Buyer", "skin":1})
	check(persistence.load_wallet(owner), "load wallet")
	check(db.query_with_bindings("UPDATE wallets SET yang=400 WHERE character_id=?;",[owner]), "seed wallet")
	persistence.runtime_wallets.erase(owner)
	check(persistence.load_wallet(owner) and persistence.add_yang(owner,1700), "pending income")
	var items: ItemStoreSqlite = persistence.item_store
	check(persistence.purchase_shop_offer(owner,shop,&"missing").error == "unknown_offer", "unknown offer")
	check(persistence.purchase_shop_offer(owner,shop,offer.offer_id,40).error == "request", "invalid exact footprint")
	var result: Dictionary = persistence.purchase_shop_offer(owner,shop,offer.offer_id,10)
	check(result.ok and result.position == 10 and result.balance == 1100, "400 persisted + 1700 pending - 1000")
	var before: Dictionary = items.inventory(owner)
	check(before.items.size()==1 and before.items[0].uid==result.uid and before.items[0].owner_character_id==owner and before.items[0].definition_id==str(offer.item_definition_id) and before.items[0].amount==offer.quantity, "authoritative purchased item identity/quantity")
	check(balance(db,owner)==1100 and persistence.wallet_balance(owner)==1100 and persistence.runtime_wallets[owner].pending_currency_delta==0 and not persistence.dirty_wallet.has(owner), "commit accepts wallet and clears delta")
	check(persistence.add_yang(owner,30), "pending income before rejection")
	check(persistence.purchase_shop_offer(owner,shop,offer.offer_id,10).error=="occupied", "exact occupied never falls back")
	check(balance(db,owner)==1100 and items.inventory(owner)==before and persistence.wallet_balance(owner)==1130 and persistence.runtime_wallets[owner].pending_currency_delta==30 and persistence.dirty_wallet.has(owner), "failed purchase preserves RAM delta and items")
	check(db.query("CREATE TEMP TRIGGER shop_fail_item BEFORE INSERT ON item_placements BEGIN SELECT RAISE(ABORT,'shop item failure'); END;"), "item fault")
	check(persistence.purchase_shop_offer(owner,shop,offer.offer_id).error=="storage", "insertion fault returned")
	check(balance(db,owner)==1100 and items.inventory(owner)==before and persistence.runtime_wallets[owner].pending_currency_delta==30, "item failure rolls back pending income and spending")
	check(db.query_with_bindings("SELECT COUNT(*) AS n FROM item_instances WHERE owner_character_id=?;",[owner]) and int(db.query_result[0].n)==1, "no orphan item")
	check(db.query("DROP TRIGGER shop_fail_item;"), "remove item fault")
	check(db.query("CREATE TEMP TRIGGER shop_fail_wallet BEFORE UPDATE ON wallets BEGIN SELECT RAISE(ABORT,'shop wallet failure'); END;"), "wallet fault")
	check(persistence.purchase_shop_offer(owner,shop,offer.offer_id).error=="storage" and items.inventory(owner)==before, "wallet failure creates no item")
	check(db.query("DROP TRIGGER shop_fail_wallet;"), "remove wallet fault")
	result = persistence.purchase_shop_offer(owner,shop,offer.offer_id)
	check(result.ok and result.position==0 and result.balance==130, "first fit and pending income committed")
	before=items.inventory(owner)
	check(persistence.purchase_shop_offer(owner,shop,offer.offer_id).error=="funds" and items.inventory(owner)==before and balance(db,owner)==130, "insufficient funds no item/no charge")
	var overflow: ItemInstance = ItemInstance.create(ItemDefinitions.IRON_SWORD,owner,[])
	overflow.amount = ItemDefinitions.IRON_SWORD.stack_limit + 1
	check(db.query("BEGIN IMMEDIATE;"), "overflow begin")
	check(not items.receive_item_in_transaction(overflow).ok, "item insertion independently enforces stack limit")
	check(db.query("ROLLBACK;"), "overflow rollback")
	for attempt: int in InventoryGrid.CAPACITY:
		check(db.query("BEGIN IMMEDIATE;"), "fill begin")
		var fill: Dictionary = items.receive_item_in_transaction(ItemInstance.create(ItemDefinitions.IRON_SWORD,owner,[]))
		if not fill.ok:
			check(fill.error=="inventory_full", "fill ends on capacity")
			db.query("ROLLBACK;")
			break
		check(db.query("COMMIT;"), "fill commit")
	check(persistence.add_yang(owner,1000), "pending for full inventory")
	before=items.inventory(owner)
	check(db.query("CREATE TEMP TRIGGER shop_capacity_first BEFORE UPDATE ON wallets BEGIN SELECT RAISE(ABORT,'wallet must not be touched'); END;"), "capacity ordering trigger")
	check(persistence.purchase_shop_offer(owner,shop,offer.offer_id).error=="inventory_full", "capacity before wallet writes")
	check(db.query("DROP TRIGGER shop_capacity_first;"), "remove capacity fault")
	check(items.inventory(owner)==before and balance(db,owner)==130 and persistence.runtime_wallets[owner].pending_currency_delta==1000, "full preserves item and wallet state")
	check(db.close_db() and db.open_db() and items.inventory(owner)==before and balance(db,owner)==130, "committed purchases survive reopening database")
	db.close_db()
	persistence.free()
	if not failed:
		print("SHOP_PURCHASE_OK: authoritative offers, exact/first-fit, capacity, stack limits, pending income, rollback and durability")
		get_tree().quit()
