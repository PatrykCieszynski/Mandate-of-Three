extends Node
## Historical P0 controls plus D1a production migration; same SQL/snapshot.
const FIXTURE := preload("res://tests/economy_fixture.gd")
const CATALOG := preload("res://tests/fixtures/market_search_fixture.gd")
const SQL := preload("res://tests/fixtures/auction_soci_sql.gd")
const BUDGET_US := 2000000
var dispatcher: Object
var reader: Object
var records: Array = []
var plans: Array = []
var telemetry: Dictionary = {}
var failures: Array[String] = []
var directory: String
var profile: String
var instrumented := false
var current_started := 0
var poll_max_us := 0
var ticks := 0
var measuring := false
var wait_mode := "frame"

static func uri(path: String) -> String:
	var value := path.replace("\\","/")
	if not value.begins_with("/"): value="/"+value
	return "file://"+value.replace("%","%25").replace("#","%23").replace("?","%3F").replace(" ","%20")+"?mode=ro"

static func params() -> Dictionary:
	return {"definition_id":"iron_sword","upgrade_min":0,"upgrade_max":9,"price_min":0,"price_max":WalletStoreSqlite.MAX_YANG,"affix_filters":[],"sort":"price_asc","cursor":"","limit":50}

func _ready() -> void:
	var v := Engine.get_version_info()
	assert(OS.is_debug_build() and v.major==4 and v.minor==7 and v.patch==2)
	Engine.max_fps=500
	var args := CmdlineUtils.get_parsed_args()
	wait_mode=args.get("p0-wait","frame")
	assert(wait_mode in ["frame","signal"])
	profile=args.get("p0-profile","release")
	directory=ProjectSettings.globalize_path(args.get("p0-directory","res://.godot/verification/auction-p0/release"))
	var allowed := ProjectSettings.globalize_path("res://.godot/verification/").replace("\\","/").simplify_path()+"/"
	var actual := directory.replace("\\","/").simplify_path()
	if OS.get_name()=="Windows": allowed=allowed.to_lower();actual=actual.to_lower()
	assert(actual.begins_with(allowed))
	assert(DirAccess.make_dir_recursive_absolute(directory)==OK)
	var base := ProjectSettings.globalize_path("res://.godot/verification/auction-p0/base.db")
	if args.has("p0-seed"):
		create_fixture(base); print("AUCTION_P0_SEED_OK");get_tree().quit();return
	assert(FileAccess.file_exists(base))
	instrumented=profile.begins_with("diag-")
	var extension: String=args.get("p0-extension","res://.godot/verification/soci-release/soci-release-library.gdextension")
	assert(GDExtensionManager.load_extension(extension)==GDExtensionManager.LOAD_STATUS_OK)
	dispatcher=ClassDB.instantiate("SociQueryDispatcher")
	var states: Array=["baseline","lookup","baseline_analyzed","lookup_analyzed"]
	if args.get("p0-state","all")!="all": states=[args["p0-state"]]
	if args.has("p0-probe"): states=["lookup"]
	for state: String in states:
		var path := directory.path_join(state+".db")
		for suffix: String in ["","-wal","-shm"]: DirAccess.remove_absolute(path+suffix)
		assert(DirAccess.copy_absolute(base,path)==OK)
		var db := SQLite.new();db.path=path;db.verbosity_level=0
		assert(db.open_db() and db.query("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;"))
		if state.begins_with("migrated"):
			assert(ExchangeStoreSqlite.ensure_ledger_schema(db) and ExchangeStoreSqlite.ensure_orders_schema(db))
			assert(MarketSearchSqlite.ensure_lookup_schema(db))
		if state.begins_with("lookup"): assert(db.query("CREATE INDEX affix_item_lookup ON item_affix_index(uid,stat_id,value);"))
		if state.ends_with("analyzed"): assert(db.query("ANALYZE;"))
		assert(db.query("PRAGMA wal_checkpoint(TRUNCATE);"))
		var cases := {"default":params(),"broad":params(),"medium":params(),"selective":params(),"rare":params(),"empty":params(),"descending":params()}
		cases.broad.affix_filters=[{"stat_id":"monster_damage","minimum":0}]
		cases.medium.affix_filters=[{"stat_id":"monster_damage","minimum":15}]
		cases.selective.merge({"upgrade_min":5,"upgrade_max":7,"price_min":4000,"price_max":8000,"affix_filters":[{"stat_id":"monster_damage","minimum":15},{"stat_id":"critical_chance","minimum":7}]},true)
		cases.rare.merge({"upgrade_min":7,"upgrade_max":7,"price_min":9900,"price_max":10000,"affix_filters":[{"stat_id":"monster_damage","minimum":15}]},true)
		cases.empty.affix_filters=[{"stat_id":"monster_damage","minimum":100}]
		cases.descending.sort="price_desc"
		var first := MarketSearchSqlite.new(db).search(params())
		cases["pagination"]=params();cases.pagination.cursor=first.next_cursor
		var tie := params();tie.price_min=100;tie.price_max=100;tie.limit=1
		# Fixture-only equal-price pair covers repeated cursor price bindings.
		assert(db.query("UPDATE shop_offers SET price_yang=100 WHERE offer_id='%032x';" % 20000))
		var tie_first := MarketSearchSqlite.new(db).search(tie)
		assert(not tie_first.next_cursor.is_empty())
		cases["tie_pagination"]=tie;cases.tie_pagination.cursor=tie_first.next_cursor
		if args.has("p0-probe"): cases={"default":params()}
		if args.has("p0-case"):
			assert(cases.has(args["p0-case"]));cases={args["p0-case"]:cases[args["p0-case"]]}
		assert(db.query("PRAGMA wal_checkpoint(TRUNCATE);"))
		for label: String in cases:
			var p: Dictionary=cases[label]
			var built := SQL.build(p)
			var expected := MarketSearchSqlite.new(db).search(p)
			assert(expected.ok)
			var count_sql: String="SELECT COUNT(*) AS n"+built.sql.substr(built.sql.find(" FROM "))
			assert(db.query_with_bindings(count_sql,built.params.values()))
			var matches := int(db.query_result[0].n)
			assert(db.query_with_bindings("EXPLAIN QUERY PLAN "+built.sql,built.params.values()))
			plans.append({"state":state,"case":label,"adapter":"installed_gdsqlite","matches":matches,"plan":db.query_result.duplicate(true)})
			var adapters: Array=["installed_gdsqlite","diagnostic_gdsqlite","soci"] if instrumented else ["installed_gdsqlite","soci"]
			if args.has("p0-skip-installed"): adapters.erase("installed_gdsqlite")
			for adapter: String in adapters:
				await open_reader(adapter,path)
				var explain := await query(adapter,"EXPLAIN QUERY PLAN "+built.sql,built.params)
				plans.append({"state":state,"case":label,"adapter":adapter,"matches":matches,"plan":explain.rows})
				await close_reader(adapter)
				await open_reader(adapter,path)
				measuring=true
				var cold := await sample(adapter,built,p,expected,db,state,label,"connection_cold",matches)
				# Two unrecorded warmups, with the same fixed deadline accounting.
				var slow: bool=int(cold.wall_us)>BUDGET_US or int(cold.get("sql_us",0))>BUDGET_US
				for warmup: int in (1 if slow else 2):
					var answer := await query(adapter,built.sql,built.params)
					assert(SQL.project(answer.rows,p,db)==expected)
					if int(answer.wall_us)>BUDGET_US or int(answer.get("p0",{}).get("sql_us",0))>BUDGET_US:
						failures.append(state+":"+label+":"+adapter+":warmup")
				var sample_count := 1 if args.has("p0-probe") else (3 if slow else 30)
				for iteration: int in sample_count:
					await sample(adapter,built,p,expected,db,state,label,"warm",matches)
				measuring=false
				await close_reader(adapter)
				print("AUCTION_P0_CASE ",JSON.stringify({"profile":profile,"state":state,"case":label,"adapter":adapter,"warm_samples":sample_count,"matches":matches,"returned":int(p.limit)+1 if expected.next_cursor!="" else expected.results.size(),"slow_diagnostic":slow}))
		assert(db.query("PRAGMA integrity_check;") and db.query_result[0].values()[0]=="ok")
		assert(db.query("PRAGMA foreign_key_check;") and db.query_result.is_empty())
		assert(db.close_db())
	var output := {"profile":profile,"wait_mode":wait_mode,"probe_only":args.has("p0-probe"),"instrumented":instrumented,"records":records,"plans":plans,"telemetry":telemetry,"failures":failures,"ticks_during_async":ticks,"poll_max_us":poll_max_us,"gate_us":BUDGET_US,"cold_definition":"fresh configured connection; OS filesystem cache not purged","godot":v.string}
	var file := FileAccess.open(directory.path_join("raw.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(output,"\t")+"\n");file.close()
	print("AUCTION_P0_FINISHED ",profile," failures=",failures.size()," records=",records.size())
	get_tree().quit(0 if failures.is_empty() else 1)

func create_fixture(path: String) -> void:
	for suffix: String in ["","-wal","-shm"]: DirAccess.remove_absolute(path+suffix)
	var db := SQLite.new();db.path=path;db.verbosity_level=0
	assert(db.open_db() and db.query("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;"))
	WorldSchema.ensure_schema(db)
	var owner := FIXTURE.create_character(WorldStoreSqlite.new(db),"p0_seed",{"name":"P0Seed","skin":1})
	assert(MarketSearchSqlite.ensure_schema(db));CATALOG.seed(db,owner)
	assert(db.query("PRAGMA wal_checkpoint(TRUNCATE);") and db.close_db())

func open_reader(adapter: String, path: String) -> void:
	if adapter=="soci":
		assert(dispatcher.start("sqlite3","dbname='"+path.replace("\\","/")+"' readonly=true timeout=1",8))
		var request: Object=dispatcher.execute_async("PRAGMA query_only=ON;")
		while not request.is_done(): await get_tree().process_frame
		assert(request.get_result().ok)
	else:
		reader=ClassDB.instantiate("SQLiteP0") if adapter=="diagnostic_gdsqlite" else SQLite.new()
		reader.path=uri(path);reader.default_extension="";reader.read_only=false;reader.verbosity_level=0
		assert(reader.open_db() and reader.query("PRAGMA query_only=ON;"))
	if not telemetry.has(adapter):
		telemetry[adapter]={"version":await query(adapter,"SELECT sqlite_version() AS version;",{}),"options":await query(adapter,"PRAGMA compile_options;",{})}

func close_reader(adapter: String) -> void:
	if adapter=="soci":
		while dispatcher.pending()!=0: await get_tree().process_frame
		dispatcher.stop()
	else:
		assert(reader.close_db());reader=null

func query(adapter: String, sql: String, bindings: Dictionary) -> Dictionary:
	var started := Time.get_ticks_usec()
	var answer: Dictionary
	if adapter=="soci":
		var request: Object=dispatcher.query_async(sql,bindings,100)
		assert(request!=null)
		if wait_mode=="signal":
			if not request.is_done(): await request.completed
		else:
			while not request.is_done(): await get_tree().process_frame
		answer=request.get_result();assert(answer.ok,str(answer))
	else:
		assert(reader.query_with_bindings(sql,bindings.values()),str(reader.error_message))
		answer={"ok":true,"rows":reader.query_result}
		if adapter=="diagnostic_gdsqlite": answer.p0=reader.p0_get_metrics()
	answer.wall_us=Time.get_ticks_usec()-started
	return answer

func sample(adapter: String, built: Dictionary, p: Dictionary, expected: Dictionary, db: SQLite, state: String, label: String, phase: String, matches: int) -> Dictionary:
	var answer := await query(adapter,built.sql,built.params)
	if phase=="connection_cold" and adapter=="installed_gdsqlite":
		# Exact SQL/bindings and ordered IDs for the standalone SOCI quick check.
		var transfer := FileAccess.open(directory.path_join(state+"-"+label+"-pure.txt"),FileAccess.WRITE)
		transfer.store_line(built.sql)
		for key: String in built.params:
			var value: Variant=built.params[key]
			transfer.store_line(key+"\t"+("s" if value is String else "d" if value is float else "i")+"\t"+str(value))
		transfer.store_line("")
		for row: Dictionary in answer.rows: transfer.store_line(str(row.offer_id)+"\t"+str(int(row.price_yang)))
		transfer.close()
	var projection := Time.get_ticks_usec()
	assert(SQL.project(answer.rows,p,db)==expected,"exact item/result/cursor parity")
	var entry: Dictionary=answer.get("p0",{}).duplicate(true)
	entry.merge({"adapter":adapter,"state":state,"case":label,"phase":phase,"wall_us":answer.wall_us,"projection_us":Time.get_ticks_usec()-projection,"rows":answer.rows.size(),"matches":matches,"cursor":expected.next_cursor})
	if int(entry.wall_us)>BUDGET_US or int(entry.get("sql_us",0))>BUDGET_US:
		failures.append(state+":"+label+":"+adapter+":"+phase)
	if adapter=="soci" and instrumented:
		assert(entry.has("sql_us") and int(entry.native_total_us)>=int(entry.sql_us) and int(entry.sql_calls)>0,"instrumentation observes actual SQL")
	records.append(entry)
	return entry

func _process(_delta: float) -> void:
	if dispatcher!=null and dispatcher.is_started():
		var started := Time.get_ticks_usec();dispatcher.poll()
		poll_max_us=maxi(poll_max_us,Time.get_ticks_usec()-started)
		if measuring: ticks+=1
