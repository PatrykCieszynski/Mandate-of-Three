class_name CoreUiController
extends Node
## Client composition only. UID/revision intentions go through authenticated RPCs.
var host: WebUiHost
var bridge: WebUiBridge
var dispatcher: UiCommandDispatcher
var world: GameWorld3D
var opened: bool = false
var equipment_opened: bool = false
var storage_opened: bool = false
var session := UiCommandSession.new()
var items := ItemUiAdapter.new()
const StorageAdapter = preload("res://source/client/ui_web/storage_ui_adapter.gd")
var storage = StorageAdapter.new()
var chat = preload("res://source/client/ui_web/chat_ui_adapter.gd").new()
var hotbar = preload("res://source/client/ui_web/hotbar_ui_adapter.gd").new()
var stats = preload("res://source/client/ui_web/stats_ui_adapter.gd").new()
var party = preload("res://source/client/ui_web/party_ui_adapter.gd").new()
var npcs := NpcUiAdapter.new()
var upgrades := UpgradeUiAdapter.new()
var shop := ShopUiAdapter.new()
var vendor = preload("res://source/client/ui_web/vendor_ui_adapter.gd").new()
var exchange := ExchangeUiAdapter.new()
var market_browser := MarketBrowserUiAdapter.new()
var market := MarketUiAdapter.new()
const UI_SCALES: Array[float] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.4, 1.5]
var ui_scale: float = 1.0
var _scale_initialized: bool = false
var _npc_target_elapsed: float = 0.0
var _npc_targets_state: Dictionary = {}
var _tooltip_alt: bool = false
var _tooltip_focused: bool = true
var _stopped: bool = false
var _flow_revision: int = 0
var _flow_error: String = ""

func setup(game_world: GameWorld3D) -> void:
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
	host.navigation_started.connect(_navigation_started)
	Client.connection_changed.connect(_connection_changed)
	bridge.ui_ready.connect(_ui_ready)
	bridge.outgoing.connect(host.send)
	bridge.interactive_regions_received.connect(host.update_interactive_regions)
	bridge.text_focus_received.connect(_text_focus)
	dispatcher.attach(bridge)
	chat.attach(world.chat_endpoint,dispatcher,session,get_tree())
	party.attach(world.party_endpoint,dispatcher,session,get_tree())
	stats.attach(dispatcher)
	world.inventory_endpoint.state_changed.connect(stats.accept_context)
	stats.accept_context(world.inventory_endpoint.state)
	world.combat_endpoint.state_changed.connect(stats.accept_vitals)
	npcs.context_updated.connect(_npc_state)
	npcs.attach(world.npc_endpoint, dispatcher, session, get_tree())
	upgrades.attach(world.upgrade_endpoint, dispatcher, session, get_tree())
	world.inventory_endpoint.state_changed.connect(upgrades.accept_context)
	upgrades.accept_context(world.inventory_endpoint.state)
	shop.state_updated.connect(_shop_state)
	shop.attach(world.shop_endpoint, dispatcher, session, get_tree())
	world.inventory_endpoint.state_changed.connect(shop.accept_context)
	shop.accept_context(world.inventory_endpoint.state)
	vendor.shown.connect(func()->void:opened=true;_layout())
	vendor.attach(world.shop_endpoint,dispatcher,session,get_tree())
	world.inventory_endpoint.state_changed.connect(vendor.accept_inventory)
	vendor.accept_inventory(world.inventory_endpoint.state)
	world.market_endpoint.operation_finished.connect(session.finish)
	world.market_endpoint.query_finished.connect(session.finish)
	market.attach(world.market_endpoint,dispatcher,session,get_tree())
	world.inventory_endpoint.state_changed.connect(market.accept_context)
	market.accept_context(world.inventory_endpoint.state)
	market_browser.attach(world.market_endpoint,dispatcher,session,get_tree())
	market.purchase_recovery.connect(market_browser.accept_purchase_recovery)
	exchange.attach(world.market_endpoint,dispatcher,session,get_tree())
	world.inventory_endpoint.state_changed.connect(exchange.accept_context)
	exchange.accept_context(world.inventory_endpoint.state)
	exchange.state_updated.connect(func(_snapshot: Dictionary)->void:
		opened=true;_layout())
	market.state_updated.connect(func(_snapshot: Dictionary) -> void:
		opened = true
		_layout())
	items.recovery_needed.connect(func() -> void:
		opened = true
		_layout())
	items.attach(world.inventory_endpoint, dispatcher, session, get_tree())
	hotbar.attach(dispatcher,items._activate)
	world.inventory_endpoint.state_changed.connect(hotbar.accept_inventory)
	hotbar.accept_inventory(world.inventory_endpoint.state)
	world.combat_endpoint.state_changed.connect(_hotbar_combat)
	_hotbar_combat(world.combat_endpoint.state)
	dispatcher.register_command("hud.action",func(p: Dictionary)->bool:return p.size()==1 and p.get("action") in ["inventory","stats","options"],_hud_action)
	storage.recovery_needed.connect(func() -> void:
		opened = true
		storage_opened = true
		_layout())
	storage.attach(world.inventory_endpoint,dispatcher,session,get_tree(),func() -> bool: return storage_opened)
	dispatcher.register_command("npc.upgrade_item", UpgradeUiAdapter.valid_item, _drop_on_npc)
	dispatcher.set_domain("npc_targets",{"width":0,"height":0,"targets":[]})
	dispatcher.register_command("storage.close", func(p: Dictionary) -> bool: return p.is_empty(), _close_storage)
	dispatcher.register_command("equipment.close", func(p: Dictionary) -> bool: return p.is_empty(), _close_equipment)
	dispatcher.register_command("inventory.close", func(p: Dictionary) -> bool: return p.is_empty(), _close)
	host.keyboard_owner_changed.connect(_keyboard_owner)
	host.resized.connect(_layout)
	host.failure.connect(_failure)
	world.currency_endpoint.state_changed.connect(_wallet)
	_wallet(world.currency_endpoint.state)
	ClientState.settings.setting_changed.connect(_setting_changed)
	_layout()
	# Warm the browser/page on world entry. DOM stays hidden until inventory_open.
	# UI_READY receives the current snapshot, including updates during startup.
	host.open()

