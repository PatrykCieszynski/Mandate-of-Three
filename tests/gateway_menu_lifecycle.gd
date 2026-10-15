extends Node
## Logout fencing is an observable menu contract, not a counter assertion.
## Instantiate the production scene and handlers, control only HTTP responses and
## credential file access. Headless client role; no account or socket required.
class TestMenu extends "res://source/client/gateway/gateway.gd":
	signal reply(response: Dictionary)
	var saved_credentials: int = 0
	func _ready() -> void:
		local_id = "gateway-menu-fixture-"
		main_panel.show()
		for path: String in ["LoginPanel", "CreateAccountPanel", "WorldSelection", "CharacterSelection", "CharacterCreation", "AlreadyConnectedPanel", "PopupPanel"]:
			get_node(path).hide()
		menu_stack.append(main_panel)
		account_name = "alpha"
		account_id = 21
		session_id = "fixture"
	func do_request(_method: HTTPClient.Method, _path: String, _payload: Dictionary) -> Dictionary:
		return await reply
	func _revoke_gateway_session(_token: String, _username: String) -> void:
		pass
	func save_refresh_token(_token: String, _path: String) -> void:
		saved_credentials += 1

var scene := preload("res://source/client/gateway/gateway.tscn")

func menu() -> TestMenu:
	var node := scene.instantiate()
	node.set_script(TestMenu)
	add_child(node)
	return node

func assert_logged_out(node: TestMenu) -> void:
	assert(node.session_id.is_empty() and node.account_name.is_empty() and node.account_id == 0)
	assert(node.main_panel.visible and not node.is_queued_for_deletion())
	for path: String in ["LoginPanel", "WorldSelection", "CharacterSelection", "AlreadyConnectedPanel", "PopupPanel"]:
		assert(not node.get_node(path).visible, "stale continuation reopened " + path)
	assert(node.saved_credentials == 0, "stale login persisted credentials")

func _ready() -> void:
	run.call_deferred()

func run() -> void:
	for error: int in [ERR_TIMEOUT, ERR_CONNECTION_ERROR]:
		assert(GatewayError.is_connection_error({"error": error}))
		assert(GatewayError.is_connection_error({"error": float(error)}))
		assert(GatewayError.humanize({"error": error}) == TranslationServer.translate("ERR_CONNECTION"))
	assert(not GatewayError.is_connection_error({"error": GatewayAPI.ERR_BAD_CREDENTIALS}))
	for action: String in ["continue", "characters", "guest", "login", "character"]:
		for succeeded: bool in [false, true]:
			var node := menu()
			match action:
				"continue": node._on_continue_button_pressed()
				"characters": node._on_world_selected(1)
				"guest": node._on_guest_button_pressed()
				"login":
					node.get_node("LoginPanel/VBoxContainer/VBoxContainer/VBoxContainer/LineEdit").text = "alpha"
					node.get_node("LoginPanel/VBoxContainer/VBoxContainer/VBoxContainer2/LineEdit").text = "Password123!"
					node._on_login_login_button_pressed()
				"character": node._on_character_selected(1, 1)
			node._logout()
			node.reply.emit({"name": "alpha", "id": 21, "session_id": "stale", "w": {}, "address": "127.0.0.1", "port": 1, "auth-token": "stale"} if succeeded else {"error": GatewayAPI.ERR_BAD_CREDENTIALS})
			assert_logged_out(node)
			node.queue_free()
			await get_tree().process_frame
	# A successful stale login must not install credentials or start a transition.
	var node := menu()
	node._on_guest_button_pressed()
	node._logout()
	node.reply.emit({"name": "alpha", "id": 21, "session_id": "stale", "w": {}})
	assert_logged_out(node)
	# Nor may an already-displayed error reopen its screen after Logout dismisses it.
	node._on_continue_button_pressed()
	node.reply.emit({"error": ERR_CONNECTION_ERROR})
	assert(node.popup_panel.visible)
	node._logout()
	assert_logged_out(node)
	# Fresh work in the new generation is still allowed.
	node._on_guest_button_pressed()
	node.reply.emit({"name": "beta", "id": 22, "session_id": "new", "w": {}})
	assert(node.session_id == "new" and node.get_node("WorldSelection").visible)
	node.queue_free()
	await get_tree().process_frame
	print("GATEWAY_MENU_LIFECYCLE_OK disconnect errors, stale replies/popup dismissal and fresh login")
	get_tree().quit()
