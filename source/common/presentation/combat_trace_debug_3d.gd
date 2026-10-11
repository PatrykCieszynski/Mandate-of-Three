class_name CombatTraceDebug3D
extends MeshInstance3D
## Dev client only. Geometry comes from the same baked Resource as World.
var step: BasicAttackStepDefinition
var targets: Array[Dictionary] = []
var legacy := false
func configure(value: BasicAttackStepDefinition, candidates: Array[Dictionary], show_legacy: bool = false) -> void:
	step = value
	targets = candidates
	legacy = show_legacy
	redraw()
func mark_hits(results: Array[Dictionary]) -> void:
	for target: Dictionary in targets:
		target["hit"] = false
		for result: Dictionary in results:
			if result.id == target.id: target.hit = true
	redraw()
func redraw() -> void:
	if step == null or step.combat_trace == null: return
	var lines := ImmediateMesh.new()
	lines.surface_begin(Mesh.PRIMITIVE_LINES)
	var trace := step.combat_trace
	if legacy:
		for i: int in 32:
			var a := deg_to_rad(-65.0+i*130.0/32)
			var b := deg_to_rad(-65.0+(i+1)*130.0/32)
			_line(lines,Vector3(sin(a),0.5,-cos(a))*Vector3(2.4,1,2.4),Vector3(sin(b),0.5,-cos(b))*Vector3(2.4,1,2.4),Color.ORANGE)
		_line(lines,Vector3(0,.5,0),Vector3(sin(deg_to_rad(-65)),.5/2.4,-cos(deg_to_rad(-65)))*2.4,Color.ORANGE)
		_line(lines,Vector3(0,.5,0),Vector3(sin(deg_to_rad(65)),.5/2.4,-cos(deg_to_rad(65)))*2.4,Color.ORANGE)
	else:
		for i: int in trace.samples.size():
			var sample := trace.samples[i]
			_line(lines,sample.base,sample.tip,Color.YELLOW)
			if i > 0:
				var previous := trace.samples[i-1]
				for rail: int in 9: _line(lines,previous.base.lerp(previous.tip,rail/8.0),sample.base.lerp(sample.tip,rail/8.0),Color(0.2,.7,1,.6))
			_ring(lines,sample.tip,trace.radius,Color.CYAN)
		var box := trace.bounds()
		for axis: int in 3:
			for first: int in 2:
				for second: int in 2:
					var a := box.position
					a[(axis+1)%3] += first*box.size[(axis+1)%3]
					a[(axis+2)%3] += second*box.size[(axis+2)%3]
					var b := a
					b[axis] += box.size[axis]
					_line(lines,a,b,Color(.5,.5,1,.5))
	for target: Dictionary in targets:
		var feet: Vector3 = target.position
		if target.get("predicted",false):
			var horizontal := Vector3(feet.x,0,feet.z)
			target.hit = (horizontal.length() <= 2.4 and absf(feet.y) <= 1.2 and (horizontal.length_squared() < .001 or horizontal.normalized().dot(Vector3.FORWARD) >= cos(deg_to_rad(65)))) if legacy else CombatTraceResolver.hits_capsule(trace,Transform3D.IDENTITY,feet,target.radius,target.height)
		var color := Color.LIME_GREEN if target.get("hit",false) else Color.INDIAN_RED
		var radius: float = target.radius
		var bottom := feet+Vector3.UP*radius
		var top := feet+Vector3.UP*maxf(radius,target.height-radius)
		_ring(lines,bottom,radius,color)
		_ring(lines,top,radius,color)
		for side: Vector3 in [Vector3.LEFT,Vector3.RIGHT,Vector3.FORWARD,Vector3.BACK]: _line(lines,bottom+side*radius,top+side*radius,color)
		# Vertical great circles also show the capsule's hemispherical ends.
		for axis: Vector3 in [Vector3.RIGHT,Vector3.FORWARD]:
			for i: int in 12:
				var a := i*PI/12
				var b := (i+1)*PI/12
				_line(lines,top+(axis*cos(a)+Vector3.UP*sin(a))*radius,top+(axis*cos(b)+Vector3.UP*sin(b))*radius,color)
				_line(lines,bottom+(axis*cos(a)-Vector3.UP*sin(a))*radius,bottom+(axis*cos(b)-Vector3.UP*sin(b))*radius,color)
	lines.surface_end()
	mesh = lines
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material_override = material
static func _line(lines: ImmediateMesh, a: Vector3, b: Vector3, color: Color) -> void:
	lines.surface_set_color(color)
	lines.surface_add_vertex(a)
	lines.surface_add_vertex(b)
static func _ring(lines: ImmediateMesh, center: Vector3, radius: float, color: Color) -> void:
	for i: int in 16:
		var a := i*TAU/16
		var b := (i+1)*TAU/16
		_line(lines,center+Vector3(cos(a),0,sin(a))*radius,center+Vector3(cos(b),0,sin(b))*radius,color)
