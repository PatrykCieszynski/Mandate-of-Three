extends Node
## Production RPC + physics + isolated real SQLite. Fixture-only commands below
## coordinate assertions; gameplay commands go through SpikeCombat3D unchanged.

const PORT: int = 18098
var peer := WebSocketMultiplayerPeer.new()
var world: SpikeWorld3D
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

func check(ok: bool, description: String) -> void:
	if not ok:
		failed = true
		push_error("PVE_NETWORK_FAILED: " + description)
		get_tree().quit(1)

func _ready() -> void:
	Engine.physics_ticks_per_second = 60
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
		db.path = "res://.godot/verification/pve-network-%s.db" % Crypto.new().generate_random_bytes(8).hex_encode()
		check(db.open_db(), "SQLite open")
		WorldSchema.ensure_schema(db)
		server.database = WorldDatabase.new()
		server.add_child(server.database)
		server.database.db = db
		server.database.item_store = ItemStoreSqlite.new(db)
		server.database.store = WorldStoreSqlite.new(db)
		var host: ServerInstance = preload("res://source/server/world/components/spike_instance_3d.gd").new()
		host.name = "Instance"
		host.instance_resource = InstanceResource.new()
		host.instance_resource.instance_name = &"Spike"
		host.load_map("res://source/common/gameplay/maps/spike/spike_map_3d.tscn")
		add_child(host)
		world = host.get_node("SpikeMap")
		api.peer_connected.connect(func(id: int) -> void:
			var number: int = server.connected_players.size() + 1
			var owner: int = server.database.store.create_player_character("pve%d" % number, {"name": "Pve%d" % number, "skin": 1})
			server.connected_players[id] = server.database.store.get_player(owner)
			host.awaiting_peers[id] = {})
		call_deferred("run_server")
	else:
		check(peer.create_client("ws://127.0.0.1:%d" % PORT) == OK, "client socket")
		api.multiplayer_peer = peer
		api.connected_to_server.connect(func() -> void:
			var instance: InstanceClient = preload("res://source/client/network/spike_instance_3d.gd").new()
			instance.name = "Instance"
			world = load("res://source/common/gameplay/maps/spike/spike_map_3d.tscn").instantiate()
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
		world.characters[id].position = SpikeCombat3D.HOME + Vector3(-1 if index == 0 else 1, 0, 1)
		index += 1

func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size() == 2 and ready_peers.size() == 2)
	var combat: SpikeCombat3D = world.combat_endpoint
	for id: int in combat.dogs:
		if id != 1:
			combat.dogs[id].ai_state = "DISABLED"
			combat.dogs[id].collision_layer = 0
	place_far()
	combat.dogs[1].position = SpikeCombat3D.HOME
	combat.dogs[1].ai_state = "IDLE"
	combat.dogs[1].target_peer = 0
	await get_tree().create_timer(0.3).timeout
	check(combat.dogs[1].ai_state == "IDLE", "idle outside aggro")
	for id: int in world.characters: world.characters[id].position = SpikeCombat3D.HOME + Vector3(0, 0, 5)
	await wait_until(func() -> bool: return combat.dogs[1].ai_state == "CHASE")
	await wait_until(func() -> bool: return combat.dogs[1].ai_state == "ATTACK")
	check(combat.health.values().min() < 100, "server mob attack")
	combat.dogs[1].hp = 50
	place_far()
	await wait_until(func() -> bool: return combat.dogs[1].ai_state == "RETURN")
	await wait_until(func() -> bool: return combat.dogs[1].ai_state == "IDLE")
	check(combat.dogs[1].hp == SpikeCombat3D.MOB_HP and combat.dogs[1].contributions.is_empty(), "return heals and resets encounter")
	set_phase("RANGE")
	await get_tree().create_timer(0.5).timeout
	check(combat.dogs[1].hp == SpikeCombat3D.MOB_HP, "distant attack/replay flood cannot damage")
	# A fixture position inside the obstacle gives a short, obstructed ray.
	# Freeze AI only here so RETURN cannot mask the line-of-sight assertion.
	combat.dogs[1].ai_enabled = false
	combat._pending.clear()
	combat._next_attack_ms.clear()
	combat.dogs[1].position = Vector3(-1.5, 0, -3.5)
	combat.dogs[1].ai_state = "CHASE"
	for id: int in world.characters: world.characters[id].position = Vector3(-1.5, 0, -1.6)
	await get_tree().create_timer(0.4).timeout
	check(not combat._pending.has(world.characters.keys()[0]), "obstructed swing reached its impact")
	check(combat.dogs[1].hp == SpikeCombat3D.MOB_HP, "attack through obstacle denied")
	combat.dogs[1].position = SpikeCombat3D.HOME
	combat.dogs[1].ai_state = "IDLE"
	combat.dogs[1].target_peer = 0
	combat._pending.clear()
	combat._combo.clear()
	combat._last_swing_ms.clear()
	combat._next_attack_ms.clear()
	combat.dogs[1].ai_enabled = true
	place_near()
	var fight_started_ms: int = Time.get_ticks_msec()
	set_phase("FIGHT")
	await wait_until(func() -> bool: return combat.dogs[1].ai_state == "DEAD")
	check(Time.get_ticks_msec() - fight_started_ms >= 1800, "spam/replay cannot bypass server combo recovery")
	combat.dogs[1].dead_until_ms = Time.get_ticks_msec() + 60000
	check(combat.dogs[1].contributions.size() == 2 and combat.ground.size() == 1, "two attackers, one death and one drop")
	drop_uid = combat.ground.keys()[0]
	var drop: Dictionary = combat.ground[drop_uid]
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
	check(replies[other_peer].get("error", "") == "reserved" and combat.ground.has(drop_uid), "non-owner denied, ground retained")
	var owner_id: int = server.connected_players[owner_peer].player_id
	var filler: Array[String] = []
	for position: int in range(2, 24):
		var item: ItemInstance = ItemInstance.create(ItemDefinitions.IRON_SWORD, owner_id, [])
		check(server.database.item_store._insert_item(item, position), "full bag fixture")
		filler.append(item.uid)
	set_phase("PICKUP", owner_peer)
	await wait_until(func() -> bool: return replies.has(owner_peer))
	check(replies[owner_peer].get("error", "") == "bag_full" and combat.ground.has(drop_uid), "full bag keeps ground loot")
	for uid: String in filler:
		db.query_with_bindings("DELETE FROM item_placements WHERE item_uid=?;", [uid])
		db.query_with_bindings("DELETE FROM item_instances WHERE uid=?;", [uid])
	world.characters[owner_peer].position = Vector3(-12, 0, 12)
	await get_tree().create_timer(0.15).timeout
	set_phase("PICKUP", owner_peer)
	await wait_until(func() -> bool: return replies.has(owner_peer))
	check(replies[owner_peer].get("error", "") == "distance", "remote pickup denied")
	world.characters[owner_peer].position = drop.position + Vector3(0.5, 0, 0.5)
	combat.ground[drop_uid].protected_until = 0 # exercise public phase without a 15s wait
	await get_tree().create_timer(0.15).timeout
	set_phase("RACE")
	await wait_until(func() -> bool: return replies.size() == 2)
	var winners: int = 0
	var winner_id: int = 0
	for id: int in replies:
		if replies[id].ok:
			winners += 1
			winner_id = server.connected_players[id].player_id
	check(winners == 1 and combat.ground.is_empty(), "double pickup has one winner")
	check(db.query("SELECT COUNT(*) AS n FROM item_instances;") and db.query_result[0].n == 5, "one additional persistent instance")
	check(db.query("SELECT COUNT(*) AS n FROM ground_item_claims;") and db.query_result[0].n == 1, "one durable receipt")
	await get_tree().create_timer(0.2).timeout
	set_phase("REPLAY")
	await wait_until(func() -> bool: return replies.size() == 2)
	for result: Dictionary in replies.values(): check(result.get("error", "") == "gone", "replay after despawn denied")
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

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed > 40:
		check(false, "timeout phase=" + phase_name)
		return
	if GameMode.is_world_server() or world == null or world.combat_endpoint.state.is_empty(): return
	if not ready_peers.has(world.local_peer):
		ready_peers[world.local_peer] = true
		register_ready.rpc_id(1)
	var combat: SpikeCombat3D = world.combat_endpoint
	saw_damage = saw_damage or combat.dogs[1].hp < SpikeCombat3D.MOB_HP
	saw_death = saw_death or combat.dogs[1].ai_state == "DEAD"
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
