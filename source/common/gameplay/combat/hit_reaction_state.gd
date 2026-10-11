class_name HitReactionState
extends RefCounted
## Only an authoritative knockdown installs an action lock. Re-hits do not extend it.
var down_until_ms: int = 0
var get_up_until_ms: int = 0
func locked(now: int) -> bool:
	return now < get_up_until_ms
func apply(result: CombatHitResult, now: int) -> void:
	if result.reaction != HitReaction.Type.KNOCKDOWN or locked(now): return
	down_until_ms = now + int(result.duration * 1000)
	get_up_until_ms = down_until_ms + int(result.get_up_duration * 1000)
func clear() -> void:
	down_until_ms = 0
	get_up_until_ms = 0
func snapshot(now: int) -> Array[int]:
	return [maxi(0,down_until_ms-now),maxi(0,get_up_until_ms-maxi(now,down_until_ms))]
