class_name BasicAttackStepDefinition
extends AttackHitDefinition
## Timing and requested reaction reuse the existing hit contract.
@export var animation_key: StringName
@export var hit_start_ms: int = 0
@export var hit_end_ms: int = 0
@export var combat_trace: CombatTraceDefinition
@export var motion_duration_ms: int = 1000
@export var advance_distance: float = 0.0

# Canonical MSA input timings at Attack Speed 100. Geometry stays unscaled.
@export var preinput_ms: int = 0
@export var direct_input_ms: int = 0
@export var input_limit_ms: int = 0

func scaled_timing(ratio: float) -> Dictionary:
	return {"impact":int(ceil(impact_ms/ratio)),"end":int(ceil(recovery_ms/ratio)),
		"preinput":int(ceil(preinput_ms/ratio)),"direct":int(ceil(direct_input_ms/ratio)),
		"limit":int(ceil(input_limit_ms/ratio)),"ratio":ratio,"motion":int(ceil(motion_duration_ms/ratio))}
