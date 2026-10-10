class_name MobPackRuntime
extends RefCounted
## Map-local aggro membership and per-member replacement tickets, never DB state.
var pack_instance_id: int
var anchor: Vector3
var spawn_radius: float
var wander_radius: float
var leash_radius: float
var respawn_seconds: float
var respawn_enabled: bool = true
var source_metinstone_id: String = ""
var expires_at: int = 0
var actor_ids: Array[int] = []
var replacements: Array[Dictionary] = []
var rng := RandomNumberGenerator.new()
func random_point(radius: float) -> Vector3:
	var angle := rng.randf_range(0,TAU)
	var distance := sqrt(rng.randf()) * radius
	return anchor + Vector3(cos(angle),0,sin(angle)) * distance
