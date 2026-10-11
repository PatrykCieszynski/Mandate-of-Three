class_name BasicAttackComboDefinition
extends Resource
@export var combo_key: StringName
@export var weapon_mode: StringName = &"onehand_sword"
@export var steps: Array[BasicAttackStepDefinition] = []
@export var reset_ms: int = 1100
func valid() -> bool:
	if combo_key == &"" or steps.is_empty() or reset_ms <= 0: return false
	for step: BasicAttackStepDefinition in steps:
		if step == null or step.animation_key == &"" or step.impact_ms < 0 or step.recovery_ms <= step.impact_ms: return false
	return true
