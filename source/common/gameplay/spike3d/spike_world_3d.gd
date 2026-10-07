class_name SpikeWorld3D
extends Node3D
## Shared RPC endpoint under the authenticated TinyMMO instance path.
## Position never comes from a client: only a bounded movement intention does.

const INPUT_INTERVAL: float = 1.0 / 20.0
const INPUT_TIMEOUT_MS: int = 250
const SNAPSHOT_INTERVAL: float = 1.0 / 20.0
var characters: Dictionary[int, SpikeCharacter3D] = {}
var intentions: Dictionary[int, Dictionary] = {}
var local_peer: int = 0
var input_enabled: bool = true
var _server: bool = false
var _sequence: int = 0
var _input_accum: float = 0.0
var _snapshot_accum: float = 0.0
var _camera: Camera3D
var _status: Label
var inventory_endpoint: SpikeInventory3D
var combat_endpoint: SpikeCombat3D

func _ready() -> void:
	_server = GameMode.is_world_server()
	_build_arena()
	inventory_endpoint = SpikeInventory3D.new()
	inventory_endpoint.name = "Inventory"
	add_child(inventory_endpoint)
	combat_endpoint = SpikeCombat3D.new()
	combat_endpoint.name = "Combat"
	add_child(combat_endpoint)
	if not _server:
		local_peer = multiplayer.get_unique_id()
		_build_camera_and_ui()
		join_world.rpc_id.call_deferred(1)

func _build_arena() -> void:
	_box("Floor", Vector3(0, -0.25, 0), Vector3(32, 0.5, 32), Color("374957"))
	_box("North", Vector3(0, 1, -16), Vector3(32, 2, 0.5), Color("637583"))
	_box("South", Vector3(0, 1, 16), Vector3(32, 2, 0.5), Color("637583"))
	_box("West", Vector3(-16, 1, 0), Vector3(0.5, 2, 32), Color("637583"))
	_box("East", Vector3(16, 1, 0), Vector3(0.5, 2, 32), Color("637583"))
	_box("Obstacle", Vector3(0, 1, -4), Vector3(4, 2, 2), Color("c18d55"))
	_box("Pillar", Vector3(6, 1.5, 3), Vector3(2, 3, 2), Color("668a7b"))
	# Tile seams give movement a visible scale without importing demo assets.
	for axis: int in range(-14, 16, 2):
		_decoration(Vector3(axis, 0.006, 0), Vector3(0.025, 0.01, 31), Color("4b616c"))
		_decoration(Vector3(0, 0.007, axis), Vector3(31, 0.01, 0.025), Color("4b616c"))
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -30, 0)
	light.light_energy = 1.2
	light.shadow_enabled = true
	add_child(light)
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color("172531")
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("c2d6ea")
	settings.ambient_light_energy = 0.65
	environment.environment = settings
	add_child(environment)

