class_name EconomyFixture
extends RefCounted
## Test Master enrollment only. Production never invents IDs from a character/name.
static func create_character(store: WorldStoreSqlite, name: String, data: Dictionary) -> int:
	var db := store.db
	assert(db.query("SELECT value FROM meta WHERE key='schema_version';"))
	if int(db.query_result[0].value) < 18:
		assert(WalletStoreSqlite.migrate_accounts(db,{}).ok)
	assert(db.query_with_bindings("SELECT master_account_id FROM accounts WHERE account_name=?;",[name]))
	if db.query_result.is_empty():
		assert(db.query("SELECT COALESCE(MAX(master_account_id),999)+1 AS id FROM accounts;"))
		assert(store.bind_account_identity(name,int(db.query_result[0].id),true))
	return store.create_player_character(name,data)

static func prepare(persistence: WorldDatabase) -> void:
	assert(persistence.db.query("SELECT account_name,master_account_id FROM accounts;"))
	var manifest := {}
	for row: Dictionary in persistence.db.query_result: manifest[row.account_name] = row.master_account_id
	assert(persistence.prepare_account_wallets(manifest).ok)
