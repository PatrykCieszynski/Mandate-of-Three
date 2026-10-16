extends Node
## Production RPC + physics + isolated real SQLite. Fixture-only commands below
## coordinate assertions; gameplay commands go through CombatEndpoint3D unchanged.

const PORT: int = 18098
var map_scene_path: String = "res://tests/fixtures/world3d/test_arena.tscn"
var database_directory: String = "res://.godot/verification"
var fixture_connection_number := 0
# Fixture-only opt-in: exercise shared-account domain races without changing login policy.
var fixture_shared_account := false
var peer := WebSocketMultiplayerPeer.new()
var world: GameWorld3D
var server: WorldServer
var db: SQLite
var client_number: int = 0
var elapsed: float = 0
var phase_name: String = "WAIT"
var drop_uid: String = ""
var sequence: int = 0
var accumulator: float = 0
var attempted: bool = false
var replies: Dictionary[int, Dictionary] = {}
var ready_peers: Dictionary[int, bool] = {}
var done_peers: Dictionary[int, bool] = {}
var saw_damage: bool = false
var saw_death: bool = false
var saw_loot: bool = false
var won: bool = false
var failed: bool = false
var fixture_checkpoint: String = "entry"
var aim_fixture_fight: bool = false
var pickup_mutations: Array[int] = []

func check(ok: bool, description: String) -> void:
	if not ok:
		failed = true
		push_error("PVE_NETWORK_FAILED: " + description)
		get_tree().quit(1)

func _ready() -> void:
	Engine.physics_ticks_per_second = 60
	BaseMultiplayerEndpoint.configure_peer(peer)
	client_number = int(CmdlineUtils.get_parsed_args().get("test-client", "0"))
	var api: SceneMultiplayer = multiplayer as SceneMultiplayer
	api.server_relay = false
	if GameMode.is_world_server():
		check(peer.create_server(PORT, "127.0.0.1") == OK, "socket")
		api.multiplayer_peer = peer
		server = WorldServer.new()
		server.name = "Session"
		server.multiplayer_api = api
		add_child(server)
		ServerInstance.world_server = server
		db = SQLite.new()
		db.path = "%s/pve-network-%s.db" % [database_directory,Crypto.new().generate_random_bytes(8).hex_encode()]
		check(db.open_db(), "SQLite open")
		WorldSchema.ensure_schema(db)
		server.database = WorldDatabase.new()
		server.add_child(server.database)
		server.database.db = db
		server.database.item_store = ItemStoreSqlite.new(db)
		server.database.store = WorldStoreSqlite.new(db)
		var host: ServerInstance = preload("res://source/server/world/components/world_instance_3d.gd").new()
		host.name = "Instance"
		host.instance_resource = InstanceResource.new()
		host.instance_resource.instance_name = &"FirstRegion"
		host.load_map(map_scene_path)
		add_child(host)
		world = host.get_node("GameWorld")
		# Opt in only in the fixture to retain natural-aggro/return coverage.
		for dog: MobActor3D in world.mob_system.mobs.values(): dog.proximity_aggro = true
		api.peer_connected.connect(func(id: int) -> void:
			fixture_connection_number += 1
			var number: int = fixture_connection_number
			var owner: int = EconomyFixture.create_character(server.database.store,"pve_shared" if fixture_shared_account else "pve%d" % number, {"name": "Pve%d" % number, "skin": 1})
			check(db.query_with_bindings("UPDATE account_wallets SET yang=0 WHERE account_id=(SELECT a.master_account_id FROM accounts a JOIN players p ON p.account_name=a.account_name WHERE p.player_id=?);", [owner]), "explicit zero wallet fixture")
			EconomyFixture.prepare(server.database)
			server.connected_players[id] = server.database.store.get_player(owner)
			server.connected_players[id].current_peer_id=id
			server.player_id_to_peer_id[owner]=id
			host.awaiting_peers[id] = {"session":server.connected_players[id]})
		call_deferred("run_server")
	else:
		check(peer.create_client("ws://127.0.0.1:%d" % PORT) == OK, "client socket")
		api.multiplayer_peer = peer
		api.connected_to_server.connect(func() -> void:
			var instance: InstanceClient = preload("res://source/client/network/world_instance_3d.gd").new()
			instance.name = "Instance"
			world = load(map_scene_path).instantiate()
			world.input_enabled = false
			instance.add_child(world)
			add_child(instance)
			world.combat_endpoint.feedback_received.connect(func(result: Dictionary) -> void:
				if phase_name == "RACE" and result.ok: won = true
				report.rpc_id(1, result)))