func _box(node_name: String, center: Vector3, dimensions: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	body.name = node_name
	body.position = center
	body.collision_layer = 1
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = dimensions
	collision.shape = shape
	body.add_child(collision)
	add_child(body)
	_mesh(body, dimensions, color)

func _decoration(center: Vector3, dimensions: Vector3, color: Color) -> void:
	var node := Node3D.new()
	node.position = center
	add_child(node)
	_mesh(node, dimensions, color)

func _mesh(parent: Node3D, dimensions: Vector3, color: Color) -> void:
	var visual := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = dimensions
	visual.mesh = box
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.9
	visual.material_override = material
	parent.add_child(visual)

func _build_camera_and_ui() -> void:
	DisplayServer.window_set_title("Mandate of Three — Spike 3D | %d" % local_peer)
	_camera = Camera3D.new()
	_camera.position = Vector3(0, 13, 12)
	_camera.fov = 55
	_camera.current = true
	add_child(_camera)
	_camera.look_at(Vector3.ZERO)
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var panel := PanelContainer.new()
	panel.position = Vector2(20, 20)
	canvas.add_child(panel)
	_status = Label.new()
	_status.text = "Mandate of Three · Spike 3D\nWASD — ruch · I — ekwipunek\nŁączenie ze światem…"
	_status.add_theme_font_size_override("font_size", 18)
	panel.add_child(_status)

@rpc("any_peer", "call_remote", "reliable", 0)
func join_world() -> void:
	if not _server:
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	var host: ServerInstance = get_parent() as ServerInstance
	if host == null or not host.awaiting_peers.has(peer_id) or characters.has(peer_id):
		return
	var resource: PlayerResource = WorldServer.curr.connected_players.get(peer_id)
	if resource == null:
		return
	host.awaiting_peers.erase(peer_id)
	host.connected_peers.append(peer_id)
	resource.current_instance = host.instance_resource.instance_name
	var body: SpikeCharacter3D = _add_character(peer_id, resource.display_name)
	body.position = Vector3(-3 + (characters.size() - 1) % 5 * 1.5, 0.1, 3)
	intentions[peer_id] = {"direction": Vector2.ZERO, "sequence": -1, "time": 0}
	_send_roster()
	inventory_endpoint.initialize_peer(peer_id)
	combat_endpoint.initialize_peer(peer_id)
	print("SPIKE3D_JOIN: ", peer_id)

func remove_peer(peer_id: int) -> void:
	if _server:
		var resource: PlayerResource = WorldServer.curr.connected_players.get(peer_id)
		if resource != null and WorldServer.curr.database != null:
			WorldServer.curr.database.flush_progression(resource.player_id)
	combat_endpoint.remove_peer(peer_id)
	inventory_endpoint.remove_peer(peer_id)
	intentions.erase(peer_id)
	if characters.has(peer_id):
		characters[peer_id].queue_free()
		characters.erase(peer_id)
	var host: ServerInstance = get_parent() as ServerInstance
	if host != null:
		host.connected_peers.erase(peer_id)
		host.awaiting_peers.erase(peer_id)
	# Let the multiplayer API finish dispatching simultaneous disconnects first.
	_send_roster.call_deferred()

func _send_roster() -> void:
	var roster: Dictionary = {}
	for peer_id: int in characters:
		var resource: PlayerResource = WorldServer.curr.connected_players.get(peer_id)
		if resource != null:
			roster[peer_id] = resource.display_name
	for peer_id: int in characters:
		receive_roster.rpc_id(peer_id, roster)

@rpc("authority", "call_remote", "reliable", 0)
func receive_roster(roster: Dictionary) -> void:
	if _server:
		return
	for peer_id: int in characters.keys():
		if not roster.has(peer_id):
			inventory_endpoint.remove_peer(peer_id)
			characters[peer_id].queue_free()
			characters.erase(peer_id)
	for peer_id: int in roster:
		if not characters.has(peer_id):
			_add_character(peer_id, str(roster[peer_id]))
	_status.text = "Mandate of Three · Spike 3D\nWASD — ruch · I — ekwipunek\nGracze: %d" % characters.size()

func _add_character(peer_id: int, display_name: String) -> SpikeCharacter3D:
	var body := SpikeCharacter3D.new()
	body.name = "Character_%d" % peer_id
	body.setup(display_name, Color.from_hsv(float(peer_id % 360) / 360.0, 0.55, 0.9))
	add_child(body)
	characters[peer_id] = body
	if inventory_endpoint != null and inventory_endpoint.public_weapons.has(peer_id):
		body.set_weapon(inventory_endpoint.public_weapons[peer_id])
	return body

@rpc("any_peer", "call_remote", "unreliable_ordered", 2)
func submit_input(sequence: int, direction: Vector2) -> void:
	if not _server or not direction.is_finite() or sequence < 0 or sequence > 2147483647:
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if not intentions.has(peer_id):
		return
	var previous: Dictionary = intentions[peer_id]
	if sequence <= int(previous.sequence):
		return
	# Bounded storage and work: even a packet flood cannot advance physics.
	intentions[peer_id] = {"direction": direction.limit_length(), "sequence": sequence, "time": Time.get_ticks_msec()}

func _physics_process(delta: float) -> void:
	if _server:
		for peer_id: int in characters:
			var intent: Dictionary = intentions[peer_id]
			var direction: Vector2 = intent.direction
			if Time.get_ticks_msec() - int(intent.time) > INPUT_TIMEOUT_MS:
				direction = Vector2.ZERO
			if not combat_endpoint.can_move(peer_id):
				direction = Vector2.ZERO
			characters[peer_id].simulate(delta, direction)
		_snapshot_accum += delta
		if _snapshot_accum >= SNAPSHOT_INTERVAL:
			_snapshot_accum = fmod(_snapshot_accum, SNAPSHOT_INTERVAL)
			_broadcast_snapshot()
	elif input_enabled and characters.has(local_peer):
		_input_accum += delta
		if _input_accum >= INPUT_INTERVAL:
			_input_accum = fmod(_input_accum, INPUT_INTERVAL)
			_sequence += 1
			var direction := Input.get_vector("player_move_left", "player_move_right", "player_move_up", "player_move_down")
			direction = combat_endpoint.assist_direction(direction)
			if ClientState.menu_open or not DisplayServer.window_is_focused():
				direction = Vector2.ZERO
			submit_input.rpc_id(1, _sequence, direction)

func _broadcast_snapshot() -> void:
	var snapshot: Dictionary = {}
	for peer_id: int in characters:
		var body: SpikeCharacter3D = characters[peer_id]
		snapshot[peer_id] = [body.position, body.rotation.y]
	for peer_id: int in characters:
		receive_snapshot.rpc_id(peer_id, snapshot)

@rpc("authority", "call_remote", "unreliable_ordered", 2)
func receive_snapshot(snapshot: Dictionary) -> void:
	if _server:
		return
	var local_was_ready: bool = characters.has(local_peer) and characters[local_peer].has_snapshot
	for peer_id: int in snapshot:
		if characters.has(peer_id):
			var state: Array = snapshot[peer_id]
			characters[peer_id].apply_snapshot(state[0], state[1])
	if not local_was_ready and characters.has(local_peer) and characters[local_peer].has_snapshot:
		ClientState.world_ready.emit(characters[local_peer])

func _process(delta: float) -> void:
	if _server:
		return
	for body: SpikeCharacter3D in characters.values():
		body.interpolate(delta)
	if characters.has(local_peer) and characters[local_peer].has_snapshot:
		var center: Vector3 = characters[local_peer].position
		_camera.position = _camera.position.lerp(center + Vector3(0, 13, 12), 1.0 - exp(-10.0 * delta))
		_camera.look_at(center + Vector3(0, 0.5, 0))
