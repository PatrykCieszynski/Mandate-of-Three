extends Node
## A2 seeded session maps. This fixture protects the previously uncovered native
## auth lifecycle: ticket replay/expiry and overlapping logins using real sockets.
## Only the Master transport and post-auth presentation pushes are controlled.
class Session extends WorldServer:
	var master: WorldManagerServer
	var notifications: Array[Dictionary] = []
	var published: Array[int] = []
	func _notify_master_disconnected(account: String, token: String = "") -> void:
		notifications.append({"account": account, "token": token,
			"retired": master.retire_world_session(7, account, token)})
	func _publish_authenticated_state(id: int, _player: PlayerResource) -> void:
		published.append(id)

class WireClient extends BaseMultiplayerEndpoint:
	var token: String
	var finish_auth := true
	var connected := false
	var ended := false
	func _connect_multiplayer_api_signals(api: SceneMultiplayer) -> void:
		api.auth_callback = func(_id: int, _data: PackedByteArray) -> void:
			api.send_auth(1, var_to_bytes(token))
			if finish_auth: api.complete_auth(1)
		api.connected_to_server.connect(func() -> void: connected = true)
		api.peer_authentication_failed.connect(func(_id: int) -> void: ended = true)
		api.connection_failed.connect(func() -> void: ended = true)
		api.server_disconnected.connect(func() -> void: ended = true)

var db := SQLite.new()
var database := WorldDatabase.new()
var server := Session.new()
var master := WorldManagerServer.new()
var authentication := AuthenticationManager.new()
var clients: Array[WireClient] = []
var characters: Array[int] = []
var total_seconds := 0.0

func _ready() -> void:
	run.call_deferred()

func _process(delta: float) -> void:
	total_seconds += delta
	assert(total_seconds < 20, "World session fixture timeout")

func wait_for(condition: Callable) -> void:
	var deadline := Time.get_ticks_msec() + 3000
	while not condition.call():
		assert(Time.get_ticks_msec() < deadline, "Native auth outcome timeout")
		await get_tree().process_frame

func issue(token: String, account: String, character: int, account_id: int) -> bool:
	var identity: AccountResource = authentication.account_collection.collection[account]
	identity.peer_id = 42
	authentication.active_accounts[account] = identity
	master.register_world_session(7, account, token)
	return server.accept_master_handoff(token, account, character, account_id)

func connect_client(token: String, finish: bool = true) -> WireClient:
	var client := WireClient.new()
	client.name = "Client%d" % clients.size()
	client.token = token
	client.finish_auth = finish
	clients.append(client)
	add_child(client)
	assert(client.create(BaseMultiplayerEndpoint.Role.CLIENT, "127.0.0.1", 18098) == OK)
	return client

