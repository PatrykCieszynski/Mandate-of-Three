class_name GearItem
extends Item
## Registry display/serialized metadata only. Runtime items use ItemDefinition/ItemInstance.
## These fields do not implement equipment, mastery, cooldowns or USE effects.

@export var slot: ItemSlot
@export_range(0, 99, 1.0, "suffix:lvl") var required_level: int = 0
@export var base_modifiers: Array[StatModifier]
