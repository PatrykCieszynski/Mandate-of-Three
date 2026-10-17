extends RefCounted
## Opt-in account Storage use cases. One native session owns the whole command.
## RPC/UI cannot choose the account or retarget the receiving character on retry.
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Grid = preload("res://source/common/gameplay/items/domain/storage_grid.gd")
const SELECT = "SELECT i.*,'storage' AS location,c.position AS bag_position,'' AS equipment_slot FROM economy.item_instances i JOIN economy.item_custody c ON c.uid=i.uid "
var db: Object
var committed:=false
var receipt_replay:=false

func _init(database: Object) -> void:
	db=database

func snapshot(character: int) -> Dictionary:
	var identity:=_account(character)
	if not identity.ok: return identity
	var result: Dictionary=db.query(SELECT+"WHERE c.location='account_storage' AND c.storage_account_id=:account ORDER BY c.position;",{"account":identity.account_id})
	if not result.ok or result.truncated: return _error("storage")
	var items: Array=[]
	for row: Dictionary in result.rows:
		var item:=ItemInstance.from_row(row)
		if item==null: return _error("invalid_item")
		var definition:=ItemDefinitions.get_definition(item.definition_id)
		if definition==null: return _error("unknown_definition")
		var display:=item.to_snapshot()
		display.merge({"item_name":definition.item_name,"icon_id":str(definition.icon_id),"stats":item.effective_stats(definition),"inventory_height":definition.inventory_height})
		items.append(display)
	return {"ok":true,"items":items}

func transfer_command(character: int, uid: String, revision: int, source: String, destination: String, position: int, operation_id: String) -> Dictionary:
	committed=false
	receipt_replay=false
	var transaction:=Commands.new(db)
	# Account lock precedes character lock and receipt lookup for every alt.
	if not transaction.begin(character,operation_id,"storage",[character,uid,revision,source,destination,position],true):
		receipt_replay=transaction.receipt_replay
		return transaction.cached
	var result:=_transfer_in_transaction(character,transaction.account_id,uid,revision,source,destination,position)
	if not result.ok: return transaction.rollback(str(result.error))
	var mutated:=bool(result.mutated)
	result=transaction.commit({"ok":true})
	committed=transaction.committed and mutated
	return result

func transfer_receipt(character: int, operation_id: String) -> Dictionary:
	if not Commands.valid_id(operation_id): return _error("request")
	var identity:=_account(character)
	if not identity.ok: return identity
	var result: Dictionary=db.query("SELECT result_json FROM economy.market_commands WHERE account_id=:account AND character_id=:character AND command_id=:command AND kind='storage';",{"account":identity.account_id,"character":character,"command":operation_id})
	if not result.ok: return _error("storage")
	if result.rows.is_empty(): return _error("unknown_command")
	var decoded:=Commands.decode(str(result.rows[0].result_json))
	return decoded if decoded.get("ok",false) else _error("storage")

func _transfer_in_transaction(character: int, account_id: int, uid: String, revision: int, source: String, destination: String, position: int) -> Dictionary:
	if (source=="inventory" and destination=="inventory") or source not in ["inventory","storage"] or destination not in ["inventory","storage"] or not ItemInstance.valid_uid(uid) or revision<0 or position < -1: return _error("request")
	var query: String=SELECT+"WHERE c.location='account_storage' AND c.storage_account_id=:owner AND i.uid=:uid;" if source=="storage" else Items.ITEM_SELECT+"WHERE i.owner_character_id=:owner AND c.owner_id=:owner AND c.location='bag' AND i.uid=:uid;"
	var result: Dictionary=db.query(query,{"owner":account_id if source=="storage" else character,"uid":uid})
	if not result.ok: return _error("storage")
	if result.rows.is_empty(): return _error("owner")
	var item:=ItemInstance.from_row(result.rows[0])
	if item==null: return _error("invalid_item")
	if item.revision!=revision: return _error("stale")
	var definition:=ItemDefinitions.get_definition(item.definition_id)
	if definition==null: return _error("unknown_definition")
	if destination=="inventory":
		var receiving:=Items.new(db).resolve_inventory_position(character,definition.inventory_height,position)
		if not receiving.ok:
			var reason: String=str(receiving.error)
			return _error("full" if reason=="inventory_full" else ("occupied" if reason=="request" else reason))
		position=int(receiving.position)
	else:
		result=db.query(SELECT+"WHERE c.location='account_storage' AND c.storage_account_id=:account;",{"account":account_id})
		if not result.ok or result.truncated: return _error("storage")
		var occupied: Dictionary={}
		for row: Dictionary in result.rows:
			if str(row.uid)==uid: continue
			var other:=ItemDefinitions.get_definition(StringName(row.definition_id))
			if other==null: return _error("unknown_definition")
			var footprint:=Grid.cells(int(row.bag_position),other.inventory_height)
			if footprint.is_empty(): return _error("placement")
			for cell: int in footprint: occupied[cell]=true
		if position==-1:
			for candidate: int in Grid.CAPACITY:
				if _fits(candidate,definition.inventory_height,occupied):
					position=candidate
					break
			if position==-1: return _error("full")
		if not _fits(position,definition.inventory_height,occupied): return _error("occupied")
	if source==destination and position==item.bag_position: return {"ok":true,"mutated":false}
	# Remove custody, keep UID/rolls, update provenance only on withdrawal.
	if not db.execute("DELETE FROM economy.item_custody WHERE uid=:uid;",{"uid":uid}).ok: return _error("storage")
	var provenance: int=character if destination=="inventory" else item.owner_character_id
	if not db.execute("UPDATE economy.item_instances SET owner_character_id=:owner,revision=revision+1 WHERE uid=:uid;",{"owner":provenance,"uid":uid}).ok: return _error("storage")
	result=db.execute("INSERT INTO economy.item_custody(uid,owner_id,location,position,storage_account_id) VALUES(:uid,:owner,:location,:position,:account);",{"uid":uid,"owner":provenance,"location":"bag" if destination=="inventory" else "account_storage","position":position,"account":null if destination=="inventory" else account_id})
	if not result.ok: return _error("storage")
	return {"ok":true,"mutated":true}

func _account(character: int) -> Dictionary:
	var result: Dictionary=db.query("SELECT account_id FROM economy.characters WHERE character_id=:character;",{"character":character})
	if not result.ok: return _error("storage")
	if result.rows.is_empty(): return _error("owner")
	return {"ok":true,"account_id":int(result.rows[0].account_id)}

func _fits(position: int, height: int, occupied: Dictionary) -> bool:
	var footprint:=Grid.cells(position,height)
	return not footprint.is_empty() and not footprint.any(func(cell: int) -> bool: return occupied.has(cell))

func _error(reason: String) -> Dictionary:
	return {"ok":false,"error":reason}
