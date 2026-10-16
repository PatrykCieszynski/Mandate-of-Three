class_name MarketStoreSqlite
extends RefCounted
## Shop domain SQL. Atomic commands compose the shared SQLite receipt boundary.
const COLUMNS := 5
const ROWS := 8
const CAPACITY := COLUMNS*ROWS
const MAX_REVENUE := 9223372036854775807 # SQLite integer storage ceiling, not wallet capacity.
var db: SQLite
var _transaction: EconomyCommandSqlite
var committed: bool:
	get: return _transaction.committed
var commit_usec: int:
	get: return _transaction.commit_usec
var rejected: MarketRejectedCommands:
	get: return _transaction.rejected
func _init(database: SQLite, rejected_commands: MarketRejectedCommands = null) -> void:
	db = database
	_transaction = EconomyCommandSqlite.new(db,rejected_commands)

static func ensure_schema(database: SQLite) -> bool:
	database.foreign_keys = true
	if not database.query("PRAGMA foreign_keys=ON;"): return false
	if not database.query("SELECT value FROM meta WHERE key='schema_version';"): return false
	var version := int(database.query_result[0].value)
	if version >= 19: return preload("res://source/server/world/database/item_state_revision_sqlite.gd").ensure_schema(database) and _ensure_offer_only_column(database) and _ensure_projection_indexes(database) and _ensure_revenue_schema(database)
	if version < 18 or not database.query("BEGIN IMMEDIATE;"): return false
	if not database.query("SELECT i.uid FROM item_instances i LEFT JOIN item_placements p ON p.item_uid=i.uid LEFT JOIN account_storage s ON s.item_uid=i.uid WHERE (p.item_uid IS NOT NULL)+(s.item_uid IS NOT NULL)<>1 LIMIT 1;") or not database.query_result.is_empty():
		database.query("ROLLBACK;")
		return false
	if not database.query("SELECT p.item_uid FROM item_placements p JOIN item_instances i ON i.uid=p.item_uid LEFT JOIN players a ON a.player_id=p.owner_character_id WHERE i.owner_character_id<>p.owner_character_id OR a.player_id IS NULL LIMIT 1;") or not database.query_result.is_empty():
		database.query("ROLLBACK;")
		return false
	var statements: Array[String] = [
		"ALTER TABLE item_instances RENAME TO item_instances_v18;",
		"DROP INDEX IF EXISTS item_owner;",
		"CREATE TABLE account_shops (shop_id INTEGER PRIMARY KEY AUTOINCREMENT,account_id INTEGER UNIQUE NOT NULL REFERENCES accounts(master_account_id),display_name TEXT NOT NULL DEFAULT 'My Shop' CHECK(length(display_name) BETWEEN 1 AND 40),status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','paused')),revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0));",
		"CREATE TABLE item_custody (uid TEXT PRIMARY KEY NOT NULL,location TEXT NOT NULL CHECK(location IN ('bag','equipment','account_storage','shop_escrow','account_claim')),owner_id INTEGER NOT NULL CHECK(owner_id>0),position INTEGER NOT NULL,equipment_slot TEXT NOT NULL DEFAULT '',container_id INTEGER NOT NULL DEFAULT 0,offer_id TEXT,FOREIGN KEY(uid) REFERENCES item_instances(uid) DEFERRABLE INITIALLY DEFERRED,FOREIGN KEY(offer_id) REFERENCES shop_offers(offer_id) DEFERRABLE INITIALLY DEFERRED,UNIQUE(uid,offer_id,container_id,owner_id,position),UNIQUE(uid,container_id),CHECK((location='bag' AND position BETWEEN 0 AND 179 AND equipment_slot='' AND container_id=0 AND offer_id IS NULL) OR (location='equipment' AND position=-1 AND equipment_slot<>'' AND container_id=0 AND offer_id IS NULL) OR (location='account_storage' AND position BETWEEN 0 AND 269 AND equipment_slot='' AND container_id=0 AND offer_id IS NULL) OR (location='shop_escrow' AND position BETWEEN 0 AND 39 AND equipment_slot='' AND container_id>0 AND offer_id IS NOT NULL) OR (location='account_claim' AND position=-1 AND equipment_slot='' AND container_id=0 AND offer_id IS NULL)));",
		"CREATE TABLE item_instances (uid TEXT PRIMARY KEY NOT NULL,owner_character_id INTEGER NOT NULL CHECK(owner_character_id>0),definition_id TEXT NOT NULL,amount INTEGER NOT NULL CHECK(amount>0),upgrade_level INTEGER NOT NULL DEFAULT 0 CHECK(upgrade_level BETWEEN 0 AND 9),affixes_json TEXT NOT NULL,sockets_json TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0),FOREIGN KEY(uid) REFERENCES item_custody(uid) DEFERRABLE INITIALLY DEFERRED);",
		"CREATE INDEX item_owner ON item_instances(owner_character_id);",
		"CREATE TABLE shop_offers (offer_id TEXT PRIMARY KEY NOT NULL,shop_id INTEGER NOT NULL REFERENCES account_shops(shop_id),account_id INTEGER NOT NULL REFERENCES accounts(master_account_id),item_uid TEXT UNIQUE NOT NULL,position INTEGER NOT NULL CHECK(position BETWEEN 0 AND 39),price_yang INTEGER NOT NULL CHECK(typeof(price_yang)='integer' AND price_yang>0 AND price_yang<=9000000000000000),revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0),FOREIGN KEY(item_uid,offer_id,shop_id,account_id,position) REFERENCES item_custody(uid,offer_id,container_id,owner_id,position) DEFERRABLE INITIALLY DEFERRED);",
		"CREATE TABLE shop_cells (shop_id INTEGER NOT NULL,position INTEGER NOT NULL CHECK(position BETWEEN 0 AND 39),item_uid TEXT NOT NULL,PRIMARY KEY(shop_id,position),FOREIGN KEY(item_uid,shop_id) REFERENCES item_custody(uid,container_id) DEFERRABLE INITIALLY DEFERRED);",
		"CREATE TABLE market_commands (account_id INTEGER NOT NULL REFERENCES accounts(master_account_id),command_id TEXT NOT NULL,kind TEXT NOT NULL,request_json TEXT NOT NULL,result_json TEXT NOT NULL,PRIMARY KEY(account_id,command_id));",
		"INSERT INTO item_instances SELECT * FROM item_instances_v18;",
		"INSERT INTO item_custody(uid,location,owner_id,position,equipment_slot) SELECT item_uid,location,owner_character_id,bag_position,equipment_slot FROM item_placements;",
		"INSERT INTO item_custody(uid,location,owner_id,position) SELECT s.item_uid,'account_storage',a.master_account_id,s.position FROM account_storage s JOIN accounts a ON a.account_name=s.account_name;",
		"DROP TABLE item_placements;",
		"DROP TABLE account_storage;",
		"DROP TABLE item_instances_v18;",
		"CREATE UNIQUE INDEX custody_bag_position ON item_custody(owner_id,position) WHERE location='bag';",
		"CREATE UNIQUE INDEX custody_equipment_slot ON item_custody(owner_id,equipment_slot) WHERE location='equipment';",
		"CREATE UNIQUE INDEX custody_storage_position ON item_custody(owner_id,position) WHERE location='account_storage';",
		"CREATE UNIQUE INDEX custody_shop_position ON item_custody(container_id,position) WHERE location='shop_escrow';",
		"CREATE UNIQUE INDEX custody_offer_identity ON item_custody(offer_id) WHERE offer_id IS NOT NULL;",
		"CREATE VIEW item_placements AS SELECT uid AS item_uid,owner_id AS owner_character_id,location,position AS bag_position,equipment_slot FROM item_custody WHERE location IN ('bag','equipment');",
		"CREATE VIEW account_storage AS SELECT c.uid AS item_uid,a.account_name,c.position FROM item_custody c JOIN accounts a ON a.master_account_id=c.owner_id WHERE c.location='account_storage';",
		"CREATE VIEW shop_escrow AS SELECT uid AS item_uid,owner_id AS account_id,container_id AS shop_id,position,offer_id FROM item_custody WHERE location='shop_escrow';",
		"CREATE VIEW account_claims AS SELECT uid AS item_uid,owner_id AS account_id FROM item_custody WHERE location='account_claim';",
		"CREATE TRIGGER placements_insert INSTEAD OF INSERT ON item_placements BEGIN INSERT INTO item_custody(uid,location,owner_id,position,equipment_slot) VALUES(NEW.item_uid,NEW.location,NEW.owner_character_id,NEW.bag_position,NEW.equipment_slot); END;",
		"CREATE TRIGGER placements_update INSTEAD OF UPDATE ON item_placements BEGIN UPDATE item_custody SET location=NEW.location,owner_id=NEW.owner_character_id,position=NEW.bag_position,equipment_slot=NEW.equipment_slot WHERE uid=OLD.item_uid; END;",
		"CREATE TRIGGER placements_delete INSTEAD OF DELETE ON item_placements BEGIN DELETE FROM item_custody WHERE uid=OLD.item_uid; END;",
		"CREATE TRIGGER storage_insert INSTEAD OF INSERT ON account_storage BEGIN INSERT INTO item_custody(uid,location,owner_id,position) VALUES(NEW.item_uid,'account_storage',(SELECT master_account_id FROM accounts WHERE account_name=NEW.account_name),NEW.position); END;",
		"CREATE TRIGGER storage_update INSTEAD OF UPDATE ON account_storage BEGIN UPDATE item_custody SET owner_id=(SELECT master_account_id FROM accounts WHERE account_name=NEW.account_name),position=NEW.position WHERE uid=OLD.item_uid; END;",
		"CREATE TRIGGER storage_delete INSTEAD OF DELETE ON account_storage BEGIN DELETE FROM item_custody WHERE uid=OLD.item_uid; END;",
		"CREATE TRIGGER custody_owner_insert BEFORE INSERT ON item_custody BEGIN SELECT CASE WHEN NEW.location IN ('bag','equipment') AND NOT EXISTS(SELECT 1 FROM item_instances i JOIN players p ON p.player_id=NEW.owner_id WHERE i.uid=NEW.uid AND i.owner_character_id=NEW.owner_id) THEN RAISE(ABORT,'custody character owner') WHEN NEW.location IN ('account_storage','shop_escrow','account_claim') AND NOT EXISTS(SELECT 1 FROM accounts WHERE master_account_id=NEW.owner_id) THEN RAISE(ABORT,'custody account owner') WHEN NEW.location='shop_escrow' AND NOT EXISTS(SELECT 1 FROM account_shops WHERE shop_id=NEW.container_id AND account_id=NEW.owner_id) THEN RAISE(ABORT,'custody shop owner') END; END;",
		"CREATE TRIGGER custody_owner_update BEFORE UPDATE ON item_custody BEGIN SELECT CASE WHEN NEW.location IN ('bag','equipment') AND NOT EXISTS(SELECT 1 FROM item_instances i JOIN players p ON p.player_id=NEW.owner_id WHERE i.uid=NEW.uid AND i.owner_character_id=NEW.owner_id) THEN RAISE(ABORT,'custody character owner') WHEN NEW.location IN ('account_storage','shop_escrow','account_claim') AND NOT EXISTS(SELECT 1 FROM accounts WHERE master_account_id=NEW.owner_id) THEN RAISE(ABORT,'custody account owner') WHEN NEW.location='shop_escrow' AND NOT EXISTS(SELECT 1 FROM account_shops WHERE shop_id=NEW.container_id AND account_id=NEW.owner_id) THEN RAISE(ABORT,'custody shop owner') END; END;",
		"CREATE TRIGGER item_owner_update BEFORE UPDATE OF owner_character_id ON item_instances WHEN EXISTS(SELECT 1 FROM item_custody WHERE uid=OLD.uid AND location IN ('bag','equipment') AND owner_id<>NEW.owner_character_id) BEGIN SELECT RAISE(ABORT,'placed item owner'); END;",
		"INSERT OR REPLACE INTO meta(key,value) VALUES('schema_version','19');", "COMMIT;"
	]
	for statement: String in statements:
		if not database.query(statement):
			database.query("ROLLBACK;")
			return false
	return preload("res://source/server/world/database/item_state_revision_sqlite.gd").ensure_schema(database) and _ensure_offer_only_column(database) and _ensure_projection_indexes(database) and _ensure_revenue_schema(database)

