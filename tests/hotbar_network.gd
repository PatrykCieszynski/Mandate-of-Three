extends "res://tests/local_map_instances.gd"
const Hud = preload("res://source/client/ui_web/hotbar_ui_adapter.gd")
var progress: Dictionary={}
var _uid := ""
var _prefs := ""
var _dom: Dictionary={}
var _native_calls: int=0
class HudProjection extends UiCommandDispatcher:
	var value: Dictionary={}
	func set_domain(_domain: String, state: Dictionary) -> void:
		if _domain=="hotbar": value=state

@rpc("any_peer","call_remote","reliable",0)
func stage(label: String) -> void:
	if GameMode.is_world_server(): progress[label]=true

@rpc("authority","call_remote","reliable",0)
func exercise_hotbar(uid: String) -> void:
	_uid=uid
	await wait_until(func()->bool:return world.inventory_endpoint.state.items.any(func(item: Dictionary)->bool:return item.uid==uid))
	if CmdlineUtils.get_parsed_args().has("native-market-check"):
		await native_hud()
	else:
		var projection:=HudProjection.new();projection.bridge=WebUiBridge.new()
		var session:=UiCommandSession.new();var items:=ItemUiAdapter.new()
		items.journal.directory="res://.godot/verification/hotbar-inventory-"+Crypto.new().generate_random_bytes(8).hex_encode()
		items.attach(world.inventory_endpoint,projection,session,get_tree())
		var hud=Hud.new();hud.directory="res://.godot/verification/hotbar-network-"+Crypto.new().generate_random_bytes(8).hex_encode();_prefs=hud.directory
		hud.attach(projection,items._activate);world.inventory_endpoint.state_changed.connect(hud.accept_inventory);hud.accept_inventory(world.inventory_endpoint.state)
		var before: Dictionary=world.inventory_endpoint.state.duplicate(true)
		check(not hud._assign({"slot":8,"id":uid}).ok,"EQUIP assignment rejected")
		hud.bindings.assign_item(8,uid);check(hud._save(),"legacy preference fixture saved");hud.publish()
		check(world.inventory_endpoint.state==before,"assignment never changes custody or placement")
		check(not (await hud.activate_slot(8)).ok,"legacy EQUIP activation rejected")
		await wait_until(func()->bool:return not projection.value.slots[8].available)
		check(hud.bindings.binding(8).id==uid,"legacy EQUIP stays unavailable")
		world.inventory_endpoint.state_changed.disconnect(hud.accept_inventory);hud.dispose();items.dispose();session.close("test");projection.bridge.free();projection.free()
	stage.rpc_id(1,"equipped")

func native_hud() -> void:
	var ui=world.get_node("WebInventory")
	await wait_until(func()->bool:return ui.bridge.is_ready and ui.hotbar._ready)
	ui.set_open(true)
	ui.host.browser.call("eval","window.sendIpcMessage(JSON.stringify({v:1,type:'hotbar.assign',id:'native-hud-bind',payload:{slot:8,id:'%s'}}));" % _uid)
	await get_tree().create_timer(0.3).timeout
	check(ui.hotbar.bindings.binding(8).is_empty(),"CEF rejects EQUIP assignment")
	ui.hotbar.bindings.assign_item(8,_uid);check(ui.hotbar._save(),"legacy native preference fixture");ui.hotbar.publish()
	var activate: Callable=ui.items._activate
	ui.hotbar.activate_item=func(payload: Dictionary)->Dictionary:_native_calls+=1;return await activate.call(payload)
	world.input_enabled=true
	ClientState.menu_open=true
	var key:=InputEventKey.new();key.keycode=KEY_F1;key.physical_keycode=KEY_F1;key.pressed=true
	Input.parse_input_event(key);await get_tree().process_frame
	check(_native_calls==0,"typing/menu focus suppresses hotbar input")
	ClientState.menu_open=false
	Input.parse_input_event(key.duplicate())
	await get_tree().create_timer(0.3).timeout
	check(_native_calls==0 and ui.hotbar._owned.has(_uid),"F1 rejects saved EQUIP without Inventory activation")
	check(ui.hotbar.bindings.binding(8).id==_uid,"native F1 retains disabled legacy reference")
	world.input_enabled=false
	ui.host.message_received.connect(func(raw: String)->void:
		var value=JSON.parse_string(raw)
		if value is Dictionary and value.get("fixture")=="hud": _dom=value)
	ui.host.browser.call("eval","document.querySelector('.bottom-hud-system button:last-child').click();")
	await wait_until(func()->bool:return world._options.visible)
	world._options.hide()
	ui.host.reload_ui();await wait_until(func()->bool:return ui.bridge.is_ready)
	await get_tree().create_timer(0.2).timeout
	ui.host.browser.call("eval","window.sendIpcMessage(JSON.stringify({fixture:'hud',slots:document.querySelectorAll('.bottom-hud-slot').length,key:document.querySelector('[data-slot=\"8\"] .bottom-hud-key').textContent,hp:document.querySelector('.bottom-hud-meter.hp span').textContent}));")
	await wait_until(func()->bool:return not _dom.is_empty())
	check(_dom.slots==16 and _dom.key=="F1" and str(_dom.hp).contains("HP "),"native two-bank HUD survives reload")
	get_viewport().get_texture().get_image().save_png("res://.godot/verification/hotbar-native.png")
	print("HOTBAR_NATIVE_OK F1, focus gate, options, vitals and reload")

