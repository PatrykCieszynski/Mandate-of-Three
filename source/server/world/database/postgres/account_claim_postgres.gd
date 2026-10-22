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
var receipt_replay: bool:
	get: return _transaction.receipt_replay

func authorize_session(context: Dictionary) -> void: _transaction.economic_context=context.duplicate(true)

func _init(database: Object, rejected_commands: MarketRejectedCommands = null) -> void:
	db=database
	rejected=rejected_commands if rejected_commands!=null else MarketRejectedCommands.new()
	_transaction=Commands.new(db,rejected)

func claim_item(character: int, command: String, uid: String, revision: int, requested_position: int = -1) -> Dictionary:
	return _transaction.run_with_retry(_claim_once.bind(character,command,uid,revision,requested_position))

func _claim_once(character: int, command: String, uid: String, revision: int, requested_position: int) -> Dictionary:
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

## Trusted claim producer (Exchange withdrawal). Caller retains command/receipt
## ownership; this method never begins/commits or returns a provisional UI grant.
func receive_in_transaction(item: ItemInstance) -> Dictionary:
	if not db.in_transaction(): return {"ok":false,"error":"transaction"}
	if item==null or not ItemInstance.valid_uid(item.uid): return {"ok":false,"error":"request"}
	var definition:=ItemDefinitions.get_definition(item.definition_id)
	if definition==null: return {"ok":false,"error":"unknown_definition"}
	if item.amount<1 or item.amount>definition.stack_limit: return {"ok":false,"error":"request"}
	var identity: Dictionary=db.query("SELECT c.account_id FROM economy.characters c JOIN economy.accounts a ON a.account_id=c.account_id WHERE c.character_id=:owner FOR NO KEY UPDATE OF a;",{"owner":item.owner_character_id})
	if not identity.ok or identity.rows.is_empty(): return {"ok":false,"error":"storage" if not identity.ok else "owner"}
	if not db.execute("INSERT INTO economy.item_instances(uid,owner_character_id,definition_id,amount,upgrade_level,affixes_json,sockets_json,revision) VALUES(:uid,:owner,:definition,:amount,:upgrade,:affixes,:sockets,:revision);",{"uid":item.uid,"owner":item.owner_character_id,"definition":str(item.definition_id),"amount":item.amount,"upgrade":item.upgrade_level,"affixes":JSON.stringify(item.affixes),"sockets":JSON.stringify(item.sockets),"revision":item.revision}).ok: return {"ok":false,"error":"storage"}
	if not db.execute("INSERT INTO economy.item_custody(uid,location,owner_id,position,claim_account_id) VALUES(:uid,'account_claim',:owner,-1,:account);",{"uid":item.uid,"owner":item.owner_character_id,"account":int(identity.rows[0].account_id)}).ok: return {"ok":false,"error":"storage"}
	return {"ok":true,"uid":item.uid}

func _reject(reason: String) -> Dictionary:
	return _transaction.commit({"ok":false,"error":reason})
