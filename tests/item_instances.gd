extends Node
## Real SQLite integration: ownership, atomic swaps, rollback and reopen.

var failed: bool = false

func _ready() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if not ok:
		failed = true
		push_error("ITEM_TEST_FAILED: " + message)
		get_tree().quit(1)

func run() -> void:
	var directory: String = ProjectSettings.globalize_path("res://.godot/verification")
	DirAccess.make_dir_recursive_absolute(directory)
	var db := SQLite.new()
	db.path = directory.path_join("items-unit-%s.db" % Crypto.new().generate_random_bytes(8).hex_encode())
	check(db.open_db(), "open isolated database")
	WorldSchema.ensure_schema(db)
	var legacy := WorldStoreSqlite.new(db)
	var owner_a: int = EconomyFixture.create_character(legacy,"test_alpha", {"name": "Alpha", "skin": 1})
	var owner_b: int = EconomyFixture.create_character(legacy,"test_beta", {"name": "Beta", "skin": 1})
	var player: PlayerResource = legacy.get_player(owner_a)
	player.profile_status = "preserve legacy player data"
	legacy.save_player(player)
	var store := ItemStoreSqlite.new(db)
	check(store.initialize_character(owner_a).ok, "first starter grant")
	check(store.initialize_character(owner_b).ok, "second owner starter grant")
	var initial: Dictionary = store.inventory(owner_a)
	check(initial.ok and initial.items.size() == 2, "two instances")
	if failed: return
	var weak: Dictionary = initial.items[0]
	var strong: Dictionary = initial.items[1]
	check(weak.icon_id == str(ItemDefinitions.IRON_SWORD.icon_id) and weak.icon_id != "", "content icon identity travels with the snapshot")
	check(weak.uid != strong.uid and weak.definition_id == strong.definition_id, "distinct UIDs, same definition")
	check(weak.stats.attack == 13 and strong.stats.attack == 17, "independent affixes")
	check(store.initialize_character(owner_a).ok and store.inventory(owner_a) == initial, "repeated grant changes nothing")
	var bag_before: Dictionary = store.inventory(owner_b)
	var moving: Dictionary = bag_before.items[0]
	check(store.move_bag_item(owner_b, moving.uid, 0, 10).ok, "move bag item commits immediately")
	var bag_moved: Dictionary = store.inventory(owner_b)
	check(_find(bag_moved, moving.uid).bag_position == 10 and _find(bag_moved, moving.uid).revision == 1, "move updates position and revision")
	check(store.move_bag_item(owner_a, moving.uid, 1, 8).error == "owner", "foreign bag move rejected")
	check(store.move_bag_item(owner_b, moving.uid, 0, 8).error == "stale", "stale bag move rejected")
	check(store.move_bag_item(owner_b, moving.uid, 1, 1).error == "occupied", "occupied bag cell rejected")
	check(store.move_bag_item(owner_b, moving.uid, 1, 180).error == "request", "outside bag rejected")
	check(store.inventory(owner_b) == bag_moved, "rejected moves preserve full state")
	check(db.query("CREATE TEMP TRIGGER fail_bag_revision BEFORE UPDATE ON item_instances BEGIN SELECT RAISE(ABORT,'intentional move failure'); END;"), "inject revision write failure")
	check(store.move_bag_item(owner_b, moving.uid, 1, 8).error == "storage", "bag write failure reported")
	check(store.inventory(owner_b) == bag_moved, "bag position rolls back if revision write fails")
	check(db.query("DROP TRIGGER fail_bag_revision;"), "remove move fault")
	check(ItemDefinitions.IRON_SWORD.base_stats[&"attack"] == 10, "shared definition unmodified")
	check(ItemDefinition.new().primary_action == ItemDefinition.PrimaryAction.NONE, "new definitions default to no action")
	check(store.activate_item(owner_a, weak.uid, 1).error == "stale", "activation rejects stale revision")
	check(store.activate_item(owner_b, weak.uid, 0).error == "owner", "activation rejects foreign ownership")
	check(store.activate_item(owner_a, "invalid", 0).error == "request", "activation rejects invalid UID")
	# Only this isolated test process changes the loaded definition to exercise
	# actions without introducing test-only items or resolver hooks in production.
	var activation_definition: ItemDefinition = ItemDefinitions.get_definition(weak.definition_id)
	var original_action: ItemDefinition.PrimaryAction = activation_definition.primary_action
	check(original_action == ItemDefinition.PrimaryAction.EQUIP, "Iron Sword declares equip action")
	activation_definition.primary_action = ItemDefinition.PrimaryAction.NONE
	check(store.activate_item(owner_a, weak.uid, 0).error == "no_action", "NONE rejects activation")
	check(store.inventory(owner_a) == initial, "NONE preserves full inventory")
	activation_definition.primary_action = ItemDefinition.PrimaryAction.USE
	check(store.activate_item(owner_a, weak.uid, 0).error == "unsupported", "USE remains unsupported")
	check(store.inventory(owner_a) == initial, "USE preserves full inventory")
	activation_definition.primary_action = original_action
	check(store.activate_item(owner_a, weak.uid, 0).ok, "activate equips weak instance by UID")
	check(store.inventory(owner_a).stats.attack == 23, "base plus weak stats")
	check(store.inventory(owner_a).stats.attack_speed == 122,"equipment adds data-defined speed to base 100")
	check(store.change_equipment(owner_a, strong.uid, 0, "equip").ok, "swap to strong instance")
	var swapped: Dictionary = store.inventory(owner_a)
	check(swapped.equipment.weapon == strong.uid and swapped.stats.attack == 27, "strong instance equipped")
	check(swapped.items.size() == 2, "swap neither duplicates nor destroys items")
	var returned: Dictionary = _find(swapped, weak.uid)
	check(returned.location == "bag" and returned.affixes == weak.affixes and returned.revision == 2, "old instance returned with original roll")
	check(not store.change_equipment(owner_b, weak.uid, 2, "equip").ok, "foreign UID rejected")
	check(store.inventory(owner_a) == swapped, "foreign request cannot mutate owner inventory")
	check(store.change_equipment(owner_a, strong.uid, 0, "unequip").error == "stale", "stale revision rejected")
	check(store.inventory(owner_a) == swapped, "stale request leaves state intact")
	check(store.change_equipment(owner_a, strong.uid, 1, "unequip", returned.bag_position).error == "occupied", "exact unequip rejects occupied target without fallback")
	check(store.change_equipment(owner_a, strong.uid, 1, "unequip", InventoryGrid.CAPACITY - 1).error == "request", "exact unequip rejects footprint beyond page")
	check(store.change_equipment(owner_a, strong.uid, 1, "unequip", -2).error == "request", "invalid requested position is not automatic placement")
	check(store.inventory(owner_a) == swapped, "invalid exact unequip preserves equipment revision and stats")
	check(store.change_equipment(owner_a, strong.uid, 1, "unequip", 10).ok, "exact unequip commits selected position")
	check(_find(store.inventory(owner_a), strong.uid).bag_position == 10, "unequip respects exact anchor")
	check(store.inventory(owner_a).stats.attack == 10, "unequip restores base stats")
	check(store.inventory(owner_a).stats.attack_speed == 100,"unequip restores speed 100")
	check(store.change_equipment(owner_a, strong.uid, 2, "equip").ok, "re-equip instance")
	var before_failure: Dictionary = store.inventory(owner_a)
	check(db.query("CREATE TEMP TRIGGER fail_exact_unequip BEFORE UPDATE ON item_instances BEGIN SELECT RAISE(ABORT,'intentional unequip failure'); END;"), "inject exact unequip failure")
	check(store.change_equipment(owner_a, strong.uid, 3, "unequip", 15).error == "storage", "exact unequip write failure reported")
	check(store.inventory(owner_a) == before_failure, "exact unequip rolls back placement revision and stats")
	check(db.query("DROP TRIGGER fail_exact_unequip;"), "remove exact unequip failure")
	check(db.query("CREATE TEMP TRIGGER fail_equipment BEFORE INSERT ON item_custody WHEN NEW.location='equipment' BEGIN SELECT RAISE(ABORT,'intentional item placement failure'); END;"), "install fault injection")
	var rejected: Dictionary = store.activate_item(owner_a, weak.uid, 2)
	check(not rejected.ok and rejected.error == "storage", "write failure reported")
	check(store.inventory(owner_a) == before_failure, "failed swap rolls back locations and revisions")
	check(db.query("DROP TRIGGER fail_equipment;"), "remove fault injection")
	check(store.change_equipment(owner_a, weak.uid, 2, "equip").ok, "transaction works after rollback")
	# Model round-trip only; this is not an implementation of upgrade/socket actions.
	check(db.query_with_bindings("UPDATE item_instances SET upgrade_level=1,sockets_json=? WHERE uid=?;", [JSON.stringify([{"definition_id": "test_stone"}]), weak.uid]), "persist per-instance fields")
	var persisted: Dictionary = store.inventory(owner_a)
	legacy.save_player(player)
	check(store.inventory(owner_a) == persisted, "legacy INSERT OR REPLACE cannot overwrite item state")
	check(db.close_db(), "close database")
	check(db.open_db(), "reopen database")
	WorldSchema.ensure_schema(db)
	store = ItemStoreSqlite.new(db)
	check(store.initialize_character(owner_a).ok, "relog initialization")
	check(store.inventory(owner_b) == bag_moved, "bag placement survives SQLite reopen")
	check(store.inventory(owner_a) == persisted, "reopen preserves UID, equip, rolls, sockets and upgrade")
	check(legacy.get_player(owner_a).profile_status == player.profile_status, "legacy profile preserved")
	check(db.query("BEGIN IMMEDIATE;"),"destroy fixture transaction")
	check(db.query_with_bindings("DELETE FROM item_placements WHERE owner_character_id=?;", [owner_b]), "empty second inventory placements")
	check(db.query_with_bindings("DELETE FROM item_instances WHERE owner_character_id=?;", [owner_b]), "empty second inventory items")
	check(db.query("COMMIT;"),"destroy fixture commit")
	check(store.initialize_character(owner_b).ok and store.inventory(owner_b).items.is_empty(), "empty inventory does not regrant starter kit")
	check(db.query("SELECT value FROM meta WHERE key='schema_version';") and int(db.query_result[0].value) == 19, "schema v19")
	_check_storage(db,legacy,store)
	var dev_owner: int = EconomyFixture.create_character(legacy,"dev_trace_fixture",{"name":"TraceFixture","skin":1})
	check(store.initialize_character(dev_owner).ok,"dev fixture initialized")
	var granted := store.grant_dev_trace_sword(dev_owner)
	check(granted.ok and store.grant_dev_trace_sword(dev_owner).uid == granted.uid,"dev sword grant is idempotent")
	check(store.change_equipment(dev_owner,granted.uid,0,"equip").ok,"practice sword equips")
	check(store.inventory(dev_owner).stats.attack == 1,"practice weapon sets total attack to one")
	check(store.change_equipment(dev_owner,granted.uid,1,"unequip").ok and store.inventory(dev_owner).stats.attack == 10,"unequip restores base attack")
	_check_inventory_boundary(db, legacy)
	_check_inventory_receipts(db, legacy)
	await _check_inventory_client_journal()
	db.close_db()
	if not failed:
		print("ITEM_INSTANCES_OK: distinct UID/rolls, exact equip, ownership, revisions, rollback, database reopen, legacy save isolation")
		get_tree().quit()

