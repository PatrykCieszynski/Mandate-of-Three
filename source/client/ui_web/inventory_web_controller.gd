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
var session := UiCommandSession.new()
var items := ItemUiAdapter.new()
const UI_SCALES: Array[float] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.4, 1.5]
var ui_scale: float = 1.0
var _scale_initialized: bool = false
var _npc_target_elapsed: float = 0.0
var _npc_targets_state: Dictionary = {}
var _tooltip_alt: bool = false
var _tooltip_focused: bool = true

func setup(game_world: SpikeWorld3D) -> void:
	world = game_world
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	if host == null: host = WebUiHost.new()
	host.capture_keyboard_on_click = false
	host.entry_path = "res://source/client/ui_web/web/inventory/game.html"
	layer.add_child(host)
	world.camera_controller.pointer_capture_changed.connect(host.set_world_pointer_capture)
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bridge = WebUiBridge.new()
	add_child(bridge)
	dispatcher = UiCommandDispatcher.new()
	add_child(dispatcher)
	host.message_received.connect(bridge.receive)
	host.navigation_started.connect(bridge.reset_transport)
	host.navigation_started.connect(func() -> void: session.cancel("ui_reload"))
	Client.connection_changed.connect(func(connected: bool) -> void:
		if not connected: session.cancel("disconnected"))
	bridge.ui_ready.connect(func() -> void: bridge.send("ui.tooltip_details", {"alt": _tooltip_alt}))
	bridge.outgoing.connect(host.send)
	bridge.interactive_regions_received.connect(host.update_interactive_regions)
	dispatcher.attach(bridge)
	items.attach(world.inventory_endpoint, dispatcher, session, get_tree(), func() -> bool: return storage_opened)
	dispatcher.register_command("npc.interact", _valid_npc, func(p: Dictionary) -> Dictionary: return await interact_npc(p.npc_instance_id))
	dispatcher.register_command("npc.select_service", _valid_npc_service, func(p: Dictionary) -> Dictionary: return await _npc_submit("select", p.npc_instance_id, p.service_id))
	dispatcher.register_command("npc.close", func(p: Dictionary) -> bool: return p.is_empty(), func(_p: Dictionary) -> Dictionary: return await _npc_submit("close"))
	dispatcher.register_command("npc.clear_service", func(p: Dictionary) -> bool: return p.is_empty(), func(_p: Dictionary) -> Dictionary: return await _npc_submit("clear_service"))
	dispatcher.register_command("shop.open", _valid_npc_service, func(p: Dictionary) -> Dictionary: return await _shop_submit("open", p))
	dispatcher.register_command("shop.buy", _valid_shop_buy, func(p: Dictionary) -> Dictionary: return await _shop_submit("buy", p))
	dispatcher.register_command("upgrade.select", _valid_upgrade, func(p: Dictionary) -> Dictionary: return await _upgrade_submit("select", p))
	dispatcher.register_command("upgrade.execute", _valid_upgrade, func(p: Dictionary) -> Dictionary: return await _upgrade_submit("upgrade", p))
	dispatcher.register_command("npc.upgrade_item", _valid_upgrade_drop, _drop_on_npc)
	world.upgrade_endpoint.state_changed.connect(func(snapshot: Dictionary) -> void: dispatcher.set_domain("upgrade",snapshot))
	world.upgrade_endpoint.operation_finished.connect(session.finish)
	dispatcher.set_domain("upgrade",world.upgrade_endpoint.state)
	dispatcher.set_domain("npc_targets",{"width":0,"height":0,"targets":[]})
	world.shop_endpoint.state_changed.connect(_shop_state)
	world.shop_endpoint.operation_finished.connect(session.finish)
	dispatcher.set_domain("shop", world.shop_endpoint.state)
	world.npc_endpoint.state_changed.connect(_npc_state)
	world.npc_endpoint.operation_finished.connect(session.finish)
	_npc_state(world.npc_endpoint.state)
	dispatcher.register_command("storage.close", func(p: Dictionary) -> bool: return p.is_empty(), _close_storage)
	dispatcher.register_command("equipment.close", func(p: Dictionary) -> bool: return p.is_empty(), _close_equipment)
	dispatcher.register_command("inventory.close", func(p: Dictionary) -> bool: return p.is_empty(), _close)
	host.keyboard_owner_changed.connect(func(owner: String) -> void: ClientState.menu_open = owner != "gameplay")
	host.resized.connect(_layout)
	host.failure.connect(_failure)
	world.currency_endpoint.state_changed.connect(_wallet)
	_wallet(world.currency_endpoint.state)
	ClientState.settings.setting_changed.connect(_setting_changed)
	_layout()
	# Warm the browser/page on world entry. DOM stays hidden until inventory_open.
	# UI_READY receives the current snapshot, including updates during startup.
	host.open()

