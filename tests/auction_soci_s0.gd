extends Node
## Released native dispatcher proof only. No production runtime references this scene.
const FIXTURE := preload("res://tests/economy_fixture.gd")
const CATALOG := preload("res://tests/fixtures/market_search_fixture.gd")
const SQL := preload("res://tests/fixtures/auction_soci_sql.gd")
const QUERY_BUDGET_USEC := 2000000 # D0's two-second deadline, never relaxed for affixes.
var db := SQLite.new()
var persistence: WorldDatabase
var dispatcher: Object
var directory: String
var seed_character := 0
var buyer := 0
var offer: Dictionary
var measuring := false
var admissions := false
var operations := 0
var ticks: Array[int] = []
var writes: Array[int] = []
var intervals: Array[Dictionary] = []
var benchmarks: Dictionary = {}
var failures: Array[String] = []
var schema_before: Array = []
var signal_thread := 0
var frame_max_usec := 0
var last_frame_usec := 0
var poll_max_usec := 0

static func connection(path: String) -> String:
	# SOCI's options parser understands quoted physical paths, not Godot VFS.
	assert(not "'" in path and not "\n" in path)
	return "dbname='"+path.replace("\\","/")+"' readonly=true timeout=1"

static func parameters() -> Dictionary:
	return {"definition_id":"iron_sword","upgrade_min":0,"upgrade_max":9,"price_min":0,"price_max":WalletStoreSqlite.MAX_YANG,"affix_filters":[],"sort":"price_asc","cursor":"","limit":50}

func start_reader(path: String) -> void:
	assert(dispatcher.start("sqlite3",connection(path),8))
	admissions = true

func submit(sql: String, params: Dictionary = {}, query: bool = true) -> Object:
	if not admissions: return null
	var request: Object
	if query: request = dispatcher.query_async(sql,params,100)
	else: request = dispatcher.execute_async(sql,params)
	assert(request != null,dispatcher.get_last_error())
	request.completed.connect(func(_result: Dictionary) -> void: signal_thread=OS.get_thread_caller_id())
	return request

func receive(request: Object, started: int, label: String = "") -> Dictionary:
	assert(request != null)
	var flagged := false
	while not request.is_done():
		if not flagged and Time.get_ticks_usec()-started>QUERY_BUDGET_USEC:
			flagged = true
			failures.append("query_deadline:"+label)
			push_warning("S0 query deadline exceeded: "+label+"; polling for diagnostic drain, no stop/backup while active")
		# A failed deadline is retained as FAIL even if SQL subsequently finishes.
		# Native v0.4.0 has no cancellation; never destroy an active session here.
		await get_tree().process_frame
	var finished := Time.get_ticks_usec()
	if not flagged and finished-started>QUERY_BUDGET_USEC: failures.append("query_deadline:"+label)
	var answer: Dictionary = request.get_result()
	assert(signal_thread==OS.get_main_thread_id(),"completion conversion/signal on main")
	assert(plain(answer),"only data crosses native worker boundary")
	if not label.is_empty():
		if not benchmarks.has(label): benchmarks[label]=[]
		benchmarks[label].append(finished-started)
	intervals.append({"start":started,"end":finished,"label":label})
	return answer

func read(sql: String, params: Dictionary = {}, label: String = "") -> Dictionary:
	var started := Time.get_ticks_usec()
	return await receive(submit(sql,params),started,label)

func execute(sql: String) -> Dictionary:
	var started := Time.get_ticks_usec()
	return await receive(submit(sql,{},false),started)

func drain_and_stop() -> void:
	admissions = false
	assert(submit("SELECT 1;")==null,"closed admissions before drain")
	var started := Time.get_ticks_usec()
	var flagged := false
	while dispatcher.pending()!=0:
		if not flagged and Time.get_ticks_usec()-started>QUERY_BUDGET_USEC:
			flagged=true;failures.append("drain_deadline")
		await get_tree().process_frame
	# pending includes undelivered completions: zero proves no active SQL remains.
	dispatcher.stop()
	assert(not dispatcher.is_started() and dispatcher.pending()==0)
	assert(dispatcher.query_async("SELECT 1;")==null,"stopped native dispatcher rejects submissions")

