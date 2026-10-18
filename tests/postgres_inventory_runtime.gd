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
var churn_snapshots: int=0
var committed_facts: int=0

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

func external_material() -> Dictionary:
	var material:=ItemInstance.create(ItemDefinitions.UPGRADE_ORE,94000,[])
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9400 FOR NO KEY UPDATE;").ok)
	assert(Items.new(pg).receive_item_in_transaction(material).ok and pg.commit())
	return native_state(94000).item_state

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
			external_material() # Deliberately missing publication: ACK detects it.
		if churn_snapshots>0:
			churn_snapshots-=1
			assert(runtime.invalidate_item_state(external_material())))
	runtime.operation_admitted.connect(func(_peer: int, id: String) -> void: admitted.append(id))
	runtime.operation_finished.connect(func(peer: int, id: String, result: Dictionary) -> void:
		assert(runtime.mutations_allowed(peer))
		verify_projection(world.connected_players[peer].player_id)
		finished.append({"peer":peer,"id":id,"result":result.duplicate(true)}))
	runtime.recovery_failed.connect(func(_peer: int, reason: String) -> void: failures.append(reason))
	runtime.inventory_committed.connect(func(_peer: int) -> void: committed_facts+=1)
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
	var initial_deliveries: int=snapshots.size()
	assert(runtime.attach(100,a) and runtime.mutations_allowed(100))
	assert(snapshots.size()==initial_deliveries,"duplicate attach of ready session does not restart hydration")
	# One account blocked in real SQL must not freeze World physics, another
	# account's Inventory or the main-thread delivery owner.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9400 FOR NO KEY UPDATE;").ok)
	assert(runtime.submit(100,"unequip","unequip",sword.uid,1,-1).queued)
	assert(runtime.submit(200,"other-equip","equip",other.uid,0,-1).queued)
	var before: int=physics_ticks
	await wait_until(func() -> bool: return finished.any(func(row: Dictionary) -> bool: return row.id=="other-equip"))
	assert(physics_ticks>before and not runtime.mutations_allowed(100))
	assert(not finished.any(func(row: Dictionary) -> bool: return row.id=="unequip"))
	assert(pg.execute("SELECT pg_stat_clear_snapshot();").ok)
	assert(int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name LIKE 'mandate-inventory-executor-%' AND wait_event_type='Lock';").rows[0].n)==1)
	assert(runtime.status(100)=="admit" and runtime.attach(100,a))
	assert(runtime.status(100)=="admit","duplicate attach preserves the in-flight admission")
	assert(pg.commit())
	await wait_until(func() -> bool: return runtime.mutations_allowed(100))
	assert(finished.filter(func(row: Dictionary) -> bool: return row.id=="unequip" and row.result.ok).size()==1)
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
	assert(runtime.attach(101,c) and runtime.status(101)=="paused","duplicate attach must not restart uncertain work")
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
	assert(runtime.attach(101,c) and runtime.status(101)=="paused","keep the original body even when admission left no durable row")
	assert(pg.execute("DROP TRIGGER fixture_admission ON economy.inventory_intents;").ok)
	assert(runtime.retry(101))
	await wait_until(func() -> bool: return runtime.mutations_allowed(101))
	assert(finished.back().id=="uncertain-admission" and finished.back().result.ok and receipt_count("uncertain-admission")==1)
	verify_projection(94000)
	# Post-command refresh needs the SAME freshness barrier as login. A later
	# domain commits after the command snapshot, without delivering a notice.
	change_after_snapshot=true
	delivered=snapshots.size()
	assert(runtime.submit(101,"post-command-race","unequip",sword.uid,7,15).queued)
	await wait_until(func() -> bool: return runtime.mutations_allowed(101))
	assert(finished.back().id=="post-command-race" and finished.back().result.ok)
	assert(snapshots.size()>=delivered+2 and receipt_count("post-command-race")==1)
	verify_projection(94000)
	# Mutation COMMIT succeeds, but its new freshness-ACK COMMIT is uncertain.
	# Keep the receipt/body, deny combat and never announce a terminal success or
	# a change fact until explicit recovery confirms the current view.
	var facts_before: int=committed_facts
	var attempts_before: int=int(pg.query("SELECT last_value FROM economy.fixture_runtime_attempt;").rows[0].last_value)
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_ack AFTER UPDATE ON economy.inventory_sessions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_runtime_commit();").ok)
	assert(runtime.submit(101,"ack-unknown","equip",sword.uid,8,-1).queued)
	await wait_until(func() -> bool: return runtime.status(101)=="paused")
	assert(failures.back()=="outcome_unknown" and receipt_count("ack-unknown")==1)
	assert(committed_facts==facts_before and not finished.any(func(row: Dictionary) -> bool: return row.id=="ack-unknown"))
	assert(world.runtime_attack(94000)==-1 and runtime.mutations_allowed(200))
	assert(pg.query("SELECT last_value FROM economy.fixture_runtime_attempt;").rows[0].last_value==attempts_before+1)
	assert(pg.execute("DROP TRIGGER fixture_ack ON economy.inventory_sessions;").ok and runtime.retry(101))
	await wait_until(func() -> bool: return runtime.mutations_allowed(101))
	assert(finished.back().id=="ack-unknown" and finished.back().result.ok and receipt_count("ack-unknown")==1)
	assert(committed_facts==facts_before+1)
	verify_projection(94000)
	# A trusted higher account revision closes only its live owner, immediately
	# removes dependent combat inputs and coalesces a burst into one hydration.
	var old_marker: Dictionary=native_state(94000).item_state
	delivered=snapshots.size()
	for index: int in 3:
		assert(runtime.invalidate_item_state(external_material()))
	assert(not runtime.mutations_allowed(101) and world.runtime_attack(94000)==-1)
	assert(runtime.mutations_allowed(200) and world.runtime_attack(94010)>0)
	await wait_until(func() -> bool: return runtime.mutations_allowed(101))
	assert(snapshots.size()==delivered+1,"burst invalidation is one coherent refresh, not a per-fact queue")
	verify_projection(94000)
	var marker: Dictionary=native_state(94000).item_state
	delivered=snapshots.size()
	assert(runtime.invalidate_item_state(marker) and runtime.invalidate_item_state(old_marker))
	assert(runtime.mutations_allowed(101) and snapshots.size()==delivered,"duplicates/reordered old notices cannot regress readiness")
	# Let SQL ACK actually finish without polling its result, then deliver a newer
	# committed notice. A delayed successful ACK cannot reopen the old RAM view.
	assert(pg.execute("CREATE SEQUENCE economy.fixture_cache_ack;").ok)
	assert(pg.execute("CREATE FUNCTION economy.fixture_cache_ack() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM nextval('economy.fixture_cache_ack'); RETURN NEW; END; $$;").ok)
	assert(pg.execute("CREATE TRIGGER fixture_cache_ack AFTER UPDATE ON economy.inventory_sessions FOR EACH ROW EXECUTE FUNCTION economy.fixture_cache_ack();").ok)
	assert(runtime.request_outcome(101,"missing-after-ack").queued)
	await wait_until(func() -> bool: return runtime.status(101)=="ack")
	await wait_until(func() -> bool:
		pg.execute("SELECT pg_stat_clear_snapshot();")
		return bool(pg.query("SELECT is_called FROM economy.fixture_cache_ack;").rows[0].is_called) and int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name LIKE 'mandate-inventory-executor-%' AND state='active';").rows[0].n)==0,false)
	assert(runtime.invalidate_item_state(external_material()))
	assert(not runtime.mutations_allowed(101))
	await wait_until(func() -> bool: return runtime.mutations_allowed(101))
	assert(finished.back().id=="missing-after-ack" and finished.back().result.error=="unknown_command")
	assert(receipt_count("missing-after-ack")==0)
	verify_projection(94000)
	assert(pg.execute("DROP TRIGGER fixture_cache_ack ON economy.inventory_sessions;").ok)
	var unrelated: Dictionary=marker.duplicate(true)
	unrelated.account_id=999999
	assert(not runtime.invalidate_item_state(unrelated) and runtime.mutations_allowed(101))
	var forged_authority: Dictionary=marker.duplicate(true)
	forged_authority.authority_id="f".repeat(32) if marker.authority_id!="f".repeat(32) else "e".repeat(32)
	assert(not runtime.invalidate_item_state(forged_authority))
	assert(runtime.status(101)=="paused" and world.runtime_attack(94000)==-1)
	assert(runtime.retry(101))
	await wait_until(func() -> bool: return runtime.mutations_allowed(101))
	# Continual commits cannot produce an unbounded repair loop or reopen an
	# unconfirmed combat view. Explicit recovery works once churn stops.
	churn_snapshots=Runtime.MAX_REPAIRS+1
	assert(runtime.invalidate_item_state(external_material()))
	await wait_until(func() -> bool: return runtime.status(101)=="paused")
	assert(churn_snapshots==0 and failures.back()=="stale_snapshot" and world.runtime_attack(94000)==-1)
	assert(runtime.retry(101))
	await wait_until(func() -> bool: return runtime.mutations_allowed(101))
	verify_projection(94000)
	change_after_snapshot=true
	delivered=snapshots.size()
	runtime.detach(101) # Deliberate fresh recovery, not duplicate attach.
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
