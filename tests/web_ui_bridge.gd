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
	print("WEB_UI_PROTOCOL_OK: readiness, explicit commands, correlation, reload snapshot")
	get_tree().quit()
func _command(_payload: Dictionary) -> Dictionary:
	handled += 1
	return {"ok":true}
