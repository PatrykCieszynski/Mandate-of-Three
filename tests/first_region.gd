extends Node3D
## Navigation/content contracts only; no exact graybox layout or balance assertions.
func _ready() -> void:
	var region_entry := preload("res://source/common/gameplay/maps/instance/instance_collection/first_region.tres")
	var world := load(region_entry.map_path).instantiate() as GameWorld3D
	add_child(world)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var region: FirstRegionGraybox = world.region
	var points := region.find_children("*","MobSpawnPoint3D",true,false)
	var expected: int = 0
	var counts: Dictionary[StringName, int] = {}
	for point: MobSpawnPoint3D in points:
		assert(point.valid())
		for entry: MobSpawnEntry in point.members:
			expected += entry.count
			assert(MobDefinitions.is_registered(entry.mob) and entry.mob.valid())
			assert(VisualResolver.paths(entry.mob.visual_id).size() == 3, "Mob visual must have local placeholder fallback")
			counts[entry.mob.mob_key] = int(counts.get(entry.mob.mob_key, 0)) + entry.count
	assert(region != null and expected == 104 and world.mob_system.mobs.size() == expected)
	assert(counts.get(&"forest_wolf", 0) == 20 and counts.get(&"dire_wolf", 0) == 3 and counts.get(&"wolf_alpha", 0) == 1)
	assert(counts.get(&"road_bandit", 0) == 20 and counts.get(&"bandit_raider", 0) == 13 and counts.get(&"bandit_captain_3d", 0) == 1)
	assert(counts.get(&"feral_dog", 0) == 28 and counts.get(&"hollow_hound", 0) == 18)
	assert(MobDefinitions.resolve(&"forest_wolf").category == &"beast")
	assert(MobDefinitions.resolve(&"road_bandit").category == &"humanoid")
	assert(MobDefinitions.resolve(&"wolf_alpha").rank == &"elite")
	assert(world.player_spawn().distance_to(FirstRegionGraybox.HUB) < 5)
	var map: RID = world.get_world_3d().navigation_map
	for i: int in 30:
		if NavigationServer3D.map_get_iteration_id(map) > 0 and not NavigationServer3D.map_get_path(map, world.player_spawn(), FirstRegionGraybox.BLACKSMITH, true).is_empty(): break
		await get_tree().physics_frame
	assert(NavigationServer3D.map_get_iteration_id(map) > 0, "Shared region navigation is ready")
	var destinations: Array[Vector3] = [FirstRegionGraybox.BLACKSMITH]
	destinations.append_array(FirstRegionGraybox.METIN_POINTS)
	for point: MobSpawnPoint3D in points:
		destinations.append(point.position)
		assert(point.position.distance_to(world.player_spawn()) > point.wander_radius + point.members.map(func(entry: MobSpawnEntry) -> float: return entry.mob.aggro_radius).max() + 5, "Hub is outside pack wander/aggro")
	for destination: Vector3 in destinations:
		var path := NavigationServer3D.map_get_path(map, world.player_spawn(), destination, true)
		assert(path.size() > 1 and path[path.size()-1].distance_to(destination) < 1, "NPC, mobs and Metin sites are reachable from hub")
	var shore: Dictionary = get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(24,0.5,0), Vector3(28,0.5,0), 1))
	assert(not shore.is_empty(), "Shore blocks entry into visual-only water")
	print("FIRST_REGION_OK: production scene, safe hub, connected navigation, mob profiles, Metin sites and shore boundary")
	get_tree().quit()
