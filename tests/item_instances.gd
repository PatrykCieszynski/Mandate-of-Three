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
	var owner_a: int = legacy.create_player_character("test_alpha", {"name": "Alpha", "skin": 1})
	var owner_b: int = legacy.create_player_character("test_beta", {"name": "Beta", "skin": 1})
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
	check(store.change_equipment(owner_a, weak.uid, 0, "equip").ok, "equip weak instance by UID")
	check(store.inventory(owner_a).stats.attack == 23, "base plus weak stats")
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
	check(store.change_equipment(owner_a, strong.uid, 1, "unequip").ok, "unequip instance")
	check(store.inventory(owner_a).stats.attack == 10, "unequip restores base stats")
	check(store.change_equipment(owner_a, strong.uid, 2, "equip").ok, "re-equip instance")
	var before_failure: Dictionary = store.inventory(owner_a)
	check(db.query("CREATE TEMP TRIGGER fail_equipment BEFORE INSERT ON item_placements WHEN NEW.location='equipment' BEGIN SELECT RAISE(ABORT,'intentional item placement failure'); END;"), "install fault injection")
	var rejected: Dictionary = store.change_equipment(owner_a, weak.uid, 2, "equip")
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
	check(db.query_with_bindings("DELETE FROM item_placements WHERE owner_character_id=?;", [owner_b]), "empty second inventory placements")
	check(db.query_with_bindings("DELETE FROM item_instances WHERE owner_character_id=?;", [owner_b]), "empty second inventory items")
	check(store.initialize_character(owner_b).ok and store.inventory(owner_b).items.is_empty(), "empty inventory does not regrant starter kit")
	check(db.query("SELECT value FROM meta WHERE key='schema_version';") and int(db.query_result[0].value) == 16, "schema v16")
	_check_storage(db,legacy,store)
	db.close_db()
	if not failed:
		print("ITEM_INSTANCES_OK: distinct UID/rolls, exact equip, ownership, revisions, rollback, database reopen, legacy save isolation")
		get_tree().quit()

func _find(snapshot: Dictionary, uid: String) -> Dictionary:
	for item: Dictionary in snapshot.items:
		if item.uid == uid: return item
	return {}

func _check_storage(database: SQLite, legacy: WorldStoreSqlite, store: ItemStoreSqlite) -> void:
	var first: int = legacy.create_player_character("storage_account",{"name":"StorageA","skin":1})
	var second: int = legacy.create_player_character("storage_account",{"name":"StorageB","skin":1})
	var foreign: int = legacy.create_player_character("foreign_storage",{"name":"Foreign","skin":1})
	for character: int in [first,second,foreign]: check(store.initialize_character(character).ok,"Storage starter fixture")
	var storage := AccountStorageSqlite.new(database)
	var bag_snapshot: Dictionary = store.inventory(first)
	var candidate: Dictionary = bag_snapshot.items[0]
	for combination: Array in [["inventory","inventory"],["equipment","storage"],["storage","equipment"],["unknown","storage"]]:
		check(storage.transfer(first,candidate.uid,0,combination[0],combination[1],5).error=="request","Storage rejects unrelated container route")
	check(store.inventory(first)==bag_snapshot,"invalid Storage routes preserve Inventory")
	var item: Dictionary = store.inventory(first).items[0]
	check(storage.transfer(first,item.uid,0,"inventory","storage",0).ok,"deposit commits")
	check(store.inventory(first).items.size()==1,"deposit removes bag placement")
	check(storage.snapshot(second).items[0].uid==item.uid,"same account sees Storage")
	check(storage.snapshot(foreign).items.is_empty(),"foreign account cannot see Storage")
	var before: Dictionary = storage.snapshot(first)
	check(storage.transfer(foreign,item.uid,1,"storage","inventory").error=="owner","foreign withdrawal rejected")
	check(storage.transfer(second,item.uid,0,"storage","inventory").error=="stale","stale withdrawal rejected")
	check(storage.transfer(second,item.uid,1,"storage","storage",269).error=="occupied","footprint crosses page bottom")
	check(storage.snapshot(first)==before,"rejections preserve stored item")
	check(database.query("CREATE TEMP TRIGGER storage_revision_failure BEFORE UPDATE ON item_instances BEGIN SELECT RAISE(ABORT,'test Storage rollback'); END;"),"inject Storage failure")
	var bag_before: Dictionary = store.inventory(second)
	check(storage.transfer(second,item.uid,1,"storage","inventory").error=="storage","withdrawal failure reported")
	check(store.inventory(second)==bag_before and storage.snapshot(first)==before,"withdrawal rolls back ownership and both placements")
	check(database.query("DROP TRIGGER storage_revision_failure;"),"remove Storage failure")
	check(database.close_db() and database.open_db(),"Storage database reopen")
	check(storage.snapshot(second)==before,"account Storage survives reopen")
	check(storage.transfer(second,item.uid,1,"storage","storage",135).ok,"move stored item to page II")
	check(storage.transfer(second,item.uid,2,"storage","inventory").ok,"other character withdraws")
	var withdrawn: Dictionary = _find(store.inventory(second),item.uid)
	check(withdrawn.owner_character_id==second and withdrawn.revision==3 and withdrawn.affixes==item.affixes,"withdrawal preserves content and transfers owner")
	check(storage.snapshot(first).items.is_empty(),"withdrawal removes account placement")
	check(store.move_bag_item(first,item.uid,3,10).error=="owner","original character no longer owns withdrawn item")
	# Fill both pages with real item footprints; overflow must remain in the bag.
	for index: int in AccountStorageSqlite.COLUMNS * AccountStorageSqlite.PAGES * (AccountStorageSqlite.ROWS / ItemDefinitions.IRON_SWORD.inventory_height):
		var filler: ItemInstance = ItemInstance.create(ItemDefinitions.IRON_SWORD,first,[])
		check(store._insert_item(filler,2),"insert Storage filler")
		check(storage.transfer(first,filler.uid,0,"inventory","storage").ok,"fill Storage footprint")
	var excess: ItemInstance = ItemInstance.create(ItemDefinitions.IRON_SWORD,first,[])
	check(store._insert_item(excess,2),"insert overflow candidate")
	bag_before=store.inventory(first)
	before=storage.snapshot(first)
	check(storage.transfer(first,excess.uid,0,"inventory","storage").error=="full","full account Storage rejects quick deposit")
	check(store.inventory(first)==bag_before and storage.snapshot(first)==before,"full transfer preserves last valid states")
