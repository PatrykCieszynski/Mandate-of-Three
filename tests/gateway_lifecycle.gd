extends Node
## New contract: bounded Gateway work and revoked/expired credentials cannot be
## covered by SQLite identity tests. Use production reply/signal handling with a
## controlled transport, no sockets, accounts or menu windows.
class TestManager extends GatewayManagerClient:
	func _ready() -> void:
		pass

class TestGateway extends "res://source/server/gateway/http_server.gd":
	var sent: Dictionary = {}
	func _ready() -> void:
		_bind_master_lifecycle()
	func _physics_process(_delta: float) -> void:
		_expire_requests()
	func _send_to_master(request_id: int, data: Dictionary) -> void:
		sent[request_id] = data

var gateway: TestGateway
var manager: TestManager
var results: Dictionary = {}
var completions: Dictionary = {}

func _ready() -> void:
	manager = TestManager.new()
	manager.name = "GatewayManagerClient"
	add_child(manager)
	manager.master_connected = true
	gateway = TestGateway.new()
	gateway.name = "GatewayHTTPServer"
	add_child(gateway)
	run.call_deferred()

func capture(label: String, action: String = "login", payload: Dictionary = {}, timeout: float = 5.0) -> void:
	results[label] = await gateway.send_request(action, payload, timeout)
	completions[label] = int(completions.get(label, 0)) + 1

func wait_monotonic(duration_ms: int) -> void:
	var deadline := Time.get_ticks_msec() + duration_ms
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

func authenticate(label: String, action: String, username: String = "alpha") -> void:
	var payload := {"a-u": username, "a-p": "test", "c-v": GatewayAPI.game_version()}
	if action == "guest":
		results[label] = await gateway.handle_guest({})
	else:
		results[label] = await gateway.handle_login(payload)

