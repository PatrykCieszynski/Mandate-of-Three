class_name RegionWater
extends MeshInstance3D
## Client-only surface; shoreline collision remains authored in First Region.
var animation_enabled: bool = true
var surface_time: float = 0.0

func _ready() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(22,144)
	plane.subdivide_width = 43
	plane.subdivide_depth = 287
	mesh = plane
	material_override = preload("res://source/client/world_visuals/water/region_water_material.tres").duplicate() as ShaderMaterial
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	extra_cull_margin = 0.15
	_build_bed()

func _process(delta: float) -> void:
	if animation_enabled: surface_time += delta
	if material_override is ShaderMaterial:
		(material_override as ShaderMaterial).set_shader_parameter("surface_time",surface_time)

func _build_bed() -> void:
	# Minimal submerged slope provides actual depth; not a terrain/shore rebuild.
	var bed := MeshInstance3D.new()
	bed.name = "SubmergedBed"
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-11,0.03,-72),Vector3(-11,0.03,72),Vector3(-9,-0.45,-72),Vector3(-9,-0.45,72),
		Vector3(11,-3.2,-72),Vector3(11,-3.2,72)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP,Vector3.UP,Vector3.UP,Vector3.UP,Vector3.UP,Vector3.UP])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0,2,1,1,2,3,2,4,3,3,4,5])
	var bed_mesh := ArrayMesh.new()
	bed_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	bed.mesh = bed_mesh
	var sand := StandardMaterial3D.new()
	sand.albedo_color = Color("77745b")
	sand.roughness = 1.0
	bed.material_override = sand
	add_child(bed)
