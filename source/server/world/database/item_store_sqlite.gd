class_name ItemStoreSqlite
extends RefCounted
## SQL is the authoritative item state. Commands are synchronous transactions;
## the legacy player JSON serializer never writes these tables.

const BAG_CAPACITY: int = InventoryGrid.CAPACITY
const ITEM_SELECT: String = "SELECT i.*, p.location, p.bag_position, p.equipment_slot FROM item_instances i JOIN item_placements p ON p.item_uid=i.uid "
var db: SQLite

func _init(database: SQLite) -> void:
	db = database

static func ensure_schema(database: SQLite) -> bool:
	if not database.query("BEGIN IMMEDIATE;"):
		return false
	var statements: Array[String] = [
		"CREATE TABLE IF NOT EXISTS item_instances (uid TEXT PRIMARY KEY NOT NULL, owner_character_id INTEGER NOT NULL CHECK(owner_character_id>0), definition_id TEXT NOT NULL, amount INTEGER NOT NULL CHECK(amount>0), upgrade_level INTEGER NOT NULL DEFAULT 0 CHECK(upgrade_level BETWEEN 0 AND 9), affixes_json TEXT NOT NULL, sockets_json TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0));",
		"CREATE TABLE IF NOT EXISTS item_placements (item_uid TEXT PRIMARY KEY NOT NULL, owner_character_id INTEGER NOT NULL, location TEXT NOT NULL CHECK(location IN ('bag','equipment')), bag_position INTEGER NOT NULL, equipment_slot TEXT NOT NULL, CHECK((location='bag' AND bag_position BETWEEN 0 AND 179 AND equipment_slot='') OR (location='equipment' AND bag_position=-1 AND equipment_slot<>'')));",
		"CREATE UNIQUE INDEX IF NOT EXISTS item_bag_position ON item_placements(owner_character_id,bag_position) WHERE location='bag';",
		"CREATE UNIQUE INDEX IF NOT EXISTS item_equipment_slot ON item_placements(owner_character_id,equipment_slot) WHERE location='equipment';",
		"CREATE INDEX IF NOT EXISTS item_owner ON item_instances(owner_character_id);",
		"CREATE TABLE IF NOT EXISTS item_initializations (owner_character_id INTEGER PRIMARY KEY NOT NULL);"
	]
	for statement: String in statements:
		if not database.query(statement):
			database.query("ROLLBACK;")
			return false
	if not database.query("COMMIT;"):
		database.query("ROLLBACK;")
		return false
	return true

func initialize_character(owner_id: int) -> Dictionary:
	if not db.query("BEGIN IMMEDIATE;"):
		return _error("storage")
	if not db.query_with_bindings("SELECT player_id FROM players WHERE player_id=?;", [owner_id]):
		return _rollback("storage")
	if db.query_result.is_empty():
		return _rollback("owner")
	if not db.query_with_bindings("SELECT owner_character_id FROM item_initializations WHERE owner_character_id=?;", [owner_id]):
		return _rollback("storage")
	if not db.query_result.is_empty():
		db.query("ROLLBACK;")
		return {"ok": true}
	# Explicit spike starter kit. A persisted marker prevents re-grants on relog.
	for index: int in 2:
		var bonus: int = 3 if index == 0 else 7
		var item: ItemInstance = ItemInstance.create(ItemDefinitions.IRON_SWORD, owner_id, [{"stat": "attack", "value": bonus}])
		if not _insert_item(item, index):
			return _rollback("storage")
	if not db.query_with_bindings("INSERT INTO item_initializations(owner_character_id) VALUES(?);", [owner_id]):
		return _rollback("storage")
	return _commit()

static func ensure_ground_claim_schema(database: SQLite) -> bool:
	return database.query("CREATE TABLE IF NOT EXISTS ground_item_claims (drop_uid TEXT PRIMARY KEY NOT NULL, owner_character_id INTEGER NOT NULL);")

