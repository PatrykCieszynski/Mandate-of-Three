extends "res://tests/pve_network.gd"
## Two real transport clients, isolated DB, the production graybox and melee path.
var saw_stone: bool = false
var saw_waves: bool = false
var saw_stone_death: bool = false
var saw_respawn: bool = false
var initial_stone_id: String = ""
var wave_ids: Array[int] = []
func _ready() -> void:
	map_scene_path = "res://source/common/gameplay/maps/graybox/first_region_3d.tscn"
	super._ready()
@rpc("authority", "call_remote", "reliable", 0)
func phase(command: String, uid: String) -> void:
	if GameMode.is_world_server(): return
	phase_name = command
	drop_uid = uid
	attempted = false
	if command == "DONE":
		check(saw_stone and saw_waves and saw_stone_death and saw_respawn,"stone, waves, death and respawn replicated")
		for id: int in wave_ids: check(not world.combat_endpoint.dogs.has(id),"expired wave removed on client")
		if not failed:
			print("METIN_CLIENT_OK: ",client_number," dynamic waves, stone lifecycle and pickup")
			finished.rpc_id(1)
			await get_tree().create_timer(0.5).timeout
			peer.close()
			get_tree().quit()
func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size()==2 and ready_peers.size()==2)
	var encounter: MetinEncounter = world.metin_encounter
	encounter.definition = encounter.definition.duplicate(true)
	encounter.definition.respawn_seconds = 5
	encounter.runtime.definition = encounter.definition
	for dog: SpikeWildDog3D in world.combat_endpoint.dogs.values():
		dog.ai_state = "DISABLED"
		dog.ai_enabled = false
		dog.collision_layer = 0
	# A real melee RPC hits one mixed-pack member and recruits its siblings.
	var wild_entry := MobSpawnEntry.new()
	wild_entry.mob = preload("res://source/common/gameplay/mobs/wild_dog.tres")
	wild_entry.count = 2
	var feral_entry := MobSpawnEntry.new()
	feral_entry.mob = preload("res://source/common/gameplay/mobs/feral_dog.tres")
	var combat := world.combat_endpoint
	var pack := combat.create_pack([wild_entry,feral_entry],Vector3(-30,0,0),0,0,12,15)
	var other_pack := combat.create_pack([feral_entry],Vector3(-30,0,-10),0,0,12,15)
	for id: int in pack.actor_ids + other_pack.actor_ids: combat.dogs[id].ai_enabled = false
	var victim := combat.dogs[pack.actor_ids[0]]
	for id: int in pack.actor_ids.slice(1): combat.dogs[id].position += Vector3(4,0,0)
	var attacker: int = world.characters.keys()[0]
	world.characters[attacker].position = victim.position + Vector3(0,0,1.7)
	world.characters[attacker].rotation.y = 0
	set_phase("FIGHT",attacker)
	await wait_until(func() -> bool: return victim.hp < victim.max_hp)
	set_phase("WAIT")
	for id: int in pack.actor_ids: check(combat.dogs[id].target_peer == attacker and combat.dogs[id].ai_state == "CHASE","melee recruits entire mixed pack")
	check(combat.dogs[other_pack.actor_ids[0]].target_peer == 0,"unrelated pack stays idle")
	for id: int in pack.actor_ids.duplicate() + other_pack.actor_ids.duplicate(): combat._remove_mob(id)
	combat.packs.erase(pack.pack_instance_id)
	combat.packs.erase(other_pack.pack_instance_id)
	combat._pending.clear()
	await get_tree().create_timer(0.7).timeout
	var index: int = 0
	for id: int in world.characters:
		world.characters[id].position = encounter.stone.position + Vector3(-0.2+index*0.4,0,1.7)
		world.characters[id].rotation.y = 0
		server.runtime_equipment[server.connected_players[id].player_id].stats[&"attack"] = 300
		index += 1
	await get_tree().create_timer(0.2).timeout
	initial_stone_id = encounter.runtime.stone_instance_id
	for id: int in world.characters: world.characters[id].rotation.y = PI
	set_phase("FIGHT")
	await get_tree().create_timer(0.35).timeout
	set_phase("WAIT")
	check(encounter.runtime.hp==encounter.definition.max_hp and encounter.runtime.spawned_mobs.is_empty(),"directional melee behind player misses stone")
	for id: int in world.characters: world.characters[id].rotation.y = 0
	await get_tree().create_timer(0.5).timeout
	set_phase("FIGHT")
	await wait_until(func() -> bool: return encounter.runtime.reward_claimed)
	set_phase("WAIT")
	check(world.combat_endpoint.ground.size()==1 and world.currency_endpoint.ground.size()==1,"one ground item and Yang reward")
	check(encounter.runtime.spawned_mobs.size()==11,"all threshold waves issued once")
	for id: int in encounter.runtime.spawned_mobs:
		var dog: SpikeWildDog3D = world.combat_endpoint.dogs[id]
		check(dog.source_metinstone_id==initial_stone_id and not dog.respawn_enabled,"wave provenance and no respawn")
		check(dog.definition.valid() and dog.pack_instance_id > 0,"wave uses shared data-defined pack runtime")
		dog.ai_enabled = false
	drop_uid = str(world.combat_endpoint.ground.keys()[0])
	var reward_owner: int = int(world.combat_endpoint.ground[drop_uid].owner)
	check(encounter.runtime.participants.size()==2,"both players contributed")
	var applied: int = 0
	for value: int in encounter.runtime.participants.values(): applied += value
	check(applied==encounter.definition.max_hp,"overkill never inflates contribution")
	for id: int in world.characters:
		check(not encounter.apply_damage(id,10000,Time.get_ticks_msec()),"dead stone rejects further damage")
	check(world.combat_endpoint.ground.size()==1,"dead stone cannot reward again")
	await get_tree().create_timer(0.5).timeout
	set_phase("RACE")
	await wait_until(func() -> bool: return replies.size()==2)
	var wins: int = 0
	for result: Dictionary in replies.values():
		if result.get("ok",false): wins += 1
	check(wins==1 and world.combat_endpoint.ground.is_empty(),"one authorized pickup wins")
	var found: bool = false
	for item: Dictionary in server.database.item_store.inventory(reward_owner).items: found = found or item.uid==drop_uid
	check(found,"reward pickup persists exact UID")
	for id: int in encounter.runtime.spawned_mobs: world.combat_endpoint.dogs[id].expires_at = Time.get_ticks_msec()+500
	await wait_until(func() -> bool: return encounter.runtime.stone_instance_id != initial_stone_id)
	check(encounter.active() and not encounter.runtime.reward_claimed and encounter.runtime.participants.is_empty(),"fresh random-site lifecycle after cooldown")
	await get_tree().create_timer(0.5).timeout
	set_phase("DONE")
	await wait_until(func() -> bool: return done_peers.size()==2)
	if not failed:
		print("METIN_SERVER_OK: real attacks, waves, contribution, once-only ground reward/pickup, cleanup and respawn")
		world.process_mode = Node.PROCESS_MODE_DISABLED
		peer.close()
		db.close_db()
		get_tree().quit()
