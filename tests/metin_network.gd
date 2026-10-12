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
		for id: int in wave_ids: check(not world.mob_system.mobs.has(id),"expired wave removed on client")
		if not failed:
			print("METIN_CLIENT_OK: ",client_number," dynamic waves, stone lifecycle and pickup")
			finished.rpc_id(1)
			await get_tree().create_timer(0.5).timeout
			peer.close()
			get_tree().quit()
func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size()==2 and ready_peers.size()==2)
	var encounter: MetinEncounter = world.metin_encounter
	encounter.definition = encounter.definition.duplicate()
	encounter.definition.respawn_seconds = 5
	encounter.runtime.definition = encounter.definition
	for dog: SpikeWildDog3D in world.mob_system.mobs.values():
		dog.ai_state = MobState.Value.DISABLED
		dog.ai_enabled = false
		dog.collision_layer = 0
	# A real melee RPC hits one mixed-pack member and recruits its siblings.
	var wild_entry := MobSpawnEntry.new()
	wild_entry.mob = preload("res://source/common/gameplay/mobs/wild_dog.tres")
	wild_entry.count = 2
	var feral_entry := MobSpawnEntry.new()
	feral_entry.mob = preload("res://source/common/gameplay/mobs/feral_dog.tres")
	var combat := world.combat_endpoint
	var pack := world.mob_system.create_pack([wild_entry,feral_entry],Vector3(-30,0,0),0,0,12,15)
	var other_pack := world.mob_system.create_pack([feral_entry],Vector3(-30,0,-10),0,0,12,15)
	for id: int in pack.actor_ids + other_pack.actor_ids: world.mob_system.mobs[id].ai_enabled = false
	var victim := world.mob_system.mobs[pack.actor_ids[0]]
	for id: int in pack.actor_ids.slice(1): world.mob_system.mobs[id].position += Vector3(4,0,0)
	var attacker: int = world.characters.keys()[0]
	world.characters[attacker].position = victim.position + Vector3(0,0,1.7)
	world.characters[attacker].rotation.y = 0
	set_phase("FIGHT",attacker)
	await wait_until(func() -> bool: return victim.hp < victim.max_hp)
	set_phase("WAIT")
	await _settle_attacks()
	for id: int in pack.actor_ids: check(world.mob_system.mobs[id].target_peer == attacker and world.mob_system.mobs[id].ai_state == MobState.Value.CHASE,"melee recruits entire mixed pack")
	check(world.mob_system.mobs[other_pack.actor_ids[0]].target_peer == 0,"unrelated pack stays idle")
	for id: int in pack.actor_ids.duplicate() + other_pack.actor_ids.duplicate(): world.mob_system.remove_mob(id)
	world.mob_system.packs.erase(pack.pack_instance_id)
	world.mob_system.packs.erase(other_pack.pack_instance_id)
	for id: int in world.characters: combat.attack_runtime(id).pending_impact = {}
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
	await _settle_attacks()
	check(encounter.runtime.hp==encounter.definition.max_hp and encounter.runtime.spawned_mobs.is_empty(),"directional melee behind player misses stone")
	for id: int in world.characters: world.characters[id].rotation.y = 0
	await get_tree().create_timer(0.5).timeout
	# Sequential contributors isolate the stone reward. Simultaneous 300-attack
	# impacts can legitimately kill a wave spawned earlier in the same physics tick.
	var contributors: Array = world.characters.keys()
	set_phase("FIGHT",int(contributors[0]))
	await wait_until(func() -> bool: return encounter.runtime.participants.has(combat._owner(int(contributors[0]))))
	set_phase("WAIT")
	await _settle_attacks()
	# Observe newly created rewards before the independent autoloot loop claims
	# Yang. Yang network tests cover autoloot; this assertion covers stone spawn.
	world.currency_endpoint.set_physics_process(false)
	set_phase("FIGHT",int(contributors[1]))
	await wait_until(func() -> bool: return encounter.runtime.reward_claimed)
	set_phase("WAIT")
	check(world.ground_loot.drops.size()==1 and world.currency_endpoint.ground.size()==1,"one ground item and Yang reward: items=%d currency=%d" % [world.ground_loot.drops.size(),world.currency_endpoint.ground.size()])
	check(encounter.runtime.spawned_mobs.size()==11,"all threshold waves issued once")
	for id: int in encounter.runtime.spawned_mobs:
		var dog: SpikeWildDog3D = world.mob_system.mobs[id]
		check(dog.source_metinstone_id==initial_stone_id and not dog.respawn_enabled,"wave provenance and no respawn")
		check(dog.definition.valid() and dog.pack_instance_id > 0,"wave uses shared data-defined pack runtime")
		check(dog.target_peer != 0,"passive wave dogs still attack stone contributors")
		dog.ai_enabled = false
	drop_uid = str(world.ground_loot.drops.keys()[0])
	var reward_owner: int = int(world.ground_loot.drops[drop_uid].owner)
	check(encounter.runtime.participants.size()==2,"both players contributed")
	var applied: int = 0
	for value: int in encounter.runtime.participants.values(): applied += value
	check(applied==encounter.definition.max_hp,"overkill never inflates contribution")
	for id: int in world.characters:
		check(not encounter.apply_damage(id,10000,Time.get_ticks_msec()),"dead stone rejects further damage")
	check(world.ground_loot.drops.size()==1,"dead stone cannot reward again")
	world.currency_endpoint.set_physics_process(true)
	await get_tree().create_timer(0.5).timeout
	set_phase("RACE")
	await wait_until(func() -> bool: return replies.size()==2)
	var wins: int = 0
	for result: Dictionary in replies.values():
		if result.get("ok",false): wins += 1
	check(wins==1 and world.ground_loot.drops.is_empty(),"one authorized pickup wins")
	var found: bool = false
	for item: Dictionary in server.database.item_store.inventory(reward_owner).items: found = found or item.uid==drop_uid
	check(found,"reward pickup persists exact UID")
	for id: int in encounter.runtime.spawned_mobs: world.mob_system.mobs[id].expires_at = Time.get_ticks_msec()+500
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
func _settle_attacks() -> void:
	# Releasing input does not cancel an already accepted current/queued swing.
	# Keep fixture yaw/position stable until both finish before the next scenario.
	await get_tree().create_timer(.15).timeout
	await wait_until(func() -> bool: return world.characters.keys().all(func(id: int) -> bool: return world.combat_endpoint.attack_runtime(id).pending_impact.is_empty() and world.combat_endpoint.attack_runtime(id).queued_sequence < 0))

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed > 35: check(false,"timeout phase="+phase_name)
	if GameMode.is_world_server():
		# Isolate stone reward assertions from ordinary wave kills in the same swing.
		if world != null:
			for dog: SpikeWildDog3D in world.mob_system.mobs.values():
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
			world.combat_endpoint.client_combat.select_target({"kind":&"metin","id":initial_stone_id})
			check(not world.combat_endpoint.client_combat.selected_target.is_empty(),"living Metin is selectable")
		elif encounter.runtime.stone_instance_id != initial_stone_id:
			saw_respawn = true
			check(world.combat_endpoint.client_combat.selected_target.is_empty(),"respawn does not revive selection")
	else:
		saw_stone_death = saw_stone_death or saw_stone
		if saw_stone:
			check(world.combat_endpoint.client_combat.selected_target.is_empty() and not world.combat_endpoint.client_combat.autoattack,"death snapshot clears selection even without autoattack")
	for dog: SpikeWildDog3D in world.mob_system.mobs.values():
		check(dog.mob_instance_id > 0 and dog.definition == MobDefinitions.resolve(dog.mob_key),"compact snapshot reconstructs identity and local definition")
		check(dog.max_hp == dog.definition.max_hp and dog.title == dog.definition.display_name and dog.visual_id == dog.definition.visual_id,"presentation metadata comes from local definition")
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
