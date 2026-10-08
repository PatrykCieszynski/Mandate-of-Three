extends SceneTree
var messages: Array[Dictionary] = []
var rejections: Array[String] = []
func _init() -> void:
	assert(not ClassDB.class_exists("CefTexture"), "Headless baseline must not load native CEF")
	var bridge := WebUiBridge.new()
	var dispatcher := UiCommandDispatcher.new()
	dispatcher.attach(bridge)
	var fixture := preload("res://tests/cef_ui/mock_inventory_controller.gd").new()
	fixture.attach(dispatcher)
	bridge.outgoing.connect(func(m: String) -> void: messages.append(JSON.parse_string(m)))
	bridge.rejected.connect(func(reason: String) -> void: rejections.append(reason))
	bridge.receive('{"v":1,"type":"inventory.move_item","id":"early","payload":{"id":"potion","x":1,"y":0,"revision":0}}')
	assert(messages.is_empty() and fixture.model.revision == 0)
	bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
	assert(messages.back().type == "ui.snapshot" and messages.back().payload.inventory.revision == 0)
	var count: int = messages.size()
	for invalid: String in ['{bad', '{"v":2,"type":"ui.ready","payload":{}}', '{"v":1,"type":"ui.ready","payload":[],"extra":true}', '{"v":1,"type":"ui.ready","payload":{},"extra":1}', '{"v":1,"type":"get_tree().quit","id":"bad","payload":{}}', '{"v":1,"type":"inventory.move_item","payload":{}}', "é".repeat(9000)]:
		bridge.receive(invalid)
	assert(messages.size() == count and rejections.size() == 8)
	bridge.receive('{"v":1,"type":"inventory.move_item","id":"shape","payload":{"rotation":90}}')
	assert(messages.back().type == "command.result" and messages.back().id == "shape" and not messages.back().payload.ok)
	bridge.receive('{"v":1,"type":"inventory.move_item","id":"req-1","payload":{"id":"potion","x":1,"y":0,"revision":0}}')
	assert(messages[-2].type == "inventory.updated" and messages[-2].payload.revision == 1)
	assert(messages[-1].type == "command.result" and messages[-1].id == "req-1" and messages[-1].payload.ok and not messages[-1].payload.has("items"))
	bridge.receive('{"v":1,"type":"inventory.move_item","id":"req-2","payload":{"id":"potion","x":2,"y":1,"revision":1}}')
	assert(messages[-1].payload.error == "overlap" and messages[-2].payload.items[0].x == 1)
	bridge.reset_transport()
	fixture.tick()
	bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
	assert(messages.back().payload.inventory.revision == 1 and messages.back().payload.hud.ticks == 1)
	var regions: Dictionary = {"width":100,"height":100,"regions":[{"id":"panel","x":10,"y":0,"w":90,"h":100}]}
	assert(WebUiBridge.valid_regions(regions))
	regions.regions[0].w = 91
	assert(not WebUiBridge.valid_regions(regions))
	assert(fixture.model.move_item({"id":"spear","x":5,"y":5,"revision":1}).error == "bounds")
	assert(fixture.model.move_item({"id":"potion","x":1,"y":0,"revision":0}).error == "stale")
	dispatcher.free()
	bridge.free()
	print("WEB_UI_PROTOCOL_OK: v1 strict envelopes, whitelist, correlation, domain state, rehydration and regions")
	_test_pointer.call_deferred()

func _test_pointer() -> void:
	var host := WebUiHost.new()
	root.add_child(host)
	host.size = Vector2(1000, 600)
	var control := Control.new()
	host.add_child(control)
	control.size = host.size
	host.browser = control # Native Control fixture; no CEF methods called.
	host.update_interactive_regions({"width":500,"height":300,"regions":[{"id":"panel","x":350,"y":0,"w":150,"h":300}]})
	assert(host.owns_pointer(Vector2(800, 300)))
	assert(not host.owns_pointer(Vector2(500, 300)))
	var press := InputEventMouseButton.new()
	press.position = Vector2(800, 300)
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	host._input(press)
	assert(host.owns_pointer(Vector2(500, 300)) and host.keyboard_owner == "web")
	press.position = Vector2(500, 300)
	press.pressed = false
	host._input(press)
	assert(not host.owns_pointer(Vector2(500, 300)))
	press.position = Vector2(800, 300)
	press.button_index = MOUSE_BUTTON_WHEEL_UP
	press.pressed = true
	host._input(press)
	assert(not host.owns_pointer(Vector2(500, 300)), "Wheel cannot latch drag capture")
	host.set_modal(true)
	assert(host.owns_pointer(Vector2(500, 300)) and host.keyboard_owner == "modal")
	host.set_modal(false)
	assert(host.keyboard_owner == "gameplay" and root.gui_get_focus_owner() != control)
	host.hide_ui()
	assert(not host.owns_pointer(Vector2(800, 300)))
	host.open()
	assert(host.owns_pointer(Vector2(800, 300)), "Hide/show must retain layout regions")
	host.browser = null
	host.queue_free()
	await process_frame
	var unavailable := WebUiHost.new()
	assert(not unavailable.open() and unavailable.browser == null)
	unavailable.free()
	print("WEB_UI_POINTER_OK: scaled regions, drag capture, wheel, modal, hide/show and headless guard")
	quit()
