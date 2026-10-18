extends Node
## Concrete regression: World replies reordered across login/enter/create must
## pass through the real Master callbacks without issuing a stale usable ticket.
class Accounts extends AuthenticationManager:
	func save_account_collection() -> void:
		pass
	func validate_credentials(username: String, _password: String) -> AccountResource:
		return account_collection.collection.get(username)

class Master extends WorldManagerServer:
	var responses: Dictionary[int, Dictionary] = {}
	func _ready() -> void:
		pass
	func _entry_response(_gateway: int, request: int, response: Dictionary) -> void:
		assert(not responses.has(request), "multiple terminal responses")
		responses[request] = response
	func _on_peer_disconnected(_id: int) -> void:
		pass # Fixture transport teardown has no Gateway roster to broadcast.

class World extends WorldManagerClient:
	var ready_for_test := false
	var requests: Dictionary[int, Dictionary] = {}
	var tickets: Array[String] = []
	var usable: Array[String] = []
	func _on_connection_succeeded() -> void:
		ready_for_test = true
	func _on_server_disconnected() -> void:
		pass
	@rpc("authority")
	func request_login(gateway: int, request: int, username: String, character: int, attempt: String) -> void:
		requests[request] = {"gateway": gateway, "username": username, "character": character, "attempt": attempt, "create": false}
	@rpc("authority")
	func create_player_character_request(gateway: int, request: int, username: String, _data: Dictionary, _account: int, attempt: String) -> void:
		requests[request] = {"gateway": gateway, "username": username, "character": 0, "attempt": attempt, "create": true}
	@rpc("authority")
	func fetch_token(token: String, _username: String, _character: int, _account: int, _inventory_context: Dictionary = {}) -> void:
		tickets.append(token)
		usable.append(token)
	@rpc("authority")
	func master_kick(_character: int) -> void:
		pass # No combat actors in the controlled worker.
	@rpc("authority")
	func revoke_account_admission(_username: String) -> void:
		usable.clear()
	func reply(request: int, result: int = OK) -> void:
		var entry: Dictionary = requests[request]
		if entry.create:
			player_character_creation_result.rpc_id(1, entry.gateway, request, entry.username, result, entry.attempt)
		else:
			result_login.rpc_id(1, result, entry.gateway, request, entry.username, entry.character, entry.attempt)

var master := Master.new()
var world := World.new()
var gateway := GatewayManagerServer.new()
var accounts := Accounts.new()
var identity := AccountResource.new()
var world_id := 0

func _ready() -> void:
	run.call_deferred()

func wait_for(check: Callable) -> void:
	var deadline := Time.get_ticks_msec() + 3000
	while not check.call():
		assert(Time.get_ticks_msec() < deadline, "Master reply fixture timeout")
		await get_tree().process_frame

func enter(request: int) -> void:
	gateway.request_enter_world(9, request, "alpha", world_id, 41)
	await wait_for(func() -> bool: return world.requests.has(request))

func create_character(request: int) -> void:
	gateway.create_player_character_request(9, request, "alpha", {"name": "Test"}, world_id)
	await wait_for(func() -> bool: return world.requests.has(request))

func run() -> void:
	identity.username = "alpha"
	identity.id = 21
	accounts.account_collection = AccountResourceCollection.new()
	accounts.account_collection.collection["alpha"] = identity
	master.authentication_manager = accounts
	gateway.authentication_manager = accounts
	gateway.world_manager = master
	master.name = "Master"
	world.name = "World"
	add_child(master)
	add_child(world)
	assert(master.create(BaseMultiplayerEndpoint.Role.SERVER, "127.0.0.1", 18098) == OK)
	assert(world.create(BaseMultiplayerEndpoint.Role.CLIENT, "127.0.0.1", 18098) == OK)
	await wait_for(func() -> bool: return world.ready_for_test)
	world_id = world.multiplayer_api.get_unique_id()
	master.connected_worlds[world_id] = {"info": {"name": "Fixture"}, "address": "127.0.0.1", "port": 18098}

	# Login B invalidates A before A's World reply, even when B has not entered.
	await enter(100)
	assert(not gateway.login_request("alpha", "fixture").has("error"))
	world.reply(100)
	await get_tree().create_timer(0.6).timeout
	assert(world.tickets.is_empty() and not master.responses.has(100) and identity.peer_id == 0)

	# B wins; A's late success/error and a duplicate B must issue no extra ticket
	# and must not reject B while its normal 0.5-second handoff delay is running.
	await enter(101)
	assert(not gateway.login_request("alpha", "fixture").has("error"))
	await enter(102)
	world.reply(102)
	await wait_for(func() -> bool: return world.tickets.size() == 1)
	world.reply(101)
	world.reply(101, ERR_UNAUTHORIZED)
	world.reply(102)
	await wait_for(func() -> bool: return master.responses.has(102))
	assert(master.responses.size() == 1 and world.tickets.size() == 1 and world.usable == world.tickets)
	assert(master.responses[102]["auth-token"] == world.tickets[0] and identity.peer_id == 102)
	assert(master.retire_world_session(world_id, "alpha", world.tickets[0]), "new marker survived stale replies")

	# New enter alone supersedes an earlier one, without requiring another login.
	await enter(103)
	await enter(104)
	world.reply(103) # Old success arrives while newer work is still pending.
	world.reply(104)
	await wait_for(func() -> bool: return master.responses.has(104))
	assert(not master.responses.has(103) and world.tickets.size() == 2 and identity.peer_id == 104)

	# Creating a character shares the same attempt identity and consumes once.
	await create_character(105)
	await create_character(106)
	world.reply(106, 52)
	world.reply(105, 51)
	world.reply(106, 52)
	await wait_for(func() -> bool: return master.responses.has(106))
	assert(not master.responses.has(105) and identity.last_character_id == 52 and world.tickets.size() == 3)
	# Late creation cannot supersede a newer enter; late enter cannot undo create.
	await create_character(107)
	await enter(108)
	world.reply(107, 53)
	world.reply(108)
	await wait_for(func() -> bool: return master.responses.has(108))
	assert(not master.responses.has(107) and world.tickets.size() == 4 and identity.peer_id == 108)
	await enter(109)
	await create_character(110)
	world.reply(110, 54)
	world.reply(109)
	await wait_for(func() -> bool: return master.responses.has(110))
	assert(not master.responses.has(109) and world.tickets.size() == 5 and identity.last_character_id == 54)

	# Gateway request IDs may be reused: even identical routing/character fields
	# cannot make an old error consume the new attempt after another login.
	await enter(111)
	var old: Dictionary = world.requests[111].duplicate()
	assert(not gateway.login_request("alpha", "fixture").has("error"))
	world.requests.erase(111)
	await enter(111)
	world.result_login.rpc_id(1, ERR_UNAUTHORIZED, old.gateway, 111, old.username, old.character, old.attempt)
	world.reply(111)
	await wait_for(func() -> bool: return master.responses.has(111))
	assert(master.responses[111].has("auth-token") and world.tickets.size() == 6)
	world.peer.close()
	master.peer.close()
	get_tree().set_multiplayer(null, world.get_path())
	get_tree().set_multiplayer(null, master.get_path())
	world.queue_free()
	master.queue_free()
	gateway.free()
	accounts.free()
	await get_tree().process_frame
	print("MASTER_ENTRY_ATTEMPTS_OK reordered real RPC replies, login revocation, enter/create supersession, duplicate suppression")
	get_tree().quit()
