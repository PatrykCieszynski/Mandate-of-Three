extends "res://tests/stats_network.gd"
const Adapter = preload("res://source/client/ui_web/stats_ui_adapter.gd")
class StatsProjection extends UiCommandDispatcher:
	var snapshot: Dictionary={}
	func set_domain(_domain: String, value: Dictionary) -> void: snapshot=value
var _wire_sequence: int=1000
var _lose_response := true
var _intents: Array[String]=[]
var _dom: Dictionary={}

func transport(type: StringName, payload: Dictionary) -> Array:
	_wire_sequence+=1
	var id: int=_wire_sequence
	var session=get_node("Session")
	session._data_request.rpc_id(1,id,str(type),payload,"")
	await wait_until(func()->bool:return session.replies.has(id))
	var result: Dictionary=session.replies[id]
	if type==&"attribute.spend":
		_intents.append(payload.command_id)
		if _lose_response:
			_lose_response=false
			check(result.ok,"server committed before deliberately losing response")
			return [{},DataRequest.Error.TIMEOUT]
	return [result,DataRequest.Error.OK]

@rpc("authority","call_remote","reliable",0)
func exercise_stats(funded: bool) -> void:
	if funded:
		await wait_until(func()->bool:return not world.inventory_endpoint.state.get("economic_context",{}).is_empty())
		var projection:=StatsProjection.new();projection.bridge=WebUiBridge.new()
		var adapter=Adapter.new();adapter.journal.directory="res://.godot/verification/stats-ui-"+Crypto.new().generate_random_bytes(16).hex_encode()
		adapter.request=transport;adapter.attach(projection);adapter.accept_context(world.inventory_endpoint.state)
		await adapter.refresh()
		check(projection.snapshot.data.available_points=="4","exact authoritative counter projection")
		var result: Dictionary=await adapter._spend({"attribute":"STR"})
		check(not result.ok and projection.snapshot.pending,"lost response retains pending intent")
		check(not (await adapter._spend({"attribute":"DEX"})).ok,"pending prevents different allocation")
		var journal=adapter.journal;adapter.dispose()
		adapter=Adapter.new();adapter.journal=journal;adapter.request=transport
		var restored:=StatsProjection.new();restored.bridge=WebUiBridge.new();adapter.attach(restored)
		adapter.accept_context(world.inventory_endpoint.state)
		check(restored.snapshot.pending,"replacement adapter restores pending intent")
		check((await adapter.retry()).ok,"original receipt recovered")
		check(_intents.size()==2 and _intents[0]==_intents[1],"retry preserves command identity")
		check(restored.snapshot.data.available_points=="3" and restored.snapshot.data.attributes.STR=="1","no double allocation")
		check(journal.load_pending().entry.is_empty(),"confirmed intent cleared durably")
		adapter.dispose();restored.bridge.free();restored.free();projection.bridge.free();projection.free()
		if CmdlineUtils.get_parsed_args().has("native-market-check"): await native_stats()
	print("STATS_UI_CLIENT_OK exact counters, lost response, pending gate and replacement recovery")
	finished.rpc_id(1)
	await get_tree().create_timer(0.2).timeout
	socket.close();get_tree().quit()

func native_stats() -> void:
	var ui=world.get_node("WebInventory")
	await wait_until(func()->bool:return ui.bridge.is_ready)
	ui.stats.request=transport
	ui.party.toggle()
	world.input_enabled=true
	var key:=InputEventKey.new();key.keycode=KEY_V;key.physical_keycode=KEY_V;key.pressed=true
	Input.parse_input_event(key)
	await wait_until(func()->bool:return ui.stats.opened)
	world.input_enabled=false
	await wait_until(func()->bool:return not ui.stats._stats.is_empty())
	ui.host.message_received.connect(func(raw: String)->void:
		var value=JSON.parse_string(raw)
		if value is Dictionary and value.get("fixture")=="stats": _dom=value)
	await get_tree().create_timer(0.2).timeout
	ui.host.browser.call("eval","document.querySelector('#stats [aria-label=\"Increase VIT\"]').click();")
	await wait_until(func()->bool:return ui.stats._stats.attributes.get(&"VIT",0)==1 and ui.stats._pending.is_empty())
	ui.host.reload_ui()
	await wait_until(func()->bool:return ui.bridge.is_ready)
	await get_tree().create_timer(0.2).timeout
	ui.host.browser.call("eval","window.sendIpcMessage(JSON.stringify({fixture:'stats',visible:!document.querySelector('#stats').hidden,vit:document.querySelector('#stats [data-stat=VIT]').textContent,points:document.querySelector('#stats [data-stat=available_points]').textContent}));")
	await wait_until(func()->bool:return not _dom.is_empty())
	check(_dom.visible and _dom.vit=="1" and _dom.points=="2","CEF spends through real RPC and restores after reload: "+JSON.stringify(_dom))
	get_viewport().get_texture().get_image().save_png("res://.godot/verification/stats-native.png")
	print("STATS_UI_NATIVE_OK actual CEF bridge, authoritative allocation and reload")

func run_server() -> void:
	await wait_until(func()->bool:return ready_peers.size()==2)
	var peers: Array=ready_peers.keys()
	peers.sort_custom(func(a: int,b: int)->bool:return ready_peers[a].number<ready_peers[b].number)
	var hero: int=peers[0]
	var player: PlayerResource=server.connected_players[hero]
	server.database.award_experience(player,105)
	for peer: int in peers:
		for mob: MobActor3D in manager.find_instance_for_peer(peer).get_node("GameWorld").mob_system.mobs.values(): mob.ai_enabled=false;mob.proximity_aggro=false
	for peer: int in peers: exercise_stats.rpc_id(peer,peer==hero)
	await wait_until(func()->bool:return done.size()==2)
	check(player.attributes.get(&"STR",0)==1,"lost response and retry allocated exactly once")
	var native: bool=CmdlineUtils.get_parsed_args().has("native-market-server")
	check(player.attributes.get(&"VIT",0)==(1 if native else 0),"native CEF intent reached authoritative player")
	check(player.available_attributes_points==(2 if native else 3),"points conserved")
	print("STATS_UI_SERVER_OK real receipt replay, no duplicate spend and CEF allocation")
	db.close_db();get_tree().quit()