@rpc("any_peer", "call_remote", "reliable", 0)
func register_ready() -> void:
	if GameMode.is_world_server(): ready_peers[multiplayer.get_remote_sender_id()] = true

@rpc("any_peer", "call_remote", "reliable", 0)
func report(result: Dictionary) -> void:
	if GameMode.is_world_server(): replies[multiplayer.get_remote_sender_id()] = result

@rpc("any_peer", "call_remote", "reliable", 0)
func finished() -> void:
	if GameMode.is_world_server(): done_peers[multiplayer.get_remote_sender_id()] = true

@rpc("authority", "call_remote", "reliable", 0)
func phase(command: String, uid: String) -> void:
	if GameMode.is_world_server(): return
	phase_name = command
	drop_uid = uid
	attempted = false
	if command == "DONE":
		check(saw_damage and saw_death and saw_loot, "replicated combat, death and ground loot")
		check(world.combat_endpoint.state.drops.is_empty(), "picked loot despawned")
		check(world.inventory_endpoint.state.items.size() == (3 if won else 2), "winner alone receives item")
		if won:
			var found: bool = false
			for item: Dictionary in world.inventory_endpoint.state.items:
				found = found or item.uid == drop_uid
			check(found, "picked exact UID snapshot")
		if not failed:
			print("PVE_CLIENT_OK: ", client_number, " combat/death/ground/pickup replication, winner=", won)
			finished.rpc_id(1)
			await get_tree().create_timer(0.5).timeout
			peer.close()
			get_tree().quit()

func set_phase(command: String, selected_peer: int = 0) -> void:
	phase_name = command
	replies.clear()
	for id: int in world.characters:
		phase.rpc_id(id, command if selected_peer == 0 or selected_peer == id else "WAIT", drop_uid)

func wait_until(predicate: Callable) -> void:
	while not failed and not predicate.call(): await get_tree().physics_frame

func place_far() -> void:
	for id: int in world.characters: world.characters[id].position = Vector3(-12, 0, 12)

func place_near() -> void:
	var index: int = 0
	for id: int in world.characters:
		world.characters[id].position = CombatEndpoint3D.HOME + Vector3(-1 if index == 0 else 1, 0, 1)
		index += 1

