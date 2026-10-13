class_name ExchangeStoreSqlite
extends MarketStoreSqlite
## Same account-scoped receipt/transaction boundary; only whitelisted plain stacks.
static func ensure_ledger_schema(database: SQLite) -> bool:
	if not database.query("SELECT value FROM meta WHERE key='schema_version';"): return false
	if int(database.query_result[0].value)>=21: return true
	if int(database.query_result[0].value)!=20 or not database.query("BEGIN IMMEDIATE;"): return false
	for sql: String in [
		"ALTER TABLE account_wallets ADD COLUMN reserved_yang INTEGER NOT NULL DEFAULT 0 CHECK(typeof(reserved_yang)='integer' AND reserved_yang>=0 AND reserved_yang<=yang);",
		"CREATE TABLE exchange_assets(account_id INTEGER NOT NULL REFERENCES accounts(master_account_id),asset_id TEXT NOT NULL,free INTEGER NOT NULL DEFAULT 0 CHECK(typeof(free)='integer' AND free>=0),reserved INTEGER NOT NULL DEFAULT 0 CHECK(typeof(reserved)='integer' AND reserved>=0),PRIMARY KEY(account_id,asset_id),CHECK(free+reserved<=9000000000000000));",
		"INSERT OR REPLACE INTO meta(key,value) VALUES('schema_version','21');","COMMIT;"
	]:
		if not database.query(sql): database.query("ROLLBACK;");return false
	return true
static func asset_definition(asset: String) -> ItemDefinition:
	var definition:=ItemDefinitions.get_definition(StringName(asset))
	return definition if definition!=null and definition.tradeable and definition.market_fungible and definition.stack_limit>1 else null
func ledger(character_id: int) -> Dictionary:
	var account:=WorldStoreSqlite.new(db).resolve_account_id(character_id)
	if account<=0: return {"ok":false,"error":"owner"}
	if not db.query_with_bindings("SELECT asset_id,free,reserved FROM exchange_assets WHERE account_id=? ORDER BY asset_id;",[account]): return {"ok":false,"error":"storage"}
	var assets: Array=[]
	for definition: ItemDefinition in [ItemDefinitions.UPGRADE_ORE]:
		var quantity: Dictionary={"asset_id":str(definition.definition_id),"name":definition.item_name,"stack_limit":definition.stack_limit,"free":0,"reserved":0}
		for row: Dictionary in db.query_result:
			if row.asset_id==str(definition.definition_id): quantity.free=int(row.free);quantity.reserved=int(row.reserved)
		assets.append(quantity)
	if not db.query_with_bindings("SELECT yang,reserved_yang FROM account_wallets WHERE account_id=?;",[account]) or db.query_result.is_empty(): return {"ok":false,"error":"storage"}
	return {"ok":true,"assets":assets,"yang":int(db.query_result[0].yang),"reserved_yang":int(db.query_result[0].reserved_yang)}
func deposit(character_id: int,command_id: String,uid: String,revision: int,amount: int,source: String) -> Dictionary:
	if not _open_command(character_id,command_id,"exchange.deposit",[character_id,uid,revision,amount,source]): return _cached
	if source not in ["bag","account_storage"] or amount<=0: return _finish({"ok":false,"error":"request"})
	if not db.query_with_bindings("SELECT i.*,c.location,c.position AS bag_position,c.equipment_slot,c.owner_id FROM item_instances i JOIN item_custody c ON c.uid=i.uid WHERE i.uid=?;",[uid]): return _abort("storage")
	if db.query_result.is_empty(): return _finish({"ok":false,"error":"owner"})
	var row: Dictionary=db.query_result[0].duplicate(true)
	if row.location!=source or int(row.owner_id)!=(character_id if source=="bag" else _account): return _finish({"ok":false,"error":"owner"})
	var item:=ItemInstance.from_row(row)
	if item==null or item.revision!=revision: return _finish({"ok":false,"error":"stale"})
	var definition:=asset_definition(str(item.definition_id))
	if definition==null or item.upgrade_level!=0 or not item.affixes.is_empty() or not item.sockets.is_empty() or amount>item.amount or item.amount>definition.stack_limit: return _finish({"ok":false,"error":"not_fungible"})
	if not db.query_with_bindings("INSERT INTO exchange_assets(account_id,asset_id,free) VALUES(?,?,?) ON CONFLICT(account_id,asset_id) DO UPDATE SET free=free+excluded.free;",[_account,str(item.definition_id),amount]): return _abort("storage")
	if amount==item.amount:
		if not db.query_with_bindings("DELETE FROM item_custody WHERE uid=?;",[uid]) or not db.query_with_bindings("DELETE FROM item_instances WHERE uid=?;",[uid]): return _abort("storage")
	elif not db.query_with_bindings("UPDATE item_instances SET amount=amount-?,revision=revision+1 WHERE uid=?;",[amount,uid]): return _abort("storage")
	return _finish({"ok":true,"asset_id":str(item.definition_id),"amount":amount})
