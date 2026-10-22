extends RefCounted
const Prior = preload("res://source/server/world/database/postgres/inventory_intent_schema_postgres.gd")

static func ensure_schema(db: Object) -> bool:
	if not Prior.ensure_schema(db) or not db.begin(): return false
	var found: Dictionary=db.query("SELECT version FROM economy.schema_versions WHERE feature='inventory_sessions';")
	if not found.ok or (not found.rows.is_empty() and int(found.rows[0].version)!=1):
		db.rollback()
		return false
	if found.rows.is_empty():
		for sql: String in [
			"CREATE TABLE economy.inventory_sessions(account_id BIGINT PRIMARY KEY REFERENCES economy.accounts(account_id),character_id BIGINT NOT NULL REFERENCES economy.characters(character_id),epoch BIGINT NOT NULL CHECK(epoch>0),session_fingerprint TEXT NOT NULL CHECK(session_fingerprint ~ '^[0-9a-f]{64}$'),phase TEXT NOT NULL CHECK(phase IN ('recovering','ready','revoked')));",
			"INSERT INTO economy.schema_versions(feature,version) VALUES('inventory_sessions',1);"
		]:
			if not db.execute(sql).ok:
				db.rollback()
				return false
	if db.commit(): return true
	db.close()
	return false
