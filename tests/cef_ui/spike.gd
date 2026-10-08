extends Node3D
## Standalone project only. Native UI/game background plus isolated web adapter.
const TestHost = preload("res://tests/cef_ui/test_web_ui_host.gd")
var host: TestHost
var bridge: WebUiBridge
var dispatcher: UiCommandDispatcher
var fixture := preload("res://tests/cef_ui/mock_inventory_controller.gd").new()
var gameplay_clicks: int = 0
var gameplay_keys: int = 0
var status: Label
var cube: MeshInstance3D
var ready_count: int = 0
var results: Array[Dictionary] = []
var reports: Array[Dictionary] = []
var _elapsed: float = 0.0
var _tick: float = 0.0
var failures: Array[String] = []
var last_command_us: int = 0
var automated: bool = false
var baseline: bool = false
var measured_focus: bool = false
var expected_navigation: bool = false

func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	automated = args.has("--automated")
	baseline = args.has("--baseline")
	DisplayServer.window_set_title("Mandate CEF UI spike")
	Engine.max_fps = 60
	get_window().grab_focus.call_deferred()
	get_tree().auto_accept_quit = false
	_build_game()
	bridge = WebUiBridge.new()

	add_child(bridge)
	dispatcher = UiCommandDispatcher.new()
	add_child(dispatcher)
	dispatcher.attach(bridge)
	fixture.attach(dispatcher)
	dispatcher.register_command("test.report", func(p: Dictionary) -> bool: return p.size() <= 12, _report)
	host = preload("res://tests/cef_ui/test_web_ui_host.gd").new()
	host.entry_path = "res://tests/cef_ui/web/index.html"
	host.name = "WebUI"
	var canvas := CanvasLayer.new()
	add_child(canvas)
	canvas.add_child(host)
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.accelerated = not args.has("--software")
	host.message_received.connect(bridge.receive)
	host.navigation_started.connect(bridge.reset_transport)
	bridge.outgoing.connect(host.send)
	bridge.ui_ready.connect(func() -> void: ready_count += 1; print("CEF_UI_READY: ",ready_count))
	bridge.interactive_regions_received.connect(host.update_interactive_regions)
	bridge.outgoing.connect(func(message: String) -> void:
		var envelope: Dictionary = JSON.parse_string(message)
		if envelope.type == "command.result" and not envelope.id.begins_with("report-") and envelope.payload.get("error", "") != "":
			results.append(envelope.payload)
		if envelope.type == "inventory.updated": last_command_us = Time.get_ticks_usec())
	host.browser_loaded.connect(func(url: String,status_code: int) -> void: print("CEF_LOADED: ",url," status=",status_code))
	host.failure.connect(func(reason: String) -> void:
		if expected_navigation and reason.begins_with("Unexpected navigation;"): print("CEF_NAVIGATION_GUARD: ",reason)
		else: failures.append(reason); push_error(reason))
	_build_toolbar()
	if not baseline: host.open()
	print("CEF_SPIKE_START: renderer=",RenderingServer.get_current_rendering_method()," baseline=",baseline)
	if automated: _run_checks.call_deferred()
	if baseline:
		await get_tree().create_timer(24).timeout
		print("CEF_BASELINE_DONE")
		get_tree().quit()

func _build_game() -> void:
	var camera := Camera3D.new()
	camera.position = Vector3(7,7,10)
	camera.current = true
	add_child(camera)
	camera.look_at(Vector3.ZERO)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50,-30,0)
	add_child(light)
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color("243d50")
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("b7d8e5")
	environment.environment = settings
	add_child(environment)
	var floor_mesh := MeshInstance3D.new()
	var floor_box := BoxMesh.new()
	floor_box.size = Vector3(20,0.2,16)
	floor_mesh.mesh = floor_box
	floor_mesh.position.y = -1
	add_child(floor_mesh)
	cube = MeshInstance3D.new()
	cube.mesh = BoxMesh.new()
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("57d5b4")
	cube.material_override = material
	add_child(cube)

func _build_toolbar() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 3
	add_child(layer)
	var bar := VBoxContainer.new()
	bar.position = Vector2(20,20)
	layer.add_child(bar)
	status = Label.new()
	bar.add_child(status)
	for action: String in ["Open / close", "Reload", "Recreate", "Resize", "Quit"]:
		var button := Button.new()
		button.text = action
		button.pressed.connect(_action.bind(action))
		bar.add_child(button)

