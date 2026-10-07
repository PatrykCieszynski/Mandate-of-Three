class_name ItemDefinitions
extends RefCounted

const IRON_SWORD: ItemDefinition = preload("res://source/common/gameplay/items/domain/iron_sword.tres")

static func get_definition(id: StringName) -> ItemDefinition:
	return IRON_SWORD if id == IRON_SWORD.definition_id else null
