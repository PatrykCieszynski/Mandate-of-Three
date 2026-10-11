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

static func hits_capsule(trace: CombatTraceDefinition, actor: Transform3D, feet: Vector3, target_radius: float, height: float) -> bool:
	var local_feet := actor.affine_inverse() * feet
	if local_feet.z > target_radius: return false # Basic melee does not hit fully behind the actor.
	var bounds := trace.bounds().grow(target_radius)
	if local_feet.y+height < bounds.position.y or local_feet.y > bounds.end.y: return false
	if local_feet.x < bounds.position.x or local_feet.x > bounds.end.x or local_feet.z < bounds.position.z or local_feet.z > bounds.end.z: return false
	var bottom := local_feet + Vector3.UP*target_radius
	var top := local_feet + Vector3.UP*maxf(target_radius,height-target_radius)
	var radius_squared := pow(trace.radius+target_radius+trace.sweep_padding(),2)
	for i: int in trace.samples.size():
		var current := trace.samples[i]
		if _near(current.base,current.tip,bottom,top,radius_squared): return true
		if i == 0: continue
		var previous := trace.samples[i-1]
		# Swept interior, not only the boundary of the blade's motion.
		# Nine rails plus half-spacing padding conservatively cover the ruled strip.
		for rail: int in 9:
			var weight := rail/8.0
			if _near(previous.base.lerp(previous.tip,weight),current.base.lerp(current.tip,weight),bottom,top,radius_squared): return true
	return false

static func _near(a: Vector3, b: Vector3, c: Vector3, d: Vector3, radius_squared: float) -> bool:
	var points := Geometry3D.get_closest_points_between_segments(a,b,c,d)
	return points[0].distance_squared_to(points[1]) <= radius_squared
