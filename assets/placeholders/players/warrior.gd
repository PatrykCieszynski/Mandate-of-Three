extends Node3D
func set_tint(tint: Color) -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = tint
	material.roughness = 0.8
	$Body.material_override = material
