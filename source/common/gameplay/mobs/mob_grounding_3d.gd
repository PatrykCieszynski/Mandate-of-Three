extends RefCounted
## W4a candidate only: floor/heightfield sampling, independent of AI and damage.
## A short foot ray deliberately does not implement capsule support, stairs,
## moving-platform attachment or arbitrary penetration recovery.
const STEP_UP: float=0.4
const DROP: float=0.75
const FOOT_CLEARANCE: float=0.002

func resolve(body: CharacterBody3D, next: Vector3) -> Dictionary:
	var from:=Vector3(next.x,body.global_position.y+STEP_UP,next.z)
	var to:=Vector3(next.x,body.global_position.y-DROP,next.z)
	var query:=PhysicsRayQueryParameters3D.create(from,to,16,[body.get_rid()])
	var hit:=body.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or hit.normal.y<=0: return {}
	# Allow a bounded descent; the native body can descend steeper ground too.
	# Steep ascent remains blocked rather than snapping up an unwalkable face.
	if hit.normal.y<cos(body.floor_max_angle) and hit.position.y>body.global_position.y+FOOT_CLEARANCE: return {}
	return {"position":Vector3(next.x,hit.position.y+FOOT_CLEARANCE,next.z)}
