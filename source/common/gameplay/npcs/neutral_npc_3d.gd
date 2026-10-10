class_name NeutralNpc3D
extends StaticBody3D
## Stable map-instance identity; no NodePath/object reference crosses the wire.
@export var instance_id: String
@export var definition: NpcDefinition
@export var interactable: bool = true
@export var disabled_services: Array[StringName] = []

static func valid_instance_id(value: String) -> bool:
	var regex := RegEx.new()
	regex.compile("^[a-z0-9][a-z0-9_-]{0,79}$")
	return regex.search(value) != null

func service_enabled(id: StringName) -> bool:
	return interactable and id not in disabled_services

func _ready() -> void:
	collision_layer = 8
	collision_mask = 0
	# Development visual keyed by visual_id; final model resolver can replace this.
	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.4
	shape.height = 1.8
	collision.shape = shape
	collision.position.y = 0.9
	add_child(collision)
	var visual := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.4
	mesh.height = 1.8
	visual.mesh = mesh
	visual.position.y = 0.9
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("ba9353")
	visual.material_override = material
	add_child(visual)
	var label := Label3D.new()
	label.text = definition.display_name if definition != null else "Invalid NPC"
	label.position.y = 2.1
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 32
	label.modulate = Color("88e580")
	add_child(label)
