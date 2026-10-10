class_name WebUiBridge
extends Node
## Protocol/transport only. Application handlers and state belong to the dispatcher.
const VERSION: int = 1
const MAX_BYTES: int = 16384
const MAX_STATE_BYTES: int = 131072
signal outgoing(message: String)
signal ui_ready
signal command_received(type: String, id: String, payload: Dictionary)
signal interactive_regions_received(payload: Dictionary)
signal rejected(reason: String)
var is_ready: bool = false
var _commands: Dictionary = {}

func allow_command(type: String, validator: Callable) -> void:
	assert(not type.begins_with("ui.") and validator.is_valid())
	_commands[type] = validator

func reset_transport() -> void:
	is_ready = false

func receive(message: String) -> void:
	if message.to_utf8_buffer().size() > MAX_BYTES:
		rejected.emit("size")
		return
	var parser := JSON.new()
	if parser.parse(message) != OK:
		rejected.emit("json")
		return
	var envelope: Variant = parser.data
	if not envelope is Dictionary or not envelope.has_all(["v", "type", "payload"]) or envelope.size() > 4:
		rejected.emit("envelope")
		return
	for key: Variant in envelope:
		if key not in ["v", "type", "id", "payload"]:
			rejected.emit("field")
			return
	if not is_integer(envelope.v) or envelope.v != VERSION or not envelope.type is String or not envelope.payload is Dictionary:
		rejected.emit("version_or_shape")
		return
	if envelope.has("id") and (not envelope.id is String or envelope.id.is_empty() or envelope.id.length() > 80):
		rejected.emit("id")
		return
	var type: String = envelope.type
	var payload: Dictionary = envelope.payload
	if type == "ui.ready":
		if envelope.has("id") or not payload.is_empty():
			rejected.emit("ready_shape")
			return
		is_ready = true
		ui_ready.emit()
		return
	if not is_ready:
		rejected.emit("not_ready")
		return
	if type == "ui.interactive_regions":
		if envelope.has("id") or not valid_regions(payload):
			rejected.emit("regions")
			return
		interactive_regions_received.emit(payload.duplicate(true))
		return
	if not _commands.has(type) or not envelope.has("id"):
		rejected.emit("command")
		return
	if not _commands[type].call(payload):
		send("command.result", {"ok": false, "error": "payload"}, envelope.id)
		return
	command_received.emit(type, envelope.id, payload.duplicate(true))

func send(type: String, payload: Dictionary, id: String = "") -> void:
	if not is_ready: return
	var envelope: Dictionary = {"v": VERSION, "type": type, "payload": payload}
	if not id.is_empty(): envelope.id = id
	var encoded: String = JSON.stringify(envelope)
	var limit: int = MAX_STATE_BYTES if type == "ui.snapshot" or type in ["shop.updated","npc.updated","inventory.updated","storage.updated","equipment.updated","wallet.updated","player.updated","hud.updated"] else MAX_BYTES
	if encoded.to_utf8_buffer().size() > limit:
		rejected.emit("outgoing_size")
		return
	outgoing.emit(encoded)

static func is_integer(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floor(float(value)) and abs(float(value)) <= 2147483647

static func valid_regions(payload: Dictionary) -> bool:
	if payload.size() != 3 or not payload.has_all(["width", "height", "regions"]): return false
	if not is_integer(payload.width) or not is_integer(payload.height) or payload.width <= 0 or payload.height <= 0 or payload.width > 32768 or payload.height > 32768: return false
	if not payload.regions is Array or payload.regions.size() > 64: return false
	var ids: Dictionary = {}
	for region: Variant in payload.regions:
		if not region is Dictionary or region.size() != 5 or not region.has_all(["id", "x", "y", "w", "h"]): return false
		if not region.id is String or region.id.is_empty() or region.id.length() > 80 or ids.has(region.id): return false
		ids[region.id] = true
		for field: String in ["x", "y", "w", "h"]:
			if not (region[field] is int or region[field] is float) or not is_finite(float(region[field])) or region[field] < 0: return false
		if region.x + region.w > payload.width or region.y + region.h > payload.height: return false
	return true
