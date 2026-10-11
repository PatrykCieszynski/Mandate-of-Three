extends "res://tests/pve_network.gd"
## Two production WebSocket clients plus isolated SQLite; validates combat
## geometry, timing, hit reactions, straight-line chase, death and respawn.

var saw_multi: bool = false
var saw_combo: bool = false
var saw_player_death: bool = false
var saw_respawn: bool = false
var saw_swing: bool = false
var saw_down: bool = false
var saw_get_up: bool = false
var dead_peer: int = 0
var observed: Array[StringName] = []
var observer_connected := false
var saw_base_order := false
var saw_extended_order := false

@rpc("authority", "call_remote", "reliable", 0)
func phase(command: String, uid: String) -> void:
	if GameMode.is_world_server(): return
	phase_name = command
	drop_uid = uid
	attempted = false
	if command == "CHECK_BASE" or command == "CHECK_EXTENDED":
		var combo := BasicAttackCombos.BASE if command == "CHECK_BASE" else BasicAttackCombos.COMBO_6
		var keys: Array[StringName] = []
		for step: BasicAttackStepDefinition in combo.steps: keys.append(step.animation_key)
		check(observed == keys,"observer receives exact ordered animation keys: " + str(observed))
		if command == "CHECK_BASE": saw_base_order = true
		else: saw_extended_order = true
		observed.clear()
	if command == "DONE":
		check(saw_base_order and saw_extended_order and saw_multi and saw_combo and saw_player_death and saw_respawn and saw_swing and saw_down and saw_get_up, "replicated multi/combo/death/respawn/swing")
		if not failed:
			print("COMBAT_CLIENT_OK: ", client_number, " multi-hit, combo, reaction, death and respawn")
			finished.rpc_id(1)
			await get_tree().create_timer(0.5).timeout
			peer.close()
			get_tree().quit()