func _find(snapshot: Dictionary, uid: String) -> Dictionary:
	for item: Dictionary in snapshot.items:
		if item.uid == uid: return item
	return {}

func _check_storage(database: SQLite, legacy: WorldStoreSqlite, store: ItemStoreSqlite) -> void:
	var first: int = EconomyFixture.create_character(legacy,"storage_account",{"name":"StorageA","skin":1})
	var second: int = EconomyFixture.create_character(legacy,"storage_account",{"name":"StorageB","skin":1})
	var foreign: int = EconomyFixture.create_character(legacy,"foreign_storage",{"name":"Foreign","skin":1})
	for character: int in [first,second,foreign]: check(store.initialize_character(character).ok,"Storage starter fixture")
	var persistence := WorldDatabase.new()
	persistence.db = database
	persistence.store = legacy
	var storage := AccountStorageSqlite.new(database)
	var bag_snapshot: Dictionary = store.inventory(first)
	var candidate: Dictionary = bag_snapshot.items[0]
	for combination: Array in [["inventory","inventory"],["equipment","storage"],["storage","equipment"],["unknown","storage"]]:
		check(persistence.transfer_storage(first,candidate.uid,0,combination[0],combination[1],5).error=="request","Storage rejects unrelated container route")
	check(store.inventory(first)==bag_snapshot,"invalid Storage routes preserve Inventory")
	var item: Dictionary = store.inventory(first).items[0]
	var operation := persistence.storage_operation(first, item.uid, 0, "inventory", "storage", 0)
	check(operation.response().ok and operation.new_commit and not operation.receipt_replay and operation.changed_accounts == PackedInt64Array([legacy.resolve_account_id(first)]), "deposit commits one account change")
	check(store.inventory(first).items.size()==1,"deposit removes bag placement")
	check(storage.snapshot(second).items[0].uid==item.uid,"same account sees Storage")
	check(storage.snapshot(foreign).items.is_empty(),"foreign account cannot see Storage")
	var before: Dictionary = storage.snapshot(first)
	# State-only assertions previously missed duplicate facts for a successful no-op.
	operation = persistence.storage_operation(second, item.uid, 1, "storage", "storage", 0)
	check(operation.response().ok and not operation.new_commit and not operation.receipt_replay and operation.changed_accounts.is_empty() and storage.snapshot(first) == before, "same-cell Storage move preserves revision without mutation or receipt replay")
	check(persistence.transfer_storage(foreign,item.uid,1,"storage","inventory",-1).error=="owner","foreign withdrawal rejected")
	check(persistence.transfer_storage(second,item.uid,0,"storage","inventory",-1).error=="stale","stale withdrawal rejected")
	check(persistence.transfer_storage(second,item.uid,1,"storage","storage",269).error=="occupied","footprint crosses page bottom")
	check(storage.snapshot(first)==before,"rejections preserve stored item")
	check(database.query("CREATE TEMP TRIGGER storage_revision_failure BEFORE UPDATE ON item_instances BEGIN SELECT RAISE(ABORT,'test Storage rollback'); END;"),"inject Storage failure")
	var bag_before: Dictionary = store.inventory(second)
	operation = persistence.storage_operation(second, item.uid, 1, "storage", "inventory", -1)
	check(operation.response().error == "storage" and not operation.new_commit and operation.changed_accounts.is_empty(), "withdrawal failure reports no new mutation")
	check(store.inventory(second)==bag_before and storage.snapshot(first)==before,"withdrawal rolls back ownership and both placements")
	check(database.query("DROP TRIGGER storage_revision_failure;"),"remove Storage failure")
	check(database.close_db() and database.open_db(),"Storage database reopen")
	check(storage.snapshot(second)==before,"account Storage survives reopen")
	check(persistence.transfer_storage(second,item.uid,1,"storage","storage",135).ok,"move stored item to page II")
	check(persistence.transfer_storage(second,item.uid,2,"storage","inventory",-1).ok,"other character withdraws")
	var withdrawn: Dictionary = _find(store.inventory(second),item.uid)
	check(withdrawn.owner_character_id==second and withdrawn.revision==3 and withdrawn.affixes==item.affixes,"withdrawal preserves content and transfers owner")
	check(storage.snapshot(first).items.is_empty(),"withdrawal removes account placement")
	check(store.move_bag_item(first,item.uid,3,10).error=="owner","original character no longer owns withdrawn item")
	# Fill both pages with real item footprints; overflow must remain in the bag.
	for index: int in AccountStorageSqlite.COLUMNS * AccountStorageSqlite.PAGES * (AccountStorageSqlite.ROWS / ItemDefinitions.IRON_SWORD.inventory_height):
		var filler: ItemInstance = ItemInstance.create(ItemDefinitions.IRON_SWORD,first,[])
		check(EconomyFixture.insert_item(store,filler,2),"insert Storage filler")
		check(persistence.transfer_storage(first,filler.uid,0,"inventory","storage",-1).ok,"fill Storage footprint")
	var excess: ItemInstance = ItemInstance.create(ItemDefinitions.IRON_SWORD,first,[])
	check(EconomyFixture.insert_item(store,excess,2),"insert overflow candidate")
	bag_before=store.inventory(first)
	before=storage.snapshot(first)
	check(persistence.transfer_storage(first,excess.uid,0,"inventory","storage",-1).error=="full","full account Storage rejects quick deposit")
	check(store.inventory(first)==bag_before and storage.snapshot(first)==before,"full transfer preserves last valid states")
	persistence.free()

