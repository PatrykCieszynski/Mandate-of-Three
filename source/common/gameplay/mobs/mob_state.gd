class_name MobState
extends RefCounted
## Stable compact wire values; one enum shared by simulation and presentation.
enum Value { IDLE = 0, WANDER = 1, CHASE = 2, ATTACK = 3, RETURN = 4, DEAD = 5, DISABLED = 6 }
const NAMES: Dictionary[int, String] = {
	Value.IDLE:"IDLE", Value.WANDER:"WANDER", Value.CHASE:"CHASE", Value.ATTACK:"ATTACK",
	Value.RETURN:"RETURN", Value.DEAD:"DEAD", Value.DISABLED:"DISABLED",
}
static func name_for(value: int) -> String:
	return NAMES.get(value,"DISABLED")
static func from_wire(value: int) -> Value:
	return value if NAMES.has(value) else Value.DISABLED
