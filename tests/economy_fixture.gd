class_name EconomyFixture
extends RefCounted
## Test Master enrollment only. Production never invents IDs from a character/name.
static func create_character(store: WorldStoreSqlite, name: String, data: Dictionary, migrate_custody: bool = true) -> int:
	var db := store.db
	assert(db.query("SELECT value FROM meta WHERE key='schema_version';"))
	if int(db.query_result[0].value) < 18:
		assert(WalletStoreSqlite.migrate_accounts(db,{}).ok)
	if migrate_custody: assert(MarketStoreSqlite.ensure_schema(db))
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

static func insert_item(store: ItemStoreSqlite, item: ItemInstance, position: int) -> bool:
	if not store.db.query("BEGIN IMMEDIATE;"): return false
	var result := store.receive_item_in_transaction(item,position)
	if result.ok and store.db.query("COMMIT;"): return true
	store.db.query("ROLLBACK;")
	return false

static func destroy_item(db: SqliteSoci, uid: String) -> bool:
	if not db.query("BEGIN IMMEDIATE;"): return false
	if db.query_with_bindings("DELETE FROM item_placements WHERE item_uid=?;",[uid]) and db.query_with_bindings("DELETE FROM item_instances WHERE uid=?;",[uid]) and db.query("COMMIT;"): return true
	db.query("ROLLBACK;")
	return false
