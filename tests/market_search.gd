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
	# R2 uncovered contract: one World budget, independent of account/instance facade.
	var persistence:=WorldDatabase.new();add_child(persistence);persistence.db=db;persistence.store=store;persistence.wallet_ready=true
	var other:=EconomyFixture.create_character(store,"other_search",{"name":"OtherSearch","skin":1})
	assert(persistence.market_query(owner,"search",p).ok)
	assert(persistence.market_query(other,"search",p).error=="rate_limited","another authenticated account shares World budget")
	assert(persistence.market_query(other,"catalog",{"query":"sword"}).ok,"cheap catalog does not consume expensive budget")
	assert(persistence.market_query(other,"visit",{"shop_id":1}).ok,"public shop read remains available")
	var after:=Time.get_ticks_msec()+WorldDatabase.MARKET_SEARCH_INTERVAL_MS+20
	while Time.get_ticks_msec()<after: await get_tree().physics_frame
	assert(persistence.market_query(other,"search",p).ok,"budget refills without queued work")
	assert(persistence.market_query(owner,"search",p).error=="rate_limited")
	print("MARKET_SEARCH_OK catalog, AND, inclusive ranges, keyset, limits, projection update, restart, 10k")
	db.close_db();DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path));get_tree().quit()
