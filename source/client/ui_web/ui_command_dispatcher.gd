class_name UiCommandDispatcher
extends Node
## Explicit application boundary. No CEF types, mock model, reflection or persistence.
const DOMAINS: Array[String] = ["upgrade", "npc_targets", "shop", "npc", "storage", "inventory", "equipment", "wallet", "player", "hud"]
var bridge: WebUiBridge
var _handlers: Dictionary = {}
var _state: Dictionary = {}

func attach(transport: WebUiBridge) -> void:
	assert(bridge == null)
	bridge = transport
	bridge.ui_ready.connect(_snapshot)
	bridge.command_received.connect(_command)

func register_command(type: String, validator: Callable, handler: Callable) -> void:
	assert(bridge != null and not _handlers.has(type) and handler.is_valid())
	_handlers[type] = handler
	bridge.allow_command(type, validator)

func set_domain(domain: String, state: Dictionary) -> void:
	assert(domain in DOMAINS)
	_state[domain] = state.duplicate(true)
	bridge.send(domain + ".updated", _state[domain])

func _snapshot() -> void:
	bridge.send("ui.snapshot", _state.duplicate(true))

func _command(type: String, id: String, payload: Dictionary) -> void:
	# Callable is registered explicitly by the application; never supplied by JS.
	var result: Dictionary = await _handlers[type].call(payload)
	assert(result.has("ok") and result.ok is bool)
	bridge.send("command.result", result, id)
