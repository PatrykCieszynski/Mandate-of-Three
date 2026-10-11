class_name CombatHitResult
extends RefCounted
var damage: int = 0
var reaction: HitReaction.Type = HitReaction.Type.NONE
var duration: float = 0.0
var get_up_duration: float = 0.0
var knockback_distance: float = 0.0
var interrupts_attack: bool = false
func presentation() -> Dictionary:
	return {"damage":damage,"reaction":reaction,"duration":duration,"get_up_duration":get_up_duration}
