extends Node
const Bootstrap = preload("res://source/server/world/database/postgres/economy_bootstrap_postgres.gd")
const Settings = preload("res://source/server/world/database/postgres/economy_bootstrap_settings.gd")
const Schema = preload("res://source/server/world/database/postgres/economy_schema_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
var pg: Object
var worlds: Array=[]
var ticks:=0
class LostMarketResult extends RefCounted:
	var inner: RefCounted
	var lost:=false
	func _init(pool: RefCounted) -> void: inner=pool
	func submit_seller(context: Dictionary, action: String, body: Dictionary, income: int = 0, token: String = "", captures: Dictionary = {}, participants: Array = []) -> Dictionary: return inner.submit_seller(context,action,body,income,token,captures,participants)
	func submit_seller_snapshot(context: Dictionary, exchange: bool = false) -> Dictionary: return inner.submit_seller_snapshot(context,exchange)
	func submit_seller_receipt(context: Dictionary, id: String) -> Dictionary: return inner.submit_seller_receipt(context,id)
	func is_stopped() -> bool: return inner.is_stopped()
	func begin_drain() -> void: inner.begin_drain()
	func poll() -> Array:
		var events: Array=inner.poll()
		for event: Dictionary in events:
			if not lost and event.intent=="seller_execute" and event.result.get("ok",false):
				lost=true;event.result={"ok":false,"error":"outcome_unknown"};event.committed=false
		return events
class FixtureWorld extends WorldServer:
	func inventory_master_available() -> bool: return economy_bootstrap!=null and economy_bootstrap.sessions_valid()
class FixtureMaster extends WorldManagerServer:
	func _ready() -> void: pass
func _physics_process(_delta: float) -> void: ticks+=1
func wait_for(predicate: Callable) -> void:
	var deadline:=Time.get_ticks_msec()+8000
	while not predicate.call() and Time.get_ticks_msec()<deadline: await get_tree().process_frame
	assert(predicate.call(),"bounded bootstrap fixture wait")
func make_world() -> FixtureWorld:
	var world:=FixtureWorld.new()
	world.database=WorldDatabase.new()
	add_child(world);world.add_child(world.database)
	worlds.append(world)
	return world
func refused(settings: Dictionary, reason: String) -> void:
	var world:=make_world()
	var owner:=Bootstrap.new()
	assert(not await owner.start_world(world,settings))
	assert(owner.status().state=="FAILED" and owner.status().stopped and owner.status().error==reason)
	assert(world.inventory_runtime==null and world.wallet_runtime==null and world.seller_runtime==null)
	assert(world.database.economy_backend=="postgresql" and not world.database.wallet_ready)
	assert(not world.inventory_master_available() and not MandateWorldServices.new().available())
	assert(not world.database.load_wallet(1) and not world.database.credit_account(1,1).ok)
	assert(not world.database.market_command(1,"open",{}).ok)
	assert(not world.database.prepare_account_wallets({}).ok)
	assert(await owner.shutdown_world(),"failed/closed startup permits ordinary process exit")
func _ready() -> void:
	Engine.max_fps=120
	get_tree().create_timer(55).timeout.connect(func()->void:get_tree().quit(1))
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	assert(Settings.resolve({}).backend=="sqlite")
	assert(not Settings.resolve({"backend":"postgres"}).ok)
	var config: Dictionary={"backend":"postgresql","connection_env":"MANDATE_PG_FIXTURE_CONNECTION","authority_id":"f".repeat(32)}
	var missing:=config.duplicate();missing.connection_env="MANDATE_PG_BOOTSTRAP_MISSING"
	await refused(missing,"connection_missing")
	var invalid:=config.duplicate();invalid.queue_capacity=100
	await refused(invalid,"capacity")
	pg=ClassDB.instantiate("GodotSociDatabase")
	var connection: String=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	assert(pg.open("postgresql",connection))
	await refused(config,"schema")
	assert(pg.query("SELECT to_regclass('economy.schema_versions')::text AS name;").rows[0].name==null,"Startup must not provision schema")
	OS.set_environment("MANDATE_ECONOMY_CONNECTION",connection)
	OS.set_environment("MANDATE_PG_PROVISION","1")
	var output: Array=[]
	var code:=OS.execute(OS.get_executable_path(),["--headless","--path",ProjectSettings.globalize_path("res://"),"--mode=world-server","--script","res://tools/postgres/provision_economy.gd"],output,true,false)
	OS.unset_environment("MANDATE_ECONOMY_CONNECTION");OS.unset_environment("MANDATE_PG_PROVISION")
	assert(code==0 and "POSTGRES_ECONOMY_PROVISIONED" in str(output))
	assert(Schema.ensure_schema(pg))
	var authority: String=str(pg.query("SELECT value FROM economy.meta WHERE key='economy_authority_id';").rows[0].value)
	await refused(config,"authority")
	config.authority_id=authority
	assert(pg.execute("UPDATE economy.schema_versions SET version=999 WHERE feature='inventory';").ok)
	await refused(config,"schema")
	assert(pg.execute("UPDATE economy.schema_versions SET version=1 WHERE feature='inventory';").ok)
	await refused(config,"profiles")
	var profile_config:=config.duplicate();profile_config.profile_id="e".repeat(32)
	await refused(profile_config,"profiles")
	assert(pg.query("SELECT value FROM economy.meta WHERE key='world_profile_id';").rows.is_empty(),"missing profiles cannot claim the PG realm")
	# Real connection exhaustion after a successful preflight closes every pool.
	var pressure: Array=[]
	for index: int in 2:
		var held: Object=ClassDB.instantiate("GodotSociDatabase")
		assert(held.open("postgresql",connection));pressure.append(held)
	await refused(config,"workers")
	for held: Object in pressure: held.close()
	assert(int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name LIKE 'mandate-inventory-executor-%';").rows[0].n)==0)
	var master:=FixtureMaster.new();add_child(master)
	var master_owner:=Bootstrap.new()
	assert(await master_owner.start_master(master,config) and master.inventory_session_issuer!=null)
	assert(await master_owner.shutdown_master() and master_owner.status().stopped)
	var world:=make_world()
	world.database.db=SQLite.new()
	world.database.db.path=OS.get_environment("MANDATE_PG_FIXTURE_DIR")+"/bootstrap-profile.db"
	assert(world.database.db.open_db())
	WorldSchema.ensure_schema(world.database.db)
	world.database.store=WorldStoreSqlite.new(world.database.db)
	var owner:=Bootstrap.new()
	var before: int=ticks
	assert(await owner.start_world(world,config) and ticks>=before)
	assert(owner.ready() and owner.status().workers==8 and world.database.wallet_ready)
	assert(world.inventory_runtime!=null and world.wallet_runtime!=null and world.npc_runtime!=null and world.storage_runtime!=null and world.ground_item_runtime!=null and world.seller_runtime.auction!=null)
	assert(not await Bootstrap.new().start_world(world,config) and owner.ready())
	assert(not JSON.stringify(owner.status()).contains(connection))
	assert(world.database.store.bind_account_identity("bootstrap",9700,true))
	var profile: int=world.database.create_player_character("bootstrap",{"name":"Bootstrap","skin":1})
	assert(profile>0 and world.database.store.get_player(profile).inventory.is_empty())
	assert(world.database.db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='account_wallets';") and world.database.db.query_result.is_empty())
	var saved_profile:=world.database.get_player_resource(profile)
	saved_profile.experience=40
	world.database.mark_progression_dirty(saved_profile)
	assert(world.database.flush_progression() and world.database.store.get_player(profile).experience==40)
	# Normal wallet checkpoint must settle before the owner releases all workers.
	assert(Wallet.new(pg).initialize_account(9700).ok and Items.new(pg).bind_character(profile,9700))
	var identity:=Sessions.identity_from_verified_ticket(9700,profile,"bootstrap-session")
	var grant:=Sessions.new(pg).install_verified_grant(identity,0)
	assert(grant.ok)
	var player:=PlayerResource.new();player.player_id=profile;player.current_peer_id=100
	world.connected_players[100]=player;world.player_id_to_peer_id[profile]=100;world._session_tokens[100]="bootstrap-session"
	assert(world.inventory_runtime.attach(100,grant.context) and world.wallet_runtime.attach(100,grant.context))
	await wait_for(func()->bool:return world.inventory_runtime.mutations_allowed(100) and world.wallet_runtime.settled(100))
	assert(world.wallet_runtime.add_income(100,35))
	assert(pg.execute("INSERT INTO economy.account_shop_revenue(account_id,yang) VALUES(9700,100);").ok)
	var boundary:=LostMarketResult.new(owner._pools.market)
	world.seller_runtime._executor=boundary
	var unknown: Dictionary={}
	world.seller_runtime.finished.connect(func(_peer: int,_id: String,result: Dictionary)->void:
		if result.get("error","")=="outcome_unknown": unknown.merge(result))
	assert(world.seller_runtime.submit(100,"claim_revenue",{"command_id":"bootstrap-collect"}).queued)
	await wait_for(func()->bool:return not unknown.is_empty())
	# Read-only receipt recovery must retain the current delivery context during drain.
	assert(await owner.shutdown_world() and owner.status().stopped and not world.database.wallet_ready)
	assert(int(Wallet.new(pg).load_wallet(9700).balance)==1635)
	assert(not world.inventory_master_available() and not MandateWorldServices.new().available())
	assert(not world.database.prepare_account_wallets({}).ok,"Stopped PG cannot reactivate SQLite")
	assert(world.database.db.close_db())
	for instance: Node in worlds: instance.free()
	master.free();WorldServer.curr=null;pg.close()
	print("POSTGRES_BOOTSTRAP_OK preflight, no fallback, partial pool failure, Master/World composition and dirty wallet shutdown")
	get_tree().quit()
