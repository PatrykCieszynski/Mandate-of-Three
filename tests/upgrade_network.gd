extends "res://tests/pve_network.gd"
var listening: bool = false
var committed_inventory_changes: int = 0
var committed_wallet_changes: int = 0
var inventory_notifications: int = 0
var wallet_notifications: int = 0
var selection_counts: Vector2i
const NPC_ID: String = "spike-blacksmith-01"
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
			world.process_mode = Node.PROCESS_MODE_DISABLED
			peer.close()
			get_tree().quit()

func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size() == 2 and ready_peers.size() == 2)
	for dog: SpikeMob3D in world.mob_system.mobs.values(): dog.ai_enabled = false
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
	var inventory: SpikeInventory3D = world.inventory_endpoint
	var currency: SpikeCurrency3D = world.currency_endpoint
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
	check(replies[hero].ok and replies[hero].level==1 and replies[hero].balance==1100,"successful RPC refreshes item and wallet")
	before = items.inventory(player.player_id)
	var upgraded: Dictionary = {}
	for item: Dictionary in before.items:
		if item.uid == drop_uid: upgraded = item
	check(not upgraded.is_empty() and replies[hero].inventoryItem == upgraded,"client receives the committed upgraded item, revision and stats in Inventory")
	await get_tree().create_timer(0.15).timeout
	set_phase("STALE_SELECT",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(not replies[hero].ok and replies[hero].error == "stale" and replies[hero].inventoryUpdates == 1 and replies[hero].walletUpdates == 0,"stale selection repairs Inventory without wallet refresh")
	set_phase("REPLAY",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(not replies[hero].ok and replies[hero].error=="stale" and items.inventory(player.player_id)==before and replies[hero].inventoryItem==upgraded and replies[hero].balance==1100,"stale replay leaves item, client Inventory and wallet unchanged")
	world.characters[hero].position = Vector3(12,0,12)
	await get_tree().create_timer(0.15).timeout
	set_phase("RANGE",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(not replies[hero].ok and replies[hero].error in ["out_of_range","no_interaction"] and items.inventory(player.player_id)==before,"execution reauthorizes range")
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
		world.upgrade_endpoint.operation_finished.connect(func(_id: String,result: Dictionary) -> void:
			var reply: Dictionary = result.duplicate(true)
			var quote: Dictionary = world.upgrade_endpoint.state
			reply["inventoryItem"] = {}
			for item: Dictionary in world.inventory_endpoint.state.get("items",[]):
				if item.uid == drop_uid: reply["inventoryItem"] = item.duplicate(true)
			reply.merge({"itemName":quote.get("itemName",""),"inventoryUpdates":inventory_notifications - selection_counts.x,"walletUpdates":wallet_notifications - selection_counts.y,"active":quote.active,"candidate":quote.get("candidate",{}).get("id",""),"level":quote.get("candidate",{}).get("level",-1),"balance":world.currency_endpoint.state.get("balance",-1)})
			report.rpc_id(1,reply))
		register_ready.rpc_id(1)
	if phase_name in ["WAIT","DONE"] or attempted: return
	attempted = true
	match phase_name:
		"INTERACT": world.npc_endpoint.request_interaction.rpc_id(1,"interact",NPC_ID,"","interact")
		"SERVICE": world.npc_endpoint.request_interaction.rpc_id(1,"select",NPC_ID,"upgrade","service")
		"CANDIDATE", "STALE_SELECT":
			selection_counts = Vector2i(inventory_notifications,wallet_notifications)
			world.upgrade_endpoint.request_upgrade.rpc_id(1,"select",NPC_ID,"upgrade",drop_uid,0,"candidate")
		_: world.upgrade_endpoint.request_upgrade.rpc_id(1,"upgrade",NPC_ID,"upgrade",drop_uid,1 if phase_name=="RANGE" else 0,"upgrade")
