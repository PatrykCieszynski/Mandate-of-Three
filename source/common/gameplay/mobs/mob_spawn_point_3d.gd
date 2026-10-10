class_name MobSpawnPoint3D
extends Marker3D
## Authored composition and radii, consumed only by the authoritative World.
@export var members: Array[MobSpawnEntry] = []
@export var spawn_radius: float = 5.0
@export var wander_radius: float = 8.0
@export var leash_radius: float = 18.0
@export var respawn_seconds: float = 15.0
func valid() -> bool:
	if members.is_empty() or not is_finite(spawn_radius) or not is_finite(wander_radius) or not is_finite(leash_radius) or not is_finite(respawn_seconds): return false
	if spawn_radius < 0 or wander_radius < spawn_radius or leash_radius <= wander_radius or respawn_seconds <= 0: return false
	for member: MobSpawnEntry in members:
		if member == null or not member.valid(): return false
	return true
