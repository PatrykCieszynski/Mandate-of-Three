extends RefCounted
## Opt-in fungible ledger boundary. No order/reservation/matching implementation.
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Storage = preload("res://source/server/world/database/postgres/account_storage_postgres.gd")
const Claims = preload("res://source/server/world/database/postgres/account_claim_postgres.gd")
const Seller = preload("res://source/server/world/database/postgres/shop_seller_postgres.gd")
const MAX_BALANCE: int=9000000000000000
var db: Object
var rejected: MarketRejectedCommands
var _transaction: RefCounted
var committed: bool:
	get: return _transaction.committed

func _init(database: Object, rejected_commands: MarketRejectedCommands = null) -> void:
	db=database
	rejected=rejected_commands if rejected_commands!=null else MarketRejectedCommands.new()
	_transaction=Commands.new(db,rejected)

static func asset_definition(asset: String) -> ItemDefinition:
	return MarketRequestRules.asset_definition(asset)

func receipt(character: int, command: String) -> Dictionary:
	return Seller.new(db,rejected).receipt(character,command)

func ledger(character: int) -> Dictionary:
	if db.in_transaction() or not db.begin(): return _error("storage")
	if not db.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;").ok: return _transaction.rollback("storage")
	var result:=read_in_transaction(character)
	if not result.ok: return _transaction.rollback(str(result.error))
	if db.commit(): return result
	db.close()
	return _error("storage")

## Existing read model within a caller-owned repeatable-read snapshot.
func read_in_transaction(character: int) -> Dictionary:
	if not db.in_transaction(): return _error("transaction")
	var identity: Dictionary=db.query("SELECT account_id FROM economy.characters WHERE character_id=:id;",{"id":character})
	if not identity.ok or identity.rows.is_empty(): return _error("storage" if not identity.ok else "owner")
	var account: int=int(identity.rows[0].account_id)
	var rows: Dictionary=db.query("SELECT asset_id,free,reserved FROM economy.exchange_assets WHERE account_id=:account ORDER BY asset_id;",{"account":account})
	if not rows.ok or rows.truncated: return _error("storage")
	var balances: Dictionary={}
	for row: Dictionary in rows.rows: balances[str(row.asset_id)]=row
	var assets: Array=[]
	for definition: ItemDefinition in ItemDefinitions.all_definitions():
		var asset: String=str(definition.definition_id)
		if asset_definition(asset)!=definition: continue
		var balance: Dictionary=balances.get(asset,{})
		assets.append({"asset_id":asset,"name":definition.item_name,"stack_limit":definition.stack_limit,"free":int(balance.get("free",0)),"reserved":int(balance.get("reserved",0))})
	var wallet: Dictionary=db.query("SELECT yang,reserved_yang FROM economy.account_wallets WHERE account_id=:account;",{"account":account})
	if not wallet.ok or wallet.rows.is_empty(): return _error("storage")
	var result: Dictionary={"ok":true,"assets":assets,"yang":int(wallet.rows[0].yang),"reserved_yang":int(wallet.rows[0].reserved_yang)}
	return result

func deposit(character: int, command: String, uid: String, revision: int, amount: int, source: String) -> Dictionary:
	return _transaction.run_with_retry(_deposit_once.bind(character,command,uid,revision,amount,source))

func _deposit_once(character: int, command: String, uid: String, revision: int, amount: int, source: String) -> Dictionary:
	if not _transaction.begin(character,command,"exchange.deposit",[character,uid,revision,amount,source],true): return _transaction.cached
	if source not in ["bag","account_storage"] or amount<=0: return _reject("request")
	var item: ItemInstance
	if source=="account_storage":
		# Both read authorization and mutation stay inside the Storage boundary.
		var owned:=Storage.new(db).item_in_transaction(character,uid)
		if not owned.ok: return _transaction.rollback("storage") if owned.error=="storage" else _reject(str(owned.error))
		item=owned.item
	else:
		var found: Dictionary=db.query(Items.ITEM_SELECT+"WHERE i.uid=:uid AND c.location='bag' AND c.owner_id=:owner;",{"uid":uid,"owner":character})
		if not found.ok: return _transaction.rollback("storage")
		if found.rows.is_empty(): return _reject("owner")
		item=ItemInstance.from_row(found.rows[0])
	if item==null or item.revision!=revision: return _reject("stale")
	var definition:=asset_definition(str(item.definition_id))
	if definition==null or item.upgrade_level!=0 or not item.affixes.is_empty() or not item.sockets.is_empty() or amount>item.amount or item.amount>definition.stack_limit: return _reject("not_fungible")
	var credited: Dictionary=db.execute("INSERT INTO economy.exchange_assets(account_id,asset_id,free) VALUES(:account,:asset,:amount) ON CONFLICT(account_id,asset_id) DO UPDATE SET free=economy.exchange_assets.free+EXCLUDED.free WHERE economy.exchange_assets.free<=:maximum-economy.exchange_assets.reserved-EXCLUDED.free;",{"account":_transaction.account_id,"asset":str(item.definition_id),"amount":amount,"maximum":MAX_BALANCE})
	if not credited.ok or int(credited.affected_rows)!=1: return _transaction.rollback("storage")
	if source=="account_storage":
		var consumed:=Storage.new(db).consume_in_transaction(character,uid,revision,amount)
		if not consumed.ok: return _transaction.rollback(str(consumed.error))
	elif amount==item.amount:
		if not db.execute("DELETE FROM economy.item_custody WHERE uid=:uid;",{"uid":uid}).ok: return _transaction.rollback("storage")
		if not db.execute("DELETE FROM economy.item_instances WHERE uid=:uid;",{"uid":uid}).ok: return _transaction.rollback("storage")
	elif not db.execute("UPDATE economy.item_instances SET amount=amount-:amount,revision=revision+1 WHERE uid=:uid;",{"amount":amount,"uid":uid}).ok: return _transaction.rollback("storage")
	return _transaction.commit({"ok":true,"asset_id":str(item.definition_id),"amount":amount})

func withdraw(character: int, command: String, asset: String, amount: int, destination: String) -> Dictionary:
	return _transaction.run_with_retry(_withdraw_once.bind(character,command,asset,amount,destination))

func _withdraw_once(character: int, command: String, asset: String, amount: int, destination: String) -> Dictionary:
	if not _transaction.begin(character,command,"exchange.withdraw",[character,asset,amount,destination],true): return _transaction.cached
	var definition:=asset_definition(asset)
	if definition==null or amount<=0 or amount>definition.stack_limit or destination not in ["bag","claim"]: return _reject("request")
	var spent: Dictionary=db.execute("UPDATE economy.exchange_assets SET free=free-:amount WHERE account_id=:account AND asset_id=:asset AND free>=:required;",{"amount":amount,"account":_transaction.account_id,"asset":asset,"required":amount})
	if not spent.ok: return _transaction.rollback("storage")
	if int(spent.affected_rows)!=1: return _reject("funds")
	var item:=ItemInstance.create(definition,character,[])
	item.amount=amount
	var received: Dictionary=Items.new(db).receive_item_in_transaction(item) if destination=="bag" else Claims.new(db).receive_in_transaction(item)
	if not received.ok: return _transaction.rollback(str(received.error))
	return _transaction.commit({"ok":true,"uid":item.uid,"amount":amount})

func _reject(reason: String) -> Dictionary:
	return _transaction.commit(_error(reason))

func _error(reason: String) -> Dictionary:
	return {"ok":false,"error":reason}
