class_name WeaponItem
extends GearItem
## Registry display/serialized metadata only. Runtime items use ItemDefinition/ItemInstance.
## These fields do not implement equipment, mastery, cooldowns or USE effects.

@export var category: StringName
@export_range(0, 5) var capacity: int = 0
@export var right_hand_scene: PackedScene
@export var left_hand_scene: PackedScene
@export var sprite_offset: Vector2 = Vector2.ZERO
