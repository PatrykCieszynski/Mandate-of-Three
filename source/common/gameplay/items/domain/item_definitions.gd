class_name ItemDefinitions
extends RefCounted

const IRON_SWORD: ItemDefinition = preload("res://source/common/gameplay/items/domain/iron_sword.tres")

const DEV_TRACE_SWORD: ItemDefinition = preload("res://source/common/gameplay/items/domain/dev_trace_sword.tres")

const UPGRADE_ORE: ItemDefinition = preload("res://source/common/gameplay/items/domain/upgrade_ore.tres")

static func get_definition(id: StringName) -> ItemDefinition:
	for definition: ItemDefinition in [IRON_SWORD, UPGRADE_ORE, DEV_TRACE_SWORD]:
		if id == definition.definition_id: return definition
	return null
