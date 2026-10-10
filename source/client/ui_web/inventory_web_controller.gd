class_name InventoryWebController
extends Node
## Client composition only. UID/revision intentions go through authenticated RPCs.
var host: WebUiHost
var bridge: WebUiBridge
var dispatcher: UiCommandDispatcher
var world: SpikeWorld3D
var opened: bool = false
var equipment_opened: bool = false
var storage_opened: bool = false
var _sequence: int = 0
var _pending_commands: Dictionary[String, Dictionary] = {}
var _request_epoch: String = Crypto.new().generate_random_bytes(8).hex_encode()
const UI_SCALES: Array[float] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.4, 1.5]
var ui_scale: float = 1.0
var _scale_initialized: bool = false

func setup(game_world: SpikeWorld3D) -> void:
	world = game_world
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	host = WebUiHost.new()
	host.capture_keyboard_on_click = false
	host.entry_path = "res://source/client/ui_web/web/inventory/game.html"
	layer.add_child(host)
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bridge = WebUiBridge.new()
	add_child(bridge)
	dispatcher = UiCommandDispatcher.new()
	add_child(dispatcher)
	host.message_received.connect(bridge.receive)
	host.navigation_started.connect(bridge.reset_transport)
	host.navigation_started.connect(func() -> void: _cancel_pending("ui_reload"))
	Client.connection_changed.connect(func(connected: bool) -> void:
		if not connected: _cancel_pending("disconnected"))
	bridge.outgoing.connect(host.send)
	bridge.interactive_regions_received.connect(host.update_interactive_regions)
	dispatcher.attach(bridge)
	dispatcher.register_command("npc.interact", _valid_npc, func(p: Dictionary) -> Dictionary: return await interact_npc(p.npc_instance_id))
	dispatcher.register_command("npc.select_service", _valid_npc_service, func(p: Dictionary) -> Dictionary: return await _npc_submit("select", p.npc_instance_id, p.service_id))
	dispatcher.register_command("npc.close", func(p: Dictionary) -> bool: return p.is_empty(), func(_p: Dictionary) -> Dictionary: return await _npc_submit("close"))
	world.npc_endpoint.state_changed.connect(_npc_state)
	world.npc_endpoint.operation_finished.connect(_operation_finished)
	_npc_state(world.npc_endpoint.state)
	dispatcher.register_command("storage.transfer", _valid_storage, _storage_transfer)
	dispatcher.register_command("storage.close", func(p: Dictionary) -> bool: return p.is_empty(), _close_storage)
	dispatcher.register_command("inventory.move_item", _valid_move, _move)
	dispatcher.register_command("item.activate", _valid_equipment, _activate)
	dispatcher.register_command("equipment.equip", _valid_equipment, _equip)
	dispatcher.register_command("equipment.unequip", _valid_unequip, _unequip)
	dispatcher.register_command("equipment.close", func(p: Dictionary) -> bool: return p.is_empty(), _close_equipment)
	dispatcher.register_command("inventory.close", func(p: Dictionary) -> bool: return p.is_empty(), _close)
	host.keyboard_owner_changed.connect(func(owner: String) -> void: ClientState.menu_open = owner != "gameplay")
	host.resized.connect(_layout)
	host.failure.connect(_failure)
	world.inventory_endpoint.state_changed.connect(_inventory)
	world.inventory_endpoint.operation_finished.connect(_operation_finished)
	world.currency_endpoint.state_changed.connect(_wallet)
	_inventory(world.inventory_endpoint.state)
	_wallet(world.currency_endpoint.state)
	ClientState.settings.setting_changed.connect(_setting_changed)
	_layout()
	# Warm the browser/page on world entry. DOM stays hidden until inventory_open.
	# UI_READY receives the current snapshot, including updates during startup.
	host.open()

func _npc_state(snapshot: Dictionary) -> void:
	dispatcher.set_domain("npc", snapshot)

static func _valid_npc(p: Dictionary) -> bool:
	return p.size() == 1 and p.get("npc_instance_id") is String and NeutralNpc3D.valid_instance_id(p.npc_instance_id)

static func _valid_npc_service(p: Dictionary) -> bool:
	return p.size() == 2 and p.get("npc_instance_id") is String and NeutralNpc3D.valid_instance_id(p.npc_instance_id) and p.get("service_id") is String and GameplayContentId.valid(StringName(p.service_id))

func interact_npc(instance_id: String) -> Dictionary:
	return await _npc_submit("interact", instance_id)

func _npc_submit(action: String, instance_id: String = "", service_id: String = "") -> Dictionary:
	var id: String = _begin_command()
	world.npc_endpoint.request_interaction.rpc_id(1, action, instance_id, service_id, id)
	return await _wait_command(id)

