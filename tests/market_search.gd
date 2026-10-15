extends Node
## Uncovered search contract: base catalog, rolled AND predicates and bounded 10k reads.
var db:=SQLite.new()
func _ready() -> void:
	db.path="res://.godot/verification/market-search.db"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path));assert(db.open_db());WorldSchema.ensure_schema(db)
	var store:=WorldStoreSqlite.new(db)
	var owner:=EconomyFixture.create_character(store,"search",{"name":"Search","skin":1})
	assert(db.query("CREATE TEMP TRIGGER fail_search BEFORE INSERT ON meta WHEN NEW.value='20' BEGIN SELECT RAISE(ABORT,'search migration fault'); END;"))
	assert(not MarketSearchSqlite.ensure_schema(db))
	assert(db.query("SELECT name FROM sqlite_master WHERE name='item_affix_index';") and db.query_result.is_empty(),"failed migration removes partial projection")
	assert(db.query("DROP TRIGGER fail_search;"))
	assert(MarketSearchSqlite.ensure_schema(db))
	var catalog:=MarketSearchSqlite.catalog("miecz")
	assert(catalog.items.size()==1 and catalog.items[0].definition_id=="iron_sword")
	assert(MarketSearchSqlite.normalize("ŻELAZNY MIECZ")=="zelazny miecz")
	var search:=MarketSearchSqlite.new(db)
	var p: Dictionary={"definition_id":"iron_sword","upgrade_min":7,"upgrade_max":9,"price_min":0,"price_max":9000000000000000,"affix_filters":[{"stat_id":"monster_damage","minimum":10},{"stat_id":"critical_chance","minimum":5}],"sort":"price_asc","cursor":"","limit":50}
	preload("res://tests/fixtures/market_search_fixture.gd").seed(db,owner)
	verify_lookup_migration(search,owner)
	p.definition_id="iron_sword"
	var result:=search.search(p);assert(result.ok and result.results.size()==50 and not result.next_cursor.is_empty())
	for row: Dictionary in result.results:
		assert(row.item.upgrade_level>=7 and row.item.upgrade_level<=9)
		assert(row.item.affixes[0].value>=10 and row.item.affixes[1].value>=5,"AND uses rolled values, not effective combat stats")
	var ids: Array=result.results.map(func(r: Dictionary)->String:return r.offer_id)
	p.cursor=result.next_cursor;result=search.search(p)
	assert(result.ok and result.results.all(func(r: Dictionary)->bool:return r.offer_id not in ids),"keyset continuation no duplicates")
	p.cursor="";p.upgrade_min=9;p.upgrade_max=9
	assert(search.search(p).results.all(func(r: Dictionary)->bool:return r.item.upgrade_level==9))
	p.upgrade_min=9;p.upgrade_max=7;assert(not search.search(p).ok)
	p.upgrade_min=0;p.upgrade_max=9;p.affix_filters=[]
	p.limit=1000;assert(not search.search(p).ok);p.limit=50
	p.definition_id="upgrade_ore' OR 1=1 --";assert(not search.search(p).ok);p.definition_id="iron_sword"
	var times: Array[int]=[]
	var db_times: Array[int]=[]
	for sample: int in 100:
		var started:=Time.get_ticks_usec();assert(search.search(p).ok);times.append(Time.get_ticks_usec()-started);db_times.append(search.last_db_usec)
	times.sort();db_times.sort()
	print("MARKET_SEARCH_BENCH offers=10000 queries_per_search=1 samples=100 p50_ms=",times[50]/1000.0," p95_ms=",times[95]/1000.0," db_p50_ms=",db_times[50]/1000.0," db_p95_ms=",db_times[95]/1000.0," includes_snapshot_build=true")
	assert(db.query_with_bindings("UPDATE item_instances SET affixes_json=? WHERE uid=?;",['[{"stat":"monster_damage","value":99}]',"%032x" % 1]))
	assert(db.query_with_bindings("SELECT value FROM item_affix_index WHERE uid=? AND stat_id='monster_damage';",["%032x" % 1]) and db.query_result[0].value==99,"mutation refreshes index")
	assert(db.query("PRAGMA foreign_key_check;") and db.query_result.is_empty())
	assert(db.close_db() and db.open_db() and MarketSearchSqlite.ensure_schema(db))
	assert(search.search(p).ok)
	# Search must never fall back to synchronous SQL through the marketplace facade.
	var persistence:=WorldDatabase.new();add_child(persistence);persistence.db=db;persistence.store=store;persistence.wallet_ready=true
	var other:=EconomyFixture.create_character(store,"other_search",{"name":"OtherSearch","skin":1})
	assert(persistence.market_query(owner,"search",p).error=="request")
	assert(persistence.market_query(other,"search",p).error=="request")
	assert(persistence.market_query(other,"catalog",{"query":"sword"}).ok,"cheap catalog does not consume expensive budget")
	assert(persistence.market_query(other,"visit",{"shop_id":1}).ok,"public shop read remains available")
	print("MARKET_SEARCH_OK catalog, AND, inclusive ranges, keyset, limits, projection update, restart, 10k")
	db.close_db();DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path));get_tree().quit()

