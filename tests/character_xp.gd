extends "res://tests/pve_network.gd"
## Two real RPC clients; highest damage owns XP, independent of final hit and
## pickup. The fixture lowers HP only to keep this integration test short.
var saw_level_up: bool = false

@rpc("authority", "call_remote", "reliable", 0)
func phase(command: String, uid: String) -> void:
	if GameMode.is_world_server(): return
	phase_name = command
	drop_uid = uid
	attempted = false
	if command == "DONE":
		var combat: SpikeCombat3D = world.combat_endpoint
		check(combat.state.progression.level == (2 if won else 1), "private progression belongs to recipient")
		check(combat.state.progression.experience == (10 if won else 0), "XP not duplicated or leaked to other player")
		check(combat.state.levels.values().has(2), "public level replicated to both players")
		if won: check(saw_level_up and combat._experience_bar.value == 10 and combat._experience_bar.max_value == 140, "level-up notice and XP bar")
		if not failed:
			print("XP_CLIENT_OK: ", client_number, " private XP, public level, HUD and level-up")
			finished.rpc_id(1)
			await get_tree().create_timer(0.5).timeout
			peer.close()
			get_tree().quit()

func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size() == 2 and ready_peers.size() == 2)
	var hero: int = world.characters.keys()[0]
	var other: int = world.characters.keys()[1]
	var owner_id: int = server.connected_players[hero].player_id
	var other_id: int = server.connected_players[other].player_id
	var combat: SpikeCombat3D = world.combat_endpoint
	var store: WorldStoreSqlite = server.database.store
	var starting_points: int = store.get_player(owner_id).available_attributes_points
	for dog: SpikeWildDog3D in combat.dogs.values():
		dog.ai_enabled = false
		if dog.mob_id != 1:
			dog.ai_state = "DISABLED"
			dog.collision_layer = 0
	for id: int in world.characters:
		world.characters[id].position = Vector3(-0.3 if id == hero else 0.3, 0, 3)
		world.characters[id].rotation.y = 0
	combat.dogs[1].position = Vector3(0, 0, 1.4)
	combat.dogs[1].hp = 35
	await get_tree().create_timer(0.2).timeout
	set_phase("HIT", hero)
	await wait_until(func() -> bool: return combat.dogs[1].hp == 25)
	set_phase("WAIT")
	await get_tree().create_timer(0.5).timeout
	set_phase("HIT", hero)
	await wait_until(func() -> bool: return combat.dogs[1].hp == 15)
	set_phase("WAIT")
	check(store.get_player(owner_id).experience == 0, "hitting a living dog gives no XP")
	set_phase("FINISH", other)
	await wait_until(func() -> bool: return combat.dogs[1].ai_state == "DEAD")
	set_phase("WAIT")
	combat.dogs[1].dead_until_ms = Time.get_ticks_msec() + 60000
	check(combat.dogs[1].contributions[owner_id] == 20 and combat.dogs[1].contributions[other_id] == 15, "actual damage contribution, including clamped final hit")
	check(server.connected_players[hero].experience == 20 and server.connected_players[other].experience == 0, "highest contributor gets runtime XP, not final hitter")
	check(store.get_player(owner_id).experience == 0, "kill does not write XP to SQLite")
	drop_uid = combat.ground.keys()[0]
	combat._die(combat.dogs[1], Time.get_ticks_msec())
	check(combat.ground.size() == 1 and server.connected_players[hero].experience == 20, "repeated runtime death callback cannot grant twice")
	set_phase("RECIPIENT", hero)
	await wait_until(func() -> bool: return replies.has(hero))
	set_phase("WAIT")
	world.characters[other].position = Vector3(-12, 0, 12)
	for id: int in [2, 3, 4]:
		await get_tree().create_timer(1.2).timeout
		var dog: SpikeWildDog3D = combat.dogs[id]
		dog.position = Vector3(0, 0, 1.4)
		dog.ai_state = "IDLE"
		dog.collision_layer = 4
		dog.hp = 10
		set_phase("HIT", hero)
		await wait_until(func() -> bool: return dog.ai_state == "DEAD")
		dog.dead_until_ms = Time.get_ticks_msec() + 60000
		set_phase("WAIT")
	var player: PlayerResource = server.connected_players[hero]
	check(player.level == 2 and player.experience == 10 and player.available_attributes_points == starting_points + PlayerResource.ATTRIBUTE_POINTS_PER_LEVEL, "level-up preserves overflow and existing point grant")
	check(store.get_player(owner_id).level == 1 and store.get_player(owner_id).experience == 0, "many kills change RAM without per-kill DB writes")
	check(server.database.dirty_progression.size() == 1 and server.database.dirty_progression.has(owner_id), "only changed character is dirty")
	check(db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='kill_xp_rewards';") and db.query_result.is_empty(), "no persistent kill receipt table")
	await get_tree().create_timer(0.2).timeout
	set_phase("PICKUP", hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok and player.experience == 10 and store.get_player(owner_id).experience == 0, "item pickup commits item, without flushing or adding XP")
	set_phase("WAIT")
	server.database._process(WorldDatabase.PROGRESSION_SAVE_SECONDS)
	check(server.database.dirty_progression.is_empty(), "periodic checkpoint clears dirty state")
	check(db.close_db() and db.open_db(), "reopen SQLite")
	player = store.get_player(owner_id)
	check(player.level == 2 and player.experience == 10 and player.available_attributes_points == starting_points + PlayerResource.ATTRIBUTE_POINTS_PER_LEVEL, "save and reopen preserve character progression")
	set_phase("INSPECT", hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok, "client sees committed level-up and render")
	set_phase("DONE")
	await wait_until(func() -> bool: return done_peers.size() == 2)
	# Both clients acknowledged the gameplay assertions and will now close their
	# real WebSocket connections. Leave one fresh dirty gain for the disconnect hook.
	server.connected_players[hero].add_experience(20)
	server.database.mark_progression_dirty(server.connected_players[hero])
	check(store.get_player(owner_id).experience == 10, "fresh dirty gain is not yet persisted")
	await wait_until(func() -> bool: return world.characters.is_empty())
	check(store.get_player(owner_id).experience == 30 and server.database.dirty_progression.is_empty(), "real disconnect flushes dirty progression")
	if not failed:
		print("XP_SERVER_OK: two attackers, runtime-only kills, no receipts, checkpoint/reopen and real disconnect flush")
		peer.close()
		db.close_db()
		get_tree().quit()

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed > 35:
		check(false, "XP timeout phase=" + phase_name)
		return
	if GameMode.is_world_server() or world == null or world.combat_endpoint.state.is_empty(): return
	if not ready_peers.has(world.local_peer):
		ready_peers[world.local_peer] = true
		register_ready.rpc_id(1)
	var combat: SpikeCombat3D = world.combat_endpoint
	saw_level_up = saw_level_up or combat._xp_notice.contains("Awans")
	accumulator += delta
	if phase_name == "FINISH" and accumulator >= 0.05:
		accumulator = 0
		sequence += 1
		combat.request_attack.rpc_id(1, sequence)
	if attempted: return
	if phase_name == "HIT":
		attempted = true
		sequence += 1
		combat.request_attack.rpc_id(1, sequence)
	elif phase_name == "RECIPIENT":
		attempted = true
		won = true
		report.rpc_id(1, {"ok": true})
	elif phase_name == "PICKUP":
		attempted = true
		combat.request_pickup.rpc_id(1, drop_uid)
	elif phase_name == "INSPECT":
		attempted = true
		var ok: bool = combat.state.progression.level == 2 and combat.state.progression.experience == 10 and saw_level_up
		if CmdlineUtils.get_parsed_args().has("preview"):
			await RenderingServer.frame_post_draw
			ok = ok and get_viewport().get_texture().get_image().save_png("res://.godot/verification/character-xp-preview.png") == OK
			if ok: print("XP_PREVIEW_OK: character-xp-preview.png")
		report.rpc_id(1, {"ok": ok})
