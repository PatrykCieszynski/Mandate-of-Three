extends Node3D
## Server horn selects nearest individual mobs without stealing aggro.
func entry(mob: MobDefinition, count: int) -> MobSpawnEntry:
	var result := MobSpawnEntry.new()
	result.mob = mob
	result.count = count
	return result

func _ready() -> void:
	var horn := HornTaunt.new()
	assert(horn.tier_for(1) == HornTaunt.BASIC)
	assert(not horn.set_tier(1, &"invalid"))
	assert(horn.set_tier(1, HornTaunt.IMPROVED))
	assert(horn.tier_for(1) == HornTaunt.IMPROVED)
	horn.clear_peer(1)
	assert(horn.tier_for(1) == HornTaunt.BASIC)
	var server := WorldServer.new()
	WorldServer.curr = server
	var player := PlayerResource.new()
	player.player_id = 1
	player.current_peer_id = 7
	server.connected_players[7] = player
	server.player_id_to_peer_id[player.player_id] = 7
	var manager := InstanceManagerServer.new()
	manager.world_server = server
	server.instance_manager = manager
	var world := preload("res://tests/fixtures/world3d/test_arena.tscn").instantiate() as GameWorld3D
	add_child(world)
	world.set_physics_process(false)
	world.combat_endpoint.set_physics_process(false)
	for id: int in world.mob_system.mobs.keys():
		world.mob_system.remove_mob(id)
	world.mob_system.packs.clear()
	var body := PlayerActor3D.new()
	body.position = Vector3.ZERO
	world.add_child(body)
	world.characters[7] = body
	var dog: MobDefinition = preload("res://source/common/gameplay/mobs/wild_dog.tres")
	var first := world.mob_system.create_pack([entry(dog, 10)], Vector3(2, 0, 0), 0, 0, 20, 0)
	var second := world.mob_system.create_pack([entry(dog, 10)], Vector3(5, 0, 0), 0, 0, 20, 0)
	var third := world.mob_system.create_pack([entry(dog, 10)], Vector3(9, 0, 0), 0, 0, 20, 0)
	assert(world.mob_system.taunt_nearby_mobs(7, 12.0, 15) == 15)
	for id: int in first.actor_ids:
		assert(world.mob_system.mobs[id].target_peer == 7)
	for id: int in second.actor_ids.slice(0, 5):
		assert(world.mob_system.mobs[id].target_peer == 7)
	for id: int in second.actor_ids.slice(5):
		assert(world.mob_system.mobs[id].target_peer == 0)
	for id: int in third.actor_ids:
		assert(world.mob_system.mobs[id].target_peer == 0)
	assert(world.mob_system.taunt_nearby_mobs(7, 12.0, 15) == 15)
	assert(world.mob_system.taunt_nearby_mobs(7, 12.0, 15) == 0)
	# Exercise the actual action entry point with real service/transfer guards.
	# PG owners must not disable a live AI action; no DB work is needed here.
	server.inventory_runtime = RefCounted.new()
	server.wallet_runtime = RefCounted.new()
	assert(not world.services.mutations_allowed(7))
	for mob: MobActor3D in world.mob_system.mobs.values():
		mob.ai_state = MobState.Value.IDLE
		mob.target_peer = 0
	var engaged: MobActor3D = world.mob_system.mobs[third.actor_ids[0]]
	engaged.ai_state = MobState.Value.CHASE
	engaged.target_peer = 8
	var now := 10000
	body.alive = false
	assert(horn.try_use(7, now, world.mob_system, world.services).error == "player")
	body.alive = true
	body.hp = 0
	assert(horn.try_use(7, now, world.mob_system, world.services).error == "player")
	body.hp = body.max_hp
	assert(horn.try_use(99, now, world.mob_system, world.services).error == "player")
	manager.transfers.attempts[7] = {"phase": "countdown", "session": player}
	assert(horn.try_use(7, now, world.mob_system, world.services).error == "transfer_pending")
	manager.transfers.attempts.clear()
	# Rejected attempts must not consume cooldown or recruit anything.
	assert(world.mob_system.mobs[first.actor_ids[0]].target_peer == 0)
	var used := horn.try_use(7, now, world.mob_system, world.services)
	assert(used.ok and used.attracted == used.cap)
	assert(used.cap == HornTaunt.LIMITS[HornTaunt.BASIC])
	assert(engaged.target_peer == 8)
	assert(horn.try_use(7, now + HornTaunt.COOLDOWN_MS - 1, world.mob_system, world.services).error == "cooldown")
	assert(world.mob_system.mobs[third.actor_ids[1]].target_peer == 0)
	assert(horn.try_use(7, now + HornTaunt.COOLDOWN_MS, world.mob_system, world.services).ok)
	assert(engaged.target_peer == 8)
	server.inventory_runtime = null
	server.wallet_runtime = null
	server.instance_manager = null
	manager.free()
	world.free()
	WorldServer.curr = null
	server.free()
	print("HORN_TAUNT_OK: individual selection, PG runtime, cooldown, dead/missing player, transfer and no aggro theft")
	get_tree().quit()
