extends Node
## D0 boundary proof only. Production search, dispatcher and lifecycle are untouched.
const PROBE := preload("res://tests/fixtures/auction_read_probe.gd")
const FIXTURE := preload("res://tests/economy_fixture.gd")
const CATALOG := preload("res://tests/fixtures/market_search_fixture.gd")
const SEARCH_SQL := "SELECT i.*,c.location,c.position AS bag_position,'' AS equipment_slot,o.offer_id,o.shop_id,o.price_yang,o.revision AS offer_revision,s.display_name AS shop_name FROM shop_offers o JOIN account_shops s ON s.shop_id=o.shop_id JOIN item_instances i ON i.uid=o.item_uid JOIN item_custody c ON c.uid=i.uid WHERE s.status='active' AND i.definition_id=? AND i.upgrade_level BETWEEN ? AND ? AND o.price_yang BETWEEN ? AND ? ORDER BY o.price_yang ASC,o.offer_id ASC LIMIT ?;"
var db:=SQLite.new()
var persistence: WorldDatabase
var worker:=PROBE.new()
var directory: String
var seed_character := 0
var buyer := 0
var offer: Dictionary
var shop_revision := 0
var bought := false
var measuring := false
var ticks: Array[int]=[]
var writes: Array[int]=[]
var statements: Array[Dictionary]=[]
var operations := 0
var replies := 0
var rows := 0

static func uri(path: String) -> String:
	var normalized:=path.replace("\\","/")
	if not normalized.begins_with("/"): normalized="/"+normalized
	return "file://"+normalized.replace("%","%25").replace("#","%23").replace("?","%3F").replace(" ","%20")+"?mode=ro"

static func plain(value: Variant) -> bool:
	if value is Object: return false
	if value is Dictionary:
		for key: Variant in value:
			if not plain(key) or not plain(value[key]): return false
	elif value is Array:
		for entry: Variant in value:
			if not plain(entry): return false
	return true

func wait_state(wanted: String, budget_ms: int = 2000) -> bool:
	var deadline:=Time.get_ticks_msec()+budget_ms
	while worker.status().state!=wanted and worker.status().state!="failed" and Time.get_ticks_msec()<deadline:
		await get_tree().physics_frame
	return worker.status().state==wanted

func result() -> Dictionary:
	var deadline:=Time.get_ticks_msec()+2000
	while Time.get_ticks_msec()<deadline:
		var answer:=worker.take_result()
		if not answer.is_empty(): return answer
		await get_tree().physics_frame
	assert(false,"worker result deadline");return {}

func stop_worker() -> void:
	worker.request_stop()
	assert(await wait_state("stopped"),"bounded clean stop")
	while not worker.join_if_finished(): await get_tree().physics_frame
	assert(worker.status().closed and worker.status().close_thread_id!=OS.get_main_thread_id())