static func _valid_upgrade(p: Dictionary) -> bool:
	return p.size() == 4 and ItemUiAdapter.valid_item_identity(p) and _valid_npc_service({"npc_instance_id":p.get("npc_instance_id"),"service_id":p.get("service_id")})

static func _valid_upgrade_drop(p: Dictionary) -> bool:
	return _valid_upgrade(p)

func _upgrade_submit(action: String, p: Dictionary) -> Dictionary:
	var id: String = session.begin()
	if id.is_empty(): return session.closed_result()
	world.upgrade_endpoint.request_upgrade.rpc_id(1,action,p.npc_instance_id,p.service_id,p.id,int(p.revision),id)
	return await session.wait(id, get_tree())

func _drop_on_npc(p: Dictionary) -> Dictionary:
	if not world.begin_npc_approach(p.npc_instance_id,{"id":p.id,"revision":int(p.revision),"service_id":p.service_id}): return {"ok":false,"error":"unavailable"}
	return {"ok":true}

func _shop_state(snapshot: Dictionary) -> void:
	if snapshot.get("active", false):
		opened = true
		_layout()
	dispatcher.set_domain("shop", snapshot)

static func _valid_shop_buy(p: Dictionary) -> bool:
	if p.size() not in [3, 6] or not p.has_all(["npc_instance_id", "service_id", "offer_id"]): return false
	if not _valid_npc_service({"npc_instance_id":p.npc_instance_id, "service_id":p.service_id}) or not p.offer_id is String or not GameplayContentId.valid(StringName(p.offer_id)): return false
	if p.size() == 3: return true
	return p.has_all(["x", "y", "page"]) and WebUiBridge.is_integer(p.x) and WebUiBridge.is_integer(p.y) and WebUiBridge.is_integer(p.page) and p.x >= 0 and p.x < InventoryGrid.COLUMNS and p.y >= 0 and p.y < InventoryGrid.ROWS and p.page >= 0 and p.page < InventoryGrid.PAGES

func _shop_submit(action: String, p: Dictionary) -> Dictionary:
	var id: String = session.begin()
	if id.is_empty(): return session.closed_result()
	var position: int = int(p.page) * InventoryGrid.PAGE_CELLS + int(p.y) * InventoryGrid.COLUMNS + int(p.x) if p.has("x") else -1
	world.shop_endpoint.request_shop.rpc_id(1, action, p.npc_instance_id, p.service_id, p.get("offer_id", ""), position, id)
	return await session.wait(id, get_tree())

func _npc_state(snapshot: Dictionary) -> void:
	# Opening Inventory changes presentation only; Upgrade owns its transaction.
	if snapshot.get("active", false):
		for service: Dictionary in snapshot.get("services", []):
			if service.id == snapshot.get("selectedServiceId", "") and service.kind == NpcServiceDefinition.Kind.UPGRADE and service.enabled:
				opened = true
				_layout()
				break
	dispatcher.set_domain("npc", snapshot)

