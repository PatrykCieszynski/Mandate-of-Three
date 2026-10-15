extends "res://addons/httpserver/http_server.gd"


const CredentialsUtils: GDScript = preload("res://source/common/utils/credentials_utils.gd")

# Fixed lifetime uses monotonic time; activity does not extend credentials forever.
@export_range(1, 86400) var session_ttl_seconds: int = 28800
@export_range(1, 65536) var max_pending_requests: int = 1024
@export_range(1, 65536) var max_sessions: int = 10000
var _session_expiry: Dictionary[String, int] = {}
var _request_sessions: Dictionary[int, String] = {}
var _request_deadlines: Dictionary[int, int] = {}
var _next_prune_ms: int = 0
# Reservations count against the same capacity as issued tokens. A replacement
# reserves its existing account slot; guests reserve a new unique slot.
var _session_reservations: Dictionary[String, bool] = {}
var _next_reservation_id: int = 0
var _token_requests: Dictionary[String, Dictionary] = {}

var next_request_id: int
var sessions: Dictionary[String, Dictionary]
var pending_requests: Dictionary[int, NetRequest]

@onready var gateway_manager_client: GatewayManagerClient = $"../GatewayManagerClient"


func _ready() -> void:
	super._ready()
	router.register_route(
		HTTPClient.Method.METHOD_POST,
		&"/v1/login",
		handle_login
	)
	router.register_route(
		HTTPClient.Method.METHOD_POST,
		&"/v1/guest",
		handle_guest
	)
	router.register_route(
		HTTPClient.Method.METHOD_POST,
		&"/v1/world/character/create",
		handle_character_create
	)
	router.register_route(
		HTTPClient.Method.METHOD_POST,
		&"/v1/world/enter",
		handle_world_enter
	)
	router.register_route(
		HTTPClient.Method.METHOD_POST,
		&"/v1/world/characters",
		handle_world_characters
	)
	router.register_route(
		HTTPClient.Method.METHOD_POST,
		&"/v1/account/create",
		handle_account_creation
	)
	router.register_route(
		HTTPClient.Method.METHOD_POST,
		&"/v1/worlds",
		handle_worlds
	)
	router.register_route(
		HTTPClient.Method.METHOD_POST,
		&"/v1/handshake",
		handle_handshake
	)
	router.register_route(HTTPClient.Method.METHOD_POST, &"/v1/logout", handle_logout)
	server.listen(8088, "127.0.0.1")
	
	_bind_master_lifecycle()


func _bind_master_lifecycle() -> void:
	gateway_manager_client.response_received.connect(_on_gateway_manager_client_response_received)
	gateway_manager_client.connection_lost.connect(_on_master_connection_lost)


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	_expire_requests()
	if Time.get_ticks_msec() >= _next_prune_ms:
		_next_prune_ms = Time.get_ticks_msec() + 1000
		prune_sessions()


func _session_slots() -> Dictionary:
	var slots := _session_reservations.duplicate()
	for account: Dictionary in sessions.values():
		slots["account:" + str(account.name).strip_edges().to_lower()] = true
	return slots


func _reserve_session(username: String = "") -> String:
	prune_sessions()
	var key := "account:" + username.strip_edges().to_lower()
	if username.is_empty():
		key = "guest:%d" % _next_reservation_id
		_next_reservation_id += 1
	if _session_reservations.has(key):
		return ""
	var slots := _session_slots()
	if not slots.has(key) and slots.size() >= max_sessions:
		return ""
	_session_reservations[key] = true
	return key


func create_session(account: Dictionary, reservation: String = "") -> String:
	prune_sessions()
	if int(account.get("id", 0)) <= 0 or str(account.get("name", "")).is_empty():
		return ""
	var slots := _session_slots()
	if not reservation.is_empty():
		if not _session_reservations.has(reservation):
			return ""
		slots.erase(reservation)
	var account_key := "account:" + str(account.name).strip_edges().to_lower()
	if not slots.has(account_key) and slots.size() >= max_sessions:
		return ""
	# New credential verification replaces previous Gateway credentials for this account.
	for token: String in sessions.keys():
		if sessions[token].get("id") == account.id:
			revoke_session(token)
	var session_id := Marshalls.raw_to_base64(Crypto.new().generate_random_bytes(32))
	# Never retain the mutable HTTP response (including guest password or session_id).
	sessions[session_id] = {"name": str(account.name), "id": int(account.id)}
	_session_expiry[session_id] = Time.get_ticks_msec() + session_ttl_seconds * 1000
	return session_id


