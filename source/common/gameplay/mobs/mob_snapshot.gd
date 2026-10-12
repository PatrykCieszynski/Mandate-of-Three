class_name MobSnapshot
extends RefCounted
## Full-snapshot wire contract; no server AI/persistence metadata.
## Keep values stable on both peers when extending this record.
enum Field { ID = 0, POSITION = 1, YAW = 2, HP = 3, STATE = 4, MOB_KEY = 5, SOURCE_METIN = 6, DOWN_REMAINING = 7, GET_UP_REMAINING = 8, COUNT = 9 }
static func capture(mob: MobActor3D, now: int = Time.get_ticks_msec()) -> Array:
	var wire_state: int = mob.ai_state
	assert(MobState.NAMES.has(wire_state), "Unknown mob AI state")
	var lock := mob.hit_reaction.snapshot(now)
	return [mob.mob_instance_id, mob.position, mob.rotation.y, mob.hp,
		wire_state, mob.mob_key, mob.source_metinstone_id, lock[0], lock[1]]

static func state_name(value: int) -> String:
	return MobState.name_for(value)
