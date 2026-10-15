extends Node
## Auth outcomes, not menu layout: production handlers with controlled responses,
## plus a real occupied HTTPRequest talking only to an ephemeral loopback server.
class MenuFixture extends "res://source/client/gateway/gateway.gd":
	var saved_credentials: int = 0
	func _ready() -> void:
		local_id = "gateway-menu-fixture-"
		account_name = "alpha"
		account_id = 21
		session_id = "fixture"
	func _revoke_gateway_session(_token: String, _username: String) -> void:
		pass
	func save_refresh_token(_token: String, _path: String) -> void:
		saved_credentials += 1

class ControlledMenu extends MenuFixture:
	signal reply(response: Dictionary)
	func do_request(_method: HTTPClient.Method, _path: String, _payload: Dictionary) -> Dictionary:
		return await reply

var scene := preload("res://source/client/gateway/gateway.tscn")
var server: TCPServer
var peers: Array[Dictionary] = []
var old_received := false
var new_received := false
var cancelled_response: Dictionary = {}
var old_completions := 0

func menu(script: GDScript = ControlledMenu) -> MenuFixture:
	var node := scene.instantiate()
	node.set_script(script)
	add_child(node)
	return node

func assert_logged_out(node: MenuFixture, world_token: String) -> void:
	assert(node.session_id.is_empty() and node.account_name.is_empty() and node.account_id == 0)
	assert(node.saved_credentials == 0, "stale login persisted credentials")
	assert(Client.authentication_token == world_token, "stale response started a World connection")
	assert(not node.is_queued_for_deletion(), "stale World handoff disposed the menu")

func _ready() -> void:
	run.call_deferred()

func run() -> void:
	for error: int in [ERR_TIMEOUT, ERR_CONNECTION_ERROR]:
		assert(GatewayError.is_connection_error({"error": error}))
		assert(GatewayError.is_connection_error({"error": float(error)}))
		assert(GatewayError.humanize({"error": error}) == TranslationServer.translate("ERR_CONNECTION"))
	assert(not GatewayError.is_connection_error({"error": GatewayAPI.ERR_BAD_CREDENTIALS}))
	for action: String in ["continue", "guest", "login", "character"]:
		for succeeded: bool in [false, true]:
			var node := menu() as ControlledMenu
			var world_token: String = Client.authentication_token
			match action:
				"continue": node._on_continue_button_pressed()
				"guest": node._on_guest_button_pressed()
				"login": node._login_with_credentials("alpha", "Password123!")
				"character": node._on_character_selected(1, 1)
			node._logout()
			node.reply.emit({"name": "alpha", "id": 21, "session_id": "stale", "w": {}, "address": "127.0.0.1", "port": 1, "auth-token": "stale"} if succeeded else {"error": GatewayAPI.ERR_BAD_CREDENTIALS})
			assert_logged_out(node, world_token)
			node.queue_free()
			await get_tree().process_frame
	# Logout also fences the continuation of an already-displayed error confirmation.
	var node := menu() as ControlledMenu
	var world_token: String = Client.authentication_token
	node._on_continue_button_pressed()
	node.reply.emit({"error": ERR_CONNECTION_ERROR})
	node._logout()
	assert_logged_out(node, world_token)
	node._on_guest_button_pressed()
	node.reply.emit({"name": "beta", "id": 22, "session_id": "new", "w": {}})
	assert(node.session_id == "new" and node.account_name == "beta" and node.account_id == 22)
	node.queue_free()
	await get_tree().process_frame
	await real_busy_http_logout()
	print("GATEWAY_MENU_LIFECYCLE_OK auth fencing and immediate relog with real occupied HTTPRequest")
	get_tree().quit()

func capture_old(node: MenuFixture, url: String) -> void:
	cancelled_response = await node.do_request(HTTPClient.METHOD_POST, url + "/old", {})
	old_completions += 1

func until(predicate: Callable) -> void:
	var deadline := Time.get_ticks_msec() + 3000
	while not predicate.call():
		assert(Time.get_ticks_msec() < deadline, "loopback HTTP fixture timed out")
		await get_tree().process_frame

func real_busy_http_logout() -> void:
	server = TCPServer.new()
	assert(server.listen(0, "127.0.0.1") == OK)
	var url := "http://127.0.0.1:%d" % server.get_local_port()
	var previous_url: Variant = ProjectSettings.get_setting("network/api/base_url", null)
	ProjectSettings.set_setting("network/api/base_url", url)
	var node := menu(MenuFixture)
	capture_old(node, url)
	await until(func() -> bool: return old_received)
	assert(node.http_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED, "real HTTP transport must be occupied")
	var busy: Dictionary = await node.do_request(HTTPClient.METHOD_POST, url + "/must-not-send", {})
	assert(busy.get("code") == ERR_BUSY, "a concurrent request must not replace the active waiter")
	# No frame, timer or old response between Logout and the new login attempt.
	node._logout()
	assert(old_completions == 1 and cancelled_response.get("error") == "request_cancelled")
	node._login_with_credentials("beta", "Password123!")
	await until(func() -> bool: return node.session_id == "new")
	assert(new_received and node.account_name == "beta" and node.account_id == 22)
	assert(node.saved_credentials == 1, "only the new login may save credentials")
	assert(old_completions == 1 and cancelled_response.get("error") == "request_cancelled", "old waiter consumed the new login response")
	node.queue_free()
	await get_tree().process_frame
	ProjectSettings.set_setting("network/api/base_url", previous_url)
	for peer: Dictionary in peers:
		peer.socket.disconnect_from_host()
	server.stop()
	server = null

func _process(_delta: float) -> void:
	if server == null:
		return
	while server.is_connection_available():
		peers.append({"socket": server.take_connection(), "data": "", "handled": false})
	for peer: Dictionary in peers:
		var socket: StreamPeerTCP = peer.socket
		socket.poll()
		if peer.handled or socket.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			continue
		var available := socket.get_available_bytes()
		if available > 0:
			var chunk := socket.get_data(available)
			assert(chunk[0] == OK)
			peer.data += chunk[1].get_string_from_utf8()
		var raw: String = peer.data
		if not raw.contains("\r\n\r\n"):
			continue
		var headers := raw.get_slice("\r\n\r\n", 0)
		var body := raw.substr(headers.length() + 4)
		var content_length := 0
		for header: String in headers.split("\r\n"):
			if header.to_lower().begins_with("content-length:"):
				content_length = header.get_slice(":", 1).strip_edges().to_int()
		if body.to_utf8_buffer().size() < content_length:
			continue
		peer.handled = true
		if raw.begins_with("POST /old "):
			old_received = true
			continue # Keep the first real HTTPRequest waiting indefinitely.
		assert(raw.begins_with("POST /v1/login "))
		assert(JSON.parse_string(body).get("a-u") == "beta")
		new_received = true
		var response := JSON.stringify({"name": "beta", "id": 22, "session_id": "new", "w": {}})
		var packet := "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [response.to_utf8_buffer().size(), response]
		assert(socket.put_data(packet.to_utf8_buffer()) == OK)