func _hotbar_combat(snapshot: Dictionary) -> void:
	hotbar.accept_combat(snapshot,world.local_peer)

func _hud_action(p: Dictionary) -> Dictionary:
	match p.action:
		"inventory": set_open(not (opened or equipment_opened))
		"stats": stats.toggle()
		"options": world.show_options()
	return {"ok":true}

func _drop_on_npc(p: Dictionary) -> Dictionary:
	if not world.begin_npc_approach(p.npc_instance_id,{"id":p.id,"revision":int(p.revision),"service_id":p.service_id}): return {"ok":false,"error":"unavailable"}
	return {"ok":true}

func _shop_state(snapshot: Dictionary) -> void:
	if snapshot.get("active", false):
		opened = true
		_layout()

func _npc_state(snapshot: Dictionary) -> void:
	# Opening Inventory changes presentation only; Upgrade owns its transaction.
	if snapshot.get("active", false):
		for service: Dictionary in snapshot.get("services", []):
			if service.id == snapshot.get("selectedServiceId", "") and service.kind == NpcServiceDefinition.Kind.UPGRADE and service.enabled:
				opened = true
				_layout()
				break

func interact_npc(instance_id: String, preselected_item: Dictionary = {}) -> Dictionary:
	if _stopped: return session.closed_result()
	var revision: int = _flow_revision
	var result: Dictionary = await npcs.interact(instance_id)
	if not result.ok or preselected_item.is_empty(): return result
	if revision != _flow_revision: return {"ok":false,"error":_flow_error}
	# Same service and selection commands as the manual menu/Upgrade slot.
	for service: Dictionary in npcs.state().get("services",[]):
		if service.id == preselected_item.get("service_id","") and service.kind == NpcServiceDefinition.Kind.UPGRADE and service.enabled:
			result = await npcs.select_service(instance_id,service.id)
			if not result.ok: return result
			if revision != _flow_revision: return {"ok":false,"error":_flow_error}
			return await upgrades.select_item({"npc_instance_id":instance_id,"service_id":service.id,"id":preselected_item.id,"revision":preselected_item.revision})
	return {"ok":false,"error":"unknown_service"}

