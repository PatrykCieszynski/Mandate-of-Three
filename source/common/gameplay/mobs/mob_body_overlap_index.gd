class_name MobBodyOverlapIndex
extends RefCounted
## A cheap, server-only broadphase for upright, unscaled capsule movement bodies.
## The old physics query is still used if an unsupported collider is present.
## Rebuilt once per physics frame, not once per player.
const CELL_SIZE := 4.0
var _cells: Dictionary = {}
var _max_mob_radius := 0.0
var _needs_fallback := false

static func _cell(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x / CELL_SIZE), floori(position.z / CELL_SIZE))

static func _upright_unit_basis(node: Node3D) -> bool:
	var basis := node.global_transform.basis
	return absf(basis.y.x) < 0.0001 and absf(basis.y.z) < 0.0001 and 		absf(basis.x.length_squared() - 1.0) < 0.0001 and 		absf(basis.y.length_squared() - 1.0) < 0.0001 and 		absf(basis.z.length_squared() - 1.0) < 0.0001

static func capsule_overlap(a_center: Vector3, a_radius: float, a_height: float, b_center: Vector3, b_radius: float, b_height: float) -> bool:
	# Exact upright capsule-vs-capsule overlap in world space: distance
	# between the two vertical line segments, then add the cap radii.
	var a_half_segment := maxf(0.0, a_height * 0.5 - a_radius)
	var b_half_segment := maxf(0.0, b_height * 0.5 - b_radius)
	var y_gap := maxf(0.0, absf(a_center.y - b_center.y) - a_half_segment - b_half_segment)
	var x_gap := a_center.x - b_center.x
	var z_gap := a_center.z - b_center.z
	var radius := a_radius + b_radius
	return x_gap * x_gap + y_gap * y_gap + z_gap * z_gap < radius * radius

func rebuild(mobs: Dictionary) -> void:
	_cells.clear()
	_max_mob_radius = 0.0
	_needs_fallback = false
	for dog: MobActor3D in mobs.values():
		if not is_instance_valid(dog) or not dog.is_inside_tree() or dog.collision_layer & 4 == 0:
			continue
		if dog.movement_collider == null or dog.movement_collider.disabled or not dog.movement_collider.shape is CapsuleShape3D or not _upright_unit_basis(dog.movement_collider):
			_needs_fallback = true
			continue
		var capsule := dog.movement_collider.shape as CapsuleShape3D
		_max_mob_radius = maxf(_max_mob_radius, capsule.radius)
		var cell := _cell(dog.movement_collider.global_position)
		if not _cells.has(cell):
			_cells[cell] = []
		_cells[cell].append(dog)

func overlapping(player: PlayerActor3D) -> Variant:
	# Null signals that the caller must use the original physics query.
	if _needs_fallback or player.combat_collider == null or player.combat_collider.disabled or 		not player.combat_collider.shape is CapsuleShape3D or not _upright_unit_basis(player.combat_collider):
		return null
	var capsule := player.combat_collider.shape as CapsuleShape3D
	var center := player.combat_collider.global_position
	# +1 cell conservatively covers all possible capsule intersections,
	# including a body whose center lies in an adjacent boundary cell.
	var reach := ceili((capsule.radius + _max_mob_radius) / CELL_SIZE) + 1
	var origin := _cell(center)
	var overlaps: Array[PhysicsBody3D] = []
	for x: int in range(origin.x - reach, origin.x + reach + 1):
		for z: int in range(origin.y - reach, origin.y + reach + 1):
			var cell := Vector2i(x, z)
			if not _cells.has(cell):
				continue
			for dog: MobActor3D in _cells[cell]:
				if not is_instance_valid(dog) or dog.collision_layer & 4 == 0 or dog.movement_collider.disabled:
					continue
				var shape := dog.movement_collider.shape as CapsuleShape3D
				if capsule_overlap(center, capsule.radius, capsule.height, dog.movement_collider.global_position, shape.radius, shape.height):
					overlaps.append(dog)
	return overlaps