func withdraw(character_id: int,command_id: String,asset: String,amount: int,destination: String) -> Dictionary:
	if not _open_command(character_id,command_id,"exchange.withdraw",[character_id,asset,amount,destination]): return _cached
	var definition:=asset_definition(asset)
	if definition==null or amount<=0 or amount>definition.stack_limit or destination not in ["bag","claim"]: return _finish({"ok":false,"error":"request"})
	if not db.query_with_bindings("UPDATE exchange_assets SET free=free-? WHERE account_id=? AND asset_id=? AND free>=?;",[amount,_account,asset,amount]): return _abort("storage")
	if not db.query("SELECT changes() AS n;"): return _abort("storage")
	if int(db.query_result[0].n)!=1: return _finish({"ok":false,"error":"funds"})
	var item:=ItemInstance.create(definition,character_id,[]);item.amount=amount
	if destination=="bag":
		var inserted:=ItemStoreSqlite.new(db).receive_item_in_transaction(item)
		if not inserted.ok: return _abort(str(inserted.error))
	else:
		if not db.query_with_bindings("INSERT INTO item_instances VALUES(?,?,?,?,?,?,?,?);",[item.uid,character_id,asset,amount,0,"[]","[]",0]): return _abort("storage")
		if not db.query_with_bindings("INSERT INTO item_custody(uid,location,owner_id,position) VALUES(?,'account_claim',?,-1);",[item.uid,_account]): return _abort("storage")
	return _finish({"ok":true,"uid":item.uid,"amount":amount})
## Only order transactions may reserve/release. These are not exposed UI commands.
func reserve_in_transaction(account: int,asset: String,amount: int,pending: int=0) -> Dictionary:
	if amount<=0 or amount>WalletStoreSqlite.MAX_YANG: return {"ok":false,"error":"request"}
	if asset=="yang":
		var income:=WalletStoreSqlite.new(db)._apply_income(account,pending)
		if not income.ok: return income
		if not db.query_with_bindings("UPDATE account_wallets SET reserved_yang=reserved_yang+? WHERE account_id=? AND yang-reserved_yang>=?;",[amount,account,amount]): return {"ok":false,"error":"storage"}
	else:
		if asset_definition(asset)==null: return {"ok":false,"error":"asset"}
		if not db.query_with_bindings("UPDATE exchange_assets SET free=free-?,reserved=reserved+? WHERE account_id=? AND asset_id=? AND free>=?;",[amount,amount,account,asset,amount]): return {"ok":false,"error":"storage"}
	if not db.query("SELECT changes() AS n;"): return {"ok":false,"error":"storage"}
	return {"ok":true} if int(db.query_result[0].n)==1 else {"ok":false,"error":"funds"}
func release_in_transaction(account: int,asset: String,amount: int) -> bool:
	if amount<=0: return false
	var ok:=db.query_with_bindings("UPDATE account_wallets SET reserved_yang=reserved_yang-? WHERE account_id=? AND reserved_yang>=?;",[amount,account,amount]) if asset=="yang" else db.query_with_bindings("UPDATE exchange_assets SET free=free+?,reserved=reserved-? WHERE account_id=? AND asset_id=? AND reserved>=?;",[amount,amount,account,asset,amount])
	return ok and db.query("SELECT changes() AS n;") and int(db.query_result[0].n)==1
