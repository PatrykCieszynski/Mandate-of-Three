class_name ItemUiAdapter
extends RefCounted
## One item-domain adapter for Inventory, Equipment and Storage.
var _endpoint: InventoryEndpoint3D
var _dispatcher: UiCommandDispatcher
var _session: UiCommandSession
var _tree: SceneTree
var _storage_open: Callable

func attach(endpoint: InventoryEndpoint3D, dispatcher: UiCommandDispatcher, session: UiCommandSession, tree: SceneTree, storage_open: Callable) -> void:
	_endpoint = endpoint
	_dispatcher = dispatcher
	_session = session
	_tree = tree
	_storage_open = storage_open
	dispatcher.register_command("storage.transfer", valid_storage, _storage_transfer)
	dispatcher.register_command("inventory.move_item", valid_move, _move)
	dispatcher.register_command("item.activate", valid_equipment, _activate)
	dispatcher.register_command("equipment.equip", valid_equipment, _equip)
	dispatcher.register_command("equipment.unequip", valid_unequip, _unequip)
	endpoint.state_changed.connect(publish)
	endpoint.operation_finished.connect(session.finish)
	publish(endpoint.state)

func dispose() -> void:
	if is_instance_valid(_endpoint):
		if _endpoint.state_changed.is_connected(publish): _endpoint.state_changed.disconnect(publish)
		if _endpoint.operation_finished.is_connected(_session.finish): _endpoint.operation_finished.disconnect(_session.finish)
	_storage_open = Callable()

static func tooltip_details(item: Dictionary) -> Dictionary:
	# Existing rolls are shown faithfully. Prefix/suffix metadata is absent until
	# the content model defines it; no generated affixes or combat changes here.
	var affixes: Array = []
	for affix: Dictionary in item.get("affixes", []):
		var value_text: String = str(affix.value)
		if affix.value >= 0: value_text = "+" + value_text
		var metadata: Dictionary=ItemAffixLabels.STATS.get(str(affix.stat),{})
		if metadata.get("unit","")=="percent": value_text+="%"
		affixes.append({"lines": ["%s %s" % [value_text, metadata.get("label",str(affix.stat).capitalize())]]})
	var properties: Array = []
	for stat: Variant in item.get("stats",{}):
		var metadata: Dictionary=ItemAffixLabels.STATS.get(str(stat),{})
		var value: float=float(item.stats[stat])
		var text:=str(int(value)) if value==floor(value) else str(value)
		properties.append("%s: %s%s" % [metadata.get("label",str(stat).capitalize()),text,"%" if metadata.get("unit","")=="percent" else ""])
	for index: int in mini(item.get("sockets",[]).size(),maxi(0,8-properties.size())):
		var socket: Variant=item.sockets[index]
		var label: String=str(socket.get("definition_id",JSON.stringify(socket))) if socket is Dictionary else str(socket)
		properties.append("Socket %d: %s" % [index+1,label.left(240)])
	return {"properties":properties,"affixes":affixes}

static func item_model(item: Dictionary) -> Dictionary:
	var definition: ItemDefinition = ItemDefinitions.get_definition(StringName(item.definition_id))
	var name_text: String = str(item.item_name)
	if definition != null and not definition.stats_per_upgrade.is_empty(): name_text += " +%d" % int(item.upgrade_level)
	return {"id":str(item.uid),"revision":int(item.revision),"definition_id":str(item.definition_id),"upgrade_level":int(item.upgrade_level),"name":name_text,"icon_id":str(item.get("icon_id","")),"height":int(item.inventory_height),"quantity":int(item.amount),"tooltip":tooltip_details(item)}

