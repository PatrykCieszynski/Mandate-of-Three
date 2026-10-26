extends "res://tests/postgres_inventory_session_bridge.gd"
## Actual client processes use the production endpoint, bridge, journal and item
## adapter. Master/World run on native isolated sockets in this server fixture;
## Gateway credentials and map/actor construction remain controlled.
class PickupCombat extends CombatEndpoint3D:
	# Exercise production pickup RPC/feedback/callbacks without starting mobs,
	# navigation, HUD or combat simulation in this economic network fixture.
	func _ready() -> void:
		_world=get_parent()
		_ground_runtime=services.ground_item_runtime()
		if GameMode.is_world_server() and _ground_runtime!=null:
			_ground_runtime.finished.connect(_ground_finished)
			_ground_runtime.committed.connect(_ground_committed)
	func _physics_process(_delta: float) -> void: pass
	func _process(_delta: float) -> void: pass
	func _send_snapshot() -> void: pass

class CurrencyMap extends GameWorld3D:
	func _ready() -> void:
		combat_endpoint=PickupCombat.new()
		combat_endpoint.name="Combat"
		combat_endpoint.services=services
		add_child(combat_endpoint)
		ground_loot.setup(self,services)
		market_endpoint=MarketEndpoint3D.new()
		market_endpoint.name="Market"
		market_endpoint.services=services
		add_child(market_endpoint)
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
	func _exit_tree() -> void: pass
	func has_line_of_sight(_from: Vector3, _to: Vector3) -> bool: return true

class FixtureMap extends Node3D:
	var combat_endpoint: Node
	var inventory_endpoint: Node
	var currency_endpoint: Node
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
		combat_endpoint=currency_map.combat_endpoint
		inventory_endpoint=endpoint
		currency_endpoint=currency_map.currency_endpoint
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
var npc_adapter: NpcUiAdapter
var shop_adapter: ShopUiAdapter
var upgrade_adapter: UpgradeUiAdapter
var craft_adapter: RefCounted
var storage_adapter: RefCounted
var world_bootstrap: RefCounted
var master_bootstrap: RefCounted
var exchange_adapter: ExchangeUiAdapter
var exchange_views: Array[Dictionary]=[]
var market_adapter: MarketUiAdapter
var browser_adapter: MarketBrowserUiAdapter
var market_views: Array[Dictionary]=[]