func _inventory(snapshot: Dictionary) -> void:
	if not snapshot.get("ok", false): return
	var bag: Array = []
	var equipped: Array = []
	for item: Dictionary in snapshot.items:
		var comparison: Dictionary = world.inventory_endpoint.weapon_comparison(item)
		var display := {"id": str(item.uid), "revision": int(item.revision), "name": "%s +%d" % [item.item_name, item.upgrade_level], "icon_id": str(item.get("icon_id", "")), "height": int(item.inventory_height), "quantity": int(item.amount), "description": "Attack %d. After equipping: %d (%+d)." % [int(item.stats.get("attack", 0)), comparison.attack, comparison.delta]}
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
		stored.append({"id":str(item.uid),"revision":int(item.revision),"name":"%s +%d" % [item.item_name,item.upgrade_level],"icon_id":str(item.icon_id),"height":int(item.inventory_height),"quantity":int(item.amount),"x":position % 15,"y":(position % 135) / 15,"page":position / 135})
	if snapshot.get("storage",{}).get("ok",false): dispatcher.set_domain("storage",{"columns":15,"rows":9,"pages":2,"items":stored})
	dispatcher.set_domain("inventory", {"columns": InventoryGrid.COLUMNS, "rows": InventoryGrid.ROWS, "pages": InventoryGrid.PAGES, "items": bag})
	dispatcher.set_domain("equipment", {"items":equipped, "stats":snapshot.get("stats", {})})

func _wallet(snapshot: Dictionary) -> void:
	dispatcher.set_domain("wallet", {"balance": int(snapshot.get("balance", 0)), "ready": snapshot.has("balance")})

static func _valid_identity(payload: Dictionary) -> bool:
	return payload.get("id") is String and ItemInstance.valid_uid(payload.id) and WebUiBridge.is_integer(payload.get("revision")) and payload.revision >= 0

static func _valid_move(p: Dictionary) -> bool:
	return p.size() == 5 and p.has_all(["id", "revision", "x", "y", "page"]) and _valid_identity(p) and WebUiBridge.is_integer(p.x) and WebUiBridge.is_integer(p.y) and p.x >= 0 and p.x < InventoryGrid.COLUMNS and p.y >= 0 and p.y < InventoryGrid.ROWS and WebUiBridge.is_integer(p.page) and p.page >= 0 and p.page < InventoryGrid.PAGES

static func _valid_scale(payload: Dictionary) -> bool:
	return payload.size() == 1 and WebUiBridge.is_integer(payload.get("percent")) and float(payload.percent) / 100.0 in UI_SCALES

static func _valid_equipment(payload: Dictionary) -> bool:
	return payload.size() == 2 and _valid_identity(payload)

static func _valid_unequip(payload: Dictionary) -> bool:
	return _valid_equipment(payload) or _valid_move(payload)

static func _valid_storage(p: Dictionary) -> bool:
	if p.size() != 8 or not p.has_all(["id","revision","from","to","x","y","page","quick"]) or not _valid_identity(p): return false
	if (p.from == "inventory" and p.to == "inventory") or p.from not in ["inventory","storage"] or p.to not in ["inventory","storage"] or not p.quick is bool: return false
	var columns: int = 15 if p.to == "storage" else 5
	var pages: int = 2 if p.to == "storage" else 4
	return WebUiBridge.is_integer(p.x) and WebUiBridge.is_integer(p.y) and WebUiBridge.is_integer(p.page) and p.x >= 0 and p.x < columns and p.y >= 0 and p.y < 9 and p.page >= 0 and p.page < pages
func _storage_transfer(payload: Dictionary) -> Dictionary:
	# UX guard only. World authorizes account access; Storage currently has no NPC/range restriction.
	if not storage_opened: return {"ok":false,"error":"closed"}
	var id: String = _begin_command()
	world.inventory_endpoint.request_storage.rpc_id(1,payload.id,int(payload.revision),payload.from,payload.to,int(payload.x),int(payload.y),int(payload.page),payload.quick,id)
	return await _wait_command(id)
func _close_storage(_payload: Dictionary) -> Dictionary:
	storage_opened = false
	_layout()
	return {"ok":true}

func _activate(payload: Dictionary) -> Dictionary:
	return await _submit(payload, "activate")

func _equip(payload: Dictionary) -> Dictionary:
	return await _submit(payload, "equip")

func _unequip(payload: Dictionary) -> Dictionary:
	return await _submit(payload, "unequip")

func _move(payload: Dictionary) -> Dictionary:
	return await _submit(payload)

func _begin_command() -> String:
	_sequence += 1
	var id: String = "web-%s-%d" % [_request_epoch, _sequence]
	_pending_commands[id] = {"result":{}}
	return id

