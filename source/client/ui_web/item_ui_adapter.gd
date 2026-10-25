class_name ItemUiAdapter
extends RefCounted
## Character-local Inventory and Equipment; account Storage has its own adapter.
var _endpoint: InventoryEndpoint3D
var _dispatcher: UiCommandDispatcher
var _session: UiCommandSession
var _tree: SceneTree
signal craft_requested(payload: Dictionary)
signal recovery_needed
const LocalJournal = preload("res://source/client/ui_web/local_economy_journal.gd")
var journal = LocalJournal.new("inventory-","user://pending_inventory_commands")
var _context: Dictionary = {}
var _journal_ready := false
var _intent: Dictionary = {}
var _in_flight := false
var _disposed := false

func attach(endpoint: InventoryEndpoint3D, dispatcher: UiCommandDispatcher, session: UiCommandSession, tree: SceneTree) -> void:
	_endpoint = endpoint
	_dispatcher = dispatcher
	_session = session
	_tree = tree
	dispatcher.register_command("inventory.move_item", valid_move, _move)
	dispatcher.register_command("item.activate", valid_equipment, _activate)
	dispatcher.register_command("equipment.equip", valid_equipment, _equip)
	dispatcher.register_command("equipment.unequip", valid_unequip, _unequip)
	dispatcher.register_command("inventory.retry", func(p: Dictionary) -> bool: return p.is_empty(), retry_inventory)
	endpoint.state_changed.connect(publish)
	endpoint.operation_finished.connect(session.finish)
	publish(endpoint.state)

func dispose() -> void:
	_disposed = true
	if is_instance_valid(_endpoint):
		if _endpoint.state_changed.is_connected(publish): _endpoint.state_changed.disconnect(publish)
		if _endpoint.operation_finished.is_connected(_session.finish): _endpoint.operation_finished.disconnect(_session.finish)

static func tooltip_details(item: Dictionary) -> Dictionary:
	# Existing rolls stay unclassified; C1 rolls carry explicit prefix/suffix kind.
	var affixes: Array = []
	for affix: Dictionary in item.get("affixes", []):
		var value_text: String = str(affix.value)
		if affix.value >= 0: value_text = "+" + value_text
		var metadata: Dictionary=ItemAffixLabels.STATS.get(str(affix.stat),{})
		if metadata.get("unit","")=="percent": value_text+="%"
		var line: Dictionary={"lines": ["%s %s" % [value_text, metadata.get("label",str(affix.stat).capitalize())]]}
		if affix.get("affix_version",0)==1 and affix.get("kind","") in ["prefix","suffix"]: line.kind=affix.kind
		affixes.append(line)
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
	return {"rarity":str(item.get("rarity",ItemInstance.legacy_rarity(item.get("affixes",[])))),"properties":properties,"affixes":affixes}

static func item_model(item: Dictionary) -> Dictionary:
	var definition: ItemDefinition = ItemDefinitions.get_definition(StringName(item.definition_id))
	var name_text: String = str(item.item_name)
	if definition != null and not definition.stats_per_upgrade.is_empty(): name_text += " +%d" % int(item.upgrade_level)
	return {"primary_action":ItemDefinition.PrimaryAction.keys()[definition.primary_action] if definition != null else "NONE","id":str(item.uid),"revision":int(item.revision),"definition_id":str(item.definition_id),"upgrade_level":int(item.upgrade_level),"name":name_text,"icon_id":str(item.get("icon_id","")),"height":int(item.inventory_height),"quantity":int(item.amount),"tooltip":tooltip_details(item)}

func publish(snapshot: Dictionary) -> void:
	if _disposed or not snapshot.get("ok", false): return
	accept_context(snapshot)
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
	_dispatcher.set_domain("inventory", {"columns": InventoryGrid.COLUMNS, "rows": InventoryGrid.ROWS, "pages": InventoryGrid.PAGES, "items": bag, "recoveryPending":not _intent.is_empty() and bool(_intent.uncertain)})
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
func _activate(payload: Dictionary) -> Dictionary:
	for item: Dictionary in _endpoint.state.get("items",[]):
		if item.uid==payload.id and item.revision==payload.revision and item.location=="bag" and preload("res://source/common/gameplay/items/crafting/crafting_rules.gd").CURRENCIES.has(str(item.definition_id)):
			craft_requested.emit(payload);return {"ok":true}
	return await _submit(payload, "activate")

func _equip(payload: Dictionary) -> Dictionary:
	return await _submit(payload, "equip")

func _unequip(payload: Dictionary) -> Dictionary:
	return await _submit(payload, "unequip")