static func _ensure_revenue_schema(database: SQLite) -> bool:
	# Old sale receipts already credited wallets. Never reconstruct/backfill them.
	return database.query("CREATE TABLE IF NOT EXISTS account_shop_revenue(account_id INTEGER PRIMARY KEY REFERENCES accounts(master_account_id),yang INTEGER NOT NULL DEFAULT 0 CHECK(typeof(yang)='integer' AND yang>=0));")

func revenue(account_id: int) -> Dictionary:
	if not db.query_with_bindings("SELECT yang FROM account_shop_revenue WHERE account_id=?;",[account_id]): return {"ok":false,"error":"storage"}
	return {"ok":true,"amount":0 if db.query_result.is_empty() else int(db.query_result[0].yang)}

func _credit_revenue(account_id: int, amount: int) -> Dictionary:
	var current := revenue(account_id)
	if not current.ok: return current
	if amount<=0 or int(current.amount)>MAX_REVENUE-amount: return {"ok":false,"error":"revenue_capacity"}
	var total: int = int(current.amount)+amount
	if not db.query_with_bindings("INSERT INTO account_shop_revenue(account_id,yang) VALUES(?,?) ON CONFLICT(account_id) DO UPDATE SET yang=excluded.yang;",[account_id,total]): return {"ok":false,"error":"storage"}
	return {"ok":true,"amount":total}

