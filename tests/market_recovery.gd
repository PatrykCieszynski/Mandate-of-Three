extends Node
var db:=SQLite.new()
func _ready() -> void:
	var phase: String=CmdlineUtils.get_parsed_args().get("recovery-phase","read")
	db.path="res://.godot/verification/market-recovery.db" if phase=="write" else "res://.godot/verification/market-restored.db"
	assert(db.open_db());assert(db.query("PRAGMA journal_mode=WAL;") and db.query("PRAGMA synchronous=FULL;"));WorldSchema.ensure_schema(db)
	var store:=WorldStoreSqlite.new(db)
	if phase=="write":
		var owner:=EconomyFixture.create_character(store,"recovery",{"name":"Recovery","skin":1})
		assert(MarketSearchSqlite.ensure_schema(db) and ExchangeStoreSqlite.ensure_ledger_schema(db) and ExchangeStoreSqlite.ensure_orders_schema(db))
		var items:=ItemStoreSqlite.new(db);assert(items.initialize_character(owner).ok)
		var market:=MarketStoreSqlite.new(db);var sword: Dictionary=items.inventory(owner).items[0]
		assert(market.list_item(owner,"durable_list",sword.uid,sword.revision,0,100).ok)
		var ore:=ItemInstance.create(ItemDefinitions.UPGRADE_ORE,owner,[]);ore.amount=100
		assert(EconomyFixture.insert_item(items,ore,2))
		var exchange:=ExchangeStoreSqlite.new(db);assert(exchange.deposit(owner,"durable_deposit",ore.uid,0,100,"bag").ok)
		assert(exchange.place_order(owner,{"command_id":"durable_order","have_asset":"upgrade_ore","want_asset":"yang","quantity":100,"price_num":10,"price_den":1},{}).ok)
		var persistence:=WorldDatabase.new();add_child(persistence);persistence.db=db;persistence.database_path=db.path;persistence.store=store
		assert(persistence.backup_database(),"production checkpoint backup with escrow and order")
		print("MARKET_RECOVERY_READY")
		return # Runner terminates only this fixture process, without close_db.
	assert(db.query("SELECT player_id FROM players WHERE account_name='recovery';") and db.query_result.size()==1)
	var owner:=int(db.query_result[0].player_id)
	assert(MarketStoreSqlite.ensure_schema(db) and MarketSearchSqlite.ensure_schema(db) and ExchangeStoreSqlite.ensure_ledger_schema(db) and ExchangeStoreSqlite.ensure_orders_schema(db))
	var market:=MarketStoreSqlite.new(db);var mine:=market.mine(owner)
	assert(mine.offers.size()==1 and market.receipt(owner,"durable_list").offer_id==mine.offers[0].offer_id)
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
			assert(market.configure(owner,"benchmark_"+sync+str(index),index+(50 if sync=="FULL" else 0),"Recovery","active").ok)
			times.append(Time.get_ticks_usec()-before)
		times.sort();timings[sync]={"p50_ms":times[25]/1000.0,"p95_ms":times[47]/1000.0}
	var reader:=SQLite.new();reader.path=ProjectSettings.globalize_path(db.path);assert(reader.open_db())
	assert(reader.query("BEGIN;") and reader.query("SELECT value FROM meta;"))
	assert(market.configure(owner,"blocked_backup",100,"Recovery","active").ok)
	var persistence:=WorldDatabase.new();add_child(persistence);persistence.db=db;persistence.database_path=db.path
	assert(not persistence.backup_database(),"busy checkpoint must not produce a success/stale backup")
	assert(reader.query("ROLLBACK;") and reader.close_db());assert(persistence.backup_database())
	print("MARKET_DURABILITY_BENCH ",JSON.stringify(timings))
	print("MARKET_RECOVERY_OK crash WAL restore, escrow/reservation/receipt, production backup, integrity and sync benchmark")
	db.close_db();get_tree().quit()