static func plain(value: Variant) -> bool:
	if value is Object: return false
	if value is Dictionary:
		for key: Variant in value:
			if not plain(key) or not plain(value[key]): return false
	elif value is Array:
		for entry: Variant in value:
			if not plain(entry): return false
	return true

func _ready() -> void:
	var version := Engine.get_version_info()
	assert(OS.is_debug_build() and version.major==4 and version.minor==7 and version.patch==2 and str(version.hash).begins_with("ed1daf0bf"),"pinned Godot 4.7.2 debug")
	Engine.max_fps=240
	var args := CmdlineUtils.get_parsed_args()
	var root: String = args.get("s0-project-root",ProjectSettings.globalize_path("res://"))
	directory=ProjectSettings.globalize_path(args.get("s0-directory","res://.godot/verification/auction-soci-s0"))
	var allowed := root.path_join(".godot/verification").replace("\\","/").simplify_path()+"/"
	var resolved := directory.replace("\\","/").simplify_path()
	if OS.get_name()=="Windows": allowed=allowed.to_lower();resolved=resolved.to_lower()
	assert(resolved.begins_with(allowed),"fixture DB must be below disposable verification root")
	assert(DirAccess.make_dir_recursive_absolute(directory)==OK)
	var extension := "res://.godot/verification/soci-release/package/addons/godot_soci/soci.gdextension"
	var native_profile: String=args.get("s0-native-profile","debug")
	assert(native_profile in ["debug","release"])
	if native_profile=="release": extension="res://.godot/verification/soci-release/soci-release-library.gdextension"
	assert(GDExtensionManager.load_extension(extension)==GDExtensionManager.LOAD_STATUS_OK)
	dispatcher=ClassDB.instantiate("SociQueryDispatcher")
	assert(dispatcher!=null)
	db.path=directory.path_join("market.db")
	# Exact fixed filenames inside the guarded disposable directory only.
	for suffix: String in ["","-wal","-shm"]: DirAccess.remove_absolute(db.path+suffix)
	assert(db.open_db())
	assert(db.query("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA wal_autocheckpoint=0;"))
	WorldSchema.ensure_schema(db)
	var store := WorldStoreSqlite.new(db)
	seed_character=FIXTURE.create_character(store,"s0_seed",{"name":"SociSeed","skin":1})
	buyer=FIXTURE.create_character(store,"s0_buyer",{"name":"SociBuyer","skin":1})
	assert(MarketSearchSqlite.ensure_schema(db))
	CATALOG.seed(db,seed_character)
	persistence=WorldDatabase.new();add_child(persistence)
	persistence.db=db;persistence.database_path=db.path;persistence.store=store
	persistence.item_store=ItemStoreSqlite.new(db);persistence.wallet_store=WalletStoreSqlite.new(db)
	FIXTURE.prepare(persistence)
	assert(persistence.load_wallet(seed_character) and persistence.load_wallet(buyer))
	assert(persistence.item_store.initialize_character(seed_character).ok)
	assert(db.query("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name;"))
	schema_before=db.query_result.duplicate(true)
	assert(db.query("PRAGMA wal_checkpoint(TRUNCATE);"))
	assert(db.query("UPDATE shop_offers SET price_yang=101 WHERE offer_id='%032x';" % 20000))
	start_reader(db.path)
	assert((await execute("PRAGMA query_only=ON;")).ok)
	var state := await read("SELECT value FROM meta WHERE key='schema_version';")
	assert(state.ok and int(state.rows[0].value)==MarketSearchSqlite.LOOKUP_SCHEMA_VERSION)
	var journal := await read("PRAGMA journal_mode;")
	assert(journal.ok and journal.rows[0].journal_mode=="wal")
	var options := await read("PRAGMA compile_options;")
	assert(options.ok and options.rows.any(func(row: Dictionary)->bool:return row.values()[0] in ["THREADSAFE=1","THREADSAFE=2"]))
	print("AUCTION_S0_CONNECTION ",JSON.stringify({"sqlite":await read("SELECT sqlite_version() AS version;"),"options":options.rows,"journal":journal.rows,"schema":22,"native_readonly":true}))
	var forbidden: Array[String] = ["INSERT INTO meta(key,value) VALUES('s0_forbidden','1');","UPDATE meta SET value='changed' WHERE key='schema_version';","DELETE FROM meta WHERE key='schema_version';","CREATE TABLE s0_forbidden_table(value INTEGER);","DROP TABLE meta;"]
	# All probes are valid SQL on the authoritative writer, rolled back completely.
	for sql: String in forbidden:
		assert(db.query("SAVEPOINT s0_readonly_control;") and db.query(sql))
		assert(db.query("ROLLBACK TO s0_readonly_control; RELEASE s0_readonly_control;"))
	for query_only: bool in [true,false]:
		assert((await execute("PRAGMA query_only="+("ON" if query_only else "OFF")+";")).ok)
		for sql: String in forbidden:
			var denied := await execute(sql)
			assert(not denied.ok and not str(denied.error).is_empty(),"native readonly refusal: "+str(denied))
			print("AUCTION_S0_DENIED query_only=",query_only," sql=",sql," result=",JSON.stringify(denied))
		assert(db.query("SELECT value FROM meta WHERE key='schema_version';") and int(db.query_result[0].value)==MarketSearchSqlite.LOOKUP_SCHEMA_VERSION)
		assert(db.query("SELECT value FROM meta WHERE key='s0_forbidden';") and db.query_result.is_empty())
		assert(db.query("SELECT name FROM sqlite_master WHERE name='s0_forbidden_table';") and db.query_result.is_empty())
	assert((await execute("PRAGMA query_only=ON;")).ok)
	var one_sql := "SELECT price_yang FROM shop_offers WHERE offer_id=:offer;"
	var one_params := {"offer":"%032x" % 20000}
	assert(int((await read(one_sql,one_params)).rows[0].price_yang)==101,"reads post-checkpoint WAL")
	assert(db.query("BEGIN IMMEDIATE;") and db.query_with_bindings("UPDATE shop_offers SET price_yang=999999 WHERE offer_id=?;",[one_params.offer]))
	assert(int((await read(one_sql,one_params)).rows[0].price_yang)==101,"no dirty read")
	assert(db.query("ROLLBACK;"))
	assert(db.query_with_bindings("UPDATE shop_offers SET price_yang=102 WHERE offer_id=?;",[one_params.offer]))
	assert(int((await read(one_sql,one_params)).rows[0].price_yang)==102,"next query sees fresh commit")
	last_frame_usec=0;measuring=true
	var default_query := SQL.build(parameters())
	var deadline := Time.get_ticks_msec()+3000
	while Time.get_ticks_msec()<deadline:
		var answer := await read(default_query.sql,default_query.params,"concurrent_default")
		assert(answer.ok and answer.rows.size()==51 and not answer.truncated)
		assert(not SQL.project(answer.rows,parameters(),db).results.is_empty())
	measuring=false
	assert(operations>=3 and offer.get("bought",false),"production list/edit/buy and Yang during reader requests")
	assert_economy(db)
	var overlapping_writes := 0
	for write: int in writes:
		if intervals.any(func(interval: Dictionary)->bool:return interval.label=="concurrent_default" and write>=int(interval.start) and write<=int(interval.end)): overlapping_writes+=1
	assert(overlapping_writes>0 and ticks.size()>0,"main progresses while dispatcher requests remain pending")
	print("AUCTION_S0_CONCURRENCY ",JSON.stringify({"ticks":ticks.size(),"writer_operations":operations,"commits_during_pending_requests":overlapping_writes,"main_frame_max_ms":frame_max_usec/1000.0,"poll_max_ms":poll_max_usec/1000.0,"intervals":"submission_to_delivery; native SQL timestamps unavailable"}))
	await benchmark_searches()
	# Queued actual search: close admissions, drain/poll, then join idle worker.
	var final_request := submit(default_query.sql,default_query.params)
	admissions=false
	assert(submit(default_query.sql,default_query.params)==null)
	await drain_and_stop()
	assert(final_request.is_done() and final_request.get_result().ok)
	assert(persistence.backup_database(),"closed native session before production checkpoint/copy")
	assert_restore()
	for cycle: int in 4:
		start_reader(db.path)
		assert((await execute("PRAGMA query_only=ON;")).ok)
		assert(int((await read("SELECT COUNT(*) AS n FROM shop_offers;")).rows[0].n)==10000)
		assert_economy(db)
		await drain_and_stop()
	var missing := directory.path_join("never-created.db")
	assert(not FileAccess.file_exists(missing))
	start_reader(missing)
	var missing_result := await read("SELECT 1 AS n;")
	assert(not missing_result.ok and not FileAccess.file_exists(missing),"readonly must not create DB")
	print("AUCTION_S0_MISSING ",JSON.stringify(missing_result))
	await drain_and_stop()
	assert(db.query("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name;") and db.query_result==schema_before,"reader did not modify schema")
	assert(db.query("PRAGMA synchronous;") and int(db.query_result[0].synchronous)==2)
	assert(db.query("PRAGMA foreign_key_check;") and db.query_result.is_empty())
	assert(db.query("PRAGMA integrity_check;") and db.query_result[0].values()[0]=="ok")
	assert(db.query("PRAGMA wal_checkpoint(TRUNCATE);") and db.close_db())
	var renamed := db.path+".closed"
	assert(DirAccess.rename_absolute(db.path,renamed)==OK and DirAccess.remove_absolute(renamed)==OK,"all handles closed")
	var summary := {"platform":OS.get_name(),"godot":version.string,"native_profile":native_profile,"tag":"v0.4.0","failures":failures,"benchmarks":benchmark_summary(),"operations":operations,"ticks":ticks.size(),"main_frame_max_ms":frame_max_usec/1000.0,"poll_max_ms":poll_max_usec/1000.0,"latency":"submission_to_delivery_including_poll_not_native_sql"}
	var report := FileAccess.open(directory.path_join("report.json"),FileAccess.WRITE)
	report.store_string(JSON.stringify(summary,"\t")+"\n");report.close()
	print("AUCTION_S0_REPORT ",JSON.stringify(summary))
	print("AUCTION_S0_OK" if failures.is_empty() else "AUCTION_S0_FAILED query budget; safe drain completed, no deadline relaxation")
	get_tree().quit(0 if failures.is_empty() else 1)