func claim_revenue(character_id: int, command_id: String, pending_income: int) -> Dictionary:
	if not _transaction.begin(character_id,command_id,"claim_revenue",[character_id]): return _transaction.cached
	var available := revenue(_transaction.account_id)
	if not available.ok: return _transaction.rollback("storage")
	if int(available.amount)==0: return _transaction.commit({"ok":false,"error":"nothing_to_claim"})
	var wallets := WalletStoreSqlite.new(db)
	var wallet := wallets.load_wallet(_transaction.account_id)
	if not wallet.ok: return _transaction.rollback(str(wallet.error))
	if pending_income<0 or pending_income>WalletStoreSqlite.MAX_YANG-int(wallet.balance): return _transaction.rollback("storage")
	var amount := mini(int(available.amount),WalletStoreSqlite.MAX_YANG-int(wallet.balance)-pending_income)
	if amount<=0: return _transaction.commit({"ok":false,"error":"wallet_full"})
	var credited := wallets.credit_in_transaction(_transaction.account_id,pending_income,amount)
	if not credited.ok: return _transaction.rollback(str(credited.error))
	if not db.query_with_bindings("UPDATE account_shop_revenue SET yang=yang-? WHERE account_id=?;",[amount,_transaction.account_id]): return _transaction.rollback("storage")
	return _transaction.commit({"ok":true,"claimed":amount,"claimable_yang":str(int(available.amount)-amount),"wallet_states":[credited.wallet_state]})

