class_name Item
extends Resource
## Registry display/serialized metadata only. Runtime items use ItemDefinition/ItemInstance.
## These fields do not implement equipment, mastery, cooldowns or USE effects.

@export var item_name: StringName = &"ItemDefault"
@export var item_icon: Texture2D
@export_multiline var description: String
@export var holdable: bool = true
@export var is_currency: bool = false
@export var can_trade: bool = false
@export var market_minimum_price: int = 0
@export_range(0, 99, 1.0) var stack_limit: int = 0
@export var tags: PackedStringArray = []

## The old stack model is not used by authoritative Inventory or Wallet.
