extends RefCounted
## Additive wallet revision feature; keeps identity-gated v18-v23 migration order.
static func ensure_schema(db: SqliteSoci) -> bool:
	if not db.query("PRAGMA table_info(account_wallets);"): return false
	var columns: Array = db.query_result.map(func(row: Dictionary) -> String: return str(row.name))
	if columns.is_empty(): return false
	var feature := "2" if columns.has("reserved_yang") else "1"
	if not db.query("SELECT value FROM meta WHERE key='wallet_revision_schema';"): return false
	if not db.query_result.is_empty() and str(db.query_result[0].value)==feature: return true
	if not db.query("BEGIN IMMEDIATE;"): return false
	var statements: Array[String] = []
	if not columns.has("wallet_revision"): statements.append("ALTER TABLE account_wallets ADD COLUMN wallet_revision INTEGER NOT NULL DEFAULT 0 CHECK(typeof(wallet_revision)='integer' AND wallet_revision>=0);")
	statements.append("DROP TRIGGER IF EXISTS account_wallet_revision;")
	var changed := "OLD.yang IS NOT NEW.yang"
	if columns.has("reserved_yang"): changed += " OR OLD.reserved_yang IS NOT NEW.reserved_yang"
	statements.append("CREATE TRIGGER account_wallet_revision AFTER UPDATE ON account_wallets WHEN %s BEGIN UPDATE account_wallets SET wallet_revision=wallet_revision+1 WHERE account_id=NEW.account_id; END;" % changed)
	statements.append("INSERT OR REPLACE INTO meta(key,value) VALUES('wallet_revision_schema','%s');" % feature)
	statements.append("COMMIT;")
	for statement: String in statements:
		if not db.query(statement):
			db.query("ROLLBACK;")
			return false
	return true

static func read(db: SqliteSoci, account: int, applied_pending: int = 0) -> Dictionary:
	if not db.query_with_bindings("SELECT w.*,m.value AS authority_id FROM account_wallets w JOIN meta m ON m.key='economy_authority_id' WHERE account_id=?;",[account]): return {"ok":false,"error":"storage"}
	if db.query_result.is_empty(): return {"ok":false,"error":"owner"}
	var row: Dictionary = db.query_result[0]
	if not row.has("wallet_revision"): return {"ok":false,"error":"storage"}
	return {"authority_id":str(row.authority_id),"account_id":account,"revision":int(row.wallet_revision),"balance":int(row.yang),"reserved_yang":int(row.get("reserved_yang",0)),"pending_applied":applied_pending}