func claim_ground_item(owner_id: int, drop_uid: String, bonus: int) -> Dictionary:
	# Only the world server supplies this roll and drop identity. The RPC accepts
	# a drop UID alone. Receipt + item + placement commit together, before despawn.
	if not ItemInstance.valid_uid(drop_uid) or bonus < 1 or bonus > 9:
		return _error("request")
	if not db.query("BEGIN IMMEDIATE;"):
		return _error("storage")
	if not db.query_with_bindings("SELECT drop_uid FROM ground_item_claims WHERE drop_uid=?;", [drop_uid]):
		return _rollback("storage")
	if not db.query_result.is_empty():
		return _rollback("claimed")
	if not db.query_with_bindings("SELECT player_id FROM players WHERE player_id=?;", [owner_id]):
		return _rollback("storage")
	if db.query_result.is_empty():
		return _rollback("owner")
	var position: int = _free_bag_position(owner_id, ItemDefinitions.IRON_SWORD.inventory_height)
	if position < 0:
		return _rollback("bag_full" if position == -1 else "storage")
	var item: ItemInstance = ItemInstance.create(ItemDefinitions.IRON_SWORD, owner_id, [{"stat": "attack", "value": bonus}])
	item.uid = drop_uid
	if not db.query_with_bindings("INSERT INTO ground_item_claims(drop_uid,owner_character_id) VALUES(?,?);", [drop_uid, owner_id]) or not _insert_item(item, position):
		return _rollback("storage")
	var result: Dictionary = _commit()
	if result.ok: result["uid"] = item.uid
	return result

func _insert_item(item: ItemInstance, bag_position: int) -> bool:
	var definition: ItemDefinition = ItemDefinitions.get_definition(item.definition_id)
	if definition == null or not _fits_position(item.owner_character_id, bag_position, definition.inventory_height): return false
	return db.query_with_bindings("INSERT INTO item_instances(uid,owner_character_id,definition_id,amount,upgrade_level,affixes_json,sockets_json,revision) VALUES(?,?,?,?,?,?,?,?);",
		[item.uid, item.owner_character_id, str(item.definition_id), item.amount, item.upgrade_level, JSON.stringify(item.affixes), JSON.stringify(item.sockets), item.revision]) \
		and _place(item.uid, item.owner_character_id, "bag", bag_position, "")

func inventory(owner_id: int) -> Dictionary:
	if not db.query_with_bindings(ITEM_SELECT + "WHERE i.owner_character_id=? AND p.owner_character_id=? ORDER BY CASE p.location WHEN 'equipment' THEN 0 ELSE 1 END,p.bag_position,i.uid;", [owner_id, owner_id]):
		return _error("storage")
	var rows: Array = db.query_result.duplicate(true)
	var items: Array = []
	var equipment: Dictionary = {}
	var stats: Dictionary = {"attack": 10.0}
	for row: Dictionary in rows:
		var item: ItemInstance = ItemInstance.from_row(row)
		if item == null:
			return _error("invalid_item")
		var definition: ItemDefinition = ItemDefinitions.get_definition(item.definition_id)
		if definition == null:
			return _error("unknown_definition")
		var snapshot: Dictionary = item.to_snapshot()
		snapshot["item_name"] = definition.item_name
		snapshot["icon_id"] = str(definition.icon_id)
		snapshot["stats"] = item.effective_stats(definition)
		snapshot["inventory_height"] = definition.inventory_height
		items.append(snapshot)
		if item.location == "equipment":
			equipment[str(item.equipment_slot)] = item.uid
			for stat: Variant in snapshot.stats:
				stats[stat] = float(stats.get(stat, 0)) + float(snapshot.stats[stat])
	return {"ok": true, "items": items, "equipment": equipment, "stats": stats}

func activate_item(owner_id: int, uid: String, expected_revision: int) -> Dictionary:
	if not ItemInstance.valid_uid(uid) or expected_revision < 0: return _error("request")
	if not db.query_with_bindings(ITEM_SELECT + "WHERE i.uid=? AND i.owner_character_id=? AND p.owner_character_id=?;", [uid,owner_id,owner_id]): return _error("storage")
	if db.query_result.is_empty(): return _error("owner")
	var item: ItemInstance = ItemInstance.from_row(db.query_result[0])
	if item == null: return _error("invalid_item")
	if item.revision != expected_revision: return _error("stale")
	var definition: ItemDefinition = ItemDefinitions.get_definition(item.definition_id)
	if definition == null: return _error("unknown_definition")
	match definition.primary_action:
		ItemDefinition.PrimaryAction.EQUIP:
			# Synchronous dispatch; the existing equip transaction rechecks ownership
			# and revision and remains the single implementation of equipment rules.
			return change_equipment(owner_id,uid,expected_revision,"equip")
		ItemDefinition.PrimaryAction.USE:
			return _error("unsupported")
		_:
			return _error("no_action")

