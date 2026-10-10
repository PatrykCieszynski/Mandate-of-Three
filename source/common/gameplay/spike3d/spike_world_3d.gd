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
var _npc_approach := NpcApproach.new()
var _npc_preselected_item: Dictionary = {}
var _npc_repath_ms: int = 0
var _npc_approach_until_ms: int = 0
var _camera: Camera3D
var camera_controller: MandateCamera3D
var _options: Navigator
var _ui_failure_label: Label
var _status: Label
var inventory_endpoint: SpikeInventory3D
var combat_endpoint: SpikeCombat3D
var upgrade_endpoint: Upgrade3D
var shop_endpoint: Shop3D
var npc_endpoint: NpcInteraction3D
var metin_encounter: MetinEncounter
var region: FirstRegionGraybox
var currency_endpoint: SpikeCurrency3D

func _ready() -> void:
	_server = GameMode.is_world_server()
	region = get_node_or_null("Region") as FirstRegionGraybox
	_build_arena()
	inventory_endpoint = SpikeInventory3D.new()
	inventory_endpoint.name = "Inventory"
	add_child(inventory_endpoint)
	combat_endpoint = SpikeCombat3D.new()
	combat_endpoint.name = "Combat"
	add_child(combat_endpoint)
	currency_endpoint = SpikeCurrency3D.new()
	currency_endpoint.name = "Currency"
	add_child(currency_endpoint)
	npc_endpoint = NpcInteraction3D.new()
	npc_endpoint.name = "NpcInteraction"
	add_child(npc_endpoint)
	shop_endpoint = Shop3D.new()
	shop_endpoint.name = "Shop"
	add_child(shop_endpoint)
	upgrade_endpoint = Upgrade3D.new()
	upgrade_endpoint.name = "Upgrade"
	add_child(upgrade_endpoint)
	var blacksmith := preload("res://source/common/gameplay/npcs/blacksmith_fixture.tscn").instantiate() as NeutralNpc3D
	if region != null: blacksmith.position = FirstRegionGraybox.BLACKSMITH
	add_child(blacksmith)
	if not npc_endpoint.register_actor(blacksmith):
		push_error("Invalid Blacksmith content/instance")
		blacksmith.queue_free()
	if region != null:
		metin_encounter = MetinEncounter.new()
		metin_encounter.name = "MetinEncounter"
		add_child(metin_encounter)
	if not _server:
		local_peer = multiplayer.get_unique_id()
		_build_camera_and_ui()
		if WebUiHost.supported_client():
			var web_inventory := InventoryWebController.new()
			web_inventory.name = "WebInventory"
			add_child(web_inventory)
			web_inventory.setup(self)
		elif DisplayServer.get_name() != "headless":
			show_ui_failure("CEF requires Vulkan Mobile and the installed addon")
		join_world.rpc_id.call_deferred(1)

func player_spawn(index: int = 0) -> Vector3:
	return region.player_spawn(index) if region != null else Vector3(-3 + index % 5 * 1.5, 0.1, 3)

func _build_arena() -> void:
	if region == null:
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
	body.collision_layer = 17 if node_name == "Floor" else 1
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
	DisplayServer.window_set_title("Mandate of Three — %s | %d" % ["First Region" if region != null else "Spike 3D", local_peer])
	camera_controller = MandateCamera3D.new()
	camera_controller.name = "CameraRig"
	camera_controller.can_control = func() -> bool: return input_enabled and not ClientState.menu_open and DisplayServer.window_is_focused() and characters.has(local_peer)
	add_child(camera_controller)
	_camera = camera_controller.camera
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var panel := PanelContainer.new()
	panel.position = Vector2(20, 20)
	canvas.add_child(panel)
	_status = Label.new()
	_status.text = "Mandate of Three · %s\nWASD — ruch · PPM — kamera · rolka — zoom\nI — ekwipunek · N — NPC\nŁączenie ze światem…" % ("First Region" if region != null else "Spike 3D")
	_status.add_theme_font_size_override("font_size", 18)
	var controls := VBoxContainer.new()
	panel.add_child(controls)
	controls.add_child(_status)
	var options_button := Button.new()
	options_button.text = "Options"
	options_button.focus_mode = Control.FOCUS_NONE
	controls.add_child(options_button)
	_ui_failure_label = Label.new()
	_ui_failure_label.custom_minimum_size.x = 300
	_ui_failure_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ui_failure_label.add_theme_font_size_override("font_size", 12)
	_ui_failure_label.hide()
	controls.add_child(_ui_failure_label)
	var options_layer := CanvasLayer.new()
	options_layer.layer = 20
	add_child(options_layer)
	_options = load("res://source/client/ui/menus/settings/settings_menu.tscn").instantiate() as Navigator
	_options.hide()
	options_layer.add_child(_options)
	_options.visibility_changed.connect(func() -> void:
		if _options.visible:
			_npc_approach.cancel()
			var inventory: Node = get_node_or_null("WebInventory")
			if inventory != null: inventory.set_open(false)
		ClientState.menu_open = _options.visible
		input_enabled = not _options.visible
		if not _options.visible: get_viewport().gui_release_focus())
	options_button.pressed.connect(func() -> void: _options.show())

