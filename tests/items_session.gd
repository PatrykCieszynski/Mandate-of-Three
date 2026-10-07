extends Node
## Full gateway/master/world test; creates a local guest character.
## Requires the three normal server roles to be running. No tokens are printed here.

var request: HTTPRequest
var world: SpikeWorld3D
var updates: int = 0
var elapsed: float = 0

func _ready() -> void:
	request = HTTPRequest.new()
	add_child(request)
	ClientState.world_ready.connect(_ready_world)
	call_deferred("run")

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed > 35: fail("timeout")

func fail(reason: String) -> void:
	push_error("ITEM_SESSION_FAILED: " + reason)
	get_tree().quit(1)

func api(url: String, payload: Dictionary) -> Dictionary:
	if request.request(url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(payload)) != OK:
		fail("HTTP start")
		return {}
	var response: Array = await request.request_completed
	if response[0] != HTTPRequest.RESULT_SUCCESS or response[1] != 200:
		fail("HTTP status")
		return {}
	var result: Variant = JSON.parse_string(response[3].get_string_from_utf8())
	if not result is Dictionary or result.has("error"):
		fail("gateway response")
		return {}
	return result

func _ready_world(_player: Node) -> void:
	world = Client.instance_manager.current_instance.get_node("SpikeMap")
	world.input_enabled = false
	world.inventory_endpoint.state_changed.connect(func(_state: Dictionary) -> void: updates += 1)

func wait_inventory() -> void:
	while world == null or world.inventory_endpoint.state.is_empty():
		await get_tree().process_frame

func action(command: String, item: Dictionary, expected_error: String = "") -> void:
	await get_tree().create_timer(0.15).timeout
	var before: int = updates
	world.inventory_endpoint.request_equipment.rpc_id(1, command, str(item.uid), int(item.revision))
	while updates == before:
		await get_tree().process_frame
	if str(world.inventory_endpoint.state.get("error", "")) != expected_error:
		fail("command response")

func run() -> void:
	var index: int = int(CmdlineUtils.get_parsed_args().get("test-client", "1"))
	var session: Dictionary = await api(GatewayAPI.guest(), {})
	if session.is_empty(): return
	var worlds: Dictionary = session.get("w", {})
	if worlds.is_empty():
		fail("no world")
		return
	var world_id: int = int(worlds.keys()[0])
	var identity: Dictionary = {"w-id": world_id, "a-id": session.id, "a-u": session.name, "t-id": session.session_id}
	await api(GatewayAPI.world_characters(), identity)
	identity["data"] = {"name": "Item%d%s" % [index, str(Time.get_ticks_usec()).right(6)], "skin": 1}
	var handoff: Dictionary = await api(GatewayAPI.world_create_char(), identity)
	if handoff.is_empty(): return
	Client.connect_to_server(handoff.address, handoff.port, handoff["auth-token"])
	await wait_inventory()
	var state: Dictionary = world.inventory_endpoint.state
	if not state.ok or state.items.size() != 2:
		fail("starter kit")
		return
	var weak: Dictionary = state.items[0].duplicate(true)
	var strong: Dictionary = state.items[1].duplicate(true)
	if weak.stats.attack > strong.stats.attack:
		var swap: Dictionary = weak
		weak = strong
		strong = swap
	if weak.uid == strong.uid or weak.stats.attack != 13 or strong.stats.attack != 17:
		fail("UID and rolls")
		return
	await action("equip", weak)
	if world.inventory_endpoint.state.stats.attack != 23 or world.inventory_endpoint.state.equipment.weapon != weak.uid:
		fail("weak exact equip")
		return
	await action("equip", strong)
	if world.inventory_endpoint.state.stats.attack != 27 or world.inventory_endpoint.state.equipment.weapon != strong.uid:
		fail("strong exact equip")
		return
	await action("equip", strong, "stale")
	# Clear the expected rejection through a valid idempotent command.
	var current: Dictionary = world.inventory_endpoint.state.items[0]
	await action("equip", current)
	var persisted: Dictionary = world.inventory_endpoint.state.duplicate(true)
	while world.characters.size() < 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	for peer_id: int in world.characters:
		if world.characters[peer_id].weapon_definition_id != "iron_sword":
			fail("public equipment replication")
			return
	Client.close_connection()
	Client.instance_manager.teardown()
	world = null
	await get_tree().create_timer(1.5 + index * 0.3).timeout
	identity.erase("data")
	var characters: Dictionary = await api(GatewayAPI.world_characters(), identity)
	if characters.is_empty(): return
	var character_id: int = int(characters.keys()[0])
	handoff = await api(GatewayAPI.world_enter(), {"t-id": session.session_id, "a-u": session.name, "w-id": world_id, "c-id": character_id})
	if handoff.is_empty(): return
	Client.connect_to_server(handoff.address, handoff.port, handoff["auth-token"])
	await wait_inventory()
	if world.inventory_endpoint.state != persisted:
		fail("reconnect changed UID, rolls, revision or equipment")
		return
	while world.characters.size() < 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	for peer_id: int in world.characters:
		if world.characters[peer_id].weapon_definition_id != "iron_sword":
			fail("reconnect public equipment")
			return
	print("ITEM_SESSION_OK: ", index, " exact UID, stats, stale RPC, public weapon, reconnect persistence")
	Client.close_connection()
	get_tree().quit()
