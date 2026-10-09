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
	check(db.query("SELECT value FROM meta WHERE key='schema_version';") and int(db.query_result[0].value) == 15, "schema v15")
	db.close_db()
	if not failed:
		print("ITEM_INSTANCES_OK: distinct UID/rolls, exact equip, ownership, revisions, rollback, database reopen, legacy save isolation")
		get_tree().quit()

func _find(snapshot: Dictionary, uid: String) -> Dictionary:
	for item: Dictionary in snapshot.items:
		if item.uid == uid: return item
	return {}