func _ready() -> void:
	get_tree().create_timer(210).timeout.connect(func() -> void: get_tree().quit(1))
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
	assert(master.responses[request].has("auth-token"),str(master.responses[request]))
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
	assert(preload("res://source/server/world/database/postgres/auction_search_schema_postgres.gd").ensure_schema(pg))
	assert(preload("res://source/server/world/database/postgres/storage_schema_postgres.gd").ensure_schema(pg))
	assert(preload("res://source/server/world/database/postgres/account_claim_schema_postgres.gd").ensure_schema(pg))
	assert(preload("res://source/server/world/database/postgres/exchange_orders_schema_postgres.gd").ensure_schema(pg))
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
		assert(pg.execute("INSERT INTO economy.item_initializations(owner_character_id) VALUES(:owner);",{"owner":owner}).ok) # Pre-existing/imported fixture character.
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
	var bootstrap_settings: Dictionary={"backend":"postgresql","connection_env":"MANDATE_PG_FIXTURE_CONNECTION","authority_id":str(pg.query("SELECT value FROM economy.meta WHERE key='economy_authority_id';").rows[0].value)}
	master_bootstrap=load("res://source/server/world/database/postgres/economy_bootstrap_postgres.gd").new()
	assert(await master_bootstrap.start_master(master,bootstrap_settings))
	world.name="World"
	world.database=database
	world.world_manager=link
	add_child(world)
	world_bootstrap=load("res://source/server/world/database/postgres/economy_bootstrap_postgres.gd").new()
	assert(await world_bootstrap.start_world(world,bootstrap_settings))
	assert(database.economy_backend=="postgresql" and world_bootstrap.status().workers_ready==world_bootstrap.status().workers)
	assert(not database.load_wallet(character) and not database.credit_account(21,100).ok)

	assert(world.create(BaseMultiplayerEndpoint.Role.SERVER,"127.0.0.1",18098)==OK)
	WorldServer.curr=world
	link.name="ControlLink"
	link.database=database
	link.world_server=world
	add_child(link)
	assert(link.create(BaseMultiplayerEndpoint.Role.CLIENT,"127.0.0.1",18099)==OK)
	await wait_for(func() -> bool: return master.connected_worlds.size()==1)
	world_id=link.multiplayer_api.get_unique_id()
	# Controlled roster handshake: production bootstraps above are actually ready.
	master.connected_worlds[world_id].economy_ready=world_bootstrap.ready()
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
		map.currency_map.market_endpoint.remove_peer(peer)
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
	assert((await phase(actor,"storage-flow")).ok)
	assert(facts==16,"Storage deposit/rearrange/withdraw each publish once, receipt recovery does not")
	assert((await phase(actor,"storage-lost-process")).error=="storage_pending")
	await phase(actor,"exit")
	await wait_for(func() -> bool: return not world.connected_players.has(actor))
	await start_client(205,"alpha","storage-restored")
	await wait_for(func() -> bool: return map.reports.has("storage-restored-ready"))
	actor=map.reports["storage-restored-ready"].peer
	assert((await phase(actor,"storage-restored")).ok)
	assert(facts==17 and Items.new(pg).inventory(character).items.size()==2)
	assert(preload("res://source/server/world/database/postgres/account_storage_postgres.gd").new(pg).snapshot(character).items.size()==1)
	assert((await phase(observer,"storage-private")).ok)
	var ground_uid: String=map.currency_map.ground_loot.spawn_resolved_item(Vector3.ZERO,character,"alpha",Time.get_ticks_msec(),&"upgrade_ore",4,[])
	assert((await phase(observer,"ground-pickup",{"uid":ground_uid})).error=="reserved")
	assert((await phase(actor,"ground-pickup",{"uid":ground_uid})).ok)
	assert(not map.currency_map.ground_loot.drops.has(ground_uid) and facts==18)
	assert((await phase(actor,"ground-pickup",{"uid":ground_uid})).ok and facts==18,"same UID receipt recovery adds no item/fact")
	assert(Items.new(pg).inventory(character).items.any(func(row: Dictionary) -> bool: return row.uid==ground_uid and row.amount==4))
	await phase(actor,"exit")
	await wait_for(func() -> bool: return not world.connected_players.has(actor))
	await start_client(206,"alpha","ground-restored")
	await wait_for(func() -> bool: return map.reports.has("ground-restored-ready"))
	actor=map.reports["ground-restored-ready"].peer
	assert((await phase(actor,"ground-restored",{"uid":ground_uid})).ok and facts==18)
	var claim_item:=ItemInstance.create(ItemDefinitions.UPGRADE_ORE,character,[])
	assert(pg.begin() and preload("res://source/server/world/database/postgres/account_claim_postgres.gd").new(pg).receive_in_transaction(claim_item).ok and pg.commit())
	assert(world.inventory_runtime.invalidate_item_state(Items.new(pg).inventory(character).item_state))
	await wait_for(func() -> bool: return world.inventory_runtime.mutations_allowed(actor))
	assert((await phase(actor,"seller-flow")).ok and facts==20)
	assert((await phase(actor,"seller-lost-process",{"uid":claim_item.uid})).error=="seller_pending")
	await phase(actor,"exit")
	await wait_for(func() -> bool: return not world.connected_players.has(actor))
	await start_client(207,"alpha","seller-restored")
	await wait_for(func() -> bool: return map.reports.has("seller-restored-ready"))
	actor=map.reports["seller-restored-ready"].peer
	assert((await phase(actor,"seller-restored",{"uid":claim_item.uid})).ok and facts==21)
	var listed: Dictionary=await phase(actor,"settlement-list")
	assert(listed.ok and facts==22)
	assert((await phase(observer,"auction-browser",listed)).ok)
	assert(world.wallet_runtime.add_income(observer,800))
	assert((await phase(observer,"settlement-buy",listed)).error=="seller_pending")
	assert(facts==23 and int(Wallet.new(pg).load_wallet(22).balance)==300)
	await wait_for(func()->bool:return world.seller_runtime.drained())
	assert((await phase(actor,"settlement-proceeds-view",{"amount":"2000"})).ok)
	await phase(observer,"exit")
	await wait_for(func()->bool:return not world.connected_players.has(observer))
	await start_client(208,"beta","buyer-restored")
	await wait_for(func()->bool:return map.reports.has("buyer-restored-ready"))
	observer=map.reports["buyer-restored-ready"].peer
	assert((await phase(observer,"settlement-restored",listed)).ok and facts==23)
	assert(world.wallet_runtime.add_income(actor,30))
	assert((await phase(actor,"settlement-collect")).ok)
	assert(int(Wallet.new(pg).load_wallet(21).balance)==3880 and facts==23)
	assert(int(preload("res://source/server/world/database/postgres/shop_settlement_postgres.gd").new(pg).revenue(21).amount)==0)
	var ledger_ore: Dictionary=Items.new(pg).inventory(character).items.filter(func(row: Dictionary)->bool:return row.definition_id=="upgrade_ore" and row.amount>=2 and row.location=="bag")[0]
	assert((await phase(actor,"exchange-deposit",{"uid":ledger_ore.uid})).ok and facts==26)
	var lost_withdrawal: Dictionary=await phase(actor,"exchange-lost-process")
	assert(lost_withdrawal.error=="exchange_pending" and facts==27)
	await phase(actor,"exit")
	await wait_for(func()->bool:return not world.connected_players.has(actor))
	await start_client(209,"alpha","exchange-restored")
	await wait_for(func()->bool:return map.reports.has("exchange-restored-ready"))
	actor=map.reports["exchange-restored-ready"].peer
	assert((await phase(actor,"exchange-restored",lost_withdrawal)).ok and facts==27)
	assert(world.wallet_runtime.add_income(actor,17) and world.wallet_runtime.add_income(observer,800))
	assert(pg.execute("UPDATE economy.exchange_assets SET free=10 WHERE account_id=21 AND asset_id='upgrade_ore';").ok)
	var sell_order: Dictionary=await phase(actor,"matching-sell")
	assert(sell_order.ok)
	assert((await phase(observer,"matching-buy")).error=="exchange_pending" and facts==27)
	assert((await phase(actor,"matching-maker",sell_order)).ok)
	await phase(observer,"exit")
	await wait_for(func()->bool:return not world.connected_players.has(observer))
	await start_client(210,"beta","matching-restored")
	await wait_for(func()->bool:return map.reports.has("matching-restored-ready"))
	observer=map.reports["matching-restored-ready"].peer
	assert((await phase(observer,"matching-restored")).ok and facts==27)
	assert((await phase(actor,"matching-cancel",sell_order)).ok and facts==27)
	assert((await phase(observer,"matching-reserve-cancel")).ok)
	assert(int(Wallet.new(pg).load_wallet(21).balance)==4297 and int(Wallet.new(pg).load_wallet(22).balance)==700)
	assert(sqlite.query("SELECT yang FROM account_wallets WHERE account_id=21;") and int(sqlite.query_result[0].yang)==1500,"PG income/spend never writes SQLite wallet")
	# Craft uses the actual endpoint, UI journal and separate native client
	# process. It must recover a committed random outcome without redrawing.
	var crafting_definitions: Array[ItemDefinition]=[ItemDefinitions.CHANGE_SPARK,ItemDefinitions.ASCENSION_EMBER,ItemDefinitions.AWAKENING_SEAL,ItemDefinitions.CLEANSING_SALT,ItemDefinitions.COMPLETION_CORE]
	for definition: ItemDefinition in crafting_definitions:
		var craft_target:=ItemInstance.create(ItemDefinitions.IRON_SWORD,character,[])
		if definition in [ItemDefinitions.AWAKENING_SEAL,ItemDefinitions.CLEANSING_SALT,ItemDefinitions.COMPLETION_CORE]:
			var rng:=RandomNumberGenerator.new();rng.seed=17
			var count: int=3 if definition in [ItemDefinitions.CLEANSING_SALT,ItemDefinitions.COMPLETION_CORE] else 1
			craft_target.affixes=preload("res://source/common/gameplay/items/affixes/affix_generator.gd").generate(ItemDefinitions.IRON_SWORD,count,count,preload("res://source/common/gameplay/items/crafting/crafting_rules.gd").PROFILE.pool,rng).affixes
			craft_target.rarity="rare" if definition in [ItemDefinitions.CLEANSING_SALT,ItemDefinitions.COMPLETION_CORE] else "magic"
			if definition==ItemDefinitions.COMPLETION_CORE: craft_target.affixes.pop_back()
		craft_target.upgrade_level=3;craft_target.sockets=[{"definition_id":"preserve"}]
		var craft_material:=ItemInstance.create(definition,character,[])
		craft_material.amount=2
		assert(pg.begin() and Items.new(pg).receive_item_in_transaction(craft_target).ok and Items.new(pg).receive_item_in_transaction(craft_material).ok and pg.commit())
		assert(world.inventory_runtime.invalidate_item_state(Items.new(pg).inventory(character).item_state))
		await wait_for(func()->bool:return world.inventory_runtime.mutations_allowed(actor))
		var craft_payload: Dictionary={"target":craft_target.uid,"currency":craft_material.uid,"rarity":"magic" if definition==ItemDefinitions.CHANGE_SPARK else ("normal" if definition==ItemDefinitions.CLEANSING_SALT else "rare"),"retry_error":"affix_capacity" if definition==ItemDefinitions.COMPLETION_CORE else "rarity"}
		assert((await phase(actor,"craft-lost",craft_payload)).error=="timeout")
		var frozen: Dictionary=Items.new(pg).inventory(character).items.filter(func(i: Dictionary)->bool:return i.uid==craft_target.uid)[0]
		assert(frozen.rarity==craft_payload.rarity and frozen.revision==1 and frozen.upgrade_level==3 and frozen.sockets==craft_target.sockets)
		if definition==ItemDefinitions.AWAKENING_SEAL:
			assert(frozen.affixes.size()==3 and frozen.affixes.slice(0,2)==craft_target.affixes)
		if definition==ItemDefinitions.CLEANSING_SALT: assert(frozen.affixes.is_empty())
		if definition==ItemDefinitions.COMPLETION_CORE: assert(frozen.affixes.size()==6 and frozen.affixes.slice(0,5)==craft_target.affixes)
		await phase(actor,"exit")
		await wait_for(func()->bool:return not world.connected_players.has(actor))
		map.reports.erase("craft-restored-ready")
		await start_client(211+crafting_definitions.find(definition),"alpha","craft-restored")
		await wait_for(func()->bool:return map.reports.has("craft-restored-ready"))
		actor=map.reports["craft-restored-ready"].peer
		assert((await phase(actor,"craft-restored",craft_payload)).ok)
		assert(Items.new(pg).inventory(character).items.filter(func(i: Dictionary)->bool:return i.uid==craft_target.uid)[0]==frozen)
		assert(Items.new(pg).inventory(character).items.filter(func(i: Dictionary)->bool:return i.uid==craft_material.uid)[0].amount==1)
	await phase(actor,"exit")
	await phase(observer,"exit")
	await wait_for(func() -> bool: return client_processes.all(func(pid: int) -> bool: return not OS.is_process_running(pid)))
	assert(await world_bootstrap.shutdown_world())
	assert(await master_bootstrap.shutdown_master())
	assert(world_bootstrap.status().stopped and master_bootstrap.status().stopped)
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
	craft_adapter=preload("res://source/client/ui_web/crafting_ui_adapter.gd").new()
	craft_adapter.journal.directory=fixture_dir+"/craft-journal"
	craft_adapter.attach(map.endpoint,dispatcher,session,get_tree())
	adapter.craft_requested.connect(craft_adapter.open)
	market_adapter=MarketUiAdapter.new()
	market_adapter.state_updated.connect(func(view: Dictionary)->void:market_views.append(view))
	market_adapter.journal.directory=fixture_dir+"/revenue-journal"
	market_adapter.seller_journal.directory=fixture_dir+"/seller-journal"
	market_adapter.attach(map.currency_map.market_endpoint,dispatcher,session,get_tree())
	map.currency_map.market_endpoint.operation_finished.connect(session.finish)
	map.currency_map.market_endpoint.query_finished.connect(session.finish)
	exchange_adapter=ExchangeUiAdapter.new()
	exchange_adapter.journal.directory=fixture_dir+"/exchange-journal"
	exchange_adapter.state_updated.connect(func(view: Dictionary)->void:exchange_views.append(view))
	exchange_adapter.attach(map.currency_map.market_endpoint,dispatcher,session,get_tree())
	map.endpoint.state_changed.connect(exchange_adapter.accept_context)
	exchange_adapter.accept_context(map.endpoint.state)
	browser_adapter=MarketBrowserUiAdapter.new()
	browser_adapter.attach(map.currency_map.market_endpoint,dispatcher,session,get_tree())
	market_adapter.purchase_recovery.connect(browser_adapter.accept_purchase_recovery)
	map.endpoint.state_changed.connect(market_adapter.accept_context)
	market_adapter.accept_context(map.endpoint.state)
	storage_adapter=preload("res://source/client/ui_web/storage_ui_adapter.gd").new()
	storage_adapter.journal.directory=fixture_dir+"/storage-journal"
	storage_adapter.attach(map.endpoint,dispatcher,session,get_tree(),func() -> bool: return true)
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
	map.endpoint.state_changed.disconnect(market_adapter.accept_context)
	map.currency_map.market_endpoint.operation_finished.disconnect(session.finish)
	map.currency_map.market_endpoint.query_finished.disconnect(session.finish)
	browser_adapter.dispose()
	map.endpoint.state_changed.disconnect(exchange_adapter.accept_context)
	exchange_adapter.dispose()
	market_adapter.dispose()
	map.endpoint.state_changed.disconnect(shop_adapter.accept_context)
	map.endpoint.state_changed.disconnect(upgrade_adapter.accept_context)
	npc_adapter.dispose()
	shop_adapter.dispose()
	upgrade_adapter.dispose()
	storage_adapter.dispose()
	craft_adapter.dispose()
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
	get_tree().create_timer(205).timeout.connect(func() -> void: get_tree().quit(1))
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
		"matching-sell":
			await exchange_adapter.open()
			assert((await command("exchange.order",{"command_id":"sell","have_asset":"upgrade_ore","want_asset":"yang","quantity":6,"price_num":100,"price_den":1})).ok)
			var order: Dictionary=exchange_views.back().orders.filter(func(row: Dictionary)->bool:return row.status=="active")[0]
			result={"ok":true,"order_id":order.id}
		"matching-buy":
			await exchange_adapter.open()
			map.currency_map.market_endpoint.operation_finished.disconnect(session.finish)
			result=await command("exchange.order",{"command_id":"buy","have_asset":"yang","want_asset":"upgrade_ore","quantity":4,"price_num":120,"price_den":1})
			map.currency_map.market_endpoint.operation_finished.connect(session.finish)
		"matching-maker":
			await wait_for(func()->bool:return exchange_views.back().orders.any(func(row: Dictionary)->bool:return row.id==payload.order_id and row.remaining==2))
			assert(exchange_views.back().yang==4297 and exchange_views.back().assets.filter(func(row: Dictionary)->bool:return row.asset_id=="upgrade_ore")[0].reserved==2)
		"matching-restored":
			await wait_for(func()->bool:return exchange_adapter.journal.load_pending().entry.is_empty())
			await exchange_adapter.open()
			assert(exchange_views.back().yang==700 and exchange_views.back().assets.filter(func(row: Dictionary)->bool:return row.asset_id=="upgrade_ore")[0].free==4)
		"matching-cancel":
			map.currency_map.market_endpoint.operation_finished.disconnect(session.finish)
			assert((await command("exchange.cancel_order",{"command_id":"cancel","order_id":payload.order_id,"revision":1})).error=="exchange_pending")
			map.currency_map.market_endpoint.operation_finished.connect(session.finish)
			close_ui();compose_ui()
			await wait_for(func()->bool:return exchange_adapter.journal.load_pending().entry.is_empty())
			await exchange_adapter.open()
			assert(exchange_views.back().assets.filter(func(row: Dictionary)->bool:return row.asset_id=="upgrade_ore")[0].free==6)
		"matching-reserve-cancel":
			assert((await command("exchange.order",{"command_id":"reserve","have_asset":"yang","want_asset":"upgrade_ore","quantity":3,"price_num":50,"price_den":1})).ok)
			assert(exchange_views.back().reservedYang==150)
			var order: Dictionary=exchange_views.back().orders.filter(func(row: Dictionary)->bool:return row.status=="active")[0]
			assert((await command("exchange.cancel_order",{"command_id":"refund","order_id":order.id,"revision":order.revision})).ok)
			assert(exchange_views.back().reservedYang==0 and exchange_views.back().yang==700)
		"exchange-deposit":
			await exchange_adapter.open()
			assert(not exchange_views.is_empty() and not exchange_views.back().ledgerOnly)
			var ore: Dictionary=map.endpoint.state.items.filter(func(row: Dictionary)->bool:return row.uid==payload.uid)[0]
			assert((await command("storage.transfer",{"id":ore.uid,"revision":ore.revision,"from":"inventory","to":"storage","x":0,"y":0,"page":0,"quick":true})).ok)
			ore=map.endpoint.state.storage.items.filter(func(row: Dictionary)->bool:return row.uid==payload.uid)[0]
			map.currency_map.market_endpoint.operation_finished.disconnect(session.finish)
			assert((await command("exchange.deposit",{"command_id":"web-deposit","uid":ore.uid,"revision":ore.revision,"amount":2,"source":"account_storage"})).error=="exchange_pending")
			map.currency_map.market_endpoint.operation_finished.connect(session.finish)
			bridge.reset_transport()
			bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
			assert(ui_snapshots.back().exchange.retryAvailable)
			assert((await command("exchange.retry",{})).ok)
			assert((await command("exchange.withdraw",{"command_id":"web-claim","asset_id":"upgrade_ore","amount":1,"destination":"claim"})).ok)
		"exchange-lost-process":
			var before: Array=map.endpoint.state.items.map(func(row: Dictionary)->String:return row.uid)
			map.currency_map.market_endpoint.operation_finished.disconnect(session.finish)
			result=await command("exchange.withdraw",{"command_id":"web-withdraw","asset_id":"upgrade_ore","amount":1,"destination":"bag"})
			map.currency_map.market_endpoint.operation_finished.connect(session.finish)
			var created: Dictionary=map.endpoint.state.items.filter(func(row: Dictionary)->bool:return row.uid not in before)[0]
			result.uid=created.uid
		"exchange-restored":
			await wait_for(func()->bool:return exchange_adapter.journal.load_pending().entry.is_empty())
			await exchange_adapter.open()
			assert(map.endpoint.state.items.any(func(row: Dictionary)->bool:return row.uid==payload.uid and row.amount==1))
			assert(exchange_views.back().assets.filter(func(row: Dictionary)->bool:return row.asset_id=="upgrade_ore")[0].free==0)
			assert((await command("exchange.retry",{})).error=="no_pending_intent")
			# A saved but never submitted intent survives read-only reopen; only
			# explicit Retry may execute it (here a definitive empty-ledger rejection).
			var saved_id: String="exchange-"+Crypto.new().generate_random_bytes(16).hex_encode()
			assert(exchange_adapter.journal.save_pending(saved_id,{"action":"withdraw","payload":{"asset_id":"upgrade_ore","amount":1,"destination":"claim"}}))
			close_ui()
			compose_ui()
			await exchange_adapter.open()
			await wait_for(func()->bool:return not exchange_views.is_empty() and exchange_views.back().retryAvailable)
			assert(exchange_adapter.journal.load_pending().entry.id==saved_id)
			assert((await command("exchange.retry",{})).error=="funds" and exchange_adapter.journal.load_pending().entry.is_empty())
		"settlement-list":
			assert((await market_adapter.open()).ok)
			var snapshot: Dictionary=map.currency_map.market_endpoint.state
			assert((await command("market.configure",{"command_id":"settlement-config","revision":snapshot.revision,"name":"Settlement network","status":"active"})).ok)
			var target: Dictionary=map.endpoint.state.items.filter(func(row: Dictionary)->bool:return row.location=="bag" and row.definition_id=="iron_sword")[0]
			assert((await command("market.list",{"command_id":"settlement-list","uid":target.uid,"revision":target.revision,"position":0,"price":2000})).ok)
			snapshot=map.currency_map.market_endpoint.state
			var offer: Dictionary=snapshot.offers[0]
			result={"ok":true,"shop_id":int(snapshot.shop_id),"offer_id":offer.offer_id,"revision":int(offer.revision),"price":int(offer.price),"uid":target.uid}
		"auction-browser":
			browser_adapter.active=true
			assert((await command("market.browser.catalog",{"query":"iron"})).ok)
			var criteria: Dictionary={"definition_id":"iron_sword","upgrade_min":0,"upgrade_max":9,"price_min":0,"price_max":9000000000000000,"affix_filters":[],"sort":"price_asc","cursor":"","limit":5}
			assert((await command("market.browser.search",criteria)).ok)
			bridge.reset_transport();bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
			assert(ui_snapshots.back().market_browser.results.size()==1 and ui_snapshots.back().market_browser.results[0].offerId==payload.offer_id)
			var replies: Array=[]
			var collect: Callable=func(id: String,answer: Dictionary)->void:
				if id.begins_with("auction-dedupe"): replies.append({"id":id,"result":answer})
			map.currency_map.market_endpoint.query_finished.connect(collect)
			await get_tree().create_timer(1.1).timeout
			map.currency_map.market_endpoint.request_query.rpc_id(1,"search",criteria,"auction-dedupe")
			for duplicate: int in 12: map.currency_map.market_endpoint.request_query.rpc_id(1,"search",{},"auction-dedupe")
			await wait_for(func()->bool:return not replies.is_empty())
			await get_tree().create_timer(0.15).timeout
			assert(replies.size()==1 and replies[0].result.ok)
			# Terminal IDs also deduplicate malformed payloads and limiter responses.
			for duplicate: int in 10: map.currency_map.market_endpoint.request_query.rpc_id(1,"catalog",{},"auction-dedupe")
			await get_tree().create_timer(0.15).timeout
			assert(replies.size()==1)
			for request: int in 9: map.currency_map.market_endpoint.request_query.rpc_id(1,"search",{},"auction-dedupe-invalid-"+str(request))
			await wait_for(func()->bool:return replies.size()==10)
			var rejected: Array=replies.filter(func(row: Dictionary)->bool:return row.id=="auction-dedupe-invalid-8")
			assert(rejected.size()==1 and rejected[0].result.error=="rate_limited")
			map.currency_map.market_endpoint.request_query.rpc_id(1,"search",criteria,"auction-dedupe-invalid-8")
			await get_tree().create_timer(0.1).timeout
			assert(replies.size()==10)
			map.currency_map.market_endpoint.query_finished.disconnect(collect)
			await get_tree().create_timer(1.05).timeout
			result={"ok":true}
		"settlement-buy":
			browser_adapter.active=true
			assert((await command("market.browser.visit",{"shop_id":payload.shop_id,"offer_id":payload.offer_id})).ok)
			# The buyer has not opened their own shop: capability discovery must
			# precede journaling and sending the first purchase.
			map.currency_map.market_endpoint.operation_finished.disconnect(session.finish)
			result=await command("market.buy",{"command_id":"browser-buy","shop_id":payload.shop_id,"offer_id":payload.offer_id,"revision":payload.revision,"price":payload.price})
			map.currency_map.market_endpoint.operation_finished.connect(session.finish)
			assert(not market_adapter.seller_journal.load_pending().entry.is_empty())
			bridge.reset_transport()
			bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
			assert(ui_snapshots.back().market_browser.purchasePending)
		"settlement-restored":
			await wait_for(func()->bool:return market_adapter.seller_journal.load_pending().entry.is_empty())
			assert(map.endpoint.state.items.any(func(row: Dictionary)->bool:return row.uid==payload.uid))
			assert((await command("market.retry_seller",{})).error=="no_pending_seller")
		"settlement-proceeds-view":
			assert(map.currency_map.market_endpoint.state.claimable_yang==payload.amount and map.currency_map.market_endpoint.state.offers.is_empty())
		"settlement-collect":
			map.currency_map.market_endpoint.operation_finished.disconnect(session.finish)
			assert((await command("market.collect_revenue",{})).error=="revenue_pending")
			map.currency_map.market_endpoint.operation_finished.connect(session.finish)
			close_ui()
			compose_ui()
			await wait_for(func()->bool:return market_adapter.journal.load_pending().entry.is_empty())
			assert((await market_adapter.open()).ok and map.currency_map.market_endpoint.state.claimable_yang=="0")
		"seller-flow":
			assert((await market_adapter.open()).ok)
			var target: Dictionary=map.endpoint.state.items.filter(func(row: Dictionary)->bool:return row.location=="bag" and row.definition_id=="iron_sword")[0]
			map.currency_map.market_endpoint.operation_finished.disconnect(session.finish)
			assert((await command("market.list",{"command_id":"browser-list","uid":target.uid,"revision":target.revision,"position":0,"price":150})).error=="seller_pending")
			map.currency_map.market_endpoint.operation_finished.connect(session.finish)
			assert(not map.endpoint.state.items.any(func(row: Dictionary)->bool:return row.uid==target.uid))
			bridge.reset_transport()
			bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
			assert(ui_snapshots.back().market.sellerPending)
			assert((await command("market.retry_seller",{})).ok)
			var offer: Dictionary=map.currency_map.market_endpoint.state.offers[0]
			assert((await command("market.edit",{"command_id":"browser-edit","offer_id":offer.offer_id,"revision":offer.revision,"position":3,"price":175})).ok)
			var snapshot: Dictionary=map.currency_map.market_endpoint.state
			assert((await command("market.configure",{"command_id":"browser-config","revision":snapshot.revision,"name":"PG seller","status":"paused"})).ok)
			offer=map.currency_map.market_endpoint.state.offers[0]
			map.currency_map.market_endpoint.operation_finished.disconnect(session.finish)
			assert((await command("market.cancel",{"command_id":"browser-cancel","offer_id":offer.offer_id,"revision":offer.revision})).error=="seller_pending")
			map.currency_map.market_endpoint.operation_finished.connect(session.finish)
			close_ui()
			compose_ui()
			await wait_for(func()->bool:return market_adapter.seller_journal.load_pending().entry.is_empty())
			assert((await market_adapter.open()).ok and map.currency_map.market_endpoint.state.offers.is_empty())
			# Persisted but never sent intent: reload/reopen performs discovery only,
			# and explicit retry executes the saved body under its original native ID.
			var operation: String="seller-"+Crypto.new().generate_random_bytes(16).hex_encode()
			var saved: Dictionary={"action":"configure","payload":{"revision":map.currency_map.market_endpoint.state.revision,"name":"Explicit saved intent","status":"active"}}
			assert(market_adapter.seller_journal.save_pending(operation,saved))
			close_ui()
			market_views.clear()
			compose_ui()
			assert((await market_adapter.open()).ok)
			await wait_for(func()->bool:return not market_views.is_empty() and market_views.back().sellerPending and not market_views.back().sellerBusy)
			assert(map.currency_map.market_endpoint.state.name!="Explicit saved intent" and market_adapter.seller_journal.load_pending().entry.id==operation)
			assert((await command("market.retry_seller",{})).ok)
			assert(map.currency_map.market_endpoint.state.name=="Explicit saved intent")
		"seller-lost-process":
			var claim: Dictionary=map.currency_map.market_endpoint.state.claims.filter(func(row: Dictionary)->bool:return row.uid==str(payload.uid))[0]
			map.currency_map.market_endpoint.operation_finished.disconnect(session.finish)
			result=await command("market.claim",{"command_id":"browser-claim","uid":claim.uid,"revision":claim.revision})
			map.currency_map.market_endpoint.operation_finished.connect(session.finish)
		"seller-restored":
			await wait_for(func()->bool:return market_adapter.seller_journal.load_pending().entry.is_empty())
			assert((await market_adapter.open()).ok and map.currency_map.market_endpoint.state.claims.is_empty())
			assert(map.endpoint.state.items.any(func(row: Dictionary)->bool:return row.uid==str(payload.uid)))
		"ground-restored":
			assert(map.endpoint.state.items.size()==3 and map.endpoint.state.items.any(func(row: Dictionary) -> bool: return row.uid==str(payload.uid) and row.amount==4))
			assert(map.endpoint.state.storage.items.size()==1)
		"ground-pickup":
			var feedback: Array=[]
			var receive:=func(value: Dictionary) -> void: feedback.append(value)
			map.currency_map.combat_endpoint.feedback_received.connect(receive)
			map.currency_map.combat_endpoint.request_pickup.rpc_id(1,str(payload.uid))
			await wait_for(func() -> bool: return not feedback.is_empty())
			map.currency_map.combat_endpoint.feedback_received.disconnect(receive)
			result=feedback.back()
			await get_tree().create_timer(0.12).timeout
		"storage-flow":
			var target: Dictionary=map.endpoint.state.items.filter(func(row: Dictionary) -> bool: return row.location=="bag" and row.definition_id=="iron_sword")[0]
			var move: Dictionary={"id":target.uid,"revision":target.revision,"from":"inventory","to":"storage","x":0,"y":0,"page":0,"quick":false}
			map.endpoint.operation_finished.disconnect(session.finish)
			assert((await command("storage.transfer",move)).error=="storage_pending")
			map.endpoint.operation_finished.connect(session.finish)
			assert(map.endpoint.state.storage.items.size()==1)
			bridge.reset_transport()
			bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
			assert(ui_snapshots.back().storage.recoveryPending)
			assert((await command("storage.retry",{})).ok,"retry does not depend on original item still being in bag")
			target=map.endpoint.state.storage.items[0]
			move.merge({"revision":target.revision,"from":"storage","x":3},true)
			assert((await command("storage.transfer",move)).ok)
			target=map.endpoint.state.storage.items[0]
			move.merge({"revision":target.revision,"to":"inventory","quick":true},true)
			assert((await command("storage.transfer",move)).ok)
			assert(map.endpoint.state.storage.items.is_empty())
		"storage-lost-process":
			var target: Dictionary=map.endpoint.state.items.filter(func(row: Dictionary) -> bool: return row.location=="bag" and row.definition_id=="iron_sword")[0]
			map.endpoint.operation_finished.disconnect(session.finish)
			result=await command("storage.transfer",{"id":target.uid,"revision":target.revision,"from":"inventory","to":"storage","x":0,"y":0,"page":0,"quick":false})
			map.endpoint.operation_finished.connect(session.finish)
			assert(not storage_adapter.journal.load_pending().entry.is_empty())
		"storage-restored":
			await wait_for(func() -> bool: return storage_adapter.journal.load_pending().entry.is_empty())
			assert(map.endpoint.state.storage.items.size()==1 and map.endpoint.state.items.size()==2)
		"storage-private": assert(map.endpoint.state.storage.items.is_empty())
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
		"craft-lost":
			var currency: Dictionary=map.endpoint.state.items.filter(func(i: Dictionary)->bool:return i.uid==payload.currency)[0]
			assert((await command("item.activate",{"id":currency.uid,"revision":currency.revision})).ok)
			map.endpoint.operation_finished.disconnect(session.finish)
			result=await command("craft.execute",{"id":payload.target,"revision":0})
			map.endpoint.operation_finished.connect(session.finish)
			assert(not craft_adapter.journal.load_pending().entry.is_empty())
		"craft-restored":
			await wait_for(func()->bool:return craft_adapter.journal.load_pending().entry.is_empty())
			var target: Dictionary=map.endpoint.state.items.filter(func(i: Dictionary)->bool:return i.uid==payload.target)[0]
			assert(target.rarity==payload.rarity and target.revision==1)
			# A journal entry saved before sending is discovered read-only.
			var id: String="craft-"+Crypto.new().generate_random_bytes(16).hex_encode()
			var currency: Dictionary=map.endpoint.state.items.filter(func(i: Dictionary)->bool:return i.uid==payload.currency)[0]
			assert(craft_adapter.journal.save_pending(id,{"uid":target.uid,"revision":target.revision,"currency_uid":currency.uid,"currency_revision":currency.revision}))
			close_ui();compose_ui()
			await get_tree().create_timer(0.4).timeout
			assert(craft_adapter.journal.load_pending().entry.id==id)
			# Explicit retry receives a definitive rarity/capacity rejection, consuming nothing.
			assert((await command("craft.retry",{})).error==payload.retry_error)
			assert(craft_adapter.journal.load_pending().entry.is_empty())
		"exit":
			map.report.rpc_id(1,label,result)
			await get_tree().create_timer(0.1).timeout
			close_ui()
			wire.peer.close()
			print("POSTGRES_INVENTORY_ENDPOINT_CLIENT_OK")
			get_tree().quit()
			return
	map.report.rpc_id(1,label,result)