func show_ui_failure(reason: String) -> void:
	push_warning("Web inventory unavailable: " + reason)
	if not is_instance_valid(_ui_failure_label): return
	_ui_failure_label.text = "Inventory UI unavailable. " + reason
	_ui_failure_label.show()

func _input(event: InputEvent) -> void:
	if _server or _npc_approach.target_id.is_empty(): return
	if event is InputEventKey and event.pressed and event.physical_keycode in [KEY_ESCAPE, KEY_SPACE, KEY_F]:
		_npc_approach.cancel()

func _unhandled_key_input(event: InputEvent) -> void:
	if is_instance_valid(_options) and _options.visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_options.hide()
		get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if _server or not input_enabled or ClientState.menu_open or not characters.has(local_peer): return
	var npc_id: String = ""
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var origin: Vector3 = _camera.project_ray_origin(event.position)
		var ray := PhysicsRayQueryParameters3D.create(origin, origin + _camera.project_ray_normal(event.position) * 100, 8)
		var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(ray)
		var npc: NeutralNpc3D = hit.get("collider") as NeutralNpc3D
		if npc != null: npc_id = npc.instance_id
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_N:
		var nearest: float = INF
		for actor: NeutralNpc3D in npc_endpoint.actors.values():
			var distance: float = characters[local_peer].global_position.distance_to(actor.global_position)
			if actor.interactable and distance <= actor.definition.interaction_radius and distance < nearest:
				nearest = distance
				npc_id = actor.instance_id
	if npc_id != "":
		begin_npc_approach(npc_id)
		get_viewport().set_input_as_handled()

func begin_npc_approach(instance_id: String, preselected_item: Dictionary = {}) -> bool:
	var actor: NeutralNpc3D = npc_endpoint.actors.get(instance_id)
	if _server or not input_enabled or ClientState.menu_open or not characters.has(local_peer) or not characters[local_peer].alive or not is_instance_valid(actor) or not actor.interactable: return false
	_npc_approach.start(instance_id)
	_npc_preselected_item = preselected_item.duplicate(true)
	_npc_repath_ms = 0
	_npc_approach_until_ms = Time.get_ticks_msec() + 15000
	combat_endpoint.autoattack = false
	return true

func _npc_direction(manual: Vector2) -> Vector2:
	if _npc_approach.target_id.is_empty(): return combat_endpoint.assist_direction(manual)
	var actor: NeutralNpc3D = npc_endpoint.actors.get(_npc_approach.target_id)
	var body: SpikeCharacter3D = characters[local_peer]
	var now: int = Time.get_ticks_msec()
	if not is_instance_valid(actor) or not actor.interactable or actor.definition == null or not body.alive or now >= _npc_approach_until_ms:
		_npc_approach.cancel()
		return manual
	var map: RID = get_world_3d().navigation_map
	if now >= _npc_repath_ms and NavigationServer3D.map_get_iteration_id(map) > 0:
		_npc_approach.set_path(NavigationServer3D.map_get_path(map, body.target_position, actor.global_position, true))
		_npc_repath_ms = now + 200
	var result: Dictionary = _npc_approach.step(body.target_position, actor.global_position, actor.definition.interaction_radius, manual)
	if not str(result.interact).is_empty():
		var ui: InventoryWebController = get_node_or_null("WebInventory")
		if ui != null: ui.interact_npc(result.interact,_npc_preselected_item)
		_npc_preselected_item = {}
	return result.direction

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
	body.position = player_spawn(characters.size() - 1)
	intentions[peer_id] = {"direction": Vector2.ZERO, "sequence": -1, "time": 0}
	_send_roster()
	inventory_endpoint.initialize_peer(peer_id)
	currency_endpoint.initialize_peer(peer_id)
	combat_endpoint.initialize_peer(peer_id)
	print("SPIKE3D_JOIN: ", peer_id)

func remove_peer(peer_id: int) -> void:
	if _server:
		var resource: PlayerResource = WorldServer.curr.connected_players.get(peer_id)
		if resource != null and WorldServer.curr.database != null:
			WorldServer.curr.database.flush_character(resource.player_id)
	upgrade_endpoint.remove_peer(peer_id)
	shop_endpoint.remove_peer(peer_id)
	npc_endpoint.remove_peer(peer_id)
	combat_endpoint.remove_peer(peer_id)
	currency_endpoint.remove_peer(peer_id)
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
	_status.text = "Mandate of Three · %s\nWASD — ruch · PPM — kamera · rolka — zoom\nI — ekwipunek · N — NPC\nGracze: %d" % ["First Region" if region != null else "Spike 3D", characters.size()]

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
			if ClientState.menu_open or not DisplayServer.window_is_focused():
				_npc_approach.cancel()
				direction = Vector2.ZERO
			else:
				direction = _npc_direction(camera_controller.movement_direction(direction))
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
	if camera_controller.orbiting and not camera_controller.can_control.call(): camera_controller.cancel_orbit()
	for body: SpikeCharacter3D in characters.values():
		body.interpolate(delta)
	if characters.has(local_peer) and characters[local_peer].has_snapshot:
		camera_controller.update_camera(delta, characters[local_peer].global_position, camera_controller.can_control.call())
