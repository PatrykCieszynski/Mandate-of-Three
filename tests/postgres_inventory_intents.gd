extends Node
const Schema = preload("res://source/server/world/database/postgres/inventory_intent_schema_postgres.gd")
const FullSchema = preload("res://source/server/world/database/postgres/exchange_orders_schema_postgres.gd")
const Executor = preload("res://source/server/world/database/postgres/inventory_executor_postgres.gd")
const Intents = preload("res://source/server/world/database/postgres/inventory_intent_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const Orders = preload("res://source/server/world/database/postgres/exchange_orders_postgres.gd")
var pg: Object
var connection: String
var directory: String
var executor: RefCounted
var answers: Dictionary={}

func wait_until(predicate: Callable) -> void:
	var deadline: int=Time.get_ticks_msec()+8000
	while not predicate.call() and Time.get_ticks_msec()<deadline:
		for result: Dictionary in executor.poll():
			assert(not answers.has(result.ticket))
			answers[result.ticket]=result
		await get_tree().process_frame
	assert(predicate.call())

func answer(queued: Dictionary) -> Dictionary:
	assert(queued.queued)
	await wait_until(func() -> bool: return answers.has(queued.ticket))
	return answers[queued.ticket]

func admit(id: String, item_uid: String, revision: int, position: int) -> Dictionary:
	return (await answer(executor.submit_inventory_admission(92000,id,"move",item_uid,revision,position))).result

func resume(id: String) -> Dictionary:
	return await answer(executor.submit_inventory_resume(92000,id))

func stored(id: String) -> Dictionary:
	return Intents.new(pg).outcome(92000,id)

func row(item_uid: String) -> Dictionary:
	return pg.query("SELECT i.revision,c.position FROM economy.item_instances i JOIN economy.item_custody c USING(uid) WHERE uid=:uid;",{"uid":item_uid}).rows[0]

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	connection=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	directory=OS.get_environment("MANDATE_PG_FIXTURE_DIR")
	assert(directory.begins_with("res://.godot/verification/postgres-readiness/run-") and not ".." in directory)
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection))
	executor=Executor.new()
	if "--intent-producer" in OS.get_cmdline_args():
		print("INTENT_PRODUCER_STARTED")
		assert(executor.start(connection,1,1))
		await wait_until(func() -> bool: return executor.is_ready())
		var item_uid: String=pg.query("SELECT uid FROM economy.item_instances WHERE owner_character_id=92000;").rows[0].uid
		var id: String="lost-"+Crypto.new().generate_random_bytes(12).hex_encode()
		assert((await admit(id,item_uid,0,10)).state=="pending")
		# Own disposable child only. Lose all RAM/worker state after durable ACK.
		var marker:=FileAccess.open(directory+"/producer-admitted",FileAccess.WRITE)
		marker.store_string("durable")
		marker.close()
		OS.kill(OS.get_process_id())
		marker=FileAccess.open(directory+"/producer-survived",FileAccess.WRITE)
		marker.store_string("kill failed")
		marker.close()
		get_tree().quit(99)
		return
	assert(Schema.ensure_schema(pg) and Schema.ensure_schema(pg) and FullSchema.ensure_schema(pg))
	for account: int in [9200,9201]:
		assert(Wallet.new(pg).initialize_account(account).ok)
		assert(Items.new(pg).bind_character(account*10,account))
	assert(Items.new(pg).bind_character(92001,9200))
	var item:=ItemInstance.create(ItemDefinitions.IRON_SWORD,92000,[])
	assert(pg.begin() and Items.new(pg).receive_item_in_transaction(item,0).ok and pg.commit())
	var output: Array=[]
	var code: int=OS.execute(OS.get_executable_path(),["--headless","--path",ProjectSettings.globalize_path("res://"),"--mode=world-server","res://tests/postgres_inventory_intents.tscn","--intent-producer"],output,true,false)
	# Windows OS.kill may report exit 0; reaching post-kill code is the failure.
	assert(code!=99 and FileAccess.file_exists(directory+"/producer-admitted") and not FileAccess.file_exists(directory+"/producer-survived"),"child code="+str(code)+" "+str(output))
	assert(executor.start(connection,2,2))
	await wait_until(func() -> bool: return executor.is_ready())
	var page: Dictionary=(await answer(executor.submit_inventory_discovery(92000,0,1))).result
	assert(page.ok and page.operations.size()==1 and not page.more)
	var lost: Dictionary=page.operations[0]
	assert(lost.state=="pending" and lost.uid==item.uid and lost.revision==0 and lost.position==10)
	assert(Intents.new(pg).outcome(92001,lost.operation_id).error=="unknown_command")
	assert((await answer(executor.submit_inventory_resume(92010,lost.operation_id))).result.error=="unknown_command")
	assert(Items.new(pg).inventory_command(92000,"move",item.uid,0,10,lost.operation_id).error=="operation_pending")
	assert(Items.new(pg).inventory_command(92000,"move",item.uid,0,20,lost.operation_id).error=="command_conflict")
	var order: Dictionary={"command_id":lost.operation_id,"have_asset":"yang","want_asset":"upgrade_ore","quantity":1,"price_num":1,"price_den":1}
	assert(Orders.new(pg).place_order(92000,order,{}).error=="command_conflict")
	assert(Wallet.new(pg).checkpoint({9200:10}).ok)
	var ordinary:=order.duplicate(true)
	ordinary.command_id="ordinary-after-intents"
	var placed: Dictionary=Orders.new(pg).place_order(92000,ordinary,{})
	assert(placed.ok and Orders.new(pg).cancel_order(92000,"ordinary-cancel",placed.order_id,0,{}).ok)
	assert((await admit(lost.operation_id,item.uid,0,20)).error=="command_conflict")
	assert((await admit(lost.operation_id,item.uid,0,10)).state=="pending")
	var duplicate_a: Dictionary=executor.submit_inventory_resume(92000,lost.operation_id)
	var duplicate_b: Dictionary=executor.submit_inventory_resume(92000,lost.operation_id)
	var done: Dictionary=await answer(duplicate_a)
	var duplicate: Dictionary=await answer(duplicate_b)
	assert(done.result==duplicate.result and int(done.committed)+int(duplicate.committed)==1)
	assert(done.result.state=="committed" and row(item.uid).revision==1)
	assert((await resume(lost.operation_id)).result==done.result and row(item.uid).position==10)
	assert((await admit(lost.operation_id,item.uid,0,10)).result==done.result.result)
	# Durable business rejection survives later changes and another session.
	assert((await admit("stale-intent",item.uid,0,15)).state=="pending")
	var rejected: Dictionary=await resume("stale-intent")
	assert(rejected.result.state=="rejected" and rejected.result.result.error=="stale" and not rejected.committed)
	assert(Items.new(pg).inventory_command(92000,"move",item.uid,1,20,"later-change").ok)
	assert((await resume("stale-intent")).result==rejected.result)
	assert(Items.new(pg).inventory_receipt(92000,"stale-intent").error=="stale")
	assert(Items.new(pg).inventory_command(92000,"move",item.uid,0,15,"stale-intent").error=="stale")
	assert((await admit("stale-intent",item.uid,0,15)).result==rejected.result.result)
	# Atomic finalization fault: item/receipt roll back, admitted identity remains.
	assert((await admit("atomic-intent",item.uid,2,25)).state=="pending")
	assert(pg.execute("CREATE FUNCTION economy.fixture_intent_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'intent fixture' USING ERRCODE=TG_ARGV[0]; END; $$;").ok)
	assert(pg.execute("CREATE TRIGGER fixture_intent_fault BEFORE UPDATE ON economy.inventory_intents FOR EACH ROW EXECUTE FUNCTION economy.fixture_intent_fault('23514');").ok)
	assert((await resume("atomic-intent")).result.error=="storage")
	assert(stored("atomic-intent").state=="pending" and row(item.uid).position==20 and row(item.uid).revision==2)
	assert(pg.query("SELECT command_id FROM economy.market_commands WHERE command_id='atomic-intent';").rows.is_empty())
	assert(pg.execute("DROP TRIGGER fixture_intent_fault ON economy.inventory_intents;").ok)
	assert(pg.execute("CREATE SEQUENCE economy.fixture_intent_attempt;").ok)
	assert(pg.execute("CREATE FUNCTION economy.fixture_intent_retry() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF nextval('economy.fixture_intent_attempt')=1 THEN RAISE EXCEPTION 'intent retry' USING ERRCODE='40001'; END IF; RETURN NEW; END; $$;").ok)
	assert(pg.execute("CREATE TRIGGER fixture_intent_fault BEFORE UPDATE ON economy.inventory_intents FOR EACH ROW EXECUTE FUNCTION economy.fixture_intent_retry();").ok)
	assert((await resume("atomic-intent")).result.state=="committed" and row(item.uid).revision==3)
	assert(pg.query("SELECT last_value FROM economy.fixture_intent_attempt;").rows[0].last_value==2)
	assert(pg.execute("DROP TRIGGER fixture_intent_fault ON economy.inventory_intents;").ok)
	# Native deferred COMMIT error is unknown, never auto-executed again.
	assert((await admit("unknown-intent",item.uid,3,30)).state=="pending")
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_intent_fault('40001');").ok)
	assert((await resume("unknown-intent")).result.get("outcome_unknown",false))
	assert(stored("unknown-intent").state=="pending" and row(item.uid).revision==3)
	assert(pg.execute("DROP TRIGGER fixture_commit ON economy.market_commands;").ok)
	assert((await resume("unknown-intent")).result.state=="committed" and row(item.uid).revision==4)
	# Admission itself cannot acknowledge a failed COMMIT as durable pending.
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_commit AFTER INSERT ON economy.inventory_intents DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_intent_fault('40001');").ok)
	assert((await admit("unknown-admission",item.uid,4,35)).get("outcome_unknown",false))
	assert(stored("unknown-admission").error=="unknown_command")
	assert(pg.execute("DROP TRIGGER fixture_commit ON economy.inventory_intents;").ok)
	# Concurrent admission reuses one immutable identity; rejection must finalize
	# in the same transaction as its negative receipt, or remain pending.
	duplicate_a=executor.submit_inventory_admission(92000,"reject-atomic","move",item.uid,0,40)
	duplicate_b=executor.submit_inventory_admission(92000,"reject-atomic","move",item.uid,0,40)
	assert((await answer(duplicate_a)).result.state=="pending" and (await answer(duplicate_b)).result.state=="pending")
	assert(pg.query("SELECT sequence FROM economy.inventory_intents WHERE operation_id='reject-atomic';").rows.size()==1)
	assert(pg.execute("CREATE TRIGGER fixture_intent_fault BEFORE UPDATE ON economy.inventory_intents FOR EACH ROW EXECUTE FUNCTION economy.fixture_intent_fault('23514');").ok)
	assert((await resume("reject-atomic")).result.error=="storage" and stored("reject-atomic").state=="pending")
	assert(Items.new(pg).inventory_receipt(92000,"reject-atomic").error=="unknown_command" and row(item.uid).revision==4)
	assert(pg.execute("DROP TRIGGER fixture_intent_fault ON economy.inventory_intents;").ok)
	assert((await resume("reject-atomic")).result.state=="rejected")
	# Bound unexecuted durable work; a rejected admission reserves nothing.
	for index: int in Intents.MAX_PENDING_PER_ACCOUNT:
		assert((await admit("bounded-"+str(index),item.uid,9007199254741033,40)).state=="pending")
	assert((await admit("not-admitted",item.uid,4,40)).error=="busy")
	assert(stored("not-admitted").error=="unknown_command")
	assert((await resume("bounded-0")).result.state=="rejected")
	assert((await admit("not-admitted",item.uid,4,40)).state=="pending")
	var ids: Array=[]
	var cursor: int=0
	while true:
		page=(await answer(executor.submit_inventory_discovery(92000,cursor,2))).result
		assert(page.ok and page.operations.size()<=2)
		for operation: Dictionary in page.operations:
			assert(not ids.has(operation.operation_id))
			ids.append(operation.operation_id)
			if operation.operation_id.begins_with("bounded-"): assert(operation.revision==9007199254741033)
		cursor=int(page.cursor)
		if not page.more: break
	assert(ids.size()==14 and Intents.new(pg).discover(92001).operations.is_empty())
	executor.begin_drain()
	await wait_until(func() -> bool: return executor.is_stopped())
	pg.close()
	assert(pg.open("postgresql",connection) and stored("stale-intent")==rejected.result)
	assert(stored("not-admitted").state=="pending")
	pg.close()
	print("POSTGRES_INVENTORY_INTENTS_OK durable admission/process loss/discovery, reserved identity, atomic success/rejection, COMMIT unknown and bounded recovery")
	get_tree().quit()
