class_name UpgradeStoreSqlite
extends RefCounted
## One connection/transaction for material, pending income, spend and item mutation.
var db: SQLite
func _init(database: SQLite) -> void:
	db = database

func candidate(owner_id: int, uid: String, revision: int, recipe: UpgradeDefinition) -> Dictionary:
	if not ItemInstance.valid_uid(uid) or revision < -1: return {"ok":false, "error":"request"}
	if not db.query_with_bindings(ItemStoreSqlite.ITEM_SELECT + "WHERE i.uid=? AND i.owner_character_id=? AND p.owner_character_id=?;", [uid,owner_id,owner_id]): return {"ok":false, "error":"storage"}
	if db.query_result.is_empty(): return {"ok":false, "error":"owner"}
	var item: ItemInstance = ItemInstance.from_row(db.query_result[0])
	if item == null: return {"ok":false, "error":"invalid_item"}
	if revision >= 0 and item.revision != revision: return {"ok":false, "error":"stale"}
	if item.location != "bag": return {"ok":false, "error":"placement"}
	if item.definition_id != recipe.item_definition_id or item.amount != 1: return {"ok":false, "error":"unsupported_item"}
	return {"ok":true, "item":item}

func upgrade(owner_id: int, pending_yang: int, recipe: UpgradeDefinition, uid: String, revision: int) -> Dictionary:
	if revision < 0 or recipe == null or not recipe.validation_errors().is_empty(): return {"ok":false, "error":"request"}
	if not db.query("BEGIN IMMEDIATE;"): return {"ok":false, "error":"storage"}
	var selected: Dictionary = candidate(owner_id,uid,revision,recipe)
	if not selected.ok: return _rollback(str(selected.error))
	var item: ItemInstance = selected.item
	if item.upgrade_level != recipe.from_level: return _rollback("upgrade_level")
	var definition: ItemDefinition = ItemDefinitions.get_definition(item.definition_id)
	var receiving: Dictionary = ItemStoreSqlite.new(db).resolve_inventory_position(owner_id,definition.inventory_height,item.bag_position,[uid])
	if not receiving.ok: return _rollback(str(receiving.error))
	if not db.query_with_bindings(ItemStoreSqlite.ITEM_SELECT + "WHERE i.owner_character_id=? AND p.owner_character_id=? AND p.location='bag' AND i.definition_id=? AND i.upgrade_level=0 ORDER BY i.uid;",[owner_id,owner_id,str(recipe.material_definition_id)]): return _rollback("storage")
	var materials: Array = db.query_result.duplicate(true)
	var total: int = 0
	for row: Dictionary in materials: total += int(row.amount)
	if total < recipe.material_amount: return _rollback("material")
	var remaining: int = recipe.material_amount
	for row: Dictionary in materials:
		if remaining == 0: break
		var used: int = mini(remaining,int(row.amount))
		if used == int(row.amount):
			if not db.query_with_bindings("DELETE FROM item_placements WHERE item_uid=? AND owner_character_id=?;",[row.uid,owner_id]) or not db.query_with_bindings("DELETE FROM item_instances WHERE uid=? AND owner_character_id=? AND revision=?;",[row.uid,owner_id,row.revision]): return _rollback("storage")
		else:
			if not db.query_with_bindings("UPDATE item_instances SET amount=amount-?,revision=revision+1 WHERE uid=? AND owner_character_id=? AND revision=?;",[used,row.uid,owner_id,row.revision]): return _rollback("storage")
		remaining -= used
	var spent: Dictionary = WalletStoreSqlite.new(db).spend_in_transaction(owner_id,pending_yang,recipe.yang_cost)
	if not spent.ok: return _rollback(str(spent.error))
	if not db.query_with_bindings("UPDATE item_instances SET upgrade_level=?,revision=revision+1 WHERE uid=? AND owner_character_id=? AND revision=? AND upgrade_level=?;",[recipe.to_level,uid,owner_id,revision,recipe.from_level]): return _rollback("storage")
	if not db.query("SELECT changes() AS n;") or int(db.query_result[0].n) != 1: return _rollback("stale")
	if not db.query("COMMIT;"): return _rollback("storage")
	return {"ok":true, "balance":spent.balance}

func _rollback(error: String) -> Dictionary:
	db.query("ROLLBACK;")
	return {"ok":false, "error":error}