func publish(snapshot: Dictionary) -> void:
	if not snapshot.get("ok", false): return
	var bag: Array = []
	var equipped: Array = []
	for item: Dictionary in snapshot.items:
		var display: Dictionary = item_model(item)
		if item.location == "equipment":
			display["slot"] = str(item.equipment_slot)
			equipped.append(display)
		elif item.location == "bag":
			var position: int = int(item.bag_position)
			display.merge({"x":position % InventoryGrid.COLUMNS, "y":(position % InventoryGrid.PAGE_CELLS) / InventoryGrid.COLUMNS, "page":position / InventoryGrid.PAGE_CELLS})
			bag.append(display)
	var stored: Array = []
	for item: Dictionary in snapshot.get("storage",{}).get("items",[]):
		var position: int = int(item.bag_position)
		var display: Dictionary = item_model(item)
		display.merge({"x":position % 15,"y":(position % 135) / 15,"page":position / 135})
		stored.append(display)
	if snapshot.get("storage",{}).get("ok",false): _dispatcher.set_domain("storage",{"columns":15,"rows":9,"pages":2,"items":stored})
	_dispatcher.set_domain("inventory", {"columns": InventoryGrid.COLUMNS, "rows": InventoryGrid.ROWS, "pages": InventoryGrid.PAGES, "items": bag})
	_dispatcher.set_domain("equipment", {"items":equipped, "stats":snapshot.get("stats", {})})

static func valid_item_identity(payload: Dictionary) -> bool:
	return payload.get("id") is String and ItemInstance.valid_uid(payload.id) and WebUiBridge.is_integer(payload.get("revision")) and payload.revision >= 0

static func valid_move(p: Dictionary) -> bool:
	return p.size() == 5 and p.has_all(["id", "revision", "x", "y", "page"]) and valid_item_identity(p) and WebUiBridge.is_integer(p.x) and WebUiBridge.is_integer(p.y) and p.x >= 0 and p.x < InventoryGrid.COLUMNS and p.y >= 0 and p.y < InventoryGrid.ROWS and WebUiBridge.is_integer(p.page) and p.page >= 0 and p.page < InventoryGrid.PAGES

static func valid_equipment(payload: Dictionary) -> bool:
	return payload.size() == 2 and valid_item_identity(payload)

static func valid_unequip(payload: Dictionary) -> bool:
	return valid_equipment(payload) or valid_move(payload)

static func valid_storage(p: Dictionary) -> bool:
	if p.size() != 8 or not p.has_all(["id","revision","from","to","x","y","page","quick"]) or not valid_item_identity(p): return false
	if (p.from == "inventory" and p.to == "inventory") or p.from not in ["inventory","storage"] or p.to not in ["inventory","storage"] or not p.quick is bool: return false
	var columns: int = 15 if p.to == "storage" else 5
	var pages: int = 2 if p.to == "storage" else 4
	return WebUiBridge.is_integer(p.x) and WebUiBridge.is_integer(p.y) and WebUiBridge.is_integer(p.page) and p.x >= 0 and p.x < columns and p.y >= 0 and p.y < 9 and p.page >= 0 and p.page < pages
func _storage_transfer(payload: Dictionary) -> Dictionary:
	# UX guard only. World authorizes account access; Storage currently has no NPC/range restriction.
	if not _storage_open.call(): return {"ok":false,"error":"closed"}
	var id: String = _session.begin()
	if id.is_empty(): return _session.closed_result()
	_endpoint.request_storage.rpc_id(1,payload.id,int(payload.revision),payload.from,payload.to,int(payload.x),int(payload.y),int(payload.page),payload.quick,id)
	return await _session.wait(id, _tree)
func _activate(payload: Dictionary) -> Dictionary:
	return await _submit(payload, "activate")

func _equip(payload: Dictionary) -> Dictionary:
	return await _submit(payload, "equip")

func _unequip(payload: Dictionary) -> Dictionary:
	return await _submit(payload, "unequip")

func _move(payload: Dictionary) -> Dictionary:
	return await _submit(payload)

func _submit(payload: Dictionary, action: String = "move") -> Dictionary:
	var id: String = _session.begin()
	if id.is_empty(): return _session.closed_result()
	if action == "move":
		_endpoint.request_move_item.rpc_id(1, payload.id, int(payload.revision), int(payload.x), int(payload.y), int(payload.page), id)
	elif action == "activate":
		_endpoint.request_activate_item.rpc_id(1, payload.id, int(payload.revision), id)
	else:
		_endpoint.request_equipment.rpc_id(1, action, payload.id, int(payload.revision), id, int(payload.page) * InventoryGrid.PAGE_CELLS + int(payload.y) * InventoryGrid.COLUMNS + int(payload.x) if payload.has("x") else -1)
	return await _session.wait(id, _tree)
