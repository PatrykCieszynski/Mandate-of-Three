extends RefCounted
## Opt-in existing Upgrade use case. Caller authorizes current NPC/service/range;
## recipe and pending income come from server state, never client economics.
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
var db: Object
var _transaction: RefCounted
var committed: bool:
	get: return _transaction.committed

func _init(database: Object) -> void:
	db=database
	_transaction=Commands.new(db)

func candidate(owner: int, uid: String, revision: int, recipe: UpgradeDefinition) -> Dictionary:
	if not ItemInstance.valid_uid(uid) or revision < -1 or recipe==null: return _error("request")
	var result: Dictionary=db.query(Items.ITEM_SELECT+"WHERE i.uid=:uid AND i.owner_character_id=:owner AND c.owner_id=:owner AND c.location IN ('bag','equipment');",{"uid":uid,"owner":owner})
	if not result.ok: return _error("storage")
	if result.rows.is_empty(): return _error("owner")
	var item:=ItemInstance.from_row(result.rows[0])
	if item==null: return _error("invalid_item")
	if revision>=0 and item.revision!=revision: return _error("stale")
	if item.location!="bag": return _error("placement")
	if item.definition_id!=recipe.item_definition_id or item.amount!=1: return _error("unsupported_item")
	return {"ok":true,"item":item}

func upgrade(owner: int, pending_yang: int, recipe: UpgradeDefinition, uid: String, revision: int, operation_id: String = "") -> Dictionary:
	_transaction.committed=false
	if revision<0 or recipe==null or not recipe.validation_errors().is_empty(): return _error("request")
	if not _transaction.begin(owner,operation_id,"upgrade",[owner,str(recipe.upgrade_id),uid,revision]): return _transaction.cached
	var selected:=candidate(owner,uid,revision,recipe)
	if not selected.ok: return _transaction.rollback(str(selected.error))
	var item: ItemInstance=selected.item
	if item.upgrade_level!=recipe.from_level: return _transaction.rollback("upgrade_level")
	var definition:=ItemDefinitions.get_definition(item.definition_id)
	var receiving:=Items.new(db).resolve_inventory_position(owner,definition.inventory_height,item.bag_position,[uid])
	if not receiving.ok: return _transaction.rollback(str(receiving.error))
	var result: Dictionary=db.query(Items.ITEM_SELECT+"WHERE i.owner_character_id=:owner AND c.owner_id=:owner AND c.location='bag' AND i.definition_id=:definition AND i.upgrade_level=0 ORDER BY i.uid;",{"owner":owner,"definition":str(recipe.material_definition_id)})
	if not result.ok or result.truncated: return _transaction.rollback("storage")
	var materials: Array=result.rows
	var total: int=0
	for row: Dictionary in materials: total+=int(row.amount)
	if total<recipe.material_amount: return _transaction.rollback("material")
	var remaining: int=recipe.material_amount
	for row: Dictionary in materials:
		if remaining==0: break
		var used: int=mini(remaining,int(row.amount))
		if used==int(row.amount):
			result=db.execute("DELETE FROM economy.item_custody WHERE uid=:uid AND owner_id=:owner AND location='bag';",{"uid":row.uid,"owner":owner})
			if not result.ok or int(result.affected_rows)!=1: return _transaction.rollback("storage")
			result=db.execute("DELETE FROM economy.item_instances WHERE uid=:uid AND owner_character_id=:owner AND revision=:revision;",{"uid":row.uid,"owner":owner,"revision":row.revision})
		else:
			result=db.execute("UPDATE economy.item_instances SET amount=amount-:used,revision=revision+1 WHERE uid=:uid AND owner_character_id=:owner AND revision=:revision;",{"used":used,"uid":row.uid,"owner":owner,"revision":row.revision})
		if not result.ok or int(result.affected_rows)!=1: return _transaction.rollback("storage")
		remaining-=used
	var spent:=Wallet.new(db).spend_in_transaction(_transaction.account_id,pending_yang,recipe.yang_cost)
	if not spent.ok: return _transaction.rollback(str(spent.error))
	result=db.execute("UPDATE economy.item_instances SET upgrade_level=:level,revision=revision+1 WHERE uid=:uid AND owner_character_id=:owner AND revision=:revision AND upgrade_level=:previous;",{"level":recipe.to_level,"uid":uid,"owner":owner,"revision":revision,"previous":recipe.from_level})
	if not result.ok: return _transaction.rollback("storage")
	if int(result.affected_rows)!=1: return _transaction.rollback("stale")
	return _transaction.commit({"ok":true,"balance":spent.balance,"wallet_states":[spent.wallet_state]})

func upgrade_receipt(owner: int, operation_id: String) -> Dictionary:
	if not Commands.valid_id(operation_id): return _error("request")
	var result: Dictionary=db.query("SELECT account_id FROM economy.characters WHERE character_id=:owner;",{"owner":owner})
	if not result.ok: return _error("storage")
	if result.rows.is_empty(): return _error("owner")
	result=db.query("SELECT result_json FROM economy.market_commands WHERE account_id=:account AND character_id=:owner AND command_id=:command AND kind='upgrade';",{"account":result.rows[0].account_id,"owner":owner,"command":operation_id})
	if not result.ok: return _error("storage")
	if result.rows.is_empty(): return _error("unknown_command")
	var decoded:=Commands.decode(str(result.rows[0].result_json))
	return decoded if decoded.get("ok",false) else _error("storage")

func _error(reason: String) -> Dictionary:
	return {"ok":false,"error":reason}
