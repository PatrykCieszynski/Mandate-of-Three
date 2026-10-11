class_name SwordTrail3D
extends MeshInstance3D
## Short world-space ribbon from the rendered weapon; no gameplay geometry.
const LIFETIME := 0.10
const MAX_SAMPLES := 10
var points: Array[Dictionary] = []
var clock := 0.0
var _ribbon := ImmediateMesh.new()
func _ready() -> void:
	mesh = _ribbon
	top_level = true
	global_transform = Transform3D.IDENTITY
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material_override = material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
func sample(delta: float, base: Vector3, tip: Vector3, active: bool) -> void:
	clock += delta
	while not points.is_empty() and clock-float(points[0].time) > LIFETIME: points.pop_front()
	if active:
		points.append({"base":base,"tip":tip,"time":clock})
		if points.size() > MAX_SAMPLES: points.pop_front()
	visible = points.size() > 1
	if not visible: return
	_ribbon.clear_surfaces()
	_ribbon.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i: int in range(1,points.size()):
		var a: Dictionary = points[i-1]
		var b: Dictionary = points[i]
		for vertex: Array in [[a.base,a.time],[a.tip,a.time],[b.tip,b.time],[a.base,a.time],[b.tip,b.time],[b.base,b.time]]:
			_ribbon.surface_set_color(Color(.7,.9,1,.35*(1-(clock-float(vertex[1]))/LIFETIME)))
			_ribbon.surface_add_vertex(vertex[0])
	_ribbon.surface_end()
func clear() -> void:
	points.clear()
	visible = false
	_ribbon.clear_surfaces()
