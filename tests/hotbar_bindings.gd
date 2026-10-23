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
	var legacy: Array=snapshot.slice(0,8)
	assert(restored.load_bindings(legacy) and restored.snapshot().size()==16 and restored.binding(15).is_empty())
	await adapter_contract()
	print("HOTBAR_BINDINGS_OK: item removal, unknown skill, snapshot/JSON round-trip and atomic restore")
	get_tree().quit()

class HudProjection extends UiCommandDispatcher:
	var value: Dictionary={}
	func set_domain(_domain: String, state: Dictionary) -> void: value=state

func adapter_contract() -> void:
	var script=preload("res://source/client/ui_web/hotbar_ui_adapter.gd")
	var projection:=HudProjection.new();projection.bridge=WebUiBridge.new()
	var adapter=script.new();adapter.directory="res://.godot/verification/hotbar-"+Crypto.new().generate_random_bytes(8).hex_encode()
	var calls: Array=[]
	var activate: Callable=func(p: Dictionary)->Dictionary:calls.append(p);return {"ok":false,"error":"no_action"}
	adapter.attach(projection,activate)
	var uid: String="0123456789abcdef0123456789abcdef"
	var context: Dictionary={"authority_id":uid,"account_id":2,"character_id":3}
	var item: Dictionary={"uid":uid,"definition_id":"iron_sword","item_name":"Sword","inventory_height":2,"amount":1,"upgrade_level":0,"revision":1,"location":"bag"}
	var inventory: Dictionary={"ok":true,"economic_context":context,"items":[item]}
	adapter.accept_inventory(inventory)
	assert(adapter._assign({"slot":15,"id":uid}).ok)
	assert(adapter._assign({"slot":0,"id":uid}).ok,"atomic preference replacement supports repeated writes")
	assert(not script.valid_slot({"slot":16},1) and not script.valid_slot({"slot":0.5},1))
	item.revision=8;adapter.accept_inventory(inventory)
	assert(not (await adapter.activate_slot(15)).ok and calls[0].revision==8,"activation resolves the current revision")
	item.location="equipment";adapter.accept_inventory(inventory)
	assert(not projection.value.slots[15].available and not (await adapter.activate_slot(15)).ok and calls.size()==1)
	item.location="bag";adapter.accept_inventory(inventory)
	assert(projection.value.slots[15].available)
	var replacement=script.new();replacement.directory=adapter.directory
	var restored:=HudProjection.new();restored.bridge=WebUiBridge.new();replacement.attach(restored,activate);replacement.accept_inventory(inventory)
	assert(replacement.bindings.binding(15).id==uid,"same character restores preferences")
	assert(replacement._clear({"slot":0}).ok and replacement.bindings.binding(0).is_empty())
	context=context.duplicate();context.character_id=4;inventory.economic_context=context;replacement.accept_inventory(inventory)
	assert(replacement.bindings.binding(15).is_empty(),"preferences never leak to another character")
	adapter.accept_inventory({"ok":false})
	assert(not projection.value.slots[15].available and not (await adapter.activate_slot(15)).ok,"failed inventory refresh disables cached ownership")
	inventory.economic_context={"authority_id":uid,"account_id":2,"character_id":3}
	adapter.accept_inventory(inventory)
	assert(projection.value.slots[15].available and projection.value.error.is_empty(),"valid repair restores the binding")
	var corrupt:=FileAccess.open(adapter._path,FileAccess.WRITE);corrupt.store_string("broken preferences");corrupt.close()
	var blocked=script.new();blocked.directory=adapter.directory
	var rejected:=HudProjection.new();rejected.bridge=WebUiBridge.new();blocked.attach(rejected,activate);blocked.accept_inventory(inventory)
	assert(not rejected.value.ready and not blocked._assign({"slot":0,"id":uid}).ok,"corrupt preferences fail closed")
	assert(FileAccess.get_file_as_string(adapter._path)=="broken preferences","corrupt preferences are never overwritten silently")
	blocked.dispose();rejected.bridge.free();rejected.free()
	adapter.dispose();replacement.dispose();projection.bridge.free();projection.free();restored.bridge.free();restored.free()
