extends RefCounted
## P1b opt-in schema only. Not a World backend switch or a legacy data migration.
## Account IDs are trusted Master identities, never client-supplied identities.
const VERSION: int = 1

static func ensure_schema(db: Object) -> bool:
	if db.in_transaction() or not db.begin(): return false
	var statements: Array[String] = [
		"CREATE SCHEMA IF NOT EXISTS economy;",
		"CREATE TABLE IF NOT EXISTS economy.schema_versions (feature TEXT PRIMARY KEY, version BIGINT NOT NULL CHECK(version>0));",
		"CREATE TABLE IF NOT EXISTS economy.meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);"
	]
	for sql: String in statements:
		if not db.execute(sql).ok:
			db.rollback()
			return false
	var version: Dictionary = db.query("SELECT version FROM economy.schema_versions WHERE feature='wallet';")
	if not version.ok or (not version.rows.is_empty() and int(version.rows[0].version) != VERSION):
		db.rollback()
		return false
	if version.rows.is_empty():
		statements = [
			"CREATE TABLE economy.accounts (account_id BIGINT PRIMARY KEY CHECK(account_id>0));",
			"CREATE TABLE economy.account_wallets (account_id BIGINT PRIMARY KEY REFERENCES economy.accounts(account_id), yang BIGINT NOT NULL DEFAULT 1500 CHECK(yang BETWEEN 0 AND 9000000000000000), reserved_yang BIGINT NOT NULL DEFAULT 0 CHECK(reserved_yang>=0 AND reserved_yang<=yang), wallet_revision BIGINT NOT NULL DEFAULT 0 CHECK(wallet_revision>=0));",
			"""CREATE FUNCTION economy.advance_wallet_revision() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.yang IS DISTINCT FROM OLD.yang OR NEW.reserved_yang IS DISTINCT FROM OLD.reserved_yang THEN
  NEW.wallet_revision := OLD.wallet_revision + 1;
 ELSE
  NEW.wallet_revision := OLD.wallet_revision;
 END IF;
 RETURN NEW;
END; $$;""",
			"CREATE TRIGGER account_wallet_revision BEFORE UPDATE ON economy.account_wallets FOR EACH ROW EXECUTE FUNCTION economy.advance_wallet_revision();",
			"INSERT INTO economy.schema_versions(feature,version) VALUES('wallet',1);"
		]
		for sql: String in statements:
			if not db.execute(sql).ok:
				db.rollback()
				return false
	var authority := Crypto.new().generate_random_bytes(16).hex_encode()
	if not db.execute("INSERT INTO economy.meta(key,value) VALUES('economy_authority_id',:authority) ON CONFLICT(key) DO NOTHING;", {"authority":authority}).ok:
		db.rollback()
		return false
	if db.commit(): return true
	db.rollback()
	return false
