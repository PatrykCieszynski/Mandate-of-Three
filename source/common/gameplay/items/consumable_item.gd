class_name ConsumableItem
extends Item
## Registry display/serialized metadata only. Runtime items use ItemDefinition/ItemInstance.
## These fields do not implement equipment, mastery, cooldowns or USE effects.

@export var heal_amount: int
@export var mana_amount: int
@export var buff_stat: StringName = &""
@export var buff_amount: float = 0.0
@export var buff_duration_s: float = 0.0
@export var shared_cooldown_ms: int = 6000
@export var cooldown_category: StringName = &"potion"
@export var use_freeze_ms: int = 900
@export var default_charges: int = 1
