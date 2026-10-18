extends Node
const Schema = preload("res://source/server/world/database/postgres/inventory_session_schema_postgres.gd")
const Executor = preload("res://source/server/world/database/postgres/inventory_executor_postgres.gd")
const Runtime = preload("res://source/server/world/database/postgres/wallet_runtime_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const Batch = preload("res://source/server/world/database/postgres/wallet_session_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
var pg: Object
var executor: RefCounted
var runtime: RefCounted
var world:=FixtureWorld.new()
var ticks: int=0
var failures: Array[String]=[]
var spends: Array[Dictionary]=[]
var auto_poll:=true

class OpenWorld extends GameWorld3D:
	func has_line_of_sight(_from: Vector3, _to: Vector3) -> bool: return true

## Transport/peer maps are controlled here; production never bypasses this gate.
## Native session admission/transport is covered by inventory-session-bridge.
class FixtureWorld extends WorldServer:
	func inventory_master_available() -> bool: return true

## Boundary fault only: the real native transaction commits, its successful
## completion is lost. No fake database, SQL outcome or wallet implementation.
class LostCompletion extends RefCounted:
	var inner: RefCounted
	var lose_next:=false
	func _init(value: RefCounted) -> void: inner=value
	func submit_wallet_snapshot(context: Dictionary) -> Dictionary: return inner.submit_wallet_snapshot(context)
	func submit_wallet_batch(context: Dictionary, issuer: int, id: String, income: int, cost: int) -> Dictionary: return inner.submit_wallet_batch(context,issuer,id,income,cost)
	func begin_drain() -> void: inner.begin_drain()
	func is_stopped() -> bool: return inner.is_stopped()
	func poll() -> Array:
		var events: Array=inner.poll()
		for event: Dictionary in events:
			if lose_next and event.intent=="wallet_batch" and event.result.get("ok",false):
				lose_next=false
				event.result={"ok":false,"error":"outcome_unknown","outcome_unknown":true}
		return events

func _physics_process(_delta: float) -> void: ticks+=1
func _process(delta: float) -> void:
	if runtime!=null and auto_poll: runtime.poll(delta)

func wait_until(predicate: Callable) -> void:
	var deadline: int=Time.get_ticks_msec()+8000
	while not predicate.call() and Time.get_ticks_msec()<deadline: await get_tree().process_frame
	assert(predicate.call(),"bounded native wallet wait")

func bind(peer: int, character: int, token: String) -> void:
	var player:=PlayerResource.new()
	player.player_id=character
	player.current_peer_id=peer
	world.connected_players[peer]=player
	world.player_id_to_peer_id[character]=peer
	world._session_tokens[peer]=token

func grant(account: int, character: int, token: String, epoch: int) -> Dictionary:
	var result: Dictionary=Sessions.new(pg).install_verified_grant(Sessions.identity_from_verified_ticket(account,character,token),epoch)
	assert(result.ok,str(result))
	return result.context

func balance(account: int) -> int: return int(Wallet.new(pg).load_wallet(account).balance)
func receipts(account: int) -> int: return int(pg.query("SELECT COUNT(*) AS n FROM economy.market_commands WHERE account_id=:account AND kind='wallet_batch';",{"account":account}).rows[0].n)

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var connection: String=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	for account: int in [9700,9701,9702]:
		assert(Wallet.new(pg).initialize_account(account).ok)
		assert(Items.new(pg).bind_character(account*10,account) and Items.new(pg).bind_character(account*10+1,account))
	assert(pg.execute("UPDATE economy.account_wallets SET yang=CASE WHEN account_id=9700 THEN 40000 ELSE 1000 END;").ok)
	assert(pg.execute("UPDATE economy.account_wallets SET yang=40000 WHERE account_id=9702;").ok)
	var spend_context:=grant(9702,97020,"wallet-cost",0)
	assert(Batch.new(pg).batch(spend_context,97020,"pending-affords-spend",30000,50000).ok and balance(9702)==20000,"pending prefix funds a cost greater than the DB balance")
	assert(Batch.new(pg).batch(spend_context,97020,"pending-affords-spend",30000,50000).ok and balance(9702)==20000)
	assert(pg.execute("UPDATE economy.account_wallets SET reserved_yang=19990 WHERE account_id=9702;").ok)
	assert(Batch.new(pg).batch(spend_context,97020,"reserved-funds",0,50).error=="funds" and balance(9702)==20000 and receipts(9702)==1)
	var a:=grant(9700,97000,"wallet-A",0)
	var b:=grant(9701,97010,"wallet-B",0)
	bind(100,97000,"wallet-A")
	bind(200,97010,"wallet-B")
	executor=Executor.new()
	assert(executor.start(connection,2,2))
	var boundary:=LostCompletion.new(executor)
	runtime=Runtime.new(world,boundary)
	runtime.failed.connect(func(_account: int, reason: String) -> void: failures.append(reason))
	runtime.spend_finished.connect(func(peer: int, id: String, result: Dictionary) -> void: spends.append({"peer":peer,"id":id,"result":result}))
	await wait_until(func() -> bool: return executor.is_ready())
	assert(runtime.attach(100,a) and runtime.attach(200,b))
	await wait_until(func() -> bool: return runtime.ready(100) and runtime.ready(200))
	var disconnected_world:=WorldServer.new()
	disconnected_world.wallet_runtime=runtime
	disconnected_world.token_list["unspent"]={"account":"fixture"}
	disconnected_world._pending_admissions[999]={"account":"fixture"}
	assert(not disconnected_world.inventory_master_available(),"wallet-only configuration also fails closed without Master")
	disconnected_world.invalidate_inventory_admissions()
	assert(disconnected_world.token_list.is_empty() and disconnected_world._pending_admissions.is_empty())
	disconnected_world.free()
	# Exercise the existing authoritative ground-currency endpoint and services,
	# not a second pickup implementation. Geometry/peer maps are fixture supplied.
	var previous: WorldServer=WorldServer.curr
	WorldServer.curr=world
	world.wallet_runtime=runtime
	var legacy_database:=WorldDatabase.new()
	world.database=legacy_database # No SQLite writer is provisioned in this fixture.
	var arena:=OpenWorld.new()
	var currency:=CurrencyEndpoint3D.new()
	currency.services=arena.services
	currency._world=arena
	arena.combat_endpoint=CombatEndpoint3D.new()
	arena.combat_endpoint._world=arena
	var body:=PlayerActor3D.new()
	body.alive=true
	body.hp=100
	arena.characters[100]=body
	for index: int in 20:
		var drop: int=currency.spawn_currency(Vector3.ZERO,97000,"A",0)
		assert(currency.pickup_for_peer(100,drop,1).ok)
		assert(currency.pickup_for_peer(100,drop,1).error=="gone")
	assert(balance(9700)==40000 and receipts(9700)==0 and runtime.snapshot(100).balance==40600,"20 pickups are RAM income, no per-drop receipts/writes")
	assert(runtime.attach(100,a) and runtime.snapshot(100).balance==40600)
	# A locked checkpoint cannot freeze simulation or an independent wallet.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9700 FOR NO KEY UPDATE;").ok)
	runtime.poll(Runtime.SAVE_SECONDS)
	legacy_database._process(30.0)
	assert(runtime.add_income(100,90),"income arriving after captured prefix")
	assert(runtime.add_income(200,100) and not runtime.checkpoint(200))
	var before: int=ticks
	await wait_until(func() -> bool: return runtime.ready(200) and balance(9701)==1100)
	assert(ticks>before and balance(9700)==40000)
	assert(pg.commit())
	await wait_until(func() -> bool: return runtime.ready(100) and balance(9700)==40600)
	assert(runtime.snapshot(100).balance==40690 and receipts(9700)==1,"ACK consumes only its captured prefix; later income remains dirty")
	assert(not runtime.checkpoint(100))
	await wait_until(func() -> bool: return runtime.ready(100) and balance(9700)==40690)
	assert(runtime.checkpoint(100))
	await get_tree().process_frame
	# Existing test spend consumes pending income atomically; no stale DB funds.
	assert(runtime.add_income(100,30000))
	var spend: Dictionary=runtime.test_spend(100)
	assert(spend.queued and not runtime.test_spend(100).queued)
	await wait_until(func() -> bool: return runtime.ready(100) and not spends.is_empty())
	assert(balance(9700)==70640 and runtime.snapshot(100).balance==70640 and spends.back().result.spent==50)
	assert(Batch.new(pg).batch(a,97000,spend.operation_id,30000,50).ok and balance(9700)==70640)
	assert(Batch.new(pg).batch(a,97000,spend.operation_id,30001,50).error=="command_conflict" and balance(9700)==70640)
	# A reservation committed after the RAM affordability check rejects the
	# whole spend. It refreshes instead of retaining an unresolvable debit.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9701 FOR NO KEY UPDATE;").ok)
	assert(runtime.test_spend(200).queued)
	runtime.poll()
	assert(pg.execute("UPDATE economy.account_wallets SET reserved_yang=1090 WHERE account_id=9701;").ok and pg.commit())
	await wait_until(func() -> bool: return runtime.ready(200) and spends.back().peer==200)
	assert(spends.back().result.error=="funds" and balance(9701)==1100 and receipts(9701)==1)
	assert(runtime.add_income(200,100))
	boundary.lose_next=true
	assert(runtime.test_spend(200).queued)
	await wait_until(func() -> bool: return spends.back().result.get("pending",false))
	assert(balance(9701)==1150 and runtime.snapshot(200).is_empty())
	assert(runtime.retry(200))
	await wait_until(func() -> bool: return runtime.ready(200))
	assert(balance(9701)==1150 and receipts(9701)==2 and spends.back().result.ok)
	# Native COMMIT succeeded but completion was lost. Retry after same-account
	# alt login keeps original issuer/body and must not add the income twice.
	assert(runtime.add_income(100,42))
	boundary.lose_next=true
	runtime.checkpoint(100)
	var unknown_count: int=failures.size()
	await wait_until(func() -> bool: return failures.size()>unknown_count)
	assert(balance(9700)==70682 and runtime.snapshot(100).is_empty() and not runtime.drained())
	assert(runtime.attach(100,a) and runtime.snapshot(100).is_empty(),"duplicate attach preserves uncertain work")
	var count: int=receipts(9700)
	var alt:=grant(9700,97001,"wallet-alt",1)
	bind(101,97001,"wallet-alt")
	assert(runtime.attach(101,alt))
	assert(runtime.snapshot(101).is_empty(),"replacement cannot publish an unconfirmed old wallet projection")
	await wait_until(func() -> bool: return runtime.ready(101))
	assert(runtime.snapshot(101).balance==70682 and balance(9700)==70682 and receipts(9700)==count and not runtime.ready(100))
	runtime.detach(100) # Late disconnect from the replaced character/peer.
	assert(runtime.ready(101) and runtime.snapshot(101).balance==70682)
	assert(Batch.new(pg).batch(a,97000,"stale-wallet",100,0).error=="stale_session")
	# Real deferred COMMIT failure rolls back income and receipt. A fresh worker
	# connection plus explicit same-ID retry recovers without blind COMMIT retry.
	assert(pg.execute("CREATE FUNCTION economy.fixture_wallet_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'wallet commit fixture' USING ERRCODE='40001'; END; $$;").ok)
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_wallet_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_wallet_commit();").ok)
	assert(runtime.add_income(101,18))
	runtime.checkpoint(101)
	var errors: int=failures.size()
	await wait_until(func() -> bool: return failures.size()>errors)
	assert(failures.back()=="outcome_unknown" and balance(9700)==70682 and receipts(9700)==count and not runtime.drained())
	assert(pg.execute("DROP TRIGGER fixture_wallet_commit ON economy.market_commands;").ok)
	runtime.poll(Runtime.SAVE_SECONDS) # Scheduled same-ID retry after rollback.
	await wait_until(func() -> bool: return runtime.ready(101))
	assert(balance(9700)==70700 and receipts(9700)==count+1)
	# Disconnect retains dirty income even if revocation wins before the batch.
	assert(runtime.add_income(101,25))
	runtime.detach(101)
	assert(Sessions.new(pg).revoke(alt).ok)
	errors=failures.size()
	await wait_until(func() -> bool: return failures.size()>errors)
	assert(balance(9700)==70700 and not runtime.drained())
	var relog:=grant(9700,97000,"wallet-relog",2)
	bind(102,97000,"wallet-relog")
	assert(runtime.attach(102,relog))
	await wait_until(func() -> bool: return runtime.ready(102))
	assert(balance(9700)==70725 and runtime.snapshot(102).balance==70725)
	assert(not runtime.add_income(102,Wallet.MAX_YANG) and runtime.snapshot(102).balance==70725)
	# Forced save/drain blocks new income and joins only after SQL is settled.
	assert(runtime.add_income(102,75))
	add_child(world)
	world.set_process(false) # This fixture already owns polling above.
	assert(await world.flush_postgres_wallets(true))
	assert(runtime.drained() and not runtime.add_income(102,1) and balance(9700)==70800)
	WorldServer.curr=previous
	world.wallet_runtime=null
	runtime=null
	executor.begin_drain()
	await wait_until(func() -> bool:
		executor.poll()
		return executor.is_stopped())
	# Recreated RAM owner starts from current durable state, never regrants income.
	assert(executor.start(connection,1,1))
	await wait_until(func() -> bool:
		executor.poll()
		return executor.is_ready())
	runtime=Runtime.new(world,executor)
	assert(runtime.attach(102,relog))
	await wait_until(func() -> bool: return runtime.ready(102))
	assert(runtime.snapshot(102).balance==70800)
	runtime=null
	executor.begin_drain()
	await wait_until(func() -> bool:
		executor.poll()
		return executor.is_stopped())
	body.free()
	arena.combat_endpoint.free()
	currency.free()
	arena.free()
	world.free()
	legacy_database.free()
	pg.close()
	print("POSTGRES_WALLET_RUNTIME_OK RAM pickups, bounded async checkpoint/prefix, atomic spend, lost completion/COMMIT recovery, alt/logout fencing and clean drain/reload")
	get_tree().quit()
