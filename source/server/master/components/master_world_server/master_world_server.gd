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
var maintenance: RefCounted
var _startup_pending:=false
var runtime_settings: RefCounted
var _handoff_waiters: Dictionary={}

func admissions_open() -> bool:
	return not _startup_pending and maintenance==null and (authentication_manager==null or authentication_manager.storage_ready) and (economy_bootstrap==null or economy_bootstrap.ready())

func begin_maintenance(id: String) -> Dictionary:
	if not ItemInstance.valid_uid(id): return {"ok":false,"error":"operation_id"}
	if maintenance!=null:
		return {"ok":true,"maintenance":maintenance.status()} if maintenance.operation_id==id else {"ok":false,"error":"maintenance_active"}
	if economy_bootstrap==null: return {"ok":false,"error":"postgresql_required"}
	if not admissions_open() or connected_worlds.size()!=1: return {"ok":false,"error":"not_ready"}
	var target: int=connected_worlds.keys()[0]
	if not world_ready(target): return {"ok":false,"error":"not_ready"}
	maintenance=preload("res://source/server/master/operations/realm_maintenance.gd").new(self,id,target)
	_entry_attempts.clear() # Fence delayed World results before sending the drain.
	gateway_manager.update_worlds_info.rpc(get_public_worlds())
	economy_quiesce.rpc_id(target,id)
	return {"ok":true,"maintenance":maintenance.status()}

func operational_status() -> Dictionary:
	var worlds: Array=[]
	for id: int in connected_worlds:
		var entry: Dictionary=connected_worlds[id]
		var raw: Variant=entry.get("heartbeat",{}).get("economy",{})
		var health: Dictionary=raw if raw is Dictionary else {}
		# Whitelist copied counters only; never publish raw heartbeat/config/jobs.
		var state: String=str(health.get("state","UNKNOWN"))
		if state not in ["NEW","STARTING","READY","DRAINING","STOPPED","FAILED","BLOCKED"]: state="UNKNOWN"
		var unsettled: Array[String]=[]
		var reported: Variant=health.get("unsettled_domains",[])
		if reported is Array:
			for domain: String in ["wallet","npc","storage","ground","market"]:
				if reported.has(domain): unsettled.append(domain)
		worlds.append({"draining":bool(entry.get("draining",false)),"unsettled_domains":unsettled,"world_id":id,"ready":world_ready(id),"state":state,"pending":clampi(int(health.get("pending",0)),0,1024),"workers_ready":clampi(int(health.get("workers_ready",0)),0,8),"heartbeat_age_seconds":maxi(0,int(Time.get_unix_time_from_system())-int(entry.get("last_heartbeat_at",0)))})
	return {"ok":true,"backend":"postgresql" if economy_bootstrap!=null else "sqlite","admissions_open":admissions_open(),"master":economy_bootstrap.status() if economy_bootstrap!=null else {},"worlds":worlds,"maintenance":maintenance.status() if maintenance!=null else {}}

@rpc("authority","call_remote","reliable")
func economy_quiesce(_id: String) -> void: pass

@rpc("any_peer","call_remote","reliable")
func economy_quiesced(id: String, result: Dictionary) -> void:
	if maintenance!=null: maintenance.acknowledge(multiplayer_api.get_remote_sender_id(),id,result)


func _process(_delta: float) -> void:
	if economy_bootstrap!=null: economy_bootstrap.check_health()
	if inventory_session_issuer!=null: inventory_session_issuer.poll()
	if maintenance!=null: maintenance.poll()
## One current, bounded-lifetime request per account, recorded BEFORE World work.
var _entry_attempts: Dictionary[String, Dictionary] = {}
const ENTRY_ATTEMPT_TTL_MS: int = 30_000
const MAX_ENTRY_ATTEMPTS: int = 1024


