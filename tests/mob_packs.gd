extends Node3D
## Small domain/physics contracts. No balance, pixel or animation timing checks.
func entry(mob: MobDefinition, count: int) -> MobSpawnEntry:
	var result := MobSpawnEntry.new()
	result.mob = mob
	result.count = count
	return result
func _ready() -> void:
	var wild: MobDefinition = preload("res://source/common/gameplay/mobs/wild_dog.tres")
	var feral: MobDefinition = preload("res://source/common/gameplay/mobs/feral_dog.tres")
	assert(wild.valid() and feral.valid())
	var profile_keys: Dictionary[StringName, bool] = {}
	for definition: MobDefinition in [
		MobDefinitions.FOREST_WOLF, MobDefinitions.DIRE_WOLF, MobDefinitions.WOLF_ALPHA,
		MobDefinitions.ROAD_BANDIT, MobDefinitions.BANDIT_RAIDER, MobDefinitions.BANDIT_CAPTAIN_3D
	]:
		assert(definition.valid() and MobDefinitions.is_registered(definition))
		assert(not profile_keys.has(definition.mob_key), "Duplicate mob family key")
		profile_keys[definition.mob_key] = true
		assert(VisualResolver.paths(definition.visual_id).size() == 3, "Optional local model must have owned placeholder")
	assert(profile_keys.size() == 6)
	assert(wild.category == &"beast" and feral.family == &"dogs")
	var invalid_category := wild.duplicate() as MobDefinition
	invalid_category.category = &"mystic"
	assert(not invalid_category.valid())
	invalid_category.category = &"beast"
	invalid_category.rank = &"rare"
	assert(not invalid_category.valid())
	invalid_category.rank = &"normal"
	invalid_category.family = &""
	assert(not invalid_category.valid())
	invalid_category.family = &"dogs"
	invalid_category.min_loot_rolls = 0
	assert(not invalid_category.valid())
	invalid_category.min_loot_rolls = 4
	invalid_category.max_loot_rolls = 3
	assert(not invalid_category.valid())
	invalid_category.min_loot_rolls = 1
	invalid_category.max_loot_rolls = 5
	assert(not invalid_category.valid())
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	var seen_counts: Dictionary[int,bool] = {}
	for iteration: int in 120:
		var count: int = wild.sample_spawn_loot_rolls(rng)
		assert(count >= 1 and count <= 3)
		seen_counts[count] = true
	assert(seen_counts.size() == 3, "Spawn count includes both range ends and the middle")
	assert(entry(wild,1).valid() and MobDefinitions.is_registered(wild))
	assert(not MobDefinitions.is_registered(null))
	var unregistered := wild.duplicate() as MobDefinition
	unregistered.mob_key = &"big_dog"
	assert(unregistered.valid() and not entry(unregistered,1).valid())
	var duplicate := wild.duplicate() as MobDefinition
	duplicate.max_hp = 999
	assert(duplicate.valid() and not entry(duplicate,1).valid())
	var invalid := wild.duplicate() as MobDefinition
	invalid.move_speed = NAN
	assert(not invalid.valid())
	invalid.move_speed = 1
	invalid.mob_key = &""
	assert(not invalid.valid())
	var server := WorldServer.new()
	WorldServer.curr = server
	var player := PlayerResource.new()
	player.player_id = 1
	server.connected_players[1] = player
	var world := preload("res://tests/fixtures/world3d/test_arena.tscn").instantiate() as GameWorld3D
	add_child(world)
	world.set_physics_process(false)
	world.combat_endpoint.set_physics_process(false)
	var combat := world.combat_endpoint
	for id: int in world.mob_system.mobs.keys(): world.mob_system.remove_mob(id)
	world.mob_system.packs.clear()
	assert(world.mob_system.create_pack([entry(wild,1),entry(unregistered,1)],Vector3.ZERO,2,3,10,1) == null)
	assert(world.mob_system.create_pack([entry(duplicate,1)],Vector3.ZERO,2,3,10,1) == null)
	assert(world.mob_system.packs.is_empty() and world.mob_system.mobs.is_empty(), "Invalid content cannot partially spawn a pack")
	var pack := world.mob_system.create_pack([entry(wild,10),entry(feral,4)],Vector3.ZERO,2,3,10,1)
	var unrelated := world.mob_system.create_pack([entry(wild,3)],Vector3(10,0,0),1,2,6,1)
	pack.rng.seed = 731
	var ids: Array[int] = pack.actor_ids.duplicate()
	assert(ids.size() == 14 and unrelated.pack_instance_id != pack.pack_instance_id)
	var wild_count: int = 0
	var feral_count: int = 0
	for id: int in ids:
		var mob := world.mob_system.mobs[id]
		assert(mob.mob_instance_id == id and mob.pack_instance_id == pack.pack_instance_id and mob.home == pack.anchor)
		assert(mob.presentation == null and mob.name_label == null and mob.hp_label == null and mob.find_children("*","Label3D",true,false).is_empty(), "World actors contain no presentation labels")
		assert(mob.definition.valid() and mob.move_speed == mob.definition.move_speed and mob.hp == mob.definition.max_hp)
		assert(mob.spawn_base_loot_rolls >= mob.definition.min_loot_rolls and mob.spawn_base_loot_rolls <= mob.definition.max_loot_rolls)
		assert(world.mob_system.horizontal_distance(mob.position,pack.anchor) <= pack.spawn_radius)
		assert(mob.find_children("*","NavigationAgent3D",true,false).is_empty() and mob.collision_mask == 16)
		if mob.mob_key == wild.mob_key: wild_count += 1
		if mob.mob_key == feral.mob_key: feral_count += 1
	assert(wild_count == 10 and feral_count == 4)
	var hero := PlayerActor3D.new()
	hero.position = Vector3(0,0,5)
	world.add_child(hero)
	world.characters[1] = hero
	world.characters[1].hp = 100
	await get_tree().physics_frame
	await get_tree().physics_frame
	# Same entry point used by melee and proximity; every live member reacts.
	world.mob_system.aggro_pack(world.mob_system.mobs[ids[0]].pack_instance_id,1)
	for id: int in ids: assert(world.mob_system.mobs[id].target_peer == 1 and world.mob_system.mobs[id].ai_state == MobState.Value.CHASE)
	for id: int in unrelated.actor_ids: assert(world.mob_system.mobs[id].target_peer == 0 and world.mob_system.mobs[id].ai_state == MobState.Value.IDLE)
	# Passive dog definitions ignore proximity; opt-in content still recruits its pack.
	for id: int in ids:
		world.mob_system.mobs[id].ai_state = MobState.Value.IDLE
		world.mob_system.mobs[id].target_peer = 0
	world.mob_system.mobs[ids[0]].position = pack.anchor
	world.mob_system.tick_mob(world.mob_system.mobs[ids[0]],1.0/60,0)
	for id: int in ids: assert(world.mob_system.mobs[id].ai_state == MobState.Value.IDLE and world.mob_system.mobs[id].target_peer == 0, "Passive dogs ignore nearby players")
	world.mob_system.mobs[ids[0]].proximity_aggro = true
	world.mob_system.tick_mob(world.mob_system.mobs[ids[0]],1.0/60,0)
	for id: int in ids: assert(world.mob_system.mobs[id].target_peer == 1 and world.mob_system.mobs[id].ai_state == MobState.Value.CHASE)
	var member := world.mob_system.mobs[ids[0]]
	member.hp = 1
	member.contributions[1] = 12
	member.position = Vector3(11,0,0)
	world.mob_system.tick_mob(member,1.0/60,1)
	assert(member.ai_state == MobState.Value.RETURN and member.target_peer == 0)
	assert(world.mob_system.horizontal_distance(member.return_target,pack.anchor) <= pack.wander_radius)
	var return_point: Vector3 = member.return_target
	world.mob_system.tick_mob(member,1.0/60,2)
	assert(member.return_target == return_point, "Return destination is chosen once, not rerolled every tick")
	world.mob_system.begin_return(world.mob_system.mobs[ids[1]])
	assert(world.mob_system.mobs[ids[1]].return_target != return_point, "Members have independent return destinations")
	member.position = member.return_target
	world.mob_system.tick_mob(member,1.0/60,2)
	assert(member.hp == member.max_hp and member.ai_state == MobState.Value.IDLE and member.target_peer == 0 and member.contributions.is_empty())
	member.ai_state = MobState.Value.CHASE
	member.target_peer = 1
	hero.position = Vector3(30,0,0)
	member.position = Vector3(8,0,0)
	var pre_aggro_loot_rolls: int = member.spawn_base_loot_rolls
	world.mob_system.tick_mob(member,1.0/60,3)
	assert(member.spawn_base_loot_rolls == pre_aggro_loot_rolls, "Leash must not reroll loot count")
	assert(member.ai_state == MobState.Value.RETURN, "Target outside pack leash triggers return")
	world.characters.clear()
	for mob: MobActor3D in world.mob_system.mobs.values(): mob.ai_enabled = false
	var killed_id := member.mob_instance_id
	member.hp = 0
	var deaths: Array[MobDeathResult] = []
	world.mob_system.mob_died.connect(deaths.append)
	world.mob_system.die(member,100)
	assert(pack.replacements.size() == 1)
	world.mob_system.die(member,101)
	assert(deaths.size() == 1 and deaths[0].mob_id == killed_id and deaths[0].mob_key == member.mob_key, "death fact freezes identity once")
	assert(deaths[0].spawn_base_loot_rolls == pre_aggro_loot_rolls and deaths[0].category == &"beast" and deaths[0].family == &"dogs", "Death freezes the spawn budget")
	var captured: Dictionary = deaths[0].contributions.duplicate()
	member.contributions.clear()
	assert(deaths[0].contributions == captured and deaths[0].timestamp_ms == 100 and deaths[0].experience_reward == member.definition.experience_reward, "death result survives actor contribution cleanup")
	assert(pack.replacements.size() == 1, "Repeated death cannot schedule another replacement")
	world.mob_system.tick(1.0/60,1099)
	assert(pack.actor_ids.size() == 14)
	world.mob_system.tick(1.0/60,1100)
	var fresh_id: int = pack.actor_ids.back()
	var fresh := world.mob_system.mobs[fresh_id]
	assert(not ids.has(fresh_id) and fresh.pack_instance_id == pack.pack_instance_id and fresh.hp == fresh.max_hp)
	assert(fresh.definition == member.definition and world.mob_system.horizontal_distance(fresh.position,pack.anchor) <= pack.spawn_radius)
	assert(fresh.spawn_base_loot_rolls >= 1 and fresh.spawn_base_loot_rolls <= 3 and fresh.mob_instance_id != killed_id)
	for id: int in ids.slice(1): assert(world.mob_system.mobs[id].hp > 0, "Other members survive replacement")
	world.mob_system.tick(1.0/60,6100)
	assert(not world.mob_system.mobs.has(killed_id) and pack.actor_ids.size() == 14)
	combat.client_combat.selected_target = {"kind":&"mob","id":killed_id}
	combat.client_combat.autoattack = true
	combat.client_combat.clear_invalid_target()
	assert(combat.client_combat.selected_target.is_empty() and not combat.client_combat.autoattack)
	# A temporary Metin pack shares definitions but expires without replacement.
	var wave := world.mob_system.create_pack([entry(wild,2),entry(feral,1)],Vector3(6,0,-6),2,3,10,0,"metin-test",10000)
	var wave_ids: Array[int] = wave.actor_ids.duplicate()
	for id: int in wave_ids: assert(world.mob_system.mobs[id].source_metinstone_id == "metin-test" and not world.mob_system.mobs[id].respawn_enabled)
	world.mob_system.mobs[wave_ids[0]].hp = 0
	world.mob_system.die(world.mob_system.mobs[wave_ids[0]],7000)
	assert(wave.replacements.is_empty())
	world.mob_system.tick(1.0/60,10000)
	for id: int in wave_ids: assert(not world.mob_system.mobs.has(id))
	assert(not world.mob_system.packs.has(wave.pack_instance_id))
	# 50 live actors, several packs, desynchronized wander, short server ticks.
	world.mob_system.create_pack([entry(wild,18)],Vector3(-7,0,-7),1,2,8,1)
	world.mob_system.create_pack([entry(feral,15)],Vector3(7,0,7),1,2,8,1)
	assert(world.mob_system.mobs.size() == 50)
	for mob: MobActor3D in world.mob_system.mobs.values():
		mob.ai_enabled = true
		mob.ai_state = MobState.Value.IDLE
		mob.wander_at_ms = 0
	for i: int in 20:
		world.mob_system.tick(1.0/60,11000+i*17)
		for mob: MobActor3D in world.mob_system.mobs.values():
			assert(mob.position.is_finite() and mob.hp > 0 and mob.ai_state in [MobState.Value.IDLE,MobState.Value.WANDER])
		await get_tree().physics_frame
	measure_snapshots(world,50)
	world.mob_system.create_pack([entry(wild,50)],Vector3.ZERO,1,2,8,1)
	assert(world.mob_system.mobs.size() == 100)
	measure_snapshots(world,100)
	world.free()
	WorldServer.curr = null
	server.free()
	print("MOB_PACKS_OK: composition, identity, aggro, anchor leash, per-member replacement, Metin expiry and 50 actors")
	get_tree().quit()

