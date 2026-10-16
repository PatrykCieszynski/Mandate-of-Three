class_name ItemDefinitions
extends RefCounted

const IRON_SWORD: ItemDefinition = preload("res://source/common/gameplay/items/domain/iron_sword.tres")

const DEV_TRACE_SWORD: ItemDefinition = preload("res://source/common/gameplay/items/domain/dev_trace_sword.tres")

const UPGRADE_ORE: ItemDefinition = preload("res://source/common/gameplay/items/domain/upgrade_ore.tres")

const FOREST_RESIN: ItemDefinition = preload("res://source/common/gameplay/items/domain/forest_resin.tres")
const BEAST_HIDE: ItemDefinition = preload("res://source/common/gameplay/items/domain/beast_hide.tres")
const WOLF_FANG: ItemDefinition = preload("res://source/common/gameplay/items/domain/wolf_fang.tres")
const BANDIT_TOKEN: ItemDefinition = preload("res://source/common/gameplay/items/domain/bandit_token.tres")

static func get_definition(id: StringName) -> ItemDefinition:
	for definition: ItemDefinition in [IRON_SWORD, UPGRADE_ORE, DEV_TRACE_SWORD, FOREST_RESIN, BEAST_HIDE, WOLF_FANG, BANDIT_TOKEN]:
		if id == definition.definition_id: return definition
	return null