func _ready() -> void:
	_startup_pending=true
	var budgets: Dictionary=preload("res://source/server/runtime/runtime_capacity_settings.gd").load_config(CmdlineUtils.get_parsed_args().get("config","res://data/config/master_config.cfg"),"master")
	if not budgets.ok:
		push_error("Master startup refused: "+str(budgets.error));get_tree().quit(1);return
	runtime_settings=budgets.settings
	ServerLog.info("Master startup budgets: grants=%d handoff_waits=%d ack_timeout_ms=%d" % [runtime_settings.value("master_grants"),runtime_settings.value("handoff_tickets"),runtime_settings.value("handoff_ack_timeout_ms")])
	var configuration: Dictionary = ConfigFileUtils.load_section(
		"world-manager-server",
		CmdlineUtils.get_parsed_args().get("config", "res://data/config/master_config.cfg")
	)
	var settings: Dictionary=preload("res://source/server/world/database/postgres/economy_bootstrap_settings.gd").load_config(CmdlineUtils.get_parsed_args().get("config","res://data/config/master_config.cfg"))
	if not settings.ok:
		push_error("Master economy startup refused: "+str(settings.error));return
	if settings.backend=="postgresql":
		var owner:=preload("res://source/server/world/database/postgres/economy_bootstrap_postgres.gd").new()
		if not await owner.start_master(self,settings):
			push_error("Master economy startup refused: "+owner.error);return
	_startup_pending=create(Role.SERVER, configuration.bind_address, configuration.port)!=OK


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
	if not admissions_open(): return
	var game_server_id: int = multiplayer_api.get_remote_sender_id()
	if connected_worlds.get(game_server_id,{}).get("draining",false): return
	var metadata: Variant=info.get("info",{})
	if not metadata is Dictionary: return
	if runtime_settings!=null:
		var declared: Variant=metadata.get("max_players",64)
		if not declared is int or declared<1 or declared>runtime_settings.value("master_grants"):
			push_error("World registration refused: session capacity exceeds Master grant budget");return
		var lifetime: Variant=metadata.get("handoff_ttl_ms",30000)
		if not lifetime is int or lifetime<=runtime_settings.value("handoff_ack_timeout_ms"):
			push_error("World registration refused: ticket expires before Master ACK deadline");return
	var expected: String="postgresql" if economy_bootstrap!=null else "sqlite"
	if str(info.get("economy_backend","sqlite"))!=expected: return
	if economy_bootstrap!=null and not connected_worlds.is_empty() and not connected_worlds.has(game_server_id): return # One profile/character-ID owner in P3.
	if economy_bootstrap!=null and (not economy_bootstrap.ready() or info.get("economy_authority_id","")!=economy_bootstrap.authority_id()): return
	connected_worlds[game_server_id] = info
	connected_worlds[game_server_id]["economy_ready"]=expected=="sqlite"
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
@rpc("any_peer")
func economy_identity_ready(authority: String) -> void:
	var peer: int=multiplayer_api.get_remote_sender_id()
	if economy_bootstrap==null or not economy_bootstrap.ready() or authority!=economy_bootstrap.authority_id() or not connected_worlds.has(peer) or connected_worlds[peer].get("draining",false): return
	connected_worlds[peer]["economy_ready"]=true
	gateway_manager.update_worlds_info.rpc(get_public_worlds())

func world_ready(world_id: int) -> bool:
	return admissions_open() and connected_worlds.has(world_id) and not connected_worlds[world_id].get("draining",false) and (economy_bootstrap==null or (economy_bootstrap.ready() and connected_worlds[world_id].get("economy_ready",false)))

func get_public_worlds() -> Dictionary:
	var out: Dictionary = {}
	for world_id: int in connected_worlds:
		if not world_ready(world_id): continue
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
	var raw: Variant=snapshot.get("economy",{})
	var economy: Dictionary=raw if raw is Dictionary else {}
	if economy_bootstrap!=null and economy.get("state","") in ["DRAINING","STOPPED","FAILED","BLOCKED"] and connected_worlds[world_peer_id].get("economy_ready",false):
		connected_worlds[world_peer_id]["economy_ready"]=false
		gateway_manager.update_worlds_info.rpc(get_public_worlds())
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
	if economy_bootstrap!=null:
		# Close routing synchronously, before World begins asynchronous drain.
		# Keep existing grants valid until their captured work has reconciled.
		connected_worlds[world_peer_id]["draining"]=true
		connected_worlds[world_peer_id]["economy_ready"]=false
		for username: String in _entry_attempts.keys():
			if _entry_attempts[username].world_id==world_peer_id: _entry_attempts.erase(username)
		gateway_manager.update_worlds_info.rpc(get_public_worlds())
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
@rpc("authority","call_remote","reliable") func master_shutdown() -> void: pass
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