## Local account projections must not scan the realm-wide catalogue. Additive,
## idempotent startup work; no custody/receipt/schema-version semantics change.
static func _ensure_projection_indexes(database: SQLite) -> bool:
	if not database.query("BEGIN IMMEDIATE;"): return false
	for statement: String in [
		"CREATE INDEX IF NOT EXISTS shop_offers_shop_position ON shop_offers(shop_id,position);",
		"CREATE INDEX IF NOT EXISTS custody_account_claim_owner ON item_custody(owner_id,uid) WHERE location='account_claim';",
		"COMMIT;"
	]:
		if not database.query(statement):
			database.query("ROLLBACK;")
			return false
	return true

## Explicit no-price mode without rebuilding the FK-linked shop_offers table.
static func _ensure_offer_only_column(database: SQLite) -> bool:
	if not database.query("PRAGMA table_info(shop_offers);"): return false
	for column: Dictionary in database.query_result:
		if column.name == "offer_only": return true
	if not database.query("BEGIN IMMEDIATE;"): return false
	if not database.query("ALTER TABLE shop_offers ADD COLUMN offer_only INTEGER NOT NULL DEFAULT 0 CHECK(offer_only IN (0,1));"):
		database.query("ROLLBACK;")
		return false
	if not database.query("COMMIT;"):
		database.query("ROLLBACK;")
		return false
	return true

static func ensure_offer_only_schema(database: SQLite) -> bool:
	if not database.query("SELECT value FROM meta WHERE key='schema_version';") or database.query_result.is_empty(): return false
	var version := int(database.query_result[0].value)
	if version >= 24: return _ensure_offer_only_column(database)
	if version != 23 or not _ensure_offer_only_column(database) or not database.query("BEGIN IMMEDIATE;"): return false
	for statement: String in ["INSERT OR REPLACE INTO meta(key,value) VALUES('schema_version','24');", "COMMIT;"]:
		if not database.query(statement):
			database.query("ROLLBACK;")
			return false
	return true

func _shop(account_id: int) -> int:
	if not db.query_with_bindings("INSERT OR IGNORE INTO account_shops(account_id) VALUES(?);",[account_id]): return 0
	if not db.query_with_bindings("SELECT shop_id FROM account_shops WHERE account_id=?;",[account_id]) or db.query_result.is_empty(): return 0
	return int(db.query_result[0].shop_id)

func _item_view(row: Dictionary) -> Dictionary:
	var item := ItemInstance.from_row(row)
	if item == null: return {}
	var definition := ItemDefinitions.get_definition(item.definition_id)
	if definition == null: return {}
	var view := item.to_snapshot()
	view.merge({"item_name":definition.item_name,"icon_id":str(definition.icon_id),"inventory_height":definition.inventory_height,"stats":item.effective_stats(definition)})
	return view

