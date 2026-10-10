extends "res://tests/pve_network.gd"
var listening: bool = false
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
	for dog: SpikeWildDog3D in world.combat_endpoint.dogs.values(): dog.ai_enabled = false
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
	world.inventory_endpoint._send_state(hero)
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
	set_phase("DENIED",other)
	await wait_until(func() -> bool: return replies.has(other))
	check(not replies[other].ok and not replies[other].active and items.inventory(player.player_id)==before,"second client cannot upgrade another player's item")
	set_phase("UPGRADE",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok and replies[hero].level==1 and replies[hero].balance==1100,"successful RPC refreshes item and wallet")
	check(server.runtime_equipment.has(player.player_id),"committed Inventory refreshes runtime equipment cache")
	before = items.inventory(player.player_id)
	await get_tree().create_timer(0.15).timeout
	set_phase("REPLAY",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(not replies[hero].ok and replies[hero].error=="stale" and items.inventory(player.player_id)==before,"stale replay is atomic")
	world.characters[hero].position = Vector3(12,0,12)
	await get_tree().create_timer(0.15).timeout
	set_phase("RANGE",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(not replies[hero].ok and replies[hero].error in ["out_of_range","no_interaction"] and items.inventory(player.player_id)==before,"execution reauthorizes range")
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
		world.npc_endpoint.operation_finished.connect(func(_id: String,result: Dictionary) -> void:
			var reply: Dictionary = result.duplicate(true)
			reply["active"] = world.upgrade_endpoint.state.active
			report.rpc_id(1,reply))
		world.upgrade_endpoint.operation_finished.connect(func(_id: String,result: Dictionary) -> void:
			var reply: Dictionary = result.duplicate(true)
			var quote: Dictionary = world.upgrade_endpoint.state
			reply.merge({"active":quote.active,"candidate":quote.get("candidate",{}).get("id",""),"level":quote.get("candidate",{}).get("level",-1),"balance":world.currency_endpoint.state.get("balance",-1)})
			report.rpc_id(1,reply))
		register_ready.rpc_id(1)
	if phase_name in ["WAIT","DONE"] or attempted: return
	attempted = true
	match phase_name:
		"INTERACT": world.npc_endpoint.request_interaction.rpc_id(1,"interact",NPC_ID,"","interact")
		"SERVICE": world.npc_endpoint.request_interaction.rpc_id(1,"select",NPC_ID,"upgrade","service")
		"CANDIDATE": world.upgrade_endpoint.request_upgrade.rpc_id(1,"select",NPC_ID,"upgrade",drop_uid,0,"candidate")
		_: world.upgrade_endpoint.request_upgrade.rpc_id(1,"upgrade",NPC_ID,"upgrade",drop_uid,1 if phase_name=="RANGE" else 0,"upgrade")
