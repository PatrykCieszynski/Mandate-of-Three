extends Node
var failed: bool = false
func check(ok: bool, message: String) -> void:
	if not ok:
		failed = true
		push_error("SHOP_FAILED: " + message)
		get_tree().quit(1)
func balance(db: SqliteSoci, owner: int) -> int:
	check(db.query_with_bindings("SELECT yang FROM account_wallets WHERE account_id=(SELECT a.master_account_id FROM accounts a JOIN players p ON p.account_name=a.account_name WHERE p.player_id=?);",[owner]), "balance query")
	return int(db.query_result[0].yang)
func _ready() -> void:
	await _test_journal()
	var shop: ShopDefinition = ShopDefinitions.BLACKSMITH_WEAPONS
	var offer: ShopOfferDefinition = shop.offers[0]
	var bad: ShopOfferDefinition = offer.duplicate(true)
	bad.price = 0
	check("invalid_price" in bad.validation_errors(), "free offers rejected")
	bad.price = offer.price
	bad.quantity = ItemDefinitions.IRON_SWORD.stack_limit + 1
	check("invalid_quantity" in bad.validation_errors(), "offer cannot exceed stack limit")
	var db := SqliteSoci.new()
	db.path = "res://.godot/verification/shop-purchase-%s.db" % Crypto.new().generate_random_bytes(8).hex_encode()
	check(db.open_db(), "open fixture")
	WorldSchema.ensure_schema(db)
	var persistence := WorldDatabase.new()
	persistence.db = db
	persistence.store = WorldStoreSqlite.new(db)
	persistence.item_store = ItemStoreSqlite.new(db)
	persistence.wallet_store = WalletStoreSqlite.new(db)
	var owner: int = EconomyFixture.create_character(persistence.store,"shop_fixture", {"name":"Buyer", "skin":1})
	EconomyFixture.prepare(persistence)
	check(persistence.load_wallet(owner), "load wallet")
	var context := persistence.economic_context(owner)
	var another_binding := WorldDatabase.new()
	another_binding.db = db
	another_binding.store = persistence.store
	check(context == another_binding.economic_context(owner) and ItemInstance.valid_uid(context.authority_id), "economy identity is persistent across bindings")
	WorldSchema.ensure_schema(db)
	check(db.query("SELECT value FROM meta WHERE key='economy_authority_id';") and db.query_result[0].value == context.authority_id, "schema initialization preserves economy identity")
	another_binding.free()
	check(db.query_with_bindings("UPDATE account_wallets SET yang=400 WHERE account_id=(SELECT a.master_account_id FROM accounts a JOIN players p ON p.account_name=a.account_name WHERE p.player_id=?);",[owner]), "seed wallet")
	persistence.runtime_wallets.erase(persistence.wallet_account_id(owner))
	check(persistence.load_wallet(owner) and persistence.add_yang(owner,1700), "pending income")
	var items: ItemStoreSqlite = persistence.item_store
	check(persistence.purchase_shop_operation(owner, shop, offer.offer_id).response().error == "request", "purchase requires explicit stable intention identity")
	check(persistence.purchase_shop_offer(owner,shop,&"missing", -1, "shop-fixture-1").error == "unknown_offer", "unknown offer")
	check(persistence.purchase_shop_offer(owner,shop,offer.offer_id,40, "shop-fixture-2").error == "request", "invalid exact footprint")
	var operation := persistence.purchase_shop_operation(owner, shop, offer.offer_id, 10, "shop-fixture-3")
	var result := operation.response()
	check(operation.action == "npc_shop.buy" and operation.character_id == owner and operation.account_id == persistence.wallet_account_id(owner), "purchase result carries trusted character/account context")
	check(operation.new_commit and not operation.receipt_replay and operation.changed_accounts == PackedInt64Array([operation.account_id]), "committed purchase reports one changed account")
	check(operation.operation_id == "shop-fixture-3", "purchase carries an explicit business intention, separate from RPC correlation")
	check(result.ok and result.position == 10 and result.balance == 1100, "400 persisted + 1700 pending - 1000")
	var before: Dictionary = items.inventory(owner)
	check(before.items.size()==1 and before.items[0].uid==result.uid and before.items[0].owner_character_id==owner and before.items[0].definition_id==str(offer.item_definition_id) and before.items[0].amount==offer.quantity, "authoritative purchased item identity/quantity")
	check(balance(db,owner)==1100 and persistence.wallet_balance(owner)==1100 and persistence.runtime_wallets[persistence.wallet_account_id(owner)].pending_currency_delta==0 and not persistence.dirty_wallet.has(persistence.wallet_account_id(owner)), "commit accepts wallet and clears delta")
	check(persistence.add_yang(owner,30), "pending income before rejection")
	var replay := persistence.purchase_shop_operation(owner, shop, offer.offer_id, 10, operation.operation_id)
	check(replay.receipt_replay and not replay.new_commit and replay.changed_accounts.is_empty() and replay.response() == result, "same intention returns identical durable purchase result without another commit")
	check(items.inventory(owner) == before and persistence.wallet_balance(owner) == 1130 and persistence.runtime_wallets[operation.account_id].pending_currency_delta == 30, "replay neither creates another UID nor overwrites new pending income with receipt balance")
	var lookup := persistence.shop_purchase_receipt(owner, operation.operation_id)
	check(lookup.response() == result and not lookup.new_commit and not lookup.receipt_replay and lookup.changed_accounts.is_empty(), "receipt-only lookup returns the committed result without mutation semantics")
	check(persistence.shop_purchase_receipt(owner, "missing-purchase").response().error == "unknown_command" and items.inventory(owner) == before, "unknown receipt does not admit or execute a purchase")
	var conflict := persistence.purchase_shop_operation(owner, shop, offer.offer_id, 11, operation.operation_id)
	check(conflict.response().error == "command_conflict" and not conflict.new_commit, "same ID with changed placement conflicts")
	var alternate := EconomyFixture.create_character(persistence.store, "shop_fixture", {"name":"Alternate", "skin":1})
	conflict = persistence.purchase_shop_operation(alternate, shop, offer.offer_id, 10, operation.operation_id)
	check(conflict.response().error == "command_conflict" and not conflict.new_commit, "same account cannot replay the purchase into another character inventory")
	check(persistence.shop_purchase_receipt(alternate, operation.operation_id).response().error == "unknown_command", "receipt lookup cannot cross receiving characters on the same account")
	var stranger := EconomyFixture.create_character(persistence.store, "shop_stranger", {"name":"Stranger", "skin":1})
	check(persistence.shop_purchase_receipt(stranger, operation.operation_id).response().error == "unknown_command", "receipt lookup cannot cross accounts")
	check(db.query_with_bindings("INSERT INTO market_commands(account_id,command_id,kind,request_json,result_json) VALUES(?,?,?,?,?);", [operation.account_id,"other-kind","market.fixture","[]",JSON.stringify({"ok":true})]), "seed unrelated command receipt")
	check(persistence.shop_purchase_receipt(owner, "other-kind").response().error == "unknown_command", "NPC receipt lookup cannot return another command kind")
	check(persistence.purchase_shop_offer(owner,shop,offer.offer_id,10, "shop-fixture-4").error=="occupied", "exact occupied never falls back")
	check(balance(db,owner)==1100 and items.inventory(owner)==before and persistence.wallet_balance(owner)==1130 and persistence.runtime_wallets[persistence.wallet_account_id(owner)].pending_currency_delta==30 and persistence.dirty_wallet.has(persistence.wallet_account_id(owner)), "failed purchase preserves RAM delta and items")
	check(db.query("CREATE TEMP TRIGGER shop_fail_item BEFORE INSERT ON item_custody BEGIN SELECT RAISE(ABORT,'shop item failure'); END;"), "item fault")
	var rejected := persistence.purchase_shop_operation(owner, shop, offer.offer_id, -1, "shop-fixture-5")
	check(rejected.response().error == "storage" and not rejected.new_commit and not rejected.receipt_replay and rejected.changed_accounts.is_empty(), "insertion rollback reports no commit or changed accounts")
	check(balance(db,owner)==1100 and items.inventory(owner)==before and persistence.runtime_wallets[persistence.wallet_account_id(owner)].pending_currency_delta==30, "item failure rolls back pending income and spending")
	check(db.query_with_bindings("SELECT COUNT(*) AS n FROM item_instances WHERE owner_character_id=?;",[owner]) and int(db.query_result[0].n)==1, "no orphan item")
	check(db.query("DROP TRIGGER shop_fail_item;"), "remove item fault")
	check(db.query("CREATE TEMP TRIGGER shop_fail_wallet BEFORE UPDATE ON account_wallets BEGIN SELECT RAISE(ABORT,'shop wallet failure'); END;"), "wallet fault")
	check(persistence.purchase_shop_offer(owner,shop,offer.offer_id, -1, "shop-fixture-6").error=="storage" and items.inventory(owner)==before, "wallet failure creates no item")
	check(db.query("DROP TRIGGER shop_fail_wallet;"), "remove wallet fault")
	check(db.query("CREATE TEMP TRIGGER shop_fail_receipt BEFORE INSERT ON market_commands WHEN NEW.kind='npc_shop.buy' BEGIN SELECT RAISE(ABORT,'receipt failure'); END;"), "receipt write fault")
	check(persistence.purchase_shop_operation(owner, shop, offer.offer_id, -1, "receipt-fault").response().error == "storage" and items.inventory(owner) == before and balance(db,owner) == 1100 and persistence.wallet_balance(owner) == 1130, "receipt insertion failure rolls back spend, pending income and created item")
	check(db.query("DROP TRIGGER shop_fail_receipt;"), "remove receipt fault")
	var next_purchase := persistence.purchase_shop_operation(owner, shop, offer.offer_id, -1, "receipt-fault")
	var first_uid: String = result.uid
	result = next_purchase.response()
	check(next_purchase.new_commit and not next_purchase.receipt_replay and result.uid != first_uid, "another accepted offer purchase creates a distinct paid item, not a receipt replay")
	check(result.ok and result.position==0 and result.balance==130, "first fit and pending income committed")
	before=items.inventory(owner)
	check(persistence.purchase_shop_offer(owner,shop,offer.offer_id, -1, "shop-fixture-8").error=="funds" and items.inventory(owner)==before and balance(db,owner)==130, "insufficient funds no item/no charge")
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
	check(db.query("CREATE TEMP TRIGGER shop_capacity_first BEFORE UPDATE ON account_wallets BEGIN SELECT RAISE(ABORT,'wallet must not be touched'); END;"), "capacity ordering trigger")
	check(persistence.purchase_shop_offer(owner,shop,offer.offer_id, -1, "shop-fixture-9").error=="inventory_full", "capacity before wallet writes")
	check(db.query("DROP TRIGGER shop_capacity_first;"), "remove capacity fault")
	check(items.inventory(owner)==before and balance(db,owner)==130 and persistence.runtime_wallets[persistence.wallet_account_id(owner)].pending_currency_delta==1000, "full preserves item and wallet state")
	check(db.close_db() and db.open_db() and items.inventory(owner)==before and balance(db,owner)==130, "committed purchases survive reopening database")
	replay = persistence.purchase_shop_operation(owner, shop, offer.offer_id, 10, operation.operation_id)
	check(replay.receipt_replay and replay.response().uid == first_uid and items.inventory(owner) == before and persistence.wallet_balance(owner) == 1130, "durable replay survives reopen/full bag without consuming newer income")
	check(db.query("SELECT COUNT(*) AS n FROM market_commands WHERE kind='npc_shop.buy';") and int(db.query_result[0].n) == 2, "only successful purchases persist receipts, not rejections or replay")
	db.close_db()
	persistence.free()
	if not failed:
		print("SHOP_PURCHASE_OK: authoritative offers, exact/first-fit, capacity, stack limits, pending income, rollback and durability")
		get_tree().quit()