func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size() == 2 and ready_peers.size() == 2)
	var combat: SpikeCombat3D = world.combat_endpoint
	var hero: int = world.characters.keys()[0]
	var other: int = world.characters.keys()[1]
	for dog: SpikeWildDog3D in combat.dogs.values(): dog.ai_enabled = false
	world.characters[hero].position = Vector3(0, 0, 5)
	world.characters[hero].rotation.y = 0
	world.characters[other].position = Vector3(-12, 0, 12)
	combat.dogs[1].position = Vector3(-0.7, 0, 3.4)
	combat.dogs[2].position = Vector3(0.7, 0, 3.4)
	combat.dogs[3].position = Vector3(0, 0, 6.5)
	combat.dogs[4].position = Vector3(2.2, 0, 5)
	await get_tree().create_timer(0.2).timeout
	set_phase("ONE", hero)
	await wait_until(func() -> bool: return combat.dogs[1].hp < 120)
	check(combat.dogs[1].hp == 110 and combat.dogs[2].hp == 110, "one swing hits both front dogs exactly once")
	check(combat.dogs[3].hp == 120 and combat.dogs[4].hp == 120, "behind and side excluded")
	check(combat._combo[hero] == 1 and combat._pending.is_empty(), "fresh sequence flood cannot bypass recovery")
	await wait_until(func() -> bool: return combat.can_move(hero))
	set_phase("TWO", hero)
	await wait_until(func() -> bool: return combat.dogs[1].hp == 100)
	check(combat._combo[hero] == 2 and combat.dogs[2].hp == 100, "second combo hit")
	await wait_until(func() -> bool: return combat.can_move(hero))
	set_phase("THREE", hero)
	await wait_until(func() -> bool: return combat._combo.get(hero,0) == 3 and not combat._pending.has(hero))
	check(not combat.dogs[1].hit_reaction.locked(Time.get_ticks_msec()), "third hit is a non-locking flinch")
	var attacking_dog: SpikeWildDog3D = combat.dogs[1]
	attacking_dog.position = world.characters[hero].position + Vector3(0,0,-1.2)
	attacking_dog.ai_enabled = true
	attacking_dog.last_attack_ms = -10000
	var before_flinch_attack: int = combat.health[hero]
	combat._tick_dog(attacking_dog,1.0/60,Time.get_ticks_msec())
	check(combat.health[hero] < before_flinch_attack, "flinching mob can continue its range attack")
	attacking_dog.ai_enabled = false
	await wait_until(func() -> bool: return combat.can_move(hero))
	set_phase("FOUR",hero)
	await wait_until(func() -> bool: return combat.dogs[1].hit_reaction.locked(Time.get_ticks_msec()))
	check(combat._combo[hero] == 4 and combat.dogs[2].hit_reaction.locked(Time.get_ticks_msec()), "finisher locks all surviving targets")
	set_phase("CHECK_BASE")
	var hit_position: Vector3 = combat.dogs[1].position
	for dog: SpikeWildDog3D in combat.dogs.values():
		if dog.mob_id <= 2: dog.ai_enabled = true
	var hp_before: int = combat.health[hero]
	await get_tree().create_timer(0.3).timeout
	check(combat.health[hero] == hp_before and combat.dogs[1].position.z < hit_position.z-0.3 and combat.dogs[1].position.distance_to(hit_position) < BasicAttackCombos.BASE.steps.back().knockback_distance * 1.2, "down mob is displaced away without AI attacks or chase")
	await wait_until(func() -> bool: return not combat.dogs[1].hit_reaction.locked(Time.get_ticks_msec()))
	for dog: SpikeWildDog3D in combat.dogs.values(): dog.ai_enabled = false
	check(combat.set_combo_skill_level(hero,2) and combat.set_combo_enabled(hero,true),"server selects six-hit combo")
	for dog: SpikeWildDog3D in combat.dogs.values():
		dog.hp = 120
		dog.hit_reaction.clear()
	combat.dogs[1].position = Vector3(-0.25,0,3.8)
	combat.dogs[2].position = Vector3(0.25,0,3.8)
	for step_index: int in BasicAttackCombos.COMBO_6.steps.size():
		await wait_until(func() -> bool: return combat.can_move(hero))
		set_phase("EXT%d" % step_index,hero)
		await wait_until(func() -> bool: return combat._pending.has(hero))
		var pending: Dictionary = combat._pending[hero]
		check(pending.step_index == step_index and pending.animation_key == BasicAttackCombos.COMBO_6.steps[step_index].animation_key,"server resolves extended step identity")
		check(not combat.dogs[1].hit_reaction.locked(Time.get_ticks_msec()),"no knockdown before accepted impact")
		await wait_until(func() -> bool: return not combat._pending.has(hero))
		check(combat.dogs[1].hit_reaction.locked(Time.get_ticks_msec()) == (step_index == 5),"only final impact knocks down")
	set_phase("CHECK_EXTENDED")
	combat.set_combo_enabled(hero,false)
	await wait_until(func() -> bool: return combat.can_move(hero))
	await wait_until(func() -> bool: return not combat.dogs[1].hit_reaction.locked(Time.get_ticks_msec()))
	# Toggle while a server-accepted swing is pending cannot rewrite its step.
	check(combat.set_combo_skill_level(other,1) and combat.set_combo_enabled(other,true),"server selects five-hit combo")
	check(combat.combo_state(other).definition() == BasicAttackCombos.COMBO_5,"level one resolves five-hit definition")
	var toggle_now := Time.get_ticks_msec()
	check(combat.begin_attack(other,1,toggle_now),"accept swing before toggle")
	var frozen_step: BasicAttackStepDefinition = combat._pending[other].step
	combat.set_combo_enabled(other,false)
	check(combat._pending[other].step == frozen_step and combat._pending[other].combo_key == &"warrior_combo_5","toggle preserves accepted pending definition")
	await wait_until(func() -> bool: return combat.can_move(other))
	check(not combat._pending.has(other),"accepted swing resolves after toggle")
	# Player-target path, also used for a future authorized PvP hit. No friendly-fire policy here.
	var now := Time.get_ticks_msec()
	check(combat.begin_attack(other,2,now), "player can begin a swing")
	combat.hurt_player(other,1,now,BasicAttackCombos.BASE.steps[0])
	check(combat._pending.has(other) and not world.characters[other].hit_reaction.locked(now), "flinch preserves player pending attack")
	var canceled_swing: Dictionary = combat._pending[other].duplicate()
	combat.hurt_player(other,1,now,BasicAttackCombos.BASE.steps[3],Vector3.RIGHT)
	check(combat.resolve_swing(other,canceled_swing,now+1).is_empty(), "canceled delayed hit cannot resolve during knockdown")
	var deadline: int = world.characters[other].hit_reaction.get_up_until_ms
	var player_hit_position: Vector3 = world.characters[other].position
	check(world.characters[other].knockback_active(),"accepted player knockdown has physical impulse")
	check(not combat._pending.has(other) and not combat.can_move(other,now) and not combat.begin_attack(other,3,now), "knockdown cancels pending player damage and blocks actions")
	combat.hurt_player(other,1,now+1,BasicAttackCombos.BASE.steps[3])
	check(world.characters[other].hit_reaction.get_up_until_ms == deadline, "re-hit does not extend player lock")
	await wait_until(func() -> bool: return not world.characters[other].hit_reaction.locked(Time.get_ticks_msec()))
	check(world.characters[other].position.x > player_hit_position.x+0.3,"player displacement is simulated on World")
	world.characters[other].reaction_profile = HitReactionProfiles.BOSS
	now = Time.get_ticks_msec()
	check(combat.begin_attack(other,4,now), "actions resume after get-up")
	combat.hurt_player(other,1,now,BasicAttackCombos.BASE.steps[3])
	check(combat._pending.has(other) and not world.characters[other].hit_reaction.locked(now), "immune target keeps its pending attack")
	world.characters[other].reaction_profile = HitReactionProfiles.PLAYER
	await get_tree().create_timer(0.3).timeout
	set_phase("RESET", hero)
	await wait_until(func() -> bool: return combat._combo.get(hero,0) == 1)
	await get_tree().create_timer(0.2).timeout
	set_phase("ASSIST")
	await wait_until(func() -> bool: return replies.size() == 2)
	for result: Dictionary in replies.values(): check(result.ok, "optional target assist cancels on manual movement")
	set_phase("WAIT")
	# Mob chase ignores scenery but remains on the authoritative floor.
	for dog: SpikeWildDog3D in combat.dogs.values(): dog.position = Vector3(-14, 0, -12)
	var dog: SpikeWildDog3D = combat.dogs[1]
	dog.position = SpikeCombat3D.HOME
	dog.hp = 120
	dog.knockback_velocity = Vector3.ZERO
	dog.stunned_until_ms = 0
	dog.ai_enabled = true
	dog.ai_state = "CHASE"
	dog.target_peer = hero
	world.characters[hero].position = Vector3(0, 0, -7)
	var crossed_scenery: bool = false
	while dog.position.distance_to(world.characters[hero].position) > 1.8:
		if dog.position.z < -3 and dog.position.z > -5 and absf(dog.position.x) < 2.35: crossed_scenery = true
		check(dog.position.is_finite() and absf(dog.position.x) < 15.6 and absf(dog.position.z) < 15.6, "straight-line chase stays on floor")
		await get_tree().physics_frame
	check(crossed_scenery, "direct chase passes through scenery")
	dog.hp = 50
	world.characters[hero].position = Vector3(-12, 0, 12)
	await wait_until(func() -> bool: return dog.ai_state == "RETURN")
	await wait_until(func() -> bool: return dog.ai_state == "IDLE")
	check(dog.hp == 120 and dog.position.distance_to(dog.home) < 0.5, "straight-line return heals at anchor")
	world.characters[hero].position = dog.home + Vector3(0, 0, 1)
	combat.health[hero] = 6
	dog.ai_enabled = false
	set_phase("DYING", hero)
	await wait_until(func() -> bool: return combat._pending.has(hero))
	dog.last_attack_ms = -10000
	dog.target_peer = hero
	dog.ai_state = "ATTACK"
	dog.ai_enabled = true
	await wait_until(func() -> bool: return combat.health[hero] == 0)
	check(not combat.can_move(hero) and not combat._pending.has(hero) and not combat._combo.has(hero), "death interrupts attack and movement")
	var dead_position: Vector3 = world.characters[hero].position
	var before: Dictionary = server.database.item_store.inventory(server.connected_players[hero].player_id)
	drop_uid = Crypto.new().generate_random_bytes(16).hex_encode()
	combat.ground[drop_uid] = {"position": dead_position, "definition_id": "iron_sword", "bonus": 3,
		"owner": server.connected_players[hero].player_id, "owner_name": "Test", "protected_until": 0, "expires": Time.get_ticks_msec() + 120000}
	set_phase("DEAD", hero)
	await get_tree().create_timer(0.6).timeout
	check(world.characters[hero].position.distance_to(dead_position) < 0.03 and dog.hp == 120, "dead input and attack denied")
	check(combat.ground.has(drop_uid) and server.database.item_store.inventory(server.connected_players[hero].player_id) == before, "dead pickup denied")
	set_phase("WAIT")
	await wait_until(func() -> bool: return combat.health[hero] == 100)
	check(world.characters[hero].position.distance_to(Vector3(-3, 0, 3)) < 0.2 and not combat._respawn_ms.has(hero), "authoritative respawn")
	check(server.database.item_store.inventory(server.connected_players[hero].player_id) == before, "death/respawn preserves inventory")
	set_phase("RESTART", hero)
	await wait_until(func() -> bool: return combat._combo.get(hero, 0) == 1)
	await wait_until(func() -> bool: return not combat._pending.has(hero))
	check(combat.health[hero] > 0, "attack resumes with first combo stage after respawn")
	await get_tree().create_timer(0.2).timeout
	set_phase("DONE")
	await wait_until(func() -> bool: return done_peers.size() == 2)
	if not failed:
		print("COMBAT_SERVER_OK: directional multi-hit, combo/replay, finisher knockdown and player-target interruption, straight-line obstacle/return, player death/respawn")
		peer.close()
		db.close_db()
		get_tree().quit()

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed > 55:
		check(false, "combat timeout phase=" + phase_name)
		return
	if GameMode.is_world_server() or world == null or world.combat_endpoint.state.is_empty(): return
	if not observer_connected:
		observer_connected = true
		world.combat_endpoint.swing_received.connect(func(_id: int,key: StringName,_index: int) -> void: observed.append(key))
	if not ready_peers.has(world.local_peer):
		ready_peers[world.local_peer] = true
		register_ready.rpc_id(1)
	var combat: SpikeCombat3D = world.combat_endpoint
	for dog: SpikeWildDog3D in combat.dogs.values():
		saw_down = saw_down or dog.presentation.animation_state == &"knockdown"
		saw_get_up = saw_get_up or dog.presentation.animation_state == &"get_up"
	saw_multi = saw_multi or (combat.dogs[1].hp < 120 and combat.dogs[2].hp < 120)
	for stage: int in combat.state.combos.values(): saw_combo = saw_combo or stage == 4
	for id: int in combat.state.health:
		var hp: int = int(combat.state.health[id])
		if hp == 0:
			saw_player_death = true
			dead_peer = id
		if id == dead_peer and hp == 100 and world.characters.has(id) and world.characters[id].alive:
			saw_respawn = true
	for body: SpikeCharacter3D in world.characters.values():
		for node: Node in body.get_children():
			if node is MeshInstance3D and node.mesh is ArrayMesh: saw_swing = true
	if attempted: return
	if phase_name.begins_with("EXT") or phase_name in ["ONE", "TWO", "THREE", "FOUR", "RESET", "DYING", "RESTART"]:
		attempted = true
		combat.select_target({"kind":&"mob","id":3}) # selected dog behind the player cannot redirect manual damage
		for i: int in 40:
			sequence += 1
			combat.request_attack.rpc_id(1, sequence)
			combat.request_attack.rpc_id(1, sequence)
		combat.request_attack.rpc_id(1, -1)
	elif phase_name == "ASSIST":
		attempted = true
		combat.select_target({"kind":&"mob","id":1})
		combat.autoattack = true
		var direction: Vector2 = combat.assist_direction(Vector2.ZERO)
		var manual: Vector2 = combat.assist_direction(Vector2.RIGHT)
		report.rpc_id(1, {"ok": direction.is_finite() and manual == Vector2.RIGHT and not combat.autoattack})
	elif phase_name == "DEAD":
		attempted = true
		sequence += 1
		combat.request_attack.rpc_id(1, sequence)
		combat.request_pickup.rpc_id(1, drop_uid)
		world.submit_input.rpc_id(1, 1, Vector2.RIGHT)
