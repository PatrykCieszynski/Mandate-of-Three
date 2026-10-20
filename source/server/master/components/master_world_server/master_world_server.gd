class_name WorldManagerServer
extends BaseMultiplayerEndpoint


@export var authentication_manager: AuthenticationManager
@export var gateway_manager: GatewayManagerServer

var connected_worlds: Dictionary[int, Dictionary]
## Latest issued World ticket also fences delayed disconnect notifications.
var _world_sessions: Dictionary[String, Dictionary] = {}
## Injected only by an opt-in PostgreSQL realm bootstrap/fixture. Default is SQLite.
var economy_bootstrap: RefCounted
var inventory_session_issuer: RefCounted

func _process(_delta: float) -> void:
	if economy_bootstrap!=null: economy_bootstrap.check_health()
	if inventory_session_issuer!=null: inventory_session_issuer.poll()
## One current, bounded-lifetime request per account, recorded BEFORE World work.
var _entry_attempts: Dictionary[String, Dictionary] = {}
const ENTRY_ATTEMPT_TTL_MS: int = 30_000
const MAX_ENTRY_ATTEMPTS: int = 1024


func _ready() -> void:
	var configuration: Dictionary = ConfigFileUtils.load_section(
		"world-manager-server",
		CmdlineUtils.get_parsed_args().get("config", "res://data/config/master_config.cfg")
	)
	create(Role.SERVER, configuration.bind_address, configuration.port)


func _connect_multiplayer_api_signals(api: SceneMultiplayer) -> void:
	api.peer_connected.connect(_on_peer_connected)
	api.peer_disconnected.connect(_on_peer_disconnected)


