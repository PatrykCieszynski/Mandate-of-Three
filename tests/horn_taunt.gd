extends Node3D
## Server horn targets whole eligible packs without stealing aggro.
func entry(mob: MobDefinition, count: int) -> MobSpawnEntry:
	var result := MobSpawnEntry.new()
	result.mob = mob
	result.count = count
	return result

func _ready() -> void:
	assert(HornTaunt.LIMITS[HornTaunt.BASIC] == 15)
	assert(HornTaunt.LIMITS[HornTaunt.IMPROVED] == 25)
	assert(HornTaunt.LIMITS[HornTaunt.ADVANCED] == 40)
	assert(HornTaunt.RANGE_METERS == 12.0 and HornTaunt.COOLDOWN_MS == 4000)
	var horn := HornTaunt.new()
	assert(horn.tier_for(1) == HornTaunt.BASIC)
	assert(not horn.set_tier(1, &"invalid"))
	assert(horn.set_tier(1, HornTaunt.IMPROVED))
	assert(horn.tier_for(1) == HornTaunt.IMPROVED)
	horn.clear_peer(1)
	assert(horn.tier_for(1) == HornTaunt.BASIC)
	var world := preload("res://tests/fixtures/world3d/test_arena.tscn").instantiate() as GameWorld3D
	add_child(world)
	world.set_physics_process(false)
	world.combat_endpoint.set_physics_process(false)
	for id: int in world.mob_system.mobs.keys():
		world.mob_system.remove_mob(id)
	world.mob_system.packs.clear()
	var server := WorldServer.new()
	WorldServer.curr = server
	var player := PlayerResource.new()
	player.player_id = 1
	server.connected_players[1] = player
	var body := PlayerActor3D.new()
	body.position = Vector3.ZERO
	world.add_child(body)
	world.characters[1] = body
	var dog: MobDefinition = preload("res://source/common/gameplay/mobs/wild_dog.tres")
	var first := world.mob_system.create_pack([entry(dog, 10)], Vector3(2, 0, 0), 0, 0, 20, 0)
	var second := world.mob_system.create_pack([entry(dog, 10)], Vector3(5, 0, 0), 0, 0, 20, 0)
	var third := world.mob_system.create_pack([entry(dog, 10)], Vector3(9, 0, 0), 0, 0, 20, 0)
	assert(world.mob_system.taunt_nearby_packs(1, 12.0, 15) == 10)
	for id: int in first.actor_ids:
		assert(world.mob_system.mobs[id].target_peer == 1)
	for id: int in second.actor_ids:
		assert(world.mob_system.mobs[id].target_peer == 0)
	for id: int in third.actor_ids:
		assert(world.mob_system.mobs[id].target_peer == 0)
	assert(world.mob_system.taunt_nearby_packs(1, 12.0, 15) == 10)
	assert(world.mob_system.taunt_nearby_packs(1, 12.0, 15) == 10)
	world.free()
	WorldServer.curr = null
	server.free()
	print("HORN_TAUNT_OK: tiers, cap, complete packs and no aggro theft")
	get_tree().quit()