func mine(character_id: int) -> Dictionary:
	if not db.query("BEGIN IMMEDIATE;"): return {"ok":false,"error":"storage"}
	var account_id := WorldStoreSqlite.new(db).resolve_account_id(character_id)
	if account_id <= 0: return _transaction.rollback("owner")
	var shop_id := _shop(account_id)
	if shop_id <= 0: return _transaction.rollback("storage")
	if not db.query_with_bindings("SELECT shop_id,display_name AS name,status,revision FROM account_shops WHERE shop_id=?;",[shop_id]): return _transaction.rollback("storage")
	var result: Dictionary = db.query_result[0].duplicate(true)
	result.ok = true
	result.columns = COLUMNS
	result.rows = ROWS
	result.offers = []
	if not db.query_with_bindings("SELECT i.*,c.location,c.position AS bag_position,'' AS equipment_slot,o.offer_id,o.position,o.price_yang,o.offer_only,o.revision AS offer_revision FROM shop_offers o JOIN item_custody c ON c.uid=o.item_uid JOIN item_instances i ON i.uid=o.item_uid WHERE o.shop_id=? ORDER BY o.position;",[shop_id]): return _transaction.rollback("storage")
	for row: Dictionary in db.query_result.duplicate(true):
		var view := _item_view(row)
		if view.is_empty(): return _transaction.rollback("unknown_definition")
		result.offers.append({"offer_id":row.offer_id,"position":row.position,"price":null if int(row.offer_only)==1 else int(row.price_yang),"revision":row.offer_revision,"item":view})
	result.claims = []
	var earnings := revenue(account_id)
	if not earnings.ok: return _transaction.rollback("storage")
	result.claimable_yang = str(earnings.amount)
	if not db.query_with_bindings("SELECT i.*,c.location,-1 AS bag_position,'' AS equipment_slot FROM item_custody c JOIN item_instances i ON i.uid=c.uid WHERE c.location='account_claim' AND c.owner_id=? ORDER BY c.uid LIMIT 200;",[account_id]): return _transaction.rollback("storage")
	for row: Dictionary in db.query_result.duplicate(true):
		var view := _item_view(row)
		if view.is_empty(): return _transaction.rollback("unknown_definition")
		result.claims.append(view)
	if not db.query("COMMIT;"): return _transaction.rollback("storage")
	return result

func _cells(position: int, height: int) -> Array[int]:
	var cells: Array[int] = []
	if position<0 or height<1 or height>3 or position+COLUMNS*(height-1)>=CAPACITY: return cells
	for row: int in height: cells.append(position+COLUMNS*row)
	return cells

func list_item(character_id: int, command_id: String, uid: String, revision: int, position: int, price: int) -> Dictionary:
	if not _transaction.begin(character_id,command_id,"list",[uid,revision,position,price]): return _transaction.cached
	if not ItemInstance.valid_uid(uid) or revision<0 or price<0 or price>WalletStoreSqlite.MAX_YANG: return _transaction.commit({"ok":false,"error":"request"})
	if not db.query_with_bindings(ItemStoreSqlite.ITEM_SELECT+"WHERE i.uid=? AND i.owner_character_id=? AND p.owner_character_id=? AND p.location='bag';",[uid,character_id,character_id]): return _transaction.rollback("storage")
	if db.query_result.is_empty(): return _transaction.commit({"ok":false,"error":"owner"})
	var item := ItemInstance.from_row(db.query_result[0])
	if item == null: return _transaction.commit({"ok":false,"error":"invalid_item"})
	if item.revision!=revision: return _transaction.commit({"ok":false,"error":"stale"})
	var definition := ItemDefinitions.get_definition(item.definition_id)
	if definition == null or not definition.tradeable or item.amount>definition.stack_limit: return _transaction.commit({"ok":false,"error":"not_tradeable"})
	var cells := _cells(position,definition.inventory_height)
	if cells.is_empty(): return _transaction.commit({"ok":false,"error":"placement"})
	var shop_id := _shop(_transaction.account_id)
	if shop_id<=0: return _transaction.rollback("storage")
	for cell: int in cells:
		if not db.query_with_bindings("SELECT 1 FROM shop_cells WHERE shop_id=? AND position=?;",[shop_id,cell]): return _transaction.rollback("storage")
		if not db.query_result.is_empty(): return _transaction.commit({"ok":false,"error":"occupied"})
	var offer_id := Crypto.new().generate_random_bytes(16).hex_encode()
	if not db.query_with_bindings("UPDATE item_custody SET location='shop_escrow',owner_id=?,position=?,container_id=?,offer_id=? WHERE uid=?;",[_transaction.account_id,position,shop_id,offer_id,uid]): return _transaction.rollback("storage")
	if not db.query_with_bindings("INSERT INTO shop_offers(offer_id,shop_id,account_id,item_uid,position,price_yang,offer_only) VALUES(?,?,?,?,?,?,?);",[offer_id,shop_id,_transaction.account_id,uid,position,max(price,1),1 if price==0 else 0]): return _transaction.rollback("storage")
	for cell: int in cells:
		if not db.query_with_bindings("INSERT INTO shop_cells(shop_id,position,item_uid) VALUES(?,?,?);",[shop_id,cell,uid]): return _transaction.rollback("storage")
	if not db.query_with_bindings("UPDATE item_instances SET revision=revision+1 WHERE uid=?;",[uid]): return _transaction.rollback("storage")
	return _transaction.commit({"ok":true,"offer_id":offer_id,"uid":uid,"revision":0,"shop_id":shop_id})

