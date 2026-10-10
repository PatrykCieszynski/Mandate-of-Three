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
	var world := preload("res://source/common/gameplay/maps/spike/spike_map_3d.tscn").instantiate() as SpikeWorld3D
	add_child(world)
	world.set_physics_process(false)
	world.combat_endpoint.set_physics_process(false)
	var combat := world.combat_endpoint
	for id: int in combat.dogs.keys(): combat._remove_mob(id)
	combat.packs.clear()
	var pack := combat.create_pack([entry(wild,10),entry(feral,4)],Vector3.ZERO,2,3,10,1)
	var unrelated := combat.create_pack([entry(wild,3)],Vector3(10,0,0),1,2,6,1)
	pack.rng.seed = 731
	var ids: Array[int] = pack.actor_ids.duplicate()
	assert(ids.size() == 14 and unrelated.pack_instance_id != pack.pack_instance_id)
	var wild_count: int = 0
	var feral_count: int = 0
	for id: int in ids:
		var mob := combat.dogs[id]
		assert(mob.mob_instance_id == id and mob.pack_instance_id == pack.pack_instance_id and mob.home == pack.anchor)
		assert(mob.definition.valid() and mob.move_speed == mob.definition.move_speed and mob.hp == mob.definition.max_hp)
		assert(combat._horizontal_distance(mob.position,pack.anchor) <= pack.spawn_radius)
		assert(mob.find_children("*","NavigationAgent3D",true,false).is_empty() and mob.collision_mask == 16)
		if mob.mob_key == wild.mob_key: wild_count += 1
		if mob.mob_key == feral.mob_key: feral_count += 1
	assert(wild_count == 10 and feral_count == 4)
	var hero := SpikeCharacter3D.new()
	hero.position = Vector3(0,0,5)
	world.add_child(hero)
	world.characters[1] = hero
	combat.health[1] = 100
	await get_tree().physics_frame
	await get_tree().physics_frame
	# Same entry point used by melee and proximity; every live member reacts.
	combat.aggro_pack(combat.dogs[ids[0]].pack_instance_id,1)
	for id: int in ids: assert(combat.dogs[id].target_peer == 1 and combat.dogs[id].ai_state == "CHASE")
	for id: int in unrelated.actor_ids: assert(combat.dogs[id].target_peer == 0 and combat.dogs[id].ai_state == "IDLE")
	# Passive dog definitions ignore proximity; opt-in content still recruits its pack.
	for id: int in ids:
		combat.dogs[id].ai_state = "IDLE"
		combat.dogs[id].target_peer = 0
	combat.dogs[ids[0]].position = pack.anchor
	combat._tick_dog(combat.dogs[ids[0]],1.0/60,0)
	for id: int in ids: assert(combat.dogs[id].ai_state == "IDLE" and combat.dogs[id].target_peer == 0, "Passive dogs ignore nearby players")
	combat.dogs[ids[0]].proximity_aggro = true
	combat._tick_dog(combat.dogs[ids[0]],1.0/60,0)
	for id: int in ids: assert(combat.dogs[id].target_peer == 1 and combat.dogs[id].ai_state == "CHASE")
	var member := combat.dogs[ids[0]]
	member.hp = 1
	member.contributions[1] = 12
	member.position = Vector3(11,0,0)
	combat._tick_dog(member,1.0/60,1)
	assert(member.ai_state == "RETURN" and member.target_peer == 0)
	assert(combat._horizontal_distance(member.return_target,pack.anchor) <= pack.wander_radius)
	var return_point: Vector3 = member.return_target
	combat._tick_dog(member,1.0/60,2)
	assert(member.return_target == return_point, "Return destination is chosen once, not rerolled every tick")
	combat._begin_return(combat.dogs[ids[1]])
	assert(combat.dogs[ids[1]].return_target != return_point, "Members have independent return destinations")
	member.position = member.return_target
	combat._tick_dog(member,1.0/60,2)
	assert(member.hp == member.max_hp and member.ai_state == "IDLE" and member.target_peer == 0 and member.contributions.is_empty())
	member.ai_state = "CHASE"
	member.target_peer = 1
	hero.position = Vector3(30,0,0)
	member.position = Vector3(8,0,0)
	combat._tick_dog(member,1.0/60,3)
	assert(member.ai_state == "RETURN", "Target outside pack leash triggers return")
	world.characters.clear()
	for mob: SpikeWildDog3D in combat.dogs.values(): mob.ai_enabled = false
	var killed_id := member.mob_instance_id
	member.hp = 0
	combat._die(member,100)
	assert(pack.replacements.size() == 1)
	combat._die(member,101)
	assert(pack.replacements.size() == 1, "Repeated death cannot schedule another replacement")
	combat._tick_mobs(1.0/60,1099)
	assert(pack.actor_ids.size() == 14)
	combat._tick_mobs(1.0/60,1100)
	var fresh_id: int = pack.actor_ids.back()
	var fresh := combat.dogs[fresh_id]
	assert(not ids.has(fresh_id) and fresh.pack_instance_id == pack.pack_instance_id and fresh.hp == fresh.max_hp)
	assert(fresh.definition == member.definition and combat._horizontal_distance(fresh.position,pack.anchor) <= pack.spawn_radius)
	for id: int in ids.slice(1): assert(combat.dogs[id].hp > 0, "Other members survive replacement")
	combat._tick_mobs(1.0/60,6100)
	assert(not combat.dogs.has(killed_id) and pack.actor_ids.size() == 14)
	combat.selected_target = {"kind":&"mob","id":killed_id}
	combat.autoattack = true
	combat._clear_invalid_target()
	assert(combat.selected_target.is_empty() and not combat.autoattack)
	# A temporary Metin pack shares definitions but expires without replacement.
	var wave := combat.create_pack([entry(wild,2),entry(feral,1)],Vector3(6,0,-6),2,3,10,0,"metin-test",10000)
	var wave_ids: Array[int] = wave.actor_ids.duplicate()
	for id: int in wave_ids: assert(combat.dogs[id].source_metinstone_id == "metin-test" and not combat.dogs[id].respawn_enabled)
	combat.dogs[wave_ids[0]].hp = 0
	combat._die(combat.dogs[wave_ids[0]],7000)
	assert(wave.replacements.is_empty())
	combat._tick_mobs(1.0/60,10000)
	for id: int in wave_ids: assert(not combat.dogs.has(id))
	assert(not combat.packs.has(wave.pack_instance_id))
	# 50 live actors, several packs, desynchronized wander, short server ticks.
	combat.create_pack([entry(wild,18)],Vector3(-7,0,-7),1,2,8,1)
	combat.create_pack([entry(feral,15)],Vector3(7,0,7),1,2,8,1)
	assert(combat.dogs.size() == 50)
	for mob: SpikeWildDog3D in combat.dogs.values():
		mob.ai_enabled = true
		mob.ai_state = "IDLE"
		mob.wander_at_ms = 0
	for i: int in 20:
		combat._tick_mobs(1.0/60,11000+i*17)
		for mob: SpikeWildDog3D in combat.dogs.values():
			assert(mob.position.is_finite() and mob.hp > 0 and mob.ai_state in ["IDLE","WANDER"])
		await get_tree().physics_frame
	measure_snapshots(combat,50)
	combat.create_pack([entry(wild,50)],Vector3.ZERO,1,2,8,1)
	assert(combat.dogs.size() == 100)
	measure_snapshots(combat,100)
	world.free()
	WorldServer.curr = null
	server.free()
	print("MOB_PACKS_OK: composition, identity, aggro, anchor leash, per-member replacement, Metin expiry and 50 actors")
	get_tree().quit()