func _process(_delta: float) -> void:
	if dispatcher==null or not dispatcher.is_started(): return
	var now := Time.get_ticks_usec()
	if measuring and last_frame_usec!=0: frame_max_usec=maxi(frame_max_usec,now-last_frame_usec)
	last_frame_usec=now
	var started := Time.get_ticks_usec()
	dispatcher.poll()
	poll_max_usec=maxi(poll_max_usec,Time.get_ticks_usec()-started)

func _physics_process(_delta: float) -> void:
	if not measuring: return
	ticks.append(Time.get_ticks_usec())
	if ticks.size()%6!=0: return
	var answer: Dictionary
	if operations==0:
		var item: Dictionary=persistence.item_store.inventory(seed_character).items[0]
		answer=persistence.market_command(seed_character,"list",{"command_id":"s0_list","uid":item.uid,"revision":0,"position":0,"price":100})
		offer=answer.duplicate(true)
	elif operations==1:
		answer=persistence.market_command(seed_character,"edit",{"command_id":"s0_edit","offer_id":offer.offer_id,"revision":0,"position":0,"price":120})
	elif operations==2:
		assert(persistence.add_yang(buyer,30) and persistence.add_yang(seed_character,20))
		answer=persistence.market_command(buyer,"buy",{"command_id":"s0_buy","shop_id":offer.shop_id,"offer_id":offer.offer_id,"revision":1,"price":120})
		offer.bought=answer.ok
	else:
		assert(persistence.add_yang(buyer,2));answer=persistence.spend_yang(buyer,1)
	assert(answer.ok,"production economic writer: "+str(answer))
	operations+=1;writes.append(Time.get_ticks_usec())

