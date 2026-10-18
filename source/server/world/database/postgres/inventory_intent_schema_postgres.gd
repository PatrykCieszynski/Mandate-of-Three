extends RefCounted
const Prior = preload("res://source/server/world/database/postgres/inventory_schema_postgres.gd")

static func ensure_schema(db: Object) -> bool:
	if not Prior.ensure_schema(db) or not db.begin(): return false
	var found: Dictionary=db.query("SELECT version FROM economy.schema_versions WHERE feature='inventory_intents';")
	if not found.ok or (not found.rows.is_empty() and int(found.rows[0].version)!=1):
		db.rollback()
		return false
	if found.rows.is_empty():
		for sql: String in [
			"CREATE TABLE economy.inventory_intents(sequence BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,account_id BIGINT NOT NULL REFERENCES economy.accounts(account_id),operation_id TEXT NOT NULL,character_id BIGINT NOT NULL REFERENCES economy.characters(character_id),action TEXT NOT NULL CHECK(action IN ('move','equip','unequip','activate')),item_uid TEXT NOT NULL CHECK(item_uid ~ '^[0-9a-f]{32}$'),expected_revision BIGINT NOT NULL CHECK(expected_revision>=0),position INTEGER NOT NULL,request_json TEXT NOT NULL,state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','terminal')),result_json TEXT,PRIMARY KEY(account_id,operation_id),CHECK((state='pending' AND result_json IS NULL) OR (state='terminal' AND result_json IS NOT NULL)));",
			"CREATE INDEX inventory_intents_discovery ON economy.inventory_intents(character_id,sequence);",
			"INSERT INTO economy.schema_versions(feature,version) VALUES('inventory_intents',1);"
		]:
			if not db.execute(sql).ok:
				db.rollback()
				return false
	if db.commit(): return true
	db.close()
	return false