func _move(payload: Dictionary) -> Dictionary:
	return await _submit(payload)

func accept_context(snapshot: Dictionary) -> void:
	if _disposed or not snapshot.get("ok",false): return
	var context: Dictionary = snapshot.get("economic_context",{})
	if context.is_empty() or context == _context: return
	if not _context.is_empty():
		_journal_ready = false
		return
	_context = context.duplicate(true)
	var restored: Dictionary = journal.configure(context)
	if not restored.ok: return
	if not restored.entry.is_empty() and not valid_intent(restored.entry.payload): return
	_journal_ready = true
	if restored.entry.is_empty(): return
	_intent = restored.entry.duplicate(true)
	_intent.uncertain = true
	recovery_needed.emit()
	_retry.call_deferred(false) # Discovery can read, never automatically mutate.

static func valid_intent(p: Dictionary) -> bool:
	if p.size() != 2 or not p.get("action") is String or not p.get("item") is Dictionary: return false
	match p.action:
		"move": return valid_move(p.item)
		"activate", "equip": return valid_equipment(p.item)
		"unequip": return valid_unequip(p.item)
	return false

func _retain_intent() -> void:
	_intent.uncertain = true
	publish(_endpoint.state)
	recovery_needed.emit()

func _release_intent() -> bool:
	if not journal.clear_pending(_intent.id):
		_retain_intent()
		return false
	_intent.clear()
	return true

func retry_inventory(_payload: Dictionary = {}) -> Dictionary:
	return await _retry(true)

func _retry(allow_execution: bool) -> Dictionary:
	if _disposed: return _session.closed_result()
	if not _journal_ready: return {"ok":false,"error":"journal_unavailable"}
	if _intent.is_empty(): return {"ok":false,"error":"no_pending_inventory"}
	if _in_flight: return {"ok":false,"error":"too_fast"}
	var id := _session.begin()
	if id.is_empty(): return _session.closed_result()
	_in_flight = true
	_endpoint.request_inventory_receipt.rpc_id(1,_intent.id,id)
	var result := await _session.wait(id,_tree)
	if _disposed: return result
	_in_flight = false
	if result.ok or result.get("terminal",false):
		if not _release_intent(): return {"ok":false,"error":"journal_unavailable"}
		publish(_endpoint.state)
		return result
	if result.get("error","") == "unknown_command" and allow_execution:
		return await _submit(_intent.payload.item.duplicate(true),str(_intent.payload.action))
	_retain_intent()
	return {"ok":false,"error":"inventory_pending"}

func _submit(payload: Dictionary, action: String = "move") -> Dictionary:
	if _disposed: return _session.closed_result()
	if not _journal_ready: return {"ok":false,"error":"journal_unavailable"}
	if _in_flight: return {"ok":false,"error":"too_fast"}
	var intention := {"action":action,"item":payload.duplicate(true)}
	if not valid_intent(intention): return {"ok":false,"error":"request"}
	if not _intent.is_empty() and _intent.payload != intention: return {"ok":false,"error":"inventory_pending"}
	if _intent.is_empty():
		var operation_id := "inventory-" + Crypto.new().generate_random_bytes(16).hex_encode()
		if not journal.save_pending(operation_id,intention):
			_journal_ready = false
			return {"ok":false,"error":"journal_unavailable"}
		_intent = {"id":operation_id,"payload":intention,"uncertain":false}
	var id: String = _session.begin()
	if id.is_empty(): return _session.closed_result()
	_in_flight = true
	if action == "move":
		_endpoint.request_move_item.rpc_id(1, payload.id, int(payload.revision), int(payload.x), int(payload.y), int(payload.page), id, _intent.id)
	elif action == "activate":
		_endpoint.request_activate_item.rpc_id(1, payload.id, int(payload.revision), id, _intent.id)
	else:
		_endpoint.request_equipment.rpc_id(1, action, payload.id, int(payload.revision), id, int(payload.page) * InventoryGrid.PAGE_CELLS + int(payload.y) * InventoryGrid.COLUMNS + int(payload.x) if payload.has("x") else -1, _intent.id)
	var result := await _session.wait(id, _tree)
	if _disposed: return result
	_in_flight = false
	if result.ok or result.get("error","") in ["stale","owner","placement","slot","request","occupied","bag_full","inventory_full","unsupported","no_action","invalid_item","unknown_definition"]:
		if not _release_intent(): return {"ok":false,"error":"journal_unavailable"}
	else:
		_retain_intent()
		return {"ok":false,"error":"inventory_pending"}
	publish(_endpoint.state)
	return result
