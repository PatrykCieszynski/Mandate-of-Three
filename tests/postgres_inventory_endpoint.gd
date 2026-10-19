extends "res://tests/postgres_inventory_session_bridge.gd"
## Actual client processes use the production endpoint, bridge, journal and item
## adapter. Master/World run on native isolated sockets in this server fixture;
## Gateway credentials and map/actor construction remain controlled.
class CurrencyMap extends GameWorld3D:
	func _ready() -> void:
		combat_endpoint=CombatEndpoint3D.new()
		combat_endpoint._world=self
		currency_endpoint=CurrencyEndpoint3D.new()
		currency_endpoint.name="Currency"
		currency_endpoint.services=services
		add_child(currency_endpoint)
		inventory_endpoint=get_parent().endpoint
		npc_endpoint=NpcInteraction3D.new()
		npc_endpoint.name="Npc"
		npc_endpoint.services=services
		add_child(npc_endpoint)
		shop_endpoint=Shop3D.new()
		shop_endpoint.name="Shop"
		shop_endpoint.services=services
		add_child(shop_endpoint)
		upgrade_endpoint=Upgrade3D.new()
		upgrade_endpoint.name="Upgrade"
		upgrade_endpoint.services=services
		add_child(upgrade_endpoint)
		get_parent().upgrade_endpoint=upgrade_endpoint
		if GameMode.is_world_server():
			var blacksmith:=NeutralNpc3D.new()
			blacksmith.instance_id="fixture-blacksmith"
			blacksmith.definition=NpcDefinitions.get_definition(&"blacksmith")
			blacksmith.position=Vector3(0,0,1)
			add_child(blacksmith)
			assert(npc_endpoint.register_actor(blacksmith))
	func _process(_delta: float) -> void: pass
	func _physics_process(_delta: float) -> void: pass
	func _exit_tree() -> void: combat_endpoint.free()
	func has_line_of_sight(_from: Vector3, _to: Vector3) -> bool: return true

class FixtureMap extends Node3D:
	var characters: Dictionary[int,PlayerActor3D]={}
	var upgrade_endpoint: Node
	var endpoint: InventoryEndpoint3D
	var reports: Dictionary={}
	var currency_map: CurrencyMap
	signal joined(peer: int)
	signal phase_received(phase: String, payload: Dictionary)
	func _ready() -> void:
		endpoint=InventoryEndpoint3D.new()
		endpoint.name="Inventory"
		endpoint.services=MandateWorldServices.new()
		add_child(endpoint)
		currency_map=CurrencyMap.new()
		currency_map.name="CurrencyMap"
		add_child(currency_map)
	@rpc("any_peer","call_remote","reliable",1)
	func join() -> void:
		if GameMode.is_world_server(): joined.emit(multiplayer.get_remote_sender_id())
	@rpc("authority","call_remote","reliable",1)
	func phase(label: String, payload: Dictionary) -> void:
		if GameMode.is_client(): phase_received.emit(label,payload)
	@rpc("any_peer","call_remote","reliable",1)
	func report(label: String, result: Dictionary) -> void:
		if GameMode.is_world_server(): reports[label]={"peer":multiplayer.get_remote_sender_id(),"result":result}

var map: FixtureMap
var wire: WireClient
var adapter: ItemUiAdapter
var session: UiCommandSession
var dispatcher: UiCommandDispatcher
var bridge: WebUiBridge
var ui_results: Dictionary={}
var ui_snapshots: Array[Dictionary]=[]
var client_processes: Array[int]=[]
var fixture_dir: String
var facts: int=0
var wallet_execution: RefCounted
var npc_execution: RefCounted
var npc_adapter: NpcUiAdapter
var shop_adapter: ShopUiAdapter
var upgrade_adapter: UpgradeUiAdapter

func _ready() -> void:
	get_tree().create_timer(45).timeout.connect(func() -> void: get_tree().quit(1))
	if GameMode.is_client(): run_client.call_deferred()
	else: super._ready()

func wait_for(predicate: Callable) -> void:
	var deadline: int=Time.get_ticks_msec()+15000
	while not predicate.call() and Time.get_ticks_msec()<deadline: await get_tree().process_frame
	assert(predicate.call(),"bounded endpoint/client fixture wait")

func add_map(parent: Node) -> FixtureMap:
	var result:=FixtureMap.new()
	result.name="Map"
	parent.add_child(result)
	return result