func _on_peer_connected(peer_id: int) -> void:
	print("World: %d is connected to WorldManager." % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	var dropped: Dictionary = connected_worlds.get(peer_id, {})
	for username: String in _entry_attempts.keys():
		if _entry_attempts[username].world_id == peer_id:
			_entry_attempts.erase(username)
	for username: String in _world_sessions.keys():
		var session: Dictionary = _world_sessions[username]
		if session.world_id == peer_id:
			retire_world_session(peer_id, username, session.token)
	connected_worlds.erase(peer_id)
	# Push the updated roster to every gateway so their cached world list (served
	# at /v1/worlds) drops the dead world. Connect already broadcasts (see
	# fetch_server_info); without this, a stopped world would linger in selection.
	gateway_manager.update_worlds_info.rpc(get_public_worlds())
	print("World: %d is disconnected from WorldManager." % peer_id)
	var world_name: String = str(dropped.get("info", {}).get("name", "world#%d" % peer_id))
	DiscordNotifier.notify_world_disconnected(world_name)


@rpc("any_peer")
func fetch_server_info(info: Dictionary) -> void:
	var game_server_id: int = multiplayer_api.get_remote_sender_id()
	connected_worlds[game_server_id] = info
	# Stamp connect time so the dashboard can show "connected for X minutes".
	connected_worlds[game_server_id]["connected_at"] = int(Time.get_unix_time_from_system())
	var identities := {}
	for account: AccountResource in authentication_manager.account_collection.collection.values():
		identities[account.username] = account.id
	account_identity_manifest.rpc_id(game_server_id,identities)
	gateway_manager.update_worlds_info.rpc(get_public_worlds())
	var world_name: String = str(info.get("info", {}).get("name", "world#%d" % game_server_id))
	DiscordNotifier.notify_world_connected(world_name)


## Client-safe view of the live worlds: name / motd / pvp only. The full roster
## (connected_worlds) also holds each world's address, port and heartbeat snapshot
## (player rosters, chat tail, server logs) — that must never reach a game client,
## so every world-list payload (login/list responses + gateway broadcasts) is
## projected through here. The raw roster stays server-side for handoff/dashboard.
func get_public_worlds() -> Dictionary:
	var out: Dictionary = {}
	for world_id: int in connected_worlds:
		var info: Dictionary = connected_worlds[world_id].get("info", {})
		out[world_id] = {
			"info": {
				"name": info.get("name", ""),
				"motd": info.get("motd", ""),
				"pvp": info.get("pvp", false),
			}
		}
	return out


## Resolve a world's display name to its live peer id, or 0 if no world by that
## name is currently connected. Character ids are per-world (each world has its
## own DB), so a last-login kick must target the player's actual world by name —
## broadcasting the id could boot a same-id character on a different world.
func world_id_by_name(world_name: String) -> int:
	if world_name.is_empty():
		return 0
	for world_id: int in connected_worlds:
		if connected_worlds[world_id].get("info", {}).get("name", "") == world_name:
			return world_id
	return 0


## Periodic snapshot push from each world. Replaces the live numbers on the
## fetched info so the dashboard always reflects what the world is reporting.
@rpc("any_peer")
func heartbeat(snapshot: Dictionary) -> void:
	var world_peer_id: int = multiplayer_api.get_remote_sender_id()
	if not connected_worlds.has(world_peer_id):
		return
	connected_worlds[world_peer_id]["heartbeat"] = snapshot
	connected_worlds[world_peer_id]["last_heartbeat_at"] = int(Time.get_unix_time_from_system())


# --- Dashboard-driven outbound RPCs (master → world) ---

## Tell the world with this peer_id to flush all players to DB + backup.
func tell_world_to_save(world_peer_id: int) -> bool:
	if not connected_worlds.has(world_peer_id):
		return false
	master_save.rpc_id(world_peer_id)
	return true


## Tell the world to shut down gracefully (save then quit).
func tell_world_to_shutdown(world_peer_id: int) -> bool:
	if not connected_worlds.has(world_peer_id):
		return false
	master_shutdown.rpc_id(world_peer_id)
	return true


## Push a system message to every connected player on this world.
func tell_world_to_broadcast(world_peer_id: int, message: String) -> bool:
	if not connected_worlds.has(world_peer_id):
		return false
	master_broadcast.rpc_id(world_peer_id, message)
	return true


## Tell one world to run a staged restart countdown (warns players over [param seconds],
## then a final save). Does NOT quit the world — the deploy's `systemctl stop` does that
## (and saves again via WorldServer._notification). Returns true if the world is known.
func tell_world_to_restart(world_peer_id: int, seconds: int, message: String) -> bool:
	if not connected_worlds.has(world_peer_id):
		return false
	master_restart.rpc_id(world_peer_id, seconds, message)
	return true


## Fan the restart countdown out to EVERY connected world in one shot (the deploy
## makes a single call; the master knows the whole roster). Returns the count notified.
func tell_all_worlds_to_restart(seconds: int, message: String) -> int:
	var count: int = 0
	for world_peer_id: int in connected_worlds:
		master_restart.rpc_id(world_peer_id, seconds, message)
		count += 1
	return count


## Flush + back up EVERY connected world right now (no countdown). This is the
## RELIABLE pre-stop persistence path: Godot headless does NOT run _notification on
## SIGINT/SIGTERM, so `systemctl stop` alone never saves — the deploy calls this
## first. master_save runs the save synchronously in its RPC handler (signal-free),
## so it actually persists. Returns the world count notified.
func tell_all_worlds_to_save() -> int:
	var count: int = 0
	for world_peer_id: int in connected_worlds:
		master_save.rpc_id(world_peer_id)
		count += 1
	return count


# Stubs declared so Godot's RPC table accepts the outbound calls. World side
# implements the actual behavior in WorldManagerClient.
@rpc("authority") func master_save() -> void: pass
@rpc("authority") func account_identity_manifest(_identities: Dictionary) -> void: pass
@rpc("authority") func master_shutdown() -> void: pass
@rpc("authority") func master_broadcast(_message: String) -> void: pass
@rpc("authority") func master_restart(_seconds: int, _message: String) -> void: pass
@rpc("authority") func master_mute(_player_id: int, _reason: String, _duration_ms: int) -> void: pass
@rpc("authority") func master_unmute(_player_id: int) -> void: pass
@rpc("authority") func master_jail(_player_id: int, _reason: String, _duration_ms: int) -> void: pass
@rpc("authority") func master_unjail(_player_id: int) -> void: pass
@rpc("authority") func master_kick(_player_id: int) -> void: pass
@rpc("authority") func master_grant_role(_player_id: int, _role: String) -> void: pass
@rpc("authority") func master_revoke_role(_player_id: int, _role: String) -> void: pass


## Dashboard helpers — each returns true if the targeted world is known.
func tell_world_to_mute(world_id: int, player_id: int, reason: String, duration_ms: int) -> bool:
	if not connected_worlds.has(world_id): return false
	master_mute.rpc_id(world_id, player_id, reason, duration_ms)
	return true


func tell_world_to_unmute(world_id: int, player_id: int) -> bool:
	if not connected_worlds.has(world_id): return false
	master_unmute.rpc_id(world_id, player_id)
	return true


func tell_world_to_jail(world_id: int, player_id: int, reason: String, duration_ms: int) -> bool:
	if not connected_worlds.has(world_id): return false
	master_jail.rpc_id(world_id, player_id, reason, duration_ms)
	return true


func tell_world_to_unjail(world_id: int, player_id: int) -> bool:
	if not connected_worlds.has(world_id): return false
	master_unjail.rpc_id(world_id, player_id)
	return true


func tell_world_to_kick(world_id: int, player_id: int) -> bool:
	if not connected_worlds.has(world_id): return false
	master_kick.rpc_id(world_id, player_id)
	return true


func tell_world_to_grant_role(world_id: int, player_id: int, role: String) -> bool:
	if not connected_worlds.has(world_id): return false
	master_grant_role.rpc_id(world_id, player_id, role)
	return true


func tell_world_to_revoke_role(world_id: int, player_id: int, role: String) -> bool:
	if not connected_worlds.has(world_id): return false
	master_revoke_role.rpc_id(world_id, player_id, role)
	return true


@rpc("authority")
func fetch_token(_auth_token: String, _username: String, _character_id: int, _account_id: int, _inventory_context: Dictionary = {}) -> void:
	pass


## Login and character creation share one attempt slot. A random attempt identity
## is echoed by World; request IDs alone can be reused after a Gateway restart.
func begin_entry_attempt(username: String, world_id: int, gateway_id: int, request_id: int, kind: StringName, character_id: int = 0) -> String:
	var now := Time.get_ticks_msec()
	for account: String in _entry_attempts.keys():
		if int(_entry_attempts[account].expires_at) <= now:
			_entry_attempts.erase(account)
	revoke_world_session(username)
	if _entry_attempts.size() >= MAX_ENTRY_ATTEMPTS: return ""
	var attempt_id := authentication_manager.generate_random_token()
	_entry_attempts[username] = {"id": attempt_id, "world_id": world_id,
		"gateway_id": gateway_id, "request_id": request_id, "kind": kind,
		"character_id": character_id, "expires_at": now + ENTRY_ATTEMPT_TTL_MS}
	return attempt_id


func _consume_entry_attempt(username: String, world_id: int, gateway_id: int, request_id: int, kind: StringName, attempt_id: String, character_id: int = 0) -> bool:
	var attempt: Dictionary = _entry_attempts.get(username, {})
	if attempt.is_empty() or attempt.id != attempt_id: return false
	if attempt.world_id != world_id or attempt.gateway_id != gateway_id or attempt.request_id != request_id or attempt.kind != kind or attempt.character_id != character_id:
		return false
	_entry_attempts.erase(username) # Consume even errors; duplicate replies do nothing.
	return int(attempt.expires_at) > Time.get_ticks_msec()


## Keep the Gateway transport separate from attempt acceptance; tests observe
## actual result_login/creation callbacks, not just token registration helpers.
func _entry_response(gateway_id: int, request_id: int, response: Dictionary) -> void:
	gateway_manager.gateway_response.rpc_id(gateway_id, request_id, response)


## Called only when issuing a trusted ticket; character identity stays in World.
func register_world_session(world_id: int, username: String, token: String, character_id: int = 0, account_id: int = 0) -> void:
	_world_sessions[username] = {"world_id":world_id,"token":token,"character_id":character_id,"account_id":account_id}

## Privileged projection of an EXISTING current Master ticket. Never an RPC or
## a World-supplied account/character assertion; used by the optional PG issuer.
func verified_inventory_ticket(world_id: int, username: String, token: String) -> Dictionary:
	if authentication_manager==null or authentication_manager.account_collection==null: return {}
	var session: Dictionary=_world_sessions.get(username,{})
	var account: AccountResource=authentication_manager.account_collection.collection.get(username)
	if not connected_worlds.has(world_id) or session.is_empty() or token.is_empty() or account==null: return {}
	if session.world_id!=world_id or session.token!=token or int(session.get("character_id",0))<=0 or int(session.get("account_id",0))!=account.id: return {}
	return {"account_id":account.id,"character":int(session.character_id),"session_fingerprint":token.sha256_text()}

func _prepare_world_ticket(world_id: int, username: String, token: String, character_id: int, account_id: int) -> Dictionary:
	if economy_bootstrap!=null and not economy_bootstrap.ready(): return {"ok":false,"error":ERR_UNAVAILABLE}
	register_world_session(world_id,username,token,character_id,account_id)
	if inventory_session_issuer==null: return {"ok":true,"context":{}}
	var request: Dictionary=inventory_session_issuer.request_grant(world_id,username,token)
	var deadline: int=Time.get_ticks_msec()+ENTRY_ATTEMPT_TTL_MS
	while request.queued and not request.done and Time.get_ticks_msec()<deadline:
		await get_tree().process_frame
	var current:=not verified_inventory_ticket(world_id,username,token).is_empty()
	if not request.done or not current or not request.result.get("ok",false):
		if current: revoke_world_session(username)
		return {"ok":false,"error":ERR_UNAUTHORIZED}
	return request.result.duplicate(true)


func retire_world_session(world_id: int, username: String, token: String) -> bool:
	var session: Dictionary = _world_sessions.get(username, {})
	if not connected_worlds.has(world_id) or session.is_empty() or token.is_empty(): return false
	if session.world_id != world_id or session.token != token: return false
	_world_sessions.erase(username)
	if inventory_session_issuer!=null: inventory_session_issuer.retire(username,token)
	var account: AccountResource = authentication_manager.account_collection.collection.get(username)
	if account != null:
		account.peer_id = 0
		authentication_manager.active_accounts.erase(username)
	return true


## A new Gateway login invalidates unclaimed tickets as well as active ownership.
func revoke_world_session(username: String) -> void:
	_entry_attempts.erase(username)
	var session: Dictionary = _world_sessions.get(username, {})
	_world_sessions.erase(username)
	if inventory_session_issuer!=null and not session.is_empty(): inventory_session_issuer.retire(username,session.token)
	if not session.is_empty() and connected_worlds.has(int(session.world_id)):
		revoke_account_admission.rpc_id(int(session.world_id), username)


@rpc("authority")
func revoke_account_admission(_username: String) -> void:
	pass


@rpc("any_peer")
func player_disconnected(username: String, session_token: String) -> void:
	retire_world_session(multiplayer_api.get_remote_sender_id(), username, session_token)


@rpc("authority")
func create_player_character_request(_gateway_id: int, _peer_id: int, _username: String, _character_data: Dictionary, _account_id: int, _attempt_id: String) -> void:
	pass


@rpc("any_peer")
func player_character_creation_result(gateway_id: int, peer_id: int, username: String, result_code: int, attempt_id: String) -> void:
	var world_id: int = multiplayer_api.get_remote_sender_id()
	if not connected_worlds.has(world_id): return
	if not _consume_entry_attempt(username, world_id, gateway_id, peer_id, &"create", attempt_id): return
	if result_code:
		var account: AccountResource = authentication_manager.account_collection.collection.get(username)
		if not account:
			return
		account.last_world_name = connected_worlds[world_id].get("info", {}).get("name", "")
		account.last_character_id = result_code
		account.peer_id = peer_id # mark connected so a second login is refused
		# Persist account metadata (last world/character) on every login — must run in
		# production too, not just debug, or "continue on last world" breaks in a
		# release build. (Was gated on "debug", which masked this on the debug server.)
		authentication_manager.save_account_collection()
		var auth_token: String = authentication_manager.generate_random_token()
		var ticket: Dictionary=await _prepare_world_ticket(world_id,username,auth_token,result_code,account.id)
		if not ticket.ok:
			_entry_response(gateway_id,peer_id,{"error":ERR_UNAUTHORIZED})
			return
		fetch_token.rpc_id(world_id,auth_token,username,result_code,account.id,ticket.context)
		
		_entry_response(
			gateway_id,
			peer_id,
			{
				"auth-token": auth_token,
				"address": connected_worlds[world_id]["address"],
				"port": connected_worlds[world_id]["port"]
			}
		)
	else:
		_entry_response(gateway_id, peer_id, {"error": GatewayAPI.ERR_GENERIC})


@rpc("any_peer")
func request_player_characters(_gateway_id: int, _peer_id: int, _username: String) -> void:
	pass


@rpc("any_peer")
func request_login(_gateway_id: int, _peer_id: int, _username: String, _character_id: int, _attempt_id: String) -> void:
	pass


@rpc("any_peer")
func result_login(result_code: int, gateway_id: int, peer_id: int, username: String, character_id: int, attempt_id: String) -> void:
	var world_id: int = multiplayer_api.get_remote_sender_id()
	if not connected_worlds.has(world_id): return
	if not _consume_entry_attempt(username, world_id, gateway_id, peer_id, &"login", attempt_id, character_id): return
	if result_code != OK:
		_entry_response(gateway_id, peer_id, {"error": result_code})
		return
	if result_code == OK:
		# Last-login-wins; only the matching ticket may later clear this status.
		var account: AccountResource = authentication_manager.account_collection.collection.get(username)
		if account == null: return
		account.peer_id = peer_id
		var auth_token: String = authentication_manager.generate_random_token()
		var ticket: Dictionary=await _prepare_world_ticket(world_id,username,auth_token,character_id,account.id)
		if not ticket.ok:
			_entry_response(gateway_id,peer_id,{"error":ERR_UNAUTHORIZED})
			return
		fetch_token.rpc_id(world_id,auth_token,username,character_id,account.id,ticket.context)
		await get_tree().create_timer(0.5).timeout
		# A newer login or world disconnect may have retired this attempt.
		if _world_sessions.get(username, {}).get("token", "") != auth_token or not connected_worlds.has(world_id):
			_entry_response(gateway_id, peer_id, {"error": ERR_UNAUTHORIZED})
			return
		_entry_response(
			gateway_id,
			peer_id,
			{
				"auth-token": auth_token,
				"address": connected_worlds[world_id]["address"],
				"port": connected_worlds[world_id]["port"]
			}
		)


@rpc("any_peer")
func receive_player_characters(player_characters: Dictionary, gateway_id: int, peer_id: int) -> void:
	gateway_manager.gateway_response.rpc_id(
		gateway_id,
		peer_id,
		player_characters
	)
