extends "res://tests/pve_network.gd"
## Optional headless two-client RPC/SQLite regression. No DOM/layout assertions.
class HeadlessUiHost extends WebUiHost:
	# Exercise the real bridge/controller without invoking an unavailable native browser.
	func open() -> bool: return true

var web: CoreUiController
var web_results: Dictionary = {}
var web_snapshots: Array[Dictionary] = []
var running: bool = false
var inventory_facts: Dictionary = {}
var journal_directory := ""

func _ready() -> void:
	var args := OS.get_cmdline_args()
	var probe := args.find("--inventory-journal-probe")
	if probe >= 0:
		var journal = preload("res://source/client/ui_web/local_economy_journal.gd").new("inventory-",args[probe+1])
		var loaded: Dictionary = journal.configure({"authority_id":args[probe+2],"account_id":int(args[probe+3]),"character_id":int(args[probe+4])})
		if loaded.ok and loaded.entry.get("id", "") == args[probe+5] and ItemUiAdapter.valid_intent(loaded.entry.payload):
			print("INVENTORY_JOURNAL_PROCESS_OK")
			get_tree().quit()
		else: get_tree().quit(1)
		return
	super._ready()

func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size() == 2 and ready_peers.size() == 2)
	world.inventory_endpoint.inventory_changed.connect(func(owner: int) -> void: inventory_facts[owner] = int(inventory_facts.get(owner, 0)) + 1)
	for dog: MobActor3D in world.mob_system.mobs.values(): dog.ai_enabled = false
	for id: int in world.characters: phase.rpc_id(id, "GO", "")
	await wait_until(func() -> bool: return done_peers.size() == 2)
	for id: int in world.characters:
		var owner: int = server.connected_players[id].player_id
		var snapshot: Dictionary = server.database.item_store.inventory(owner)
		check(snapshot.items.size() == 2 and snapshot.stats.attack == 10 and snapshot.equipment.is_empty(), "private exact inventory after moves")
		check(snapshot.items.all(func(i: Dictionary) -> bool: return i.location == "bag" and i.bag_position >= 0), "RPC equipment cycle persisted")
		check(server.runtime_attack(owner) == 10, "runtime attack reconciled")
		check(int(inventory_facts.get(owner, 0)) == 10, "nine original mutations plus one explicit unsent-intent retry publish facts; replays/no-ops/rejections do not")
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
	var context: Dictionary = world.inventory_endpoint.state.economic_context
	journal_directory = "res://.godot/verification/inventory-journal-network-" + str(context.authority_id) + "-" + str(context.character_id)
	_compose_web()
	register_ready.rpc_id(1)
	await wait_until(func() -> bool: return phase_name == "GO")
	var endpoint: InventoryEndpoint3D = world.inventory_endpoint
	var entry_projection := endpoint.state.duplicate(true)
	check(int(entry_projection.get("projection_version", 0)) > 0, "entry snapshot hydrates a versioned inventory/equipment projection")
	var item: Dictionary = endpoint.state.items[0].duplicate(true)
	var result: Dictionary = await lost_command("inventory.move_item", {"id":item.uid,"revision":item.revision,"x":0,"y":3,"page":0},true)
	check(result.ok, "web command waits for committed move RPC")
	check(endpoint.state.items.any(func(i: Dictionary) -> bool: return i.uid == item.uid and i.bag_position == 15 and i.revision == 1), "snapshot after move")
	var moved_projection := endpoint.state.duplicate(true)
	check(int(moved_projection.projection_version) > int(entry_projection.projection_version), "committed move advances projection version")
	var duplicate_notifications: Array[Dictionary] = []
	var observe_duplicate := func(snapshot: Dictionary) -> void: duplicate_notifications.append(snapshot)
	endpoint.state_changed.connect(observe_duplicate)
	endpoint.receive_inventory(entry_projection)
	endpoint.receive_inventory(moved_projection)
	endpoint.receive_inventory({"ok":true})
	endpoint.state_changed.disconnect(observe_duplicate)
	check(endpoint.state == moved_projection and duplicate_notifications.is_empty(), "older and duplicate full snapshots cannot undo a committed move")
	var unchanged: Array = endpoint.state.items.duplicate(true)
	result = await command("inventory.move_item", {"id":item.uid,"revision":1,"x":0,"y":3,"page":0})
	check(result.ok and endpoint.state.items == unchanged, "same-cell Web move succeeds without changing revision")
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
	result = await lost_command("item.activate", {"id":item.uid,"revision":current.revision},false)
	check(result.ok and endpoint.state.equipment.get("weapon") == item.uid, "Web activation commits and publishes equipment")
	check(not endpoint.state.items.any(func(i: Dictionary) -> bool: return i.has("primary_action")), "action stays outside presentation snapshots")
	current = endpoint.state.items.filter(func(i: Dictionary) -> bool: return i.uid == item.uid)[0]
	check(current.location == "equipment", "equipped item leaves bag")
	var equipped_projection := endpoint.state.duplicate(true)
	unchanged = endpoint.state.items.duplicate(true)
	result = await lost_command("equipment.equip", {"id":item.uid,"revision":current.revision},false)
	check(result.ok and endpoint.state.items == unchanged and endpoint.state.stats.attack > 10, "repeat Web equip preserves equipment and runtime-derived stats")
	result = await command("equipment.unequip", {"id":item.uid,"revision":current.revision - 1})
	check(not result.ok and result.error == "stale", "Web unequip rejects stale revision")
	result = await command("equipment.unequip", {"id":item.uid,"revision":current.revision})
	check(result.ok and not endpoint.state.equipment.has("weapon"), "Web unequip commits and clears slot")
	var unequipped_projection := endpoint.state.duplicate(true)
	endpoint.receive_inventory(equipped_projection)
	endpoint.receive_weapon(world.local_peer, str(item.definition_id), int(equipped_projection.projection_version))
	check(endpoint.state == unequipped_projection and endpoint.public_weapons.get(world.local_peer) == "", "delayed equipment snapshot and public weapon cannot restore an unequipped sword")
	check(endpoint.state.items.any(func(i: Dictionary) -> bool: return i.uid == item.uid and i.location == "bag"), "unequip returns to free bag cells")
	current = endpoint.state.items.filter(func(i: Dictionary) -> bool: return i.uid == item.uid)[0]
	result = await lost_command("equipment.equip", {"id":item.uid,"revision":current.revision},false)
	check(result.ok and endpoint.state.equipment.get("weapon") == item.uid, "explicit equip still commits")
	current = endpoint.state.items.filter(func(i: Dictionary) -> bool: return i.uid == item.uid)[0]
	result = await lost_command("equipment.unequip", {"id":item.uid,"revision":current.revision,"x":2,"y":3,"page":1},true)
	check(result.ok and endpoint.state.stats.attack == 10, "exact unequip restores runtime stats")
	check(endpoint.state.items.any(func(i: Dictionary) -> bool: return i.uid == item.uid and i.bag_position == 62 and i.revision == current.revision + 1), "Web exact unequip publishes selected cell and page")
	# A browser transport reload must replay the current accepted domain state,
	# without requiring another mutation or accepting an old network snapshot.
	var snapshot_count := web_snapshots.size()
	web.bridge.reset_transport()
	web.bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
	check(web_snapshots.size() == snapshot_count + 1 and web_snapshots[-1].equipment.items.is_empty() and web_snapshots[-1].inventory.items.any(func(i: Dictionary) -> bool: return i.id == item.uid and int(i.revision) == int(current.revision) + 1), "ui.ready after reload restores the latest accepted inventory/equipment projection")
	web.storage_opened = true
	current = endpoint.state.items.filter(func(i: Dictionary) -> bool: return i.uid == item.uid)[0]
	var transfer_payload: Dictionary = {"id":item.uid,"revision":current.revision,"from":"inventory","to":"storage","x":14,"y":0,"page":1,"quick":false}
	result = await command("storage.transfer",transfer_payload)
	check(result.ok and endpoint.state.storage.items.size()==1,"Web deposit commits and publishes Storage")
	check(not endpoint.state.items.any(func(i: Dictionary) -> bool: return i.uid==item.uid),"deposit removes Inventory item")
	var stored_before: Array = endpoint.state.storage.items.duplicate(true)
	var stored_revision: int = current.revision + 1
	transfer_payload.merge({"from":"storage","revision":stored_revision}, true)
	result = await command("storage.transfer", transfer_payload)
	check(result.ok and endpoint.state.storage.items == stored_before, "same-cell Storage success resynchronizes without another revision or mutation fact")
	transfer_payload.merge({"from":"storage","to":"inventory","quick":true,"revision":current.revision+1},true)
	transfer_payload.x=0
	transfer_payload.page=0
	result = await command("storage.transfer",transfer_payload)
	check(result.ok and endpoint.state.storage.items.is_empty(),"Web quick withdrawal clears Storage")
	check(endpoint.state.items.any(func(i: Dictionary) -> bool: return i.uid==item.uid and i.revision==current.revision+2),"withdrawal publishes revised Inventory")
	await absent_intent_recovery()
	_cleanup_journal()
	if not failed: print("WEB_INVENTORY_CLIENT_OK: ", client_number)
	finished.rpc_id(1)
	await get_tree().create_timer(0.4).timeout
	get_tree().quit(1 if failed else 0)