func verify_lookup_migration(search: MarketSearchSqlite, owner: int) -> void:
	# Existing v20 rollback/search coverage does not protect v22->23 atomic DDL,
	# startup refusal, exact before/after cursors or the new index's write cost.
	assert(ExchangeStoreSqlite.ensure_ledger_schema(db) and ExchangeStoreSqlite.ensure_orders_schema(db))
	var controls: Array[Dictionary]=[]
	for sort: String in ["price_asc","price_desc"]:
		for filters: Array in [[],[{"stat_id":"monster_damage","minimum":0}],[{"stat_id":"monster_damage","minimum":15},{"stat_id":"critical_chance","minimum":7}]]:
			var params: Dictionary={"definition_id":"iron_sword","upgrade_min":0,"upgrade_max":9,"price_min":0,"price_max":WalletStoreSqlite.MAX_YANG,"affix_filters":filters,"sort":sort,"cursor":"","limit":50}
			for page: int in 2:
				var response:=search.search(params);assert(response.ok)
				controls.append({"params":params.duplicate(true),"response":response})
				params.cursor=response.next_cursor
	var before:=mutation_cost(owner)
	assert(db.query("CREATE TEMP TRIGGER fail_lookup BEFORE INSERT ON meta WHEN NEW.value='23' BEGIN SELECT RAISE(ABORT,'lookup migration fault'); END;"))
	var persistence:=WorldDatabase.new();add_child(persistence);persistence.db=db;persistence.store=WorldStoreSqlite.new(db)
	assert(db.query("SELECT account_name,master_account_id FROM accounts;"))
	var manifest: Dictionary={}
	for row: Dictionary in db.query_result: manifest[row.account_name]=row.master_account_id
	var failed:=persistence.prepare_account_wallets(manifest)
	assert(not failed.ok and failed.error=="market_lookup_migration" and not persistence.wallet_ready,"failed index migration prevents admissions readiness")
	assert(db.query("SELECT value FROM meta WHERE key='schema_version';") and db.query_result[0].value=="22")
	assert(db.query("SELECT name FROM sqlite_master WHERE name='affix_item_lookup';") and db.query_result.is_empty(),"failed version write rolls back CREATE INDEX")
	assert(db.query("SELECT COUNT(*) AS n FROM item_instances;") and db.query_result[0].n==10000,"rollback retains all items")
	assert(db.query("DROP TRIGGER fail_lookup;") and persistence.prepare_account_wallets(manifest).ok and persistence.wallet_ready)
	assert(db.query("SELECT value FROM meta WHERE key='schema_version';") and int(db.query_result[0].value)==24)
	assert(MarketSearchSqlite.ensure_lookup_schema(db),"idempotent repeat")
	assert(db.query("PRAGMA index_info(affix_item_lookup);") and db.query_result.map(func(row: Dictionary)->String:return row.name)==["uid","stat_id","value"])
	for control: Dictionary in controls: assert(search.search(control.params)==control.response,"exact content/order/cursor parity across migration")
	var after:=mutation_cost(owner)
	print("MARKET_LOOKUP_MUTATIONS ",JSON.stringify({"samples":30,"before":before,"after":after,"includes_atomic_commit":true}))
	assert(db.query("PRAGMA foreign_key_check;") and db.query_result.is_empty())
	assert(db.query("PRAGMA integrity_check;") and db.query_result[0].values()[0]=="ok")
	assert(db.close_db() and db.open_db() and MarketSearchSqlite.ensure_lookup_schema(db),"restart preserves v24 and the lookup index")
	persistence.queue_free()

func mutation_cost(owner: int) -> Dictionary:
	var updates: Array[int]=[];var creates: Array[int]=[];var deletes: Array[int]=[]
	var uid:="%032x" % 1
	assert(db.query_with_bindings("SELECT affixes_json FROM item_instances WHERE uid=?;",[uid]))
	var original: String=db.query_result[0].affixes_json
	for iteration: int in 30:
		var started:=Time.get_ticks_usec()
		assert(db.query("BEGIN IMMEDIATE;") and db.query_with_bindings("UPDATE item_instances SET affixes_json=? WHERE uid=?;",['[{"stat":"monster_damage","value":99}]',uid]) and db.query("COMMIT;"))
		updates.append(Time.get_ticks_usec()-started)
		assert(db.query_with_bindings("SELECT stat_id,value FROM item_affix_index WHERE uid=?;",[uid]) and db.query_result.size()==1 and db.query_result[0].value==99)
		assert(db.query_with_bindings("UPDATE item_instances SET affixes_json=? WHERE uid=?;",[original,uid]))
		var item:=ItemInstance.create(ItemDefinitions.IRON_SWORD,owner,[{"stat":"monster_damage","value":7}])
		started=Time.get_ticks_usec();assert(EconomyFixture.insert_item(ItemStoreSqlite.new(db),item,0));creates.append(Time.get_ticks_usec()-started)
		assert(db.query_with_bindings("SELECT value FROM item_affix_index WHERE uid=?;",[item.uid]) and db.query_result[0].value==7)
		started=Time.get_ticks_usec();assert(EconomyFixture.destroy_item(db,item.uid));deletes.append(Time.get_ticks_usec()-started)
		assert(db.query_with_bindings("SELECT uid FROM item_affix_index WHERE uid=?;",[item.uid]) and db.query_result.is_empty(),"item deletion cascades index rows")
	return {"update":distribution(updates),"create":distribution(creates),"delete":distribution(deletes)}

func distribution(values: Array[int]) -> Dictionary:
	values.sort()
	return {"p50_ms":values[values.size()/2]/1000.0,"p95_ms":values[int(ceil(values.size()*0.95))-1]/1000.0,"max_ms":values.back()/1000.0}