func cancel_offer(character_id: int, command_id: String, offer_id: String, revision: int) -> Dictionary:
	# Keep the existing account-scoped receipt fingerprint for old successful retries.
	if not _transaction.begin(character_id,command_id,"cancel",[offer_id,revision]): return _transaction.cached
	if not db.query_with_bindings("SELECT o.*,i.definition_id FROM shop_offers o JOIN item_instances i ON i.uid=o.item_uid WHERE o.offer_id=? AND o.account_id=?;",[offer_id,_transaction.account_id]): return _transaction.rollback("storage")
	if db.query_result.is_empty(): return _transaction.commit({"ok":false,"error":"unavailable"})
	var offer: Dictionary = db.query_result[0].duplicate(true)
	if int(offer.revision)!=revision: return _transaction.commit({"ok":false,"error":"stale"})
	var definition := ItemDefinitions.get_definition(StringName(offer.definition_id))
	if definition == null: return _transaction.commit({"ok":false,"error":"unknown_definition"})
	# A shop withdrawal is not a second claim vault. Resolve the receiving
	# character's footprint before changing custody or deleting the offer.
	var receiving := ItemStoreSqlite.new(db).resolve_inventory_position(character_id,definition.inventory_height,-1)
	if not receiving.ok: return _transaction.commit({"ok":false,"error":receiving.error})
	if not db.query_with_bindings("DELETE FROM shop_cells WHERE item_uid=?;",[offer.item_uid]): return _transaction.rollback("storage")
	# Move the item owner before switching to bag custody: the custody trigger
	# requires the owning character to match the item instance.
	if not db.query_with_bindings("UPDATE item_instances SET owner_character_id=?,revision=revision+1 WHERE uid=?;",[character_id,offer.item_uid]): return _transaction.rollback("storage")
	if not db.query_with_bindings("UPDATE item_custody SET location='bag',owner_id=?,position=?,container_id=0,offer_id=NULL WHERE uid=?;",[character_id,receiving.position,offer.item_uid]): return _transaction.rollback("storage")
	if not db.query_with_bindings("DELETE FROM shop_offers WHERE offer_id=?;",[offer_id]): return _transaction.rollback("storage")
	return _transaction.commit({"ok":true,"uid":offer.item_uid,"position":int(receiving.position)})

func claim_item(character_id: int, command_id: String, uid: String, revision: int, requested_position: int = -1) -> Dictionary:
	if not _transaction.begin(character_id,command_id,"claim",[character_id,uid,revision,requested_position]): return _transaction.cached
	if not db.query_with_bindings("SELECT i.*,c.location,-1 AS bag_position,'' AS equipment_slot FROM item_instances i JOIN item_custody c ON c.uid=i.uid WHERE i.uid=? AND c.location='account_claim' AND c.owner_id=?;",[uid,_transaction.account_id]): return _transaction.rollback("storage")
	if db.query_result.is_empty(): return _transaction.commit({"ok":false,"error":"owner"})
	var item := ItemInstance.from_row(db.query_result[0])
	if item==null or item.revision!=revision: return _transaction.commit({"ok":false,"error":"stale"})
	var definition := ItemDefinitions.get_definition(item.definition_id)
	if definition == null: return _transaction.commit({"ok":false,"error":"unknown_definition"})
	var receiving := ItemStoreSqlite.new(db).resolve_inventory_position(character_id,definition.inventory_height,requested_position)
	if not receiving.ok: return _transaction.commit({"ok":false,"error":receiving.error})
	if not db.query_with_bindings("UPDATE item_instances SET owner_character_id=?,revision=revision+1 WHERE uid=?;",[character_id,uid]): return _transaction.rollback("storage")
	if not db.query_with_bindings("UPDATE item_custody SET location='bag',owner_id=?,position=?,container_id=0,offer_id=NULL WHERE uid=?;",[character_id,receiving.position,uid]): return _transaction.rollback("storage")
	return _transaction.commit({"ok":true,"uid":uid,"position":int(receiving.position)})

