class_name UiCommandDispatcher
extends Node
## Explicit application boundary. No CEF types, mock model, reflection or persistence.
const DOMAINS: Array[String] = ["stats", "chat", "party", "exchange", "market_browser", "market", "upgrade", "npc_targets", "shop", "npc", "storage", "inventory", "equipment", "wallet", "player", "hud"]
var bridge: WebUiBridge
var _handlers: Dictionary = {}
var _state: Dictionary = {}
var _disposed: bool = false

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
	if _disposed: return
	assert(domain in DOMAINS)
	_state[domain] = state.duplicate(true)
	bridge.send(domain + ".updated", _state[domain])

func _snapshot() -> void:
	bridge.send("ui.snapshot", _state.duplicate(true))

func _command(type: String, id: String, payload: Dictionary) -> void:
	if _disposed: return
	# Callable is registered explicitly by the application; never supplied by JS.
	var transport := bridge
	var generation: int = transport.generation()
	var result: Dictionary = await _handlers[type].call(payload)
	assert(result.has("ok") and result.ok is bool)
	if is_instance_valid(transport) and transport.generation() == generation:
		transport.send("command.result", result, id)

func dispose() -> void:
	if _disposed: return
	_disposed = true
	if is_instance_valid(bridge):
		bridge.reset_transport()
		if bridge.ui_ready.is_connected(_snapshot): bridge.ui_ready.disconnect(_snapshot)
		if bridge.command_received.is_connected(_command): bridge.command_received.disconnect(_command)
	_handlers.clear()
