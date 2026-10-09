extends Node
var failed: bool = false
func check(ok: bool, message: String) -> void:
	if not ok:
		failed = true
		push_error("INVENTORY_GRID_FAILED: " + message)
func _ready() -> void:
	for height: int in range(1, 4):
		check(InventoryGrid.cells(0, height).size() == height, "all footprints")
		check(InventoryGrid.fits((9-height)*5+4, height, {}), "last legal row")
		if height > 1: check(not InventoryGrid.fits((10-height)*5+4, height, {}), "page boundary")
		check(not InventoryGrid.fits(0, height, {0: true}), "overlap")
	check(InventoryGrid.cells(135, 3) == [135,140,145], "fourth page")
	check(not InventoryGrid.fits(-1, 1, {}) and not InventoryGrid.fits(180, 1, {}), "bounds")
	var db := SQLite.new()
	db.path = "res://.godot/verification/grid-%s.db" % Crypto.new().generate_random_bytes(8).hex_encode()
	check(db.open_db(), "open isolated DB")
	WorldSchema.ensure_schema(db)
	var legacy := WorldStoreSqlite.new(db)
	var owner: int = legacy.create_player_character("grid_test", {"name":"Grid", "skin":1})
	var store := ItemStoreSqlite.new(db)
	check(store.initialize_character(owner).ok, "starter")
	var before: Dictionary = store.inventory(owner)
	var moved: String = before.items[1].uid
	# Recreate the previous narrow table and a legal v14 layout that overlaps at height 3.
	check(db.query("DROP INDEX item_bag_position; DROP INDEX item_equipment_slot; ALTER TABLE item_placements RENAME TO placements_fixture; CREATE TABLE item_placements(item_uid TEXT PRIMARY KEY,owner_character_id INTEGER,location TEXT,bag_position INTEGER CHECK(bag_position BETWEEN -1 AND 23),equipment_slot TEXT); INSERT INTO item_placements SELECT * FROM placements_fixture; DROP TABLE placements_fixture; CREATE UNIQUE INDEX item_bag_position ON item_placements(owner_character_id,bag_position) WHERE location='bag'; CREATE UNIQUE INDEX item_equipment_slot ON item_placements(owner_character_id,equipment_slot) WHERE location='equipment'; UPDATE meta SET value='14' WHERE key='schema_version';"), "v14 fixture")
	check(db.query_with_bindings("UPDATE item_placements SET bag_position=5 WHERE item_uid=?;", [moved]), "legacy one-cell layout")
	check(db.query("CREATE TEMP TRIGGER reject_migration BEFORE UPDATE ON item_instances BEGIN SELECT RAISE(ABORT,'migration rollback fixture'); END;"), "inject migration fault")
	check(not ItemStoreSqlite.migrate_grid(db), "migration failure reported")
	check(db.query("SELECT value FROM meta WHERE key='schema_version';") and db.query_result[0].value == "14", "failed migration keeps schema version")
	check(db.query_with_bindings("SELECT bag_position FROM item_placements WHERE item_uid=?;", [moved]) and db.query_result[0].bag_position == 5, "failed migration restores placement")
	check(db.query("DROP TRIGGER reject_migration;"), "remove fault")
	check(ItemStoreSqlite.migrate_grid(db), "atomic v15 migration")
	var after: Dictionary = store.inventory(owner)
	check(after.items.size() == 2 and after.items[0].uid == before.items[0].uid and after.items[1].uid == moved, "migration preserves identities")
	check(after.items[1].bag_position == 1 and after.items[1].revision == 1 and after.items[1].stats == before.items[1].stats, "collision repacked with revision; stats intact")
	check(store.move_bag_item(owner,moved,1,5).get("error", "") == "occupied", "covered non-anchor cell rejected")
	check(store.move_bag_item(owner,moved,1,39).get("error", "") == "request", "page-crossing sword rejected")
	check(store.move_bag_item(owner,moved,1,135).ok, "cross-page move")
	check(db.close_db() and db.open_db(), "reopen")
	check(store.inventory(owner).items.any(func(i: Dictionary) -> bool: return i.uid == moved and i.bag_position == 135), "page and footprint survive relog")
	db.close_db()
	if not failed: print("INVENTORY_GRID_OK: heights, overlap, pages, atomic migration/rollback, relog")
	get_tree().quit(1 if failed else 0)
