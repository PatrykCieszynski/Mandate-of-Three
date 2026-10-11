class_name BasicAttackCombos
extends RefCounted
const BASE: BasicAttackComboDefinition = preload("res://source/common/gameplay/combat/warrior_basic_4.tres")
const COMBO_5: BasicAttackComboDefinition = preload("res://source/common/gameplay/combat/warrior_combo_5.tres")
const COMBO_6: BasicAttackComboDefinition = preload("res://source/common/gameplay/combat/warrior_combo_6.tres")
const ALL: Array[BasicAttackComboDefinition] = [BASE,COMBO_5,COMBO_6]
static func resolve(mode: StringName, enabled: bool, skill: int) -> BasicAttackComboDefinition:
	if mode != &"onehand_sword": return null
	if not enabled or skill == 0: return BASE
	return COMBO_6 if skill >= 2 else COMBO_5
static func animation_keys() -> Array[StringName]:
	var keys: Array[StringName] = []
	for combo: BasicAttackComboDefinition in ALL:
		for step: BasicAttackStepDefinition in combo.steps:
			if not keys.has(step.animation_key): keys.append(step.animation_key)
	return keys
