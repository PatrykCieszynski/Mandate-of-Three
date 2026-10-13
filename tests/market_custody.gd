extends Node
## Uncovered contract: SQL-exclusive custody + account-scoped command receipts.
var db := SQLite.new()
var store: WorldStoreSqlite
var market: MarketStoreSqlite
var items: ItemStoreSqlite
func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.godot/verification"))
	db.path = "res://.godot/verification/market-custody.db"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path))
	assert(db.open_db())
	WorldSchema.ensure_schema(db)
	store = WorldStoreSqlite.new(db)
	var first := EconomyFixture.create_character(store,"alpha",{"name":"Alpha","skin":1},false)
	var alt := EconomyFixture.create_character(store,"alpha",{"name":"Alt","skin":1},false)
	var foreign := EconomyFixture.create_character(store,"beta",{"name":"Beta","skin":1},false)
	items = ItemStoreSqlite.new(db)
	assert(items.initialize_character(first).ok and items.initialize_character(alt).ok and items.initialize_character(foreign).ok)
	var storage := AccountStorageSqlite.new(db)
	var stored: Dictionary = items.inventory(first).items[0]
	assert(storage.transfer(first,stored.uid,0,"inventory","storage",0).ok)
	var old_bag := items.inventory(first)
	var old_storage := storage.snapshot(alt)
	assert(db.query("CREATE TRIGGER fail_v19 BEFORE INSERT ON meta WHEN NEW.value='19' BEGIN SELECT RAISE(ABORT,'custody migration fault'); END;"))
	assert(not MarketStoreSqlite.ensure_schema(db))
	assert(items.inventory(first)==old_bag and storage.snapshot(alt)==old_storage,"migration failure restores every UID/roll/socket/placement")
	assert(db.query("DROP TRIGGER fail_v19;"))
	assert(MarketStoreSqlite.ensure_schema(db) and MarketStoreSqlite.ensure_schema(db))
	assert(db.close_db() and db.open_db())
	assert(MarketStoreSqlite.ensure_schema(db))
	assert(items.inventory(first)==old_bag and storage.snapshot(alt)==old_storage,"canonical migration preserves old data")
	market = MarketStoreSqlite.new(db)
	var mine := market.mine(first)
	assert(mine.ok and market.mine(alt).shop_id==mine.shop_id and market.mine(foreign).shop_id!=mine.shop_id)
	var item: Dictionary = items.inventory(first).items[0]
	var original := items.inventory(first)
	# Every write stage in the public listing flow gets a concrete SQL fault.
	for fault: Array in [["custody","BEFORE UPDATE ON item_custody"],["offer","BEFORE INSERT ON shop_offers"],["cells","BEFORE INSERT ON shop_cells"],["item","BEFORE UPDATE ON item_instances"],["receipt","BEFORE INSERT ON market_commands"]]:
		assert(db.query("CREATE TEMP TRIGGER fail_market %s BEGIN SELECT RAISE(ABORT,'market stage fault'); END;" % fault[1]))
		assert(market.list_item(first,"fault_"+fault[0],item.uid,item.revision,0,100).error=="storage")
		assert(items.inventory(first)==original and market.mine(first).offers.is_empty(),"failed list leaves source and shop unchanged")
		assert(db.query("DROP TRIGGER fail_market;"))
	var listed := market.list_item(first,"list_a",item.uid,item.revision,0,100)
	assert(listed.ok and market.list_item(first,"list_a",item.uid,item.revision,0,100)==listed,"retry returns same receipt, not another listing")
	assert(market.list_item(first,"list_a",item.uid,item.revision,5,100).error=="command_conflict")
	assert(items.inventory(first).items.is_empty() and market.mine(alt).offers.size()==1)
	assert(market.configure(alt,"rename",0,"Bread Shop","paused").ok)
	assert(market.configure(first,"stale_name",0,"Wrong","active").error=="stale")
	assert(market.mine(first).name=="Bread Shop" and market.mine(first).status=="paused")
	for fault: String in ["BEFORE DELETE ON shop_cells","BEFORE UPDATE ON item_custody","BEFORE UPDATE ON shop_offers","BEFORE INSERT ON shop_cells","BEFORE UPDATE ON item_instances","BEFORE INSERT ON market_commands"]:
		assert(db.query("CREATE TEMP TRIGGER fail_edit %s BEGIN SELECT RAISE(ABORT,'edit stage fault'); END;" % fault))
		assert(market.edit_offer(alt,"edit_fault",listed.offer_id,0,12,321).error=="storage")
		assert(market.mine(first).offers[0].position==0 and market.mine(first).offers[0].price==100 and market.mine(first).offers[0].revision==0)
		assert(db.query("DROP TRIGGER fail_edit;"))

	assert(items.change_equipment(first,item.uid,item.revision,"equip").error=="owner","escrow cannot be equipped")
	assert(storage.transfer(first,item.uid,item.revision,"inventory","storage").error=="owner","escrow cannot also enter Storage")
	# Direct SQL bypass cannot introduce another location, nor commit an unplaced item.
	assert(db.query("BEGIN;"))
	assert(not db.query_with_bindings("INSERT INTO item_placements VALUES(?,?,'bag',10,'');",[item.uid,first]))
	assert(db.query("ROLLBACK;"))
	assert(db.query("BEGIN;"))
	assert(not db.query_with_bindings("UPDATE item_custody SET location='shop_escrow',owner_id=?,position=20,container_id=?,offer_id=? WHERE uid=?;",[store.resolve_account_id(first),mine.shop_id,listed.offer_id,stored.uid]),"one offer cannot alias two escrow UIDs")
	assert(db.query("ROLLBACK;"))
	assert(market.cancel_offer(foreign,"foreign_cancel",listed.offer_id,0).error=="unavailable")
	for fault: String in ["BEFORE DELETE ON shop_cells","BEFORE UPDATE ON item_custody","BEFORE DELETE ON shop_offers","BEFORE UPDATE ON item_instances","BEFORE INSERT ON market_commands"]:
		assert(db.query("CREATE TEMP TRIGGER fail_cancel %s BEGIN SELECT RAISE(ABORT,'cancel stage fault'); END;" % fault))
		assert(market.cancel_offer(alt,"cancel_fault",listed.offer_id,0).error=="storage")
		assert(market.mine(first).offers.size()==1 and market.mine(first).claims.is_empty())
		assert(db.query("DROP TRIGGER fail_cancel;"))
	assert(market.cancel_offer(alt,"cancel_a",listed.offer_id,0).ok)
	assert(market.cancel_offer(alt,"cancel_a",listed.offer_id,0).ok,"cancel retry cannot duplicate claim")
	var claim: Dictionary = market.mine(alt).claims[0]
	assert(claim.uid==item.uid and claim.affixes==item.affixes and claim.sockets==item.sockets)
	assert(market.claim_item(foreign,"foreign_claim",item.uid,claim.revision).error=="owner")
	# Fill the receiving alt through the real item receive transaction.
	while items._free_bag_position(alt,ItemDefinitions.IRON_SWORD.inventory_height)>=0:
		var position := items._free_bag_position(alt,ItemDefinitions.IRON_SWORD.inventory_height)
		assert(EconomyFixture.insert_item(items,ItemInstance.create(ItemDefinitions.IRON_SWORD,alt,[]),position))
	assert(market.claim_item(alt,"full_claim",item.uid,claim.revision).error=="inventory_full")
	assert(market.mine(first).claims.size()==1,"full receiver leaves account claim intact")
	var filler: Dictionary = items.inventory(alt).items[0]
	assert(EconomyFixture.destroy_item(db,filler.uid))
	for fault: String in ["BEFORE UPDATE ON item_instances","BEFORE UPDATE ON item_custody","BEFORE INSERT ON market_commands"]:
		assert(db.query("CREATE TEMP TRIGGER fail_claim %s BEGIN SELECT RAISE(ABORT,'claim stage fault'); END;" % fault))
		assert(market.claim_item(alt,"claim_fault",item.uid,claim.revision).error=="storage")
		assert(market.mine(first).claims.size()==1)
		assert(db.query("DROP TRIGGER fail_claim;"))
	var received := market.claim_item(alt,"claim_a",item.uid,claim.revision)
	assert(received.ok and market.claim_item(alt,"claim_a",item.uid,claim.revision)==received)
	assert(market.mine(first).claims.is_empty())
	assert(items.inventory(alt).items.any(func(i: Dictionary) -> bool: return i.uid==item.uid and i.owner_character_id==alt))
	assert(db.query("BEGIN;") and db.query_with_bindings("DELETE FROM item_placements WHERE item_uid=?;",[item.uid]))
	assert(not db.query("COMMIT;"),"deferred FK rejects a final item with no custody")
	assert(db.query("ROLLBACK;"))
	assert(db.query("PRAGMA foreign_key_check;") and db.query_result.is_empty())
	assert(db.query("SELECT COUNT(*) AS n FROM item_instances i JOIN item_custody c ON c.uid=i.uid;") and db.query_result[0].n==items.inventory(alt).items.size()+items.inventory(foreign).items.size()+storage.snapshot(first).items.size(),"every UID has one legal location")
	assert(db.close_db() and db.open_db() and MarketStoreSqlite.ensure_schema(db))
	assert(market.claim_item(alt,"claim_a",item.uid,claim.revision)==received,"receipt survives restart")
	# R0/R1: distinct rejected IDs must not create durable economic history.
	assert(db.query("SELECT COUNT(*) AS n FROM market_commands;"));var before_receipts:=int(db.query_result[0].n)
	var spam_started:=Time.get_ticks_usec()
	for request: int in 1024:
		assert(market.cancel_offer(first,"reject_%d" % request,"%032x" % 999999,0).error=="unavailable")
	assert(db.query("SELECT COUNT(*) AS n FROM market_commands;"));var rejected_receipts:=int(db.query_result[0].n)-before_receipts
	print("MARKET_REJECT_BENCH requests=1024 durable_rows=",rejected_receipts," elapsed_ms=",(Time.get_ticks_usec()-spam_started)/1000.0)
	assert(db.close_db())
	DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path))
	print("MARKET_CUSTODY_OK migration/retry/rollback, SQL single location, escrow/claims, alt ownership, durable receipts")
	get_tree().quit()
