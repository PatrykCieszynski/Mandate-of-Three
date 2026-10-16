extends RefCounted
## Opt-in character Inventory port. World endpoints remain on SQLite.
## Every mutation and receipt is owned by one native transaction/session.
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const ITEM_SELECT = "SELECT i.*,c.location,c.position AS bag_position,c.equipment_slot FROM economy.item_instances i JOIN economy.item_custody c ON c.uid=i.uid "
var db: Object
var committed:=false
var receipt_replay:=false

func _init(database: Object) -> void:
	db=database

## Trusted server identity import only. Never reassign an existing character.
func bind_character(character_id: int, account_id: int) -> bool:
	if character_id<=0 or account_id<=0: return false
	var result: Dictionary = db.execute("INSERT INTO economy.characters(character_id,account_id) VALUES(:character,:account) ON CONFLICT DO NOTHING;",{"character":character_id,"account":account_id})
	if not result.ok: return false
	result=db.query("SELECT account_id FROM economy.characters WHERE character_id=:character;",{"character":character_id})
	return result.ok and result.rows.size()==1 and int(result.rows[0].account_id)==account_id

func read_state(character_id: int) -> Dictionary:
	return Commands.read_state(db,character_id)

func inventory(character_id: int) -> Dictionary:
	var result: Dictionary=db.query("SELECT i.*,c.location,c.position AS bag_position,c.equipment_slot FROM economy.item_instances i JOIN economy.item_custody c ON c.uid=i.uid WHERE i.owner_character_id=:id AND c.owner_id=:id ORDER BY CASE c.location WHEN 'equipment' THEN 0 ELSE 1 END,c.position,i.uid;",{"id":character_id})
	if not result.ok or result.truncated: return {"ok":false,"error":"storage"}
	var items: Array=[]
	var equipment: Dictionary={}
	var stats: Dictionary={"attack":10.0,"attack_speed":PlayerResource.BASE_STATS[Stat.ATTACK_SPEED]}
	for row: Dictionary in result.rows:
		var item:=ItemInstance.from_row(row)
		if item==null: return {"ok":false,"error":"invalid_item"}
		var definition:=ItemDefinitions.get_definition(item.definition_id)
		if definition==null: return {"ok":false,"error":"unknown_definition"}
		var snapshot:=item.to_snapshot()
		snapshot.merge({"item_name":definition.item_name,"icon_id":str(definition.icon_id),"stats":item.effective_stats(definition),"inventory_height":definition.inventory_height})
		items.append(snapshot)
		if item.location=="equipment":
			equipment[str(item.equipment_slot)]=item.uid
			for stat: Variant in snapshot.stats: stats[stat]=float(stats.get(stat,0))+float(snapshot.stats[stat])
	for item: Dictionary in items:
		if item.uid==equipment.get("weapon","") and item.definition_id=="dev_trace_sword": stats.attack=1.0
	var state:=read_state(character_id)
	if state.is_empty(): return {"ok":false,"error":"owner"}
	return {"ok":true,"items":items,"equipment":equipment,"stats":stats,"item_state":state}

func resolve_inventory_position(character_id: int, height: int, requested_position: int = -1, excluded: Array = []) -> Dictionary:
	if not db.in_transaction(): return {"ok":false,"error":"transaction"}
	if requested_position < -1 or height<1 or height>3: return {"ok":false,"error":"request"}
	if requested_position!=-1 and InventoryGrid.cells(requested_position,height).is_empty(): return {"ok":false,"error":"request"}
	# Protect capacity on this character while validating dependent reads/writes.
	# This is a local DB row lock, never an application-wide command queue.
	var result: Dictionary=db.query("SELECT character_id FROM economy.characters WHERE character_id=:id FOR UPDATE;",{"id":character_id})
	if not result.ok: return {"ok":false,"error":"storage"}
	if result.rows.is_empty(): return {"ok":false,"error":"owner"}
	result=db.query("SELECT i.uid,i.definition_id,c.position FROM economy.item_instances i JOIN economy.item_custody c ON c.uid=i.uid WHERE c.owner_id=:id AND c.location='bag';",{"id":character_id})
	if not result.ok or result.truncated: return {"ok":false,"error":"storage"}
	var occupied: Dictionary={}
	for row: Dictionary in result.rows:
		if str(row.uid) in excluded: continue
		var definition:=ItemDefinitions.get_definition(StringName(row.definition_id))
		if definition==null: return {"ok":false,"error":"storage"}
		var cells:=InventoryGrid.cells(int(row.position),definition.inventory_height)
		if cells.is_empty(): return {"ok":false,"error":"storage"}
		for cell: int in cells: occupied[cell]=true
	if requested_position!=-1:
		return {"ok":true,"position":requested_position} if InventoryGrid.fits(requested_position,height,occupied) else {"ok":false,"error":"occupied"}
	for position: int in InventoryGrid.CAPACITY:
		if InventoryGrid.fits(position,height,occupied): return {"ok":true,"position":position}
	return {"ok":false,"error":"inventory_full"}

