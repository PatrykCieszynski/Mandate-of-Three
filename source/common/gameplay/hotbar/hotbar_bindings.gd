class_name HotbarBindings
extends RefCounted
## Client preference: references only. Item custody remains in the authoritative inventory.
const SLOT_COUNT: int = 16
const ITEM: StringName = &"item"
const SKILL: StringName = &"skill"
var slots: Array[Dictionary] = []

func _init() -> void:
	for i: int in SLOT_COUNT:
		slots.append({})

func assign_item(index: int, uid: String) -> bool:
	if not _valid_index(index) or not ItemInstance.valid_uid(uid):
		return false
	slots[index] = {"kind": ITEM, "id": uid}
	return true

func assign_skill(index: int, skill_id: StringName) -> bool:
	if not _valid_index(index) or skill_id.is_empty():
		return false
	slots[index] = {"kind": SKILL, "id": skill_id}
	return true

func clear(index: int) -> bool:
	if not _valid_index(index):
		return false
	slots[index] = {}
	return true

func binding(index: int) -> Dictionary:
	return slots[index].duplicate() if _valid_index(index) else {}

## Never promote inventory coordinates or UI state into ownership.
func resolve(index: int, owned_uids: Dictionary, known_skills: Dictionary) -> Dictionary:
	var value := binding(index)
	if value.is_empty():
		return {}
	if value.kind == ITEM and not owned_uids.has(value.id):
		return {}
	if value.kind == SKILL and not known_skills.has(value.id):
		return {}
	return value

func load_bindings(values: Array) -> bool:
	# Preserve the original eight-slot preference format on upgrade.
	if values.size() not in [8,SLOT_COUNT]:
		return false
	var next: Array[Dictionary] = []
	for value: Variant in values:
		if not value is Dictionary:
			return false
		if value.is_empty():
			next.append({})
			continue
		if not value.has_all(["kind", "id"]):
			return false
		if value.kind == ITEM and value.id is String and ItemInstance.valid_uid(value.id):
			next.append({"kind": ITEM, "id": value.id})
		# JSON restores identifiers as String; keep the internal skill ID canonical.
		elif value.kind == SKILL and (value.id is StringName or value.id is String) and not value.id.is_empty():
			next.append({"kind": SKILL, "id": StringName(value.id)})
		else:
			return false
	while next.size()<SLOT_COUNT: next.append({})
	slots = next
	return true

func snapshot() -> Array[Dictionary]:
	return slots.duplicate(true)

static func _valid_index(index: int) -> bool:
	return index >= 0 and index < SLOT_COUNT
