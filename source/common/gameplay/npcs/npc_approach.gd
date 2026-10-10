class_name NpcApproach
extends RefCounted
## Client movement intention only. Server physics and interaction remain authoritative.
var target_id: String = ""
var path := PackedVector3Array()
var waypoint: int = 0

func start(instance_id: String) -> void:
	cancel()
	target_id = instance_id

func cancel() -> void:
	target_id = ""
	path.clear()
	waypoint = 0

func set_path(points: PackedVector3Array) -> void:
	path = points
	waypoint = 0

func step(position: Vector3, target: Vector3, radius: float, manual: Vector2) -> Dictionary:
	if manual.length_squared() > 0.001:
		cancel()
		return {"direction": manual, "interact": ""}
	if target_id.is_empty(): return {"direction": Vector2.ZERO, "interact": ""}
	# Leave margin for snapshot latency and the player's vertical floor offset.
	if position.distance_to(target) <= maxf(0.1, radius - 0.4):
		var arrived: String = target_id
		cancel()
		return {"direction": Vector2.ZERO, "interact": arrived}
	while waypoint < path.size():
		var offset: Vector3 = path[waypoint] - position
		var flat := Vector2(offset.x, offset.z)
		if flat.length() > 0.3:
			return {"direction": flat.normalized(), "interact": ""}
		waypoint += 1
	return {"direction": Vector2.ZERO, "interact": ""}
