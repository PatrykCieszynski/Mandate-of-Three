extends Node
## Opt-in P1a only. Runner owns a fresh loopback PostgreSQL cluster; no live DSN.
var directory := "res://.godot/verification/postgres-readiness"
var workers: Array[Object] = []
var failed := false

func check(value: bool, message: String) -> bool:
	if value: return true
	failed=true
	push_error("POSTGRES_READINESS_FAILED: "+message)
	get_tree().quit(1)
	return false

func _ready() -> void:
	run.call_deferred()

func _process(_delta: float) -> void:
	for worker: Object in workers: worker.poll()

func receive(request: Object) -> Dictionary:
	if not check(request!=null,"native request admitted"): return {}
	if not request.is_done(): await request.completed
	return request.get_result()

func capture_sqlite() -> void:
	var db:=SqliteSoci.new()
	db.path=directory+"/source.db"
	if not check(not FileAccess.file_exists(db.path),"only create a new disposable SQLite fixture"): return
	if not check(db.open_db(),"open disposable SQLite"): return
	WorldSchema.ensure_schema(db)
	var store:=WorldStoreSqlite.new(db)
	var owner:=EconomyFixture.create_character(store,"pg-readiness",{"name":"Readiness","skin":1})
	var runtime:=WorldDatabase.new()
	runtime.db=db
	runtime.store=store
	EconomyFixture.prepare(runtime)
	check(owner>0,"all identity-gated migrations applied")
	check(db.query("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name;"),"schema catalogue")
	var objects:=db.query_result.duplicate(true)
	check(db.query("SELECT key,value FROM meta ORDER BY key;"),"migration and feature metadata")
	var metadata:=db.query_result.duplicate(true)
	# Do not export the per-fixture random authority as a baseline identity.
	metadata=metadata.filter(func(row: Dictionary)->bool:return row.key!="economy_authority_id")
	var file:=FileAccess.open(directory+"/sqlite-schema.json",FileAccess.WRITE)
	check(file!=null,"write schema audit")
	file.store_string(JSON.stringify({"objects":objects,"meta":metadata},"  "))
	file.close()
	runtime.db=null
	runtime.free()
	check(db.close_db(),"close fixture")
	for suffix: String in ["","-wal","-shm"]: DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path+suffix))
	print("SQLITE_SCHEMA_BASELINE_OK objects=",objects.size())

