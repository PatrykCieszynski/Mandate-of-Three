class_name InventoryWebController
extends Node
## Client composition only. UID/revision intentions go through authenticated RPCs.
var host: WebUiHost
var bridge: WebUiBridge
var dispatcher: UiCommandDispatcher
var world: SpikeWorld3D
var opened: bool = false
var _sequence: int = 0
var _active_command: String = ""
var _result: Dictionary = {}

func setup(game_world: SpikeWorld3D) -> void:
	world = game_world
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	host = WebUiHost.new()
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
	dispatcher.register_command("inventory.equipment", _valid_equipment, _equipment)
	dispatcher.register_command("inventory.close", func(p: Dictionary) -> bool: return p.is_empty(), _close)
	bridge.ui_ready.connect(func() -> void: host.set_modal(opened))
	host.failure.connect(_failure)
	world.inventory_endpoint.state_changed.connect(_inventory)
	world.inventory_endpoint.operation_finished.connect(_operation_finished)
	world.currency_endpoint.state_changed.connect(_wallet)
	world.combat_endpoint.state_changed.connect(func(_s: Dictionary) -> void: _player())
	world.inventory_endpoint.enable_web_ui(true)
	_inventory(world.inventory_endpoint.state)
	_wallet(world.currency_endpoint.state)
	_player()
	dispatcher.set_domain("hud", {"inventory_open": false})

func _inventory(snapshot: Dictionary) -> void:
	if not snapshot.get("ok", false): return
	var bag: Array = []
	var slots: Array = [{"slot": "weapon", "label": "Weapon"}]
	for item: Dictionary in snapshot.items:
		var display: Dictionary = {"id": str(item.uid), "revision": int(item.revision), "name": "%s +%d" % [item.item_name, item.upgrade_level], "icon": "blade", "height": 1, "quantity": int(item.amount), "attack": str(int(item.stats.get("attack", 0))), "category": "WEAPON", "description": "Weapon attack %d" % int(item.stats.get("attack", 0))}
		if item.location == "bag":
			display["x"] = int(item.bag_position) % 6
			display["y"] = int(item.bag_position) / 6
			var comparison: Dictionary = world.inventory_endpoint.weapon_comparison(item)
			display["description"] = "After equipping: %d character attack (%+d)." % [comparison.attack, comparison.delta]
			bag.append(display)
		elif item.equipment_slot == "weapon":
			display["slot"] = "weapon"
			display["label"] = display.name
			slots[0] = display
	dispatcher.set_domain("inventory", {"columns": 6, "rows": 4, "revision": 0, "items": bag})
	dispatcher.set_domain("equipment", {"slots": slots, "attack": int(snapshot.stats.get("attack", 10))})

func _wallet(snapshot: Dictionary) -> void:
	dispatcher.set_domain("wallet", {"balance": int(snapshot.get("balance", 0)), "ready": snapshot.has("balance")})

func _player() -> void:
	var body: SpikeCharacter3D = world.characters.get(world.local_peer)
	var name_text: String = body.get_display_name() if body != null else "Character"
	var progression: Dictionary = world.combat_endpoint.state.get("progression", {})
	dispatcher.set_domain("player", {"name": name_text, "level": int(progression.get("level", 1))})

static func _valid_identity(payload: Dictionary) -> bool:
	return payload.get("id") is String and ItemStoreSqlite.valid_uid(payload.id) and WebUiBridge.is_integer(payload.get("revision")) and payload.revision >= 0

static func _valid_move(p: Dictionary) -> bool:
	return p.size() == 4 and p.has_all(["id", "revision", "x", "y"]) and _valid_identity(p) and WebUiBridge.is_integer(p.x) and WebUiBridge.is_integer(p.y) and p.x >= 0 and p.x < 6 and p.y >= 0 and p.y < 4

static func _valid_equipment(p: Dictionary) -> bool:
	return p.size() == 3 and p.has_all(["id", "revision", "action"]) and _valid_identity(p) and p.action in ["equip", "unequip"]

func _move(payload: Dictionary) -> Dictionary:
	return await _submit(payload, "move")

func _equipment(payload: Dictionary) -> Dictionary:
	return await _submit(payload, str(payload.action))

func _submit(payload: Dictionary, action: String) -> Dictionary:
	if _active_command != "": return {"ok": false, "error": "pending"}
	_sequence += 1
	_active_command = "web-%d" % _sequence
	_result = {}
	if action == "move":
		world.inventory_endpoint.request_move_item.rpc_id(1, payload.id, int(payload.revision), int(payload.y) * 6 + int(payload.x), _active_command)
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
	set_open(false)
	return {"ok": true}

func set_open(active: bool) -> void:
	opened = active
	ClientState.menu_open = active
	dispatcher.set_domain("hud", {"inventory_open": active})
	if active:
		if not host.open():
			_failure("CEF could not open")
			return
		host.set_modal(true) # Click-carried items receive motion beyond the panels.
	else:
		host.hide_ui()

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_I:
		set_open(not opened)
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
