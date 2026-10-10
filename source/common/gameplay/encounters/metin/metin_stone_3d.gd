class_name MetinStone3D
extends StaticBody3D
## Presentation/attack collider only. The encounter owns HP and lifecycle.
var hp_label: Label3D
func _ready() -> void:
	collision_layer = 4
	collision_mask = 0
	var collider := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.7
	shape.height = 2.8
	collider.shape = shape
	collider.position.y = 1.4
	add_child(collider)
	if GameMode.is_world_server(): return
	var visual := MeshInstance3D.new()
	var mesh := PrismMesh.new()
	mesh.size = Vector3(1.4,2.8,1.4)
	visual.mesh = mesh
	visual.position.y = 1.4
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("705487")
	material.emission_enabled = true
	material.emission = Color("301b49")
	visual.material_override = material
	add_child(visual)
	hp_label = Label3D.new()
	hp_label.position.y = 3.3
	hp_label.font_size = 30
	hp_label.pixel_size = 0.008
	hp_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(hp_label)
func present(title: String, hp: int, max_hp: int, active: bool) -> void:
	visible = active
	collision_layer = 4 if active else 0
	if hp_label != null: hp_label.text = "%s\n%d / %d" % [title,hp,max_hp]
