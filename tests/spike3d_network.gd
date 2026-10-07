extends Node
## Three-process integration fixture using the production WebSocket transport.
## It supplies authenticated session resources instead of touching accounts/DB.

const PORT: int = 18097
var world: SpikeWorld3D
var server: WorldServer
var peer := WebSocketMultiplayerPeer.new()
var client_number: int = 0
var elapsed: float = 0.0
var play_elapsed: float = 0.0
var sequence: int = 0
var accumulator: float = 0.0
var failed: bool = false
var saw_two: bool = false
var saw_remote_move: bool = false
var hit_boundary: bool = false
var hit_obstacle: bool = false
var last_positions: Dictionary[int, Vector3] = {}
var initial_positions: Dictionary[int, Vector3] = {}
var stopped_position: Vector3

func _ready() -> void:
	Engine.physics_ticks_per_second = 60
	client_number = int(CmdlineUtils.get_parsed_args().get("test-client", "0"))
	var api: SceneMultiplayer = multiplayer as SceneMultiplayer
	api.server_relay = false
	if GameMode.is_world_server():
		_check(peer.create_server(PORT, "127.0.0.1") == OK, "server socket")
		api.multiplayer_peer = peer
		server = WorldServer.new()
		server.name = "Session"
		server.multiplayer_api = api
		add_child(server)
		ServerInstance.world_server = server
		var host: ServerInstance = preload("res://source/server/world/components/spike_instance_3d.gd").new()
		host.name = "Instance"
		host.instance_resource = InstanceResource.new()
		host.instance_resource.instance_name = &"Spike"
		host.load_map("res://source/common/gameplay/maps/spike/spike_map_3d.tscn")
		add_child(host)
		world = host.get_node("SpikeMap")
		api.peer_connected.connect(func(id: int) -> void:
			var resource := PlayerResource.new()
			resource.display_name = "Test_%d" % server.connected_players.size()
			server.connected_players[id] = resource
			host.awaiting_peers[id] = {})
	else:
		_check(peer.create_client("ws://127.0.0.1:%d" % PORT) == OK, "client socket")
		api.multiplayer_peer = peer
		api.connected_to_server.connect(func() -> void:
			var instance: InstanceClient = preload("res://source/client/network/spike_instance_3d.gd").new()
			instance.name = "Instance"
			world = load("res://source/common/gameplay/maps/spike/spike_map_3d.tscn").instantiate()
			world.input_enabled = false
			instance.add_child(world)
			add_child(instance))

func _check(ok: bool, message: String) -> void:
	if not ok:
		failed = true
		push_error("SPIKE3D_TEST_FAILED: " + message)
		get_tree().quit(1)

func _physics_process(delta: float) -> void:
	if failed:
		return
	elapsed += delta
	if elapsed > 25.0:
		_check(false, "timeout")
		return
	if world == null:
		return
	if GameMode.is_world_server():
		_server_checks(delta)
	else:
		_client_checks(delta)

func _server_checks(delta: float) -> void:
	saw_two = saw_two or world.characters.size() == 2
	for id: int in world.characters:
		var pos: Vector3 = world.characters[id].position
		_check(pos.is_finite() and absf(pos.x) < 15.6 and absf(pos.z) < 15.6 and pos.y > -0.1, "finite position inside arena")
		if last_positions.has(id):
			var change: Vector3 = pos - last_positions[id]
			_check(Vector2(change.x, change.z).length() <= SpikeCharacter3D.SPEED * delta + 0.025, "packet flood/large direction cannot increase speed")
		last_positions[id] = pos
		hit_boundary = hit_boundary or pos.x > 15.2
		hit_obstacle = hit_obstacle or (absf(pos.x) < 2.2 and pos.z < -2.5 and pos.z > -2.8)
	if elapsed > 19.0:
		print("SPIKE3D_COLLISION_CHECK: two=", saw_two, " wall=", hit_boundary, " obstacle=", hit_obstacle)
		_check(saw_two and hit_boundary and hit_obstacle, "two peers, wall and obstacle collision")
		_check(world.characters.is_empty() and world.intentions.is_empty(), "disconnect removes bodies and input")
		if not failed:
			print("SPIKE3D_SERVER_OK: two peers, speed cap, collisions, disconnect cleanup")
			peer.close()
			get_tree().quit()

func _client_checks(delta: float) -> void:
	if not world.characters.has(world.local_peer) or not world.characters[world.local_peer].has_snapshot:
		return
	play_elapsed += delta
	saw_two = saw_two or world.characters.size() == 2
	for id: int in world.characters:
		var body: SpikeCharacter3D = world.characters[id]
		if not body.has_snapshot:
			continue
		if not initial_positions.has(id):
			initial_positions[id] = body.target_position
		if id != world.local_peer and body.target_position.distance_to(initial_positions[id]) > 1.0:
			saw_remote_move = true
	accumulator += delta
	if accumulator >= 0.05:
		accumulator = fmod(accumulator, 0.05)
		sequence += 1
		if play_elapsed < 10.0 or play_elapsed >= 12.0:
			var direction := Vector2.ZERO
			if play_elapsed > 1.0 and play_elapsed < 10.0:
				if client_number == 1:
					direction = Vector2(100, 100) if play_elapsed < 3.0 else Vector2.RIGHT
				else:
					# Join order is nondeterministic. Reach the obstacle lane from
					# either spawn before walking north into its collision shape.
					var x: float = world.characters[world.local_peer].target_position.x
					if play_elapsed < 3.0 and absf(x + 1.0) > 0.2:
						direction = Vector2(signf(-1.0 - x), 0)
					else:
						direction = Vector2.UP
			world.submit_input.rpc_id(1, sequence, direction)
			# Same sequence must not replace the accepted direction. NaN must not
			# poison physics or consume the next sequence.
			world.submit_input.rpc_id(1, sequence, -direction)
			world.submit_input.rpc_id(1, sequence + 1, Vector2(NAN, 0))
	if play_elapsed >= 10.6 and play_elapsed < 10.6 + delta:
		stopped_position = world.characters[world.local_peer].target_position
	if play_elapsed >= 11.6 and play_elapsed < 11.6 + delta:
		_check(world.characters[world.local_peer].target_position.distance_to(stopped_position) < 0.05, "stale input stops movement")
	if play_elapsed > 14.0:
		_check(saw_two and saw_remote_move, "roster and remote movement snapshots")
		if not failed:
			print("SPIKE3D_CLIENT_OK: ", client_number, " roster, remote movement, input timeout")
			peer.close()
			get_tree().quit()
