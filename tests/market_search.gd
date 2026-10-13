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
	# 500 account shops x 20 two-cell swords, inserted atomically in fixture batches.
	assert(db.query("BEGIN IMMEDIATE;"))
	for shop: int in 500:
		var account:=2000+shop
		assert(db.query_with_bindings("INSERT INTO accounts(account_name,master_account_id) VALUES(?,?);",["catalog%d" % shop,account]))
		assert(db.query_with_bindings("INSERT INTO account_shops(shop_id,account_id) VALUES(?,?);",[shop+1,account]))
		var instances: Array[String]=[];var custody: Array[String]=[];var offers: Array[String]=[];var cells: Array[String]=[]
		for slot: int in 20:
			var n:=shop*20+slot
			var uid:="%032x" % (n+1);var offer:="%032x" % (n+20000)
			var level:=int(n/10)%10
			var rolls:=JSON.stringify([{"stat":"monster_damage","value":15 if n%3==0 else 5},{"stat":"critical_chance","value":7 if n%5==0 else 2}])
			var definition:="iron_sword"
			var position:=slot
			instances.append("('%s',%d,'%s',1,%d,'%s','[]',0)" % [uid,owner,definition,level,rolls])
			custody.append("('%s','shop_escrow',%d,%d,'',%d,'%s')" % [uid,account,position,shop+1,offer])
			offers.append("('%s',%d,%d,'%s',%d,%d,0)" % [offer,shop+1,account,uid,position,n+1])
			cells.append("(%d,%d,'%s'),(%d,%d,'%s')" % [shop+1,position,uid,shop+1,position+20,uid])
		assert(db.query("INSERT INTO item_instances VALUES "+",".join(instances)+";"))
		assert(db.query("INSERT INTO item_custody VALUES "+",".join(custody)+";"))
		assert(db.query("INSERT INTO shop_offers VALUES "+",".join(offers)+";"))
		assert(db.query("INSERT INTO shop_cells VALUES "+",".join(cells)+";"))
	assert(db.query("COMMIT;"))
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
	print("MARKET_SEARCH_OK catalog, AND, inclusive ranges, keyset, limits, projection update, restart, 10k")
	db.close_db();DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path));get_tree().quit()
