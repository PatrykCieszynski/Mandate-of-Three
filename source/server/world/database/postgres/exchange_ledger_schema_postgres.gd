extends RefCounted
## Fungible balances only; orders/reservations/matching are a separate port.
const SearchSchema = preload("res://source/server/world/database/postgres/auction_search_schema_postgres.gd")

static func ensure_schema(db: Object) -> bool:
	if not SearchSchema.ensure_schema(db) or not db.begin(): return false
	var result: Dictionary=db.query("SELECT version FROM economy.schema_versions WHERE feature='exchange_ledger';")
	if not result.ok or (not result.rows.is_empty() and int(result.rows[0].version)!=1):
		db.rollback()
		return false
	if result.rows.is_empty():
		for sql: String in [
			"CREATE TABLE economy.exchange_assets(account_id BIGINT NOT NULL REFERENCES economy.accounts(account_id),asset_id TEXT NOT NULL,free BIGINT NOT NULL DEFAULT 0 CHECK(free BETWEEN 0 AND 9000000000000000),reserved BIGINT NOT NULL DEFAULT 0 CHECK(reserved BETWEEN 0 AND 9000000000000000),PRIMARY KEY(account_id,asset_id),CHECK(free<=9000000000000000-reserved));",
			"INSERT INTO economy.schema_versions(feature,version) VALUES('exchange_ledger',1);"
		]:
			if not db.execute(sql).ok:
				db.rollback()
				return false
	if db.commit(): return true
	db.close()
	return false