func _action(action: String) -> void:
	match action:
		"Open / close":
			if is_instance_valid(host.browser) and host.browser.visible: host.hide_ui()
			else: host.open()
		"Reload": host.reload_ui()
		"Recreate":
			host.destroy_browser()
			await get_tree().process_frame
			host.open()
		"Resize": DisplayServer.window_set_size(Vector2i(1280,900) if DisplayServer.window_get_size().x < 1200 else Vector2i(960,640))
		"Quit": _quit()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST: _quit()

func _quit() -> void:
	host.destroy_browser()
	await get_tree().process_frame
	print("CEF_SPIKE_QUIT")
	get_tree().quit(1 if not failures.is_empty() else 0)

func _process(delta: float) -> void:
	_elapsed += delta
	if not measured_focus and _elapsed >= 10:
		measured_focus = true
		print("CEF_IDLE_FOCUS: ",get_window().has_focus()," fps=",Engine.get_frames_per_second())
	_tick += delta
	cube.rotation.y += delta * 0.25
	if _tick >= 1:
		_tick = fmod(_tick,1)
		fixture.tick()
	status.text = "Web UI foundation fixture\nReady: %d | rev %d | tick %d\nFPS %d | renderer %s" % [ready_count,fixture.model.revision,fixture.model.ticks,Engine.get_frames_per_second(),RenderingServer.get_current_rendering_method()]
	if automated and _elapsed > 90:
		failures.append("Automated timeout")
		_quit()

func check(ok: bool, label: String) -> void:
	if not ok:
		failures.append(label)
		push_error("CEF_CHECK_FAILED: " + label)
	else: print("CEF_CHECK_OK: ",label)

func wait_ready(count: int) -> void:
	var deadline: int = Time.get_ticks_msec()+15000
	while ready_count < count and Time.get_ticks_msec() < deadline: await get_tree().process_frame
	check(ready_count >= count,"UI_READY full snapshot %d" % count)

func _run_checks() -> void:
	if OS.get_cmdline_user_args().has("--measure"):
		await get_tree().create_timer(20).timeout
	await wait_ready(1)
	if not failures.is_empty():
		_quit()
		return
	await get_tree().create_timer(1).timeout
	check(not reports.is_empty(),"Godot -> web snapshot/update -> diagnostic roundtrip")
	# Real IPC bridge commands; rejection must keep Godot's authoritative state.
	host.diagnostic_eval("window.sendIpcMessage(JSON.stringify({v:1,type:'inventory.move_item',id:'direct-test',payload:{id:'potion',x:1,y:0,revision:0}}))")
	await get_tree().create_timer(0.3).timeout
	check(fixture.model.revision == 1 and fixture.model.items[0].x == 1,"valid move via CEF IPC")
	host.diagnostic_eval("window.sendIpcMessage(JSON.stringify({v:1,type:'inventory.move_item',id:'direct-test',payload:{id:'spear',x:0,y:6,revision:1}}))")
	await get_tree().create_timer(0.3).timeout
	check(fixture.model.revision == 1 and results.back().error == "bounds","rejected placement retains authoritative snapshot")
	var target_ready: int = ready_count+1
	host.reload_ui()
	await wait_ready(target_ready)
	check(fixture.model.revision == 1,"reload retains client state in Godot")
	for i: int in 10:
		host.hide_ui()
		await get_tree().process_frame
		check(not host.browser.visible,"close %d" % i)
		host.open()
		await get_tree().process_frame
	check(fixture.model.revision == 1,"ten open/close cycles retain state")
	target_ready = ready_count+1
	host.destroy_browser()
	await get_tree().process_frame
	host.open()
	await wait_ready(target_ready)
	check(fixture.model.revision == 1,"browser recreation retains state")
	DisplayServer.window_set_size(Vector2i(1280,900))
	await get_tree().create_timer(0.7).timeout
	host.diagnostic_eval("window.sendIpcMessage(JSON.stringify({v:1,type:'test.report',id:'report-direct',payload:{kind:'geometry',width:innerWidth,height:innerHeight,transparent:getComputedStyle(document.body).backgroundColor,revision:window.spikeState.revision}}))")
	await get_tree().create_timer(0.3).timeout
	for report: Dictionary in reports:
		if report.get("kind") == "geometry": print("CEF_GEOMETRY: ",JSON.stringify(report)); check(report.width >= 1100 and report.transparent == "rgba(0, 0, 0, 0)","resize and transparent CSS")
	print("CEF_TEXTURE_CLASS: ",host.texture_class())
	check(host.policies_restrictive(),"native popup block and permission deny")
	host.diagnostic_eval("fetch('https://example.invalid/').then(()=>window.sendIpcMessage(JSON.stringify({v:1,type:'test.report',id:'report-direct',payload:{kind:'csp',blocked:false}}))).catch(()=>window.sendIpcMessage(JSON.stringify({v:1,type:'test.report',id:'report-direct',payload:{kind:'csp',blocked:true}})))")
	await get_tree().create_timer(0.3).timeout
	check(reports.any(func(r: Dictionary) -> bool: return r.get("kind") == "csp" and r.get("blocked") == true),"CSP denies remote fetch")
	await _input_checks()
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://cef-spike.png")
	print("CEF_SCREENSHOT: ",ProjectSettings.globalize_path("user://cef-spike.png"))
	expected_navigation = true
	host.diagnostic_eval("location.href='about:blank'")
	await get_tree().create_timer(0.5).timeout
	check(not is_instance_valid(host.browser) and not bridge.is_ready,"unexpected navigation disables bridge and removes browser")
	print("CEF_AUTOMATED_RESULT: ",JSON.stringify({"ok":failures.is_empty(),"failures":failures,"ready_count":ready_count,"revision":fixture.model.revision}))
	_quit()

