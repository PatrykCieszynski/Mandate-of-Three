extends Node
const Schema = preload("res://source/server/world/database/postgres/inventory_session_schema_postgres.gd")
const Executor = preload("res://source/server/world/database/postgres/inventory_executor_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Intents = preload("res://source/server/world/database/postgres/inventory_intent_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
var pg: Object
var connection: String
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
	assert(queued.queued,str(queued))
	await wait_until(func() -> bool: return answers.has(queued.ticket))
	return answers[queued.ticket]

func snapshot(context: Dictionary) -> Dictionary:
	var result: Dictionary=(await answer(executor.submit_session_snapshot(context))).result
	assert(result.ok,str(result))
	return result

func activate(identity: Dictionary, epoch: int) -> Dictionary:
	var result: Dictionary=(await answer(executor.submit_verified_inventory_grant(identity,epoch))).result
	assert(result.ok,str(result))
	return result.context

func session_row() -> Dictionary:
	return pg.query("SELECT * FROM economy.inventory_sessions WHERE account_id=9300;").rows[0]

func wait_locks(count: int) -> void:
	var deadline: int=Time.get_ticks_msec()+600
	var found: int=0
	while found<count and Time.get_ticks_msec()<deadline:
		assert(pg.execute("SELECT pg_stat_clear_snapshot();").ok)
		found=int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name LIKE 'mandate-inventory-executor-%' AND wait_event_type='Lock';").rows[0].n)
		if found<count: await get_tree().process_frame
	assert(found==count,"native admissions must actually queue behind account ownership")

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	connection=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg) and Schema.ensure_schema(pg))
	assert(Wallet.new(pg).initialize_account(9300).ok)
	assert(Items.new(pg).bind_character(93000,9300) and Items.new(pg).bind_character(93001,9300))
	var item:=ItemInstance.create(ItemDefinitions.IRON_SWORD,93000,[])
	assert(pg.begin() and Items.new(pg).receive_item_in_transaction(item,0).ok and pg.commit())
	assert(Intents.new(pg).admit(93000,"before-grant","move",item.uid,0,10).state=="pending")
	executor=Executor.new()
	assert(executor.start(connection,2,2))
	await wait_until(func() -> bool: return executor.is_ready())
	# Inputs model already VERIFIED Master grants; no fixture token is a client
	# credential or proof that the not-yet-wired Master bridge exists.
	var identity_a:=Sessions.identity_from_verified_ticket(9300,93000,"verified-master-ticket-A")
	var a:=await activate(identity_a,0)
	assert(a.epoch==1 and session_row().phase=="recovering")
	assert(await activate(identity_a,0)==a)
	var old_snapshot:=await snapshot(a)
	assert((await answer(executor.submit_inventory_recovery_ready(a,old_snapshot.item_state))).result.error=="operations_pending")
	assert((await answer(executor.submit_session_inventory(a,"too-early","move",item.uid,0,15))).result.error=="recovery_required")
	assert(Intents.new(pg).admit(93000,"raw-bypass","move",item.uid,0,15).error=="session_required")
	assert(Items.new(pg).inventory_command(93000,"move",item.uid,0,15,"raw-command").error=="session_required")
	assert((await answer(executor.submit_session_resume(a,"before-grant"))).result.state=="committed")
	assert((await answer(executor.submit_inventory_recovery_ready(a,old_snapshot.item_state))).result.error=="stale_snapshot")
	var current:=await snapshot(a)
	var wrong: Dictionary=current.item_state.duplicate(true)
	wrong.authority_id="another-backend"
	assert((await answer(executor.submit_inventory_recovery_ready(a,wrong))).result.error=="stale_snapshot")
	assert((await answer(executor.submit_inventory_recovery_ready(a,current.item_state))).result.ok)
	assert((await answer(executor.submit_session_inventory(a,"terminal-reject","move",item.uid,0,15))).result.state=="pending")
	assert((await answer(executor.submit_session_resume(a,"terminal-reject"))).result.state=="rejected")
	# FIFO SQL lock ordering: admission before takeover may finish durably, but
	# its delayed response remains tagged with the superseded context.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9300 FOR NO KEY UPDATE;").ok)
	var captured:=a.duplicate(true)
	var admitted: Dictionary=executor.submit_session_inventory(captured,"late-A","move",item.uid,1,15)
	captured.epoch=999 # caller mutation cannot alter the captured context
	await wait_locks(1)
	var identity_b:=Sessions.identity_from_verified_ticket(9300,93001,"verified-master-ticket-B")
	var installing: Dictionary=executor.submit_verified_inventory_grant(identity_b,1)
	await wait_locks(2)
	assert(pg.commit())
	var late: Dictionary=await answer(admitted)
	var installed: Dictionary=await answer(installing)
	assert(late.result.state=="pending" and installed.result.ok)
	var b: Dictionary=installed.result.context
	assert(b.epoch==2 and late.session.epoch==1 and not Sessions.same_context(late.session,b))
	assert((await answer(executor.submit_verified_inventory_grant(identity_a,0))).result.error=="epoch_conflict")
	assert((await answer(executor.submit_inventory_revoke(a))).result.error=="stale_session")
	assert((await answer(executor.submit_session_inventory(a,"terminal-reject","move",item.uid,0,15))).result.error=="stale_session")
	assert((await answer(executor.submit_session_discovery(a))).result.error=="stale_session")
	assert((await answer(executor.submit_session_pending_discovery(a))).result.error=="stale_session")
	assert((await answer(executor.submit_session_outcome(a,"before-grant"))).result.error=="stale_session")
	var forged:=b.duplicate(true)
	forged.character=93000
	assert((await answer(executor.submit_session_snapshot(forged))).result.error=="stale_session")
	assert((await answer(executor.submit_session_pending_discovery(forged))).result.error=="stale_session")
	var before_late:=await snapshot(b)
	assert((await answer(executor.submit_inventory_recovery_ready(b,before_late.item_state))).result.error=="operations_pending")
	var discovered: Dictionary=(await answer(executor.submit_session_discovery(b,0,10))).result
	assert(discovered.ok and discovered.operations.any(func(row: Dictionary) -> bool: return row.operation_id=="late-A" and row.character==93000 and row.state=="pending"))
	var pending_only: Dictionary=(await answer(executor.submit_session_pending_discovery(b,0,1))).result
	assert(pending_only.ok and pending_only.operations.size()==1 and pending_only.operations[0].operation_id=="late-A" and not pending_only.more)
	assert((await answer(executor.submit_session_resume(b,"late-A"))).result.state=="committed")
	assert(Items.new(pg).inventory(93000).items[0].uid==item.uid and Items.new(pg).inventory(93001).items.is_empty(),"new active alt must not retarget the old issuer's command")
	assert((await answer(executor.submit_inventory_recovery_ready(b,before_late.item_state))).result.error=="stale_snapshot")
	current=await snapshot(b)
	assert((await answer(executor.submit_inventory_recovery_ready(b,current.item_state))).result.ok)
	# Reverse order: revocation first prevents a previously buffered admission.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9300 FOR NO KEY UPDATE;").ok)
	var revoked: Dictionary=executor.submit_inventory_revoke(b)
	await wait_locks(1)
	var denied: Dictionary=executor.submit_session_inventory(b,"after-revoke","move",item.uid,2,20)
	await wait_locks(2)
	assert(pg.commit())
	assert((await answer(revoked)).result.ok and (await answer(denied)).result.error=="stale_session")
	assert(Intents.new(pg).outcome(93001,"after-revoke").error=="unknown_command")
	assert((await answer(executor.submit_verified_inventory_grant(identity_b,2))).result.error=="stale_session")
	assert((await answer(executor.submit_inventory_revoke(b))).result.ok)
	var identity_c:=Sessions.identity_from_verified_ticket(9300,93000,"verified-master-ticket-C")
	var c:=await activate(identity_c,2)
	assert(c.epoch==3)
	current=await snapshot(c)
	assert((await answer(executor.submit_inventory_recovery_ready(c,current.item_state))).result.ok)
	# A failed grant COMMIT is uncertain, not proof of a new/current epoch.
	assert(pg.execute("CREATE SEQUENCE economy.fixture_session_commit_attempt;").ok)
	assert(pg.execute("CREATE FUNCTION economy.fixture_session_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM nextval('economy.fixture_session_commit_attempt'); RAISE EXCEPTION 'session commit fixture' USING ERRCODE='40001'; END; $$;").ok)
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_commit AFTER UPDATE ON economy.inventory_sessions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_session_commit();").ok)
	var identity_d:=Sessions.identity_from_verified_ticket(9300,93000,"verified-master-ticket-D")
	assert((await answer(executor.submit_verified_inventory_grant(identity_d,3))).result.get("outcome_unknown",false))
	assert(session_row().epoch==3 and pg.query("SELECT last_value FROM economy.fixture_session_commit_attempt;").rows[0].last_value==1)
	assert(pg.execute("DROP TRIGGER fixture_commit ON economy.inventory_sessions;").ok)
	var d:=await activate(identity_d,3)
	assert(d.epoch==4 and await activate(identity_d,3)==d)
	executor.begin_drain()
	await wait_until(func() -> bool: return executor.is_stopped())
	pg.close()
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg) and session_row().epoch==4)
	assert(executor.start(connection,1,2))
	await wait_until(func() -> bool: return executor.is_ready())
	assert((await answer(executor.submit_session_snapshot(c))).result.error=="stale_session")
	current=await snapshot(d)
	assert((await answer(executor.submit_inventory_recovery_ready(d,current.item_state))).result.ok)
	# Keep native epoch values exact beyond JSON's floating-point range.
	var huge: int=9007199254741033
	assert(pg.execute("UPDATE economy.inventory_sessions SET epoch=:epoch WHERE account_id=9300;",{"epoch":huge}).ok)
	var identity_e:=Sessions.identity_from_verified_ticket(9300,93000,"verified-master-ticket-E")
	var e:=await activate(identity_e,huge)
	assert(e.epoch==huge+1 and not Sessions.same_context(d,e))
	current=await snapshot(e)
	assert((await answer(executor.submit_inventory_recovery_ready(e,current.item_state))).result.ok)
	# Pending keyset cursors and request revisions stay native int64 too.
	assert(pg.query("SELECT setval(pg_get_serial_sequence('economy.inventory_intents','sequence'),:sequence,true);",{"sequence":huge}).ok)
	assert((await answer(executor.submit_session_inventory(e,"large-cursor","move",item.uid,huge,20))).result.state=="pending")
	pending_only=(await answer(executor.submit_session_pending_discovery(e,huge,1))).result
	assert(pending_only.cursor==huge+1 and pending_only.operations[0].sequence==huge+1 and pending_only.operations[0].revision==huge)
	assert((await answer(executor.submit_session_resume(e,"large-cursor"))).result.state=="rejected")
	pending_only=(await answer(executor.submit_session_pending_discovery(e,huge,1))).result
	assert(pending_only.operations.is_empty() and pending_only.cursor==huge and not pending_only.more)
	executor.begin_drain()
	await wait_until(func() -> bool: return executor.is_stopped())
	pg.close()
	print("POSTGRES_INVENTORY_SESSIONS_OK durable CAS epochs/revocation, fenced queued admission, old-work recovery, fresh snapshot barrier and context-tagged delivery")
	get_tree().quit()
