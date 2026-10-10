class_name MobSnapshot
extends RefCounted
## Full-snapshot wire contract; no server AI/persistence metadata.
## Keep values stable on both peers when extending this record.
enum Field { ID, POSITION, YAW, HP, STATE, MOB_KEY, SOURCE_METIN, COUNT }
enum State { IDLE, WANDER, CHASE, ATTACK, RETURN, DEAD, DISABLED }
const STATE_NAMES: Array[String] = ["IDLE", "WANDER", "CHASE", "ATTACK", "RETURN", "DEAD", "DISABLED"]

static func capture(mob: SpikeWildDog3D) -> Array:
	var wire_state := STATE_NAMES.find(mob.ai_state)
	assert(wire_state >= 0, "Unknown mob AI state")
	return [mob.mob_instance_id, mob.position, mob.rotation.y, mob.hp,
		wire_state, mob.mob_key, mob.source_metinstone_id]

static func state_name(value: int) -> String:
	return STATE_NAMES[value]