func _ready() -> void:
	var version:=Engine.get_version_info()
	if not OS.is_debug_build() or version.major!=4 or version.minor!=7 or version.patch!=2:
		push_error("D0 proof requires the pinned Godot 4.7.2 editor/debug engine; fixture assertions are mandatory")
		get_tree().quit(1);return
	directory=ProjectSettings.globalize_path(CmdlineUtils.get_parsed_args().get("d0-directory","res://.godot/verification/auction-d0"))
	# res:// points at the pack directory when launched with --main-pack.
	var project_root: String=CmdlineUtils.get_parsed_args().get("d0-project-root",ProjectSettings.globalize_path("res://"))
	var allowed:=project_root.path_join(".godot/verification").replace("\\","/").simplify_path()+"/"
	var resolved:=directory.replace("\\","/").simplify_path()
	if OS.get_name()=="Windows": allowed=allowed.to_lower();resolved=resolved.to_lower()
	if not resolved.begins_with(allowed):
		push_error("Refusing D0 database outside disposable verification directory")
		get_tree().quit(1);return
	assert(DirAccess.make_dir_recursive_absolute(directory)==OK)
	db.path=directory.path_join("market.db")
	for suffix: String in ["","-wal","-shm"]: DirAccess.remove_absolute(db.path+suffix)
	assert(db.open_db())
	assert(db.query("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA wal_autocheckpoint=0;"))
	WorldSchema.ensure_schema(db)
	var store:=WorldStoreSqlite.new(db)
	seed_character=FIXTURE.create_character(store,"thread_seed",{"name":"ThreadSeed","skin":1})
	buyer=FIXTURE.create_character(store,"thread_buyer",{"name":"ThreadBuyer","skin":1})
	assert(MarketSearchSqlite.ensure_schema(db))
	CATALOG.seed(db,seed_character)
	persistence=WorldDatabase.new();add_child(persistence)
	persistence.db=db;persistence.database_path=db.path;persistence.store=store
	persistence.item_store=ItemStoreSqlite.new(db);persistence.wallet_store=WalletStoreSqlite.new(db)
	FIXTURE.prepare(persistence)
	assert(persistence.load_wallet(seed_character) and persistence.load_wallet(buyer))
	assert(persistence.item_store.initialize_character(seed_character).ok)
	var item: Dictionary=persistence.item_store.inventory(seed_character).items[0]
	offer=persistence.market_command(seed_character,"list",{"command_id":"d0_list","uid":item.uid,"revision":0,"position":0,"price":100})
	assert(offer.ok);offer.price=100
	assert(db.query("PRAGMA wal_checkpoint(TRUNCATE);"))
	# Commit a frame after checkpoint; a valid reader must include this WAL data.
	assert(db.query("UPDATE shop_offers SET price_yang=101 WHERE offer_id='"+offer.offer_id+"';"));offer.price=101
	assert(worker.start(db.path,true)==OK)
	var plugin_ok:=await wait_state("idle")
	print("AUCTION_D0_PLUGIN_VFS ",JSON.stringify(worker.status()))
	if plugin_ok: await stop_worker()
	else:
		assert(worker.status().state=="failed");while not worker.join_if_finished(): await get_tree().physics_frame
	assert(worker.start(uri(db.path))==OK and await wait_state("idle"))
	var opening:=worker.status()
	assert(opening.thread_id!=OS.get_main_thread_id() and opening.connection_instance!=db.get_instance_id())
	assert(opening.schema==MarketSearchSqlite.LOOKUP_SCHEMA_VERSION and opening.journal=="wal")
	assert(opening.options.any(func(option: Dictionary)->bool:return option.values()[0]=="THREADSAFE=1" or option.values()[0]=="THREADSAFE=2"))
	print("AUCTION_D0_CONNECTION ",JSON.stringify(opening)," main_thread=",OS.get_main_thread_id()," writer_instance=",db.get_instance_id())
	var one_sql:="SELECT price_yang FROM shop_offers WHERE offer_id=?;"
	assert(worker.submit(one_sql,[offer.offer_id]));assert((await result()).rows[0].price_yang==101,"native reader sees committed WAL")
	assert(db.query("BEGIN IMMEDIATE;") and db.query_with_bindings("UPDATE shop_offers SET price_yang=999999 WHERE offer_id=?;",[offer.offer_id]))
	assert(worker.submit(one_sql,[offer.offer_id]));assert((await result()).rows[0].price_yang==101,"no dirty/uncommitted reads")
	assert(db.query("ROLLBACK;"))
	assert(persistence.market_command(seed_character,"edit",{"command_id":"d0_visible","offer_id":offer.offer_id,"revision":0,"position":0,"price":110}).ok)
	offer.revision=1;offer.price=110
	assert(worker.submit(one_sql,[offer.offer_id]));assert((await result()).rows[0].price_yang==110,"next query sees committed revision")
	measuring=true
	var deadline:=Time.get_ticks_msec()+3000
	while Time.get_ticks_msec()<deadline:
		assert(worker.submit(SEARCH_SQL,["iron_sword",0,9,0,WalletStoreSqlite.MAX_YANG,51],4))
		var answer:=await result()
		assert(answer.ok and answer.thread_id!=OS.get_main_thread_id() and answer.rows.size()==51)
		assert(plain(answer),"thread handoff contains copied data, never nodes/resources/SQLite")
		statements.append_array(answer.timings);replies+=1;rows+=answer.rows.size()
		# Resource-dependent projection runs here, never in the worker.
		assert(not MarketStoreSqlite.new(db)._item_view(answer.rows[0]).is_empty())
	measuring=false
	var overlapping_ticks:=0;var overlapping_writes:=0
	for timing: Dictionary in statements:
		for tick: int in ticks:
			if tick>=int(timing.start) and tick<=int(timing.end): overlapping_ticks+=1
		for write: int in writes:
			if write>=int(timing.start) and write<=int(timing.end): overlapping_writes+=1
	assert(overlapping_ticks>0 and overlapping_writes>0 and operations>=3 and bought,"main-thread progress and economic COMMIT overlap actual worker SQL")
	assert(db.query_with_bindings("SELECT owner_character_id FROM item_instances WHERE uid=?;",[offer.uid]) and int(db.query_result[0].owner_character_id)==buyer)
	assert_balances(db)
	var durations: Array[int]=[]
	for timing: Dictionary in statements: durations.append(int(timing.end)-int(timing.start))
	durations.sort()
	print("AUCTION_D0_CONCURRENCY ",JSON.stringify({"batches":replies,"queries":statements.size(),"raw_rows":rows,"ticks":ticks.size(),"writer_operations":operations,"ticks_during_sql":overlapping_ticks,"commits_during_sql":overlapping_writes,"sql_p50_ms":durations[int(durations.size()*0.5)]/1000.0,"sql_p95_ms":durations[int(durations.size()*0.95)]/1000.0,"sql_max_ms":durations.back()/1000.0}))
	# Retain a snapshot and commit afterwards: current TRUNCATE backup must fail.
	assert(worker.submit("SELECT value FROM meta WHERE key='schema_version';",[],1,true))
	assert(await wait_state("holding"))
	assert(persistence.market_command(seed_character,"configure",{"command_id":"d0_before_backup","revision":shop_revision,"name":"After reader snapshot","status":"active"}).ok);shop_revision+=1
	assert(not persistence.backup_database(),"active WAL snapshot refuses unsafe backup")
	worker.request_pause()
	assert(not await wait_state("paused",50),"reader drain has a bounded failure path, not an unlimited wait")
	assert(not persistence.backup_database(),"timeout must not claim a successful backup")
	worker.release_hold();assert((await result()).ok)
	assert(await wait_state("paused") and worker.status().closed)
	assert(not worker.submit(one_sql,[offer.offer_id]),"paused reader refuses new jobs")
	assert(persistence.backup_database(),"drained/closed reader allows production checkpoint+copy")
	assert_restore()
	worker.resume();assert(await wait_state("idle"))
	assert(worker.submit("SELECT display_name FROM account_shops WHERE shop_id=?;",[offer.shop_id]))
	assert((await result()).rows[0].display_name=="After reader snapshot")
	await stop_worker()
	for cycle: int in 4:
		assert(worker.start(uri(db.path))==OK and await wait_state("idle"))
		assert(worker.submit("SELECT COUNT(*) AS n FROM shop_offers;"));assert((await result()).rows[0].n==10000)
		await stop_worker()
	# mode=ro must not silently create a missing DB or run a schema migration.
	var missing:=directory.path_join("never-created.db")
	assert(worker.start(uri(missing))==OK and not await wait_state("idle"))
	assert(worker.status().state=="failed" and not FileAccess.file_exists(missing))
	while not worker.join_if_finished(): await get_tree().physics_frame
	assert(db.query("PRAGMA synchronous;") and int(db.query_result[0].synchronous)==2,"writer FULL unchanged")
	assert(db.query("SELECT value FROM meta WHERE key='d0_forbidden';") and db.query_result.is_empty())
	assert(db.query("SELECT name FROM sqlite_master WHERE name='d0_forbidden_table';") and db.query_result.is_empty())
	assert(db.query("SELECT value FROM meta WHERE key='schema_version';") and int(db.query_result[0].value)==MarketSearchSqlite.LOOKUP_SCHEMA_VERSION)
	assert(db.query("PRAGMA foreign_key_check;") and db.query_result.is_empty())
	assert(db.query("PRAGMA integrity_check;") and db.query_result[0].values()[0]=="ok")
	assert(db.query("PRAGMA wal_checkpoint(TRUNCATE);") and db.close_db())
	var renamed:=db.path+".closed"
	assert(DirAccess.rename_absolute(db.path,renamed)==OK and DirAccess.remove_absolute(renamed)==OK)
	print("AUCTION_D0_OK distinct thread-owned handles, OS read-only, concurrent commits, visibility, bounded reader drain, production backup/restore, four restarts, FULL/FKs/integrity")
	get_tree().quit()

