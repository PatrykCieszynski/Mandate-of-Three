extends "res://tests/pve_network.gd"
var currency_connected: bool = false
var expected_balance: int = 0
var currency_id: int = 0

@rpc("authority", "call_remote", "reliable", 0)
func phase(command: String, uid: String) -> void:
	if GameMode.is_world_server(): return
	phase_name = command
	drop_uid = uid
	attempted = false
	if command == "DONE":
		expected_balance = int(uid)
		var currency: SpikeCurrency3D = world.currency_endpoint
		check(int(currency.state.balance) == expected_balance, "private wallet snapshot")
		check(currency.state.keys().size() == 2 and currency.state.has("drops"), "wallet snapshot excludes other balances and pending deltas")
		check(currency._balance_label.text == "%d Yang" % expected_balance, "HUD shows authoritative Yang")
		if not failed:
			print("YANG_CLIENT_OK: ",client_number," private balance, ground currency, HUD and spend feedback")
			finished.rpc_id(1)
			await get_tree().create_timer(0.5).timeout
			peer.close()
			get_tree().quit()

func sql_balance(owner_id: int) -> int:
	check(db.query_with_bindings("SELECT yang FROM wallets WHERE character_id=?;",[owner_id]), "read wallet")
	return int(db.query_result[0].yang)

