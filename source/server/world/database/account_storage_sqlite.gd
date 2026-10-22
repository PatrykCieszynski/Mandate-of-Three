class_name AccountStorageSqlite
extends RefCounted
## Account membership is resolved from the authenticated character, never the RPC.
const Grid = preload("res://source/common/gameplay/items/domain/storage_grid.gd")
const COLUMNS: int = Grid.COLUMNS
const ROWS: int = Grid.ROWS
const PAGES: int = Grid.PAGES
const PAGE_CELLS: int = Grid.PAGE_CELLS
const CAPACITY: int = Grid.CAPACITY
const SELECT: String = "SELECT i.*, 'storage' AS location,s.position AS bag_position,'' AS equipment_slot FROM item_instances i JOIN account_storage s ON s.item_uid=i.uid "
var db: SQLite
# Last transfer mutated durable custody/placement, excluding same-cell success.
var committed := false
var receipt_replay := false
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
	return Grid.cells(position,height)
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
	# Trusted standalone/tooling wrapper; production commands use transfer_command.
	receipt_replay = false
	committed = false
	if not db.query("BEGIN IMMEDIATE;"): return _error("storage")
	var result := _transfer_in_transaction(character_id,uid,revision,source,destination,position)
	return _finish(bool(result.ok),str(result.get("error","")),bool(result.get("mutated",false)))

func transfer_command(character_id: int, uid: String, revision: int, source: String, destination: String, position: int, operation_id: String) -> Dictionary:
	committed = false
	receipt_replay = false
	var transaction := EconomyCommandSqlite.new(db)
	# Account scope never retargets an intent to another issuing/receiving character.
	if not transaction.begin(character_id,operation_id,"storage",[character_id,uid,revision,source,destination,position]):
		receipt_replay = bool(transaction.cached.get("ok",false))
		return transaction.cached
	var result := _transfer_in_transaction(character_id,uid,revision,source,destination,position)
	if not result.ok: return transaction.rollback(str(result.error))
	var mutated := bool(result.mutated)
	result = transaction.commit({"ok":true})
	committed = transaction.committed and mutated
	return result

func transfer_receipt(character_id: int, operation_id: String) -> Dictionary:
	if operation_id.is_empty() or operation_id.length() > 96: return _error("request")
	var account_id := WorldStoreSqlite.new(db).resolve_account_id(character_id)
	if account_id <= 0: return _error("owner")
	if not db.query_with_bindings("SELECT request_json,result_json FROM market_commands WHERE account_id=? AND command_id=? AND kind='storage';",[account_id,operation_id]): return _error("storage")
	if db.query_result.is_empty(): return _error("unknown_command")
	var row: Dictionary = db.query_result[0]
	var args: Variant = JSON.parse_string(row.request_json)
	if not args is Array or args.size() != 6: return _error("storage")
	if int(args[0]) != character_id: return _error("unknown_command")
	var result: Variant = EconomyCommandSqlite.decode_result(row.result_json)
	if not result is Dictionary or not result.get("ok",false): return _error("storage")
	return result

func _error(error: String) -> Dictionary:
	return {"ok":false,"error":error}

func _transfer_in_transaction(character_id: int, uid: String, revision: int, source: String, destination: String, position: int) -> Dictionary:
	if (source == "inventory" and destination == "inventory") or source not in ["inventory","storage"] or destination not in ["inventory","storage"] or not ItemInstance.valid_uid(uid) or revision < 0 or position < -1: return {"ok":false,"error":"request"}
	var name: String = account(character_id)
	if name == "": return _error("owner")
	var query: String = SELECT + "WHERE s.account_name=? AND i.uid=?;" if source == "storage" else ItemStoreSqlite.ITEM_SELECT + "WHERE i.owner_character_id=? AND p.owner_character_id=? AND i.uid=? AND p.location='bag';"
	var bindings: Array = [name,uid] if source == "storage" else [character_id,character_id,uid]
	if not db.query_with_bindings(query,bindings): return _error("storage")
	if db.query_result.is_empty(): return _error("owner")
	var item: ItemInstance = ItemInstance.from_row(db.query_result[0])
	if item == null: return _error("invalid_item")
	if item.revision != revision: return _error("stale")
	var definition: ItemDefinition = ItemDefinitions.get_definition(item.definition_id)
	if definition == null: return _error("unknown_definition")
	if destination == "inventory":
		var receiving: Dictionary = ItemStoreSqlite.new(db).resolve_inventory_position(character_id, definition.inventory_height, position)
		if not receiving.ok:
			var reason: String = str(receiving.error)
			return _error( "full" if reason == "inventory_full" else ("occupied" if reason == "request" else reason))
		position = int(receiving.position)
	else:
		query = SELECT + "WHERE s.account_name=?;"
		bindings = [name]
		if not db.query_with_bindings(query,bindings): return _error("storage")
		var occupied: Dictionary = {}
		for row: Dictionary in db.query_result:
			if str(row.uid) == uid: continue
			var other: ItemDefinition = ItemDefinitions.get_definition(StringName(row.definition_id))
			if other == null: return _error("unknown_definition")
			var footprint: Array[int] = cells(int(row.bag_position),other.inventory_height)
			if footprint.is_empty(): return _error("placement")
			for cell: int in footprint: occupied[cell] = true
		var capacity: int = CAPACITY
		if position == -1:
			for candidate: int in capacity:
				if _fits(candidate,definition.inventory_height,occupied):
					position = candidate
					break
			if position == -1: return _error("full")
		if not _fits(position,definition.inventory_height,occupied): return _error("occupied")
	if source == destination and position == item.bag_position: return {"ok":true,"mutated":false}
	query = "DELETE FROM account_storage WHERE item_uid=?;" if source == "storage" else "DELETE FROM item_placements WHERE item_uid=?;"
	if not db.query_with_bindings(query,[uid]): return _error("storage")
	# Prepare provenance before inserting a character placement; custody validates it.
	if not db.query_with_bindings("UPDATE item_instances SET owner_character_id=?,revision=revision+1 WHERE uid=?;",[character_id if destination == "inventory" else item.owner_character_id,uid]): return _error("storage")
	if destination == "storage":
		if not db.query_with_bindings("INSERT INTO account_storage(item_uid,account_name,position) VALUES(?,?,?);",[uid,name,position]): return _error("storage")
	else:
		if not db.query_with_bindings("INSERT INTO item_placements(item_uid,owner_character_id,location,bag_position,equipment_slot) VALUES(?,?,'bag',?,'');",[uid,character_id,position]): return _error("storage")
	# A stored item's account placement owns access; character owner is provenance
	# until withdrawal atomically assigns the receiving character.
	return {"ok":true,"mutated":true}
func _fits(position: int,height: int,occupied: Dictionary) -> bool:
	var footprint: Array[int] = cells(position,height)
	return not footprint.is_empty() and not footprint.any(func(cell: int) -> bool: return occupied.has(cell))
func _finish(ok: bool,error: String = "", mutated: bool = true) -> Dictionary:
	if ok and db.query("COMMIT;"):
		committed = mutated
		return {"ok":true}
	db.query("ROLLBACK;")
	return {"ok":false,"error":error if error != "" else "storage"}
