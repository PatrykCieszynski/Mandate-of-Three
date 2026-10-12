extends "res://tests/pve_network.gd"
## Optional native renderer/CEF feasibility probe, not default smoke or physical input QA.
const NPC_ID: String = "spike-blacksmith-01"
var web: CoreUiController
var running: bool = false
var dom_replies: Dictionary = {}
var js_sequence: int = 0
var frame_samples: Array[float] = []
var gpu_samples: Array[float] = []
var sampling: bool = false
var diagnostic_second: int = -1

func _ready() -> void:
	map_scene_path = "res://source/common/gameplay/maps/graybox/first_region_3d.tscn"
	super._ready()
	if not GameMode.is_world_server():
		check(WebUiHost.supported_client(), "native Vulkan renderer gate")
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed > 80:
		check(false, "V0 timeout at " + fixture_checkpoint)
		return
	if sampling:
		frame_samples.append(delta * 1000.0)
		gpu_samples.append(RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()))
	if int(elapsed / 5.0) != diagnostic_second:
		diagnostic_second = int(elapsed / 5.0)
		print("V0_PROGRESS server=",GameMode.is_world_server()," elapsed=",elapsed," checkpoint=",fixture_checkpoint," phase=",phase_name," ready=",ready_peers.size()," running=",running)
	if GameMode.is_world_server() or running or world == null: return
	if not world.inventory_endpoint.state.get("ok", false) or world.currency_endpoint.state.is_empty(): return
	web = world.get_node_or_null("WebInventory") as CoreUiController
	if web == null or not web.bridge.is_ready: return
	running = true
	print("V0_NATIVE_STARTED")
	web.host.message_received.connect(func(message: String) -> void:
		var parsed: Variant = JSON.parse_string(message)
		if parsed is Dictionary and parsed.has("v0_id"): dom_replies[int(parsed.v0_id)] = parsed.get("value"))
	web.host.failure.connect(func(reason: String) -> void: check(false, "CEF failure: " + reason))
	web.host.browser.connect("console_message",func(level: int,message: String,_source: String,_line: int) -> void: print("V0_CONSOLE ",level," ",message))
	register_ready.rpc_id(1)
	run_native()

func run_server() -> void:
	fixture_checkpoint = "server-ready"
	await wait_until(func() -> bool: return world.characters.size() == 1 and ready_peers.size() == 1)
	for dog: MobActor3D in world.mob_system.mobs.values(): dog.ai_enabled = false
	var hero: int = world.characters.keys()[0]
	var owner: int = server.connected_players[hero].player_id
	world.characters[hero].position = world.npc_endpoint.actors[NPC_ID].position + Vector3(0, 0, 2)
	var ore := ItemInstance.create(ItemDefinitions.UPGRADE_ORE, owner, [])
	ore.amount = 2
	check(db.query("BEGIN IMMEDIATE;"), "material transaction")
	check(server.database.item_store.receive_item_in_transaction(ore).ok and db.query("COMMIT;"), "material fixture")
	check(server.database.add_yang(owner, 5000), "isolated pending Yang")
	world.inventory_endpoint.resynchronize(hero)
	print("V0_SERVER_GO")
	phase.rpc_id(hero, "GO", "")
	await wait_until(func() -> bool: return phase_name == "COMBAT")
	var dog: MobActor3D = world.mob_system.mobs.values()[0]
	dog.position = world.characters[hero].position + Vector3(0, 0, -1.1)
	dog.hp = 1000
	dog.ai_state = MobState.Value.IDLE
	phase.rpc_id(hero, "ATTACK", "")
	await wait_until(func() -> bool: return dog.hp < 1000)
	phase.rpc_id(hero, "HIT", "")
	await wait_until(func() -> bool: return done_peers.size() == 1)
	print("VISUAL_V0_SERVER_OK: isolated First Region, inventory, NPC economy and confirmed combat")
	world.process_mode = Node.PROCESS_MODE_DISABLED
	peer.close()
	db.close_db()
	get_tree().quit(1 if failed else 0)

@rpc("any_peer", "call_remote", "reliable", 0)
func prepare_combat() -> void:
	if GameMode.is_world_server(): phase_name = "COMBAT"

func js(body: String) -> Variant:
	js_sequence += 1
	var id: int = js_sequence
	print("V0_JS_START ",id," ",body)
	web.host.browser.call("eval", "Promise.resolve((()=>{%s})()).then(value=>window.sendIpcMessage(JSON.stringify({v0_id:%d,value}))).catch(e=>window.sendIpcMessage(JSON.stringify({v0_id:%d,value:{error:String(e)}})))" % [body, id, id])
	await wait_until(func() -> bool: return dom_replies.has(id))
	var value: Variant = dom_replies.get(id)
	print("V0_JS_DONE ",id," ",value)
	check(not (value is Dictionary and value.has("error")), "DOM eval: " + str(value))
	return value

