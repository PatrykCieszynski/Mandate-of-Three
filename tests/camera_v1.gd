extends Node3D
## Bounded headless contracts, no balance/animation/pixel expectations.
var rig: MandateCamera3D
func block(center: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = center
	body.collision_layer = 1
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	add_child(body)
	return body

func _ready() -> void:
	block(Vector3(0,-0.25,0), Vector3(100,0.5,100))
	var wall: StaticBody3D = block(Vector3(0,3,3), Vector3(12,6,0.5))
	rig = MandateCamera3D.new()
	rig.settings = preload("res://source/client/camera/camera_v1.tres").duplicate(true)
	rig.settings.auto_align_enabled = false
	add_child(rig)
	await get_tree().physics_frame
	await get_tree().physics_frame
	rig.update_camera(1.0/60.0, Vector3.ZERO, true)
	var requested: float = rig.desired_distance
	assert(rig.movement_direction(Vector2.UP).is_equal_approx(Vector2.UP), "Default view maps W to world forward")
	assert(rig.resolved_distance < requested, "Wall retracts boom")
	assert(rig.camera.global_position.z < 2.75 - rig.settings.collision_radius, "Sphere stays in front of wall")
	assert(rig.desired_distance == requested, "Collision does not overwrite requested zoom")
	# Walking toward a wall with the camera on the free side must not collapse
	# the boom into the player's body. This also exercises a clamped follow pivot.
	var near_wall := Vector3(0,0,3.61)
	for i: int in 180: rig.update_camera(1.0/60.0, near_wall, true)
	assert(rig.resolved_distance > rig.settings.min_distance, "Facing a nearby wall retains the free rear camera")
	var eye: Vector3 = near_wall + Vector3.UP * rig.settings.pivot_height
	assert(rig._safe_motion(eye, Vector3(0,0,-2)).length() > 0, "Near-wall pivot sweep has a nonzero safe fraction")
	var clamped_pivot: Vector3 = eye + rig._safe_motion(eye, Vector3(0,0,-2))
	assert(rig._safe_motion(clamped_pivot, Vector3(0,2,4)).length() > 1, "Outward cast from a clamped pivot does not collapse")
	rig.update_camera(1.0/60.0, Vector3.ZERO, true)
	for i: int in 180: rig.update_camera(1.0/60.0, Vector3.ZERO, true)
	# Actual screen picking continues through the same Camera3D after orbit/zoom.
	var pick := StaticBody3D.new()
	pick.position = Vector3(0,1,0)
	pick.collision_layer = 8
	var pick_shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	pick_shape.shape = capsule
	pick.add_child(pick_shape)
	add_child(pick)
	await get_tree().physics_frame
	wall.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var obstructed: float = rig.resolved_distance
	rig.update_camera(1.0/60.0, Vector3.ZERO, true)
	assert(rig.resolved_distance > obstructed and rig.resolved_distance < requested, "Unobstructed return is damped")
	for i: int in 180: rig.update_camera(1.0/60.0, Vector3.ZERO, true)
	assert(absf(rig.resolved_distance-requested) < 0.01, "Return restores requested distance")
	rig.orbit_by(Vector2(700,10000))
	assert(rig.desired_pitch == rig.settings.max_pitch)
	rig.orbit_by(Vector2(0,-20000))
	assert(rig.desired_pitch == rig.settings.min_pitch)
	rig.zoom_by(-10000)
	assert(rig.desired_distance == rig.settings.min_distance)
	var old_position: Vector3 = rig.camera.global_position
	rig.update_camera(1.0/60.0, Vector3.ZERO, true)
	assert(not old_position.is_equal_approx(rig.camera.global_position), "Orbit and zoom update presentation")
	for i: int in 180: rig.update_camera(1.0/60.0, Vector3.ZERO, true)
	assert(rig.camera.global_position.y >= rig.settings.collision_radius, "Low pitch does not enter terrain")
	rig.zoom_by(10000)
	assert(rig.desired_distance == rig.settings.max_distance)
	rig.desired_pitch = 40
	rig.desired_yaw = PI * 0.5
	for i: int in 180: rig.update_camera(1.0/60.0, Vector3.ZERO, true)
	assert(rig.movement_direction(Vector2.UP).is_equal_approx(Vector2.LEFT), "W follows rendered camera yaw")
	assert(rig.movement_direction(Vector2.RIGHT).is_equal_approx(Vector2.UP), "D follows camera right")
	assert(is_equal_approx(rig.movement_direction(Vector2(0.3,-0.4)).length(), 0.5), "Pitch preserves analog input magnitude")
	assert(rig.movement_direction(Vector2.ZERO) == Vector2.ZERO)
	var pixel: Vector2 = rig.camera.unproject_position(pick.global_position)
	var origin: Vector3 = rig.camera.project_ray_origin(pixel)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + rig.camera.project_ray_normal(pixel) * 100, 8)
	assert(get_world_3d().direct_space_state.intersect_ray(query).get("collider") == pick, "NPC picking remains correct after orbit and zoom")
	var yaw_before: float = rig.desired_yaw
	for i: int in 120: rig.update_camera(1.0/60.0, Vector3(-i/60.0,0,0), true)
	assert(rig.desired_yaw == yaw_before, "Movement does not automatically rotate default camera")
	var teleport := Vector3(20,0,20)
	rig.update_camera(1.0/60.0, teleport, true)
	assert(rig.camera.global_position.distance_to(teleport) < rig.settings.max_distance + 3, "Teleport resets follow lag")
	var query_shape := PhysicsShapeQueryParameters3D.new()
	query_shape.shape = SphereShape3D.new()
	query_shape.shape.radius = rig.settings.collision_radius
	query_shape.transform = Transform3D(Basis.IDENTITY,rig.camera.global_position)
	query_shape.collision_mask = 1
	assert(get_world_3d().direct_space_state.intersect_shape(query_shape).is_empty(), "Resolved camera volume is outside scenery")
	# Snapshot cadence must be filtered more strongly than one follow lerp,
	# without changing authoritative character interpolation. No pixel assertions.
	var subject := SpikeCharacter3D.new()
	add_child(subject)
	subject.apply_snapshot(Vector3(-10,0,-20), 0)
	for i: int in 180: rig.update_camera(1.0/120.0, subject.position, true)
	var reference: Vector3 = subject.position
	var reference_low: float = INF
	var reference_high: float = 0
	var low_speed: float = INF
	var high_speed: float = 0
	for frame: int in 480:
		if frame % 6 == 0: subject.apply_snapshot(Vector3(-10+frame/120.0*3,0,-20), 0)
		subject.interpolate(1.0/120.0)
		var reference_before: Vector3 = reference
		reference = reference.lerp(subject.position, 1.0-exp(-rig.settings.position_smoothing/120.0))
		var before: Vector3 = rig.camera.global_position
		rig.update_camera(1.0/120.0, subject.position, true)
		if frame > 240:
			var speed: float = rig.camera.global_position.distance_to(before)*120
			var reference_speed: float = reference.distance_to(reference_before)*120
			reference_low = minf(reference_low,reference_speed)
			reference_high = maxf(reference_high,reference_speed)
			low_speed = minf(low_speed,speed)
			high_speed = maxf(high_speed,speed)
	assert(low_speed > 0 and high_speed-low_speed < (reference_high-reference_low)*0.5, "20Hz snapshot pulses are suppressed without stopping follow")
	print("CAMERA_V1_OK: pitch/zoom bounds, sphere collision, smooth return, terrain, picking, independent follow, teleport and snapshot cadence")
	get_tree().quit()
