extends RefCounted
var model := MockInventory.new()
var dispatcher: UiCommandDispatcher

func attach(application: UiCommandDispatcher) -> void:
	dispatcher = application
	dispatcher.register_command("inventory.move_item", valid_move, move)
	dispatcher.set_domain("inventory", model.snapshot())

func valid_move(payload: Dictionary) -> bool:
	if payload.size() != 4 or not payload.has_all(["id", "x", "y", "revision"]): return false
	return payload.id is String and payload.id.length() <= 32 and WebUiBridge.is_integer(payload.x) and WebUiBridge.is_integer(payload.y) and WebUiBridge.is_integer(payload.revision)

func move(payload: Dictionary) -> Dictionary:
	var result: Dictionary = model.move_item(payload)
	# Including rejection: restore authoritative placement independently of result.
	dispatcher.set_domain("inventory", model.snapshot())
	return result

func tick() -> void:
	model.ticks += 1
	dispatcher.set_domain("hud", {"ticks": model.ticks})
