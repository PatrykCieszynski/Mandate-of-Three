class_name ItemDefinition
extends Resource
## Shared immutable content. Rolled values and ownership belong to ItemInstance.

enum PrimaryAction {
	NONE = 0,
	EQUIP = 1,
	USE = 2,
}
@export var primary_action: PrimaryAction = PrimaryAction.NONE

@export var definition_id: StringName
@export var item_name: String
@export var icon_id: StringName
@export var equipment_slot: StringName
@export var stack_limit: int = 1
@export var base_stats: Dictionary[StringName, float] = {}
@export var stats_per_upgrade: Dictionary[StringName, float] = {}

@export_range(1, 3) var inventory_height: int = 1