func benchmark_searches() -> void:
	var cases := {"default":parameters(),"broad_affix":parameters(),"selective":parameters(),"descending":parameters()}
	cases.broad_affix.affix_filters=[{"stat_id":"monster_damage","minimum":0}]
	cases.selective.merge({"upgrade_min":5,"upgrade_max":7,"price_min":4000,"price_max":8000,"affix_filters":[{"stat_id":"monster_damage","minimum":15},{"stat_id":"critical_chance","minimum":7}]},true)
	cases.descending.sort="price_desc"
	var first := MarketSearchSqlite.new(db).search(parameters())
	assert(first.ok and not first.next_cursor.is_empty())
	cases["pagination"]=parameters();cases.pagination.cursor=first.next_cursor
	var first_desc := MarketSearchSqlite.new(db).search(cases.descending)
	assert(first_desc.ok and not first_desc.next_cursor.is_empty())
	cases["pagination_desc"]=cases.descending.duplicate(true);cases.pagination_desc.cursor=first_desc.next_cursor
	for label: String in cases:
		var p: Dictionary=cases[label]
		var built := SQL.build(p)
		assert(db.query_with_bindings("EXPLAIN QUERY PLAN "+built.sql.replace(":definition","?").replace(":upgrade_min","?").replace(":upgrade_max","?").replace(":price_min","?").replace(":price_max","?").replace(":stat_0","?").replace(":minimum_0","?").replace(":stat_1","?").replace(":minimum_1","?").replace(":cursor_price","?").replace(":cursor_equal","?").replace(":cursor_id","?").replace(":row_limit","?"),built.params.values()))
		print("AUCTION_S0_WRITER_PLAN ",label," ",JSON.stringify(db.query_result))
		var reader_plan := await read("EXPLAIN QUERY PLAN "+built.sql,built.params)
		assert(reader_plan.ok)
		print("AUCTION_S0_READER_PLAN ",label," ",JSON.stringify(reader_plan.rows))
		# Reference runs outside main-progress measurements; same current production SQL.
		var reference := MarketSearchSqlite.new(db)
		var expected := reference.search(p)
		assert(expected.ok)
		print("AUCTION_S0_REFERENCE ",label," sql_ms=",reference.last_db_usec/1000.0)
		last_frame_usec=0;measuring=true
		for sample: int in 5:
			var answer := await read(built.sql,built.params,label)
			assert(answer.ok and not answer.truncated,str(answer))
			assert(SQL.project(answer.rows,p,db)==expected,"search semantics/cursor: "+label)
		measuring=false