func measure_snapshots(combat: SpikeCombat3D, count: int) -> void:
	# Frozen pre-refactor wire shape; only the new side uses production encoding.
	var legacy: Dictionary = {}
	for mob: SpikeWildDog3D in combat.dogs.values():
		legacy[mob.mob_instance_id] = {"position":mob.position,"yaw":mob.rotation.y,
			"hp":mob.hp,"state":mob.ai_state,"max_hp":mob.max_hp,"damage":mob.attack_damage,
			"title":mob.title,"home":mob.home,"source_metinstone_id":mob.source_metinstone_id,
			"mob_key":mob.mob_key,"visual_id":mob.visual_id,"move_speed":mob.move_speed,
			"pack_instance_id":mob.pack_instance_id}
	var records := combat._mob_snapshots()
	assert(records.size() == count)
	var decoded: Dictionary = bytes_to_var(var_to_bytes({"mobs":records}))
	var seen: Dictionary[int,bool] = {}
	for record: Array in decoded.mobs:
		assert(record.size() == MobSnapshot.Field.COUNT)
		var id: int = record[MobSnapshot.Field.ID]
		assert(not seen.has(id))
		seen[id] = true
		var mob: SpikeWildDog3D = combat.dogs[id]
		assert(MobDefinitions.resolve(record[MobSnapshot.Field.MOB_KEY]) == mob.definition)
		assert(record[MobSnapshot.Field.POSITION] == mob.position and record[MobSnapshot.Field.YAW] == mob.rotation.y)
		assert(record[MobSnapshot.Field.HP] == mob.hp and record[MobSnapshot.Field.SOURCE_METIN] == mob.source_metinstone_id)
		assert(typeof(record[MobSnapshot.Field.STATE]) == TYPE_INT)
		assert(MobSnapshot.state_name(record[MobSnapshot.Field.STATE]) == mob.ai_state)
	var probe: SpikeWildDog3D = combat.dogs.values()[0]
	var original_state := probe.ai_state
	for name: String in MobSnapshot.STATE_NAMES:
		probe.ai_state = name
		assert(MobSnapshot.state_name(MobSnapshot.capture(probe)[MobSnapshot.Field.STATE]) == name)
	probe.ai_state = original_state
	for key: StringName in [&"wild_dog",&"feral_dog",&"hollow_hound",&"metin_hound_elite"]:
		assert(MobDefinitions.resolve(key).valid())
	assert(MobDefinitions.resolve(&"unknown") == null)
	var before := var_to_bytes({"dogs":legacy}).size()
	var after := var_to_bytes({"mobs":records}).size()
	assert(after < before / 2, "Compact mob section should remove repeated metadata overhead")
	print("MOB_SNAPSHOT_SIZE count=%d before=%d bytes (%.2f KiB) after=%d bytes (%.2f KiB) reduction=%.1f%%" % [count,before,before/1024.0,after,after/1024.0,100.0*(1.0-float(after)/before)])