func measure_snapshots(world: GameWorld3D, count: int) -> void:
	# Frozen pre-refactor wire shape; only the new side uses production encoding.
	var legacy: Dictionary = {}
	for mob: MobActor3D in world.mob_system.mobs.values():
		legacy[mob.mob_instance_id] = {"position":mob.position,"yaw":mob.rotation.y,
			"hp":mob.hp,"state":mob.ai_state,"max_hp":mob.max_hp,"damage":mob.attack_damage,
			"title":mob.title,"home":mob.home,"source_metinstone_id":mob.source_metinstone_id,
			"mob_key":mob.mob_key,"visual_id":mob.visual_id,"move_speed":mob.move_speed,
			"pack_instance_id":mob.pack_instance_id}
	var records := world.mob_system.snapshot()
	assert(records.size() == count)
	var decoded: Dictionary = bytes_to_var(var_to_bytes({"mobs":records}))
	var seen: Dictionary[int,bool] = {}
	for record: Array in decoded.mobs:
		assert(record.size() == MobSnapshot.Field.COUNT)
		var id: int = record[MobSnapshot.Field.ID]
		assert(not seen.has(id))
		seen[id] = true
		var mob: MobActor3D = world.mob_system.mobs[id]
		assert(MobDefinitions.resolve(record[MobSnapshot.Field.MOB_KEY]) == mob.definition)
		assert(record[MobSnapshot.Field.POSITION] == mob.position and record[MobSnapshot.Field.YAW] == mob.rotation.y)
		assert(record[MobSnapshot.Field.HP] == mob.hp and record[MobSnapshot.Field.SOURCE_METIN] == mob.source_metinstone_id)
		assert(typeof(record[MobSnapshot.Field.STATE]) == TYPE_INT)
		assert(record[MobSnapshot.Field.STATE] == mob.ai_state)
	var probe: MobActor3D = world.mob_system.mobs.values()[0]
	var original_state := probe.ai_state
	for name: String in MobState.NAMES.values():
		probe.ai_state = MobState.Value[name]
		assert(MobSnapshot.state_name(MobSnapshot.capture(probe)[MobSnapshot.Field.STATE]) == name)
	probe.ai_state = original_state
	for key: StringName in [&"wild_dog",&"feral_dog",&"hollow_hound",&"metin_hound_elite"]:
		assert(MobDefinitions.resolve(key).valid())
	assert(MobDefinitions.resolve(&"unknown") == null)
	var before := var_to_bytes({"dogs":legacy}).size()
	var after := var_to_bytes({"mobs":records}).size()
	assert(after < before / 2, "Compact mob section should remove repeated metadata overhead")
	print("MOB_SNAPSHOT_SIZE count=%d before=%d bytes (%.2f KiB) after=%d bytes (%.2f KiB) reduction=%.1f%%" % [count,before,before/1024.0,after,after/1024.0,100.0*(1.0-float(after)/before)])
