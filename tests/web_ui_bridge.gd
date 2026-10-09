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
	host.free()
	if OS.has_feature("client"):
		assert(not ClassDB.class_exists("SQLite"), "Exported client validation must work without SQLite")
	# Run the real client validator; this also runs in an exported client without SQLite.
	var item_uid := "0123456789abcdef0123456789abcdef"
	assert(InventoryWebController._valid_identity({"id":item_uid,"revision":0}))
	for invalid: Variant in ["", item_uid.left(31), item_uid.to_upper(), "g".repeat(32), 42]:
		assert(not InventoryWebController._valid_identity({"id":invalid,"revision":0}))
	assert(not InventoryWebController._valid_identity({"id":item_uid,"revision":-1}))
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
	dispatcher.free()
	bridge.free()
	print("WEB_UI_PROTOCOL_OK: readiness, explicit commands, correlation, reload snapshot, shared UID and gateway config")
	get_tree().quit()
func _command(_payload: Dictionary) -> Dictionary:
	handled += 1
	return {"ok":true}
