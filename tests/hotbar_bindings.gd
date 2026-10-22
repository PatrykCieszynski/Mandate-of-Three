extends Node
## Preferences are references only; persistence cannot grant items or skills.
const Bindings = preload("res://source/common/gameplay/hotbar/hotbar_bindings.gd")

func _ready() -> void:
	var bindings := Bindings.new()
	assert(bindings.snapshot().size() == Bindings.SLOT_COUNT)
	assert(not bindings.assign_item(-1, "bad"))
	assert(not bindings.assign_skill(Bindings.SLOT_COUNT, &"slash"))
	var uid := "0123456789abcdef0123456789abcdef"
	assert(bindings.assign_item(0, uid))
	var inventory := {uid: true}
	assert(bindings.resolve(0, inventory, {}).id == uid)
	inventory.erase(uid)
	assert(bindings.resolve(0, inventory, {}).is_empty())
	# Retaining the preference does not make a missing item usable.
	assert(bindings.binding(0).id == uid)
	assert(bindings.assign_skill(1, &"slash"))
	assert(bindings.resolve(1, {}, {&"other_skill": true}).is_empty())
	assert(bindings.resolve(1, {}, {&"slash": true}).id == &"slash")

	var snapshot := bindings.snapshot()
	var restored := Bindings.new()
	assert(restored.load_bindings(snapshot))
	assert(restored.snapshot() == snapshot)
	var json: Array = JSON.parse_string(JSON.stringify(snapshot))
	assert(json[1].id is String)
	assert(restored.load_bindings(json))
	assert(restored.snapshot() == snapshot)
	assert(restored.binding(1).id is StringName)
	assert(restored.resolve(0, {}, {}).is_empty())
	assert(restored.resolve(1, {}, {}).is_empty())

	# Failed load must preserve every previous slot, even after valid entries.
	for invalid_id: Variant in ["", 42]:
		var malformed := snapshot.duplicate(true)
		malformed[0] = {} # A valid prefix must not clear the existing item on failure.
		malformed[1] = {"kind": "skill", "id": invalid_id}
		assert(not restored.load_bindings(malformed))
		assert(restored.snapshot() == snapshot)
	assert(not restored.load_bindings([{"kind": "item", "id": "invalid"}]))
	assert(restored.snapshot() == snapshot)
	assert(bindings.clear(1))
	assert(bindings.binding(1).is_empty())
	assert(restored.binding(1).id == &"slash")
	print("HOTBAR_BINDINGS_OK: item removal, unknown skill, snapshot/JSON round-trip and atomic restore")
	get_tree().quit()