func _wallet(snapshot: Dictionary) -> void:
	exchange.accept_wallet(snapshot)
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
	if _stopped: return
	opened = active
	if not active: storage_opened = false
	equipment_opened = active
	_layout()
	host.set_modal(false) # Browser stays alive; opening only changes DOM visibility.

# Pointer-only CEF keeps gameplay keyboard ownership. Send modifier changes as
# presentation input, never server RPCs or a request for keyboard focus.
func _process(_delta: float) -> void:
	stats.tick(_delta)
	vendor.tick(_delta)
	_npc_target_elapsed += _delta
	if _npc_target_elapsed >= 0.1 and is_instance_valid(world) and is_instance_valid(dispatcher):
		_npc_target_elapsed = 0.0
		var snapshot: Dictionary = NpcDropTargetProjector.project(world.gameplay_camera(), world.get_viewport().get_visible_rect().size, world.npc_endpoint.actors.values())
		if snapshot != _npc_targets_state:
			_npc_targets_state = snapshot
			dispatcher.set_domain("npc_targets",snapshot)
	_set_tooltip_alt(_tooltip_focused and Input.is_key_pressed(KEY_ALT))

func _set_tooltip_alt(pressed: bool) -> void:
	if _stopped: return
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
	var shortcut: int=-1
	if event.physical_keycode>=KEY_1 and event.physical_keycode<=KEY_8: shortcut=event.physical_keycode-KEY_1
	elif event.physical_keycode>=KEY_F1 and event.physical_keycode<=KEY_F8: shortcut=8+event.physical_keycode-KEY_F1
	if shortcut>=0 and not event.ctrl_pressed and not event.alt_pressed and not event.meta_pressed:
		hotbar.activate_slot(shortcut)
		get_viewport().set_input_as_handled()
		return
	if event.keycode in [KEY_ENTER,KEY_KP_ENTER]:
		if _stopped or not bridge.is_ready: return
		host.set_keyboard_owner("web")
		chat.focus()
		get_viewport().set_input_as_handled()
	elif event.physical_keycode == KEY_V:
		stats.toggle()
		get_viewport().set_input_as_handled()
	elif event.physical_keycode == KEY_P:
		party.toggle()
		get_viewport().set_input_as_handled()
	elif event.physical_keycode == KEY_I:
		set_open(not (opened or equipment_opened))
		get_viewport().set_input_as_handled()
	elif event.physical_keycode == KEY_B:
		storage_opened = not storage_opened
		if storage_opened: opened = true
		_layout()
		get_viewport().set_input_as_handled()
	elif event.physical_keycode == KEY_X:
		if exchange.active: exchange.close()
		else: exchange.open()
		get_viewport().set_input_as_handled()
	elif event.physical_keycode == KEY_T:
		if market_browser.active: market_browser.close()
		else: market_browser.open()
		get_viewport().set_input_as_handled()
	elif event.physical_keycode == KEY_M:
		if market.active: market.close()
		else: market.open()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_ESCAPE and (vendor.is_open() or stats.opened or exchange.active or market_browser.active or market.active or opened or equipment_opened or storage_opened or npcs.state().get("active", false)):
		# Presentation shortcut only: web cancels carry first, otherwise requests close.
		bridge.send("ui.shortcut", {"key": "Escape"})
		get_viewport().set_input_as_handled()

func _navigation_started() -> void:
	_cancel_flows("ui_reload")
	host.set_keyboard_owner("gameplay")

func _text_focus(active: bool) -> void:
	host.set_keyboard_owner("web" if active else "gameplay")

func _connection_changed(connected: bool) -> void:
	if not connected: _cancel_flows("disconnected")

func _cancel_flows(reason: String) -> void:
	_flow_revision += 1
	_flow_error = reason
	session.cancel(reason)

func _ui_ready() -> void:
	bridge.send("ui.tooltip_details", {"alt":_tooltip_alt})

func _keyboard_owner(owner: String) -> void:
	ClientState.menu_open = owner != "gameplay"

func _failure(reason: String) -> void:
	_stop("ui_unavailable")
	if is_instance_valid(world): world.show_ui_failure(reason)