func change_equipment(owner_id: int, uid: String, expected_revision: int, action: String) -> Dictionary:
	if action not in ["equip", "unequip"] or not ItemInstance.valid_uid(uid) or expected_revision < 0:
		return _error("request")
	if not db.query("BEGIN IMMEDIATE;"):
		return _error("storage")
	if not db.query_with_bindings(ITEM_SELECT + "WHERE i.uid=? AND i.owner_character_id=? AND p.owner_character_id=?;", [uid, owner_id, owner_id]):
		return _rollback("storage")
	if db.query_result.is_empty():
		return _rollback("owner")
	var item: ItemInstance = ItemInstance.from_row(db.query_result[0])
	if item == null:
		return _rollback("invalid_item")
	if item.revision != expected_revision:
		return _rollback("stale")
	var definition: ItemDefinition = ItemDefinitions.get_definition(item.definition_id)
	if definition == null or definition.equipment_slot == &"":
		return _rollback("slot")
	if (action == "equip" and item.location == "equipment") or (action == "unequip" and item.location == "bag"):
		return _commit()
	if action == "unequip":
		var position: int = _free_bag_position(owner_id, definition.inventory_height)
		if position == -2:
			return _rollback("storage")
		if position == -1:
			return _rollback("bag_full")
		if not _remove_placement(uid) or not _place(uid, owner_id, "bag", position, "") or not _increment_revision(uid, owner_id):
			return _rollback("storage")
	else:
		if not db.query_with_bindings("SELECT p.item_uid,i.definition_id FROM item_placements p JOIN item_instances i ON i.uid=p.item_uid WHERE p.owner_character_id=? AND p.location='equipment' AND p.equipment_slot=?;", [owner_id, str(definition.equipment_slot)]):
			return _rollback("storage")
		var previous_uid: String = "" if db.query_result.is_empty() else str(db.query_result[0].item_uid)
		var previous_position: int = item.bag_position
		if previous_uid != "":
			var previous_definition: ItemDefinition = ItemDefinitions.get_definition(StringName(db.query_result[0].definition_id))
			if previous_definition == null: return _rollback("unknown_definition")
			if not _fits_position(owner_id, previous_position, previous_definition.inventory_height, [uid]):
				previous_position = _free_bag_position(owner_id, previous_definition.inventory_height, [uid])
				if previous_position < 0: return _rollback("bag_full" if previous_position == -1 else "storage")
		# Remove placements, never item records. Unique indexes stay valid during
		# the swap, and rollback restores both locations if any statement fails.
		if not _remove_placement(uid):
			return _rollback("storage")
		if previous_uid != "":
			if not _remove_placement(previous_uid) or not _place(previous_uid, owner_id, "bag", previous_position, "") or not _increment_revision(previous_uid, owner_id):
				return _rollback("storage")
		if not _place(uid, owner_id, "equipment", -1, str(definition.equipment_slot)) or not _increment_revision(uid, owner_id):
			return _rollback("storage")
	return _commit()

func move_bag_item(owner_id: int, uid: String, expected_revision: int, position: int) -> Dictionary:
	if not ItemInstance.valid_uid(uid) or expected_revision < 0 or position < 0 or position >= BAG_CAPACITY:
		return _error("request")
	if not db.query("BEGIN IMMEDIATE;"):
		return _error("storage")
	if not db.query_with_bindings(ITEM_SELECT + "WHERE i.uid=? AND i.owner_character_id=? AND p.owner_character_id=?;", [uid, owner_id, owner_id]):
		return _rollback("storage")
	if db.query_result.is_empty():
		return _rollback("owner")
	var item: ItemInstance = ItemInstance.from_row(db.query_result[0])
	if item == null or item.location != "bag":
		return _rollback("placement")
	if item.revision != expected_revision:
		return _rollback("stale")
	if item.bag_position == position:
		return _commit()
	var definition: ItemDefinition = ItemDefinitions.get_definition(item.definition_id)
	if definition == null: return _rollback("unknown_definition")
	if InventoryGrid.cells(position, definition.inventory_height).is_empty(): return _rollback("request")
	var occupied: Dictionary = _occupied(owner_id, [uid])
	if occupied.has("error"): return _rollback("storage")
	if not InventoryGrid.fits(position, definition.inventory_height, occupied): return _rollback("occupied")
	if not db.query_with_bindings("UPDATE item_placements SET bag_position=? WHERE item_uid=? AND owner_character_id=? AND location='bag';", [position, uid, owner_id]) or not _increment_revision(uid, owner_id):
		return _rollback("storage")
	return _commit()

func _occupied(owner_id: int, excluded: Array = []) -> Dictionary:
	if not db.query_with_bindings(ITEM_SELECT + "WHERE i.owner_character_id=? AND p.owner_character_id=? AND p.location='bag';", [owner_id, owner_id]): return {"error": true}
	var occupied: Dictionary = {}
	for row: Dictionary in db.query_result:
		if str(row.uid) in excluded: continue
		var definition: ItemDefinition = ItemDefinitions.get_definition(StringName(row.definition_id))
		if definition == null: return {"error": true}
		var footprint: Array[int] = InventoryGrid.cells(int(row.bag_position), definition.inventory_height)
		if footprint.is_empty(): return {"error": true}
		for cell: int in footprint: occupied[cell] = true
	return occupied

