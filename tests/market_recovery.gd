extends Node
var db:=SQLite.new()
var load_service: AuctionQueryService
var load_next_ms := 0
var load_sequence := 0
const LOAD_PARAMS := {"definition_id":"iron_sword","upgrade_min":0,"upgrade_max":9,"price_min":0,"price_max":9000000000000000,"affix_filters":[{"stat_id":"monster_damage","minimum":0}],"sort":"price_asc","cursor":"","limit":50}
func _ready() -> void:
	Engine.max_fps=60
	var phase: String=CmdlineUtils.get_parsed_args().get("recovery-phase","read")
	db.path="res://.godot/verification/market-recovery.db" if phase=="write" else "res://.godot/verification/market-restored.db"
	assert(db.open_db());assert(db.query("PRAGMA journal_mode=WAL;") and db.query("PRAGMA synchronous=FULL;"));WorldSchema.ensure_schema(db)
	var store:=WorldStoreSqlite.new(db)
	if phase=="write":
		var owner:=EconomyFixture.create_character(store,"recovery",{"name":"Recovery","skin":1})
		assert(MarketSearchSqlite.ensure_schema(db) and ExchangeStoreSqlite.ensure_ledger_schema(db) and ExchangeStoreSqlite.ensure_orders_schema(db))
		preload("res://tests/fixtures/market_search_fixture.gd").seed(db,owner,true)
		var items:=ItemStoreSqlite.new(db);assert(items.initialize_character(owner).ok)
		var market:=MarketStoreSqlite.new(db);var sword: Dictionary=items.inventory(owner).items[0]
		assert(market.list_item(owner,"durable_list",sword.uid,sword.revision,0,100).ok)
		var ore:=ItemInstance.create(ItemDefinitions.UPGRADE_ORE,owner,[]);ore.amount=100
		assert(EconomyFixture.insert_item(items,ore,2))
		var exchange:=ExchangeStoreSqlite.new(db);assert(exchange.deposit(owner,"durable_deposit",ore.uid,0,100,"bag").ok)
		assert(exchange.place_order(owner,{"command_id":"durable_order","have_asset":"upgrade_ore","want_asset":"yang","quantity":100,"price_num":10,"price_den":1},{}).ok)
		var persistence:=WorldDatabase.new();add_child(persistence);persistence.db=db;persistence.database_path=db.path;persistence.store=store;persistence.item_store=items
		EconomyFixture.prepare(persistence)
		assert(await persistence.start_auction_queries())
		assert(await persistence.coordinated_backup(),"production drain/checkpoint backup with escrow and order")
		load_service=persistence.auction_queries
		# The runner kills this owned process with live async search traffic; the
		# native connection must not invalidate committed writer state in the WAL.
		while load_service.active.is_empty(): await get_tree().process_frame
		assert(market.configure(owner,"after_checkpoint",0,"Recovered from WAL","active").ok)
		var buyer:=EconomyFixture.create_character(store,"recovery_buyer",{"name":"RecoveryBuyer","skin":1})
		var sold:=ItemInstance.create(ItemDefinitions.IRON_SWORD,owner,[])
		assert(EconomyFixture.insert_item(items,sold,items._free_bag_position(owner,2)))
		var offer:=market.list_item(owner,"wal_revenue_list",sold.uid,0,10,90)
		assert(offer.ok and market.purchase(buyer,"wal_revenue_buy",offer.shop_id,offer.offer_id,0,90,{}).ok)
		assert(db.query_with_bindings("UPDATE account_wallets SET yang=? WHERE account_id=?;",[WalletStoreSqlite.MAX_YANG-50,store.resolve_account_id(owner)]))
		var collected:=market.claim_revenue(owner,"wal_revenue_collect",0)
		assert(collected.ok and collected.claimed==50 and market.mine(owner).claimable_yang=="40")
		assert(FileAccess.file_exists(db.path+"-wal") and FileAccess.open(db.path+"-wal",FileAccess.READ).get_length()>32,"committed WAL survives beyond the prior backup")
		print("MARKET_RECOVERY_READY")
		return # Runner terminates only this fixture process, without close_db.
	assert(db.query("SELECT player_id FROM players WHERE account_name='recovery';") and db.query_result.size()==1)
	var owner:=int(db.query_result[0].player_id)
	assert(MarketStoreSqlite.ensure_schema(db) and MarketSearchSqlite.ensure_schema(db) and ExchangeStoreSqlite.ensure_ledger_schema(db) and ExchangeStoreSqlite.ensure_orders_schema(db))
	var market:=MarketStoreSqlite.new(db);var mine:=market.mine(owner)
	assert(mine.offers.size()==1 and market.receipt(owner,"durable_list").offer_id==mine.offers[0].offer_id)
	assert(mine.name=="Recovered from WAL" and market.receipt(owner,"after_checkpoint").ok,"recovery includes post-backup WAL commit, not just checkpointed DB")
	assert(db.query("SELECT player_id FROM players WHERE account_name='recovery_buyer';") and db.query_result.size()==1)
	assert(mine.claimable_yang=="40" and market.receipt(int(db.query_result[0].player_id),"wal_revenue_buy").ok)
	var old_claim:=market.receipt(owner,"wal_revenue_collect")
	assert(old_claim.ok and old_claim.claimed==50 and market.claim_revenue(owner,"wal_revenue_collect",0)==old_claim,"WAL recovery replays collection without consuming remainder")
	var exchange:=ExchangeStoreSqlite.new(db)
	assert(exchange.ledger(owner).assets[0].reserved==100 and exchange.orders_snapshot(owner).orders[0].remaining==100)
	assert(db.query("PRAGMA integrity_check;") and db.query_result[0].values()[0]=="ok")
	assert(db.query("PRAGMA foreign_key_check;") and db.query_result.is_empty())
	assert(exchange.place_order(owner,{"command_id":"durable_order","have_asset":"upgrade_ore","want_asset":"yang","quantity":100,"price_num":10,"price_den":1},{}).ok)
	var timings: Dictionary={}
	for sync: String in ["NORMAL","FULL"]:
		assert(db.query("PRAGMA wal_checkpoint(TRUNCATE);") and db.query("PRAGMA synchronous="+sync+";"))
		var times: Array[int]=[]
		for index: int in 50:
			var before:=Time.get_ticks_usec()
			assert(market.configure(owner,"benchmark_"+sync+str(index),index+1+(50 if sync=="FULL" else 0),"Recovery","active").ok)
			times.append(Time.get_ticks_usec()-before)
		times.sort();timings[sync]={"p50_ms":times[25]/1000.0,"p95_ms":times[47]/1000.0}
	var reader:=SQLite.new();reader.path=ProjectSettings.globalize_path(db.path);assert(reader.open_db())
	assert(reader.query("BEGIN;") and reader.query("SELECT value FROM meta;"))
	assert(market.configure(owner,"blocked_backup",101,"Recovery","active").ok)
	var persistence:=WorldDatabase.new();add_child(persistence);persistence.db=db;persistence.database_path=db.path
	assert(not persistence.backup_database(),"busy checkpoint must not produce a success/stale backup")
	assert(reader.query("ROLLBACK;") and reader.close_db());assert(persistence.backup_database())
	persistence.store=store;persistence.item_store=ItemStoreSqlite.new(db)
	EconomyFixture.prepare(persistence)
	assert(await persistence.start_auction_queries(),"reader restarts against recovered WAL")
	var recovered: Dictionary={}
	persistence.auction_queries.submit(store.resolve_account_id(owner),"recovered",LOAD_PARAMS,func(r: Dictionary)->void:recovered.merge(r),func()->bool:return true)
	while recovered.is_empty(): await get_tree().process_frame
	assert(recovered.ok and recovered.results.size()==50,"search works after process restart")
	assert(await persistence.auction_queries.pause())
	print("MARKET_DURABILITY_BENCH ",JSON.stringify(timings))
	print("MARKET_RECOVERY_OK crash during async traffic, WAL restore, escrow/reservation/receipt, production backup, restarted reader, integrity and sync benchmark")
	db.close_db();get_tree().quit()

func _process(_delta: float) -> void:
	if load_service==null or Time.get_ticks_msec()<load_next_ms: return
	load_next_ms=Time.get_ticks_msec()+125
	for account: int in range(2000,2016):
		load_sequence+=1
		load_service.submit(account,"crash_load:%d" % load_sequence,LOAD_PARAMS,func(_r: Dictionary)->void:pass,func()->bool:return true)