func run_server() -> void:
	aim_fixture_fight = true
	await wait_until(func() -> bool: return world.characters.size() == 2 and ready_peers.size() == 2)
	var combat: CombatEndpoint3D = world.combat_endpoint
	world.inventory_endpoint.inventory_changed.connect(func(owner: int) -> void: pickup_mutations.append(owner))
	for id: int in world.mob_system.mobs:
		if id != 1:
			world.mob_system.mobs[id].ai_state = MobState.Value.DISABLED
			world.mob_system.mobs[id].collision_layer = 0
	place_far()
	world.mob_system.mobs[1].position = CombatEndpoint3D.HOME
	world.mob_system.mobs[1].ai_state = MobState.Value.IDLE
	world.mob_system.mobs[1].target_peer = 0
	await get_tree().create_timer(0.3).timeout
	check(world.mob_system.mobs[1].ai_state == MobState.Value.IDLE, "idle outside aggro")
	for id: int in world.characters: world.characters[id].position = CombatEndpoint3D.HOME + Vector3(0, 0, 5)
	fixture_checkpoint = "CHASE"
	await wait_until(func() -> bool: return world.mob_system.mobs[1].ai_state == MobState.Value.CHASE)
	fixture_checkpoint = "ATTACK"
	await wait_until(func() -> bool: return world.mob_system.mobs[1].ai_state == MobState.Value.ATTACK)
	check(world.characters.values().map(func(body: PlayerActor3D) -> int: return body.hp).min() < 100, "server mob attack")
	world.mob_system.mobs[1].hp = 50
	place_far()
	fixture_checkpoint = "RETURN"
	await wait_until(func() -> bool: return world.mob_system.mobs[1].ai_state == MobState.Value.RETURN)
	fixture_checkpoint = "IDLE"
	await wait_until(func() -> bool: return world.mob_system.mobs[1].ai_state == MobState.Value.IDLE)
	check(world.mob_system.mobs[1].hp == CombatEndpoint3D.MOB_HP and world.mob_system.mobs[1].contributions.is_empty(), "return heals and resets encounter")
	set_phase("RANGE")
	await get_tree().create_timer(0.5).timeout
	check(world.mob_system.mobs[1].hp == CombatEndpoint3D.MOB_HP, "distant attack/replay flood cannot damage")
	# A fixture position inside the obstacle gives a short, obstructed ray.
	# Freeze AI only here so RETURN cannot mask the line-of-sight assertion.
	world.mob_system.mobs[1].ai_enabled = false
	for id: int in world.characters: combat.attacks.attack_runtime(id).pending_impact = {}
	for id: int in world.characters: combat.attacks.attack_runtime(id).next_attack_ms = 0
	world.mob_system.mobs[1].position = Vector3(-1.5, 0, -3.5)
	world.mob_system.mobs[1].ai_state = MobState.Value.CHASE
	for id: int in world.characters: world.characters[id].position = Vector3(-1.5, 0, -1.6)
	await get_tree().create_timer(0.4).timeout
	check(combat.attacks.attack_runtime(world.characters.keys()[0]).pending_impact.is_empty(), "obstructed swing reached its impact")
	check(world.mob_system.mobs[1].hp == CombatEndpoint3D.MOB_HP, "attack through obstacle denied")
	world.mob_system.mobs[1].position = CombatEndpoint3D.HOME
	world.mob_system.mobs[1].ai_state = MobState.Value.IDLE
	world.mob_system.mobs[1].target_peer = 0
	for id: int in world.characters: combat.attacks.attack_runtime(id).pending_impact = {}
	for id: int in world.characters: combat.attacks.attack_runtime(id).display_combo_step = 0
	for id: int in world.characters: combat.attacks.attack_runtime(id).combo = BasicAttackComboState.new()
	for id: int in world.characters: combat.attacks.attack_runtime(id).next_attack_ms = 0
	world.mob_system.mobs[1].ai_enabled = true
	place_near()
	var fight_started_ms: int = Time.get_ticks_msec()
	set_phase("FIGHT")
	await wait_until(func() -> bool: return world.mob_system.mobs[1].ai_state == MobState.Value.DEAD)
	check(Time.get_ticks_msec() - fight_started_ms >= 1800, "spam/replay cannot bypass server combo recovery")
	world.mob_system.mobs[1].dead_until_ms = Time.get_ticks_msec() + 60000
	check(world.mob_system.mobs[1].contributions.size() == 2 and world.ground_loot.drops.size() == 1, "two attackers, one death and one drop")
	drop_uid = world.ground_loot.drops.keys()[0]
	var drop: Dictionary = world.ground_loot.drops[drop_uid]
	var owner_peer: int = 0
	var other_peer: int = 0
	for id: int in world.characters:
		if server.connected_players[id].player_id == drop.owner: owner_peer = id
		else: other_peer = id
	check(owner_peer != 0 and other_peer != 0, "damage owner")
	for id: int in world.characters: world.characters[id].position = drop.position + Vector3(0.5, 0, 0.5)
	check(db.query("SELECT COUNT(*) AS n FROM item_instances;") and db.query_result[0].n == 4, "loot stays on ground before pickup")
	set_phase("PICKUP", other_peer)
	await wait_until(func() -> bool: return replies.has(other_peer))
	check(replies[other_peer].get("error", "") == "reserved" and world.ground_loot.drops.has(drop_uid), "non-owner denied, ground retained")
	var owner_id: int = server.connected_players[owner_peer].player_id
	var filler: Array[String] = []
	while server.database.item_store._free_bag_position(owner_id, ItemDefinitions.IRON_SWORD.inventory_height) >= 0:
		var position: int = server.database.item_store._free_bag_position(owner_id, ItemDefinitions.IRON_SWORD.inventory_height)
		var item: ItemInstance = ItemInstance.create(ItemDefinitions.IRON_SWORD, owner_id, [])
		check(EconomyFixture.insert_item(server.database.item_store,item, position), "full bag fixture")
		filler.append(item.uid)
	set_phase("PICKUP", owner_peer)
	await wait_until(func() -> bool: return replies.has(owner_peer))
	check(replies[owner_peer].get("error", "") == "bag_full" and world.ground_loot.drops.has(drop_uid), "full bag keeps ground loot")
	for uid: String in filler:
		check(EconomyFixture.destroy_item(db,uid),"destroy filler transaction")
	world.characters[owner_peer].position = Vector3(-12, 0, 12)
	await get_tree().create_timer(0.15).timeout
	set_phase("PICKUP", owner_peer)
	await wait_until(func() -> bool: return replies.has(owner_peer))
	check(replies[owner_peer].get("error", "") == "distance", "remote pickup denied")
	world.characters[owner_peer].position = drop.position + Vector3(0.5, 0, 0.5)
	world.ground_loot.drops[drop_uid].protected_until = 0 # exercise public phase without a 15s wait
	await get_tree().create_timer(0.15).timeout
	set_phase("RACE")
	await wait_until(func() -> bool: return replies.size() == 2)
	var winners: int = 0
	var winner_id: int = 0
	for id: int in replies:
		if replies[id].ok:
			winners += 1
			winner_id = server.connected_players[id].player_id
	check(winners == 1 and world.ground_loot.drops.is_empty(), "double pickup has one winner")
	check(db.query("SELECT COUNT(*) AS n FROM item_instances;") and db.query_result[0].n == 5, "one additional persistent instance")
	check(db.query("SELECT COUNT(*) AS n FROM ground_item_claims;") and db.query_result[0].n == 1, "one durable receipt")
	await get_tree().create_timer(0.2).timeout
	set_phase("REPLAY")
	await wait_until(func() -> bool: return replies.size() == 2)
	for result: Dictionary in replies.values(): check(result.get("error", "") == "gone", "replay after despawn denied")
	check(pickup_mutations == [winner_id], "only the winning durable pickup publishes an inventory mutation; rejection/replay publish none")
	var persisted: Dictionary = server.database.item_store.inventory(winner_id)
	check(db.close_db() and db.open_db(), "reopen real DB")
	check(server.database.item_store.inventory(winner_id) == persisted, "picked item survives database reopen")
	await get_tree().create_timer(0.3).timeout
	set_phase("DONE")
	await wait_until(func() -> bool: return done_peers.size() == 2)
	if not failed:
		print("PVE_SERVER_OK: AI cycle, server damage, two attackers, reserved/full/distance, double pickup, persistence")
		peer.close()
		db.close_db()
		get_tree().quit()