func _input_checks() -> void:
	host.trace_pointer = true
	# Engine event injection, NOT physical Windows SendInput. Exercises CefTexture GUI routing.
	get_window().grab_focus()
	await get_tree().create_timer(0.3).timeout
	print("CEF_INPUT_FOCUS: ",get_window().has_focus())
	host.diagnostic_eval("window.sendIpcMessage(JSON.stringify({v:1,type:'test.report',id:'report-direct',payload:{kind:'input_geometry',width:innerWidth,height:innerHeight,grid:[grid.getBoundingClientRect().left,grid.getBoundingClientRect().top],cell:parseFloat(getComputedStyle(grid).getPropertyValue('--cell')),field:[document.getElementById('focus-test').getBoundingClientRect().left+20,document.getElementById('focus-test').getBoundingClientRect().top+12]}}))")
	await get_tree().create_timer(0.2).timeout
	var geometry: Dictionary = {}
	for report: Dictionary in reports:
		if report.get("kind") == "input_geometry": geometry = report
	check(not geometry.is_empty(),"input geometry from Chromium")
	if geometry.is_empty(): return
	var origin := Vector2(float(geometry.grid[0]),float(geometry.grid[1]))
	var cell: float = float(geometry.cell)
	var from: Vector2 = _map_point(origin+Vector2(1.5*cell,0.5*cell),geometry)
	var to: Vector2 = _map_point(origin+Vector2(1.5*cell,1.5*cell),geometry)
	await _mouse_move(from)
	await _mouse_button(from,true)
	await _mouse_move(to,true)
	check(reports.any(func(r: Dictionary) -> bool: return r.get("kind") == "preview" and r.get("valid") == true),"mouse drag green placement preview")
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://cef-preview-green.png")
	var sent: int = Time.get_ticks_usec()
	await _mouse_button(to,false)
	await _wait_command_after(sent)
	check(fixture.model.revision == 2 and fixture.model.items[0].y == 1,"drag/drop mouse events validate move in Godot")
	if last_command_us >= sent: print("CEF_INPUT_ROUNDTRIP_MS: ",(last_command_us-sent)/1000.0," (engine injected mouse release -> Godot command result)")
	# Drag onto the blade: web preview red, Godot rejects overlap, state restored.
	var blocked: Vector2 = _map_point(origin+Vector2(2.5*cell,1.5*cell),geometry)
	await _mouse_button(to,true)
	await _mouse_move(blocked,true)
	check(reports.any(func(r: Dictionary) -> bool: return r.get("kind") == "preview" and r.get("valid") == false),"mouse drag red placement preview")
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://cef-preview-red.png")
	var rejection_sent: int = Time.get_ticks_usec()
	await _mouse_button(blocked,false)
	await _wait_command_after(rejection_sent)
	check(fixture.model.revision == 2 and results.back().error == "overlap" and fixture.model.items[0].x == 1,"rejected drag restores authoritative placement")
	host.trace_pointer = false
	var field: Vector2 = _map_point(Vector2(float(geometry.field[0]),float(geometry.field[1])),geometry)
	await _mouse_move(field)
	await _mouse_button(field,true)
	await _mouse_button(field,false)
	for character: String in ["a","b","c"]:
		var key := InputEventKey.new()
		key.keycode = character.to_upper().unicode_at(0)
		key.physical_keycode = key.keycode
		key.unicode = character.unicode_at(0)
		key.pressed = true
		Input.parse_input_event(key)
		await get_tree().create_timer(0.1).timeout
	check(reports.any(func(r: Dictionary) -> bool: return r.get("kind") == "input" and r.get("value") == "abc"),"mouse focus and keyboard text input")
	var tab := InputEventKey.new()
	tab.keycode = KEY_TAB
	tab.physical_keycode = KEY_TAB
	tab.pressed = true
	Input.parse_input_event(tab)
	await get_tree().create_timer(0.2).timeout
	check(reports.any(func(r: Dictionary) -> bool: return r.get("kind") == "key" and r.get("key") == "Tab"),"keyboard Tab reaches Chromium")
	host.hide_ui()
	var before: int = reports.filter(func(r: Dictionary) -> bool: return r.get("kind") == "key").size()
	Input.parse_input_event(tab)
	await get_tree().create_timer(0.2).timeout
	check(reports.filter(func(r: Dictionary) -> bool: return r.get("kind") == "key").size() == before,"hidden browser does not capture keyboard")
	host.open()
	await get_tree().create_timer(0.3).timeout
	var outside := Vector2(400, 500)
	var click_count: int = gameplay_clicks
	await _mouse_move(outside)
	await _mouse_button(outside, true)
	await _mouse_button(outside, false)
	check(gameplay_clicks > click_count and host.keyboard_owner == "gameplay", "transparent area passes pointer to gameplay and releases web focus")
	var key_count: int = gameplay_keys
	get_viewport().push_input(tab, true)
	await get_tree().process_frame
	check(gameplay_keys > key_count, "gameplay keyboard restored after outside click")
	host.set_modal(true)
	click_count = gameplay_clicks
	await _mouse_move(outside)
	await _mouse_button(outside, true)
	await _mouse_button(outside, false)
	check(gameplay_clicks == click_count and host.keyboard_owner == "modal", "modal owns entire viewport")
	host.set_modal(false)
	key_count = gameplay_keys
	get_viewport().push_input(tab, true)
	await get_tree().process_frame
	check(gameplay_keys > key_count and host.keyboard_owner == "gameplay", "closing modal restores keyboard")

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed: gameplay_clicks += 1
	if event is InputEventKey and event.pressed: gameplay_keys += 1

func _wait_command_after(sent: int) -> void:
	var deadline: int = Time.get_ticks_msec()+1000
	while last_command_us < sent and Time.get_ticks_msec() < deadline: await get_tree().process_frame
	if last_command_us < sent: print("CEF_POINTER_DIAGNOSTICS: ",JSON.stringify(reports.filter(func(r: Dictionary) -> bool: return r.get("kind") in ["pointer","preview"])))

func _map_point(point: Vector2, geometry: Dictionary) -> Vector2:
	return host.browser.global_position+point*host.browser.size/Vector2(float(geometry.width),float(geometry.height))

func _mouse_move(point: Vector2, held: bool = false) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	get_viewport().push_input(event,true)
	await get_tree().create_timer(0.15).timeout

func _mouse_button(point: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.pressed = pressed
	get_viewport().push_input(event,true)
	await get_tree().create_timer(0.15).timeout

func _report(payload: Dictionary) -> Dictionary:
	reports.append(payload)
	if reports.size() > 1000: reports.pop_front()
	return {"ok": true}