func run() -> void:
	if not check(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster","use the disposable runner"): return
	directory=OS.get_environment("MANDATE_PG_FIXTURE_DIR")
	if not check(directory.begins_with("res://.godot/verification/postgres-readiness/run-") and not ".." in directory,"owned fixture output"): return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	capture_sqlite()
	if failed: return
	if not check(ClassDB.class_exists("GodotSociDatabase") and ClassDB.class_exists("SociQueryDispatcher"),"install pinned tools/soci payload"): return
	var connection:=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	if not check(not connection.is_empty(),"runner connection"): return
	var db: Object=ClassDB.instantiate("GodotSociDatabase")
	if not check(db.open("postgresql",connection),"open native PostgreSQL session"): return
	var result: Dictionary=db.query("SELECT current_database() AS db, current_user AS role, version() AS version;")
	if not check(result.get("ok",false) and result.rows[0].db=="mandate_readiness" and result.rows[0].role=="mandate_fixture","fixture identity"): return
	print("POSTGRES_SERVER ",result.rows[0].version)
	check(db.execute("CREATE TABLE probe (id BIGINT PRIMARY KEY, amount BIGINT NOT NULL CHECK(amount>=0), label TEXT, note TEXT);").ok,"probe schema")
	check(db.begin() and db.in_transaction(),"explicit transaction")
	check(db.execute("INSERT INTO probe VALUES(:id,:amount,:label,:note);",{"id":1,"amount":9223372036854775806,"label":"Zażółć — sword","note":null}).ok,"bound int64/UTF-8/NULL")
	check(db.commit() and not db.in_transaction(),"commit")
	result=db.query("SELECT amount,label,note FROM probe WHERE id=:id;",{"id":1})
	check(result.ok and result.rows[0].amount is int and result.rows[0].amount==9223372036854775806 and result.rows[0].label=="Zażółć — sword" and result.rows[0].note==null,"exact native value roundtrip")
	check(db.begin(),"rollback begin")
	check(db.execute("UPDATE probe SET amount=7 WHERE id=1;").ok,"provisional write")
	check(not db.execute("INSERT INTO probe VALUES(2,-1,'bad',NULL);").ok,"constraint abort")
	check(db.rollback(),"rollback failed transaction")
	result=db.query("SELECT amount FROM probe WHERE id=1;")
	check(result.ok and result.rows[0].amount==9223372036854775806,"no partial update after SQL error")
	var first: Object=ClassDB.instantiate("SociQueryDispatcher")
	var second: Object=ClassDB.instantiate("SociQueryDispatcher")
	workers=[first,second]
	check(first.start("postgresql",connection,2) and second.start("postgresql",connection,2),"two bounded independent worker sessions")
	var pids: Array[int]=[]
	for worker: Object in workers:
		result=await receive(worker.query_async("SELECT pg_backend_pid() AS pid;",{},1))
		if not check(result.get("ok",false),"worker connection confirmed by SQL"): return
		pids.append(result.rows[0].pid)
	check(pids[0]!=pids[1],"independent PostgreSQL connections")
	# Hold an actual lock on the third session; observe the worker waiting instead
	# of inferring independence from noisy elapsed-time comparisons.
	check(db.query("SELECT pg_advisory_lock(81234)::TEXT AS locked;").ok,"hold fixture advisory lock")
	var slow: Object=first.query_async("SELECT pg_advisory_xact_lock(81234)::TEXT AS acquired;",{},1)
	var deadline:=Time.get_ticks_msec()+2000
	while true:
		result=db.query("SELECT wait_event_type::TEXT AS waiting FROM pg_stat_activity WHERE pid=:pid;",{"pid":pids[0]})
		if result.ok and not result.rows.is_empty() and result.rows[0].waiting=="Lock": break
		if not check(not slow.is_done() and Time.get_ticks_msec()<deadline,"worker reaches server lock wait"): return
		await get_tree().process_frame
	var queued: Object=first.query_async("SELECT 7 AS queued;",{},1)
	var denied: Object=first.query_async("SELECT 8 AS overflow;",{},1)
	check(queued!=null and denied==null,"bounded pending capacity rejects unscheduled overflow")
	var fast: Object=second.query_async("SELECT 41+1 AS answer;",{},1)
	var callback_thread: Array[int]=[0]
	fast.completed.connect(func(_r: Dictionary)->void:callback_thread[0]=OS.get_thread_caller_id())
	result=await receive(fast)
	check(result.ok and result.rows[0].answer==42 and not slow.is_done() and callback_thread[0]==OS.get_main_thread_id(),"main-thread completion while another native session waits")
	check(db.query("SELECT pg_advisory_unlock(81234)::TEXT AS unlocked;").ok,"release fixture lock")
	result=await receive(slow)
	check(result.ok,"bounded waiting query drains")
	result=await receive(queued)
	check(result.ok and result.rows[0].queued==7,"accepted queued read completes after lock release")
	result=await receive(first.transaction_async([
		{"sql":"UPDATE probe SET amount=9 WHERE id=:id;","params":{"id":1},"expected_affected_rows":1},
		{"sql":"UPDATE probe SET amount=10 WHERE id=:id;","params":{"id":999},"expected_affected_rows":1}]))
	check(not result.ok and not result.get("outcome_unknown",true),"batch row-count mismatch is known rollback")
	result=await receive(second.query_async("SELECT amount FROM probe WHERE id=1;",{},1))
	check(result.ok and result.rows[0].amount==9223372036854775806,"async batch rollback visible on independent connection")
	result=await receive(first.query_async("SELECT pg_sleep(2)::TEXT AS waited;",{},1))
	check(not result.ok,"server statement timeout bounds slow query")
	result=await receive(first.query_async("SELECT 1 AS recovered;",{},1))
	check(result.ok and result.rows[0].recovered==1,"session usable after statement timeout")
	for worker: Object in workers:
		check(worker.pending()==0,"drain before blocking native stop")
		worker.stop()
	workers.clear()
	db.close()
	if not failed: print("POSTGRES_READINESS_OK native int64/NULL/text, commit/rollback, independent async sessions, timeout and drained shutdown")
	get_tree().quit(1 if failed else 0)
