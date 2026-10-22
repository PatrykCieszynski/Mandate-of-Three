extends Node
## Slot preferences never mint items or grant skills.
func _ready() -> void:
	var bindings := preload("res://source/common/gameplay/hotbar/hotbar_bindings.gd").new()
	assert(bindings.snapshot().size() == 8)
	assert(not bindings.assign_item(-1, "bad"))
	assert(not bindings.assign_skill(8, &"slash"))
	assert(bindings.assign_skill(1, &"slash"))
	assert(bindings.resolve(1, {}, {}).is_empty())
	assert(bindings.resolve(1, {}, {&"slash": true}).id == &"slash")
	assert(bindings.clear(1))
	assert(bindings.binding(1).is_empty())
	var before := bindings.snapshot()
	assert(not bindings.load_bindings([{"kind": &"item", "id": "invalid"}]))
	assert(bindings.snapshot() == before)
	print("HOTBAR_BINDINGS_OK: bounds, references, authorization lookup, atomic restore")
	get_tree().quit()