func _compose_web() -> void:
	web = CoreUiController.new()
	web.host = HeadlessUiHost.new()
	world.add_child(web)
	web.items.journal.directory = journal_directory
	web.storage.journal.directory = journal_directory+"-storage"
	web.setup(world)
	web.bridge.outgoing.connect(func(json: String) -> void:
		var message: Dictionary = JSON.parse_string(json)
		if message.type == "command.result" and str(message.id).begins_with("fixture-"): web_results[str(message.id)] = message.payload
		if message.type == "ui.snapshot": web_snapshots.append(message.payload))
	web.bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')

func lost_command(type: String, payload: Dictionary, restart: bool) -> Dictionary:
	var endpoint := world.inventory_endpoint
	endpoint.operation_finished.disconnect(web.session.finish)
	var result := await command(type,payload)
	endpoint.operation_finished.connect(web.session.finish)
	check(not result.ok and result.error == "inventory_pending","lost "+type+" response retains original intent")
	var loaded: Dictionary = web.items.journal.load_pending()
	check(loaded.ok and not loaded.entry.is_empty(),"pending intent is on disk before teardown")
	var changed := payload.duplicate()
	changed.revision = int(changed.revision)+1
	var action: String = "move" if type == "inventory.move_item" else type.get_slice(".",1)
	check((await web.items._submit(changed,action)).error == "inventory_pending","changed payload cannot replace unresolved "+type)
	var state := endpoint.state.duplicate(true)
	if restart:
		var context: Dictionary = state.economic_context
		var output: Array = []
		var status := OS.execute(OS.get_executable_path(),["--headless","--path",ProjectSettings.globalize_path("res://"),"--mode=client","res://tests/web_inventory.tscn","--inventory-journal-probe",journal_directory,str(context.authority_id),str(context.account_id),str(context.character_id),loaded.entry.id],output)
		check(status == 0 and str(output).contains("INVENTORY_JOURNAL_PROCESS_OK"),"independent process restores original Inventory ID/action")
		web._stop("teardown")
		web.queue_free()
		await get_tree().process_frame
		_compose_web()
		check(web_snapshots[-1].inventory.get("recoveryPending",false),"ui.ready exposes journal recovery before lookup finishes")
		await wait_until(func() -> bool: return web.items.journal.load_pending().entry.is_empty())
		result = {"ok":true}
	else:
		web.bridge.reset_transport()
		web.bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
		check(web_snapshots[-1].inventory.get("recoveryPending",false),"reload exposes explicit Inventory retry")
		result = await command("inventory.retry",{})
	check(result.ok and endpoint.state.items == state.items and endpoint.state.equipment == state.equipment and endpoint.state.stats == state.stats,"recovery confirms current state without applying "+type+" twice")
	check(web.items.journal.load_pending().entry.is_empty(),"confirmation clears only resolved journal entry")
	await get_tree().create_timer(0.12).timeout
	return result

