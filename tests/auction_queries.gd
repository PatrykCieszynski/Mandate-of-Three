extends Node
## New contracts absent from synchronous suites: bounded async admission/session,
## signal delivery, deadlines including queue wait, and safe native reader drain.
const P := {"definition_id":"iron_sword","upgrade_min":0,"upgrade_max":9,"price_min":0,"price_max":9000000000000000,"affix_filters":[],"sort":"price_asc","cursor":"","limit":50}
var persistence: WorldDatabase
var db:=SQLite.new()
var results: Dictionary={}
var delivered: Array[String]=[]
var ticks:=0

func record(answer: Dictionary, key: String) -> void:
	assert(not results.has(key),"one terminal answer per request")
	results[key]=answer;delivered.append(key)

func send(account: int, key: String, p: Dictionary = P, valid: Callable = func()->bool:return true) -> void:
	persistence.auction_queries.submit(account,key,p,record.bind(key),valid)

func wait_for(condition: Callable, budget_ms: int = 8000) -> void:
	var deadline:=Time.get_ticks_msec()+budget_ms
	while not condition.call() and Time.get_ticks_msec()<deadline: await get_tree().process_frame
	assert(condition.call(),"bounded test completion")

func _physics_process(_delta: float) -> void: ticks+=1

func _ready() -> void:
	Engine.max_fps=120
	db.path=ProjectSettings.globalize_path("res://.godot/verification/auction-d1b/queries.db")
	DirAccess.remove_absolute(db.path)
	assert(db.open_db() and db.query("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;"))
	WorldSchema.ensure_schema(db)
	var store:=WorldStoreSqlite.new(db)
	var owner:=EconomyFixture.create_character(store,"auction",{"name":"Auction","skin":1})
	assert(MarketSearchSqlite.ensure_schema(db))
	preload("res://tests/fixtures/market_search_fixture.gd").seed(db,owner)
	persistence=WorldDatabase.new();add_child(persistence)
	persistence.db=db;persistence.database_path=db.path;persistence.store=store
	persistence.item_store=ItemStoreSqlite.new(db);persistence.wallet_store=WalletStoreSqlite.new(db)
	EconomyFixture.prepare(persistence)
	assert(await persistence.start_auction_queries(),"native readonly readiness after migration")
	var service:=persistence.auction_queries
	assert(not (await service.reader.query("INSERT INTO meta(key,value) VALUES('forbidden_auction','1');",{},1)).ok,"native readonly session rejects mutation")
	var absent:=AuctionSociReader.new()
	assert(not await absent.start(db.path+".missing") and not FileAccess.file_exists(db.path+".missing"),"startup cannot create a missing DB")
	persistence.database_path=db.path+".changed"
	assert(not await persistence.start_auction_queries(),"ready reader cannot be reused for a changed DB path")
	assert(not service.admissions and not persistence.auction_binding_current())
	persistence.database_path=db.path
	assert(await service.pause() and await persistence.start_auction_queries())
	# Existing independent diagnostic SQL projection is the oracle for all wire cases.
	var cases: Array[Dictionary]=[P.duplicate(true)]
	var broad:=P.duplicate(true);broad.affix_filters=[{"stat_id":"monster_damage","minimum":0}];cases.append(broad)
	var selective:=P.duplicate(true);selective.affix_filters=[{"stat_id":"monster_damage","minimum":15},{"stat_id":"critical_chance","minimum":7}];selective.upgrade_min=5;selective.upgrade_max=7;cases.append(selective)
	var desc:=P.duplicate(true);desc.sort="price_desc";cases.append(desc)
	for index: int in cases.size():
		var p: Dictionary=cases[index]
		for page: int in 2:
			var built:=preload("res://tests/fixtures/auction_soci_sql.gd").build(p)
			assert(db.query_with_bindings(built.sql,built.params.values()))
			var expected:=preload("res://tests/fixtures/auction_soci_sql.gd").project(db.query_result.duplicate(true),p,db)
			var key:="parity%d_%d" % [index,page]
			send(2000+index,key,p);assert(not results.has(key),"submit returns before SQL/result")
			await wait_for(func()->bool:return results.has(key));assert(results[key]==expected,"same rows/items/cursor")
			p.cursor=expected.next_cursor
	var invalid:=P.duplicate(true);invalid.cursor="broken"
	send(2100,"bad_cursor",invalid);assert(results.bad_cursor.error=="cursor")
	# Replacements settle old waiters; another account keeps its queue position.
	send(2101,"replace_old");send(2102,"fair_other");send(2101,"replace_new")
	assert(results.replace_old.error=="rate_limited")
	await wait_for(func()->bool:return results.has("replace_new") and results.has("fair_other"))
	assert(results.fair_other.ok and results.replace_new.ok)
	for number: int in 9: send(2410,"account_limit%d" % number)
	assert(results.account_limit8.error=="rate_limited","one account shares admission budget across callers")
	await wait_for(func()->bool:return results.has("account_limit7"))
	send(2411,"duplicate")
	for attempt: int in 20:
		send(2411,"duplicate",invalid if attempt%2==0 else P)
	await wait_for(func()->bool:return results.has("duplicate"))
	assert(delivered.count("duplicate")==1 and results["duplicate"].ok,"valid/malformed retries produce only original success")
	for number: int in 7:
		var key:="duplicate_budget%d" % number
		send(2411,key)
		await wait_for(func()->bool:return results.has(key))
		assert(results[key].ok,"duplicate IDs do not consume the account admission budget")
	send(2411,"duplicate_budget_over")
	assert(results.duplicate_budget_over.error=="rate_limited")
	# Recovery must not reopen a session whose World database binding changed.
	send(2412,"recovery_binding",P,func()->bool:return persistence.auction_binding_current())
	await wait_for(func()->bool:return not service.active.is_empty())
	assert(not await service.pause(0))
	persistence.database_path=db.path+".changed"
	await wait_for(func()->bool:return service.active.is_empty())
	send(2413,"recovery_binding_denied")
	assert(results.recovery_binding_denied.error=="storage" and not results.has("recovery_binding"),"binding mismatch suppresses late delivery and automatic resume")
	persistence.database_path=db.path
	assert(await service.pause() and await persistence.start_auction_queries())
	var token: Dictionary={"live":true}
	send(2103,"stale",P,func()->bool:return token.live);token.live=false
	await wait_for(func()->bool:return service.queued.is_empty() and service.active.is_empty())
	assert(not results.has("stale"),"invalid session receives no late answer")
	send(2104,"removed:pending");service.cancel_scope("removed:")
	await get_tree().process_frame;assert(not results.has("removed:pending"))
	# Deterministic bounded admission without artificially slowing the native SQL.
	for number: int in service.MAX_PENDING+1: send(2200+number,"cap%d" % number)
	assert(results["cap%d" % service.MAX_PENDING].error=="rate_limited")
	assert(service.queued.size()<=service.MAX_PENDING)
	assert(not persistence.backup_database(),"uncoordinated checkpoint refuses open reader")
	assert(await persistence.coordinated_backup(),"drain all accepted jobs, close session, backup, resume")
	assert(service.admissions)
	# Queue delay is included in the same 2s deadline, even across a main-loop hitch.
	service.set_process(false);send(2400,"queue_timeout")
	await get_tree().create_timer(2.1).timeout;service.set_process(true)
	await wait_for(func()->bool:return results.has("queue_timeout"))
	assert(results.queue_timeout.error=="timeout")
	# Simulate a degraded plan in this disposable DB: active SQL has no cancellation.
	assert(db.query("DROP INDEX affix_item_lookup;"))
	send(2401,"active_timeout",broad)
	await wait_for(func()->bool:return not service.active.is_empty())
	var tick_before:=ticks
	assert(not await service.pause(1),"busy reader drain refuses rather than join an active query")
	assert(not persistence.backup_database())
	assert(not await persistence.coordinated_backup(),"failed coordinated drain refuses the backup")
	await wait_for(func()->bool:return results.has("active_timeout"))
	assert(results.active_timeout.error=="timeout" and ticks>tick_before,"deadline does not block physics")
	send(2401,"active_timeout",invalid)
	assert(delivered.count("active_timeout")==1,"native slot still deduplicates terminal timeout retries")
	# No second pause/start/backup repairs the service for this assertion.
	await wait_for(func()->bool:return service.admissions)
	assert(db.query("CREATE INDEX affix_item_lookup ON item_affix_index(uid,stat_id,value);"))
	send(2402,"automatic_recovery")
	await wait_for(func()->bool:return results.has("automatic_recovery"))
	assert(results.automatic_recovery.ok,"failed backup restores search automatically after late SQL completes")
	assert(await service.pause(),"successful pause still keeps admissions closed")
	await get_tree().create_timer(.05).timeout
	assert(not service.admissions,"successful lifecycle pause must not auto-resume")
	assert(await persistence.start_auction_queries())
	for cycle: int in 3:
		assert(await service.pause() and service.reader.dispatcher==null)
		assert(await persistence.start_auction_queries())
	assert(db.query("PRAGMA synchronous;") and int(db.query_result[0].synchronous)==2)
	assert(db.query("PRAGMA integrity_check;") and db.query_result[0].values()[0]=="ok")
	assert(db.query("PRAGMA foreign_key_check;") and db.query_result.is_empty())
	assert(await persistence.shutdown_database())
	var renamed:=db.path+".closed";assert(DirAccess.rename_absolute(db.path,renamed)==OK and DirAccess.remove_absolute(renamed)==OK)
	print("AUCTION_QUERIES_OK real native async, parity, malformed retry dedup/budget, stale sessions, deadlines, automatic failed-drain recovery/binding guard, successful pause/restarts/FULL")
	get_tree().quit()
