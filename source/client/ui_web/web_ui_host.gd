class_name WebUiHost
extends Control
## Only CEF adapter. Never instantiate in server/headless composition roots.
signal message_received(message: String)
signal navigation_started
signal browser_loaded(url: String, status: int)
signal failure(reason: String)
signal keyboard_owner_changed(owner: String)
var browser: Control
var accelerated: bool = true
var entry_path: String = "res://source/client/ui_web/web/index.html"
## Pointer-only screens keep gameplay keys; text/modal screens opt into web focus.
var capture_keyboard_on_click: bool = true
var keyboard_owner: String = "gameplay"
var modal: bool = false
var _regions: Array[Rect2] = []
var _held: int = 0
var _world_pointer_capture: bool = false

static func supported_client() -> bool:
	return DisplayServer.get_name() != "headless" and ClassDB.class_exists("CefTexture") and RenderingServer.get_current_rendering_method() == "mobile"

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(func() -> void: _regions.clear())

func open() -> bool:
	if is_instance_valid(browser):
		browser.show()
		_apply_focus()
		return true
	if DisplayServer.get_name() == "headless" or not ClassDB.class_exists("CefTexture"):
		failure.emit("CEF unavailable or headless: no browser created")
		return false
	if not entry_path.begins_with("res://") or not entry_path.ends_with(".html") or not FileAccess.file_exists(entry_path):
		failure.emit("Only an existing bundled res:// HTML entry is allowed")
		return false
	browser = ClassDB.instantiate("CefTexture") as Control
	browser.set("url", entry_path)
	browser.set("enable_accelerated_osr", accelerated)
	browser.set("background_color", Color(0, 0, 0, 0))
	browser.set("popup_policy", 0)
	browser.set("permission_policy", 0)
	browser.mouse_filter = Control.MOUSE_FILTER_IGNORE
	browser.focus_mode = Control.FOCUS_NONE
	browser.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# CEF drains IPC before loading signals in one native batch. Deliver IPC after
	# navigation reset, and avoid calling back into CEF from its signal stack.
	browser.connect("ipc_message", _on_ipc_message, CONNECT_DEFERRED)
	browser.connect("load_started", _on_load_started)
	browser.connect("load_finished", func(url: String, status: int) -> void: browser_loaded.emit(url, status))
	add_child(browser)
	_apply_focus()
	return true

func update_interactive_regions(payload: Dictionary) -> void:
	if not WebUiBridge.valid_regions(payload) or not is_instance_valid(browser): return
	_regions.clear()
	var scale: Vector2 = browser.size / Vector2(payload.width, payload.height)
	for region: Dictionary in payload.regions:
		_regions.append(Rect2(Vector2(region.x, region.y) * scale, Vector2(region.w, region.h) * scale))

func set_world_pointer_capture(active: bool) -> void:
	_world_pointer_capture = active
	if active:
		_held = 0
		set_keyboard_owner("gameplay")
		if is_instance_valid(browser): browser.mouse_filter = Control.MOUSE_FILTER_IGNORE

func owns_pointer(point: Vector2) -> bool:
	if _world_pointer_capture and not modal: return false
	if not is_instance_valid(browser) or not browser.is_visible_in_tree(): return false
	if modal or _held != 0: return true
	var local: Vector2 = browser.get_global_transform_with_canvas().affine_inverse() * point
	return _regions.any(func(rect: Rect2) -> bool: return rect.has_point(local))

func _input(event: InputEvent) -> void:
	if not is_instance_valid(browser) or not browser.is_visible_in_tree(): return
	if event is InputEventMouse:
		var owns: bool = owns_pointer(event.position)
		browser.mouse_filter = Control.MOUSE_FILTER_STOP if owns else Control.MOUSE_FILTER_IGNORE
		if event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_XBUTTON1, MOUSE_BUTTON_XBUTTON2]:
			var bit: int = 1 << (event.button_index - 1)
			if event.pressed:
				if owns: _held |= bit
				set_keyboard_owner("web" if owns and capture_keyboard_on_click else "gameplay")
			else:
				_held &= ~bit
				# Keep STOP through GUI delivery of this release; next mouse event recomputes.

func set_keyboard_owner(owner: String) -> void:
	assert(owner in ["gameplay", "web"])
	keyboard_owner = "modal" if modal else owner
	_apply_focus()
	keyboard_owner_changed.emit(keyboard_owner)

func set_modal(active: bool) -> void:
	modal = active
	_held = 0
	set_keyboard_owner("web" if active else "gameplay")
	if is_instance_valid(browser): browser.mouse_filter = Control.MOUSE_FILTER_STOP if active else Control.MOUSE_FILTER_IGNORE

func _apply_focus() -> void:
	if not is_inside_tree() or not is_instance_valid(browser): return
	if keyboard_owner == "gameplay" or not browser.is_visible_in_tree():
		var owner: Control = get_viewport().gui_get_focus_owner()
		if owner == browser or (is_instance_valid(owner) and browser.is_ancestor_of(owner)):
			get_viewport().gui_release_focus()
		browser.focus_mode = Control.FOCUS_NONE
	else:
		browser.focus_mode = Control.FOCUS_ALL
		var owner: Control = get_viewport().gui_get_focus_owner()
		# Preserve CEF's editable/IME proxy if already focused inside the adapter.
		if owner != browser and not (is_instance_valid(owner) and browser.is_ancestor_of(owner)):
			browser.grab_focus()

func _reset_input() -> void:
	_world_pointer_capture = false
	_regions.clear()
	_held = 0
	modal = false
	set_keyboard_owner("gameplay")

func hide_ui() -> void:
	_held = 0
	modal = false
	set_keyboard_owner("gameplay")
	if is_instance_valid(browser): browser.hide()

func reload_ui() -> void:
	if is_instance_valid(browser):
		_reset_input()
		navigation_started.emit()
		browser.call("reload")

func destroy_browser() -> void:
	_reset_input()
	if not is_instance_valid(browser): return
	remove_child(browser)
	browser.queue_free()
	browser = null
	navigation_started.emit()

func send(message: String) -> void:
	if is_instance_valid(browser): browser.call("send_ipc_message", message)

func _on_ipc_message(message: String) -> void:
	message_received.emit(message)

func _on_load_started(url: String) -> void:
	_reset_input()
	navigation_started.emit()
	if url != entry_path and url != entry_path + "/":
		# Upstream exposes only an after-start notification, not a synchronous veto.
		failure.emit("Unexpected navigation; bridge disabled and browser removed: " + url)
		destroy_browser.call_deferred()