func _exit_tree() -> void:
	_stop("teardown")

func _stop(reason: String) -> void:
	if _stopped: return
	_stopped = true
	_cancel_flows(reason)
	session.close(reason)
	if is_instance_valid(dispatcher): dispatcher.dispose()
	items.dispose()
	storage.dispose()
	chat.dispose()
	party.dispose()
	stats.dispose()
	hotbar.dispose()
	if is_instance_valid(world):
		if is_instance_valid(world.inventory_endpoint) and world.inventory_endpoint.state_changed.is_connected(hotbar.accept_inventory): world.inventory_endpoint.state_changed.disconnect(hotbar.accept_inventory)
		if is_instance_valid(world.combat_endpoint) and world.combat_endpoint.state_changed.is_connected(_hotbar_combat): world.combat_endpoint.state_changed.disconnect(_hotbar_combat)
		if is_instance_valid(world.inventory_endpoint) and world.inventory_endpoint.state_changed.is_connected(stats.accept_context): world.inventory_endpoint.state_changed.disconnect(stats.accept_context)
		if is_instance_valid(world.combat_endpoint) and world.combat_endpoint.state_changed.is_connected(stats.accept_vitals): world.combat_endpoint.state_changed.disconnect(stats.accept_vitals)
	npcs.dispose()
	upgrades.dispose()
	shop.dispose()
	vendor.dispose()
	if is_instance_valid(world) and is_instance_valid(world.inventory_endpoint) and world.inventory_endpoint.state_changed.is_connected(vendor.accept_inventory): world.inventory_endpoint.state_changed.disconnect(vendor.accept_inventory)
	market.dispose()
	market_browser.dispose()
	exchange.dispose()
	if Client.connection_changed.is_connected(_connection_changed): Client.connection_changed.disconnect(_connection_changed)
	if ClientState.settings.setting_changed.is_connected(_setting_changed): ClientState.settings.setting_changed.disconnect(_setting_changed)
	if is_instance_valid(world):
		if is_instance_valid(world.inventory_endpoint) and world.inventory_endpoint.state_changed.is_connected(exchange.accept_context): world.inventory_endpoint.state_changed.disconnect(exchange.accept_context)
		if is_instance_valid(world.inventory_endpoint) and world.inventory_endpoint.state_changed.is_connected(market.accept_context): world.inventory_endpoint.state_changed.disconnect(market.accept_context)
		if is_instance_valid(world.market_endpoint):
			if world.market_endpoint.operation_finished.is_connected(session.finish): world.market_endpoint.operation_finished.disconnect(session.finish)
			if world.market_endpoint.query_finished.is_connected(session.finish): world.market_endpoint.query_finished.disconnect(session.finish)
		if is_instance_valid(world.currency_endpoint) and world.currency_endpoint.state_changed.is_connected(_wallet): world.currency_endpoint.state_changed.disconnect(_wallet)
		if is_instance_valid(world.camera_controller) and is_instance_valid(host) and world.camera_controller.pointer_capture_changed.is_connected(host.set_world_pointer_capture):
			world.camera_controller.pointer_capture_changed.disconnect(host.set_world_pointer_capture)
	if is_instance_valid(host) and is_instance_valid(bridge):
		if host.message_received.is_connected(bridge.receive): host.message_received.disconnect(bridge.receive)
		if host.navigation_started.is_connected(bridge.reset_transport): host.navigation_started.disconnect(bridge.reset_transport)
		if host.navigation_started.is_connected(_navigation_started): host.navigation_started.disconnect(_navigation_started)
		if bridge.ui_ready.is_connected(_ui_ready): bridge.ui_ready.disconnect(_ui_ready)
		if bridge.outgoing.is_connected(host.send): bridge.outgoing.disconnect(host.send)
		if bridge.interactive_regions_received.is_connected(host.update_interactive_regions): bridge.interactive_regions_received.disconnect(host.update_interactive_regions)
		if bridge.text_focus_received.is_connected(_text_focus): bridge.text_focus_received.disconnect(_text_focus)
	opened = false
	equipment_opened = false
	storage_opened = false
	ClientState.menu_open = false
	set_process(false)
	set_process_unhandled_key_input(false)
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
	if _stopped: return
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
