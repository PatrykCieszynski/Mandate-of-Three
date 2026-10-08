extends WebUiHost
var trace_pointer: bool = false
## Trusted test adapter. Evaluation/native diagnostics are never in production host.
func diagnostic_eval(script: String) -> void:
	if is_instance_valid(browser): browser.call("eval", script)

func texture_class() -> String:
	return browser.get("texture").get_class()

func policies_restrictive() -> bool:
	return int(browser.get("popup_policy")) == 0 and int(browser.get("permission_policy")) == 0

func open() -> bool:
	var ok: bool = super.open()
	if ok and not browser.is_connected("console_message", _console):
		browser.connect("console_message", _console)
		browser.gui_input.connect(func(event: InputEvent) -> void:
			if trace_pointer and event is InputEventMouse: print("CEF_NATIVE_GUI: ", event.as_text()))
	return ok

func _console(_level: int, message: String, _source: String, _line: int) -> void:
	print("CEF_WEB: ", message)

func _input(event: InputEvent) -> void:
	super._input(event)
	if trace_pointer and event is InputEventMouse:
		print("CEF_HOST_POINTER: ", event.as_text(), " held=", _held, " filter=", browser.mouse_filter if is_instance_valid(browser) else -1)