# Protect the commit/no-op distinction: existing swap/rollback cases alone cannot
# detect duplicate change facts or a no-op incorrectly labelled receipt replay.
func _check_inventory_boundary(database: SQLite, legacy: WorldStoreSqlite) -> void:
	var persistence := WorldDatabase.new()
	persistence.db = database
	persistence.store = legacy
	var owner := EconomyFixture.create_character(legacy, "inventory_boundary", {"name":"Boundary", "skin":1})
	var items := ItemStoreSqlite.new(database)
	check(items.initialize_character(owner).ok, "boundary starter fixture")
	var candidate: Dictionary = items.inventory(owner).items[0]
	var operation := persistence.inventory_operation(owner, "activate", candidate.uid, 0, -1, "inventory-test-1")
	check(operation.response().ok and operation.new_commit and not operation.receipt_replay, "activation reports a new mutation")
	check(operation.character_id == owner and operation.account_id == legacy.resolve_account_id(owner) and operation.changed_accounts == PackedInt64Array([operation.account_id]) and not operation.operation_id.is_empty(), "inventory result has trusted context and explicit receipt identity")
	var equipped := items.inventory(owner)
	operation = persistence.inventory_operation(owner, "equip", candidate.uid, 1, -1, "inventory-test-2")
	check(operation.response().ok and not operation.new_commit and not operation.receipt_replay and operation.changed_accounts.is_empty() and items.inventory(owner) == equipped, "repeat equip is an unchanged success, not a receipt replay")
	operation = persistence.inventory_operation(owner, "unequip", candidate.uid, 0, -1, "inventory-test-3")
	check(operation.response().error == "stale" and not operation.new_commit and not operation.receipt_replay and items.inventory(owner) == equipped, "stale retry preserves equipped state")
	operation = persistence.inventory_operation(owner, "unequip", candidate.uid, 1, 15, "inventory-test-4")
	check(operation.response().ok and operation.new_commit, "boundary exact unequip commits")
	var before := items.inventory(owner)
	operation = persistence.inventory_operation(owner, "move", candidate.uid, 2, 15, "inventory-test-5")
	check(operation.response().ok and not operation.new_commit and not operation.receipt_replay and items.inventory(owner) == before, "same-cell move preserves revision without commit fact")
	operation = persistence.inventory_operation(owner, "unequip", candidate.uid, 2, -1, "inventory-test-6")
	check(operation.response().ok and not operation.new_commit and not operation.receipt_replay, "already-bag unequip is a no-op")
	check(database.query("CREATE TEMP TRIGGER fail_boundary_revision BEFORE UPDATE ON item_instances BEGIN SELECT RAISE(ABORT,'boundary failure'); END;"), "inject boundary failure")
	operation = persistence.inventory_operation(owner, "move", candidate.uid, 2, 20, "inventory-test-7")
	check(operation.response().error == "storage" and not operation.new_commit and operation.changed_accounts.is_empty() and items.inventory(owner) == before, "boundary rolls back placement and revision without a commit fact")
	check(database.query("DROP TRIGGER fail_boundary_revision;"), "remove boundary failure")
	check(items.move_bag_item(owner, candidate.uid, 2, 20).ok and items.committed, "shared store mutation commits")
	check(items.move_bag_item(owner, candidate.uid, 3, 20).ok and not items.committed, "shared store resets commit outcome for no-op")
	check(items.activate_item(owner, "invalid", 3).error == "request" and not items.committed, "shared store rejects without stale commit outcome")
	persistence.free()