func receive_item_in_transaction(item: ItemInstance, requested_position: int = -1) -> Dictionary:
	if not db.in_transaction(): return {"ok":false,"error":"transaction"}
	if item==null or not ItemInstance.valid_uid(item.uid): return {"ok":false,"error":"request"}
	var definition:=ItemDefinitions.get_definition(item.definition_id)
	if definition==null: return {"ok":false,"error":"unknown_definition"}
	if item.amount<1 or item.amount>definition.stack_limit: return {"ok":false,"error":"storage"}
	var receiving:=resolve_inventory_position(item.owner_character_id,definition.inventory_height,requested_position)
	if not receiving.ok: return receiving
	var result: Dictionary=db.execute("INSERT INTO economy.item_instances(uid,owner_character_id,definition_id,amount,upgrade_level,affixes_json,sockets_json,revision) VALUES(:uid,:owner,:definition,:amount,:upgrade,:affixes,:sockets,:revision);",{"uid":item.uid,"owner":item.owner_character_id,"definition":str(item.definition_id),"amount":item.amount,"upgrade":item.upgrade_level,"affixes":JSON.stringify(item.affixes),"sockets":JSON.stringify(item.sockets),"revision":item.revision})
	if not result.ok: return {"ok":false,"error":"storage"}
	result=db.execute("INSERT INTO economy.item_custody(uid,location,owner_id,position) VALUES(:uid,'bag',:owner,:position);",{"uid":item.uid,"owner":item.owner_character_id,"position":receiving.position})
	if not result.ok: return {"ok":false,"error":"storage"}
	return {"ok":true,"uid":item.uid,"position":receiving.position}

func initialize_character(owner: int) -> Dictionary:
	committed=false
	var started:=_begin_character(owner)
	if not started.ok: return started
	var result: Dictionary=db.query("SELECT owner_character_id FROM economy.item_initializations WHERE owner_character_id=:owner;",{"owner":owner})
	if not result.ok: return _rollback("storage")
	if not result.rows.is_empty():
		if not db.rollback():
			db.close()
			return _error("storage")
		return {"ok":true}
	for index: int in 2:
		var item:=ItemInstance.create(ItemDefinitions.IRON_SWORD,owner,[{"stat":"attack","value":3 if index==0 else 7}])
		if not receive_item_in_transaction(item,index).ok: return _rollback("storage")
	if not db.execute("INSERT INTO economy.item_initializations(owner_character_id) VALUES(:owner);",{"owner":owner}).ok: return _rollback("storage")
	return _commit()

func claim_ground_item(owner: int, drop_uid: String, item: ItemInstance) -> Dictionary:
	committed=false
	if item==null or not ItemInstance.valid_uid(drop_uid) or item.uid!=drop_uid: return _error("request")
	var started:=_begin_character(owner)
	if not started.ok: return started
	var result: Dictionary=db.query("SELECT drop_uid FROM economy.ground_item_claims WHERE drop_uid=:uid;",{"uid":drop_uid})
	if not result.ok: return _rollback("storage")
	if not result.rows.is_empty(): return _rollback("claimed")
	if item.owner_character_id!=owner: return _rollback("owner")
	var definition:=ItemDefinitions.get_definition(item.definition_id)
	if definition==null: return _rollback("request")
	var receiving:=resolve_inventory_position(owner,definition.inventory_height)
	if not receiving.ok: return _rollback("bag_full" if receiving.error=="inventory_full" else str(receiving.error))
	if not db.execute("INSERT INTO economy.ground_item_claims(drop_uid,owner_character_id) VALUES(:uid,:owner);",{"uid":drop_uid,"owner":owner}).ok: return _rollback("storage")
	if not receive_item_in_transaction(item,int(receiving.position)).ok: return _rollback("storage")
	result=_commit()
	if result.ok: result.uid=item.uid
	return result

