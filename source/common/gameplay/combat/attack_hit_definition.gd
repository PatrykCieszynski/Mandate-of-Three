class_name AttackHitDefinition
extends Resource
@export var damage_multiplier: float = 1.0
@export var reaction: HitReaction.Type = HitReaction.Type.FLINCH
@export var reaction_duration: float = 0.18
@export var get_up_duration: float = 0.4
@export var knockback_distance: float = 0.0
@export var interrupt_attack: bool = false
@export var impact_ms: int = 120
@export var recovery_ms: int = 450
@export var presentation_clip: StringName = &"attack_1"
