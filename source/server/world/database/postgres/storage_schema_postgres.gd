extends RefCounted
## Account Storage is an explicit extension of character custody, not an escrow
## placeholder. The original item owner remains provenance until withdrawal.
const InventorySchema = preload("res://source/server/world/database/postgres/inventory_schema_postgres.gd")

static func ensure_schema(db: Object) -> bool:
	if not InventorySchema.ensure_schema(db) or not db.begin(): return false
	var result: Dictionary=db.query("SELECT version FROM economy.schema_versions WHERE feature='storage';")
	if not result.ok or (not result.rows.is_empty() and int(result.rows[0].version)!=1):
		db.rollback()
		return false
	if result.rows.is_empty():
		for sql: String in [
			"ALTER TABLE economy.characters ADD CONSTRAINT character_account_identity UNIQUE(character_id,account_id);",
			"ALTER TABLE economy.item_custody ADD COLUMN storage_account_id BIGINT REFERENCES economy.accounts(account_id);",
			"ALTER TABLE economy.item_custody ADD CONSTRAINT storage_provenance_account FOREIGN KEY(owner_id,storage_account_id) REFERENCES economy.characters(character_id,account_id) DEFERRABLE INITIALLY DEFERRED;",
			"ALTER TABLE economy.item_custody DROP CONSTRAINT item_custody_location_check, DROP CONSTRAINT item_custody_check;",
			"ALTER TABLE economy.item_custody ADD CONSTRAINT item_custody_location_check CHECK(location IN ('bag','equipment','account_storage')), ADD CONSTRAINT item_custody_check CHECK((location='bag' AND position BETWEEN 0 AND 179 AND equipment_slot='' AND storage_account_id IS NULL) OR (location='equipment' AND position=-1 AND equipment_slot<>'' AND storage_account_id IS NULL) OR (location='account_storage' AND position BETWEEN 0 AND 269 AND equipment_slot='' AND storage_account_id IS NOT NULL));",
			"CREATE UNIQUE INDEX custody_storage_position ON economy.item_custody(storage_account_id,position) WHERE location='account_storage';",
			"INSERT INTO economy.schema_versions(feature,version) VALUES('storage',1);"
		]:
			if not db.execute(sql).ok:
				db.rollback()
				return false
	if db.commit(): return true
	db.close()
	return false
