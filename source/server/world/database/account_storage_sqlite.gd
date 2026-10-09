class_name AccountStorageSqlite
extends RefCounted
## Account membership is resolved from the authenticated character, never the RPC.
const COLUMNS: int = 15
const ROWS: int = 9
const PAGES: int = 2
const PAGE_CELLS: int = COLUMNS * ROWS
const CAPACITY: int = PAGE_CELLS * PAGES
const SELECT: String = "SELECT i.*, 'storage' AS location,s.position AS bag_position,'' AS equipment_slot FROM item_instances i JOIN account_storage s ON s.item_uid=i.uid "
var db: SQLite
func _init(database: SQLite) -> void:
	db = database
static func ensure_schema(database: SQLite) -> bool:
	if not database.query("BEGIN IMMEDIATE;"): return false
	for statement: String in ["CREATE TABLE IF NOT EXISTS account_storage (item_uid TEXT PRIMARY KEY NOT NULL,account_name TEXT NOT NULL,position INTEGER NOT NULL CHECK(position BETWEEN 0 AND 269));", "CREATE UNIQUE INDEX IF NOT EXISTS account_storage_position ON account_storage(account_name,position);", "INSERT OR REPLACE INTO meta(key,value) VALUES('schema_version','16');"]:
		if not database.query(statement):
			database.query("ROLLBACK;")
			return false
	if database.query("COMMIT;"): return true
	database.query("ROLLBACK;")
	return false
static func cells(position: int, height: int) -> Array[int]:
	var result: Array[int] = []
	if position < 0 or position >= CAPACITY or height < 1 or height > 3 or (position % PAGE_CELLS) / COLUMNS + height > ROWS: return result
	for offset: int in height: result.append(position + offset * COLUMNS)
	return result
func account(character_id: int) -> String:
	if not db.query_with_bindings("SELECT account_name FROM players WHERE player_id=?;", [character_id]) or db.query_result.is_empty(): return ""
	return str(db.query_result[0].account_name)
func snapshot(character_id: int) -> Dictionary:
	var name: String = account(character_id)
	if name == "": return {"ok":false,"error":"owner"}
	if not db.query_with_bindings(SELECT + "WHERE s.account_name=? ORDER BY s.position;",[name]): return {"ok":false,"error":"storage"}
	var items: Array = []
	for row: Dictionary in db.query_result.duplicate(true):
		var item: ItemInstance = ItemInstance.from_row(row)
		if item == null: return {"ok":false,"error":"invalid_item"}
		var definition: ItemDefinition = ItemDefinitions.get_definition(item.definition_id)
		if definition == null: return {"ok":false,"error":"unknown_definition"}
		var display: Dictionary = item.to_snapshot()
		display.merge({"item_name":definition.item_name,"icon_id":str(definition.icon_id),"stats":item.effective_stats(definition),"inventory_height":definition.inventory_height})
		items.append(display)
	return {"ok":true,"items":items}
func transfer(character_id: int, uid: String, revision: int, source: String, destination: String, position: int = -1) -> Dictionary:
	if source not in ["inventory","storage"] or destination not in ["inventory","storage"] or not ItemInstance.valid_uid(uid) or revision < 0 or position < -1: return {"ok":false,"error":"request"}
	if not db.query("BEGIN IMMEDIATE;"): return {"ok":false,"error":"storage"}
	var name: String = account(character_id)
	if name == "": return _finish(false,"owner")
	var query: String = SELECT + "WHERE s.account_name=? AND i.uid=?;" if source == "storage" else ItemStoreSqlite.ITEM_SELECT + "WHERE i.owner_character_id=? AND p.owner_character_id=? AND i.uid=? AND p.location='bag';"
	var bindings: Array = [name,uid] if source == "storage" else [character_id,character_id,uid]
	if not db.query_with_bindings(query,bindings): return _finish(false,"storage")
	if db.query_result.is_empty(): return _finish(false,"owner")
	var item: ItemInstance = ItemInstance.from_row(db.query_result[0])
	if item == null: return _finish(false,"invalid_item")
	if item.revision != revision: return _finish(false,"stale")
	var definition: ItemDefinition = ItemDefinitions.get_definition(item.definition_id)
	if definition == null: return _finish(false,"unknown_definition")
	query = SELECT + "WHERE s.account_name=?;" if destination == "storage" else ItemStoreSqlite.ITEM_SELECT + "WHERE p.owner_character_id=? AND i.owner_character_id=? AND p.location='bag';"
	bindings = [name] if destination == "storage" else [character_id,character_id]
	if not db.query_with_bindings(query,bindings): return _finish(false,"storage")
	var occupied: Dictionary = {}
	for row: Dictionary in db.query_result:
		if str(row.uid) == uid: continue
		var other: ItemDefinition = ItemDefinitions.get_definition(StringName(row.definition_id))
		if other == null: return _finish(false,"unknown_definition")
		var footprint: Array[int] = cells(int(row.bag_position),other.inventory_height) if destination == "storage" else InventoryGrid.cells(int(row.bag_position),other.inventory_height)
		if footprint.is_empty(): return _finish(false,"placement")
		for cell: int in footprint: occupied[cell] = true
	var capacity: int = CAPACITY if destination == "storage" else InventoryGrid.CAPACITY
	if position == -1:
		for candidate: int in capacity:
			if _fits(destination,candidate,definition.inventory_height,occupied):
				position = candidate
				break
		if position == -1: return _finish(false,"full")
	if not _fits(destination,position,definition.inventory_height,occupied): return _finish(false,"occupied")
	if source == destination and position == item.bag_position: return _finish(true)
	query = "DELETE FROM account_storage WHERE item_uid=?;" if source == "storage" else "DELETE FROM item_placements WHERE item_uid=?;"
	if not db.query_with_bindings(query,[uid]): return _finish(false,"storage")
	if destination == "storage":
		if not db.query_with_bindings("INSERT INTO account_storage(item_uid,account_name,position) VALUES(?,?,?);",[uid,name,position]): return _finish(false,"storage")
	else:
		if not db.query_with_bindings("INSERT INTO item_placements(item_uid,owner_character_id,location,bag_position,equipment_slot) VALUES(?,?,'bag',?,'');",[uid,character_id,position]): return _finish(false,"storage")
	# A stored item's account placement owns access; character owner is provenance
	# until withdrawal atomically assigns the receiving character.
	if not db.query_with_bindings("UPDATE item_instances SET owner_character_id=?,revision=revision+1 WHERE uid=?;",[character_id if destination == "inventory" else item.owner_character_id,uid]): return _finish(false,"storage")
	return _finish(true)
func _fits(destination: String,position: int,height: int,occupied: Dictionary) -> bool:
	var footprint: Array[int] = cells(position,height) if destination == "storage" else InventoryGrid.cells(position,height)
	return not footprint.is_empty() and not footprint.any(func(cell: int) -> bool: return occupied.has(cell))
func _finish(ok: bool,error: String = "") -> Dictionary:
	if ok and db.query("COMMIT;"): return {"ok":true}
	db.query("ROLLBACK;")
	return {"ok":false,"error":error if error != "" else "storage"}
