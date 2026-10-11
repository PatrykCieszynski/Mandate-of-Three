class_name BasicAttackStepDefinition
extends AttackHitDefinition
## Timing and requested reaction reuse the existing hit contract.
@export var animation_key: StringName
@export var hit_start_ms: int = 0
@export var hit_end_ms: int = 0
@export var combat_trace: CombatTraceDefinition
