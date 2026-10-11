class_name CombatTraceResolver
extends RefCounted
## One broadphase, then actor-local capsule distance tests. No bones on World.
const MAX_CANDIDATES := 256

static func candidates(space: PhysicsDirectSpaceState3D, trace: CombatTraceDefinition, actor: Transform3D) -> Array[Dictionary]:
	var box := trace.bounds()
	var shape := BoxShape3D.new()
	shape.size = box.size
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = actor * Transform3D(Basis.IDENTITY,box.get_center())
	query.collision_mask = 4
	return space.intersect_shape(query,MAX_CANDIDATES)

static func hits_capsule(trace: CombatTraceDefinition, actor: Transform3D, feet: Vector3, target_radius: float, height: float, bottom_offset: float = 0.0) -> bool:
	var local_feet := actor.affine_inverse() * feet
	if local_feet.z > target_radius: return false # Basic melee does not hit fully behind the actor.
	var bounds := trace.bounds().grow(target_radius)
	if local_feet.x < bounds.position.x or local_feet.x > bounds.end.x or local_feet.z < bounds.position.z or local_feet.z > bounds.end.z: return false
	var target_min_y := local_feet.y+bottom_offset
	var target_max_y := target_min_y+height
	var center := Vector3(local_feet.x,0,local_feet.z)
	var radius_squared := pow(trace.radius+target_radius+trace.sweep_padding(),2)
	for i: int in range(1,trace.samples.size()):
		var previous := trace.samples[i-1]
		var current := trace.samples[i]
		var interval := trace.vertical_interval(previous,current)
		if interval.y < target_min_y or target_max_y < interval.x: continue
		if _near_xz(previous.base,previous.tip,center,radius_squared) or _near_xz(current.base,current.tip,center,radius_squared): return true
		# Keep the same nine rails and half-spacing XZ padding; Y is a separate gate.
		for rail: int in 9:
			var weight := rail/8.0
			if _near_xz(previous.base.lerp(previous.tip,weight),current.base.lerp(current.tip,weight),center,radius_squared): return true
	return false

static func _near_xz(a: Vector3, b: Vector3, center: Vector3, radius_squared: float) -> bool:
	a.y = 0
	b.y = 0
	var points := Geometry3D.get_closest_points_between_segments(a,b,center,center)
	return points[0].distance_squared_to(points[1]) <= radius_squared
