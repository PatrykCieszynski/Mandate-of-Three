extends "res://tests/local_map_instances.gd"
var received: Array=[]
var responses: Dictionary={}
var chat_attached: bool=false
var tag: int=0
var _native_dom: Dictionary={}
@rpc("authority","call_remote","reliable",0)
func send_chat(id: String, payload: Dictionary) -> void:
	world.chat_endpoint.request.rpc_id(1,id,payload)
@rpc("any_peer","call_remote","reliable",0)
func chat_reply(id: String, result: Dictionary) -> void:
	if GameMode.is_world_server(): responses[id]=result
@rpc("authority","call_remote","reliable",0)
func inspect_chat(label: String, expected: int) -> void:
	await get_tree().process_frame
	check(received.filter(func(m: Dictionary)->bool: return m.text==label).size()==expected,"client delivery count: "+label)
	report.rpc_id(1,label)
@rpc("authority","call_remote","reliable",0)
func chat_finish() -> void:
	if CmdlineUtils.get_parsed_args().has("native-market-check"):
		var ui=world.get_node("WebInventory")
		await wait_until(func()->bool:return ui.bridge.is_ready)
		ui.host.message_received.connect(func(raw: String)->void:
			var value=JSON.parse_string(raw)
			if value is Dictionary and value.get("fixture")=="chat": _native_dom=value)
		world.input_enabled=true
		var enter:=InputEventKey.new();enter.keycode=KEY_ENTER;enter.physical_keycode=KEY_ENTER;enter.pressed=true
		Input.parse_input_event(enter)
		await wait_until(func()->bool:return ClientState.menu_open)
		ui.host.browser.call("eval","window.sendIpcMessage(JSON.stringify({fixture:'chat',focused:document.activeElement?.getAttribute('aria-label'),logs:document.querySelector('#chat').textContent,whispers:document.querySelectorAll('.chat-whisper').length}));")
		await wait_until(func()->bool:return not _native_dom.is_empty())
		check(_native_dom.focused=="Chat message" and str(_native_dom.logs).contains("party after transfer") and int(_native_dom.whispers)==1,"native Enter focuses main chat and real messages/whisper render")
		ui.host.browser.call("eval","const field=document.querySelector('#chat [aria-label=\"Chat message\"]');field.value='native CEF send';field.form.requestSubmit();")
		await wait_until(func()->bool:return received.any(func(m: Dictionary)->bool:return m.text=="native CEF send"))
		var escape:=InputEventKey.new();escape.keycode=KEY_ESCAPE;escape.physical_keycode=KEY_ESCAPE;escape.pressed=true
		Input.parse_input_event(escape)
		await wait_until(func()->bool:return not ClientState.menu_open)
		_native_dom.clear();ui.host.reload_ui()
		await wait_until(func()->bool:return ui.bridge.is_ready)
		await get_tree().create_timer(0.5).timeout
		ui.host.browser.call("eval","window.sendIpcMessage(JSON.stringify({fixture:'chat',logs:document.querySelector('#chat').textContent,whispers:document.querySelectorAll('.chat-whisper').length}));")
		await wait_until(func()->bool:return not _native_dom.is_empty())
		check(str(_native_dom.logs).contains("party after transfer") and int(_native_dom.whispers)==1,"native reload restores session history and one whisper window")
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://.godot/verification/chat-native.png")
		print("CHAT_NATIVE_OK native Enter/Escape focus, messages, whisper and reload; synthetic native key input")
	world.input_enabled=false
	print("CHAT_CLIENT_OK real RPC cross-channel deliveries")
	finished.rpc_id(1)
	await get_tree().create_timer(0.2).timeout
	socket.close();get_tree().quit()
func send_from(peer: int, payload: Dictionary, ok: bool = true) -> void:
	tag+=1
	var id: String="chat-test-%d"%tag
	send_chat.rpc_id(peer,id,payload)
	await wait_until(func()->bool: return responses.has(id))
	check(bool(responses[id].ok)==ok,"chat response "+str(payload))
func counts(peers: Array, label: String, expected: Array) -> void:
	answers.clear()
	for i: int in peers.size(): inspect_chat.rpc_id(peers[i],label,expected[i])
	await wait_until(func()->bool:return answers.size()==peers.size())