@rpc("authority","call_remote","reliable",0)
func after_transfer() -> void:
	await wait_until(func()->bool:return world.inventory_endpoint.state.get("ok",false))
	if CmdlineUtils.get_parsed_args().has("native-market-check"):
		var ui=world.get_node("WebInventory")
		await wait_until(func()->bool:return ui.hotbar._ready)
		check(ui.hotbar.bindings.binding(8).get("id","")==_uid,"new native composition restores CH-independent preferences")
	else:
		var projection:=HudProjection.new();projection.bridge=WebUiBridge.new()
		var hud=Hud.new();hud.directory=_prefs;hud.attach(projection,func(_p: Dictionary)->Dictionary:return {"ok":false})
		hud.accept_inventory(world.inventory_endpoint.state)
		check(hud.bindings.binding(8).get("id","")==_uid,"replacement composition restores preferences after real CH transfer")
		hud.dispose();projection.bridge.free();projection.free()
	print("HOTBAR_CLIENT_OK bindings, USE-only policy and CH restoration")
	finished.rpc_id(1);await get_tree().create_timer(0.2).timeout;socket.close();get_tree().quit()

@rpc("authority","call_remote","reliable",0)
func finish_observer() -> void:
	print("HOTBAR_CLIENT_OK observer on independent channel")
	finished.rpc_id(1);await get_tree().create_timer(0.2).timeout;socket.close();get_tree().quit()

func run_server() -> void:
	await wait_until(func()->bool:return ready_peers.size()==2)
	var peers: Array=ready_peers.keys();peers.sort_custom(func(a: int,b: int)->bool:return ready_peers[a].number<ready_peers[b].number)
	var hero: int=peers[0];var other: int=peers[1]
	var owner: int=server.connected_players[hero].player_id
	var host: ServerInstance=manager.find_instance_for_peer(hero)
	var target: ServerInstance=manager.find_instance_for_peer(other)
	for peer: int in peers:
		for mob: MobActor3D in manager.find_instance_for_peer(peer).get_node("GameWorld").mob_system.mobs.values(): mob.ai_enabled=false;mob.proximity_aggro=false
	var store: ItemStoreSqlite=server.database.item_store
	var item:=ItemInstance.create(ItemDefinitions.IRON_SWORD,owner,[])
	check(EconomyFixture.insert_item(store,item,100),"owned bag item fixture")
	var endpoint: InventoryEndpoint3D=host.get_node("GameWorld").inventory_endpoint
	endpoint.resynchronize(hero)
	exercise_hotbar.rpc_id(hero,item.uid)
	await wait_until(func()->bool:return progress.has("equipped"))
	check(store.inventory(owner).equipment.get("weapon","")!=item.uid,"hotbar never equipped the rejected UID")
	host.get_node("GameWorld").combat_endpoint.last_combat_ms.erase(hero)
	check(manager.transfers.start(hero,target.identity.channel_id).ok,"real local CH handoff")
	await wait_until(func()->bool:return target.get_node("GameWorld").characters.has(hero))
	await get_tree().create_timer(0.4).timeout
	after_transfer.rpc_id(hero)
	await wait_until(func()->bool:return done.has(hero))
	finish_observer.rpc_id(other)
	await wait_until(func()->bool:return done.size()==2)
	print("HOTBAR_SERVER_OK rejected EQUIP and local channel transfer")
	db.close_db();get_tree().quit()
