class_name Actor3D
extends CharacterBody3D
## Shared movement body/reaction/interpolation plumbing, without player policy.
const GRAVITY: float = 20.0
const KNOCKBACK_DAMPING: float = 8.0
var knockback_velocity: Vector3 = Vector3.ZERO
var hit_reaction := HitReactionState.new()
var reaction_profile: HitReactionProfile = HitReactionProfiles.NORMAL
var target_position: Vector3
var target_yaw: float = 0.0
var has_snapshot: bool = false
var alive: bool = true
var combat_collider: CollisionShape3D

func apply_knockback(direction: Vector3, distance: float) -> void:
	if not direction.is_finite() or not is_finite(distance) or distance <= 0: return
	var planar := Vector3(direction.x,0,direction.z)
	if planar.length_squared() < 0.0001: return
	# Integral of v0 * exp(-damping*t) is distance. No position mutation here.
	knockback_velocity = planar.normalized() * distance * KNOCKBACK_DAMPING

func knockback_active() -> bool:
	return knockback_velocity.length_squared() > 0.0025

func damp_knockback(delta: float) -> Vector3:
	if delta <= 0: return Vector3.ZERO
	var decay := exp(-KNOCKBACK_DAMPING * delta)
	# Average velocity keeps travel independent of physics tick duration.
	var motion := knockback_velocity * (1.0-decay) / (KNOCKBACK_DAMPING*delta)
	knockback_velocity *= decay
	if not knockback_active(): knockback_velocity = Vector3.ZERO
	return motion

func apply_snapshot(next_position: Vector3, yaw: float) -> void:
	if not has_snapshot or position.distance_to(next_position) > 5.0:
		position = next_position
		rotation.y = yaw
	target_position = next_position
	target_yaw = yaw
	has_snapshot = true

func combat_radius() -> float: return (combat_collider.shape as CapsuleShape3D).radius

func combat_height() -> float: return (combat_collider.shape as CapsuleShape3D).height

func combat_bottom_offset() -> float: return combat_collider.position.y-combat_height()/2.0

func interpolate(delta: float) -> void:
	if not has_snapshot: return
	var weight: float = 1.0-exp(-20.0*delta)
	position = position.lerp(target_position,weight)
	rotation.y = lerp_angle(rotation.y,target_yaw,weight)
