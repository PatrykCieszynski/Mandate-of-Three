extends Node
## Query/result parity plus transactional affix projection on real PostgreSQL.
const Schema = preload("res://source/server/world/database/postgres/auction_search_schema_postgres.gd")
const Prior = preload("res://source/server/world/database/postgres/account_claim_schema_postgres.gd")
const Search = preload("res://source/server/world/database/postgres/auction_search_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
var pg: Object
var sqlite: SqliteSoci
var connection: String
var characters: Array[int]=[]
var accounts: Array[int]=[]

func uid(id: int) -> String: return "%032x" % id

func params() -> Dictionary:
	return {"definition_id":"iron_sword","upgrade_min":0,"upgrade_max":9,"price_min":0,"price_max":9000000000000000,"affix_filters":[],"sort":"price_asc","cursor":"","limit":7}

func execute(native: bool, sql: String, bindings: Dictionary = {}) -> void:
	if native:
		var result: Dictionary=pg.execute(sql,bindings)
		assert(result.ok,str(result))
	else: assert(sqlite.query_with_bindings(sql,bindings.values()))

func query(native: bool, sql: String, bindings: Dictionary = {}) -> Array:
	if native:
		var result: Dictionary=pg.query(sql,bindings)
		assert(result.ok and not result.truncated)
		return result.rows
	assert(sqlite.query_with_bindings(sql,bindings.values()))
	return sqlite.query_result.duplicate(true)

func seed_offers(native: bool) -> void:
	var prefix: String="economy." if native else ""
	assert(pg.begin() if native else sqlite.query("BEGIN IMMEDIATE;"))
	for shop: int in 3:
		execute(native,"INSERT INTO "+prefix+"account_shops(shop_id,account_id,display_name,status) VALUES(:shop,:account,:name,:status);",{"shop":100+shop,"account":accounts[shop],"name":"Żelazny O'Brien "+str(shop),"status":"paused" if shop==2 else "active"})
		for slot: int in 20:
			var n: int=shop*20+slot
			var rolls: Array=[{"stat":"monster_damage","value":15 if n%3==0 else 5},{"stat":"critical_chance","value":7 if n%5==0 else 2}]
			if n==0: rolls.append({"stat":"monster_damage","value":16})
			var definition: String="upgrade_ore" if n%7==0 else "iron_sword"
			execute(native,"INSERT INTO "+prefix+"item_instances(uid,owner_character_id,definition_id,amount,upgrade_level,affixes_json,sockets_json,revision) VALUES(:uid,:owner,:definition,1,:upgrade,:affixes,'[]',0);",{"uid":uid(n+1),"owner":characters[shop],"definition":definition,"upgrade":n%10,"affixes":JSON.stringify(rolls)})
			var position: int=slot%5+(slot/5)*10
			if native:
				execute(true,"INSERT INTO economy.item_custody(uid,location,owner_id,position,escrow_account_id,shop_id,offer_id) VALUES(:uid,'shop_escrow',:owner,:position,:account,:shop,:offer);",{"uid":uid(n+1),"owner":characters[shop],"position":position,"account":accounts[shop],"shop":100+shop,"offer":uid(n+20000)})
			else:
				execute(false,"INSERT INTO item_custody(uid,location,owner_id,position,container_id,offer_id) VALUES(:uid,'shop_escrow',:account,:position,:shop,:offer);",{"uid":uid(n+1),"account":accounts[shop],"position":position,"shop":100+shop,"offer":uid(n+20000)})
			var price: int=1 if n%6==0 else (n%4+1)*100
			if n==19: price=9000000000000000
			execute(native,"INSERT INTO "+prefix+"shop_offers(offer_id,shop_id,account_id,item_uid,position,price_yang,offer_only,revision) VALUES(:offer,:shop,:account,:uid,:position,:price,:negotiable,0);",{"offer":uid(n+20000),"shop":100+shop,"account":accounts[shop],"uid":uid(n+1),"position":position,"price":price,"negotiable":1 if n%6==0 else 0})
			for cell: int in [position,position+5] if definition=="iron_sword" else [position]:
				execute(native,"INSERT INTO "+prefix+"shop_cells(shop_id,position,item_uid) VALUES(:shop,:position,:uid);",{"shop":100+shop,"position":cell,"uid":uid(n+1)})
	assert(pg.commit() if native else sqlite.query("COMMIT;"))

func compare_pages(reference: RefCounted, candidate: RefCounted, payload: Dictionary) -> Array:
	var p:=payload.duplicate(true)
	var seen: Array=[]
	for page: int in 100:
		var a: Dictionary=reference.search(p)
		var b: Dictionary=candidate.search(p)
		assert(a==b,"same content/order/metadata/cursor for "+str(p))
		assert(a.ok)
		for result: Dictionary in a.results:
			assert(result.offer_id not in seen)
			seen.append(result.offer_id)
		if a.next_cursor.is_empty(): return seen
		p.cursor=a.next_cursor
	assert(false,"bounded small fixture must finish pagination")
	return []

func parity() -> void:
	var reference:=MarketSearchSqlite.new(sqlite)
	var candidate:=Search.new(pg)
	for definition: String in ["iron_sword","upgrade_ore","forest_resin"]:
		for order: String in ["price_asc","price_desc"]:
			for filters: Array in [[],[{"stat_id":"monster_damage","minimum":15}],[{"stat_id":"monster_damage","minimum":15},{"stat_id":"critical_chance","minimum":7}]]:
				var p:=params()
				p.definition_id=definition
				p.sort=order
				p.affix_filters=filters
				compare_pages(reference,candidate,p)
	for bounds: Array in [[0,0],[100,100],[100,300],[9000000000000000,9000000000000000]]:
		var p:=params()
		p.price_min=bounds[0]
		p.price_max=bounds[1]
		compare_pages(reference,candidate,p)
	for limit: int in [1,50]:
		var p:=params()
		p.limit=limit
		p.upgrade_min=2
		p.upgrade_max=7
		compare_pages(reference,candidate,p)
	# Negotiable entries are last for BOTH price orders and only accepted with
	# completely unbounded price filters; equal-price ties use ascending offer ID.
	for order: String in ["price_asc","price_desc"]:
		var p:=params()
		p.sort=order
		p.limit=50
		var results: Array=candidate.search(p).results
		assert(results.any(func(row: Dictionary) -> bool: return row.price==null))
		var negotiable: bool=false
		for row: Dictionary in results:
			if row.price==null: negotiable=true
			else: assert(not negotiable)
	for cursor: String in ["garbage","-1:"+uid(1),"9000000000000001:"+uid(1),"1:not-an-id","1:"+uid(1)+":extra"]:
		var p:=params()
		p.cursor=cursor
		assert(reference.search(p)==candidate.search(p) and candidate.search(p).error=="cursor")
	for malformed: Dictionary in [{},{"definition_id":"iron_sword' OR 1=1 --"}]:
		assert(reference.search(malformed)==candidate.search(malformed))
	var invalid:=params()
	invalid.affix_filters=[{"stat_id":"monster_damage","minimum":NAN}]
	assert(candidate.search(invalid).error=="request")
	invalid=params()
	invalid.limit=51
	assert(candidate.search(invalid).error=="request")
	invalid=params()
	invalid.definition_id="iron_sword' OR 1=1 --"
	assert(candidate.search(invalid).error=="request")
	invalid=params()
	invalid.affix_filters=[{"stat_id":"monster_damage","minimum":1},{"stat_id":"monster_damage","minimum":2}]
	assert(candidate.search(invalid).error=="request")
	print("POSTGRES_AUCTION_PARITY_OK filters, inclusive bounds, AND/duplicate rolls, ties, negotiable continuation, limits and exact row/cursor parity")

func mutations() -> void:
	var candidate:=Search.new(pg)
	for native: bool in [false,true]:
		var prefix: String="economy." if native else ""
		assert(query(native,"SELECT * FROM "+prefix+"item_affix_index WHERE uid=:uid;",{"uid":uid(1)}).size()==3)
		assert(pg.begin() if native else sqlite.query("BEGIN IMMEDIATE;"))
		execute(native,"UPDATE "+prefix+"item_instances SET affixes_json='[]' WHERE uid=:uid;",{"uid":uid(1)})
		assert(query(native,"SELECT * FROM "+prefix+"item_affix_index WHERE uid=:uid;",{"uid":uid(1)}).is_empty())
		assert(pg.rollback() if native else sqlite.query("ROLLBACK;"))
		assert(query(native,"SELECT * FROM "+prefix+"item_affix_index WHERE uid=:uid;",{"uid":uid(1)}).size()==3)
		execute(native,"UPDATE "+prefix+"item_instances SET affixes_json=:affixes WHERE uid=:uid;",{"affixes":'[{"stat":"monster_damage","value":99}]',"uid":uid(1)})
		var projected:=query(native,"SELECT stat_id,value FROM "+prefix+"item_affix_index WHERE uid=:uid;",{"uid":uid(1)})
		assert(projected.size()==1 and projected[0].value==99)
		assert(pg.begin() if native else sqlite.query("BEGIN IMMEDIATE;"))
		execute(native,"DELETE FROM "+prefix+"shop_cells WHERE item_uid=:uid;",{"uid":uid(2)})
		execute(native,"DELETE FROM "+prefix+"shop_offers WHERE item_uid=:uid;",{"uid":uid(2)})
		execute(native,"DELETE FROM "+prefix+"item_custody WHERE uid=:uid;",{"uid":uid(2)})
		execute(native,"DELETE FROM "+prefix+"item_instances WHERE uid=:uid;",{"uid":uid(2)})
		assert(pg.commit() if native else sqlite.query("COMMIT;"))
		assert(query(native,"SELECT * FROM "+prefix+"item_affix_index WHERE uid=:uid;",{"uid":uid(2)}).is_empty())
	compare_pages(MarketSearchSqlite.new(sqlite),candidate,params())
	# Projection failures must abort the item mutation, not leave stale rolled data.
	execute(true,"CREATE FUNCTION economy.fixture_affix_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'affix fixture fault'; END; $$;")
	execute(true,"CREATE TRIGGER fixture_affix_fault BEFORE INSERT ON economy.item_affix_index FOR EACH ROW EXECUTE FUNCTION economy.fixture_affix_fault();")
	var before:=query(true,"SELECT affixes_json FROM economy.item_instances WHERE uid=:uid;",{"uid":uid(1)})
	assert(not pg.execute("UPDATE economy.item_instances SET affixes_json=:affixes WHERE uid=:uid;",{"affixes":'[{"stat":"monster_damage","value":1}]',"uid":uid(1)}).ok)
	assert(query(true,"SELECT affixes_json FROM economy.item_instances WHERE uid=:uid;",{"uid":uid(1)})==before)
	assert(query(true,"SELECT value FROM economy.item_affix_index WHERE uid=:uid;",{"uid":uid(1)})[0].value==99)
	execute(true,"DROP TRIGGER fixture_affix_fault ON economy.item_affix_index;")
	assert(not pg.execute("UPDATE economy.item_instances SET affixes_json=:affixes WHERE uid=:uid;",{"affixes":'[{"stat":"monster_damage","value":"99"}]',"uid":uid(1)}).ok,"numeric strings must not become a valid rolled-affix projection")
	assert(query(true,"SELECT affixes_json FROM economy.item_instances WHERE uid=:uid;",{"uid":uid(1)})==before)
	assert(pg.begin())
	assert(candidate.search(params()).error=="storage" and pg.in_transaction() and pg.rollback())
	pg.close()
	assert(candidate.search(params()).error=="storage")
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	compare_pages(MarketSearchSqlite.new(sqlite),candidate,params())
	# A separately owned read-only session can search and recovers after denied
	# mutation. Runtime pool/role configuration remains a later execution milestone.
	var reader: Object=ClassDB.instantiate("GodotSociDatabase")
	assert(reader.open("postgresql",connection) and reader.execute("SET default_transaction_read_only=on;").ok)
	var readonly_search:=Search.new(reader)
	assert(readonly_search.search(params())==candidate.search(params()))
	assert(not reader.execute("DELETE FROM economy.shop_offers;").ok)
	assert(readonly_search.search(params())==candidate.search(params()) and not reader.in_transaction())
	reader.close()

func benchmark() -> void:
	# Legal 500 Shops x 20 two-cell items; distinct account/character provenance.
	# Prepared fixture SQL only, no runtime command/receipt bypass in production.
	execute(true,"UPDATE economy.account_shops SET status='paused' WHERE shop_id<10000;")
	execute(true,"INSERT INTO economy.accounts SELECT 10000+n FROM generate_series(0,499) n;")
	execute(true,"INSERT INTO economy.characters SELECT 20000+n,10000+n FROM generate_series(0,499) n;")
	execute(true,"INSERT INTO economy.account_shops(shop_id,account_id) SELECT 10000+n,10000+n FROM generate_series(0,499) n;")
	# Keep the runner's 1-second statement bound; seed in bounded transactions.
	for index: int in 20:
		var batch: Dictionary={"first":index*500,"last":index*500+499}
		assert(pg.begin())
		execute(true,"INSERT INTO economy.item_instances(uid,owner_character_id,definition_id,amount,upgrade_level,affixes_json,sockets_json,revision) SELECT lpad(to_hex(100000+n),32,'0'),20000+n/20,'iron_sword',1,n%10,jsonb_build_array(jsonb_build_object('stat','monster_damage','value',CASE WHEN n%3=0 THEN 15 ELSE 5 END),jsonb_build_object('stat','critical_chance','value',CASE WHEN n%5=0 THEN 7 ELSE 2 END))::text,'[]',0 FROM generate_series(CAST(:first AS INTEGER),CAST(:last AS INTEGER)) n;",batch)
		execute(true,"INSERT INTO economy.item_custody(uid,location,owner_id,position,escrow_account_id,shop_id,offer_id) SELECT lpad(to_hex(100000+n),32,'0'),'shop_escrow',20000+n/20,n%5+(n%20/5)*10,10000+n/20,10000+n/20,lpad(to_hex(200000+n),32,'0') FROM generate_series(CAST(:first AS INTEGER),CAST(:last AS INTEGER)) n;",batch)
		execute(true,"INSERT INTO economy.shop_offers(offer_id,shop_id,account_id,item_uid,position,price_yang) SELECT lpad(to_hex(200000+n),32,'0'),10000+n/20,10000+n/20,lpad(to_hex(100000+n),32,'0'),n%5+(n%20/5)*10,n+1 FROM generate_series(CAST(:first AS INTEGER),CAST(:last AS INTEGER)) n;",batch)
		execute(true,"INSERT INTO economy.shop_cells SELECT c.shop_id,c.position+5*v,c.uid FROM economy.item_custody c CROSS JOIN generate_series(0,1) v WHERE c.shop_id>=10000 AND c.offer_id BETWEEN :first AND :last;",{"first":uid(200000+int(batch.first)),"last":uid(200000+int(batch.last))})
		assert(pg.commit())
	assert(int(query(true,"SELECT COUNT(*) AS n FROM economy.shop_offers WHERE shop_id>=10000;")[0].n)==10000)
	execute(true,"ANALYZE economy.item_instances;")
	execute(true,"ANALYZE economy.shop_offers;")
	execute(true,"ANALYZE economy.item_affix_index;")
	var candidate:=Search.new(pg)
	for filters: Array in [[],[{"stat_id":"monster_damage","minimum":15}],[{"stat_id":"monster_damage","minimum":15},{"stat_id":"critical_chance","minimum":7}]]:
		var p:=params()
		p.limit=50
		p.affix_filters=filters
		var times: Array[int]=[]
		var db_times: Array[int]=[]
		for sample: int in 30:
			var started:=Time.get_ticks_usec()
			assert(candidate.search(p).ok)
			times.append(Time.get_ticks_usec()-started)
			db_times.append(candidate.last_db_usec)
		times.sort()
		db_times.sort()
		var built:=Search.build_query(p)
		var plan:=query(true,"EXPLAIN (FORMAT TEXT) "+str(built.sql),built.params)
		print("POSTGRES_AUCTION_BENCH ",JSON.stringify({"offers":10000,"filters":filters.size(),"samples":30,"p50_ms":times[15]/1000.0,"p95_ms":times[28]/1000.0,"native_p50_ms":db_times[15]/1000.0,"native_p95_ms":db_times[28]/1000.0,"includes_projection":true}))
		print("POSTGRES_AUCTION_PLAN ",JSON.stringify({"filters":filters.size(),"plan":plan}))

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var directory:=OS.get_environment("MANDATE_PG_FIXTURE_DIR")
	assert(directory.begins_with("res://.godot/verification/postgres-readiness/run-") and not ".." in directory)
	sqlite=SqliteSoci.new()
	sqlite.path=directory+"/auction-search.db"
	assert(not FileAccess.file_exists(sqlite.path) and sqlite.open_db())
	WorldSchema.ensure_schema(sqlite)
	var identities:=WorldStoreSqlite.new(sqlite)
	for index: int in 3:
		var character:=EconomyFixture.create_character(identities,"search-"+str(index),{"name":"Search"+str(index),"skin":1})
		characters.append(character)
		accounts.append(identities.resolve_account_id(character))
	var runtime:=WorldDatabase.new()
	runtime.db=sqlite
	runtime.store=identities
	EconomyFixture.prepare(runtime)
	connection=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Prior.ensure_schema(pg))
	for index: int in 3:
		assert(Wallet.new(pg).initialize_account(accounts[index]).ok and Items.new(pg).bind_character(characters[index],accounts[index]))
	seed_offers(false)
	seed_offers(true)
	# Fault after DDL/backfill must leave the populated pre-search schema intact.
	execute(true,"CREATE FUNCTION economy.fixture_search_schema_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.feature='auction_search' THEN RAISE EXCEPTION 'search schema fault'; END IF; RETURN NEW; END; $$;")
	execute(true,"CREATE TRIGGER fixture_search_schema_fault BEFORE INSERT ON economy.schema_versions FOR EACH ROW EXECUTE FUNCTION economy.fixture_search_schema_fault();")
	assert(not Schema.ensure_schema(pg) and not pg.in_transaction())
	assert(pg.query("SELECT to_regclass('economy.item_affix_index')::text AS name;").rows[0].name==null)
	assert(int(query(true,"SELECT COUNT(*) AS n FROM economy.item_instances;")[0].n)==60)
	execute(true,"DROP TRIGGER fixture_search_schema_fault ON economy.schema_versions;")
	assert(Schema.ensure_schema(pg) and Schema.ensure_schema(pg))
	parity()
	mutations()
	execute(true,"UPDATE economy.schema_versions SET version=999 WHERE feature='auction_search';")
	assert(not Schema.ensure_schema(pg) and not pg.in_transaction())
	execute(true,"UPDATE economy.schema_versions SET version=1 WHERE feature='auction_search';")
	assert(Schema.ensure_schema(pg))
	benchmark()
	pg.close()
	runtime.db=null
	runtime.free()
	sqlite.close_db()
	print("POSTGRES_AUCTION_SEARCH_OK SQLite row/cursor parity, transactional rolled-affix index, schema recovery and 10k native observations")
	get_tree().quit()