func receipt(character_id: int, command_id: String) -> Dictionary:
	return _transaction.receipt(character_id,command_id)

func configure(character_id: int, command_id: String, revision: int, name: String, status: String) -> Dictionary:
	if not _transaction.begin(character_id,command_id,"configure",[revision,name,status]): return _transaction.cached
	if name.strip_edges().is_empty() or name.length()>40 or status not in ["active","paused"]: return _transaction.commit({"ok":false,"error":"request"})
	for character: String in name:
		if character.unicode_at(0)<32: return _transaction.commit({"ok":false,"error":"request"})
	var shop_id := _shop(_transaction.account_id)
	if shop_id<=0 or not db.query_with_bindings("SELECT revision FROM account_shops WHERE shop_id=?;",[shop_id]): return _transaction.rollback("storage")
	if int(db.query_result[0].revision)!=revision: return _transaction.commit({"ok":false,"error":"stale"})
	if not db.query_with_bindings("UPDATE account_shops SET display_name=?,status=?,revision=revision+1 WHERE shop_id=?;",[name.strip_edges(),status,shop_id]): return _transaction.rollback("storage")
	return _transaction.commit({"ok":true,"revision":revision+1})

func edit_offer(character_id: int, command_id: String, offer_id: String, revision: int, position: int, price: int) -> Dictionary:
	if not _transaction.begin(character_id,command_id,"edit",[offer_id,revision,position,price]): return _transaction.cached
	if price<0 or price>WalletStoreSqlite.MAX_YANG: return _transaction.commit({"ok":false,"error":"request"})
	if not db.query_with_bindings("SELECT o.*,i.definition_id FROM shop_offers o JOIN item_instances i ON i.uid=o.item_uid WHERE o.offer_id=? AND o.account_id=?;",[offer_id,_transaction.account_id]): return _transaction.rollback("storage")
	if db.query_result.is_empty(): return _transaction.commit({"ok":false,"error":"unavailable"})
	var offer: Dictionary = db.query_result[0].duplicate(true)
	if int(offer.revision)!=revision: return _transaction.commit({"ok":false,"error":"stale"})
	var definition := ItemDefinitions.get_definition(StringName(offer.definition_id))
	if definition == null: return _transaction.commit({"ok":false,"error":"unknown_definition"})
	var cells := _cells(position,definition.inventory_height)
	if cells.is_empty(): return _transaction.commit({"ok":false,"error":"placement"})
	for cell: int in cells:
		if not db.query_with_bindings("SELECT 1 FROM shop_cells WHERE shop_id=? AND position=? AND item_uid<>?;",[offer.shop_id,cell,offer.item_uid]): return _transaction.rollback("storage")
		if not db.query_result.is_empty(): return _transaction.commit({"ok":false,"error":"occupied"})
	if not db.query_with_bindings("DELETE FROM shop_cells WHERE item_uid=?;",[offer.item_uid]): return _transaction.rollback("storage")
	if not db.query_with_bindings("UPDATE item_custody SET position=? WHERE uid=?;",[position,offer.item_uid]): return _transaction.rollback("storage")
	if not db.query_with_bindings("UPDATE shop_offers SET position=?,price_yang=?,offer_only=?,revision=revision+1 WHERE offer_id=?;",[position,max(price,1),1 if price==0 else 0,offer_id]): return _transaction.rollback("storage")
	for cell: int in cells:
		if not db.query_with_bindings("INSERT INTO shop_cells(shop_id,position,item_uid) VALUES(?,?,?);",[offer.shop_id,cell,offer.item_uid]): return _transaction.rollback("storage")
	if position!=int(offer.position) and not db.query_with_bindings("UPDATE item_instances SET revision=revision+1 WHERE uid=?;",[offer.item_uid]): return _transaction.rollback("storage")
	return _transaction.commit({"ok":true,"revision":revision+1})


