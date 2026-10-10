class_name FirstRegionGraybox
extends Node3D
## One authored prototype region; metres, XZ ground plane. No spawn framework.
const HUB := Vector3(0, 0.1, 20)
const BLACKSMITH := Vector3(-6, 0, 14)
const METIN_POINTS: Array[Vector3] = [Vector3(-24,0,-20), Vector3(16,0,-44), Vector3(-20,0,-78), Vector3(10,0,-92)]
const ZONE_CENTERS: Array[Vector3] = [Vector3(-16,0,-10), Vector3(8,0,-46), Vector3(-12,0,-82)]
const ZONE_NAMES: Array[String] = ["Outskirts", "Old Road", "Stone Hollow"]

func player_spawn(index: int = 0) -> Vector3:
	return HUB + Vector3(-3 + index % 5 * 1.5, 0, 0)

func _ready() -> void:
	# Land ends at x=26; the water remains a visual/material test, not swimming.
	_box("Land", Vector3(-11,-0.25,-36), Vector3(74,0.5,144), Color("626b59"))
	_box("NorthRidge", Vector3(-11,3,-108), Vector3(74,6,1), Color("555d60"))
	_box("SouthRidge", Vector3(-11,3,36), Vector3(74,6,1), Color("555d60"))
	_box("WestRidge", Vector3(-48,3,-36), Vector3(1,6,144), Color("555d60"))
	_box("ShoreBoundary", Vector3(26,0.5,-36), Vector3(0.5,1,144), Color("8d907c"))
	_surface("Water", Vector3(37,-0.1,-36), Vector3(22,0.08,144), Color("467d91"))
	_surface("Beach", Vector3(23,0.012,-36), Vector3(5,0.02,143), Color("ac9c7a"))
	_surface("HubSquare", Vector3(0,0.015,20), Vector3(20,0.03,20), Color("8d8980"))
	var route: Array[Vector3] = [HUB, ZONE_CENTERS[0], ZONE_CENTERS[1], ZONE_CENTERS[2], Vector3(-32,0,-46), Vector3(-32,0,10), HUB]
	for i: int in route.size() - 1: _road(route[i], route[i+1], 5.0, Color("9a8c70"))
	# A direct north route and a coast-side cut connect the bends in the main loop.
	_road(Vector3(0,0,10), Vector3(0,0,-80), 2.5, Color("807960"))
	_road(Vector3(8,0,-46), Vector3(20,0,-52), 2.5, Color("807960"))
	_road(Vector3(20,0,-52), Vector3(20,0,-68), 2.5, Color("807960"))
	_road(Vector3(20,0,-68), Vector3(-12,0,-82), 2.5, Color("807960"))
	_box("Forge", Vector3(-11,2.5,21), Vector3(6,5,8), Color("75645c"))
	_box("Storehouse", Vector3(11,3,23), Vector3(7,6,10), Color("716957"))
	_box("ForgeChimney", Vector3(-12,5,24), Vector3(1.5,5,1.5), Color("4b4c4c"))
	_box("WestWatchtower", Vector3(-36,5,-70), Vector3(5,10,5), Color("69717c"))
	_box("HollowShrine", Vector3(-12,3,-99), Vector3(10,6,4), Color("777083"))
	# Camera cases: close walls, pillars, a lintel and rocky corners.
	_box("ArchLeft", Vector3(3,2,-36), Vector3(2,4,2), Color("83827b"))
	_box("ArchRight", Vector3(13,2,-36), Vector3(2,4,2), Color("83827b"))
	_box("ArchLintel", Vector3(8,4.5,-36), Vector3(12,1,2), Color("83827b"))
	_box("RockWest", Vector3(-25,2,-34), Vector3(8,4,9), Color("58616a"))
	_box("RockEast", Vector3(15,2.5,-62), Vector3(6,5,8), Color("58616a"))
	_box("HollowWall", Vector3(-24,2,-90), Vector3(3,4,12), Color("58616a"))
	for i: int in ZONE_CENTERS.size():
		_surface("Zone%d" % i, ZONE_CENTERS[i] + Vector3(0,0.035,0), Vector3(14,0.02,14), [Color("74825e"),Color("9a865e"),Color("8b6d68")][i])
		_label(ZONE_NAMES[i], ZONE_CENTERS[i] + Vector3(0,3,5))
	for i: int in METIN_POINTS.size():
		var marker := Marker3D.new()
		marker.name = "MetinSpawn%d" % (i+1)
		marker.position = METIN_POINTS[i]
		add_child(marker)
		_surface("MetinPad%d" % i, marker.position + Vector3(0,0.06,0), Vector3(3,0.04,3), Color("b39b61"))
		_label("Metin site %d" % (i+1), marker.position + Vector3(0,1.5,0))
	_label("Hub / Blacksmith", HUB + Vector3(0,3,4))
	_label("Shore / water test", Vector3(23,2,-18))
	# Five-metre ticks along the direct route make scale visible.
	for z: int in range(-100, 31, 5):
		_surface("ScaleTick%d" % (z+100), Vector3(0,0.055,z), Vector3(2.5,0.01,0.08), Color("bab49b"))

func _road(start: Vector3, end: Vector3, width: float, color: Color) -> void:
	var offset: Vector3 = end - start
	var road: Node3D = _surface("Road", (start+end)*0.5 + Vector3(0,0.04,0), Vector3(width,0.02,offset.length()), color)
	road.rotation.y = atan2(offset.x, offset.z)

func _box(id: String, center: Vector3, size: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	body.name = id
	body.position = center
	body.collision_layer = 17 if id == "Land" else 1
	body.collision_mask = 0
	var collider := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collider.shape = shape
	body.add_child(collider)
	add_child(body)
	_mesh(body,size,color)

func _surface(id: String, center: Vector3, size: Vector3, color: Color) -> Node3D:
	var node := Node3D.new()
	node.name = id
	node.position = center
	add_child(node)
	_mesh(node,size,color)
	return node

func _mesh(parent: Node3D, size: Vector3, color: Color) -> void:
	if GameMode.is_world_server(): return
	var visual := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	visual.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.9
	visual.material_override = material
	parent.add_child(visual)

func _label(text: String, point: Vector3) -> void:
	if GameMode.is_world_server(): return
	var label := Label3D.new()
	label.text = text
	label.position = point
	label.font_size = 28
	label.pixel_size = 0.008
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(label)