func start_client(request: int, username: String, role: String) -> void:
	issue(request,username,character if username=="alpha" else extra_characters[username])
	await wait_for(func() -> bool: return master.responses.has(request))
	assert(master.responses[request].has("auth-token"))
	var arguments: Array[String]=["--headless","--path",ProjectSettings.globalize_path("res://"),"--mode=client","res://tests/postgres_inventory_endpoint.tscn","--fixture-token="+master.responses[request]["auth-token"],"--fixture-role="+role,"--fixture-dir="+ProjectSettings.globalize_path(fixture_dir),"--log-file",ProjectSettings.globalize_path(fixture_dir+"/client-"+role+".log")]
	var pid:=OS.create_process(OS.get_executable_path(),arguments,false)
	assert(pid>0)
	client_processes.append(pid)

func phase(peer: int, label: String, payload: Dictionary = {}) -> Dictionary:
	map.reports.erase(label)
	map.phase.rpc_id(peer,label,payload)
	await wait_for(func() -> bool: return map.reports.has(label))
	assert(map.reports[label].peer==peer)
	return map.reports[label].result

func run() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var connection: String=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	fixture_dir=OS.get_environment("MANDATE_PG_FIXTURE_DIR")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	sqlite.path=fixture_dir+"/identity.db"
	assert(sqlite.open_db())
	WorldSchema.ensure_schema(sqlite)
	database.db=sqlite
	database.store=WorldStoreSqlite.new(sqlite)
	assert(WalletStoreSqlite.migrate_accounts(sqlite,{}).ok)
	authentication.account_collection=AccountResourceCollection.new()
	for username: String in ["alpha","beta"]:
		var id: int=21 if username=="alpha" else 22
		assert(database.store.bind_account_identity(username,id,true))
		var owner: int=database.store.create_player_character(username,{"name":username,"skin":1})
		if username=="alpha": character=owner
		else: extra_characters[username]=owner
		assert(owner>0 and Wallet.new(pg).initialize_account(id).ok and Items.new(pg).bind_character(owner,id))
		var sword:=ItemInstance.create(ItemDefinitions.IRON_SWORD,owner,[])
		assert(pg.begin() and Items.new(pg).receive_item_in_transaction(sword,0).ok and pg.commit())
		var account:=AccountResource.new()
		account.id=id
		account.username=username
		authentication.account_collection.collection[username]=account
		authentication.active_accounts[username]=account
	assert(database.prepare_account_wallets({"alpha":21,"beta":22}).ok)
	master.authentication_manager=authentication
	master.name="Master"
	add_child(master)
	assert(master.create(BaseMultiplayerEndpoint.Role.SERVER,"127.0.0.1",18099)==OK)
	world.name="World"
	world.database=database
	world.world_manager=link
	add_child(world)
	assert(world.create(BaseMultiplayerEndpoint.Role.SERVER,"127.0.0.1",18098)==OK)
	WorldServer.curr=world
	link.name="ControlLink"
	link.database=database
	link.world_server=world
	link.token_received.connect(world.accept_master_handoff)
	add_child(link)
	assert(link.create(BaseMultiplayerEndpoint.Role.CLIENT,"127.0.0.1",18099)==OK)
	await wait_for(func() -> bool: return master.connected_worlds.size()==1)
	world_id=link.multiplayer_api.get_unique_id()
	control=Executor.new()
	execution=Executor.new()
	wallet_execution=Executor.new()
	npc_execution=Executor.new()
	assert(control.start(connection,2,2) and execution.start(connection,2,2) and wallet_execution.start(connection,2,2) and npc_execution.start(connection,2,2))
	while not control.is_ready() or not execution.is_ready() or not wallet_execution.is_ready() or not npc_execution.is_ready():
		control.poll()
		execution.poll()
		wallet_execution.poll()
		npc_execution.poll()
		await get_tree().process_frame
	master.inventory_session_issuer=Issuer.new(master,control)
	world.inventory_runtime=Runtime.new(world,execution)
	world.wallet_runtime=load("res://source/server/world/database/postgres/wallet_runtime_postgres.gd").new(world,wallet_execution)
	world.npc_runtime=load("res://source/server/world/database/postgres/npc_runtime_postgres.gd").new(world.wallet_runtime,world.inventory_runtime,npc_execution)
	map=add_map(world)
	map.joined.connect(func(peer: int) -> void:
		assert(world.connected_players.has(peer))
		var body:=PlayerActor3D.new()
		map.currency_map.add_child(body)
		map.characters[peer]=body
		map.currency_map.characters[peer]=body
		map.endpoint.initialize_peer(peer)
		map.currency_map.currency_endpoint.initialize_peer(peer))
	world.multiplayer_api.peer_disconnected.connect(func(peer: int) -> void:
		if map.characters.has(peer): map.characters[peer].queue_free()
		map.characters.erase(peer)
		map.currency_map.characters.erase(peer)
		map.currency_map.currency_endpoint.remove_peer(peer)
		map.currency_map.shop_endpoint.remove_peer(peer)
		map.currency_map.upgrade_endpoint.remove_peer(peer)
		map.currency_map.npc_endpoint.remove_peer(peer)
		map.endpoint.remove_peer(peer))
	map.endpoint.inventory_changed.connect(func(_owner: int) -> void: facts+=1)
	await start_client(201,"alpha","actor")
	await start_client(202,"beta","observer")
	await wait_for(func() -> bool: return map.reports.has("actor-ready") and map.reports.has("observer-ready"))
	var actor: int=map.reports["actor-ready"].peer
	var observer: int=map.reports["observer-ready"].peer
	assert(map.reports["actor-ready"].result.account==21 and map.reports["observer-ready"].result.account==22)
	assert(map.endpoint.services.item_store()==null and map.endpoint.services.economy()==null and not map.endpoint.services.mutations_allowed(actor),"other domains cannot fall back to SQLite")
	await wait_for(func() -> bool: return world.wallet_runtime.ready(actor) and world.wallet_runtime.ready(observer))
	var drop: int=map.currency_map.currency_endpoint.spawn_currency(Vector3(2,0,0),character,"alpha",Time.get_ticks_msec(),100)
	assert((await phase(actor,"wallet-pickup",{"drop":drop,"balance":1600})).ok)
	assert(int(Wallet.new(pg).load_wallet(21).balance)==1500,"actual client pickup updates RAM before SQL checkpoint")
	world.wallet_runtime.checkpoint(actor)
	await wait_for(func() -> bool: return world.wallet_runtime.ready(actor) and int(Wallet.new(pg).load_wallet(21).balance)==1600)
	assert((await phase(actor,"wallet-spend",{"balance":1550})).ok)
	assert(int(Wallet.new(pg).load_wallet(21).balance)==1550)
	assert((await phase(observer,"wallet-balance",{"balance":1500,"account":22})).ok)
	# Hold one real account row. The other client's RPC/commit and physics continue.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=21 FOR NO KEY UPDATE;").ok)
	map.phase.rpc_id(actor,"blocked-equip",{})
	await get_tree().create_timer(0.15).timeout
	var ticks: int=physics_ticks
	assert((await phase(observer,"other-equip")).ok)
	assert(physics_ticks>ticks and not map.reports.has("blocked-equip"))
	assert(world.runtime_attack(character)==-1,"pending Inventory cannot expose dependent cached combat inputs")
	assert(pg.commit())
	await wait_for(func() -> bool: return map.reports.has("blocked-equip"))
	assert(map.reports["blocked-equip"].result.ok)
	assert(world.runtime_attack(character)>10 and map.characters[actor].weapon_definition_id=="iron_sword")
	# Controlled external-domain fixture commit, not a new Upgrade UI feature.
	# Its account revision must invalidate RAM before any dependent combat read.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=21 FOR NO KEY UPDATE;").ok)
	assert(pg.execute("UPDATE economy.item_instances SET upgrade_level=1,revision=revision+1 WHERE owner_character_id=:owner;",{"owner":character}).ok and pg.commit())
	var upgraded: Dictionary=Items.new(pg).inventory(character)
	assert(world.inventory_runtime.invalidate_item_state(upgraded.item_state))
	assert(world.runtime_attack(character)==-1 and world.runtime_attack_speed_ratio(character)==-1.0)
	assert(world.runtime_attack(extra_characters.beta)>0)
	await wait_for(func() -> bool: return world.inventory_runtime.mutations_allowed(actor))
	assert(world.runtime_attack(character)==int(upgraded.stats.attack))
	assert((await phase(actor,"cache-refreshed",{"attack":upgraded.stats.attack,"revision":upgraded.item_state.revision})).ok)
	assert((await phase(actor,"flow")).ok)
	assert((await phase(observer,"privacy",{"other":actor})).ok)
	# Force a mutation COMMIT error. Receipt recovery finishes the already-admitted
	# body, then returns the same ID. No automatic new business ID or SQLite write.
	assert(pg.execute("CREATE FUNCTION economy.fixture_endpoint_fail() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'endpoint commit fixture' USING ERRCODE='40001'; END; $$;").ok)
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_endpoint AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_endpoint_fail();").ok)
	assert((await phase(actor,"uncertain")).error=="inventory_pending")
	assert(pg.execute("DROP TRIGGER fixture_endpoint ON economy.market_commands;").ok)
	assert((await phase(actor,"recover")).ok)
	# Destroy the actual client process after an accepted move lost its response.
	assert((await phase(actor,"lost-restart")).error=="inventory_pending")
	await phase(actor,"exit")
	await wait_for(func() -> bool: return not world.connected_players.has(actor))
	# Force the hydration/ACK window: the client's first journal lookup must not
	# race the still-closed backend lane. No initial snapshot is published early.
	assert(pg.execute("CREATE FUNCTION economy.fixture_endpoint_ready() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.phase='ready' THEN PERFORM pg_advisory_xact_lock(940022); END IF; RETURN NEW; END; $$;").ok)
	assert(pg.execute("CREATE TRIGGER fixture_endpoint_ready BEFORE UPDATE ON economy.inventory_sessions FOR EACH ROW EXECUTE FUNCTION economy.fixture_endpoint_ready();").ok)
	assert(pg.execute("SELECT pg_advisory_lock(940022);").ok)
	await start_client(203,"alpha","restored")
	await wait_for(func() -> bool:
		pg.execute("SELECT pg_stat_clear_snapshot();")
		return int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name LIKE 'mandate-inventory-executor-%' AND wait_event_type='Lock';").rows[0].n)>0)
	assert(not map.reports.has("restored-ready"),"initial client snapshot waits for readiness ACK")
	assert(world.runtime_attack(character)==-1 and world.runtime_attack_speed_ratio(character)==-1.0,"hydrated but unacknowledged stats remain gated")
	assert(pg.execute("SELECT pg_advisory_unlock(940022);").ok)
	await wait_for(func() -> bool: return map.reports.has("restored-ready"))
	assert(pg.execute("DROP TRIGGER fixture_endpoint_ready ON economy.inventory_sessions;").ok)
	actor=map.reports["restored-ready"].peer
	assert((await phase(actor,"wallet-balance",{"balance":1550,"account":21})).ok)
	assert((await phase(actor,"restored")).ok)
	assert(facts==9,"nine Inventory command mutations; invalidation/replay/no-op/rejection add no commit facts")
	assert(sqlite.query("SELECT COUNT(*) AS n FROM item_instances;") and int(sqlite.query_result[0].n)==0)
	assert(int(pg.query("SELECT COUNT(*) AS n FROM economy.item_instances;").rows[0].n)==2)
	assert((await phase(observer,"npc-foreign")).error=="no_interaction")
	assert((await phase(actor,"npc-open")).ok)
	map.characters[actor].position=Vector3(20,0,0)
	assert((await phase(actor,"npc-range")).error in ["out_of_range","no_interaction"])
	assert(int(Wallet.new(pg).load_wallet(21).balance)==1550 and Items.new(pg).inventory(character).items.size()==1)
	map.characters[actor].position=Vector3.ZERO
	await wait_for(func() -> bool: return world.wallet_runtime.ready(actor))
	assert(world.wallet_runtime.add_income(actor,2500))
	assert((await phase(actor,"npc-flow")).ok)
	assert(int(Wallet.new(pg).load_wallet(21).balance)==1950)
	assert(Items.new(pg).inventory(character).items.size()==2 and facts==12,"NPC purchase/material/upgrade each publish once; receipt replay does not")
	assert((await phase(actor,"npc-lost-process")).error=="purchase_pending")
	await phase(actor,"exit")
	await wait_for(func() -> bool: return not world.connected_players.has(actor))
	await start_client(204,"alpha","npc-restored")
	await wait_for(func() -> bool: return map.reports.has("npc-restored-ready"))
	actor=map.reports["npc-restored-ready"].peer
	assert((await phase(actor,"npc-restored")).ok)
	assert(int(Wallet.new(pg).load_wallet(21).balance)==1850 and Items.new(pg).inventory(character).items.size()==3 and facts==13)
	assert(sqlite.query("SELECT yang FROM account_wallets WHERE account_id=21;") and int(sqlite.query_result[0].yang)==1500,"PG income/spend never writes SQLite wallet")
	await phase(actor,"exit")
	await phase(observer,"exit")
	await wait_for(func() -> bool: return client_processes.all(func(pid: int) -> bool: return not OS.is_process_running(pid)))
	assert(await world.flush_postgres_wallets(true))
	control.begin_drain()
	execution.begin_drain()
	while not control.is_stopped() or not execution.is_stopped(): await get_tree().process_frame
	for endpoint: BaseMultiplayerEndpoint in [link,world,master]:
		endpoint.peer.close()
		endpoint.multiplayer_api.auth_callback=Callable()
		get_tree().set_multiplayer(null,endpoint.get_path())
		endpoint.queue_free()
	await get_tree().process_frame
	WorldServer.curr=null
	database.db=null
	database.free()
	authentication.free()
	assert(sqlite.close_db())
	pg.close()
	print("POSTGRES_INVENTORY_ENDPOINT_OK native client commands, independent SQL, receipt/rejection/reload/process-relogin recovery, private inventory/public weapon, PG wallet pickup/spend/relog and no SQLite item/wallet writes")
	get_tree().quit()

func compose_ui() -> void:
	session=UiCommandSession.new()
	bridge=WebUiBridge.new()
	dispatcher=UiCommandDispatcher.new()
	add_child(bridge)
	add_child(dispatcher)
	dispatcher.attach(bridge)
	adapter=ItemUiAdapter.new()
	adapter.journal.directory=fixture_dir+"/journal"
	adapter.attach(map.endpoint,dispatcher,session,get_tree())
	npc_adapter=NpcUiAdapter.new()
	npc_adapter.attach(map.currency_map.npc_endpoint,dispatcher,session,get_tree())
	shop_adapter=ShopUiAdapter.new()
	shop_adapter.journal.directory=fixture_dir+"/shop-journal"
	shop_adapter.attach(map.currency_map.shop_endpoint,dispatcher,session,get_tree())
	upgrade_adapter=UpgradeUiAdapter.new()
	upgrade_adapter.journal.directory=fixture_dir+"/upgrade-journal"
	upgrade_adapter.attach(map.currency_map.upgrade_endpoint,dispatcher,session,get_tree())
	map.endpoint.state_changed.connect(shop_adapter.accept_context)
	map.endpoint.state_changed.connect(upgrade_adapter.accept_context)
	shop_adapter.accept_context(map.endpoint.state)
	upgrade_adapter.accept_context(map.endpoint.state)
	bridge.outgoing.connect(func(json: String) -> void:
		var envelope: Dictionary=JSON.parse_string(json)
		if envelope.type=="command.result": ui_results[envelope.id]=envelope.payload
		if envelope.type=="ui.snapshot": ui_snapshots.append(envelope.payload))
	bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')

func close_ui() -> void:
	map.endpoint.state_changed.disconnect(shop_adapter.accept_context)
	map.endpoint.state_changed.disconnect(upgrade_adapter.accept_context)
	npc_adapter.dispose()
	shop_adapter.dispose()
	upgrade_adapter.dispose()
	adapter.dispose()
	session.close("teardown")
	dispatcher.dispose()
	dispatcher.queue_free()
	bridge.queue_free()

func command(type: String, payload: Dictionary) -> Dictionary:
	var id: String="fixture-"+str(ui_results.size())
	bridge.receive(JSON.stringify({"v":1,"id":id,"type":type,"payload":payload}))
	await wait_for(func() -> bool: return ui_results.has(id))
	await get_tree().create_timer(0.12).timeout
	return ui_results[id]

func item() -> Dictionary: return map.endpoint.state.items[0]

func lose_response(type: String, payload: Dictionary) -> Dictionary:
	map.endpoint.operation_finished.disconnect(session.finish)
	var result:=await command(type,payload)
	map.endpoint.operation_finished.connect(session.finish)
	assert(result.error=="inventory_pending" and not adapter.journal.load_pending().entry.is_empty())
	return result

func run_client() -> void:
	get_tree().create_timer(40).timeout.connect(func() -> void: get_tree().quit(1))
	fixture_dir=str(CmdlineUtils.get_parsed_args()["fixture-dir"])
	wire=WireClient.new()
	wire.name="Client"
	wire.token=str(CmdlineUtils.get_parsed_args()["fixture-token"])
	add_child(wire)
	assert(wire.create(BaseMultiplayerEndpoint.Role.CLIENT,"127.0.0.1",18098)==OK)
	map=add_map(wire)
	map.phase_received.connect(client_phase)
	await wait_for(func() -> bool: return wire.connected)
	map.join.rpc_id(1)
	await wait_for(func() -> bool: return map.endpoint.state.get("ok",false))
	compose_ui()
	var role: String=str(CmdlineUtils.get_parsed_args()["fixture-role"])
	map.report.rpc_id(1,role+"-ready",{"ok":true,"account":map.endpoint.state.economic_context.account_id})

func client_phase(label: String, payload: Dictionary) -> void:
	var result: Dictionary={"ok":true}
	match label:
		"npc-open":
			assert((await command("npc.interact",{"npc_instance_id":"fixture-blacksmith"})).ok)
			result=await command("npc.select_service",{"npc_instance_id":"fixture-blacksmith","service_id":"weapon_shop"})
		"npc-range": result=await command("shop.buy",{"npc_instance_id":"fixture-blacksmith","service_id":"weapon_shop","offer_id":"iron_sword"})
		"npc-lost-process":
			assert((await command("npc.select_service",{"npc_instance_id":"fixture-blacksmith","service_id":"weapon_shop"})).ok)
			map.currency_map.shop_endpoint.operation_finished.disconnect(session.finish)
			result=await command("shop.buy",{"npc_instance_id":"fixture-blacksmith","service_id":"weapon_shop","offer_id":"upgrade_ore"})
			map.currency_map.shop_endpoint.operation_finished.connect(session.finish)
		"npc-restored":
			await wait_for(func() -> bool: return shop_adapter.journal.load_pending().entry.is_empty())
			await wait_for(func() -> bool: return map.currency_map.currency_endpoint.state.get("balance",-1)==1850)
			assert(map.endpoint.state.items.size()==3)
		"npc-foreign": result=await command("shop.buy",{"npc_instance_id":"fixture-blacksmith","service_id":"weapon_shop","offer_id":"iron_sword"})
		"npc-flow":
			assert((await command("npc.interact",{"npc_instance_id":"fixture-blacksmith"})).ok)
			assert((await command("npc.select_service",{"npc_instance_id":"fixture-blacksmith","service_id":"weapon_shop"})).ok)
			assert((await command("shop.open",{"npc_instance_id":"fixture-blacksmith","service_id":"weapon_shop"})).ok)
			var old_uid: String=item().uid
			map.currency_map.shop_endpoint.operation_finished.disconnect(session.finish)
			var lost:=await command("shop.buy",{"npc_instance_id":"fixture-blacksmith","service_id":"weapon_shop","offer_id":"iron_sword"})
			map.currency_map.shop_endpoint.operation_finished.connect(session.finish)
			assert(lost.error=="purchase_pending")
			assert((await command("shop.retry",{})).ok)
			assert((await command("shop.buy",{"npc_instance_id":"fixture-blacksmith","service_id":"weapon_shop","offer_id":"upgrade_ore"})).ok)
			var target: Dictionary=map.endpoint.state.items.filter(func(row: Dictionary) -> bool: return row.uid!=old_uid and row.definition_id=="iron_sword")[0]
			assert((await command("npc.select_service",{"npc_instance_id":"fixture-blacksmith","service_id":"upgrade"})).ok)
			var selected: Dictionary={"npc_instance_id":"fixture-blacksmith","service_id":"upgrade","id":target.uid,"revision":target.revision}
			assert((await command("upgrade.select",selected)).ok)
			assert(map.currency_map.upgrade_endpoint.state.candidate.id==target.uid)
			map.currency_map.upgrade_endpoint.operation_finished.disconnect(session.finish)
			lost=await command("upgrade.execute",selected)
			map.currency_map.upgrade_endpoint.operation_finished.connect(session.finish)
			assert(lost.error=="upgrade_pending")
			close_ui()
			compose_ui() # Restored journal performs read-only receipt recovery.
			await wait_for(func() -> bool: return upgrade_adapter.journal.load_pending().entry.is_empty())
			await wait_for(func() -> bool: return map.currency_map.currency_endpoint.state.get("balance",-1)==1950)
			assert(map.endpoint.state.items.filter(func(row: Dictionary) -> bool: return row.uid==target.uid)[0].upgrade_level==1)
		"wallet-pickup":
			map.currency_map.currency_endpoint.request_pickup.rpc_id(1,int(payload.drop))
			await wait_for(func() -> bool: return map.currency_map.currency_endpoint.state.get("balance",-1)==int(payload.balance))
		"wallet-spend":
			map.currency_map.currency_endpoint.request_test_spend.rpc_id(1,0)
			await wait_for(func() -> bool: return map.currency_map.currency_endpoint.state.get("balance",-1)==int(payload.balance))
		"wallet-balance":
			await wait_for(func() -> bool: return map.currency_map.currency_endpoint.state.get("balance",-1)==int(payload.balance))
			assert(map.currency_map.currency_endpoint.state.wallet_state.account_id==int(payload.account))
		"cache-refreshed":
			assert(item().upgrade_level==1 and map.endpoint.state.stats.attack==payload.attack)
			assert(map.endpoint.state.item_state.revision>=int(payload.revision))
		"blocked-equip", "other-equip": result=await command("equipment.equip",{"id":item().uid,"revision":item().revision})
		"flow":
			assert((await command("equipment.unequip",{"id":item().uid,"revision":item().revision,"x":0,"y":3,"page":0})).ok)
			var invalid:=await command("inventory.move_item",{"id":item().uid,"revision":item().revision,"x":0,"y":8,"page":0})
			assert(not invalid.ok and invalid.get("terminal",false),"out-of-bounds footprint is a durable rejection")
			var before: Dictionary=map.endpoint.state.duplicate(true)
			await lose_response("inventory.move_item",{"id":item().uid,"revision":item().revision-1,"x":2,"y":2,"page":0})
			assert((await command("inventory.retry",{})).error=="stale")
			assert(adapter.journal.load_pending().entry.is_empty() and item().revision==before.items[0].revision)
			await lose_response("inventory.move_item",{"id":item().uid,"revision":item().revision,"x":2,"y":2,"page":0})
			bridge.reset_transport()
			bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
			assert(ui_snapshots.back().inventory.recoveryPending)
			assert((await command("inventory.retry",{})).ok)
			assert((await command("item.activate",{"id":item().uid,"revision":item().revision})).ok)
			assert((await command("equipment.equip",{"id":item().uid,"revision":item().revision})).ok) # no-op
			assert((await command("equipment.unequip",{"id":item().uid,"revision":item().revision})).ok)
		"privacy":
			assert(map.endpoint.state.items.size()==1 and map.endpoint.state.economic_context.account_id==22)
			assert(map.endpoint.public_weapons.get(int(payload.other),"missing")=="")
		"uncertain": result=await command("equipment.equip",{"id":item().uid,"revision":item().revision})
		"recover": result=await command("inventory.retry",{})
		"lost-restart": result=await lose_response("equipment.unequip",{"id":item().uid,"revision":item().revision})
		"restored":
			await wait_for(func() -> bool: return adapter.journal.load_pending().entry.is_empty())
			assert(item().location=="bag" and map.endpoint.state.stats.attack==10)
			# A saved but never sent body is read-only on restore, and executes only
			# after an explicit retry, retaining its original operation identity.
			var id: String="inventory-"+Crypto.new().generate_random_bytes(16).hex_encode()
			assert(adapter.journal.save_pending(id,{"action":"move","item":{"id":item().uid,"revision":item().revision,"x":3,"y":3,"page":2}}))
			close_ui()
			compose_ui()
			await get_tree().create_timer(0.3).timeout
			assert(adapter.journal.load_pending().entry.id==id and item().bag_position!=108)
			result=await command("inventory.retry",{})
			assert(result.ok and adapter.journal.load_pending().entry.is_empty())
		"exit":
			map.report.rpc_id(1,label,result)
			await get_tree().create_timer(0.1).timeout
			close_ui()
			wire.peer.close()
			print("POSTGRES_INVENTORY_ENDPOINT_CLIENT_OK")
			get_tree().quit()
			return
	map.report.rpc_id(1,label,result)