func absent_intent_recovery() -> void:
	var endpoint := world.inventory_endpoint
	var current: Dictionary = endpoint.state.items[0]
	var intent := {"action":"move","item":{"id":current.uid,"revision":current.revision,"x":4,"y":3,"page":2}}
	var operation_id := "inventory-" + Crypto.new().generate_random_bytes(16).hex_encode()
	check(web.items.journal.save_pending(operation_id,intent),"seed crash-before-send intention")
	var before := endpoint.state.duplicate(true)
	web._stop("teardown")
	web.queue_free()
	await get_tree().process_frame
	var results: Array[Dictionary] = []
	var observe := func(_id: String,result: Dictionary) -> void: results.append(result)
	endpoint.operation_finished.connect(observe)
	_compose_web()
	await wait_until(func() -> bool: return not results.is_empty())
	await get_tree().create_timer(0.25).timeout
	check(results.size() == 1 and results[0].get("error", "") == "unknown_command" and web.items.journal.load_pending().entry.get("id", "") == operation_id,"restart performs one lookup and never auto-executes absent intent")
	check(endpoint.state.items == before.items and endpoint.state.equipment == before.equipment,"absent discovery leaves current placement untouched")
	endpoint.operation_finished.disconnect(observe)
	var result := await command("inventory.retry",{})
	var position := 2 * InventoryGrid.PAGE_CELLS + 3 * InventoryGrid.COLUMNS + 4
	check(result.ok and endpoint.state.items.any(func(item: Dictionary) -> bool: return item.uid == current.uid and item.revision == current.revision+1 and item.bag_position == position),"explicit unknown-receipt retry executes original saved action exactly once")
	check(web.items.journal.load_pending().entry.is_empty(),"confirmed first execution clears saved intent")
	check((await command("inventory.retry",{})).error == "no_pending_inventory","resolved intent cannot execute again via Retry")

func _cleanup_journal() -> void:
	var context: Dictionary = world.inventory_endpoint.state.economic_context
	DirAccess.remove_absolute(ProjectSettings.globalize_path(journal_directory).path_join(("%s:%d:%d" % [context.authority_id,context.account_id,context.character_id]).sha256_text()))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(journal_directory))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(journal_directory+"-storage").path_join(("%s:%d:%d" % [context.authority_id,context.account_id,context.character_id]).sha256_text()))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(journal_directory+"-storage"))
