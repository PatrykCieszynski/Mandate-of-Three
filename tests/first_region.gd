extends Node3D
## Navigation/content contracts only; no exact graybox layout or balance assertions.
func _ready() -> void:
	var region_entry := preload("res://source/common/gameplay/maps/instance/instance_collection/first_region.tres")
	var world := load(region_entry.map_path).instantiate() as GameWorld3D
	add_child(world)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var region: FirstRegionGraybox = world.region
	# The production region activates authored loot (the tiny test arena retains
	# the old guaranteed-sword fixture). Resolve without a DB to check safe RAM drops.
	assert(world.kill_rewards._region_key == &"first_region")
	var death := MobDeathResult.new()
	death.mob_key = &"forest_wolf"
	death.category = &"beast"
	death.spawn_base_loot_rolls = 4
	death.position = Vector3(-14,0,-15)
	death.reward_owner = 0
	death.timestamp_ms = Time.get_ticks_msec()
	for roll_index: int in 30:
		world.kill_rewards.spawn_ordinary_rewards(death)
	assert(world.currency_endpoint.ground.size() == 30, "One Yang pile per mob, not per item roll")
	for uid: String in world.ground_loot.drops:
		var drop: Dictionary = world.ground_loot.drops[uid]
		var definition := ItemDefinitions.get_definition(StringName(drop.definition_id))
		assert(definition != null and drop.amount >= 1 and drop.amount <= definition.stack_limit)
		assert(GroundLootSystem.prepare_claim_item(uid, 1, drop) != null, "Generated ground item can be claimed using its frozen payload")
	var points := region.find_children("*","MobSpawnPoint3D",true,false)
	var expected: int = 0
	for point: MobSpawnPoint3D in points:
		assert(point.valid())
		for entry: MobSpawnEntry in point.members: expected += entry.count
	assert(region != null and expected > 0 and world.mob_system.mobs.size() == expected)
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
