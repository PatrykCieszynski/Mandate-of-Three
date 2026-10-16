extends RefCounted
## Character-local grant/pickup markers only; no account Storage or escrow.
const ItemsSchema = preload("res://source/server/world/database/postgres/npc_shop_schema_postgres.gd")

static func ensure_schema(db: Object) -> bool:
	if not ItemsSchema.ensure_schema(db) or not db.begin(): return false
	var result: Dictionary=db.query("SELECT version FROM economy.schema_versions WHERE feature='inventory';")
	if not result.ok or (not result.rows.is_empty() and int(result.rows[0].version)!=1):
		db.rollback()
		return false
	if result.rows.is_empty():
		for sql: String in [
			"CREATE TABLE economy.item_initializations (owner_character_id BIGINT PRIMARY KEY REFERENCES economy.characters(character_id));",
			"CREATE TABLE economy.ground_item_claims (drop_uid TEXT PRIMARY KEY CHECK(drop_uid ~ '^[0-9a-f]{32}$'),owner_character_id BIGINT NOT NULL REFERENCES economy.characters(character_id));",
			"INSERT INTO economy.schema_versions(feature,version) VALUES('inventory',1);"
		]:
			if not db.execute(sql).ok:
				db.rollback()
				return false
	if db.commit(): return true
	db.close()
	return false