static func _valid_npc(p: Dictionary) -> bool:
	return p.size() == 1 and p.get("npc_instance_id") is String and NeutralNpc3D.valid_instance_id(p.npc_instance_id)

static func _valid_npc_service(p: Dictionary) -> bool:
	return p.size() == 2 and p.get("npc_instance_id") is String and NeutralNpc3D.valid_instance_id(p.npc_instance_id) and p.get("service_id") is String and GameplayContentId.valid(StringName(p.service_id))

func interact_npc(instance_id: String, preselected_item: Dictionary = {}) -> Dictionary:
	var generation: int = bridge.generation() if is_instance_valid(bridge) else -1
	var result: Dictionary = await _npc_submit("interact",instance_id)
	if not result.ok or preselected_item.is_empty(): return result
	if is_instance_valid(bridge) and bridge.generation() != generation: return {"ok":false,"error":"ui_reload"}
	# Same service and selection commands as the manual menu/Upgrade slot.
	for service: Dictionary in world.npc_endpoint.state.get("services",[]):
		if service.id == preselected_item.get("service_id","") and service.kind == NpcServiceDefinition.Kind.UPGRADE and service.enabled:
			result = await _npc_submit("select",instance_id,service.id)
			if not result.ok: return result
			if is_instance_valid(bridge) and bridge.generation() != generation: return {"ok":false,"error":"ui_reload"}
			return await _upgrade_submit("select",{"npc_instance_id":instance_id,"service_id":service.id,"id":preselected_item.id,"revision":preselected_item.revision})
	return {"ok":false,"error":"unknown_service"}

func _npc_submit(action: String, instance_id: String = "", service_id: String = "") -> Dictionary:
	var id: String = session.begin()
	if id.is_empty(): return session.closed_result()
	world.npc_endpoint.request_interaction.rpc_id(1, action, instance_id, service_id, id)
	return await session.wait(id, get_tree())




func _wallet(snapshot: Dictionary) -> void:
	dispatcher.set_domain("wallet", {"balance": int(snapshot.get("balance", 0)), "ready": snapshot.has("balance")})



static func _valid_scale(payload: Dictionary) -> bool:
	return payload.size() == 1 and WebUiBridge.is_integer(payload.get("percent")) and float(payload.percent) / 100.0 in UI_SCALES





func _close_storage(_payload: Dictionary) -> Dictionary:
	storage_opened = false
	_layout()
	return {"ok":true}






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

# Pointer-only CEF keeps gameplay keyboard ownership. Send modifier changes as
# presentation input, never server RPCs or a request for keyboard focus.
func _process(_delta: float) -> void:
	_npc_target_elapsed += _delta
	if _npc_target_elapsed >= 0.1 and is_instance_valid(world) and is_instance_valid(dispatcher):
		_npc_target_elapsed = 0.0
		var snapshot: Dictionary = NpcDropTargetProjector.project(world.gameplay_camera(), world.get_viewport().get_visible_rect().size, world.npc_endpoint.actors.values())
		if snapshot != _npc_targets_state:
			_npc_targets_state = snapshot
			dispatcher.set_domain("npc_targets",snapshot)
	_set_tooltip_alt(_tooltip_focused and Input.is_key_pressed(KEY_ALT))


func _set_tooltip_alt(pressed: bool) -> void:
	if pressed == _tooltip_alt: return
	_tooltip_alt = pressed
	if is_instance_valid(bridge): bridge.send("ui.tooltip_details", {"alt": pressed})

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_tooltip_focused = false
		_set_tooltip_alt(false)
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_tooltip_focused = true

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
	session.close("ui_unavailable")
	host.destroy_browser()
	equipment_opened = false
	storage_opened = false
	world.show_ui_failure(reason)
	set_process_unhandled_key_input(false)

func _exit_tree() -> void:
	session.close("teardown")
	items.dispose()
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