func inventory_command(owner: int, action: String, uid: String, revision: int, position: int, operation_id: String) -> Dictionary:
	committed=false
	receipt_replay=false
	if action not in ["move","equip","unequip","activate"] or not ItemInstance.valid_uid(uid) or revision<0: return _error("request")
	if (action in ["activate","equip"] and position!=-1) or position < -1 or position>=InventoryGrid.CAPACITY: return _error("request")
	var transaction:=Commands.new(db)
	if not transaction.begin(owner,operation_id,"inventory",[owner,action,uid,revision,position]):
		receipt_replay=transaction.receipt_replay
		return transaction.cached
	var result: Dictionary
	match action:
		"activate": result=_activate_in_transaction(owner,uid,revision)
		"move": result=_move_in_transaction(owner,uid,revision,position)
		_: result=_equipment_in_transaction(owner,uid,revision,action,position)
	if not result.ok: return transaction.rollback(str(result.error))
	var mutated:=bool(result.mutated)
	result=transaction.commit({"ok":true})
	committed=transaction.committed and mutated
	return result

func inventory_receipt(owner: int, operation_id: String) -> Dictionary:
	if not Commands.valid_id(operation_id): return _error("request")
	var result: Dictionary=db.query("SELECT account_id FROM economy.characters WHERE character_id=:owner;",{"owner":owner})
	if not result.ok: return _error("storage")
	if result.rows.is_empty(): return _error("owner")
	result=db.query("SELECT result_json FROM economy.market_commands WHERE account_id=:account AND character_id=:owner AND command_id=:command AND kind='inventory';",{"account":result.rows[0].account_id,"owner":owner,"command":operation_id})
	if not result.ok: return _error("storage")
	if result.rows.is_empty(): return _error("unknown_command")
	var decoded:=Commands.decode(str(result.rows[0].result_json))
	return decoded if decoded.get("ok",false) else _error("storage")

func _activate_in_transaction(owner: int, uid: String, revision: int) -> Dictionary:
	var found:=_find_item(owner,uid)
	if not found.ok: return found
	var item: ItemInstance=found.item
	if item.revision!=revision: return _error("stale")
	var definition:=ItemDefinitions.get_definition(item.definition_id)
	if definition==null: return _error("unknown_definition")
	match definition.primary_action:
		ItemDefinition.PrimaryAction.EQUIP: return _equipment_in_transaction(owner,uid,revision,"equip")
		ItemDefinition.PrimaryAction.USE: return _error("unsupported")
		_: return _error("no_action")

func _move_in_transaction(owner: int, uid: String, revision: int, position: int) -> Dictionary:
	if position<0: return _error("request")
	var found:=_find_item(owner,uid)
	if not found.ok: return found
	var item: ItemInstance=found.item
	if item.location!="bag": return _error("placement")
	if item.revision!=revision: return _error("stale")
	if item.bag_position==position: return {"ok":true,"mutated":false}
	var definition:=ItemDefinitions.get_definition(item.definition_id)
	if definition==null: return _error("unknown_definition")
	var receiving:=resolve_inventory_position(owner,definition.inventory_height,position,[uid])
	if not receiving.ok: return receiving
	if not db.execute("UPDATE economy.item_custody SET position=:position WHERE uid=:uid AND owner_id=:owner AND location='bag';",{"position":position,"uid":uid,"owner":owner}).ok or not _increment_revision(uid,owner): return _error("storage")
	return {"ok":true,"mutated":true}

