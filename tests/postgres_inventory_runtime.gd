extends Node
## Real PostgreSQL + production World combat projection, with authenticated
## World peer maps seeded explicitly. Not a real Master/Gateway login fixture.
const Schema = preload("res://source/server/world/database/postgres/inventory_session_schema_postgres.gd")
const Executor = preload("res://source/server/world/database/postgres/inventory_executor_postgres.gd")
const Runtime = preload("res://source/server/world/database/postgres/inventory_runtime_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Intents = preload("res://source/server/world/database/postgres/inventory_intent_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
var pg: Object
var executor: RefCounted
var runtime: RefCounted
var world:=WorldServer.new()
var physics_ticks: int=0
var snapshots: Array[Dictionary]=[]
var finished: Array[Dictionary]=[]
var admitted: Array[String]=[]
var failures: Array[String]=[]
var change_after_snapshot:=false

func _physics_process(_delta: float) -> void: physics_ticks+=1

func wait_until(predicate: Callable, poll_runtime: bool = true) -> void:
	var deadline: int=Time.get_ticks_msec()+8000
	while not predicate.call() and Time.get_ticks_msec()<deadline:
		if poll_runtime: runtime.poll()
		await get_tree().process_frame
	assert(predicate.call(),"bounded native runtime fixture wait")

func seed_item(account: int, character: int) -> ItemInstance:
	assert(Wallet.new(pg).initialize_account(account).ok and Items.new(pg).bind_character(character,account))
	var item:=ItemInstance.create(ItemDefinitions.IRON_SWORD,character,[])
	assert(pg.begin() and Items.new(pg).receive_item_in_transaction(item,0).ok and pg.commit())
	return item

func bind_peer(peer: int, character: int, token: String) -> void:
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

func native_state(character: int) -> Dictionary:
	var result: Dictionary=Items.new(pg).inventory(character)
	assert(result.ok)
	return result

func receipt_count(operation: String) -> int:
	return int(pg.query("SELECT COUNT(*) AS n FROM economy.market_commands WHERE command_id=:id;",{"id":operation}).rows[0].n)

func verify_projection(character: int) -> void:
	var snapshot:=native_state(character)
	assert(world.runtime_equipment[character].equipment==snapshot.equipment)
	assert(world.runtime_equipment[character].stats==snapshot.stats)
	assert(world.runtime_equipment[character].item_state==snapshot.item_state)
	assert(world.runtime_attack(character)==int(snapshot.stats.attack))

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var connection: String=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	var sword:=seed_item(9400,94000)
	var other:=seed_item(9401,94010)
	# Recovery must scan past historical terminal pages to find later pending work.
	for index: int in Runtime.PAGE_SIZE+1:
		var history: String="history-"+str(index)
		assert(Intents.new(pg).admit(94000,history,"move",sword.uid,0,0).state=="pending")
		assert(Intents.new(pg).execute(94000,history).state=="committed")
	# Work admitted by a previous owner must finish BEFORE runtime becomes ready.
	assert(Intents.new(pg).admit(94000,"before-runtime","equip",sword.uid,0,-1).state=="pending")
	var a:=grant(9400,94000,"verified-A",0)
	var b:=grant(9401,94010,"verified-B",0)
	bind_peer(100,94000,"verified-A")
	bind_peer(200,94010,"verified-B")
	assert(world.session_ticket_fingerprint(999,94000).is_empty())
	assert(world.session_ticket_fingerprint(100,94010).is_empty())
	executor=Executor.new()
	assert(executor.start(connection,2,2))
	runtime=Runtime.new(world,executor)
	runtime.snapshot_applied.connect(func(peer: int, snapshot: Dictionary) -> void:
		snapshots.append({"peer":peer,"state":snapshot.duplicate(true)})
		assert(not runtime.mutations_allowed(peer),"apply/reconcile before opening dependent actions")
		if change_after_snapshot:
			change_after_snapshot=false
			# A different economic source commits between hydration and readiness.
			# The next acknowledgement must reject this now-stale marker.
			var material:=ItemInstance.create(ItemDefinitions.UPGRADE_ORE,94000,[])
			assert(pg.begin() and Items.new(pg).receive_item_in_transaction(material,30).ok and pg.commit()))
	runtime.operation_admitted.connect(func(_peer: int, id: String) -> void: admitted.append(id))
	runtime.operation_finished.connect(func(peer: int, id: String, result: Dictionary) -> void:
		assert(runtime.mutations_allowed(peer))
		verify_projection(world.connected_players[peer].player_id)
		finished.append({"peer":peer,"id":id,"result":result.duplicate(true)}))
	runtime.recovery_failed.connect(func(_peer: int, reason: String) -> void: failures.append(reason))
	# Startup is asynchronous. The owner waits for pool readiness before handing
	# its exclusive polling responsibility to the runtime delivery component.
	while not executor.is_ready():
		executor.poll()
		await get_tree().process_frame
	assert(not runtime.attach(999,a))
	var forged:=a.duplicate(true)
	forged.session_fingerprint="0".repeat(64)
	assert(not runtime.attach(100,forged))
	assert(runtime.attach(100,a) and runtime.attach(200,b))
	assert(not runtime.mutations_allowed(100))
	await wait_until(func() -> bool: return runtime.mutations_allowed(100) and runtime.mutations_allowed(200))
	verify_projection(94000)
	assert(not world.runtime_equipment[94000].equipment.is_empty())
	assert(receipt_count("before-runtime")==1)
	# One account blocked in real SQL must not freeze World physics, another
	# account's Inventory or the main-thread delivery owner.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9400 FOR NO KEY UPDATE;").ok)
	assert(runtime.submit(100,"unequip","unequip",sword.uid,1,-1).queued)
	assert(runtime.submit(200,"other-equip","equip",other.uid,0,-1).queued)
	var before: int=physics_ticks
	await wait_until(func() -> bool: return finished.any(func(row: Dictionary) -> bool: return row.id=="other-equip"))
	assert(physics_ticks>before and not runtime.mutations_allowed(100))
	assert(not finished.any(func(row: Dictionary) -> bool: return row.id=="unequip"))
	assert(pg.commit())
	await wait_until(func() -> bool: return runtime.mutations_allowed(100))
	verify_projection(94000)
	assert(world.runtime_equipment[94000].equipment.is_empty())
	assert(runtime.submit(100,"overlap-a","equip",sword.uid,2,-1).queued)
	assert(runtime.submit(100,"overlap-b","equip",sword.uid,2,-1).error=="recovery_required")
	await wait_until(func() -> bool: return runtime.mutations_allowed(100))
	assert(receipt_count("overlap-b")==0)
	# Restore the test sword for the rejection/lost-delivery scenarios below.
	assert(runtime.submit(100,"restore-bag","unequip",sword.uid,3,-1).queued)
	await wait_until(func() -> bool: return runtime.mutations_allowed(100))
	# Durable rejection is delivered after authoritative repair, not reported as
	# a new commit and not reevaluated on original-ID replay.
	assert(runtime.submit(100,"stale-equip","equip",sword.uid,0,-1).queued)
	await wait_until(func() -> bool: return runtime.mutations_allowed(100))
	assert(finished.back().id=="stale-equip" and finished.back().result.error=="stale")
	assert(runtime.submit(100,"stale-equip","equip",sword.uid,0,-1).queued)
	await wait_until(func() -> bool: return runtime.mutations_allowed(100))
	assert(finished.back().result.error=="stale" and receipt_count("stale-equip")==1)
	# Lose interest after durable admission but before receiving the native
	# execution result. Replacement must recover it without any new command ID.
	assert(runtime.submit(100,"late-equip","equip",sword.uid,4,-1).queued)
	await wait_until(func() -> bool: return admitted.has("late-equip"))
	await wait_until(func() -> bool: return receipt_count("late-equip")==1,false)
	var delivered: int=snapshots.size()
	var c:=grant(9400,94000,"verified-C",1)
	bind_peer(101,94000,"verified-C")
	assert(runtime.attach(101,c))
	runtime.detach(100) # Late disconnect must not erase the replacement binding.
	assert(not runtime.mutations_allowed(100) and not runtime.mutations_allowed(101))
	await wait_until(func() -> bool: return runtime.mutations_allowed(101))
	assert(not finished.any(func(row: Dictionary) -> bool: return row.id=="late-equip"))
	for row: Dictionary in snapshots.slice(delivered): assert(row.peer!=100)
	assert(receipt_count("late-equip")==1)
	verify_projection(94000)
	# Failed mutation COMMIT remains pending, does not announce terminal success
	# or auto-retry. Explicit recovery reuses the original durable identity.
	assert(pg.execute("CREATE SEQUENCE economy.fixture_runtime_attempt;").ok)
	assert(pg.execute("CREATE FUNCTION economy.fixture_runtime_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM nextval('economy.fixture_runtime_attempt'); RAISE EXCEPTION 'runtime commit fixture' USING ERRCODE='40001'; END; $$;").ok)
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_runtime_commit();").ok)
	assert(runtime.submit(101,"uncertain-unequip","unequip",sword.uid,5,-1).queued)
	await wait_until(func() -> bool: return runtime.status(101)=="paused")
	assert(failures.back()=="outcome_unknown" and receipt_count("uncertain-unequip")==0)
	assert(pg.query("SELECT last_value FROM economy.fixture_runtime_attempt;").rows[0].last_value==1)
	assert(not finished.any(func(row: Dictionary) -> bool: return row.id=="uncertain-unequip"))
	assert(Intents.new(pg).outcome(94000,"uncertain-unequip").state=="pending")
	assert(pg.execute("DROP TRIGGER fixture_commit ON economy.market_commands;").ok)
	assert(runtime.retry(101))
	await wait_until(func() -> bool: return runtime.mutations_allowed(101))
	assert(finished.back().id=="uncertain-unequip" and finished.back().result.ok and receipt_count("uncertain-unequip")==1)
	verify_projection(94000)
	# Uncertain admission may have left NO durable row. Explicit retry first
	# discovers that outcome, then resubmits the original ID/body (never a new ID).
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_admission AFTER INSERT ON economy.inventory_intents DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_runtime_commit();").ok)
	assert(runtime.submit(101,"uncertain-admission","equip",sword.uid,6,-1).queued)
	await wait_until(func() -> bool: return runtime.status(101)=="paused")
	assert(failures.back()=="outcome_unknown" and not admitted.has("uncertain-admission"))
	assert(Intents.new(pg).outcome(94000,"uncertain-admission").error=="unknown_command")
	assert(pg.query("SELECT last_value FROM economy.fixture_runtime_attempt;").rows[0].last_value==2)
	assert(pg.execute("DROP TRIGGER fixture_admission ON economy.inventory_intents;").ok)
	assert(runtime.retry(101))
	await wait_until(func() -> bool: return runtime.mutations_allowed(101))
	assert(finished.back().id=="uncertain-admission" and finished.back().result.ok and receipt_count("uncertain-admission")==1)
	verify_projection(94000)
	change_after_snapshot=true
	delivered=snapshots.size()
	assert(runtime.attach(101,c))
	await wait_until(func() -> bool: return runtime.mutations_allowed(101))
	assert(snapshots.size()>=delivered+2 and not change_after_snapshot)
	verify_projection(94000)
	# Disconnect before a snapshot delivery must not rehydrate or notify the
	# retired session. Recreate the delivery owner and recover from PostgreSQL.
	runtime.detach(101)
	assert(runtime.attach(101,c))
	runtime.poll()
	world.connected_players[101].current_peer_id=0
	delivered=snapshots.size()
	await wait_until(func() -> bool: return runtime.status(101)=="detached")
	assert(snapshots.size()==delivered)
	executor.begin_drain()
	await wait_until(func() -> bool: return executor.is_stopped())
	assert(executor.start(connection,2,2))
	while not executor.is_ready():
		executor.poll()
		await get_tree().process_frame
	runtime=Runtime.new(world,executor)
	bind_peer(102,94000,"verified-C")
	assert(runtime.attach(102,c))
	await wait_until(func() -> bool: return runtime.mutations_allowed(102))
	verify_projection(94000)
	executor.begin_drain()
	await wait_until(func() -> bool: return executor.is_stopped())
	pg.close()
	world.free()
	print("POSTGRES_INVENTORY_RUNTIME_OK account recovery, World combat projection, stale delivery fencing, physics during SQL, terminal repair and explicit same-ID recovery")
	get_tree().quit()
