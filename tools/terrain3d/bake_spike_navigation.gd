extends SceneTree
## One map's native source adapter; does not change production navigation ownership.
const DIR := "res://source/common/gameplay/maps/terrain3d_spike"
func _initialize() -> void:
	call_deferred("bake")
func bake() -> void:
	var packed: PackedScene = load(DIR+"/terrain_spike.tscn")
	var spike: Terrain3DSpike = packed.instantiate()
	root.add_child(spike)
	spike.animate_preview = false
	var nav := NavigationMesh.new()
	nav.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav.geometry_collision_mask = 1
	nav.agent_radius = 0.5
	nav.agent_height = 1.2
	nav.agent_max_climb = 0.2
	nav.agent_max_slope = 45.0
	nav.cell_size = 0.125
	nav.cell_height = 0.1
	nav.filter_baking_aabb = AABB(Vector3(2,-3,2),Vector3(59,13,59))
	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(nav,source,spike)
	var native_faces: PackedVector3Array = spike.terrain.generate_nav_mesh_source_geometry(nav.filter_baking_aabb,true)
	assert(not native_faces.is_empty(),"Terrain3D navigable control map supplies faces")
	source.add_faces(native_faces,Transform3D.IDENTITY)
	NavigationServer3D.bake_from_source_geometry_data(nav,source)
	assert(nav.get_polygon_count()>0,"native terrain nav bake")
	assert(ResourceSaver.save(nav,DIR+"/navigation.res")==OK)
	nav = load(DIR+"/navigation.res")
	(spike.get_node("Navigation") as NavigationRegion3D).navigation_mesh = nav
	NavigationServer3D.map_set_cell_size(spike.get_world_3d().navigation_map,nav.cell_size)
	# Persist normally so editor Save/Reopen keeps its baked NavigationMesh.
	var saved := PackedScene.new()
	assert(saved.pack(spike)==OK and ResourceSaver.save(saved,DIR+"/terrain_spike.tscn")==OK)
	print("TERRAIN_NAV_BAKE_OK: ",native_faces.size()/3," source triangles, ",nav.get_polygon_count()," nav polygons")
	quit()
