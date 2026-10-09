extends "res://tests/pve_network.gd"
## Optional headless two-client RPC/SQLite regression. No DOM/layout assertions.
var web: InventoryWebController
var web_results: Dictionary = {}
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
		check(snapshot.items.all(func(i: Dictionary) -> bool: return i.location == "bag" and i.bag_position >= 0), "RPC equipment cycle persisted")
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
	web = InventoryWebController.new()
	world.add_child(web)
	web.setup(world)
	web.bridge.outgoing.connect(func(json: String) -> void:
		var message: Dictionary = JSON.parse_string(json)
		if message.type == "command.result" and str(message.id).begins_with("fixture-"): web_results[str(message.id)] = message.payload)
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
	result = await command("inventory.move_item", {"id":item.uid,"revision":1,"x":0,"y":InventoryGrid.ROWS - int(item.inventory_height) + 1,"page":0})
	check(not result.ok, "multi-cell item cannot cross page boundary")
	result = await command("inventory.move_item", {"id":item.uid,"revision":1,"x":0,"y":0,"page":3})
	check(result.ok and endpoint.state.items.any(func(i: Dictionary) -> bool: return i.uid == item.uid and i.bag_position == 135), "fourth page persists")
	result = await command("inventory.move_item", {"id":item.uid,"revision":2,"x":0,"y":3,"page":0})
	check(result.ok, "return to first page")
	var current: Dictionary = endpoint.state.items.filter(func(i: Dictionary) -> bool: return i.uid == item.uid)[0]
	var before_activation: Dictionary = endpoint.state.duplicate(true)
	result = await command("item.activate", {"id":item.uid,"revision":current.revision - 1})
	check(not result.ok and result.error == "stale" and endpoint.state.items == before_activation.items and endpoint.state.equipment == before_activation.equipment and endpoint.state.stats == before_activation.stats, "stale activation preserves authoritative snapshot")
	result = await command("item.activate", {"id":item.uid,"revision":current.revision})
	check(result.ok and endpoint.state.equipment.get("weapon") == item.uid, "Web activation commits and publishes equipment")
	check(not endpoint.state.items.any(func(i: Dictionary) -> bool: return i.has("primary_action")), "action stays outside presentation snapshots")
	current = endpoint.state.items.filter(func(i: Dictionary) -> bool: return i.uid == item.uid)[0]
	check(current.location == "equipment", "equipped item leaves bag")
	result = await command("equipment.unequip", {"id":item.uid,"revision":current.revision - 1})
	check(not result.ok and result.error == "stale", "Web unequip rejects stale revision")
	result = await command("equipment.unequip", {"id":item.uid,"revision":current.revision})
	check(result.ok and not endpoint.state.equipment.has("weapon"), "Web unequip commits and clears slot")
	check(endpoint.state.items.any(func(i: Dictionary) -> bool: return i.uid == item.uid and i.location == "bag"), "unequip returns to free bag cells")
	current = endpoint.state.items.filter(func(i: Dictionary) -> bool: return i.uid == item.uid)[0]
	result = await command("equipment.equip", {"id":item.uid,"revision":current.revision})
	check(result.ok and endpoint.state.equipment.get("weapon") == item.uid, "explicit equip still commits")
	current = endpoint.state.items.filter(func(i: Dictionary) -> bool: return i.uid == item.uid)[0]
	result = await command("equipment.unequip", {"id":item.uid,"revision":current.revision,"x":2,"y":3,"page":1})
	check(result.ok and endpoint.state.stats.attack == 10, "exact unequip restores runtime stats")
	check(endpoint.state.items.any(func(i: Dictionary) -> bool: return i.uid == item.uid and i.bag_position == 62 and i.revision == current.revision + 1), "Web exact unequip publishes selected cell and page")
	web.storage_opened = true
	current = endpoint.state.items.filter(func(i: Dictionary) -> bool: return i.uid == item.uid)[0]
	var transfer_payload: Dictionary = {"id":item.uid,"revision":current.revision,"from":"inventory","to":"storage","x":14,"y":0,"page":1,"quick":false}
	result = await command("storage.transfer",transfer_payload)
	check(result.ok and endpoint.state.storage.items.size()==1,"Web deposit commits and publishes Storage")
	check(not endpoint.state.items.any(func(i: Dictionary) -> bool: return i.uid==item.uid),"deposit removes Inventory item")
	transfer_payload.merge({"from":"storage","to":"inventory","quick":true,"revision":current.revision+1},true)
	transfer_payload.x=0
	transfer_payload.page=0
	result = await command("storage.transfer",transfer_payload)
	check(result.ok and endpoint.state.storage.items.is_empty(),"Web quick withdrawal clears Storage")
	check(endpoint.state.items.any(func(i: Dictionary) -> bool: return i.uid==item.uid and i.revision==current.revision+2),"withdrawal publishes revised Inventory")
	if not failed: print("WEB_INVENTORY_CLIENT_OK: ", client_number)
	finished.rpc_id(1)
	await get_tree().create_timer(0.4).timeout
	get_tree().quit(1 if failed else 0)
