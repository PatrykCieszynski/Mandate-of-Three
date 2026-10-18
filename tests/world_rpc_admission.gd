extends Node
## The risk is cross-instance/unauthenticated dispatch and client-selected script
## paths. Use real two-client RPCs and the production dispatcher/lookup/handlers;
## only admission setup and map rendering are controlled, with no database.
class Session extends WorldServer:
	var answers: Dictionary = {}
	var master_disconnects: Array[String] = []
	func _notify_master_disconnected(account_name: String, _session_token: String = "") -> void:
		master_disconnects.append(account_name)
	@rpc("authority", "call_remote", "reliable", 1)
	func _data_response(id: int, _type: String, data: Dictionary) -> void:
		answers[id] = data

class Instance extends LegacyServerInstance2D:
	func _ready() -> void:
		pass

class MembershipMap extends GameWorld3D:
	func _ready() -> void:
		pass # Admission state only; actual 3D simulation is covered by PvE.

var bodies: Array[PlayerActor3D] = []
var socket := WebSocketMultiplayerPeer.new()
var session: Session
var manager: InstanceManagerServer
var context := ""
var own_instance := ""
var sequence := 0
var assignments: Dictionary = {}
var finished_peers: Dictionary = {}
var actors: Array[Player] = []
var elapsed := 0.0

func _ready() -> void:
	BaseMultiplayerEndpoint.configure_peer(socket)
	var api := multiplayer as SceneMultiplayer
	api.server_relay = false
	session = Session.new()
	session.name = "Session"
	add_child(session)
	manager = InstanceManagerServer.new()
	manager.name = "Instances"
	manager.world_server = session
	session.instance_manager = manager
	session.add_child(manager)
	ServerInstance.world_server = session
	for id: String in ["One", "Two"]:
		var instance := Instance.new()
		instance.name = id
		instance.instance_resource = InstanceResource.new()
		instance.instance_resource.instance_name = id
		instance.instance_resource.charged_instances.append(instance)
		manager.instance_collection[id] = instance.instance_resource
		manager.add_child(instance)
	manager.default_instance = manager.instance_collection.One
	if GameMode.is_world_server():
		assert(socket.create_server(18098, "127.0.0.1") == OK)
		api.multiplayer_peer = socket
		api.peer_connected.connect(func(peer: int) -> void:
			assignments[peer] = "One" if assignments.is_empty() else "Two")
	else:
		assert(socket.create_client("ws://127.0.0.1:18098") == OK)
		api.multiplayer_peer = socket
		api.connected_to_server.connect(run_client)

func _process(delta: float) -> void:
	elapsed += delta
	assert(elapsed < 25, "World RPC fixture timeout")

@rpc("any_peer", "call_remote", "reliable", 0)
func set_context(mode: String) -> void:
	if not GameMode.is_world_server(): return
	var peer := multiplayer.get_remote_sender_id()
	var id: String = assignments[peer]
	var instance := manager.get_instance_server_by_id(id)
	if not session.connected_players.has(peer):
		var player := PlayerResource.new()
		player.player_id = 101 if id == "One" else 102
		player.account_name = "alpha" if id == "One" else "beta"
		player.level = 3 if id == "One" else 7
		session.connected_players[peer] = player
		var actor := Player.new()
		actor.player_resource = player
		actors.append(actor)
		instance.players_by_peer_id[peer] = actor
	var player: PlayerResource = session.connected_players[peer]
	instance.players_by_peer_id[peer].player_resource = PlayerResource.new() if mode == "wrong_actor" else player
	player.current_instance = id
	player.current_peer_id = 0 if mode == "wrong_peer" else peer
	session.player_id_to_peer_id[player.player_id] = 0 if mode == "wrong_owner" else peer
	instance.connected_peers.erase(peer)
	instance.awaiting_peers.erase(peer)
	if mode == "awaiting": instance.awaiting_peers[peer] = {}
	else: instance.connected_peers.append(peer)
	instance.instance_resource.use_3d = mode.begins_with("3d_")
	if instance.instance_resource.use_3d:
		var world := instance.get_node_or_null("GameWorld") as GameWorld3D
		if world == null:
			world = MembershipMap.new()
			world.name = "GameWorld"
			world.process_mode = Node.PROCESS_MODE_DISABLED
			instance.add_child(world)
		world.characters.clear()
		if mode == "3d_joined":
			var body := PlayerActor3D.new()
			bodies.append(body)
			world.characters[peer] = body
	if mode in ["relogin_shared", "relogin_distinct"]:
		# Mirror the completed authentication boundary: the new peer owns the
		# character before an old peer's queued disconnect is delivered.
		var old_peer := 100
		while session.connected_players.has(old_peer): old_peer += 1
		var old_player: PlayerResource = player if mode == "relogin_shared" else player.duplicate()
		old_player.current_peer_id = old_peer
		session.connected_players[old_peer] = old_player
		session.player_id_to_peer_id[player.player_id] = old_peer
		session.connected_players[peer] = player
		player.current_peer_id = peer
		session.player_id_to_peer_id[player.player_id] = peer
		session.runtime_equipment[player.player_id] = {"stats": {"attack": 37}}
		var disconnect_count := session.master_disconnects.size()
		session._on_peer_disconnected(old_peer)
		session._on_peer_disconnected(old_peer) # duplicate/unknown disconnect is safe.
		assert(not session.connected_players.has(old_peer))
		assert(session.runtime_attack(player.player_id) == 37, "old disconnect invalidated new combat stats")
		assert(session.master_disconnects.size() == disconnect_count, "old peer disconnected the new account session at Master")
	context_ready.rpc_id(peer, mode, id)

