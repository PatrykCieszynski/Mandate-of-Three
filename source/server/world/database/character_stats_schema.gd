extends RefCounted
## Additive offline PG / disposable SQLite provisioning. Old rows stay v0 until decoded.
static func sqlite(db: SqliteSoci) -> bool:
	if not db.query("PRAGMA table_info(players);"): return false
	var found := false
	for row: Dictionary in db.query_result:
		if row.name=="progression_json": found=true
	if not found and not db.query("ALTER TABLE players ADD COLUMN progression_json TEXT NOT NULL DEFAULT '{}';"): return false
	return db.query("CREATE TABLE IF NOT EXISTS stats_commands(character_id INTEGER NOT NULL,command_id TEXT NOT NULL,attribute TEXT NOT NULL,PRIMARY KEY(character_id,command_id));")
static func postgres(db: Object) -> bool:
	if not db.begin(): return false
	for sql: String in [
		"ALTER TABLE realm.players ADD COLUMN IF NOT EXISTS progression_json TEXT NOT NULL DEFAULT '{}';",
		"CREATE TABLE IF NOT EXISTS realm.stats_commands(character_id BIGINT NOT NULL REFERENCES realm.players(player_id) ON DELETE CASCADE,command_id TEXT NOT NULL,attribute TEXT NOT NULL,PRIMARY KEY(character_id,command_id));",
		"INSERT INTO economy.schema_versions(feature,version) VALUES('character_stats',1) ON CONFLICT(feature) DO NOTHING;"
	]:
		if not db.execute(sql).ok: db.rollback();return false
	if db.commit(): return true
	db.close();return false
