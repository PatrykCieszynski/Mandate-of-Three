extends "res://source/common/gameplay/mobs/mob_grounding_3d.gd"
## Map-owned, opt-in heightfield surface. No scheduling/cache or physics query.
## Terrain3D 1.0.2 uses GLOBAL coordinates, returns NaN for missing data/holes,
## and resets its local transform. Transformed terrain is unsupported here.
var _terrain: Node3D

func _init(terrain: Node3D) -> void:
	_terrain=terrain

func resolve(body: CharacterBody3D, next: Vector3) -> Dictionary:
	if not is_instance_valid(_terrain) or not _terrain.global_transform.is_equal_approx(Transform3D.IDENTITY): return {}
	var data=_terrain.get("data")
	if data==null: return {}
	var height: float=data.get_height(next)
	if not is_finite(height): return {}
	var rise:=height-body.global_position.y
	if rise>STEP_UP or rise < -DROP: return {}
	return {"position":Vector3(next.x,height+FOOT_CLEARANCE,next.z)}