func _submit(payload: Dictionary, action: String = "move") -> Dictionary:
	var id: String = _begin_command()
	if action == "move":
		world.inventory_endpoint.request_move_item.rpc_id(1, payload.id, int(payload.revision), int(payload.x), int(payload.y), int(payload.page), id)
	elif action == "activate":
		world.inventory_endpoint.request_activate_item.rpc_id(1, payload.id, int(payload.revision), id)
	else:
		world.inventory_endpoint.request_equipment.rpc_id(1, action, payload.id, int(payload.revision), id, int(payload.page) * InventoryGrid.PAGE_CELLS + int(payload.y) * InventoryGrid.COLUMNS + int(payload.x) if payload.has("x") else -1)
	return await _wait_command(id)

func _wait_command(id: String, timeout_ms: int = 2500) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while _pending_commands.has(id) and _pending_commands[id].result.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.025).timeout
	var result: Dictionary = _pending_commands.get(id, {"result":{}}).result.duplicate(true)
	_pending_commands.erase(id)
	return result if not result.is_empty() else {"ok":false, "error":"timeout"}

func _operation_finished(id: String, result: Dictionary) -> void:
	if _pending_commands.has(id) and _pending_commands[id].result.is_empty():
		_pending_commands[id].result = result.duplicate(true)

func _cancel_pending(reason: String) -> void:
	for entry: Dictionary in _pending_commands.values():
		if entry.result.is_empty(): entry.result = {"ok":false, "error":reason}

func _close(_payload: Dictionary) -> Dictionary:
	opened = false
	storage_opened = false
	_layout()
	host.set_modal(false)
	return {"ok": true}

func _close_equipment(_payload: Dictionary) -> Dictionary:
	equipment_opened = false
	_layout()
	return {"ok":true}

func set_open(active: bool) -> void:
	opened = active
	if not active: storage_opened = false
	equipment_opened = active
	_layout()
	host.set_modal(false) # Browser stays alive; opening only changes DOM visibility.

func _unhandled_key_input(event: InputEvent) -> void:
	if ClientState.menu_open or not world.input_enabled: return
	if not event is InputEventKey or not event.pressed or event.echo: return
	if event.physical_keycode == KEY_I:
		set_open(not (opened or equipment_opened))
		get_viewport().set_input_as_handled()
	elif event.physical_keycode == KEY_B:
		storage_opened = not storage_opened
		if storage_opened: opened = true
		_layout()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_ESCAPE and (opened or equipment_opened or storage_opened or world.npc_endpoint.state.get("active", false)):
		# Presentation shortcut only: web cancels carry first, otherwise requests close.
		bridge.send("ui.shortcut", {"key": "Escape"})
		get_viewport().set_input_as_handled()

func _failure(reason: String) -> void:
	opened = false
	ClientState.menu_open = false
	_cancel_pending("ui_unavailable")
	host.destroy_browser()
	equipment_opened = false
	storage_opened = false
	world.show_ui_failure(reason)
	set_process_unhandled_key_input(false)

func _exit_tree() -> void:
	_cancel_pending("teardown")
	ClientState.menu_open = false
	if is_instance_valid(host): host.destroy_browser()

func _setting_changed(section: StringName, property: StringName, value: Variant) -> void:
	if section != &"interface" or property != &"ui_scale_percent": return
	if _valid_scale({"percent":value}): set_ui_scale(float(value) / 100.0)
	elif value == 0:
		_scale_initialized = false
		_layout()

func set_ui_scale(value: float) -> void:
	if value not in UI_SCALES: return
	ui_scale = value
	_scale_initialized = true
	_layout()

func _layout() -> void:
	if not is_instance_valid(host) or not is_instance_valid(dispatcher): return
	if not _scale_initialized:
		ui_scale = 0.9 if host.size.y <= 720 else (1.5 if host.size.y >= 2160 else (1.1 if host.size.y >= 1440 else 1.0))
		var configured: float = float(ProjectSettings.get_setting("mandate/ui_scale", ui_scale))
		var saved: Variant = ClientState.settings.get_value(&"interface", &"ui_scale_percent")
		if _valid_scale({"percent": saved}): configured = float(saved) / 100.0
		for argument: String in OS.get_cmdline_args():
			if argument.begins_with("--ui-scale="): configured = argument.trim_prefix("--ui-scale=").to_float() / 100.0
		if configured in UI_SCALES: ui_scale = configured
		_scale_initialized = true
	dispatcher.set_domain("hud", {"storage_open":storage_opened, "inventory_open": opened, "equipment_open":equipment_opened, "ui_scale": ui_scale, "viewport": {"width": host.size.x, "height": host.size.y}})