func command(type: String, payload: Dictionary) -> Dictionary:
	var envelope: String = JSON.stringify({"v":1,"type":type,"id":"v0-%d" % (js_sequence + 1),"payload":payload})
	var result: Variant = await js("return new Promise(resolve=>{const request=%s;window.ipcMessage.addListener(raw=>{const m=JSON.parse(raw);if(m.type==='command.result'&&m.id===request.id)resolve(m.payload)});window.sendIpcMessage(JSON.stringify(request))})" % envelope)
	check(result is Dictionary and result.get("ok",false), "DOM → CEF → RPC → CEF result: " + type + " " + str(result))
	return result if result is Dictionary else {}

func capture(label: String) -> void:
	await get_tree().create_timer(0.4).timeout
	await RenderingServer.frame_post_draw
	var method: String = CmdlineUtils.get_parsed_args().get("v0-renderer", "unknown")
	check(get_viewport().get_texture().get_image().save_png("res://.godot/verification/%s-%s-%s.png" % [capture_prefix(),method,label]) == OK, "native capture")

func capture_prefix() -> String:
	return CmdlineUtils.get_parsed_args().get("visual-prefix", "visual-v0")

func run_native() -> void:
	await wait_until(func() -> bool: return phase_name == "GO")
	fixture_checkpoint = "inventory"
	world.input_enabled = true
	await key(KEY_I)
	check(web.opened, "native I shortcut opens Inventory")
	await get_tree().create_timer(0.6).timeout
	check(await js("return !document.querySelector('#inventory').hidden && document.querySelectorAll('#inventory .inventory-item').length>=2"), "production Inventory DOM")
	check(web.host.browser.get("texture") is Texture2DRD, "accelerated OSR texture")
	await capture("inventory")
	var item: Dictionary = world.inventory_endpoint.state.items.filter(func(i: Dictionary) -> bool: return i.definition_id == "iron_sword")[0].duplicate(true)
	# Synthetic Godot mouse input crosses CEF into the actual production drag code.
	var rect: Array = await js("const r=document.querySelector('#inventory [data-id=%s]').getBoundingClientRect();const g=document.querySelector('#inventory .inventory-grid').getBoundingClientRect();return [r.x+12,r.y+12,g.x+12,g.y+132]" % JSON.stringify(item.uid))
	await move_mouse(Vector2(rect[0],rect[1]), false)
	await mouse(Vector2(rect[0],rect[1]), true)
	await move_mouse(Vector2(rect[2],rect[3]))
	await mouse(Vector2(rect[2],rect[3]), false)
	print("V0_DRAG_DOM ",await js("return {status:document.querySelector('.inventory-status').textContent,carrying:!document.querySelector('.carried-item').hidden}"))
	await wait_until(func() -> bool: return world.inventory_endpoint.state.items.any(func(i: Dictionary) -> bool: return i.uid == item.uid and i.revision > item.revision))
	print("VISUAL_V0_DRAG_OK")
	await key(KEY_I)
	check(not web.opened and web.host.keyboard_owner == "gameplay", "native I closes UI and keeps gameplay keys")
	await key(KEY_I)
	check(web.opened, "native I reopens Inventory")
	var before_camera: Basis = world.gameplay_camera().global_basis
	await mouse(Vector2(650,300),true,MOUSE_BUTTON_RIGHT)
	var orbit_motion := InputEventMouseMotion.new()
	orbit_motion.position = Vector2(690,300)
	orbit_motion.relative = Vector2(40,0)
	orbit_motion.button_mask = MOUSE_BUTTON_MASK_RIGHT
	Input.parse_input_event(orbit_motion)
	await get_tree().create_timer(0.25).timeout
	check(not world.gameplay_camera().global_basis.is_equal_approx(before_camera), "native RMB orbit changes rendered camera with CEF open")
	await mouse(Vector2(690,300),false,MOUSE_BUTTON_RIGHT)
	check(not world.camera_controller.orbiting and web.host.keyboard_owner == "gameplay", "orbit release restores ownership")
	world.input_enabled = false
	web.host.hide_ui()
	check(web.host.keyboard_owner == "gameplay", "hide restores gameplay ownership")
	check(web.host.open(), "reopen CEF")
	web.host.set_modal(true)
	check(web.host.keyboard_owner == "modal", "modal ownership")
	web.host.set_modal(false)
	web.host.set_keyboard_owner("gameplay")
	fixture_checkpoint = "reload"
	web.host.reload_ui()
	await wait_until(func() -> bool: return web.bridge.is_ready)
	check(await js("return !document.querySelector('#inventory').hidden"), "reload restores production UI")
	fixture_checkpoint = "resize"
	DisplayServer.window_set_size(Vector2i(1100,780))
	await get_tree().create_timer(0.6).timeout
	check(await js("return innerWidth===1100 && innerHeight===780"), "CEF resize")
	await capture("resize")
	fixture_checkpoint = "recreate"
	web.host.destroy_browser()
	await get_tree().process_frame
	check(web.host.open(), "recreate CEF")
	await wait_until(func() -> bool: return web.bridge.is_ready)
	check(web.host.browser.get("texture") is Texture2DRD, "recreated accelerated OSR")
	fixture_checkpoint = "shop-upgrade"
	await command("npc.interact", {"npc_instance_id":NPC_ID})
	await command("npc.select_service", {"npc_instance_id":NPC_ID,"service_id":"weapon_shop"})
	await command("shop.open", {"npc_instance_id":NPC_ID,"service_id":"weapon_shop"})
	await wait_until(func() -> bool: return world.shop_endpoint.state.active)
	check(await js("return !document.querySelector('#shop').hidden"), "production Shop DOM")
	await capture("shop")
	await command("shop.buy", {"npc_instance_id":NPC_ID,"service_id":"weapon_shop","offer_id":"iron_sword"})
	await command("npc.select_service", {"npc_instance_id":NPC_ID,"service_id":"upgrade"})
	item = world.inventory_endpoint.state.items.filter(func(i: Dictionary) -> bool: return i.uid == item.uid)[0].duplicate(true)
	await command("upgrade.select", {"npc_instance_id":NPC_ID,"service_id":"upgrade","id":item.uid,"revision":item.revision})
	check(await js("return !document.querySelector('#upgrade').hidden"), "production Upgrade DOM")
	await capture("upgrade")
	await command("upgrade.execute", {"npc_instance_id":NPC_ID,"service_id":"upgrade","id":item.uid,"revision":item.revision})
	check(world.inventory_endpoint.state.items.any(func(i: Dictionary) -> bool: return i.uid == item.uid and i.upgrade_level == 1), "upgraded authoritative Inventory")
	fixture_checkpoint = "combat"
	await command("npc.close", {})
	prepare_combat.rpc_id(1)
	await wait_until(func() -> bool: return phase_name == "ATTACK")
	world.combat_endpoint.request_attack.rpc_id(1,1)
	await wait_until(func() -> bool: return phase_name == "HIT")
	await review_world()
	fixture_checkpoint = "measurement"
	sampling = true
	await get_tree().create_timer(3).timeout
	sampling = false
	frame_samples.sort()
	gpu_samples.sort()
	var report_data: Dictionary = {"renderer":RenderingServer.get_current_rendering_method(),"driver":RenderingServer.get_current_rendering_driver_name(),"gpu":RenderingServer.get_video_adapter_name(),"frames":frame_samples.size(),"frame_median_ms":frame_samples[frame_samples.size()/2],"frame_p95_ms":frame_samples[int(frame_samples.size()*0.95)],"viewport_gpu_median_ms":gpu_samples[gpu_samples.size()/2],"viewport_gpu_p95_ms":gpu_samples[int(gpu_samples.size()*0.95)],"static_memory_bytes":OS.get_static_memory_usage(),"physical_input_verified":false}
	var file := FileAccess.open("res://.godot/verification/%s-%s.json" % [capture_prefix(),CmdlineUtils.get_parsed_args().get("v0-renderer","unknown")],FileAccess.WRITE)
	file.store_string(JSON.stringify(report_data,"\t"))
	print("VISUAL_V0_CLIENT_OK: ",JSON.stringify(report_data))
	finished.rpc_id(1)
	await get_tree().create_timer(0.3).timeout
	web.host.destroy_browser()
	world.process_mode = Node.PROCESS_MODE_DISABLED
	peer.close()
	get_tree().quit(1 if failed else 0)

func move_mouse(point: Vector2, pressed: bool = true) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	Input.parse_input_event(motion)
	await get_tree().create_timer(0.2).timeout

func review_world() -> void:
	pass

func mouse(point: Vector2, pressed: bool, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = button
	event.pressed = pressed
	event.button_mask = (MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT) if pressed else 0
	Input.parse_input_event(event)
	await get_tree().create_timer(0.2).timeout

func key(code: Key) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await get_tree().create_timer(0.1).timeout
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
	await get_tree().create_timer(0.1).timeout