func run() -> void:
	# Repeated completion must release retained work, never resolve a caller twice.
	for index: int in 32:
		var label := str(index)
		capture(label)
		var id := gateway.next_request_id - 1
		manager.gateway_response(id, {"ok": true})
		manager.gateway_response(id, {"error": 1})
		assert(results[label].get("ok", false) and completions[label] == 1)
	assert(gateway.pending_requests.is_empty(), "terminal replies release bounded pending work")
	gateway.max_pending_requests = 2
	capture("held1")
	var held1 := gateway.next_request_id - 1
	capture("held2")
	capture("overflow")
	assert(results.overflow.error == GatewayAPI.ERR_RATE_LIMITED)
	assert(gateway.pending_requests.size() == 2)
	manager.gateway_response(held1, {"ok": true})
	capture("admitted_again")
	assert(not results.has("admitted_again"), "completed work returns capacity")
	manager._on_server_disconnected()
	assert(results.held2.error == ERR_CONNECTION_ERROR and results.admitted_again.error == ERR_CONNECTION_ERROR)
	assert(gateway.pending_requests.is_empty())
	capture("offline")
	assert(results.offline.error == ERR_TIMEOUT)
	manager.master_connected = true
	capture("timeout", "login", {}, 0.01)
	var timed_out := gateway.next_request_id - 1
	await wait_monotonic(50)
	await get_tree().physics_frame
	await get_tree().process_frame
	assert(results.timeout.error == ERR_TIMEOUT and gateway.pending_requests.is_empty())
	manager.gateway_response(timed_out, {"ok": true})
	assert(results.timeout.error == ERR_TIMEOUT and completions.timeout == 1)
	capture("after_timeout")
	var newer := gateway.next_request_id - 1
	manager.gateway_response(timed_out, {"ok": true})
	assert(not results.has("after_timeout"), "old reply cannot resolve a newer request")
	manager.gateway_response(newer, {"ok": true})

	var account := {"name": "alpha", "id": 21, "password": "must_not_be_retained"}
	var token := gateway.create_session(account)
	account.name = "mutated"
	var payload := {"t-id": token, "a-u": "alpha", "a-id": 999}
	var verified := gateway.verified_session(payload)
	assert(verified.id == 21 and not verified.has("password"))
	assert(gateway.verified_session({"t-id": token, "a-u": "other"}).is_empty())
	capture("identity", "get_characters", payload)
	var identity_id := gateway.next_request_id - 1
	assert(gateway.sent[identity_id]["a-id"] == 21 and payload["a-id"] == 999)
	assert(gateway.handle_logout(payload).ok)
	assert(results.identity.error == GatewayAPI.ERR_BAD_CREDENTIALS)
	manager.gateway_response(identity_id, {"secret": true})
	assert(completions.identity == 1 and gateway.verified_session(payload).is_empty())
	capture("revoked", "get_characters", payload)
	assert(results.revoked.error == GatewayAPI.ERR_BAD_CREDENTIALS)
	var old_token := gateway.create_session({"name": "alpha", "id": 21})
	var replacement := gateway.create_session({"name": "alpha", "id": 21})
	assert(gateway.verified_session({"t-id": old_token, "a-u": "alpha"}).is_empty())
	assert(not gateway.verified_session({"t-id": replacement, "a-u": "alpha"}).is_empty())
	gateway.max_sessions = 1
	assert(gateway.create_session({"name": "beta", "id": 22}).is_empty())
	manager._on_server_disconnected()
	assert(gateway.verified_session({"t-id": replacement, "a-u": "alpha"}).is_empty())
	manager.master_connected = true

	gateway.session_ttl_seconds = 1
	var expired := gateway.create_session({"name": "alpha", "id": 21})
	capture("expires_inflight", "get_characters", {"t-id": expired, "a-u": "alpha"})
	var expiring_id := gateway.next_request_id - 1
	await wait_monotonic(1050)
	manager.gateway_response(expiring_id, {"secret": true})
	assert(results.expires_inflight.error == GatewayAPI.ERR_BAD_CREDENTIALS)
	assert(gateway.verified_session({"t-id": expired, "a-u": "alpha"}).is_empty())
	var prune_token := gateway.create_session({"name": "alpha", "id": 21})
	await wait_monotonic(1050)
	gateway.prune_sessions()
	assert(gateway.sessions.is_empty())
	assert(gateway.verified_session({"t-id": prune_token, "a-u": "alpha"}).is_empty())
	# Session admission precedes side effects in Master, including concurrent auth.
	gateway.session_ttl_seconds = 28800
	gateway.max_sessions = 1
	var active := gateway.create_session({"name": "alpha", "id": 21})
	var before_id := gateway.next_request_id
	authenticate("full_guest", "guest")
	authenticate("full_other", "login", "beta")
	assert(results.full_guest.error == GatewayAPI.ERR_RATE_LIMITED)
	assert(results.full_other.error == GatewayAPI.ERR_RATE_LIMITED)
	assert(gateway.next_request_id == before_id, "no Master guest/account/kick side effects at capacity")
	# Replacement reserves the existing slot and wrong credentials do not revoke it.
	authenticate("bad_replace", "login", " ALPHA ")
	var replacement_id := gateway.next_request_id - 1
	manager.gateway_response(replacement_id, {"error": GatewayAPI.ERR_BAD_CREDENTIALS})
	assert(not gateway.verified_session({"t-id": active, "a-u": "alpha"}).is_empty())
	authenticate("replace", "login", "alpha")
	authenticate("concurrent_replace", "login", "alpha")
	assert(results.concurrent_replace.error == GatewayAPI.ERR_RATE_LIMITED)
	# Logging out while replacement waits cannot free its reserved capacity.
	gateway.handle_logout({"t-id": active, "a-u": "alpha"})
	before_id = gateway.next_request_id
	authenticate("reserved_guest", "guest")
	assert(results.reserved_guest.error == GatewayAPI.ERR_RATE_LIMITED and gateway.next_request_id == before_id)
	manager.gateway_response(before_id - 1, {"name": "alpha", "id": 21})
	assert(results.replace.has("session_id"))
	gateway.handle_logout({"t-id": results.replace.session_id, "a-u": "alpha"})
	authenticate("guest1", "guest")
	var guest_id := gateway.next_request_id - 1
	before_id = gateway.next_request_id
	authenticate("guest_overflow", "guest")
	assert(results.guest_overflow.error == GatewayAPI.ERR_RATE_LIMITED and gateway.next_request_id == before_id)
	manager.gateway_response(guest_id, {"name": "guest22", "id": 22})
	assert(results.guest1.has("session_id"))
	gateway.handle_logout({"t-id": results.guest1.session_id, "a-u": "guest22"})
	# Disconnect releases held reservations; a subsequent authentication can proceed.
	authenticate("interrupted_auth", "guest")
	manager._on_server_disconnected()
	assert(results.interrupted_auth.error == ERR_CONNECTION_ERROR)
	manager.master_connected = true
	authenticate("recovered_guest", "guest")
	manager.gateway_response(gateway.next_request_id - 1, {"name": "guest23", "id": 23})
	assert(results.recovered_guest.has("session_id"))
	gateway.handle_logout({"t-id": results.recovered_guest.session_id, "a-u": "guest23"})
	gateway.max_sessions = 3
	gateway.max_pending_requests = 8
	gateway.session_ttl_seconds = 1
	for index: int in 3:
		var name := "batch%d" % index
		var batch_token := gateway.create_session({"name": name, "id": index + 100})
		for query: int in 2:
			capture("%s_%d" % [name, query], "get_characters", {"t-id": batch_token, "a-u": name})
	await wait_monotonic(1050)
	gateway.prune_sessions()
	for index: int in 3:
		for query: int in 2:
			var label := "batch%d_%d" % [index, query]
			assert(results[label].error == GatewayAPI.ERR_BAD_CREDENTIALS and completions[label] == 1)
	assert(gateway.pending_requests.is_empty() and gateway.sessions.is_empty())
	print("GATEWAY_LIFECYCLE_OK bounded requests, single completion, expiry/logout/reconnect and stale reply rejection")
	get_tree().quit()