func run() -> void:
	db.path = "res://.godot/verification/world-session.db"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path))
	assert(db.open_db())
	WorldSchema.ensure_schema(db)
	database.db = db
	database.store = WorldStoreSqlite.new(db)
	assert(WalletStoreSqlite.migrate_accounts(db, {}).ok)
	for account: String in ["alpha", "beta"]:
		var account_id := 21 if account == "alpha" else 22
		assert(database.store.bind_account_identity(account, account_id, true))
		var resource := AccountResource.new()
		resource.username = account
		resource.id = account_id
		if authentication.account_collection == null:
			authentication.account_collection = AccountResourceCollection.new()
		authentication.account_collection.collection[account] = resource
		for index: int in 2:
			characters.append(database.store.create_player_character(account, {"name": account + str(index), "skin": 1}))
	assert(database.prepare_account_wallets({"alpha": 21, "beta": 22}).ok)
	master.authentication_manager = authentication
	master.connected_worlds[7] = {}
	master.connected_worlds[8] = {}
	server.master = master
	server.database = database
	server.name = "World"
	add_child(server)
	assert(server.create(BaseMultiplayerEndpoint.Role.SERVER, "127.0.0.1", 18098) == OK)
	# Keep the native handshake timeout short only for this fixture.
	server.multiplayer_api.auth_timeout = 2.5

	var invalid := connect_client("unknown")
	await wait_for(func() -> bool: return invalid.ended)
	assert(not invalid.connected and server.connected_players.is_empty())
	server.handoff_ttl_ms = 15
	assert(issue("expired", "alpha", characters[0], 21))
	await get_tree().create_timer(0.025).timeout
	var expired := connect_client("expired")
	await wait_for(func() -> bool: return expired.ended)
	assert(not expired.connected and server.notifications.back().retired)
	server.handoff_ttl_ms = 30_000
	server.max_handoff_tickets = 1
	assert(issue("superseded", "alpha", characters[0], 21))
	assert(issue("first", "alpha", characters[0], 21), "same account replaces its own ticket at capacity")
	assert(not issue("capacity", "beta", characters[2], 22))
	assert(server.notifications.back().retired, "rejected ticket retires its Master marker")
	var obsolete := connect_client("superseded")
	await wait_for(func() -> bool: return obsolete.ended)
	assert(not obsolete.connected)
	server.max_handoff_tickets = 1024
	var first := connect_client("first")
	await wait_for(func() -> bool: return first.connected and server.connected_players.size() == 1)
	var first_id := first.multiplayer_api.get_unique_id()
	assert(server.player_id_to_peer_id[characters[0]] == first_id)
	var replay := connect_client("first")
	await wait_for(func() -> bool: return replay.ended)
	assert(not replay.connected and not first.ended and server.connected_players.size() == 1)

	assert(issue("replacement", "alpha", characters[0], 21))
	# Change RAM AFTER issuance: admitting the earlier snapshot would lose this.
	var player: PlayerResource = server.connected_players[first_id]
	player.level = 9
	player.experience = 17
	database.dirty_progression[player.player_id] = player
	assert(database.load_wallet(player.player_id) and database.add_yang(player.player_id, 23))
	var balance := database.wallet_balance(player.player_id)
	var replacement := connect_client("replacement")
	await wait_for(func() -> bool: return replacement.connected and first.ended)
	var new_id := replacement.multiplayer_api.get_unique_id()
	assert(server.connected_players.size() == 1 and server.connected_players.has(new_id))
	assert(server.connected_players[new_id].level == 9 and server.connected_players[new_id].experience == 17)
	assert(database.load_wallet(player.player_id) and database.wallet_balance(player.player_id) == balance)
	assert(not server.notifications.back().retired, "old disconnect cannot retire the newer issued ticket")
	assert(authentication.account_collection.collection["alpha"].peer_id == 42 and authentication.active_accounts.has("alpha"))
	server._on_peer_disconnected(first_id) # Delayed duplicate after admission.
	assert(server.player_id_to_peer_id[characters[0]] == new_id)
	assert(server.connected_players[new_id].current_peer_id == new_id)
	assert(not master.retire_world_session(8, "alpha", "replacement"), "wrong World cannot retire another World's session")

	assert(issue("other-character", "alpha", characters[1], 21))
	var other := connect_client("other-character")
	await wait_for(func() -> bool: return other.connected and replacement.ended)
	var other_id := other.multiplayer_api.get_unique_id()
	assert(server.connected_players.size() == 1 and not server.player_id_to_peer_id.has(characters[0]))
	assert(server.player_id_to_peer_id[characters[1]] == other_id)
	server.peer.disconnect_peer(other_id)
	await wait_for(func() -> bool: return other.ended and server.connected_players.is_empty())
	assert(server.notifications.back().retired, "current session disconnect clears Master status")
	assert(authentication.account_collection.collection["alpha"].peer_id == 0 and not authentication.active_accounts.has("alpha"))
	assert(not master.retire_world_session(7, "alpha", "other-character"), "duplicate retirement is harmless")

	assert(issue("half-open", "beta", characters[2], 22))
	var half_open := connect_client("half-open", false)
	await wait_for(func() -> bool: return half_open.ended)
	assert(not half_open.connected and server.connected_players.is_empty())
	assert(not server.is_valid_authentication_token("half-open") and server.notifications.back().retired)
	assert(issue("pending-old", "beta", characters[2], 22))
	var pending_old := connect_client("pending-old", false)
	await wait_for(func() -> bool: return not server.is_valid_authentication_token("pending-old"))
	assert(issue("pending-new", "beta", characters[3], 22))
	await wait_for(func() -> bool: return pending_old.ended)
	assert(not pending_old.connected and server.connected_players.is_empty())
	var pending_new := connect_client("pending-new")
	await wait_for(func() -> bool: return pending_new.connected)
	var pending_id := pending_new.multiplayer_api.get_unique_id()
	assert(server.player_id_to_peer_id[characters[3]] == pending_id)
	server.peer.disconnect_peer(pending_id)
	await wait_for(func() -> bool: return pending_new.ended and server.connected_players.is_empty())
	assert(server.notifications.back().retired)
	assert(issue("revoked", "beta", characters[2], 22))
	server.revoke_account_admission("beta")
	var revoked := connect_client("revoked")
	await wait_for(func() -> bool: return revoked.ended)
	assert(not revoked.connected and server.connected_players.is_empty())

	for client: WireClient in clients:
		client.peer.close()
		client.multiplayer_api.auth_callback = Callable()
		get_tree().set_multiplayer(null, client.get_path())
	server.peer.close()
	server.multiplayer_api.auth_callback = Callable()
	get_tree().set_multiplayer(null, server.get_path())
	server.queue_free()
	for client: WireClient in clients: client.queue_free()
	await get_tree().process_frame
	master.free()
	authentication.free()
	database.db = null
	database.free()
	assert(db.close_db())
	for suffix: String in ["", "-wal", "-shm"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path + suffix))
	print("WORLD_SESSION_ADMISSION_OK native ticket expiry/replay, replacement, persistence and Master fencing")
	get_tree().quit()