## One transaction owns buyer wallet, seller revenue, live offer removal and UID transfer.
func purchase(character_id: int, command_id: String, shop_id: int, offer_id: String, revision: int, price: int, pending: Dictionary) -> Dictionary:
	if not _transaction.begin(character_id,command_id,"buy",[character_id,shop_id,offer_id,revision,price]): return _transaction.cached
	if not db.query_with_bindings("SELECT o.*,s.status,i.definition_id FROM shop_offers o JOIN account_shops s ON s.shop_id=o.shop_id JOIN item_instances i ON i.uid=o.item_uid WHERE o.offer_id=? AND o.shop_id=?;",[offer_id,shop_id]): return _transaction.rollback("storage")
	if db.query_result.is_empty(): return _transaction.commit({"ok":false,"error":"unavailable"})
	var offer: Dictionary = db.query_result[0].duplicate(true)
	var seller := int(offer.account_id)
	if seller==_transaction.account_id: return _transaction.commit({"ok":false,"error":"self_trade"})
	if offer.status!="active": return _transaction.commit({"ok":false,"error":"paused"})
	if int(offer.offer_only)==1: return _transaction.commit({"ok":false,"error":"offer_only"})
	if int(offer.revision)!=revision or int(offer.price_yang)!=price: return _transaction.commit({"ok":false,"error":"stale"})
	var definition := ItemDefinitions.get_definition(StringName(offer.definition_id))
	if definition==null: return _transaction.commit({"ok":false,"error":"unknown_definition"})
	var receiving := ItemStoreSqlite.new(db).resolve_inventory_position(character_id,definition.inventory_height,-1)
	if not receiving.ok: return _transaction.commit({"ok":false,"error":receiving.error})
	var wallets := WalletStoreSqlite.new(db)
	var spent := wallets.spend_in_transaction(_transaction.account_id,int(pending.get(_transaction.account_id,0)),price)
	if not spent.ok: return _transaction.rollback(str(spent.error))
	var credited := _credit_revenue(seller,price)
	if not credited.ok: return _transaction.rollback(str(credited.error))
	if not db.query_with_bindings("DELETE FROM shop_cells WHERE item_uid=?;",[offer.item_uid]): return _transaction.rollback("storage")
	if not db.query_with_bindings("UPDATE item_instances SET owner_character_id=?,revision=revision+1 WHERE uid=?;",[character_id,offer.item_uid]): return _transaction.rollback("storage")
	if not db.query_with_bindings("UPDATE item_custody SET location='bag',owner_id=?,position=?,container_id=0,offer_id=NULL WHERE uid=?;",[character_id,receiving.position,offer.item_uid]): return _transaction.rollback("storage")
	if not db.query_with_bindings("DELETE FROM shop_offers WHERE offer_id=?;",[offer_id]): return _transaction.rollback("storage")
	return _transaction.commit({"ok":true,"uid":offer.item_uid,"buyer_account":_transaction.account_id,"seller_account":seller,"buyer_balance":int(spent.balance),"seller_claimable_yang":str(credited.amount),"wallet_states":[spent.wallet_state],"shop_id":int(offer.shop_id)})

## Public read has no claims, credentials or offline player/session dependency.
func visit(shop_id: int) -> Dictionary:
	if not db.query_with_bindings("SELECT shop_id,display_name AS name,status,revision FROM account_shops WHERE shop_id=?;",[shop_id]): return {"ok":false,"error":"storage"}
	if db.query_result.is_empty(): return {"ok":false,"error":"unavailable"}
	var result: Dictionary = db.query_result[0].duplicate(true)
	result.merge({"ok":true,"columns":COLUMNS,"rows":ROWS,"offers":[],"claims":[]})
	if not db.query_with_bindings("SELECT i.*,c.location,c.position AS bag_position,'' AS equipment_slot,o.offer_id,o.position,o.price_yang,o.offer_only,o.revision AS offer_revision FROM shop_offers o JOIN item_custody c ON c.uid=o.item_uid JOIN item_instances i ON i.uid=o.item_uid WHERE o.shop_id=? ORDER BY o.position;",[shop_id]): return {"ok":false,"error":"storage"}
	for row: Dictionary in db.query_result.duplicate(true):
		var view := _item_view(row)
		if view.is_empty(): return {"ok":false,"error":"unknown_definition"}
		result.offers.append({"offer_id":row.offer_id,"position":row.position,"price":null if int(row.offer_only)==1 else int(row.price_yang),"revision":row.offer_revision,"item":view})
	return result
