extends "res://tests/pve_network.gd"
## Real two-client RPC/SQLite fixture. Optional rendered client uses the actual CEF page.
var web: InventoryWebController
var web_results: Dictionary = {}
var browser_mode: bool = false
var running: bool = false

func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size() == 2 and ready_peers.size() == 2)
	for dog: SpikeWildDog3D in world.combat_endpoint.dogs.values(): dog.ai_enabled = false
	for id: int in world.characters: phase.rpc_id(id, "GO", "")
	await wait_until(func() -> bool: return done_peers.size() == 2)
	for id: int in world.characters:
		var owner: int = server.connected_players[id].player_id
		var snapshot: Dictionary = server.database.item_store.inventory(owner)
		check(snapshot.items.size() == 2 and snapshot.stats.attack == 10 and snapshot.equipment.is_empty(), "private exact inventory after moves")
		check(snapshot.items.any(func(i: Dictionary) -> bool: return i.bag_position == 15), "RPC bag move persisted")
		check(server.runtime_attack(owner) == 10, "runtime attack reconciled")
	var before: Array = []
	for id: int in world.characters: before.append(server.database.item_store.inventory(server.connected_players[id].player_id))
	db.close_db()
	check(db.open_db(), "reopen")
	var index: int = 0
	for id: int in world.characters:
		check(server.database.item_store.inventory(server.connected_players[id].player_id) == before[index], "relog item state")
		index += 1
	if not failed: print("WEB_INVENTORY_SERVER_OK: page/footprint moves, privacy, runtime stats and reopen")
	await get_tree().create_timer(0.6).timeout
	get_tree().quit(1 if failed else 0)

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed > 50: check(false, "web inventory timeout")
	if GameMode.is_world_server() or running or world == null or not world.inventory_endpoint.state.get("ok", false) or world.currency_endpoint.state.is_empty(): return
	running = true
	run_client()

func command(type: String, payload: Dictionary) -> Dictionary:
	var id: String = "fixture-%d" % (web_results.size() + 1)
	web.bridge.receive(JSON.stringify({"v": 1, "type": type, "id": id, "payload": payload}))
	await wait_until(func() -> bool: return web_results.has(id))
	await get_tree().create_timer(0.12).timeout
	return web_results.get(id, {"ok": false})

func run_client() -> void:
	web = world.get_node_or_null("WebInventory")
	browser_mode = web != null
	if web == null:
		web = InventoryWebController.new()
		world.add_child(web)
		web.setup(world)
	web.bridge.outgoing.connect(func(json: String) -> void:
		var message: Dictionary = JSON.parse_string(json)
		if message.type == "command.result" and str(message.id).begins_with("fixture-"): web_results[str(message.id)] = message.payload)
	if browser_mode:
		web.set_open(true)
		await wait_until(func() -> bool: return web.bridge.is_ready)
		await get_tree().create_timer(1.0).timeout
	else:
		web.bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
	register_ready.rpc_id(1)
	await wait_until(func() -> bool: return phase_name == "GO")
	var endpoint: SpikeInventory3D = world.inventory_endpoint
	var item: Dictionary = endpoint.state.items[0].duplicate(true)
	var result: Dictionary = await command("inventory.move_item", {"id":item.uid,"revision":item.revision,"x":0,"y":3,"page":0})
	check(result.ok, "web command waits for committed move RPC")
	check(endpoint.state.items.any(func(i: Dictionary) -> bool: return i.uid == item.uid and i.bag_position == 15 and i.revision == 1), "snapshot after move")
	result = await command("inventory.move_item", {"id":item.uid,"revision":0,"x":1,"y":3,"page":0})
	check(not result.ok and result.error == "stale", "server rejects stale UI command")
	result = await command("inventory.move_item", {"id":item.uid,"revision":1,"x":1,"y":0,"page":0})
	check(not result.ok and result.error == "occupied", "server rejects occupied placement")
	result = await command("inventory.move_item", {"id":item.uid,"revision":1,"x":0,"y":7,"page":0})
	check(not result.ok, "three-cell item cannot cross page boundary")
	result = await command("inventory.move_item", {"id":item.uid,"revision":1,"x":0,"y":0,"page":3})
	check(result.ok and endpoint.state.items.any(func(i: Dictionary) -> bool: return i.uid == item.uid and i.bag_position == 135), "fourth page persists")
	result = await command("inventory.move_item", {"id":item.uid,"revision":2,"x":0,"y":3,"page":0})
	check(result.ok, "return to first page")
	if browser_mode:
		# Test-only DOM events exercise the bundled view -> CEF IPC -> server flow.
		# Physical input is still a separate manual check.
		web.host.browser.connect("console_message", func(_level: int, message: String, _source: String, _line: int) -> void: print("CEF_GAME: ", message))
		await get_tree().create_timer(0.3).timeout
		# Pointer events emulate drag through the real page/IPC. Physical input is separate.
		web.host.browser.call("eval", "{const n=document.querySelector('.inventory-item');const r=n.getBoundingClientRect();n.setPointerCapture=()=>{};n.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,button:0,pointerId:1,clientX:r.x+12,clientY:r.y+12}));document.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,button:0,pointerId:1,clientX:r.x+12,clientY:r.y+12}));}")
		await get_tree().create_timer(0.8).timeout
		web.host.browser.call("eval", "{const g=document.querySelector('.inventory-grid').getBoundingClientRect();const c=g.width/5;document.body.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,button:0,pointerId:2,clientX:g.x+4*c+12,clientY:g.y+3*c+12}));}")
		await wait_until(func() -> bool: return endpoint.state.items.any(func(i: Dictionary) -> bool: return i.bag_position == 19))
		await get_tree().create_timer(0.2).timeout
		web.host.browser.call("eval", "console.log('GAME_INVENTORY_DOM',document.getElementById('inventory').hidden,document.querySelectorAll('.cell').length,document.querySelector('.wallet strong').textContent);")
		web.host.reload_ui()
		await wait_until(func() -> bool: return web.bridge.is_ready)
		await get_tree().create_timer(0.5).timeout
		check(not web.host.modal, "reload retains region-based ownership")
		await RenderingServer.frame_post_draw
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.godot/verification"))
		get_viewport().get_texture().get_image().save_png("res://.godot/verification/web-inventory-game.png")
		web.set_open(false)
		check(not ClientState.menu_open and web.host.keyboard_owner == "gameplay", "closing releases gameplay")
		web.set_open(true)
		await get_tree().create_timer(0.2).timeout
		web.set_open(false)
	if not failed: print("WEB_INVENTORY_CLIENT_OK: ", client_number, " rendered=", browser_mode)
	finished.rpc_id(1)
	await get_tree().create_timer(0.4).timeout
	get_tree().quit(1 if failed else 0)