func prune_sessions() -> void:
	var now := Time.get_ticks_msec()
	for token: String in sessions.keys():
		if now >= _session_expiry.get(token, 0):
			revoke_session(token)


func revoke_session(token: String) -> void:
	sessions.erase(token)
	_session_expiry.erase(token)
	var requests: Dictionary = _token_requests.get(token, {}).duplicate()
	_token_requests.erase(token)
	for request_id: int in requests:
		_finish_request(request_id, {"error": GatewayAPI.ERR_BAD_CREDENTIALS})


func handle_logout(payload: Dictionary) -> Dictionary:
	if verified_session(payload).is_empty():
		return {"error": GatewayAPI.ERR_BAD_CREDENTIALS}
	revoke_session(payload[GatewayAPI.KEY_TOKEN_ID])
	return {"ok": true}


func send_request(action: String, data: Dictionary, timeout_sec: float = 5.0) -> Dictionary:
	if action in ["create_character", "get_characters", "enter_world"]:
		var session: Dictionary = verified_session(data)
		if session.is_empty(): return {"error": GatewayAPI.ERR_BAD_CREDENTIALS}
		data = data.duplicate(true)
		data[GatewayAPI.KEY_ACCOUNT_USERNAME] = session.name
		data[GatewayAPI.KEY_ACCOUNT_ID] = session.id
	# The link up to the master may not be established yet at cold start. Bail with
	# a connection error rather than firing an RPC at an absent peer (which throws
	# ERR_CONNECTION_ERROR); the client treats this as retryable.
	if not gateway_manager_client.master_connected:
		return {"error": Error.ERR_TIMEOUT, "msg": "gateway not ready"}

	if pending_requests.size() >= max_pending_requests:
		return {"error": GatewayAPI.ERR_RATE_LIMITED, "msg": "gateway busy"}
	data = data.duplicate(true)
	var request_id: int = next_request_id
	next_request_id += 1

	var request: NetRequest = NetRequest.new()
	pending_requests[request_id] = request
	_request_deadlines[request_id] = Time.get_ticks_msec() + maxi(1, int(timeout_sec * 1000))
	if action in ["create_character", "get_characters", "enter_world"]:
		var token: String = data[GatewayAPI.KEY_TOKEN_ID]
		_request_sessions[request_id] = token
		if not _token_requests.has(token):
			_token_requests[token] = {}
		_token_requests[token][request_id] = true
	
	data.merge({GatewayAPI.KEY_REQUEST_ID: request_id, "action": action}, true)
	
	_send_to_master(request_id, data)
	
	# Also tolerate a synchronous transport rejection/completion.
	if request.is_done:
		return request.response
	return await request.completed


func _send_to_master(request_id: int, data: Dictionary) -> void:
	gateway_manager_client.gateway_request.rpc_id(1, request_id, data)

## Only the Gateway's credential-verified session may supply account identity.
func verified_session(data: Dictionary) -> Dictionary:
	var token: Variant = data.get(GatewayAPI.KEY_TOKEN_ID)
	if not token is String or not sessions.has(token): return {}
	if Time.get_ticks_msec() >= _session_expiry.get(token, 0):
		revoke_session(token)
		return {}
	var session: Dictionary = sessions[token]
	if str(data.get(GatewayAPI.KEY_ACCOUNT_USERNAME,"")) != str(session.get("name","")): return {}
	return session


func _finish_request(request_id: int, response: Dictionary) -> void:
	var request: NetRequest = pending_requests.get(request_id)
	if request == null:
		return
	var token: String = _request_sessions.get(request_id, "")
	# Erase before emitting: resumed callers may revoke sessions or enqueue work.
	pending_requests.erase(request_id)
	_request_deadlines.erase(request_id)
	_request_sessions.erase(request_id)
	if _token_requests.has(token):
		_token_requests[token].erase(request_id)
		if _token_requests[token].is_empty():
			_token_requests.erase(token)
	if not token.is_empty() and (not sessions.has(token) or Time.get_ticks_msec() >= _session_expiry.get(token, 0)):
		response = {"error": GatewayAPI.ERR_BAD_CREDENTIALS}
	request.resolve(response)