func _physics_process(_delta: float) -> void:
	# This fixture exercises a sustained two-player fight. Full-motion advance
	# moves actors; keep subsequent intentions aimed at the moving dog, as target
	# assistance does in gameplay. An accepted swing keeps its own frozen yaw.
	if not aim_fixture_fight or not GameMode.is_world_server() or phase_name!="FIGHT" or world==null: return
	var combat: CombatEndpoint3D = world.combat_endpoint
	var dog: MobActor3D = world.mob_system.mobs.get(1)
	if dog==null or dog.ai_state==MobState.Value.DEAD: return
	for id: int in world.characters:
		var body: PlayerActor3D = world.characters[id]
		var offset: Vector3 = dog.position-body.position
		body.rotation.y = atan2(-offset.x,-offset.z)
		combat.remember_next_facing(id,Vector2(offset.x,offset.z))

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed > 40:
		check(false, "timeout phase=" + phase_name + " checkpoint=" + fixture_checkpoint + " health=" + str(world.characters.values().map(func(body: PlayerActor3D) -> int: return body.hp)) + " ready=" + str(ready_peers.size()) + " mobs=" + str(world.mob_system.snapshot()) if world != null else "timeout before world setup")
		return
	if GameMode.is_world_server() or world == null or world.combat_endpoint.state.is_empty(): return
	if not ready_peers.has(world.local_peer):
		ready_peers[world.local_peer] = true
		register_ready.rpc_id(1)
	var combat: CombatEndpoint3D = world.combat_endpoint
	saw_damage = saw_damage or world.mob_system.mobs[1].hp < CombatEndpoint3D.MOB_HP
	saw_death = saw_death or world.mob_system.mobs[1].ai_state == MobState.Value.DEAD
	saw_loot = saw_loot or not combat.state.drops.is_empty()
	accumulator += delta
	if accumulator >= 0.05 and phase_name in ["RANGE", "FIGHT"]:
		accumulator = 0
		sequence += 1
		combat.request_attack.rpc_id(1, sequence)
		combat.request_attack.rpc_id(1, sequence) # same sequence cannot hit twice
		combat.request_attack.rpc_id(1, -1) # invalid sequence denied
	if phase_name in ["PICKUP", "RACE", "REPLAY"] and not attempted:
		attempted = true
		combat.request_pickup.rpc_id(1, drop_uid)
