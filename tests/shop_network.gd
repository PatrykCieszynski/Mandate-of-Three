extends "res://tests/pve_network.gd"
## Production Shop RPC on an isolated two-client world, never actual accounts.
var listening: bool = false
var shop_adapter := ShopUiAdapter.new()
var shop_session := UiCommandSession.new()
var shop_bridge: WebUiBridge
var committed_inventory_changes: int = 0
var committed_wallet_changes: int = 0

class CountingItemStore extends ItemStoreSqlite:
	var inventory_reads: int = 0
	var fail_inventory_reads: bool = false
	func inventory(owner_id: int) -> Dictionary:
		inventory_reads += 1
		if fail_inventory_reads: return {"ok":false,"error":"storage"}
		return super.inventory(owner_id)

@rpc("authority", "call_remote", "reliable", 0)
func phase(command: String, uid: String) -> void:
	if GameMode.is_world_server(): return
	phase_name = command
	drop_uid = uid
	attempted = false
	if command == "DONE":
		check(not world.shop_endpoint.state.active and not world.npc_endpoint.state.active, "shop and NPC context closed")
		if not failed:
			print("SHOP_CLIENT_OK: ", client_number, " private shop, wallet, inventory and close")
			finished.rpc_id(1)
			await get_tree().create_timer(0.3).timeout
			world.process_mode = Node.PROCESS_MODE_DISABLED
			peer.close()
			get_tree().quit()