func _expire_requests() -> void:
	var now := Time.get_ticks_msec()
	for request_id: int in _request_deadlines.keys():
		if now >= _request_deadlines.get(request_id, now + 1):
			_on_request_timeout(request_id)


func _on_request_timeout(request_id: int) -> void:
	_finish_request(request_id, {"error": Error.ERR_TIMEOUT, "msg": "request timeout"})


func _on_gateway_manager_client_response_received(request_id: int, response: Dictionary) -> void:
	if _request_deadlines.has(request_id) and Time.get_ticks_msec() >= _request_deadlines[request_id]:
		_on_request_timeout(request_id)
		return
	_finish_request(request_id, response)


func _on_master_connection_lost() -> void:
	# No old authenticated work or credential survives a Master reconnection.
	for request_id: int in pending_requests.keys():
		_finish_request(request_id, {"error": Error.ERR_CONNECTION_ERROR, "msg": "master disconnected"})
	for token: String in sessions.keys():
		revoke_session(token)


# Per-IP throttle for the brute-forceable / spammable auth endpoints. __ip__ is the
# real client even behind Caddy — the HTTP addon reads the X-Real-IP header Caddy
# stamps (header_up X-Real-IP {remote_host}), falling back to the socket host. So
# loopback stays exempt only for local multi-instance testing (no proxy header).
func _rate_ok(payload: Dictionary, endpoint: StringName, max_calls: int, window_ms: int) -> bool:
	var ip: String = str(payload.get("__ip__", ""))
	if ip.is_empty() or ip == "127.0.0.1" or ip == "::1":
		return true
	return AuthRateLimiter.allow(ip, endpoint, max_calls, window_ms)


## Exact-match version gate (server build == client build). Returns {} when OK, else
## {error: ERR_OUTDATED_VERSION, msg}. Shared by login + the boot handshake so the
## two never drift.
func _check_version(payload: Dictionary) -> Dictionary:
	var server_version: String = GatewayAPI.game_version()
	var client_version: String = str(payload.get(GatewayAPI.KEY_CLIENT_VERSION, ""))
	if client_version == server_version:
		return {}
	var have: String = client_version if not client_version.is_empty() else "unknown"
	return {
		"error": GatewayAPI.ERR_OUTDATED_VERSION,
		"msg": "Outdated game version. Please update. (server %s, you have %s)" % [server_version, have],
	}


## Boot healthcheck (no auth): the gateway client calls this before showing any menu.
## OK only when the build matches AND the master link is up (so a login would land).
func handle_handshake(payload: Dictionary) -> Dictionary:
	var version_check: Dictionary = _check_version(payload)
	if not version_check.is_empty():
		return version_check
	if not gateway_manager_client.master_connected:
		return {"error": Error.ERR_TIMEOUT, "msg": "gateway not ready"}
	return {"ok": true}


func handle_login(payload: Dictionary) -> Dictionary:
	if not _rate_ok(payload, &"login", 10, 60000):
		return {"error": GatewayAPI.ERR_RATE_LIMITED}
	if not payload.has_all(
		[
			GatewayAPI.KEY_ACCOUNT_USERNAME,
			GatewayAPI.KEY_ACCOUNT_PASSWORD
		]
	):
		return {"error": "invalid_payload"}
	# Version gate (shared with the boot handshake) — reject a mismatched build.
	var version_check: Dictionary = _check_version(payload)
	if not version_check.is_empty():
		return version_check
	return await _authenticate("login", payload, str(payload[GatewayAPI.KEY_ACCOUNT_USERNAME]))


func _authenticate(action: String, payload: Dictionary, username: String = "") -> Dictionary:
	var reservation := _reserve_session(username)
	if reservation.is_empty():
		return {"error": GatewayAPI.ERR_RATE_LIMITED, "msg": "gateway session capacity"}
	var result: Dictionary = await send_request(action, payload)
	var error: Error = result.get("error", 0)
	if error != OK:
		_session_reservations.erase(reservation)
		return result
	
	var token := create_session(result, reservation)
	_session_reservations.erase(reservation)
	if token.is_empty():
		return {"error": GatewayAPI.ERR_RATE_LIMITED, "msg": "gateway session capacity"}
	result["session_id"] = token
	return result


func handle_guest(payload: Dictionary) -> Dictionary:
	if not _rate_ok(payload, &"guest", 5, 60000):
		return {"error": GatewayAPI.ERR_RATE_LIMITED}
	return await _authenticate("guest", payload)