func _equipment_in_transaction(owner: int, uid: String, revision: int, action: String, position: int = -1) -> Dictionary:
	var found:=_find_item(owner,uid)
	if not found.ok: return found
	var item: ItemInstance=found.item
	if item.revision!=revision: return _error("stale")
	var definition:=ItemDefinitions.get_definition(item.definition_id)
	if definition==null or definition.equipment_slot==&"": return _error("slot")
	if action=="unequip" and item.location=="bag" and position!=-1: return _error("placement")
	if (action=="equip" and item.location=="equipment") or (action=="unequip" and item.location=="bag"): return {"ok":true,"mutated":false}
	if action=="unequip":
		var receiving:=resolve_inventory_position(owner,definition.inventory_height,position)
		if not receiving.ok: return _error("bag_full" if receiving.error=="inventory_full" else str(receiving.error))
		if not _remove_placement(uid) or not _place(uid,owner,"bag",int(receiving.position),"") or not _increment_revision(uid,owner): return _error("storage")
	else:
		var result: Dictionary=db.query("SELECT i.uid,i.definition_id FROM economy.item_instances i JOIN economy.item_custody c ON c.uid=i.uid WHERE c.owner_id=:owner AND c.location='equipment' AND c.equipment_slot=:slot;",{"owner":owner,"slot":str(definition.equipment_slot)})
		if not result.ok: return _error("storage")
		var previous_uid: String="" if result.rows.is_empty() else str(result.rows[0].uid)
		var previous_position: int=item.bag_position
		if previous_uid!="":
			var previous_definition:=ItemDefinitions.get_definition(StringName(result.rows[0].definition_id))
			if previous_definition==null: return _error("unknown_definition")
			var receiving:=resolve_inventory_position(owner,previous_definition.inventory_height,previous_position,[uid])
			if not receiving.ok:
				if receiving.error not in ["occupied","request"]: return receiving
				receiving=resolve_inventory_position(owner,previous_definition.inventory_height,-1,[uid])
			if not receiving.ok: return _error("bag_full" if receiving.error=="inventory_full" else str(receiving.error))
			previous_position=int(receiving.position)
		# Delete/reinsert custody, preserving SQLite swap and watermark semantics.
		if not _remove_placement(uid): return _error("storage")
		if previous_uid!="":
			if not _remove_placement(previous_uid) or not _place(previous_uid,owner,"bag",previous_position,"") or not _increment_revision(previous_uid,owner): return _error("storage")
		if not _place(uid,owner,"equipment",-1,str(definition.equipment_slot)) or not _increment_revision(uid,owner): return _error("storage")
	return {"ok":true,"mutated":true}

func _find_item(owner: int, uid: String) -> Dictionary:
	var result: Dictionary=db.query(ITEM_SELECT+"WHERE i.uid=:uid AND i.owner_character_id=:owner AND c.owner_id=:owner;",{"uid":uid,"owner":owner})
	if not result.ok: return _error("storage")
	if result.rows.is_empty(): return _error("owner")
	var item:=ItemInstance.from_row(result.rows[0])
	return {"ok":true,"item":item} if item!=null else _error("invalid_item")

func _remove_placement(uid: String) -> bool:
	return db.execute("DELETE FROM economy.item_custody WHERE uid=:uid;",{"uid":uid}).ok

func _place(uid: String, owner: int, location: String, position: int, slot: String) -> bool:
	return db.execute("INSERT INTO economy.item_custody(uid,owner_id,location,position,equipment_slot) VALUES(:uid,:owner,:location,:position,:slot);",{"uid":uid,"owner":owner,"location":location,"position":position,"slot":slot}).ok

func _increment_revision(uid: String, owner: int) -> bool:
	return db.execute("UPDATE economy.item_instances SET revision=revision+1 WHERE uid=:uid AND owner_character_id=:owner;",{"uid":uid,"owner":owner}).ok

func _begin_character(owner: int) -> Dictionary:
	if db.in_transaction() or not db.begin(): return _error("storage")
	var result: Dictionary=db.query("SELECT character_id FROM economy.characters WHERE character_id=:owner FOR UPDATE;",{"owner":owner})
	if not result.ok: return _rollback("storage")
	if result.rows.is_empty(): return _rollback("owner")
	return {"ok":true}

func _commit() -> Dictionary:
	if not db.commit():
		db.close()
		return {"ok":false,"error":"outcome_unknown","outcome_unknown":true}
	committed=true
	return {"ok":true}

func _rollback(error: String) -> Dictionary:
	if not db.rollback():
		db.close()
		return _error("storage")
	return _error(error)

func _error(error: String) -> Dictionary:
	return {"ok":false,"error":error}
