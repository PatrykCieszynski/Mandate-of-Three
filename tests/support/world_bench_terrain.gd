extends RefCounted
## Disposable native flat heightfield, four regions around the global origin.
## No file import/generation/save and no edits to the authored terrain scene.
static func add_to(world: Node3D, region_size: int = 64, full_collision: bool = true) -> Node3D:
	assert(ClassDB.class_exists("Terrain3D"),"Terrain benchmark needs the pinned local addon")
	var terrain=ClassDB.instantiate("Terrain3D")
	terrain.name="BenchTerrain"
	# Before native material/data initialization; never migrate populated regions.
	terrain.region_size=region_size
	world.add_child(terrain)
	var camera:=Camera3D.new();terrain.add_child(camera);camera.position=Vector3(0,20,0)
	terrain.set_camera(camera)
	terrain.collision.mode=3 if full_collision else 0
	terrain.collision.layer=17;terrain.collision.mask=0
	for x: int in [-1,0]:
		for z: int in [-1,0]:
			assert(terrain.data.add_region_blank(Vector2i(x,z),false)!=null)
	terrain.data.update_maps()
	terrain.set_physics_process(false)
	assert(terrain.data.get_region_count()==4)
	return terrain
