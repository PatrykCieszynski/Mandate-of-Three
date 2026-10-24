class_name QuestItem
extends Item
## Registry display/serialized metadata only. Runtime items use ItemDefinition/ItemInstance.
## These fields do not implement equipment, mastery, cooldowns or USE effects.

@export var quest_id: int = 0
@export var auto_bind: bool = true

func _init() -> void:
	can_trade = false
	stack_limit = 1
