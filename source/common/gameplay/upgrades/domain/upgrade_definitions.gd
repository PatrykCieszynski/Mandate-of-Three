class_name UpgradeDefinitions
extends RefCounted
const BASIC: UpgradeDefinition = preload("res://source/common/gameplay/upgrades/domain/basic_upgrade.tres")
static func get_definition(id: StringName) -> UpgradeDefinition:
	return BASIC if id == BASIC.upgrade_id else null