# Disk journal contract: no scene layout or private adapter state assertions.
func _test_journal() -> void:
	var script = preload("res://source/client/ui_web/local_economy_journal.gd")
	var journal = script.new()
	journal.directory = "res://.godot/verification/npc-journal-fixture-" + Crypto.new().generate_random_bytes(8).hex_encode()
	var context := {"authority_id":"a".repeat(32),"account_id":1,"character_id":2}
	check(journal.configure(context).ok, "create isolated journal")
	var id := "npc-buy-" + "b".repeat(32)
	var payload := {"npc_instance_id":"blacksmith","service_id":"weapon_shop","offer_id":"iron_sword","x":0,"y":2,"page":0}
	check(journal.save_pending(id,payload), "intention persisted before send")
	check(not journal.save_pending("npc-buy-" + "c".repeat(32),payload), "cannot replace unresolved intention")
	var fresh = script.new()
	fresh.directory = journal.directory
	var restored: Dictionary = fresh.configure(context)
	check(restored.ok and restored.entry.id == id and ShopUiAdapter.valid_buy(restored.entry.payload), "new instance restores exact valid payload")
	for field: String in ["authority_id","account_id","character_id"]:
		var other := context.duplicate()
		other[field] = "d".repeat(32) if field == "authority_id" else 9
		check(fresh.configure(other).entry.is_empty(), "journal isolated by " + field)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(journal.directory).path_join(("%s:%d:%d" % [other.authority_id,other.account_id,other.character_id]).sha256_text()))
	check(journal.clear_pending(id) and journal.load_pending().entry.is_empty(), "confirmed intention removed")
	# Corrupt files must block writes, never be silently discarded.
	var scope := ("%s:%d:%d" % [context.authority_id,context.account_id,context.character_id]).sha256_text()
	var folder := ProjectSettings.globalize_path(journal.directory).path_join(scope)
	var corrupt := folder.path_join(id + ".json")
	var file := FileAccess.open(corrupt,FileAccess.WRITE)
	file.store_string("broken")
	file.close()
	check(not journal.load_pending().ok and not journal.save_pending(id,payload), "corruption blocks new admission")
	DirAccess.remove_absolute(corrupt)
	var adapter := ShopUiAdapter.new()
	adapter.journal.directory = journal.directory
	adapter.accept_context({"ok":true,"economic_context":context})
	DirAccess.remove_absolute(folder)
	# Replace only the owned fixture folder with a file to simulate I/O failure.
	file = FileAccess.open(folder,FileAccess.WRITE)
	file.close()
	var refused: Dictionary = await adapter._submit("buy",payload)
	check(refused.get("error", "") == "journal_unavailable", "journal failure blocks purchase before any RPC/session use")
	DirAccess.remove_absolute(folder)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(journal.directory))
