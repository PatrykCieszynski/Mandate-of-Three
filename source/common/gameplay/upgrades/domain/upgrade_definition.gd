class_name UpgradeDefinition
extends Resource
@export var upgrade_id: StringName
@export var item_definition_id: StringName
@export var from_level: int = 0
@export var to_level: int = 1
@export var yang_cost: int = 1000
@export var material_definition_id: StringName
@export var material_amount: int = 1
@export var success_rate: int = 100

func validation_errors() -> Array[String]:
	var errors: Array[String] = []
	if not GameplayContentId.valid(upgrade_id): errors.append("invalid_id")
	var item: ItemDefinition = ItemDefinitions.get_definition(item_definition_id)
	var material: ItemDefinition = ItemDefinitions.get_definition(material_definition_id)
	if item == null or item.equipment_slot == &"": errors.append("unknown_item")
	if material == null or material.equipment_slot != &"" or item_definition_id == material_definition_id: errors.append("invalid_material")
	if from_level != 0 or to_level != 1 or success_rate != 100: errors.append("unsupported_upgrade")
	if yang_cost <= 0 or yang_cost > 9000000000000000 or material_amount <= 0 or material_amount > 999: errors.append("invalid_cost")
	return errors
