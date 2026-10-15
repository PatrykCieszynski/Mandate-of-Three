extends "res://tests/pve_network.gd"
var listening: bool = false
var adapter := UpgradeUiAdapter.new()
var session := UiCommandSession.new()
var bridge: WebUiBridge
var dispatcher: UiCommandDispatcher
var journal_directory := ""
var committed_inventory_changes: int = 0
var committed_wallet_changes: int = 0
var inventory_notifications: int = 0
var wallet_notifications: int = 0
var selection_counts: Vector2i
const NPC_ID: String = "spike-blacksmith-01"
func _ready() -> void:
	var args := OS.get_cmdline_args()
	var probe := args.find("--upgrade-journal-probe")
	if probe >= 0:
		var journal = preload("res://source/client/ui_web/local_economy_journal.gd").new("upgrade-",args[probe + 1])
		var loaded: Dictionary = journal.configure({"authority_id":args[probe + 2],"account_id":int(args[probe + 3]),"character_id":int(args[probe + 4])})
		if loaded.ok and loaded.entry.get("id", "") == args[probe + 5]:
			print("UPGRADE_JOURNAL_PROCESS_OK")
			get_tree().quit()
		else: get_tree().quit(1)
		return
	super._ready()

@rpc("authority", "call_remote", "reliable", 0)
func phase(command: String, uid: String) -> void:
	if GameMode.is_world_server(): return
	phase_name = command
	drop_uid = uid
	attempted = false
	if command == "DONE":
		if not failed:
			print("UPGRADE_CLIENT_OK: ",client_number," private quote, selection, upgrade and rejection snapshots")
			finished.rpc_id(1)
			await get_tree().create_timer(0.3).timeout
			_cleanup_journal()
			world.process_mode = Node.PROCESS_MODE_DISABLED
			peer.close()
			get_tree().quit()

