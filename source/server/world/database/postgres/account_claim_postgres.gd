extends RefCounted
## Claim -> issuing character Inventory. No claim producer or Storage fallback.
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Seller = preload("res://source/server/world/database/postgres/shop_seller_postgres.gd")
var db: Object
var rejected: MarketRejectedCommands
var _transaction: RefCounted
var committed: bool:
	get: return _transaction.committed

func _init(database: Object, rejected_commands: MarketRejectedCommands = null) -> void:
	db=database
	rejected=rejected_commands if rejected_commands!=null else MarketRejectedCommands.new()
	_transaction=Commands.new(db,rejected)

func claim_item(character: int, command: String, uid: String, revision: int, requested_position: int = -1) -> Dictionary:
	if not _transaction.begin(character,command,"claim",[character,uid,revision,requested_position],true): return _transaction.cached
	var found: Dictionary=db.query(Items.ITEM_SELECT+"WHERE i.uid=:uid AND c.location='account_claim' AND c.claim_account_id=:account;",{"uid":uid,"account":_transaction.account_id})
	if not found.ok: return _transaction.rollback("storage")
	if found.rows.is_empty(): return _reject("owner")
	var item:=ItemInstance.from_row(found.rows[0])
	if item==null or item.revision!=revision: return _reject("stale")
	var definition:=ItemDefinitions.get_definition(item.definition_id)
	if definition==null: return _reject("unknown_definition")
	var receiving:=Items.new(db).resolve_inventory_position(character,definition.inventory_height,requested_position)
	if not receiving.ok: return _reject(str(receiving.error))
	if not db.execute("UPDATE economy.item_instances SET owner_character_id=:owner,revision=revision+1 WHERE uid=:uid;",{"owner":character,"uid":uid}).ok: return _transaction.rollback("storage")
	if not db.execute("UPDATE economy.item_custody SET location='bag',owner_id=:owner,position=:position,claim_account_id=NULL WHERE uid=:uid;",{"owner":character,"position":receiving.position,"uid":uid}).ok: return _transaction.rollback("storage")
	return _transaction.commit({"ok":true,"uid":uid,"position":int(receiving.position)})

func receipt(character: int, command: String) -> Dictionary:
	return Seller.new(db,rejected).receipt(character,command)

func _reject(reason: String) -> Dictionary:
	return _transaction.commit({"ok":false,"error":reason})