@rpc("any_peer","call_remote","reliable")
func handoff_accepted(token: String, accepted: bool) -> void:
	var waiting: Dictionary=_handoff_waiters.get(token,{})
	if waiting.is_empty() or waiting.done or waiting.world!=multiplayer_api.get_remote_sender_id() or Time.get_ticks_msec()>=int(waiting.deadline): return
	waiting.done=true;waiting.accepted=accepted


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
	if not world_ready(world_id): return {"ok":false,"error":ERR_UNAVAILABLE}
	# Replacing this account retires its old wait without consuming a second slot.
	for previous: String in _handoff_waiters.keys():
		if _handoff_waiters[previous].account==username:
			_handoff_waiters[previous].done=true
			_handoff_waiters.erase(previous)
	if runtime_settings!=null and _handoff_waiters.size()>=runtime_settings.value("handoff_tickets"): return {"ok":false,"error":ERR_BUSY}
	register_world_session(world_id,username,token,character_id,account_id)
	var request: Dictionary={"queued":false,"done":true,"result":{"ok":true,"context":{}}} if inventory_session_issuer==null else inventory_session_issuer.request_grant(world_id,username,token)
	var deadline: int=Time.get_ticks_msec()+ENTRY_ATTEMPT_TTL_MS
	while request.queued and not request.done and Time.get_ticks_msec()<deadline:
		await get_tree().process_frame
	if not world_ready(world_id):
		if _world_sessions.get(username,{}).get("token","")==token: revoke_world_session(username)
		return {"ok":false,"error":ERR_UNAVAILABLE}
	var current:=not verified_inventory_ticket(world_id,username,token).is_empty()
	if not request.done or not current or not request.result.get("ok",false):
		if current: revoke_world_session(username)
		return {"ok":false,"error":ERR_BUSY if request.result.get("error","")=="busy" else ERR_UNAUTHORIZED}
	# Capacity may have changed while the native grant was awaited.
	if runtime_settings!=null and _handoff_waiters.size()>=runtime_settings.value("handoff_tickets"):
		revoke_world_session(username)
		return {"ok":false,"error":ERR_BUSY}
	var waiting: Dictionary={"world":world_id,"account":username,"done":false,"accepted":false,"deadline":Time.get_ticks_msec()+(runtime_settings.value("handoff_ack_timeout_ms") if runtime_settings!=null else 5000)}
	if runtime_settings!=null: _handoff_waiters[token]=waiting
	fetch_token.rpc_id(world_id,token,username,character_id,account_id,request.result.context)
	if runtime_settings!=null:
		while not waiting.done and world_ready(world_id) and _world_sessions.get(username,{}).get("token","")==token and Time.get_ticks_msec()<int(waiting.deadline):
			await get_tree().process_frame
		_handoff_waiters.erase(token)
		if not waiting.done or not waiting.accepted or not world_ready(world_id) or _world_sessions.get(username,{}).get("token","")!=token:
			if _world_sessions.get(username,{}).get("token","")==token: revoke_world_session(username)
			return {"ok":false,"error":ERR_BUSY if waiting.done and not waiting.accepted else ERR_UNAVAILABLE}
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
		# Persist account metadata (last world/character) on every login — must run in
		# production too, not just debug, or "continue on last world" breaks in a
		# release build. (Was gated on "debug", which masked this on the debug server.)
		authentication_manager.save_account_collection()
		var auth_token: String = authentication_manager.generate_random_token()
		var ticket: Dictionary=await _prepare_world_ticket(world_id,username,auth_token,result_code,account.id)
		if not ticket.ok:
			_entry_response(gateway_id,peer_id,{"error":ticket.error})
			return
		account.peer_id = peer_id
		
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
		var auth_token: String = authentication_manager.generate_random_token()
		var ticket: Dictionary=await _prepare_world_ticket(world_id,username,auth_token,character_id,account.id)
		if not ticket.ok:
			_entry_response(gateway_id,peer_id,{"error":ticket.error})
			return
		account.peer_id = peer_id
		# A newer login or world disconnect may have retired this attempt.
		if _world_sessions.get(username, {}).get("token", "") != auth_token or not world_ready(world_id):
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
