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
	assert(rig.resolved_distance < requested, "Wall retracts boom")
	assert(rig.camera.global_position.z < 2.75 - rig.settings.collision_radius, "Sphere stays in front of wall")
	assert(rig.desired_distance == requested, "Collision does not overwrite requested zoom")
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
	rig.orbit_by(Vector2(700,-10000))
	assert(rig.desired_pitch == rig.settings.max_pitch)
	rig.orbit_by(Vector2(0,20000))
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
	print("CAMERA_V1_OK: pitch/zoom bounds, sphere collision, smooth return, terrain, picking, independent follow and teleport")
	get_tree().quit()