func _physics_process(_delta: float) -> void:
	if not measuring: return
	ticks.append(Time.get_ticks_usec())
	if ticks.size()%6!=0: return
	var answer: Dictionary
	if operations==0:
		answer=persistence.market_command(seed_character,"edit",{"command_id":"d0_edit","offer_id":offer.offer_id,"revision":int(offer.revision),"position":0,"price":120})
		offer.price=120
	elif operations==1:
		answer=persistence.market_command(seed_character,"configure",{"command_id":"d0_config","revision":shop_revision,"name":"Concurrent writer","status":"active"});shop_revision+=1
	elif operations==2:
		assert(persistence.add_yang(buyer,30) and persistence.add_yang(seed_character,20))
		answer=persistence.market_command(buyer,"buy",{"command_id":"d0_buy","shop_id":offer.shop_id,"offer_id":offer.offer_id,"revision":int(offer.revision)+1,"price":120})
		bought=answer.ok
	else:
		assert(persistence.add_yang(buyer,2));answer=persistence.spend_yang(buyer,1)
	assert(answer.ok,"concurrent authoritative economic operation: "+str(answer))
	operations+=1;writes.append(Time.get_ticks_usec())

func assert_restore() -> void:
	var files:=DirAccess.get_files_at("user://db_backups")
	var backups: Array[String]=[]
	for file: String in files:
		if file.begins_with("market_") and file.ends_with(".db"): backups.append(file)
	backups.sort();assert(not backups.is_empty())
	var restored:=SQLite.new();restored.path=ProjectSettings.globalize_path("user://db_backups/"+backups.back())
	assert(restored.open_db())
	assert(restored.query("PRAGMA integrity_check;") and restored.query_result[0].values()[0]=="ok")
	assert(restored.query("PRAGMA foreign_key_check;") and restored.query_result.is_empty())
	assert(restored.query_with_bindings("SELECT owner_character_id FROM item_instances WHERE uid=?;",[offer.uid]) and int(restored.query_result[0].owner_character_id)==buyer)
	assert(restored.query("SELECT COUNT(*) AS n FROM market_commands WHERE command_id='d0_buy';") and restored.query_result[0].n==1)
	assert(restored.query_with_bindings("SELECT display_name FROM account_shops WHERE shop_id=?;",[offer.shop_id]) and restored.query_result[0].display_name=="After reader snapshot")
	assert_balances(restored)
	assert(restored.close_db())

func assert_balances(connection: SQLite) -> void:
	var expected_buyer:=1410+operations-3 # 1500 + pending 30 - purchase 120 + net 1/spend.
	for entry: Array in [[buyer,expected_buyer],[seed_character,1640]]:
		assert(connection.query_with_bindings("SELECT yang FROM account_wallets WHERE account_id=?;",[persistence.wallet_account_id(int(entry[0]))]) and int(connection.query_result[0].yang)==int(entry[1]))
		assert(persistence.wallet_balance(int(entry[0]))==int(entry[1]),"SQL and authoritative RAM agree after committed pending income")

func _exit_tree() -> void: worker.emergency_stop()
