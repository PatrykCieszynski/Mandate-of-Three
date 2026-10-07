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
var _hit_tween: Tween
var _swing_tween: Tween
var _base_tint: Color
var alive: bool = true
var _name_label: Label3D
var _display_name: String = ""

func setup(display_name: String, tint: Color) -> void:
	_display_name = display_name
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
	_base_tint = tint
	material.roughness = 0.8
	visual.material_override = material
	add_child(visual)
	var label := Label3D.new()
	_name_label = label
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

func set_level(level: int) -> void:
	if _name_label != null: _name_label.text = "Lv %d · %s" % [level, _display_name]

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

func play_hit() -> void:
	if visual == null: return
	var material: StandardMaterial3D = visual.material_override
	if _hit_tween != null: _hit_tween.kill()
	var original: Color = _base_tint if _base_tint != Color(0, 0, 0, 1) else Color("986943")
	material.albedo_color = Color("ffdddd")
	_hit_tween = create_tween()
	_hit_tween.tween_property(material, "albedo_color", original, 0.18)

func set_alive(value: bool) -> void:
	if alive == value: return
	alive = value
	if visual == null: return
	visual.rotation.z = 0 if alive else PI * 0.5
	visual.position.y = 0.9 if alive else 0.4
	if _weapon != null: _weapon.visible = alive

func play_swing(stage: int) -> void:
	if _weapon != null:
		if _swing_tween != null: _swing_tween.kill()
		_weapon.rotation.z = -1.4 if stage != 2 else 1.4
		_swing_tween = create_tween()
		_swing_tween.tween_property(_weapon, "rotation:z", 1.4 if stage != 2 else -1.4, 0.18)
		_swing_tween.tween_property(_weapon, "rotation:z", 0.0, 0.12)
	# Brief sweeping ribbon; presentation only, never the damage authority.
	var vertices := PackedVector3Array()
	for i: int in 16:
		var first: float = deg_to_rad(-65.0 + i * 130.0 / 16)
		var second: float = deg_to_rad(-65.0 + (i + 1) * 130.0 / 16)
		var a := Vector3(sin(first), 0.65, -cos(first)) * Vector3(1.9, 1, 1.9)
		var b := Vector3(sin(first), 0.65, -cos(first)) * Vector3(2.3, 1, 2.3)
		var c := Vector3(sin(second), 0.65, -cos(second)) * Vector3(2.3, 1, 2.3)
		var d := Vector3(sin(second), 0.65, -cos(second)) * Vector3(1.9, 1, 1.9)
		vertices.append_array(PackedVector3Array([a, b, c, a, c, d]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var slash := MeshInstance3D.new()
	slash.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1, 0.8, 0.25, 0.8) if stage == 3 else Color(0.6, 0.9, 1, 0.6)
	slash.material_override = material
	add_child(slash)
	var tween := create_tween()
	tween.tween_property(material, "albedo_color:a", 0.0, 0.25)
	tween.tween_callback(slash.queue_free)