# Receipt, replay and lost-response risks are additional to legacy placement tests.
func _check_inventory_receipts(database: SQLite, legacy: WorldStoreSqlite) -> void:
	var persistence := WorldDatabase.new()
	persistence.db = database
	persistence.store = legacy
	var owner := EconomyFixture.create_character(legacy,"inventory_receipts",{"name":"Receipts","skin":1})
	var alternate := EconomyFixture.create_character(legacy,"inventory_receipts",{"name":"Alternate","skin":1})
	var stranger := EconomyFixture.create_character(legacy,"inventory_stranger",{"name":"Stranger","skin":1})
	var items := ItemStoreSqlite.new(database)
	check(items.initialize_character(owner).ok,"receipt starter kit")
	var uid: String = items.inventory(owner).items[0].uid
	check(persistence.inventory_operation(owner,"move",uid,0,15).response().error == "request","missing intention ID cannot mutate Inventory")
	var revision := 0
	var first_id := ""
	for action: String in ["move","equip","unequip","activate"]:
		var position := 15 if action in ["move","unequip"] else -1
		var id := "inventory-contract-"+action
		if first_id.is_empty(): first_id = id
		var before := items.inventory(owner)
		check(database.query("CREATE TEMP TRIGGER fail_inventory_receipt BEFORE INSERT ON market_commands WHEN NEW.kind='inventory' BEGIN SELECT RAISE(ABORT,'inventory receipt fault'); END;"),"inject receipt fault")
		var operation := persistence.inventory_operation(owner,action,uid,revision,position,id)
		check(operation.response().error == "storage" and not operation.new_commit and items.inventory(owner)==before,"receipt failure rolls back "+action)
		check(persistence.inventory_receipt(owner,id).response().error == "unknown_command","failed mutation cannot leave a success receipt")
		check(database.query("DROP TRIGGER fail_inventory_receipt;"),"remove receipt fault")
		operation = persistence.inventory_operation(owner,action,uid,revision,position,id)
		check(operation.response().ok and operation.new_commit and not operation.receipt_replay,"same-ID retry commits "+action)
		var after := items.inventory(owner)
		operation = persistence.inventory_operation(owner,action,uid,revision,position,id)
		check(operation.response().ok and not operation.new_commit and operation.receipt_replay and operation.changed_accounts.is_empty() and items.inventory(owner)==after,"durable replay confirms without another mutation: "+action)
		check(persistence.inventory_operation(owner,action,uid,revision+1,position,id).response().error == "command_conflict","changed revision conflicts: "+action)
		revision += 1
	var final := items.inventory(owner)
	check(persistence.inventory_operation(owner,"move",uid,0,15,first_id).receipt_replay and items.inventory(owner)==final,"old move receipt cannot restore historical placement after later equip")
	var lookup := persistence.inventory_receipt(owner,first_id)
	check(lookup.response().ok and not lookup.new_commit and not lookup.receipt_replay and lookup.changed_accounts.is_empty(),"result lookup has read-only semantics")
	check(persistence.inventory_receipt(alternate,first_id).response().error == "unknown_command" and persistence.inventory_receipt(stranger,first_id).response().error == "unknown_command","receipt lookup isolates character/account")
	check(persistence.inventory_operation(alternate,"move",uid,0,15,first_id).response().error == "command_conflict","alternate character cannot reuse fingerprint")
	check(persistence.inventory_operation(stranger,"move",uid,0,15,first_id).response().error == "owner","another account cannot replay another owner's item")
	check(persistence.inventory_operation(owner,"unequip",uid,0,-1,first_id).response().error == "command_conflict","action is part of original fingerprint")
	check(persistence.inventory_receipt(owner,"missing").response().error == "unknown_command" and items.inventory(owner)==final,"unknown receipt never admits a mutation")
	check(database.query_with_bindings("INSERT INTO market_commands(account_id,command_id,kind,request_json,result_json) VALUES(?,?,?,?,?);",[legacy.resolve_account_id(owner),"other-inventory-kind","upgrade","[]",JSON.stringify({"ok":true})]),"seed other command kind")
	check(persistence.inventory_receipt(owner,"other-inventory-kind").response().error == "unknown_command","receipt lookup cannot expose another command kind")
	# Successful no-op is durable but has no new mutation fact, including replay.
	var noop := persistence.inventory_operation(owner,"equip",uid,revision,-1,"inventory-noop")
	check(noop.response().ok and not noop.new_commit and not noop.receipt_replay,"new no-op is not labelled a replay")
	check(persistence.inventory_operation(owner,"equip",uid,revision,-1,"inventory-noop").receipt_replay,"no-op retry has a durable outcome")
	var swapping: Dictionary = final.items.filter(func(item: Dictionary) -> bool: return item.uid != uid)[0]
	check(database.query("CREATE TEMP TRIGGER fail_inventory_receipt BEFORE INSERT ON market_commands WHEN NEW.kind='inventory' BEGIN SELECT RAISE(ABORT,'swap receipt fault'); END;"),"inject swap receipt fault")
	check(persistence.inventory_operation(owner,"equip",swapping.uid,swapping.revision,-1,"inventory-swap").response().error == "storage" and items.inventory(owner)==final,"receipt failure restores both sides of equipment swap and revisions")
	check(database.query("DROP TRIGGER fail_inventory_receipt;"),"remove swap receipt fault")
	check(persistence.inventory_operation(owner,"equip",swapping.uid,swapping.revision,-1,"inventory-swap").new_commit,"retry commits complete swap")
	final = items.inventory(owner)
	check(database.close_db() and database.open_db(),"reopen receipt database")
	check(persistence.inventory_operation(owner,"move",uid,0,15,first_id).receipt_replay and items.inventory(owner)==final,"receipt and final placement survive reopen")
	persistence.free()