@rpc("authority", "call_remote", "reliable", 0)
func context_ready(mode: String, id: String) -> void:
	context = mode
	own_instance = id

func query(type: StringName, instance: String = "") -> Dictionary:
	sequence += 1
	var id := sequence
	session._data_request.rpc_id(1, id, type, {"a-id": 999, "peer": 999}, instance)
	while not session.answers.has(id): await get_tree().process_frame
	return session.answers[id]

func change_context(mode: String) -> void:
	context = ""
	set_context.rpc_id(1, mode)
	while context != mode: await get_tree().process_frame

func run_client() -> void:
	var result := await query(&"progression.get", "One")
	assert(result.get("error") == ERR_UNAUTHORIZED, "unregistered session reached a handler")
	await change_context("joined")
	var expected_level := 3 if own_instance == "One" else 7
	for id: String in [own_instance, ""]:
		result = await query(&"progression.get", id)
		assert(result.get("level") == expected_level, "omitted/explicit ID must use caller's own instance")
	for id: String in ["Two" if own_instance == "One" else "One", "unknown", "../", ".", "/root", "One/../Two", "%One", "One:resource"]:
		result = await query(&"progression.get", id)
		assert(result.get("error") == ERR_UNAUTHORIZED, "forged instance fell back or crossed scope: " + id)
	for type: StringName in [&"data_request_handler", &"../world_server", &"../../world_server", &"unknown.operation"]:
		result = await query(type, own_instance)
		assert(result.get("error") == ERR_INVALID_PARAMETER, "unlisted operation reached script loading")
	for mode: String in ["wrong_peer", "wrong_owner", "wrong_actor", "awaiting"]:
		await change_context(mode)
		result = await query(&"progression.get", own_instance)
		assert(result.get("error") == ERR_UNAUTHORIZED, "stale/unjoined binding admitted")
	await change_context("joined")
	result = await query(&"progression.get")
	assert(result.get("level") == expected_level)
	# A delayed old disconnect must not invalidate a newly installed session.
	for mode: String in ["relogin_shared", "relogin_distinct"]:
		await change_context(mode)
		result = await query(&"progression.get")
		assert(result.get("level") == expected_level, "new session lost RPC authority after old disconnect")
	# 3D requests require actual map actor membership, not just connected_peers.
	await change_context("3d_missing_actor")
	result = await query(&"chat.typing.set")
	assert(result.get("error") == ERR_UNAUTHORIZED)
	await change_context("3d_joined")
	result = await query(&"chat.typing.set")
	assert(result.is_empty(), "valid 3D member should reach the real world-scoped handler")
	# Legacy entry RPC must not spawn into a different replicated instance.
	var other := manager.get_instance_server_by_id("Two" if own_instance == "One" else "One")
	other.ready_to_enter_instance.rpc_id(1)
	finished.rpc_id(1)
	while context != "entry_denied_confirmed": await get_tree().process_frame
	print("WORLD_RPC_CLIENT_OK identity/operation/instance admission and recovery")
	await get_tree().create_timer(0.2).timeout
	get_tree().quit()

@rpc("any_peer", "call_remote", "reliable", 0)
func finished() -> void:
	if not GameMode.is_world_server(): return
	var peer := multiplayer.get_remote_sender_id()
	var id: String = assignments[peer]
	var own := manager.get_instance_server_by_id(id)
	var other := manager.get_instance_server_by_id("Two" if id == "One" else "One")
	var player: PlayerResource = session.connected_players[peer]
	assert(not other.players_by_peer_id.has(peer), "unauthorized legacy spawn created a foreign actor")
	assert(not other.connected_peers.has(peer) and not other.awaiting_peers.has(peer), "denied entry changed foreign membership/assignment")
	assert(own.connected_peers.has(peer) and not own.awaiting_peers.has(peer), "denied entry changed the legitimate assignment")
	assert(player.current_instance == id, "denied entry changed the character's assigned instance")
	assert(player.current_peer_id == peer and session.player_id_to_peer_id.get(player.player_id) == peer)
	assert(own.get_node("GameWorld").characters.has(peer), "denied entry removed the legitimate 3D actor")
	context_ready.rpc_id(peer, "entry_denied_confirmed", id)
	finished_peers[peer] = true
	if finished_peers.size() != 2: return
	for actor: Player in actors: actor.free()
	for body: PlayerActor3D in bodies: body.free()
	print("WORLD_RPC_SERVER_OK two isolated clients, real production ingress/handlers")
	await get_tree().create_timer(0.3).timeout
	get_tree().quit()