func run_server() -> void:
	await wait_until(func()->bool:return ready_peers.size()==2)
	var peers: Array=ready_peers.keys()
	peers.sort_custom(func(a: int,b: int)->bool:return ready_peers[a].number<ready_peers[b].number)
	var first: int=peers[0];var second: int=peers[1]
	var a: ServerInstance=manager.find_instance_for_peer(first);var b: ServerInstance=manager.find_instance_for_peer(second)
	check(a!=b,"two real CH")
	var left: GameWorld3D=a.get_node("GameWorld");var right: GameWorld3D=b.get_node("GameWorld")
	for w: GameWorld3D in [left,right]:
		for mob: MobActor3D in w.mob_system.mobs.values(): mob.ai_enabled=false;mob.proximity_aggro=false
	await send_from(first,{"action":"send","channel":"general","text":"global CH"})
	await counts(peers,"global CH",[1,1])
	await send_from(first,{"action":"send","channel":"trade","text":"trade CH"})
	await counts(peers,"trade CH",[1,1])
	await send_from(first,{"action":"send","channel":"local","text":"local CH"})
	await counts(peers,"local CH",[1,0])
	var owner_a: int=server.connected_players[first].player_id;var owner_b: int=server.connected_players[second].player_id
	await send_from(first,{"action":"send","channel":"party","text":"no party"},false)
	await send_from(first,{"action":"send","channel":"guild","text":"no guild"},false)
	check(server.party_service.command(owner_a,{"action":"invite","target":owner_b}).ok,"invite")
	check(server.party_service.command(owner_b,{"action":"accept"}).ok,"accept")
	await send_from(first,{"action":"send","channel":"party","text":"party CH"})
	await counts(peers,"party CH",[1,1])
	await send_from(first,{"action":"send","channel":"whisper","target":owner_b,"text":"secret"})
	await counts(peers,"secret",[1,1])
	await send_from(first,{"action":"send","channel":"whisper","target":90000000,"text":"missing"},false)
	await send_from(first,{"action":"send","channel":"general","text":"spoof","sender":owner_b},false)
	await send_from(first,{"action":"send","channel":"system","text":"fake GM"},false)
	await counts(peers,"spoof",[0,0]);await counts(peers,"fake GM",[0,0])
	await get_tree().create_timer(5.1).timeout
	var replay: Dictionary={"action":"send","channel":"party","text":"transfer replay"}
	send_chat.rpc_id(second,"stable-transfer-message",replay)
	await wait_until(func()->bool:return responses.has("stable-transfer-message"))
	check(responses["stable-transfer-message"].ok,"original send accepted before transfer")
	# Transfer the second player through the real manager into the first CH.
	right.combat_endpoint.last_combat_ms.erase(second)
	check(manager.transfers.start(second,a.identity.channel_id).ok,"start local CH transfer")
	await wait_until(func()->bool:return left.characters.has(second) and not right.characters.has(second))
	await get_tree().create_timer(0.4).timeout
	responses.erase("stable-transfer-message")
	send_chat.rpc_id(second,"stable-transfer-message",replay)
	await wait_until(func()->bool:return responses.has("stable-transfer-message"))
	await counts(peers,"transfer replay",[1,1])
	left.characters[first].position=Vector3.ZERO;left.characters[second].position=Vector3(41,0,0)
	await send_from(first,{"action":"send","channel":"local","text":"local far"})
	await counts(peers,"local far",[1,0])
	left.characters[second].position=Vector3(2,0,0)
	await send_from(first,{"action":"send","channel":"local","text":"local near"})
	await counts(peers,"local near",[1,1])
	await send_from(first,{"action":"send","channel":"party","text":"party after transfer"})
	await counts(peers,"party after transfer",[1,1])
	for p: int in peers: chat_finish.rpc_id(p)
	await wait_until(func()->bool:return done.size()==2)
	print("CHAT_SERVER_OK process-global, local radius, party transfer, whisper and authorization")
	db.close_db();get_tree().quit()
func _process(delta: float) -> void:
	super(delta)
	if GameMode.is_world_server() or world==null: return
	if world.chat_endpoint.has_meta("fixture_attached"): return
	world.chat_endpoint.set_meta("fixture_attached",true)
	world.chat_endpoint.message_received.connect(func(message: Dictionary)->void: received.append(message))
	world.chat_endpoint.operation_finished.connect(func(id: String,result: Dictionary)->void: chat_reply.rpc_id(1,id,result))
