extends SceneTree
## Opt-in traversability contracts for the same persisted terrain/collider.
func _initialize() -> void:
	call_deferred("validate")
func validate() -> void:
	var spike: Terrain3DSpike = load("res://source/common/gameplay/maps/terrain3d_spike/terrain_spike.tscn").instantiate()
	root.add_child(spike)
	spike.animate_preview = false
	var map: RID = spike.get_world_3d().navigation_map
	NavigationServer3D.map_set_cell_size(map,0.125)
	var start := Vector3(13,spike.terrain.data.get_height(Vector3(13,0,14)),14)
	var hill := Vector3(18.5,spike.terrain.data.get_height(Vector3(18.5,0,27.5)),27.5)
	for step: int in 60:
		await physics_frame
		if not NavigationServer3D.map_get_path(map,start,hill,true).is_empty(): break
	var path := NavigationServer3D.map_get_path(map,start,hill,true)
	assert(path.size()>1 and path[-1].distance_to(hill)<0.5,"flat ground connects to gentle hill")
	var steep := Vector3(35,spike.terrain.data.get_height(Vector3(35,0,30)),30)
	var nearest := NavigationServer3D.map_get_closest_point(map,steep)
	assert(nearest.distance_to(steep)>0.4,"steep slope is excluded by agent slope filter")
	var underwater := Vector3(58,spike.terrain.data.get_height(Vector3(58,0,32)),32)
	var shore_path := NavigationServer3D.map_get_path(map,start,underwater,true)
	assert(shore_path.size()>1 and spike.terrain.data.get_height(shore_path[-1])>-0.5,"path stops on land before submerged shore")
	var dog_path := NavigationServer3D.map_get_path(map,spike.mob.position,hill,true)
	assert(dog_path.size()>1,"production mob receives terrain route")
	var index: int = 0
	for step: int in 480:
		await physics_frame
		if index>=dog_path.size(): break
		var offset: Vector3 = dog_path[index]-spike.mob.position
		var planar := Vector2(offset.x,offset.z)
		if planar.length()<0.5: index+=1
		spike.mob.simulate_mob(1.0/60.0,planar.normalized(),Time.get_ticks_msec())
	assert(spike.mob.position.distance_to(hill)<1.0 and spike.mob.is_on_floor(),"production mob follows baked route without falling")
	print("TERRAIN_NAV_OK: flat/hill path, steep exclusion, shore boundary and production mob at ",spike.mob.position)
	quit()
