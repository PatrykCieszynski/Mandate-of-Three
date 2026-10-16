extends RefCounted
## Narrow P1c receiving/reading port. Gameplay authority and Inventory mutation
## endpoints remain on SQLite. Caller owns the entire native transaction.
var db: Object

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
	var result: Dictionary=db.query("SELECT c.account_id,COALESCE(r.revision,0) AS revision,m.value AS authority_id FROM economy.characters c LEFT JOIN economy.account_item_revisions r ON r.account_id=c.account_id JOIN economy.meta m ON m.key='economy_authority_id' WHERE c.character_id=:id;",{"id":character_id})
	if not result.ok or result.rows.is_empty(): return {}
	var row: Dictionary=result.rows[0]
	return {"authority_id":str(row.authority_id),"account_id":int(row.account_id),"character_id":character_id,"revision":int(row.revision)}

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

func resolve_inventory_position(character_id: int, height: int, requested_position: int = -1) -> Dictionary:
	if not db.in_transaction(): return {"ok":false,"error":"transaction"}
	if requested_position < -1 or height<1 or height>3: return {"ok":false,"error":"request"}
	if requested_position!=-1 and InventoryGrid.cells(requested_position,height).is_empty(): return {"ok":false,"error":"request"}
	# Protect capacity on this character while validating dependent reads/writes.
	# This is a local DB row lock, never an application-wide command queue.
	var result: Dictionary=db.query("SELECT character_id FROM economy.characters WHERE character_id=:id FOR UPDATE;",{"id":character_id})
	if not result.ok: return {"ok":false,"error":"storage"}
	if result.rows.is_empty(): return {"ok":false,"error":"owner"}
	result=db.query("SELECT i.definition_id,c.position FROM economy.item_instances i JOIN economy.item_custody c ON c.uid=i.uid WHERE c.owner_id=:id AND c.location='bag';",{"id":character_id})
	if not result.ok or result.truncated: return {"ok":false,"error":"storage"}
	var occupied: Dictionary={}
	for row: Dictionary in result.rows:
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