func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size() == 2 and ready_peers.size() == 2)
	var hero: int = world.characters.keys()[0]
	var other: int = world.characters.keys()[1]
	var owner: int = server.connected_players[hero].player_id
	var other_owner: int = server.connected_players[other].player_id
	var currency: SpikeCurrency3D = world.currency_endpoint
	var combat: SpikeCombat3D = world.combat_endpoint
	currency.set_physics_process(false) # Explicit phases control the live autoloot tick.
	for dog: SpikeWildDog3D in combat.dogs.values():
		dog.ai_enabled = false
		dog.ai_state = "DISABLED"
		dog.collision_layer = 0
	place_far()
	var dog: SpikeWildDog3D = combat.dogs[1]
	dog.hp = 0
	dog.ai_state = "IDLE"
	dog.contributions = {owner:20, other_owner:15}
	dog.contribution_players[owner] = server.connected_players[hero]
	combat._die(dog,Time.get_ticks_msec())
	check(currency.ground.size() == 1 and server.database.wallet_balance(owner) == 0, "death creates currency on ground, not directly in wallet")
	currency_id = currency.ground.keys()[0]
	combat._die(dog,Time.get_ticks_msec())
	check(currency.ground.size() == 1, "repeated death cannot duplicate currency")
	var point: Vector3 = currency.ground[currency_id].position
	world.characters[other].position = point + Vector3(0,0,0.5)
	drop_uid = str(currency_id)
	currency._send_snapshot()
	set_phase("PICKUP",other)
	await wait_until(func() -> bool: return replies.has(other))
	check(replies[other].error == "reserved" and currency.ground.has(currency_id), "non-owner RPC denied")
	set_phase("WAIT")
	world.characters[hero].position = point + Vector3(0,0,4)
	set_phase("PICKUP",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].error == "distance", "remote pickup denied")
	set_phase("WAIT")
	while server.database.item_store._free_bag_position(owner, ItemDefinitions.IRON_SWORD.inventory_height) >= 0:
		var position: int = server.database.item_store._free_bag_position(owner, ItemDefinitions.IRON_SWORD.inventory_height)
		var filler: ItemInstance = ItemInstance.create(ItemDefinitions.IRON_SWORD,owner,[])
		check(server.database.item_store._insert_item(filler,position), "full bag fixture")
	var full_bag: Dictionary = server.database.item_store.inventory(owner)
	check(db.query("CREATE TEMP TRIGGER reject_pickup_sql BEFORE UPDATE ON wallets BEGIN SELECT RAISE(ABORT,'currency pickup tried SQL'); END;"), "forbid per-pickup wallet writes")
	world.characters[hero].position = point + Vector3(0,0,0.8)
	currency.set_physics_process(true)
	await wait_until(func() -> bool: return not currency.ground.has(currency_id))
	currency.set_physics_process(false)
	check(server.database.wallet_balance(owner) == 30 and sql_balance(owner) == 0 and server.database.runtime_wallets[owner].pending_currency_delta == 30, "autoloot credits RAM without DB write")
	check(server.database.wallet_balance(other_owner) == 0 and server.database.item_store.inventory(owner) == full_bag, "full inventory does not block autoloot or receive currency items")
	check(currency.pickup_for_peer(hero,currency_id,Time.get_ticks_msec()).error == "gone", "no double pickup")
	# Public currency: two actual client RPCs race for the same transient entity.
	currency_id = currency.spawn_currency(point,owner,"",Time.get_ticks_msec())
	currency.ground[currency_id].protected_until = 0
	drop_uid = str(currency_id)
	currency._send_snapshot()
	await get_tree().create_timer(0.2).timeout
	set_phase("PICKUP")
	await wait_until(func() -> bool: return replies.size() == 2)
	var winners: int = 0
	for result: Dictionary in replies.values():
		if result.ok: winners += 1
	check(winners == 1 and server.database.wallet_balance(owner) + server.database.wallet_balance(other_owner) == 60, "public RPC race credits exactly once")
	set_phase("WAIT")
	# Expiry, death and obstruction reuse the same authoritative pickup guards.
	currency_id = currency.spawn_currency(point,owner,"",Time.get_ticks_msec())
	currency.ground[currency_id].expires = 0
	check(currency.pickup_for_peer(hero,currency_id,Time.get_ticks_msec()).error == "gone", "expired currency")
	currency_id = currency.spawn_currency(point,owner,"",Time.get_ticks_msec())
	combat.health[hero] = 0
	check(currency.pickup_for_peer(hero,currency_id,Time.get_ticks_msec()).error == "player", "dead player cannot loot")
	combat.health[hero] = 100
	currency.ground[currency_id].position = Vector3(-1.5,0,-3.5)
	world.characters[hero].position = Vector3(-1.5,0,-1.6)
	check(currency.pickup_for_peer(hero,currency_id,Time.get_ticks_msec()).error == "distance", "obstruction denies pickup")
	currency.ground.erase(currency_id)
	# Fixed-cost spend uses RPC and includes still-uncheckpointed pickup income.
	check(db.query("DROP TRIGGER reject_pickup_sql;"), "allow checkpoint and spend writes")
	check(server.database.add_yang(owner,60), "fixture income for critical spend")
	var before: int = server.database.wallet_balance(owner)
	currency._send_snapshot()
	set_phase("SPEND",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok and replies[hero].spent == 50 and sql_balance(owner) == before-50 and server.database.runtime_wallets[owner].pending_currency_delta == 0, "RPC spends from RAM and commits pending income atomically")
	set_phase("WAIT")
	check(currency.spend_for_peer(hero,1,Time.get_ticks_msec()+1000).error == "replay", "spend replay cannot charge twice")
	check(currency.spend_for_peer(hero,-1,Time.get_ticks_msec()+1000).error == "replay", "invalid spend sequence")
	server.database._process(WorldDatabase.WALLET_SAVE_SECONDS)
	check(server.database.dirty_wallet.is_empty(), "periodic wallet save")
	# Capture visible currency and wallet HUD before disconnect.
	currency.spawn_currency(Vector3(2,0,2),owner,server.connected_players[hero].display_name,Time.get_ticks_msec())
	currency._send_snapshot()
	await get_tree().create_timer(0.3).timeout
	set_phase("INSPECT",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok, "client renders Yang and ground stack")
	set_phase("WAIT")
	for id: int in world.characters:
		phase.rpc_id(id,"DONE",str(server.database.wallet_balance(server.connected_players[id].player_id)))
	await wait_until(func() -> bool: return done_peers.size() == 2)
	var saved: int = sql_balance(owner)
	check(server.database.add_yang(owner,42), "fresh dirty income before real disconnect")
	await wait_until(func() -> bool: return world.characters.is_empty())
	check(sql_balance(owner) == saved+42 and server.database.dirty_wallet.is_empty(), "real disconnect forces final delta")
	server.database.release_wallet(owner)
	check(server.database.load_wallet(owner) and server.database.wallet_balance(owner) == saved+42, "reentry restores saved balance")
	if not failed:
		print("YANG_SERVER_OK: death, rights, distance, autoloot, race, expiry, spend RPC, checkpoint and real disconnect")
		peer.close()
		db.close_db()
		get_tree().quit()

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed > 30:
		check(false,"Yang timeout phase="+phase_name)
		return
	if GameMode.is_world_server() or world == null or world.currency_endpoint.state.is_empty(): return
	var currency: SpikeCurrency3D = world.currency_endpoint
	if not currency_connected:
		currency_connected = true
		currency.feedback_received.connect(func(result: Dictionary) -> void: report.rpc_id(1,result))
	if not ready_peers.has(world.local_peer):
		ready_peers[world.local_peer] = true
		register_ready.rpc_id(1)
	if attempted: return
	if phase_name == "PICKUP":
		attempted = true
		currency.request_pickup.rpc_id(1,int(drop_uid))
	elif phase_name == "SPEND":
		attempted = true
		currency.request_test_spend.rpc_id(1,1)
	elif phase_name == "INSPECT":
		attempted = true
		var ok: bool = int(currency.state.balance) >= 0 and not currency._visuals.is_empty()
		if CmdlineUtils.get_parsed_args().has("preview"):
			await RenderingServer.frame_post_draw
			ok = ok and get_viewport().get_texture().get_image().save_png("res://.godot/verification/yang-preview.png") == OK
			if ok: print("YANG_PREVIEW_OK: yang-preview.png")
		report.rpc_id(1,{"ok":ok})
