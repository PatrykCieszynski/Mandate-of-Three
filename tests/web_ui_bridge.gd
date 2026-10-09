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
	# Independent requests accept out-of-order replies and ignore expired IDs.
	var controller := InventoryWebController.new()
	add_child(controller)
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
	bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
	assert(messages.back().payload.wallet.balance == 30, "Reload gets current full state")
	var count: int = messages.size()
	bridge.send("storage.updated",{"items":"x".repeat(WebUiBridge.MAX_BYTES+1)})
	assert(messages.size()==count+1,"Bounded large state reaches CEF")
	bridge.send("command.result",{"ok":true,"error":"x".repeat(WebUiBridge.MAX_BYTES)},"oversize")
	assert(messages.size()==count+1,"Command result limit remains 16 KiB")
	bridge.send("storage.updated",{"items":"x".repeat(WebUiBridge.MAX_STATE_BYTES)})
	assert(messages.size()==count+1,"State boundary remains finite")
	dispatcher.free()
	bridge.free()
	print("WEB_UI_PROTOCOL_OK: readiness, explicit commands, correlation, reload snapshot, shared UID and gateway config")
	get_tree().quit()
func _command(_payload: Dictionary) -> Dictionary:
	handled += 1
	return {"ok":true}
