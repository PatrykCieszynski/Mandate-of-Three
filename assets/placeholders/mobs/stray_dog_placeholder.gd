extends Node3D
## Procedural visual only: no collision, physics or gameplay data.
func _ready() -> void:
	_part(Vector3(0, 0.5, 0), Vector3(0.65, 0.45, 0.95), Color("986943"))
	_part(Vector3(0, 0.65, -0.65), Vector3(0.4, 0.4, 0.45), Color("795033"))
	_part(Vector3(0, 0.57, -0.93), Vector3(0.26, 0.2, 0.2), Color("3a2d25"))
	for x: float in [-0.2, 0.2]:
		for z: float in [-0.3, 0.3]:
			_part(Vector3(x, 0.2, z), Vector3(0.13, 0.4, 0.14), Color("67462f"))
		_part(Vector3(x, 0.92, -0.65), Vector3(0.12, 0.25, 0.16), Color("493426"))
	_part(Vector3(0, 0.7, 0.65), Vector3(0.12, 0.12, 0.5), Color("67462f"))

func _part(center: Vector3, dimensions: Vector3, tint: Color) -> void:
	var part := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = dimensions
	part.mesh = box
	part.position = center
	var material := StandardMaterial3D.new()
	material.albedo_color = tint
	part.material_override = material
	add_child(part)
