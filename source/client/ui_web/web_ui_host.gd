class_name WebUiHost
extends Control
## All CEF API usage stays in this adapter. Loaded only by the standalone spike.
const LOCAL_URL: String = "res://source/client/ui_web/web/index.html"
signal message_received(message: String)
signal navigation_started
signal browser_loaded(url: String, status: int)
signal failure(reason: String)
var browser: Control
var accelerated: bool = true

func open() -> bool:
	if is_instance_valid(browser):
		browser.show()
		return true
	if DisplayServer.get_name() == "headless" or not ClassDB.class_exists("CefTexture"):
		failure.emit("CEF unavailable or headless: no browser created")
		return false
	browser = ClassDB.instantiate("CefTexture") as Control
	browser.set("url",LOCAL_URL)
	browser.set("enable_accelerated_osr",accelerated)
	browser.set("background_color",Color(0,0,0,0))
	browser.set("popup_policy",0)
	browser.set("permission_policy",0)
	browser.mouse_filter = Control.MOUSE_FILTER_STOP
	browser.focus_mode = Control.FOCUS_ALL
	browser.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	browser.connect("ipc_message",func(message: String) -> void: message_received.emit(message))
	browser.connect("load_started",_on_load_started)
	browser.connect("load_finished",func(url: String,status: int) -> void: browser_loaded.emit(url,status))
	browser.connect("console_message",func(_level: int,message: String,_source: String,_line: int) -> void: print("CEF_WEB: ",message))
	add_child(browser)
	browser.grab_focus()
	return true

func hide_ui() -> void:
	if is_instance_valid(browser):
		browser.release_focus()
		browser.hide()

func reload_ui() -> void:
	if is_instance_valid(browser):
		navigation_started.emit()
		browser.call("reload")

func destroy_browser() -> void:
	if not is_instance_valid(browser): return
	browser.release_focus()
	remove_child(browser)
	browser.queue_free()
	browser = null
	navigation_started.emit()

func send(message: String) -> void:
	if is_instance_valid(browser): browser.call("send_ipc_message",message)

func diagnostic_eval(script: String) -> void:
	# Trusted test harness only; never called from a web command.
	if is_instance_valid(browser): browser.call("eval",script)

func _on_load_started(url: String) -> void:
	navigation_started.emit()
	if url != LOCAL_URL and url != "res://source/client/ui_web/web/index.html/":
		# This notification is after navigation starts, not a native veto hook.
		failure.emit("Unexpected navigation; bridge disabled and browser removed: " + url)
		destroy_browser.call_deferred()
