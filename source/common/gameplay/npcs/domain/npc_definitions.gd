class_name NpcDefinitions
extends RefCounted
const BLACKSMITH: NpcDefinition = preload("res://source/common/gameplay/npcs/domain/blacksmith.tres")
static func get_definition(id: StringName) -> NpcDefinition:
	return BLACKSMITH if id == BLACKSMITH.definition_id else null
