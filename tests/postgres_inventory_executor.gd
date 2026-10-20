extends Node
## Real native sessions; no runtime backend switch or fake async SQL responses.
const Executor = preload("res://source/server/world/database/postgres/inventory_executor_postgres.gd")
const Schema = preload("res://source/server/world/database/postgres/inventory_schema_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
var pg: Object
var connection: String
var executor: RefCounted
var answers: Dictionary={}
var physics_ticks: int=0
var observations: Array=[]

func _physics_process(_delta: float) -> void: physics_ticks+=1

func collect() -> void:
	for answer: Dictionary in executor.poll():
		assert(not answer.has("metrics"),"diagnostic timestamps never enter runtime result envelopes")
		assert(not answers.has(answer.ticket),"one local completion per ticket")
		answers[answer.ticket]=answer

func wait_until(predicate: Callable, poll_results: bool = true) -> void:
	var deadline: int=Time.get_ticks_msec()+8000
	while not predicate.call() and Time.get_ticks_msec()<deadline:
		if poll_results: collect()
		await get_tree().process_frame
	if poll_results: collect()
	assert(predicate.call(),"bounded fixture wait; no successful result inferred from timeout")

func submit(character: int, id: String, item_uid: String, revision: int, position: int) -> int:
	var queued: Dictionary=executor.submit_inventory(character,id,"move",item_uid,revision,position)
	assert(queued.queued)
	return int(queued.ticket)

func wait_answer(ticket: int) -> Dictionary:
	await wait_until(func() -> bool: return answers.has(ticket))
	return answers[ticket]

func position(item_uid: String) -> Dictionary:
	var found: Dictionary=pg.query("SELECT i.revision,c.position,c.owner_id FROM economy.item_instances i JOIN economy.item_custody c USING(uid) WHERE i.uid=:uid;",{"uid":item_uid})
	assert(found.ok and found.rows.size()==1)
	return found.rows[0]

func receipt_count(command: String) -> int:
	var found: Dictionary=pg.query("SELECT COUNT(*) AS n FROM economy.market_commands WHERE command_id=:id;",{"id":command})
	assert(found.ok)
	return int(found.rows[0].n)

func worker_sessions() -> int:
	assert(pg.execute("SELECT pg_stat_clear_snapshot();").ok)
	return int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name LIKE 'mandate-inventory-executor-%';").rows[0].n)

func seed_item(account: int) -> String:
	assert(Wallet.new(pg).initialize_account(account).ok and Items.new(pg).bind_character(account*10,account))
	var item:=ItemInstance.create(ItemDefinitions.IRON_SWORD,account*10,[])
	assert(pg.begin() and Items.new(pg).receive_item_in_transaction(item,0).ok and pg.commit())
	return item.uid

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	connection=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	var a:=seed_item(9100)
	var b:=seed_item(9101)
	executor=Executor.new()
	executor.observation.connect(func(sample: Dictionary)->void:
		assert(sample.keys().size()==8 and sample.queue_us>=0 and sample.worker_us>=0 and sample.delivery_us>=0)
		observations.append(sample))
	assert(not executor.start(connection,0,1) and not executor.start(connection,5,1) and not executor.start(connection,1,17))
	assert(executor.start(connection,2,1))
	assert(executor.submit_receipt(91000,"before-ready").error=="unavailable")
	await wait_until(func() -> bool: return executor.is_ready())
	assert(worker_sessions()==2)
	assert(executor.submit_inventory(91000,"invalid","execute",a,0,10).error=="request")
	# Keep one worker in real SQL while another transaction commits. No poll or
	# shutdown call may wait for the active native session on the main thread.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9100 FOR NO KEY UPDATE;").ok)
	var first:=submit(91000,"initial-a",a,0,10)
	var second:=submit(91010,"initial-b",b,0,10)
	var ticks_before: int=physics_ticks
	for index: int in 10: await get_tree().physics_frame
	await wait_until(func() -> bool: return receipt_count("initial-b")==1,false)
	assert(executor.pending_count()==2 and executor.submit_inventory(91000,"not-buffered","move",a,0,15).error=="busy")
	var other: Dictionary=await wait_answer(second)
	assert(other.result.ok and other.committed and not answers.has(first) and physics_ticks>ticks_before)
	assert(position(a).position==0 and position(b).position==10 and receipt_count("not-buffered")==0)
	executor.begin_drain()
	assert(not executor.is_stopped() and executor.submit_receipt(91010,"initial-b").error=="unavailable")
	collect()
	assert(not answers.has(first) and pg.commit())
	await wait_until(func() -> bool: return executor.is_stopped())
	assert(answers[first].result.ok and answers[first].committed and executor.pending_count()==0)
	assert(position(a).revision==1 and position(b).revision==1)
	await wait_until(func() -> bool: return worker_sessions()==0)
	print("POSTGRES_EXECUTOR_PROGRESS_OK two native owners, main-thread physics during blocked SQL, bounded unconsumed results and nonblocking drain")
	assert(observations.is_empty(),"disabled profiling emits nothing")
	executor.profiling_enabled=true
	# Recreate sessions and recover the same operation without a second mutation.
	assert(executor.start(connection,1,2))
	await wait_until(func() -> bool: return executor.is_ready())
	var replay:=submit(91000,"initial-a",a,0,10)
	var lookup: Dictionary=executor.submit_receipt(91000,"initial-a")
	assert(lookup.queued and executor.submit_receipt(91000,"overflow").error=="busy")
	await wait_until(func() -> bool: return answers.has(replay) and answers.has(lookup.ticket))
	assert(answers[replay].result==answers[first].result and answers[replay].receipt_replay and not answers[replay].committed)
	assert(answers[lookup.ticket].result==answers[first].result and not answers[lookup.ticket].committed and not answers[lookup.ticket].receipt_replay)
	assert(observations.size()==2,"one sanitized sample for each profiled native completion")
	# Consumer-owned copies cannot rewrite a durable receipt or worker state.
	answers[replay].result.item_state.revision=-1
	lookup=executor.submit_receipt(91000,"initial-a")
	assert((await wait_answer(lookup.ticket)).result==answers[first].result)
	var noop: Dictionary=await wait_answer(submit(91000,"no-op-async",a,1,10))
	assert(noop.result.ok and not noop.committed and not noop.receipt_replay)
	noop=await wait_answer(submit(91000,"no-op-async",a,1,10))
	assert(noop.result.ok and not noop.committed and noop.receipt_replay and position(a).revision==1)
	# A real deferred COMMIT error closes the worker session. It must publish
	# unknown once, then reconnect for discovery, not rerun the mutation itself.
	assert(pg.execute("CREATE SEQUENCE economy.fixture_executor_commit;").ok)
	assert(pg.execute("CREATE FUNCTION economy.fixture_executor_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.command_id='unknown-async' THEN PERFORM nextval('economy.fixture_executor_commit'); RAISE EXCEPTION 'executor commit fixture' USING ERRCODE='40001'; END IF; RETURN NEW; END; $$;").ok)
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_executor_commit();").ok)
	var failed: Dictionary=await wait_answer(submit(91000,"unknown-async",a,1,15))
	assert(failed.result.get("outcome_unknown",false) and not failed.committed)
	assert(pg.query("SELECT last_value FROM economy.fixture_executor_commit;").rows[0].last_value==1)
	assert(position(a).position==10 and position(a).revision==1 and receipt_count("unknown-async")==0)
	assert(pg.execute("DROP TRIGGER fixture_commit ON economy.market_commands;").ok)
	lookup=executor.submit_receipt(91000,"unknown-async")
	assert((await wait_answer(lookup.ticket)).result.error=="unknown_command")
	var retried: Dictionary=await wait_answer(submit(91000,"unknown-async",a,1,15))
	assert(retried.result.ok and retried.committed and position(a).revision==2 and receipt_count("unknown-async")==1)
	# Real lock timeout yields a cleaned known failure; future jobs still work.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9100 FOR NO KEY UPDATE;").ok)
	ticks_before=physics_ticks
	failed=await wait_answer(submit(91000,"lock-timeout-async",a,2,20))
	assert(failed.result.error=="storage" and not failed.committed and physics_ticks>ticks_before and pg.commit())
	assert(receipt_count("lock-timeout-async")==0 and position(a).revision==2)
	assert((await wait_answer(submit(91000,"lock-timeout-async",a,2,20))).result.ok and position(a).revision==3)
	# Stop while both work slots are buffered: neither job is cancelled/dropped.
	var queued_a:=submit(91010,"drain-a",b,1,20)
	var queued_b:=submit(91010,"drain-b",b,2,25)
	executor.begin_drain()
	await wait_until(func() -> bool: return executor.is_stopped())
	assert(answers[queued_a].result.ok and answers[queued_b].result.ok and position(b).revision==3 and position(b).position==25)
	await wait_until(func() -> bool: return worker_sessions()==0)
	# Failed startup is also asynchronous and fully reaped, with no DSN in errors.
	assert(executor.start(connection+" dbname=mandate_missing_fixture",2,1))
	await wait_until(func() -> bool: return executor.is_stopped())
	assert(executor.startup_error=="storage" and executor.pending_count()==0)
	assert(executor.start(connection,1,1))
	await wait_until(func() -> bool: return executor.is_ready())
	executor.begin_drain()
	await wait_until(func() -> bool: return executor.is_stopped() and worker_sessions()==0)
	pg.close()
	print("POSTGRES_INVENTORY_EXECUTOR_OK bounded complete transactions, independent progress, replay/copy/reopen, COMMIT unknown, timeout recovery and clean drain/restart")
	get_tree().quit()