func handle_character_create(payload: Dictionary) -> Dictionary:
	if not payload.has_all(
		[
			GatewayAPI.KEY_TOKEN_ID,
			GatewayAPI.KEY_ACCOUNT_USERNAME,
			GatewayAPI.KEY_WORLD_ID,
			"data"
		]
	):
		return {"error": "invalid_payload"}

	var character_data: Dictionary = payload.get("data", null) as Dictionary
	if character_data.is_empty():
		return {"error": 1}
	var result: Dictionary = CredentialsUtils.validate_username(character_data.get("name", ""))
	if result.get("code", CredentialsUtils.UsernameError.EMPTY) != CredentialsUtils.UsernameError.OK:
		return {"error": result}

	var response: Dictionary = await send_request("create_character", payload)
	var error: Error = response.get("error", 0)
	if error != OK:
		return response

	return response


func handle_world_characters(payload: Dictionary) -> Dictionary:
	if not payload.has_all(
		[
			GatewayAPI.KEY_TOKEN_ID,
			GatewayAPI.KEY_ACCOUNT_USERNAME,
			GatewayAPI.KEY_WORLD_ID,
		]
	):
		return {"error": "invalid_payload"}

	var response: Dictionary = await send_request("get_characters", payload)
	var error: Error = response.get("error", 0)
	if error != OK:
		return response

	return response



func handle_world_enter(payload: Dictionary) -> Dictionary:
	if not payload.has_all(
		[
			GatewayAPI.KEY_TOKEN_ID,
			GatewayAPI.KEY_ACCOUNT_USERNAME,
			GatewayAPI.KEY_WORLD_ID,
			GatewayAPI.KEY_CHAR_ID
		]
	):
		return {"error": "invalid_payload"}

	var response: Dictionary = await send_request("enter_world", payload)
	var error: Error = response.get("error", 0)
	if error != OK:
		return {"error": error}

	return response


## Cheap world-list refresh: served straight from the gateway's cached roster
## (the master broadcasts it on every world connect/disconnect), so no master
## round-trip per refresh. Used by the client's "Update" button and the
## empty-state auto-retry.
func handle_worlds(_payload: Dictionary) -> Dictionary:
	return {"w": _public_worlds(gateway_manager_client.worlds_info)}


## Whitelist only what a world card needs. The cached roster also carries each
## world's address, port and full heartbeat snapshot (player rosters, chat tail,
## server logs) — never ship those to a game client.
func _public_worlds(raw: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for world_id: Variant in raw:
		var info: Dictionary = raw[world_id].get("info", {})
		out[world_id] = {
			"info": {
				"name": info.get("name", ""),
				"motd": info.get("motd", ""),
				"pvp": info.get("pvp", false),
			}
		}
	return out


func handle_account_creation(payload: Dictionary) -> Dictionary:
	if not _rate_ok(payload, &"account_create", 5, 300000):
		return {"error": GatewayAPI.ERR_RATE_LIMITED}
	if not payload.has_all(
		[
			GatewayAPI.KEY_ACCOUNT_USERNAME,
			GatewayAPI.KEY_ACCOUNT_PASSWORD,
		]
	):
		return {"error": "invalid_payload"}

	# Validate server-side too — never trust the client's pre-check (length, chars,
	# reserved names). Same CredentialsUtils the client uses, so messages match.
	var username: String = str(payload.get(GatewayAPI.KEY_ACCOUNT_USERNAME, ""))
	var password: String = str(payload.get(GatewayAPI.KEY_ACCOUNT_PASSWORD, ""))
	var uname_check: Dictionary = CredentialsUtils.validate_username(username)
	if uname_check.get("code", CredentialsUtils.UsernameError.EMPTY) != CredentialsUtils.UsernameError.OK:
		return {"error": str(uname_check.get("message", "Invalid username."))}
	var pass_check: Dictionary = CredentialsUtils.validate_password(password)
	if pass_check.get("code", CredentialsUtils.UsernameError.EMPTY) != CredentialsUtils.UsernameError.OK:
		return {"error": str(pass_check.get("message", "Invalid password."))}

	var response: Dictionary = await send_request("create_account", payload)
	var error: Error = response.get("error", 0)
	if error != OK:
		return {"error": error}

	return response
