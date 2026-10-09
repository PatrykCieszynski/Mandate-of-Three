class_name InventoryWebController
extends Node
## Client composition only. UID/revision intentions go through authenticated RPCs.
var host: WebUiHost
var bridge: WebUiBridge
var dispatcher: UiCommandDispatcher
var world: SpikeWorld3D
var opened: bool = false
var equipment_opened: bool = false
var _sequence: int = 0
var _active_command: String = ""
var _result: Dictionary = {}
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
	bridge.outgoing.connect(host.send)
	bridge.interactive_regions_received.connect(host.update_interactive_regions)
	dispatcher.attach(bridge)
	dispatcher.register_command("inventory.move_item", _valid_move, _move)
	dispatcher.register_command("equipment.equip", _valid_equipment, _equip)
	dispatcher.register_command("equipment.unequip", _valid_equipment, _unequip)
	dispatcher.register_command("equipment.close", func(p: Dictionary) -> bool: return p.is_empty(), _close_equipment)
	dispatcher.register_command("inventory.close", func(p: Dictionary) -> bool: return p.is_empty(), _close)
	host.keyboard_owner_changed.connect(func(owner: String) -> void: ClientState.menu_open = owner != "gameplay")
	host.resized.connect(_layout)
	host.failure.connect(_failure)
	world.inventory_endpoint.state_changed.connect(_inventory)
	world.inventory_endpoint.operation_finished.connect(_operation_finished)
	world.currency_endpoint.state_changed.connect(_wallet)
	world.inventory_endpoint.enable_web_ui(true)
	_inventory(world.inventory_endpoint.state)
	_wallet(world.currency_endpoint.state)
	ClientState.settings.setting_changed.connect(_setting_changed)
	_layout()
	# Warm the browser/page on world entry. DOM stays hidden until inventory_open.
	# UI_READY receives the current snapshot, including updates during startup.
	host.open()

func _inventory(snapshot: Dictionary) -> void:
	if not snapshot.get("ok", false): return
	var bag: Array = []
	var equipped: Array = []
	for item: Dictionary in snapshot.items:
		var comparison: Dictionary = world.inventory_endpoint.weapon_comparison(item)
		var display := {"id": str(item.uid), "revision": int(item.revision), "name": "%s +%d" % [item.item_name, item.upgrade_level], "icon": "iron_sword", "height": int(item.inventory_height), "quantity": int(item.amount), "description": "Attack %d. After equipping: %d (%+d)." % [int(item.stats.get("attack", 0)), comparison.attack, comparison.delta]}
		if item.location == "equipment":
			display["slot"] = str(item.equipment_slot)
			equipped.append(display)
		elif item.location == "bag":
			var position: int = int(item.bag_position)
			display.merge({"x":position % InventoryGrid.COLUMNS, "y":(position % InventoryGrid.PAGE_CELLS) / InventoryGrid.COLUMNS, "page":position / InventoryGrid.PAGE_CELLS})
			bag.append(display)
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

func _equip(payload: Dictionary) -> Dictionary:
	return await _submit(payload, "equip")

func _unequip(payload: Dictionary) -> Dictionary:
	return await _submit(payload, "unequip")

func _move(payload: Dictionary) -> Dictionary:
	return await _submit(payload)

func _submit(payload: Dictionary, action: String = "move") -> Dictionary:
	if _active_command != "": return {"ok": false, "error": "pending"}
	_sequence += 1
	_active_command = "web-%d" % _sequence
	_result = {}
	if action == "move":
		world.inventory_endpoint.request_move_item.rpc_id(1, payload.id, int(payload.revision), int(payload.x), int(payload.y), int(payload.page), _active_command)
	else:
		world.inventory_endpoint.request_equipment.rpc_id(1, action, payload.id, int(payload.revision), _active_command)
	var deadline: int = Time.get_ticks_msec() + 2500
	while _result.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.025).timeout
	var result: Dictionary = _result.duplicate()
	_active_command = ""
	return result if not result.is_empty() else {"ok": false, "error": "timeout"}

func _operation_finished(id: String, result: Dictionary) -> void:
	if id == _active_command: _result = result

func _close(_payload: Dictionary) -> Dictionary:
	opened = false
	_layout()
	host.set_modal(false)
	return {"ok": true}

func _close_equipment(_payload: Dictionary) -> Dictionary:
	equipment_opened = false
	_layout()
	return {"ok":true}

func set_open(active: bool) -> void:
	opened = active
	equipment_opened = active
	_layout()
	host.set_modal(false) # Browser stays alive; opening only changes DOM visibility.

func _unhandled_key_input(event: InputEvent) -> void:
	if ClientState.menu_open or not world.input_enabled: return
	if not event is InputEventKey or not event.pressed or event.echo: return
	if event.physical_keycode == KEY_I:
		set_open(not (opened or equipment_opened))
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_ESCAPE and (opened or equipment_opened):
		# Presentation shortcut only: web cancels carry first, otherwise requests close.
		bridge.send("ui.shortcut", {"key": "Escape"})
		get_viewport().set_input_as_handled()

func _failure(reason: String) -> void:
	push_warning("Web inventory unavailable; native inventory retained: " + reason)
	opened = false
	ClientState.menu_open = false
	host.destroy_browser()
	world.inventory_endpoint.enable_web_ui(false)
	set_process_unhandled_key_input(false)

func _exit_tree() -> void:
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
	dispatcher.set_domain("hud", {"inventory_open": opened, "equipment_open":equipment_opened, "ui_scale": ui_scale, "viewport": {"width": host.size.x, "height": host.size.y}})
