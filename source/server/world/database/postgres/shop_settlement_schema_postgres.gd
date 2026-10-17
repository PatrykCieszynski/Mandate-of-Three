extends RefCounted
## Additive seller proceeds only. Historical receipts are never backfilled.
const SellerSchema = preload("res://source/server/world/database/postgres/shop_schema_postgres.gd")

static func ensure_schema(db: Object) -> bool:
	if not SellerSchema.ensure_schema(db) or not db.begin(): return false
	var result: Dictionary=db.query("SELECT version FROM economy.schema_versions WHERE feature='shop_settlement';")
	if not result.ok or (not result.rows.is_empty() and int(result.rows[0].version)!=1):
		db.rollback()
		return false
	if result.rows.is_empty():
		for sql: String in [
			"CREATE TABLE economy.account_shop_revenue(account_id BIGINT PRIMARY KEY REFERENCES economy.accounts(account_id),yang BIGINT NOT NULL DEFAULT 0 CHECK(yang>=0));",
			"INSERT INTO economy.schema_versions(feature,version) VALUES('shop_settlement',1);"
		]:
			if not db.execute(sql).ok:
				db.rollback()
				return false
	if db.commit(): return true
	db.close()
	return false
