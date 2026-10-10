extends Node
## Small contract test: no browser, mock inventory, layout or gameplay fixture.
var messages: Array[Dictionary] = []
var handled: int = 0
func _ready() -> void:
	_run.call_deferred()
func _run() -> void:
	assert(not WebUiHost.supported_client(), "Headless must never compose a browser")
	if OS.has_feature("dedicated_server"):
		assert(not ClassDB.class_exists("CefTexture"), "Server export must exclude native CEF")
	var host := WebUiHost.new()
	assert(not host.open() and not is_instance_valid(host.browser), "Headless must not create a browser")
	# Native Control fixture: pointer capture must not imply gameplay keyboard lock.
	add_child(host)
	host.browser = Control.new()
	host.add_child(host.browser)
	host.browser.size = Vector2(300, 300)
	host.capture_keyboard_on_click = false
	host.update_interactive_regions({"width":300,"height":300,"regions":[{"id":"bag","x":0,"y":0,"w":200,"h":200}]})
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.position = Vector2(20, 20)
	click.pressed = true
	host._input(click)
	assert(host.keyboard_owner == "gameplay" and host.browser.focus_mode == Control.FOCUS_NONE)
	assert(host.browser.mouse_filter == Control.MOUSE_FILTER_STOP and host.owns_pointer(Vector2(250,250)))
	click.pressed = false
	host._input(click)
	assert(not host.owns_pointer(Vector2(250,250)))
	host.set_modal(true)
	assert(host.keyboard_owner == "modal")
	host.set_modal(false)
	remove_child(host)
	host.free()
	if OS.has_feature("client"):
		assert(not ClassDB.class_exists("SQLite"), "Exported client validation must work without SQLite")
	# Run the real client validator; this also runs in an exported client without SQLite.
	var item_uid := "0123456789abcdef0123456789abcdef"
	assert(InventoryWebController._valid_identity({"id":item_uid,"revision":0}))
	for invalid: Variant in ["", item_uid.left(31), item_uid.to_upper(), "g".repeat(32), 42]:
		assert(not InventoryWebController._valid_identity({"id":invalid,"revision":0}))
	assert(not InventoryWebController._valid_identity({"id":item_uid,"revision":-1}))
	assert(InventoryWebController._valid_equipment({"id":item_uid,"revision":2}))
	assert(not InventoryWebController._valid_equipment({"id":item_uid,"revision":2,"action":"quit"}))
	assert(not InventoryWebController._valid_equipment({"id":"bad","revision":2}))
	assert(InventoryWebController._valid_unequip({"id":item_uid,"revision":2}))
	var exact_unequip: Dictionary = {"id":item_uid,"revision":2,"x":2,"y":3,"page":1}
	assert(InventoryWebController._valid_unequip(exact_unequip))
	for coordinate: String in ["x","y","page"]:
		for bad: Variant in [NAN,INF,-1,1.5,1000000,"1"]:
			var malformed: Dictionary = exact_unequip.duplicate()
			malformed[coordinate] = bad
			assert(not InventoryWebController._valid_unequip(malformed))
		var partial: Dictionary = exact_unequip.duplicate()
		partial.erase(coordinate)
		assert(not InventoryWebController._valid_unequip(partial))
	for percent: int in [80,90,100,110,125,140,150]:
		assert(InventoryWebController._valid_scale({"percent":percent}))
	for invalid: Variant in [0,79,81,151,100.5,"125",null]:
		assert(not InventoryWebController._valid_scale({"percent":invalid}))
	assert(not InventoryWebController._valid_scale({"percent":100,"extra":true}))
	var storage_command: Dictionary = {"id":item_uid,"revision":0,"from":"inventory","to":"storage","x":14,"y":8,"page":1,"quick":false}
	assert(InventoryWebController._valid_storage(storage_command))
	for bad: Variant in [INF,NAN,-1,15,1.5]:
		var invalid: Dictionary = storage_command.duplicate()
		invalid.x=bad
		assert(not InventoryWebController._valid_storage(invalid))
	var inventory_route: Dictionary = storage_command.duplicate()
	inventory_route.merge({"from":"inventory","to":"inventory","x":0,"page":0},true)
	assert(not InventoryWebController._valid_storage(inventory_route),"Inventory has one authoritative move path")
	# Independent requests accept out-of-order replies and ignore expired IDs.
	var controller := InventoryWebController.new()
	add_child(controller)
	controller.host=WebUiHost.new()
	controller.add_child(controller.host)
	controller.opened=true
	controller.storage_opened=true
	controller._close({})
	assert(not controller.opened and not controller.storage_opened,"Close Inventory closes Storage")
	controller.opened=true
	controller.storage_opened=true
	controller.set_open(false)
	assert(not controller.opened and not controller.storage_opened,"Inventory shortcut closes both")
	controller.bridge = WebUiBridge.new()
	controller.add_child(controller.bridge)
	controller.dispatcher = UiCommandDispatcher.new()
	controller.add_child(controller.dispatcher)
	controller.dispatcher.attach(controller.bridge)
	controller.opened = false
	controller._shop_state({"active":true})
	assert(controller.opened, "Shop opening ensures Inventory is visible")
	controller._shop_state({"active":false})
	assert(controller.opened, "Shop closing leaves Inventory available in v1")
	var first := controller._begin_command()
	var second := controller._begin_command()
	controller._operation_finished(second, {"ok":true, "request":"second"})
	controller._operation_finished(first, {"ok":false, "error":"first"})
	assert((await controller._wait_command(first)).error == "first")
	assert((await controller._wait_command(second)).request == "second")
	var expired := controller._begin_command()
	assert((await controller._wait_command(expired, 0)).error == "timeout")
	controller._operation_finished(expired, {"ok":true})
	assert(controller._pending_commands.is_empty())
	var cancelled := controller._begin_command()
	controller._cancel_pending("disconnected")
	assert((await controller._wait_command(cancelled)).error == "disconnected")
	controller.free()
	assert(InventoryWebController._valid_npc({"npc_instance_id":"spike-blacksmith-01"}))
	assert(not InventoryWebController._valid_npc({"npc_instance_id":"../NPC"}))
	assert(InventoryWebController._valid_npc_service({"npc_instance_id":"spike-blacksmith-01", "service_id":"weapon_shop"}))
	assert(not InventoryWebController._valid_npc_service({"npc_instance_id":"spike-blacksmith-01", "service_id":"weapon_shop", "kind":1}))
	var buy: Dictionary = {"npc_instance_id":"spike-blacksmith-01","service_id":"weapon_shop","offer_id":"iron_sword"}
	assert(InventoryWebController._valid_shop_buy(buy))
	var exact_buy: Dictionary = buy.duplicate()
	exact_buy.merge({"x":2,"y":3,"page":1})
	assert(InventoryWebController._valid_shop_buy(exact_buy))
	for field: String in ["x","y","page"]:
		var partial: Dictionary = exact_buy.duplicate()
		partial.erase(field)
		assert(not InventoryWebController._valid_shop_buy(partial))
		for bad: Variant in [-1,1.5,NAN,INF,"1",1000]:
			var invalid: Dictionary = exact_buy.duplicate()
			invalid[field]=bad
			assert(not InventoryWebController._valid_shop_buy(invalid))
	for field: String in ["price","quantity","item_definition_id"]:
		var invalid: Dictionary = buy.duplicate()
		invalid[field]=1
		assert(not InventoryWebController._valid_shop_buy(invalid))
	var configured_url: Variant = ProjectSettings.get_setting("network/api/base_url")
	ProjectSettings.set_setting("network/api/base_url", "")
	assert(GatewayAPI.base_url() == "http://127.0.0.1:8088")
	ProjectSettings.set_setting("network/api/base_url", "http://127.0.0.1:18098/")
	assert(GatewayAPI.handshake() == "http://127.0.0.1:18098/v1/handshake")
	ProjectSettings.set_setting("network/api/base_url", configured_url)
	var bridge := WebUiBridge.new()
	var dispatcher := UiCommandDispatcher.new()
	dispatcher.attach(bridge)
	dispatcher.register_command("inventory.move_item", func(p: Dictionary) -> bool: return p.size() == 1 and p.get("id") is String, _command)
	dispatcher.set_domain("wallet", {"balance": 12})
	bridge.outgoing.connect(func(message: String) -> void: messages.append(JSON.parse_string(message)))
	var command: String = JSON.stringify({"v":1,"type":"inventory.move_item","id":"one","payload":{"id":"item"}})
	bridge.receive(command)
	assert(handled == 0 and messages.is_empty(), "No commands before ready")
	# Native event batches may emit IPC before load_started. Ready must follow reset.
	var adapter := WebUiHost.new()
	var native := Control.new()
	native.add_user_signal("ipc_message", [{"name":"message","type":TYPE_STRING}])
	native.connect("ipc_message", adapter._on_ipc_message, CONNECT_DEFERRED)
	adapter.message_received.connect(bridge.receive)
	adapter.navigation_started.connect(bridge.reset_transport)
	native.emit_signal("ipc_message", '{"v":1,"type":"ui.ready","payload":{}}')
	adapter._on_load_started(adapter.entry_path)
	assert(not bridge.is_ready)
	await get_tree().process_frame
	assert(bridge.is_ready and messages.back().type == "ui.snapshot", "Startup ready survives native load notification")
	assert(messages.back().payload.wallet.balance == 12)
	native.free()
	adapter.free()
	bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
	assert(messages.back().type == "ui.snapshot" and messages.back().payload.wallet.balance == 12)
	bridge.receive('{"v":1,"type":"get_tree().quit","id":"bad","payload":{}}')
	bridge.receive('{"v":1,"type":"inventory.move_item","id":"shape","payload":{}}')
	assert(handled == 0 and not messages.back().payload.ok, "Whitelist and payload boundary")
	bridge.receive(command)
	assert(handled == 1 and messages.back().type == "command.result" and messages.back().id == "one" and messages.back().payload == {"ok":true})
	bridge.reset_transport()
	dispatcher.set_domain("wallet", {"balance": 30})
	var shop_snapshot: Dictionary = {"active":true,"npcInstanceId":"spike-blacksmith-01","serviceId":"weapon_shop","shopId":"blacksmith_weapon_shop","name":"Weapons","currency":"yang","offers":[]}
	dispatcher.set_domain("shop", shop_snapshot)
	bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
	assert(messages.back().payload.wallet.balance == 30, "Reload gets current full state")
	assert(messages.back().payload.shop == shop_snapshot, "Reload restores published Shop without new purchase")
	var count: int = messages.size()
	bridge.send("storage.updated",{"items":"x".repeat(WebUiBridge.MAX_BYTES+1)})
	assert(messages.size()==count+1,"Bounded large state reaches CEF")
	bridge.send("command.result",{"ok":true,"error":"x".repeat(WebUiBridge.MAX_BYTES)},"oversize")
	assert(messages.size()==count+1,"Command result limit remains 16 KiB")
	bridge.send("storage.updated",{"items":"x".repeat(WebUiBridge.MAX_STATE_BYTES)})
	assert(messages.size()==count+1,"State boundary remains finite")
	var original_item: Dictionary = {"stats":{"attack":13},"affixes":[{"stat":"attack","value":3}]}
	var tooltip_model: Dictionary = InventoryWebController._item_tooltip_details(original_item)
	assert(tooltip_model.properties == ["Attack: 13"] and tooltip_model.affixes == [{"lines":["+3 Attack"]}], "Existing rolls are displayed without inventing prefix/suffix kind")
	assert(original_item.stats.attack == 13 and original_item.affixes[0].value == 3)
	var fractional_item: Dictionary = {"affixes":[{"stat":"attack","value":1.5},{"stat":"attack","value":-0.25},{"stat":"attack","value":0}]}
	var fractional_tooltip: Dictionary = InventoryWebController._item_tooltip_details(fractional_item)
	assert(fractional_tooltip.affixes == [{"lines":["+1.5 Attack"]},{"lines":["-0.25 Attack"]},{"lines":["+0 Attack"]}], "Affix display preserves fractional values and explicit signs")
	assert(fractional_item.affixes[0].value == 1.5 and fractional_item.affixes[1].value == -0.25)
	var tooltip_controller := InventoryWebController.new()
	tooltip_controller.bridge = bridge
	var tooltip_count: int = messages.size()
	tooltip_controller._set_tooltip_alt(true)
	assert(messages.size() == tooltip_count + 1 and messages.back().type == "ui.tooltip_details" and messages.back().payload == {"alt":true})
	tooltip_controller._set_tooltip_alt(true)
	assert(messages.size() == tooltip_count + 1, "Held Alt sends only transitions")
	tooltip_controller._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	assert(messages.back().payload == {"alt":false}, "Focus loss releases tooltip details without changing keyboard owner")
	tooltip_controller.free()
	dispatcher.free()
	bridge.free()
	print("WEB_UI_PROTOCOL_OK: readiness, explicit commands, correlation, reload snapshot, shared UID and gateway config")
	get_tree().quit()
func _command(_payload: Dictionary) -> Dictionary:
	handled += 1
	return {"ok":true}