func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size()==2 and ready_peers.size()==2)
	for dog: MobActor3D in world.mob_system.mobs.values(): dog.ai_enabled=false
	var hero: int = world.characters.keys()[0]
	var other: int = world.characters.keys()[1]
	var npc: NeutralNpc3D = world.npc_endpoint.actors["spike-blacksmith-01"]
	var owner: int = server.connected_players[hero].player_id
	var inventory: InventoryEndpoint3D = world.inventory_endpoint
	var currency: CurrencyEndpoint3D = world.currency_endpoint
	var counting := CountingItemStore.new(db)
	server.database.item_store = counting
	# Narrow A1 regression probe: publication used to own authoritative cache
	# refresh. A client snapshot alone cannot detect that coupling or SQL reads.
	server.runtime_equipment.erase(owner)
	inventory._send_state(hero)
	check(not server.runtime_equipment.has(owner) and counting.inventory_reads==0,"publication has no authoritative cache/Inventory-read side effects")
	inventory.resynchronize(hero)
	check(server.runtime_equipment.has(owner),"explicit refresh restores authoritative cache")
	counting.fail_inventory_reads = true
	inventory.resynchronize(hero)
	check(not server.runtime_equipment.has(owner) and server.runtime_attack(owner)==-1,"failed refresh invalidates combat cache rather than retaining stale stats")
	counting.fail_inventory_reads = false
	inventory.resynchronize(hero)
	check(server.runtime_equipment.has(owner),"explicit resynchronization restores state after read failure")
	# Public fact semantics: commits emit changes; rejection/repair does not.
	inventory.inventory_changed.connect(func(_owner_id: int) -> void: committed_inventory_changes += 1)
	currency.wallet_changed.connect(func(_owner_id: int) -> void: committed_wallet_changes += 1)
	drop_uid = npc.instance_id
	world.characters[hero].position=npc.position+Vector3(0,0,2)
	world.characters[other].position=Vector3(12,0,12)
	check(server.database.add_yang(owner,2500), "pending income fixture")
	for command: String in ["INTERACT","SELECT","OPEN"]:
		set_phase(command,hero)
		await wait_until(func() -> bool: return replies.has(hero))
		check(replies[hero].ok, "RPC "+command)
	check(replies[hero].shop_active and replies[hero].offer_price==1000, "authoritative Shop snapshot")
	check(not world.shop_endpoint.snapshot_for_peer(other).active, "other player receives no shop context")
	set_phase("FOREIGN",other)
	await wait_until(func() -> bool: return replies.has(other))
	check(not replies[other].ok and replies[other].error=="no_interaction", "other player cannot purchase")
	var before: Dictionary = server.database.item_store.inventory(owner)
	set_phase("BUY_EXACT",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(not replies[hero].ok and replies[hero].error == "purchase_pending" and replies[hero].has_purchase and replies[hero].wallet == 1500, "lost purchase response leaves a committed item and unresolved client intention")
	await get_tree().create_timer(0.12).timeout
	set_phase("RETRY_EXACT", hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok and replies[hero].has_purchase and replies[hero].wallet == 1500, "adapter retries the same purchase after lost response without a second charge")
	check(server.database.runtime_wallets[server.database.wallet_account_id(owner)].pending_currency_delta==0 and not server.database.dirty_wallet.has(server.database.wallet_account_id(owner)), "RPC commit clears pending income")
	await get_tree().create_timer(0.12).timeout
	set_phase("OCCUPIED",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(not replies[hero].ok and replies[hero].error=="occupied" and server.database.wallet_balance(owner)==1500, "occupied exact position cannot fall back or charge")
	await get_tree().create_timer(0.12).timeout
	set_phase("BUY_AUTO",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok and replies[hero].wallet==500, "automatic purchase publishes balance")
	var purchased: Dictionary = server.database.item_store.inventory(owner)
	check(purchased.items.size()==before.items.size()+2, "exactly two items created")
	await get_tree().create_timer(0.12).timeout
	set_phase("FUNDS",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(not replies[hero].ok and replies[hero].error=="funds" and server.database.item_store.inventory(owner)==purchased, "funds rejection leaves items intact")
	set_phase("BACK",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok and not replies[hero].shop_active and replies[hero].npc_active and replies[hero].selected=="", "clear service closes Shop but retains NPC context")
	await get_tree().create_timer(0.12).timeout
	set_phase("SELECT",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	set_phase("OPEN",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok and replies[hero].shop_active, "Shop can reopen from service menu")
	world.characters[hero].position=Vector3(12,0,12)
	await get_tree().create_timer(0.12).timeout
	set_phase("STALE",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(not replies[hero].ok and replies[hero].error in ["out_of_range","no_interaction"] and server.database.wallet_balance(owner)==500 and server.database.item_store.inventory(owner)==purchased, "stale range cannot spend/create")
	set_phase("CLOSE",hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(committed_inventory_changes==2 and committed_wallet_changes==2,"only the two committed purchases emit change facts; rejection emits none")
	set_phase("DONE")
	await wait_until(func() -> bool: return done_peers.size()==2)
	if not failed:
		print("SHOP_SERVER_OK: production RPC, pending income, exact/auto, private snapshots, ownership, rejection, back and range")
		world.process_mode=Node.PROCESS_MODE_DISABLED
		peer.close()
		db.close_db()
		get_tree().quit()

func _report_operation(_id: String, result: Dictionary) -> void:
	if phase_name in ["BUY_EXACT","RETRY_EXACT","BUY_AUTO"] and result.ok:
		var expected_balance: int = 1500 if phase_name in ["BUY_EXACT","RETRY_EXACT"] else 500
		await wait_until(func() -> bool: return world.currency_endpoint.state.get("balance",-1)==expected_balance)
	var shop_state: Dictionary = world.shop_endpoint.state
	var npc_state: Dictionary = world.npc_endpoint.state
	var has_purchase: bool = false
	for item: Dictionary in world.inventory_endpoint.state.get("items",[]):
		if item.location=="bag" and item.bag_position==10: has_purchase=true
	var reply: Dictionary = result.duplicate(true)
	reply.merge({"shop_active":shop_state.active, "npc_active":npc_state.active, "selected":npc_state.get("selectedServiceId",""), "wallet":world.currency_endpoint.state.get("balance",-1), "has_purchase":has_purchase, "offer_price":shop_state.get("offers",[{}])[0].get("price",-1)})
	report.rpc_id(1,reply)

func _process(delta: float) -> void:
	elapsed+=delta
	if elapsed>25:
		check(false,"Shop network timeout: "+phase_name)
		return
	if GameMode.is_world_server() or world==null or world.combat_endpoint.state.is_empty(): return
	if not listening:
		listening=true
		world.npc_endpoint.operation_finished.connect(_report_operation)
		world.shop_endpoint.operation_finished.connect(_report_operation)
		var dispatcher := UiCommandDispatcher.new()
		add_child(dispatcher)
		shop_bridge = WebUiBridge.new()
		add_child(shop_bridge)
		dispatcher.attach(shop_bridge)
		shop_adapter.attach(world.shop_endpoint, dispatcher, shop_session, get_tree())
		register_ready.rpc_id(1)
	if phase_name in ["WAIT","DONE"] or attempted: return
	attempted=true
	match phase_name:
		"INTERACT": world.npc_endpoint.request_interaction.rpc_id(1,"interact",drop_uid,"","shop-interact")
		"SELECT": world.npc_endpoint.request_interaction.rpc_id(1,"select",drop_uid,"weapon_shop","shop-select")
		"OPEN": world.shop_endpoint.request_shop.rpc_id(1,"open",drop_uid,"weapon_shop","",-1,"shop-open")
		"BUY_EXACT": _adapter_purchase(true)
		"RETRY_EXACT": _retry_from_web()
		"OCCUPIED": world.shop_endpoint.request_shop.rpc_id(1,"buy",drop_uid,"weapon_shop","iron_sword",10,"shop-exact", "occupied-intention")
		"BUY_AUTO": _adapter_purchase(false, false)
		"FUNDS","FOREIGN","STALE": world.shop_endpoint.request_shop.rpc_id(1,"buy",drop_uid,"weapon_shop","iron_sword",-1,"shop-auto", "npc-" + phase_name)
		"BACK": world.npc_endpoint.request_interaction.rpc_id(1,"clear_service","","","shop-back")
		"CLOSE": world.npc_endpoint.request_interaction.rpc_id(1,"close","","","shop-close")

# Exercise real busy RPC correlation with the first accepted response discarded.
# A new transport request must reuse the adapter's business intention on retry.
func _adapter_purchase(lose_response: bool, exact: bool = true) -> void:
	world.shop_endpoint.operation_finished.disconnect(_report_operation)
	if lose_response: world.shop_endpoint.operation_finished.disconnect(shop_session.finish)
	var payload := {"npc_instance_id":drop_uid,"service_id":"weapon_shop","offer_id":"iron_sword"}
	if exact: payload.merge({"x":0,"y":2,"page":0})
	var result := await shop_adapter._submit("buy", payload)
	if lose_response:
		world.shop_endpoint.operation_finished.connect(shop_session.finish)
		shop_session.cancel("ui_reload")
		var changed := payload.duplicate(true)
		changed.x = 1
		var blocked := await shop_adapter._submit("buy", changed)
		check(not blocked.ok and blocked.error == "purchase_pending", "uncertain purchase prevents another placement/intention until resolved")
	world.shop_endpoint.operation_finished.connect(_report_operation)
	await _report_operation("", result)

# Result recovery enters through the same explicit empty-payload Web command as
# the Retry button. The committed sword already occupies the requested cell.
func _retry_from_web() -> void:
	check(world.inventory_endpoint.state.items.any(func(item: Dictionary) -> bool: return item.location == "bag" and item.bag_position == 10), "retry target is occupied by the committed purchase")
	world.shop_endpoint.operation_finished.disconnect(_report_operation)
	var received := {}
	var listener := func(json: String) -> void:
		var message: Dictionary = JSON.parse_string(json)
		if message.type == "command.result" and message.id == "retry-from-web": received.result = message.payload
		if message.type == "ui.snapshot": received.pending_purchase = message.payload.shop.get("purchasePending", false)
	shop_bridge.outgoing.connect(listener)
	shop_bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
	check(received.get("pending_purchase", false), "ui.ready exposes unresolved purchase so Retry remains available after browser reload")
	shop_bridge.receive('{"v":1,"type":"shop.retry","id":"retry-from-web","payload":{}}')
	await wait_until(func() -> bool: return received.has("result"))
	shop_bridge.outgoing.disconnect(listener)
	world.shop_endpoint.operation_finished.connect(_report_operation)
	await _report_operation("", received.result)