func _fits_position(owner_id: int, position: int, height: int, excluded: Array = []) -> bool:
	var occupied: Dictionary = _occupied(owner_id, excluded)
	return not occupied.has("error") and InventoryGrid.fits(position, height, occupied)

func _free_bag_position(owner_id: int, height: int = 1, excluded: Array = []) -> int:
	var occupied: Dictionary = _occupied(owner_id, excluded)
	if occupied.has("error"): return -2
	for position: int in BAG_CAPACITY:
		if InventoryGrid.fits(position, height, occupied): return position
	return -1

static func migrate_grid(database: SQLite) -> bool:
	if not database.query("BEGIN IMMEDIATE;"): return false
	if not database.query(ITEM_SELECT + "ORDER BY p.owner_character_id,p.bag_position,i.uid;"):
		database.query("ROLLBACK;")
		return false
	var rows: Array = database.query_result.duplicate(true)
	var occupied_by_owner: Dictionary = {}
	for statement: String in ["ALTER TABLE item_placements RENAME TO item_placements_v14;", "DROP INDEX IF EXISTS item_bag_position;", "DROP INDEX IF EXISTS item_equipment_slot;", "CREATE TABLE item_placements (item_uid TEXT PRIMARY KEY NOT NULL, owner_character_id INTEGER NOT NULL, location TEXT NOT NULL CHECK(location IN ('bag','equipment')), bag_position INTEGER NOT NULL, equipment_slot TEXT NOT NULL, CHECK((location='bag' AND bag_position BETWEEN 0 AND 179 AND equipment_slot='') OR (location='equipment' AND bag_position=-1 AND equipment_slot<>'')));", "CREATE UNIQUE INDEX item_bag_position ON item_placements(owner_character_id,bag_position) WHERE location='bag';", "CREATE UNIQUE INDEX item_equipment_slot ON item_placements(owner_character_id,equipment_slot) WHERE location='equipment';"]:
		if not database.query(statement):
			database.query("ROLLBACK;")
			return false
	for row: Dictionary in rows:
		var position: int = int(row.bag_position)
		if row.location == "bag":
			var definition: ItemDefinition = ItemDefinitions.get_definition(StringName(row.definition_id))
			if definition == null:
				database.query("ROLLBACK;")
				return false
			var occupied: Dictionary = occupied_by_owner.get(int(row.owner_character_id), {})
			if not InventoryGrid.fits(position, definition.inventory_height, occupied):
				position = -1
				for candidate: int in BAG_CAPACITY:
					if InventoryGrid.fits(candidate, definition.inventory_height, occupied):
						position = candidate
						break
			if position < 0:
				database.query("ROLLBACK;")
				return false
			for cell: int in InventoryGrid.cells(position, definition.inventory_height): occupied[cell] = true
			occupied_by_owner[int(row.owner_character_id)] = occupied
		if not database.query_with_bindings("INSERT INTO item_placements(item_uid,owner_character_id,location,bag_position,equipment_slot) VALUES(?,?,?,?,?);", [row.uid, row.owner_character_id, row.location, position, row.equipment_slot]):
			database.query("ROLLBACK;")
			return false
		if position != int(row.bag_position) and not database.query_with_bindings("UPDATE item_instances SET revision=revision+1 WHERE uid=?;", [row.uid]):
			database.query("ROLLBACK;")
			return false
	if not database.query("DROP TABLE item_placements_v14;") or not database.query("UPDATE meta SET value='15' WHERE key='schema_version';") or not database.query("COMMIT;"):
		database.query("ROLLBACK;")
		return false
	return true

func _place(uid: String, owner_id: int, location: String, position: int, slot: String) -> bool:
	return db.query_with_bindings("INSERT INTO item_placements(item_uid,owner_character_id,location,bag_position,equipment_slot) VALUES(?,?,?,?,?);", [uid, owner_id, location, position, slot])

func _remove_placement(uid: String) -> bool:
	return db.query_with_bindings("DELETE FROM item_placements WHERE item_uid=?;", [uid])

func _increment_revision(uid: String, owner_id: int) -> bool:
	return db.query_with_bindings("UPDATE item_instances SET revision=revision+1 WHERE uid=? AND owner_character_id=?;", [uid, owner_id])

func _commit() -> Dictionary:
	if not db.query("COMMIT;"):
		return _rollback("storage")
	return {"ok": true}

func _rollback(reason: String) -> Dictionary:
	db.query("ROLLBACK;")
	return _error(reason)

func _error(reason: String) -> Dictionary:
	return {"ok": false, "error": reason}
