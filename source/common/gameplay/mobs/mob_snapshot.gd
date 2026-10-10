class_name MobSnapshot
extends RefCounted
## Full-snapshot wire contract; no server AI/persistence metadata.
## Keep values stable on both peers when extending this record.
enum Field { ID = 0, POSITION = 1, YAW = 2, HP = 3, STATE = 4, MOB_KEY = 5, SOURCE_METIN = 6, COUNT = 7 }
enum State { IDLE = 0, WANDER = 1, CHASE = 2, ATTACK = 3, RETURN = 4, DEAD = 5, DISABLED = 6 }
const STATE_NAMES: Dictionary[int, String] = {
	State.IDLE: "IDLE", State.WANDER: "WANDER", State.CHASE: "CHASE",
	State.ATTACK: "ATTACK", State.RETURN: "RETURN", State.DEAD: "DEAD",
	State.DISABLED: "DISABLED",
}

static func capture(mob: SpikeWildDog3D) -> Array:
	var wire_state: int = State.get(mob.ai_state, -1)
	assert(wire_state >= 0, "Unknown mob AI state")
	return [mob.mob_instance_id, mob.position, mob.rotation.y, mob.hp,
		wire_state, mob.mob_key, mob.source_metinstone_id]

static func state_name(value: int) -> String:
	return STATE_NAMES.get(value, "DISABLED")