func benchmark_summary() -> Dictionary:
	var result: Dictionary={}
	for label: String in benchmarks:
		var samples: Array=benchmarks[label].duplicate();samples.sort()
		result[label]={"samples":samples.size(),"p50_ms":samples[int(samples.size()*0.5)]/1000.0,"p95_ms":samples[mini(samples.size()-1,int(ceil(samples.size()*0.95))-1)]/1000.0,"max_ms":samples.back()/1000.0}
	return result

func assert_economy(connection_db: SQLite) -> void:
	assert(connection_db.query_with_bindings("SELECT owner_character_id FROM item_instances WHERE uid=?;",[offer.uid]) and int(connection_db.query_result[0].owner_character_id)==buyer)
	assert(connection_db.query_with_bindings("SELECT location,owner_id FROM item_custody WHERE uid=?;",[offer.uid]) and connection_db.query_result[0].location=="bag" and int(connection_db.query_result[0].owner_id)==buyer)
	assert(connection_db.query("SELECT COUNT(*) AS n FROM market_commands WHERE command_id='s0_buy';") and int(connection_db.query_result[0].n)==1)
	for entry: Array in [[buyer,1410+operations-3],[seed_character,1640]]:
		assert(connection_db.query_with_bindings("SELECT yang FROM account_wallets WHERE account_id=?;",[persistence.wallet_account_id(int(entry[0]))]) and int(connection_db.query_result[0].yang)==int(entry[1]))
		assert(persistence.wallet_balance(int(entry[0]))==int(entry[1]),"SQL/RAM wallets agree")

func assert_restore() -> void:
	var backups: Array[String]=[]
	for file: String in DirAccess.get_files_at("user://db_backups"):
		if file.begins_with("market_") and file.ends_with(".db"): backups.append(file)
	backups.sort();assert(not backups.is_empty())
	var restored := SQLite.new()
	restored.path=ProjectSettings.globalize_path("user://db_backups/"+backups.back())
	assert(restored.open_db())
	assert(restored.query("PRAGMA integrity_check;") and restored.query_result[0].values()[0]=="ok")
	assert(restored.query("PRAGMA foreign_key_check;") and restored.query_result.is_empty())
	assert_economy(restored)
	assert(restored.close_db())
