class_name SpikeCharacter3D
extends CharacterBody3D
## The server owns physics; clients interpolate its snapshots.

const SPEED: float = 5.0
const GRAVITY: float = 20.0
var target_position: Vector3
var target_yaw: float = 0.0
var has_snapshot: bool = false
var visual: MeshInstance3D
var weapon_definition_id: String = ""
var _weapon: Node3D

func setup(display_name: String, tint: Color) -> void:
	collision_layer = 2
	collision_mask = 1
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	var shape := CollisionShape3D.new()
	shape.shape = capsule
	shape.position.y = 0.9
	add_child(shape)
	visual = MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = capsule.radius
	mesh.height = capsule.height
	visual.mesh = mesh
	visual.position.y = 0.9
	var material := StandardMaterial3D.new()
	material.albedo_color = tint
	material.roughness = 0.8
	visual.material_override = material
	add_child(visual)
	var label := Label3D.new()
	label.text = display_name
	label.position.y = 2.25
	label.font_size = 48
	label.pixel_size = 0.012
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	add_child(label)
	# A small forward marker makes turning readable without an animated model.
	var marker := MeshInstance3D.new()
	var marker_mesh := BoxMesh.new()
	marker_mesh.size = Vector3(0.12, 0.12, 0.35)
	marker.mesh = marker_mesh
	marker.position = Vector3(0, 1.1, -0.4)
	add_child(marker)

func simulate(delta: float, direction: Vector2) -> void:
	velocity.x = direction.x * SPEED
	velocity.z = direction.y * SPEED
	velocity.y = -0.5 if is_on_floor() else velocity.y - GRAVITY * delta
	if direction.length_squared() > 0.001:
		rotation.y = atan2(-direction.x, -direction.y)
	move_and_slide()

func apply_snapshot(next_position: Vector3, yaw: float) -> void:
	if not has_snapshot or position.distance_to(next_position) > 5.0:
		position = next_position
		rotation.y = yaw
	target_position = next_position
	target_yaw = yaw
	has_snapshot = true

func interpolate(delta: float) -> void:
	if not has_snapshot:
		return
	var weight: float = 1.0 - exp(-20.0 * delta)
	position = position.lerp(target_position, weight)
	rotation.y = lerp_angle(rotation.y, target_yaw, weight)

func set_weapon(definition_id: String) -> void:
	if weapon_definition_id == definition_id:
		return
	weapon_definition_id = definition_id
	if _weapon != null:
		_weapon.free()
		_weapon = null
	if ItemDefinitions.get_definition(StringName(definition_id)) == null:
		return
	_weapon = Node3D.new()
	_weapon.name = "Weapon"
	_weapon.position = Vector3(0.55, 0.9, -0.15)
	add_child(_weapon)
	_weapon_part(Vector3(0, 0.5, 0), Vector3(0.12, 0.75, 0.06), Color("c6d7df"))
	_weapon_part(Vector3(0, 0.1, 0), Vector3(0.35, 0.07, 0.1), Color("bb964b"))
	_weapon_part(Vector3(0, -0.06, 0), Vector3(0.09, 0.25, 0.08), Color("694c36"))

func _weapon_part(center: Vector3, dimensions: Vector3, tint: Color) -> void:
	var part := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = dimensions
	part.mesh = box
	part.position = center
	var material := StandardMaterial3D.new()
	material.albedo_color = tint
	part.material_override = material
	_weapon.add_child(part)