func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size() == 2 and ready_peers.size() == 2)
	for dog: MobActor3D in world.mob_system.mobs.values(): dog.ai_enabled = false
	var hero: int = world.characters.keys()[0]
	var other: int = world.characters.keys()[1]
	var player: PlayerResource = server.connected_players[hero]
	var npc: NeutralNpc3D = world.npc_endpoint.actors[NPC_ID]
	world.characters[hero].position = npc.position + Vector3(0,0,2)
	world.characters[other].position = Vector3(12,0,12)
	var items: ItemStoreSqlite = server.database.item_store
	var initial: Dictionary = items.inventory(player.player_id)
	drop_uid = str(initial.items[0].uid)
	var ore: ItemInstance = ItemInstance.create(ItemDefinitions.UPGRADE_ORE,player.player_id,[])
	ore.amount = 2
	check(db.query("BEGIN IMMEDIATE;"),"begin material fixture")
	check(items.receive_item_in_transaction(ore).ok and db.query("COMMIT;"),"seed material")
	check(server.database.add_yang(player.player_id,2100),"pending income")
	world.inventory_endpoint.resynchronize(hero)
	var inventory: InventoryEndpoint3D = world.inventory_endpoint
	var currency: CurrencyEndpoint3D = world.currency_endpoint
	inventory.inventory_changed.connect(func(_owner_id: int) -> void: committed_inventory_changes += 1)
	currency.wallet_changed.connect(func(_owner_id: int) -> void: committed_wallet_changes += 1)
	set_phase("INTERACT",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok,"open NPC context")
	set_phase("SERVICE",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok and replies[hero].active,"selected Upgrade publishes recipe")
	var before: Dictionary = items.inventory(player.player_id)
	set_phase("CANDIDATE",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok and replies[hero].candidate == drop_uid and items.inventory(player.player_id)==before,"selection leaves authoritative Inventory untouched")
	check(replies[hero].inventoryUpdates == 0 and replies[hero].walletUpdates == 0,"successful selection publishes only Upgrade")
	check(replies[hero].itemName == ItemDefinitions.IRON_SWORD.item_name,"quote publishes the content item name")
	set_phase("DENIED",other)
	await wait_until(func() -> bool: return replies.has(other))
	check(not replies[other].ok and not replies[other].active and items.inventory(player.player_id)==before,"second client cannot upgrade another player's item")
	set_phase("UPGRADE",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(not replies[hero].ok and replies[hero].error=="upgrade_pending" and replies[hero].level==1 and replies[hero].balance==1100,"lost response retains pending intention while committed item/wallet refresh")
	before = items.inventory(player.player_id)
	var upgraded: Dictionary = {}
	for item: Dictionary in before.items:
		if item.uid == drop_uid: upgraded = item
	check(not upgraded.is_empty() and replies[hero].inventoryItem == upgraded,"client receives the committed upgraded item, revision and stats in Inventory")
	await get_tree().create_timer(0.15).timeout
	set_phase("STALE_SELECT",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(not replies[hero].ok and replies[hero].error == "stale" and replies[hero].inventoryUpdates == 1 and replies[hero].walletUpdates == 0,"stale selection repairs Inventory without wallet refresh")
	set_phase("CLOSE",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	world.characters[hero].position = Vector3(12,0,12)
	await get_tree().create_timer(0.15).timeout
	set_phase("RESTORE",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok and items.inventory(player.player_id)==before and replies[hero].inventoryItem==upgraded and replies[hero].balance==1100,"fresh adapter confirms journal receipt outside NPC range without second consumption")
	set_phase("RANGE",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(not replies[hero].ok and replies[hero].error in ["out_of_range","no_interaction"] and items.inventory(player.player_id)==before,"execution reauthorizes range")
	await get_tree().create_timer(0.15).timeout
	set_phase("RESTORE_ABSENT",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok and items.inventory(player.player_id)==before,"absent receipt discovery never upgrades")
	set_phase("REPLAY",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(not replies[hero].ok and replies[hero].error == "upgrade_pending", "explicit retry with absent receipt must retain intent when NPC authorization fails")
	world.characters[hero].position = npc.position + Vector3(0,0,2)
	for command: String in ["INTERACT","SERVICE"]:
		set_phase(command,hero)
		await wait_until(func() -> bool: return replies.has(hero))
		check(replies[hero].ok,"reopen original Upgrade service")
	await get_tree().create_timer(0.15).timeout
	set_phase("RETRY_STALE",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(not replies[hero].ok and replies[hero].error == "stale" and items.inventory(player.player_id)==before,"explicit absent-receipt retry uses original revision through normal authorization")
	check(committed_inventory_changes==1 and committed_wallet_changes==1,"selection, stale/replay and range repair never emit committed-change facts")
	set_phase("DONE")
	await wait_until(func() -> bool: return done_peers.size() == 2)
	if not failed:
		print("UPGRADE_SERVER_OK: two-client RPC selection, atomic commit, private state, replay and range rejection")
		world.process_mode = Node.PROCESS_MODE_DISABLED
		peer.close()
		db.close_db()
		get_tree().quit()

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed > 25:
		check(false,"Upgrade timeout: " + phase_name)
		return
	if GameMode.is_world_server() or world == null or world.combat_endpoint.state.is_empty(): return
	if not listening:
		listening = true
		world.inventory_endpoint.state_changed.connect(func(_state: Dictionary) -> void: inventory_notifications += 1)
		world.currency_endpoint.state_changed.connect(func(_state: Dictionary) -> void: wallet_notifications += 1)
		world.npc_endpoint.operation_finished.connect(func(_id: String,result: Dictionary) -> void:
			var reply: Dictionary = result.duplicate(true)
			reply["active"] = world.upgrade_endpoint.state.active
			report.rpc_id(1,reply))
		world.upgrade_endpoint.operation_finished.connect(_report_upgrade)
		var context: Dictionary = world.inventory_endpoint.state.economic_context
		journal_directory = "res://.godot/verification/upgrade-journal-network-" + str(context.authority_id) + "-" + str(context.character_id)
		_attach_adapter()
		register_ready.rpc_id(1)
	if phase_name in ["WAIT","DONE"] or attempted: return
	attempted = true
	match phase_name:
		"INTERACT": world.npc_endpoint.request_interaction.rpc_id(1,"interact",NPC_ID,"","interact")
		"SERVICE": world.npc_endpoint.request_interaction.rpc_id(1,"select",NPC_ID,"upgrade","service")
		"CANDIDATE", "STALE_SELECT":
			selection_counts = Vector2i(inventory_notifications,wallet_notifications)
			world.upgrade_endpoint.request_upgrade.rpc_id(1,"select",NPC_ID,"upgrade",drop_uid,0,"candidate")
		"UPGRADE": _lost_upgrade()
		"REPLAY", "RETRY_STALE": _retry_from_web()
		"RESTORE": _restore_upgrade()
		"RESTORE_ABSENT": _restore_absent_upgrade()
		"CLOSE": world.npc_endpoint.request_interaction.rpc_id(1,"close","","","close")
		_: world.upgrade_endpoint.request_upgrade.rpc_id(1,"upgrade",NPC_ID,"upgrade",drop_uid,1 if phase_name=="RANGE" else 0,"upgrade","upgrade-"+phase_name)

func _report_upgrade(_id: String, result: Dictionary) -> void:
	var reply: Dictionary = result.duplicate(true)
	var quote: Dictionary = world.upgrade_endpoint.state
	reply["inventoryItem"] = {}
	for item: Dictionary in world.inventory_endpoint.state.get("items",[]):
		if item.uid == drop_uid: reply["inventoryItem"] = item.duplicate(true)
	reply.merge({"itemName":quote.get("itemName",""),"inventoryUpdates":inventory_notifications - selection_counts.x,"walletUpdates":wallet_notifications - selection_counts.y,"active":quote.active,"candidate":quote.get("candidate",{}).get("id",""),"level":quote.get("candidate",{}).get("level",-1),"balance":world.currency_endpoint.state.get("balance",-1)})
	report.rpc_id(1,reply)

func _lost_upgrade() -> void:
	world.upgrade_endpoint.operation_finished.disconnect(_report_upgrade)
	world.upgrade_endpoint.operation_finished.disconnect(session.finish)
	var payload := {"npc_instance_id":NPC_ID,"service_id":"upgrade","id":drop_uid,"revision":0}
	var result := await adapter._submit("upgrade",payload)
	world.upgrade_endpoint.operation_finished.connect(session.finish)
	session.cancel("ui_reload")
	var changed := payload.duplicate()
	changed.revision = 1
	check((await adapter._submit("upgrade",changed)).error == "upgrade_pending", "new revision cannot replace an unresolved upgrade")
	world.upgrade_endpoint.operation_finished.connect(_report_upgrade)
	_report_upgrade("",result)

func _retry_from_web() -> void:
	world.upgrade_endpoint.operation_finished.disconnect(_report_upgrade)
	var received := {}
	var listener := func(json: String) -> void:
		var message: Dictionary = JSON.parse_string(json)
		if message.type == "ui.snapshot": received.pending = message.payload.upgrade.get("upgradePending",false)
		if message.type == "command.result" and message.id == "upgrade-retry": received.result = message.payload
	bridge.outgoing.connect(listener)
	bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
	check(received.get("pending",false), "ui.ready retains unresolved upgrade after +1 state arrived")
	bridge.receive('{"v":1,"type":"upgrade.retry","id":"upgrade-retry","payload":{}}')
	await wait_until(func() -> bool: return received.has("result"))
	bridge.outgoing.disconnect(listener)
	world.upgrade_endpoint.operation_finished.connect(_report_upgrade)
	_report_upgrade("",received.result)

func _attach_adapter() -> void:
	dispatcher = UiCommandDispatcher.new()
	add_child(dispatcher)
	bridge = WebUiBridge.new()
	add_child(bridge)
	dispatcher.attach(bridge)
	adapter.journal.directory = journal_directory
	adapter.attach(world.upgrade_endpoint,dispatcher,session,get_tree())
	world.inventory_endpoint.state_changed.connect(adapter.accept_context)
	adapter.accept_context(world.inventory_endpoint.state)

func _recreate_adapter() -> void:
	world.inventory_endpoint.state_changed.disconnect(adapter.accept_context)
	adapter.dispose()
	session.close("disconnected")
	dispatcher.queue_free()
	bridge.queue_free()
	adapter = UpgradeUiAdapter.new()
	session = UiCommandSession.new()
	_attach_adapter()

func _restore_upgrade() -> void:
	world.upgrade_endpoint.operation_finished.disconnect(_report_upgrade)
	var context: Dictionary = world.inventory_endpoint.state.economic_context
	var loaded: Dictionary = adapter.journal.load_pending()
	check(loaded.ok and not loaded.entry.is_empty(),"uncertain Upgrade persisted before teardown")
	var output: Array = []
	var status := OS.execute(OS.get_executable_path(),["--headless","--path",ProjectSettings.globalize_path("res://"),"--mode=client","res://tests/upgrade_network.tscn","--upgrade-journal-probe",journal_directory,str(context.authority_id),str(context.account_id),str(context.character_id),loaded.entry.id],output)
	check(status == 0 and str(output).contains("UPGRADE_JOURNAL_PROCESS_OK"),"independent process restores Upgrade ID")
	var received := {}
	var listener := func(_id: String,result: Dictionary) -> void: received.result = result
	world.upgrade_endpoint.operation_finished.connect(listener)
	_recreate_adapter()
	await wait_until(func() -> bool: return received.has("result"))
	await wait_until(func() -> bool: return adapter.journal.load_pending().entry.is_empty())
	check((await adapter.retry_upgrade()).error == "no_pending_upgrade","successful discovery clears only the confirmed intention")
	world.upgrade_endpoint.operation_finished.disconnect(listener)
	world.upgrade_endpoint.operation_finished.connect(_report_upgrade)
	_report_upgrade("",received.result)

func _restore_absent_upgrade() -> void:
	world.upgrade_endpoint.operation_finished.disconnect(_report_upgrade)
	var intention := "upgrade-" + Crypto.new().generate_random_bytes(16).hex_encode()
	check(adapter.journal.save_pending(intention,{"npc_instance_id":NPC_ID,"service_id":"upgrade","id":drop_uid,"revision":0}),"seed owned crash-before-RPC intention")
	var results: Array[Dictionary] = []
	var listener := func(_id: String,result: Dictionary) -> void: results.append(result)
	world.upgrade_endpoint.operation_finished.connect(listener)
	_recreate_adapter()
	await wait_until(func() -> bool: return not results.is_empty())
	await get_tree().create_timer(0.25).timeout
	check(results.size() == 1 and results[0].get("error", "") == "unknown_command" and adapter.journal.load_pending().entry.get("id", "") == intention,"automatic restore reads once, retains absent receipt and never executes Upgrade")
	world.upgrade_endpoint.operation_finished.disconnect(listener)
	world.upgrade_endpoint.operation_finished.connect(_report_upgrade)
	_report_upgrade("",{"ok":true})

func _cleanup_journal() -> void:
	if journal_directory.is_empty(): return
	check(adapter.journal.load_pending().entry.is_empty(),"no unresolved fixture intent after definitive stale rejection")
	var context: Dictionary = world.inventory_endpoint.state.economic_context
	DirAccess.remove_absolute(ProjectSettings.globalize_path(journal_directory).path_join(("%s:%d:%d" % [context.authority_id,context.account_id,context.character_id]).sha256_text()))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(journal_directory))
