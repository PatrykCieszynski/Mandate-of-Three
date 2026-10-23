class_name VendorRecipeDefinition
extends Resource
## Pure content: all requirements of one recipe consume disjoint units.
@export var recipe_id: StringName
@export var priority: int = 0
@export var inputs: Array[Dictionary] = []
@export var reward_pool: StringName
@export var reward_quantity: int = 1
