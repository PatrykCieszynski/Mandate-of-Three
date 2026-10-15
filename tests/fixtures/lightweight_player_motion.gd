extends RefCounted
## EXPERIMENT-ONLY player controller for flat benchmark arenas.
## Keeps real PlayerActor3D state, combat shape and network contract but avoids
## CharacterBody3D.move_and_slide() and per-frame collision exceptions.
## Sweeps the existing player capsule against native static/mob broadphase.
## This is not a terrain-height, stairs, slopes or moving-platform solver.
var _sweep_query := PhysicsShapeQueryParameters3D.new()

func _sweep_axis(player: PlayerActor3D, movement: Vector3, collision_mask: int) -> void:
	if movement.length_squared() < 0.00000001:
		return
	_sweep_query.shape = player.combat_collider.shape
	_sweep_query.transform = player.combat_collider.global_transform
	_sweep_query.motion = movement
	_sweep_query.collision_mask = collision_mask
	_sweep_query.margin = 0.01
	var allowed: PackedFloat32Array = player.get_world_3d().direct_space_state.cast_motion(_sweep_query)
	if allowed.size() != 2:
		return
	player.position += movement * clampf(allowed[0], 0.0, 1.0)

func simulate(player: PlayerActor3D, delta: float, direction: Vector2) -> void:
	if not player.alive:
		player.velocity = Vector3.ZERO
		return
	if delta <= 0.0:
		return
	if player.hit_reaction.locked(Time.get_ticks_msec()) or player.knockback_active():
		direction = Vector2.ZERO
		player.cancel_attack_advance()
	# Valid input is clamped by the World; also protect direct fixture calls.
	direction = direction.limit_length()
	var attack_velocity: Vector3 = player._consume_attack_advance(delta)
	var displacement: Vector3 = player.damp_knockback(delta) + attack_velocity
	var planar := Vector2(direction.x * PlayerActor3D.SPEED + displacement.x,
		direction.y * PlayerActor3D.SPEED + displacement.z)
	player.velocity = Vector3(planar.x, 0.0, planar.y)
	if direction.length_squared() > 0.001:
		player.rotation.y = atan2(-direction.x, -direction.y)
	# Existing mob penetration only blocks movement further into a mob.
	# When escaping an overlap, ignore mob casts but keep scenery blocked.
	var overlaps: Array[PhysicsBody3D] = player._overlapping_mob_bodies()
	for mob: PhysicsBody3D in overlaps:
		var to_mob := mob.global_position - player.global_position
		if Vector2(planar.x, planar.y).dot(Vector2(to_mob.x, to_mob.z)) > 0.0001:
			planar = Vector2.ZERO
			player.velocity.x = 0.0
			player.velocity.z = 0.0
			break
	var mask := 1 if not overlaps.is_empty() else (1 | 4)
	# Two axis sweeps allow sliding along simple axis-aligned walls without
	# running Godot's CharacterBody3D solver; no gravity/ground snap here.
	_sweep_axis(player, Vector3(planar.x * delta, 0, 0), mask)
	_sweep_axis(player, Vector3(0, 0, planar.y * delta), mask)