func _process(delta: float) -> void:
	elapsed += delta
	if elapsed > 35: check(false,"timeout phase="+phase_name)
	if GameMode.is_world_server():
		# Isolate stone reward assertions from ordinary wave kills in the same swing.
		if world != null:
			for dog: SpikeWildDog3D in world.combat_endpoint.dogs.values():
				if not dog.source_metinstone_id.is_empty():
					dog.ai_enabled = false
					dog.collision_layer = 0
		return
	if world==null or world.combat_endpoint.state.is_empty(): return
	if not ready_peers.has(world.local_peer):
		ready_peers[world.local_peer] = true
		register_ready.rpc_id(1)
	var encounter: MetinEncounter = world.metin_encounter
	if encounter.active():
		saw_stone = true
		if initial_stone_id.is_empty():
			initial_stone_id = encounter.runtime.stone_instance_id
			world.combat_endpoint.select_target({"kind":&"metin","id":initial_stone_id})
			check(not world.combat_endpoint.selected_target.is_empty(),"living Metin is selectable")
		elif encounter.runtime.stone_instance_id != initial_stone_id:
			saw_respawn = true
			check(world.combat_endpoint.selected_target.is_empty(),"respawn does not revive selection")
	else:
		saw_stone_death = saw_stone_death or saw_stone
		if saw_stone:
			check(world.combat_endpoint.selected_target.is_empty() and not world.combat_endpoint.autoattack,"death snapshot clears selection even without autoattack")
	for dog: SpikeWildDog3D in world.combat_endpoint.dogs.values():
		check(dog.mob_instance_id > 0 and dog.pack_instance_id > 0 and not dog.mob_key.is_empty(),"dynamic snapshot reconstructs identities/content")
		if not dog.source_metinstone_id.is_empty():
			saw_waves = true
			if not wave_ids.has(dog.mob_id): wave_ids.append(dog.mob_id)
	accumulator += delta
	if phase_name=="FIGHT" and accumulator>=0.05:
		accumulator = 0
		sequence += 1
		world.combat_endpoint.request_attack.rpc_id(1,sequence)
		world.combat_endpoint.request_attack.rpc_id(1,sequence)
	if phase_name=="RACE" and not attempted:
		attempted = true
		world.combat_endpoint.request_pickup.rpc_id(1,drop_uid)
