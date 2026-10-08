class_name WebUiBridge
extends Node
## JSON is data. The only domain command is the mock inventory move.
signal outgoing(message: String)
signal ui_ready
signal command_result(result: Dictionary)
signal diagnostic(payload: Dictionary)
var router := UiCommandRouter.new()
var is_ready: bool = false
var diagnostics_enabled: bool = false

func reset_transport() -> void:
	is_ready = false

func receive(message: String) -> void:
	if message.length() > 4096: return
	var parser := JSON.new()
	if parser.parse(message) != OK: return
	var envelope: Variant = parser.data
	if not envelope is Dictionary or envelope.size() != 2 or not envelope.has_all(["type","payload"]): return
	if not envelope.type is String or not envelope.payload is Dictionary: return
	match envelope.type:
		"UI_READY":
			if not envelope.payload.is_empty(): return
			is_ready = true
			publish("state.snapshot")
			ui_ready.emit()
		"inventory.move_item":
			if not is_ready: return
			var result: Dictionary = router.move_item(envelope.payload)
			publish("state.update",result)
			command_result.emit(result)
		"spike.report":
			if diagnostics_enabled and envelope.payload.size() <= 12:
				diagnostic.emit(envelope.payload)
		_: # Unknown method names never become Object.call()/NodePath operations.
			if is_ready: publish("state.update", {"ok":false,"error":"command"})

func publish(kind: String = "state.update", result: Dictionary = {}) -> void:
	if not is_ready: return
	outgoing.emit(JSON.stringify({"type":kind,"payload":router.snapshot(),"result":result}))

func tick() -> void:
	router.ticks += 1
	publish()