func _check_inventory_client_journal() -> void:
	var adapter := ItemUiAdapter.new()
	var directory := "res://.godot/verification/inventory-journal-unit-" + Crypto.new().generate_random_bytes(8).hex_encode()
	adapter.journal.directory = directory
	var context := {"authority_id":"a".repeat(32),"account_id":1,"character_id":2}
	adapter.accept_context({"ok":true,"economic_context":context})
	var folder := ProjectSettings.globalize_path(directory).path_join(("%s:%d:%d" % [context.authority_id,context.account_id,context.character_id]).sha256_text())
	DirAccess.remove_absolute(folder)
	var file := FileAccess.open(folder,FileAccess.WRITE)
	file.close()
	var item := {"id":"b".repeat(32),"revision":0}
	check((await adapter._submit(item,"equip")).error == "journal_unavailable","failed journal write blocks Inventory before RPC/session")
	DirAccess.remove_absolute(folder)
	var script = preload("res://source/client/ui_web/local_economy_journal.gd")
	var journal = script.new("inventory-",directory)
	check(journal.configure(context).ok,"configure owned journal fixture")
	var payload := {"action":"equip","item":item}
	var id := "inventory-" + "c".repeat(32)
	check(journal.save_pending(id,payload),"persist original action and item identity")
	var fresh = script.new("inventory-",directory)
	var loaded: Dictionary = fresh.configure(context)
	check(loaded.ok and loaded.entry.id == id and ItemUiAdapter.valid_intent(loaded.entry.payload),"fresh reader validates original Inventory intention")
	check(not ItemUiAdapter.valid_intent({"action":"storage.transfer","item":item}),"Inventory journal cannot route Storage")
	check(fresh.clear_pending(id),"clear owned fixture intention")
	DirAccess.remove_absolute(folder)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(directory))
