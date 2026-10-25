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
@export var market_fungible: bool = false
@export var tradeable: bool = true
## -1 explicitly excludes an item from NPC sale (including recipe inputs).
@export var vendor_price: int = -1
@export var recipe_tags: Array[StringName] = []
@export var recipe_category: StringName
@export var base_stats: Dictionary[StringName, float] = {}
@export var stats_per_upgrade: Dictionary[StringName, float] = {}
## C1 eligibility is a property of the base, independent of player/+level.
## Empty family opts out. Future per-instance item level is a separate decision.
@export var affix_family: StringName
@export_range(1, 1000000) var affix_level: int = 1

@export_range(1, 3) var inventory_height: int = 1
