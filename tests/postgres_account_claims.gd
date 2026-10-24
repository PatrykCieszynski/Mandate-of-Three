extends Node
## Real claim custody/recovery parity, not UI geometry or implementation shape.
const Schema = preload("res://source/server/world/database/postgres/account_claim_schema_postgres.gd")
const PriorSchema = preload("res://source/server/world/database/postgres/shop_settlement_schema_postgres.gd")
const Claims = preload("res://source/server/world/database/postgres/account_claim_postgres.gd")
const Queries = preload("res://source/server/world/database/postgres/shop_queries_postgres.gd")
const Seller = preload("res://source/server/world/database/postgres/shop_seller_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const Storage = preload("res://source/server/world/database/postgres/account_storage_postgres.gd")
var pg: Object
var sqlite: SqliteSoci
var connection: String
var primary: int
var alt: int
var foreign: int
var account: int

## A narrow fixture probe delegates every statement to the real native session.
## Commit a writer after the first read establishes the visitor's snapshot.
class VisitBarrier extends RefCounted:
	var db: Object
	var after_read: Callable
	var fired:=false
	func _init(database: Object, callback: Callable) -> void:
		db=database
		after_read=callback
	func begin() -> bool: return db.begin()
	func in_transaction() -> bool: return db.in_transaction()
	func commit() -> bool: return db.commit()
	func rollback() -> bool: return db.rollback()
	func close() -> void: db.close()
	func execute(sql: String, bindings: Dictionary = {}) -> Dictionary: return db.execute(sql,bindings)
	func query(sql: String, bindings: Dictionary = {}) -> Dictionary:
		var result: Dictionary=db.query(sql,bindings)
		if not fired:
			fired=true
			after_read.call()
		return result

func uid(id: int) -> String: return str(id).pad_zeros(32)

func rows(native: bool, sql: String) -> Array:
	if native:
		var result: Dictionary=pg.query(sql)
		assert(result.ok and not result.truncated)
		return result.rows
	assert(sqlite.query(sql))
	return sqlite.query_result.duplicate(true)

func execute(native: bool, sql: String) -> void:
	assert(pg.execute(sql).ok if native else sqlite.query(sql))

func seed_item(items: RefCounted, native: bool, character: int, id: int, position: int, definition: ItemDefinition = ItemDefinitions.IRON_SWORD) -> void:
	var item:=ItemInstance.create(definition,character,[{"stat":"attack","value":3}])
	item.uid=uid(id)
	item.sockets=["fixture"]
	assert(pg.begin() if native else sqlite.query("BEGIN IMMEDIATE;"))
	assert(items.receive_item_in_transaction(item,position).ok)
	assert(pg.commit() if native else sqlite.query("COMMIT;"))

func seed_claim(items: RefCounted, native: bool, character: int, id: int, claim_account: int, definition: ItemDefinition = ItemDefinitions.IRON_SWORD) -> void:
	seed_item(items,native,character,id,160,definition)
	# Fixture-owned producer only: Exchange creation is a separate port. Native
	# custody retains character provenance; SQLite stores account ownership here.
	if native:
		execute(true,"UPDATE economy.item_custody SET location='account_claim',position=-1,claim_account_id="+str(claim_account)+" WHERE uid='"+uid(id)+"';")
	else:
		execute(false,"UPDATE item_custody SET location='account_claim',position=-1,owner_id="+str(claim_account)+" WHERE uid='"+uid(id)+"';")

func canonical(view: Dictionary) -> Dictionary:
	var result:=view.duplicate(true)
	result.erase("shop_id")
	for offer: Dictionary in result.get("offers",[]): offer.offer_id=offer.item.uid
	return result

func claim_receipt(claims: RefCounted, character: int, command: String) -> Dictionary:
	var result: Dictionary=claims.receipt(character,command)
	# Legacy SQLite read-only receipt JSON exposes top-level scalars as floats.
	if result.has("position"): result.position=int(result.position)
	return result

func snapshot(queries: RefCounted, items: RefCounted, storage: RefCounted, native: bool) -> Dictionary:
	var inventories: Array=[]
	for character: int in [primary,alt,foreign]:
		var inventory: Dictionary=items.inventory(character)
		inventory.item_state.erase("authority_id")
		inventories.append(inventory)
	var prefix: String="economy." if native else ""
	var private_view: Dictionary=queries.mine(primary)
	return {"mine":canonical(private_view),"public":canonical(queries.visit(private_view.shop_id)),"alt":canonical(queries.mine(alt)),"foreign":canonical(queries.mine(foreign)),"inventory":inventories,"storage":storage.snapshot(primary),"receipts":int(rows(native,"SELECT COUNT(*) AS n FROM "+prefix+"market_commands;")[0].n)}

func fault(native: bool, table: String) -> void:
	if native:
		execute(true,"CREATE OR REPLACE FUNCTION economy.fixture_claim_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'claim fixture fault'; END; $$;")
		execute(true,"CREATE TRIGGER fixture_claim_fault BEFORE %s ON economy.%s FOR EACH ROW EXECUTE FUNCTION economy.fixture_claim_fault();" % ["INSERT" if table=="market_commands" else "UPDATE",table])
	else: execute(false,"CREATE TEMP TRIGGER fixture_claim_fault BEFORE %s ON %s BEGIN SELECT RAISE(ABORT,'claim fixture fault'); END;" % ["INSERT" if table=="market_commands" else "UPDATE",table])

func exercise(claims: RefCounted, queries: RefCounted, selling: RefCounted, items: RefCounted, storage: RefCounted, native: bool) -> Array:
	var checkpoints: Array=[]
	seed_claim(items,native,primary,1,account)
	seed_claim(items,native,primary,2,account,ItemDefinitions.UPGRADE_ORE)
	var first: Dictionary=queries.mine(primary)
	assert(first.ok and first.claims.size()==2 and first.claimable_yang=="0")
	assert(canonical(first)==canonical(queries.mine(alt)))
	assert(queries.mine(foreign).claims.is_empty() and queries.mine(999999).error=="owner")
	var public_view: Dictionary=queries.visit(first.shop_id)
	assert(public_view.ok and public_view.claims.is_empty() and not public_view.has("claimable_yang") and not public_view.has("account_id"))
	assert(public_view.offers.size()==1 and queries.visit(999999).error=="unavailable")
	assert(claims.claim_item(foreign,"foreign",uid(1),0).error=="owner")
	assert(claims.claim_item(primary,"stale",uid(1),1).error=="stale")
	assert(claims.claim_item(primary,"bag-source",uid(91),1).error=="owner")
	assert(claims.claim_item(primary,"escrow-source",uid(90),1).error=="owner")
	assert(claims.claim_item(primary,"bad-position",uid(1),0,175).error=="request")
	seed_item(items,native,alt,3,0)
	assert(claims.claim_item(alt,"overlap",uid(1),0,5).error=="occupied","different starts still overlap the whole two-cell footprint")
	var before:=snapshot(queries,items,storage,native)
	for table: String in ["item_instances","item_custody","market_commands"]:
		fault(native,table)
		assert(claims.claim_item(alt,"receive",uid(1),0,2).error=="storage")
		assert(snapshot(queries,items,storage,native)==before,"claim fault restores provenance, UID, revisions, capacity and receipt")
		execute(native,"DROP TRIGGER fixture_claim_fault ON economy."+table+";" if native else "DROP TRIGGER fixture_claim_fault;")
	var received: Dictionary=claims.claim_item(alt,"receive",uid(1),0,2)
	assert(received.ok and claims.committed and received.position==2)
	assert(items.inventory(alt).items.any(func(i: Dictionary) -> bool: return i.uid==uid(1) and i.owner_character_id==alt and i.revision==1 and i.sockets==["fixture"]))
	before=snapshot(queries,items,storage,native)
	assert(claims.claim_item(alt,"receive",uid(1),0,2)==received and not claims.committed)
	assert(claims.claim_item(primary,"receive",uid(1),0,2).error=="command_conflict")
	assert(claims.claim_item(alt,"receive",uid(1),0,3).error=="command_conflict")
	assert(claims.claim_item(primary,"second-claim",uid(1),0).error=="owner")
	assert(claim_receipt(claims,primary,"receive")==received and claim_receipt(claims,foreign,"receive").error=="unknown_command")
	assert(snapshot(queries,items,storage,native)==before)
	checkpoints.append(before)
	if native:
		pg.close()
		assert(pg.open("postgresql",connection))
	else:
		sqlite.close_db()
		assert(sqlite.open_db())
	assert(claims.claim_item(alt,"receive",uid(1),0,2)==received and claim_receipt(claims,alt,"receive")==received)
	# One- and three-cell receiving use the same authoritative footprint path.
	assert(claims.claim_item(primary,"single",uid(2),0,0).ok)
	var ore: ItemDefinition=ItemDefinitions.UPGRADE_ORE
	var original_height: int=ore.inventory_height
	ore.inventory_height=3
	seed_claim(items,native,alt,4,account,ore)
	assert(claims.claim_item(alt,"tall-bounds",uid(4),0,170).error=="request")
	assert(claims.claim_item(alt,"tall",uid(4),0,20).ok)
	ore.inventory_height=original_height
	# Neither opening a private Shop nor claiming a nonempty bag can consume an
	# account claim implicitly. Full inventory never falls back to Storage.
	seed_claim(items,native,primary,5,account)
	for position: int in 180:
		if position in [0,5,2,7,20,25,30]: continue
		seed_item(items,native,alt,1000+position,position,ore)
	# The temporary three-cell ore returns to its real one-cell footprint.
	for position: int in [25,30]: seed_item(items,native,alt,1000+position,position,ore)
	before=snapshot(queries,items,storage,native)
	assert(claims.claim_item(alt,"full",uid(5),0).error=="inventory_full")
	assert(snapshot(queries,items,storage,native)==before)
	assert(claims.claim_item(primary,"first-fit",uid(5),0).ok)
	checkpoints.append(snapshot(queries,items,storage,native))
	# Private revenue projection is real and separate from public presentation.
	var prefix: String="economy." if native else ""
	execute(native,"INSERT INTO "+prefix+"account_shop_revenue(account_id,yang) VALUES("+str(account)+",12345);")
	assert(queries.mine(alt).claimable_yang=="12345" and not queries.visit(first.shop_id).has("claimable_yang"))
	assert(selling.configure(primary,"paused",0,"Claims fixture","paused").ok)
	assert(selling.edit_offer(primary,"offer-only",first.offers[0].offer_id,0,0,0).ok)
	public_view=queries.visit(first.shop_id)
	assert(public_view.status=="paused" and public_view.offers[0].price==null)
	# Existing account Storage still uses its transfer contract on the extended
	# schema, with no claim-specific field leaking into that custody shape.
	assert(storage.transfer_command(alt,uid(1),1,"inventory","storage",2,"store-received").ok)
	assert(storage.transfer_command(primary,uid(1),2,"storage","inventory",10,"take-received").ok)
	execute(native,"UPDATE "+prefix+"item_instances SET definition_id='unknown-fixture' WHERE uid='"+uid(90)+"';")
	assert(queries.mine(primary).error=="unknown_definition" and queries.visit(first.shop_id).error=="unknown_definition")
	execute(native,"UPDATE "+prefix+"item_instances SET definition_id='iron_sword' WHERE uid='"+uid(90)+"';")
	checkpoints.append(snapshot(queries,items,storage,native))
	return checkpoints

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var directory:=OS.get_environment("MANDATE_PG_FIXTURE_DIR")
	assert(directory.begins_with("res://.godot/verification/postgres-readiness/run-") and not ".." in directory)
	sqlite=SqliteSoci.new()
	sqlite.path=directory+"/account-claims.db"
	assert(not FileAccess.file_exists(sqlite.path) and sqlite.open_db())
	WorldSchema.ensure_schema(sqlite)
	var identities:=WorldStoreSqlite.new(sqlite)
	primary=EconomyFixture.create_character(identities,"owner",{"name":"Owner","skin":1})
	alt=EconomyFixture.create_character(identities,"owner",{"name":"Alt","skin":1})
	foreign=EconomyFixture.create_character(identities,"foreign",{"name":"Foreign","skin":1})
	account=identities.resolve_account_id(primary)
	var runtime:=WorldDatabase.new()
	runtime.db=sqlite
	runtime.store=identities
	EconomyFixture.prepare(runtime)
	connection=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and PriorSchema.ensure_schema(pg))
	var items:=Items.new(pg)
	var si:=ItemStoreSqlite.new(sqlite)
	for character: int in [primary,alt,foreign]:
		var id: int=identities.resolve_account_id(character)
		assert(Wallet.new(pg).initialize_account(id).ok and items.bind_character(character,id))
	for native: bool in [false,true]:
		var store: RefCounted=items if native else si
		var selling: RefCounted=Seller.new(pg) if native else MarketStoreSqlite.new(sqlite)
		var storage: RefCounted=Storage.new(pg) if native else AccountStorageSqlite.new(sqlite)
		seed_item(store,native,primary,90,0)
		seed_item(store,native,primary,91,1)
		assert(selling.list_item(primary,"prior-list",uid(90),0,0,100).ok)
		assert(storage.transfer_command(primary,uid(91),0,"inventory","storage",0,"prior-store").ok)
	var prior: Dictionary=Storage.new(pg).snapshot(primary)
	assert(Schema.ensure_schema(pg) and Schema.ensure_schema(pg) and Storage.new(pg).snapshot(primary)==prior)
	var sm:=MarketStoreSqlite.new(sqlite)
	var baseline:=exercise(sm,sm,sm,si,AccountStorageSqlite.new(sqlite),false)
	var candidate:=exercise(Claims.new(pg),Queries.new(pg),Seller.new(pg),items,Storage.new(pg),true)
	assert(baseline==candidate,"complete private/public projections, claim receiver/revisions and Inventory/Storage match SQLite")
	await native_checks(items)
	await retry_checks(items)
	pg.close()
	runtime.db=null
	runtime.free()
	sqlite.close_db()
	print("POSTGRES_ACCOUNT_CLAIMS_OK SQLite projections/claim parity, ownership/capacity, SQL/COMMIT recovery and independent-session conflicts")
	get_tree().quit()

func native_checks(items: RefCounted) -> void:
	assert(Wallet.new(pg).initialize_account(7000).ok)
	for character: int in [70000,70001]: assert(items.bind_character(character,7000))
	var claims:=Claims.new(pg)
	var queries:=Queries.new(pg)
	seed_claim(items,true,70000,9001,7000)
	var results:=await race([[70000,"a",uid(9001),0],[70001,"b",uid(9001),0]],"claim-race")
	assert(int(results[0].result.ok)+int(results[1].result.ok)==1)
	assert(results[0].result.get("error","")=="owner" or results[1].result.get("error","")=="owner")
	var receiver: int=70000 if results[0].result.ok else 70001
	assert(items.inventory(receiver).items.any(func(i: Dictionary) -> bool: return i.uid==uid(9001) and i.owner_character_id==receiver and i.revision==1))
	seed_claim(items,true,70000,9002,7000)
	results=await race([[70001,"shared",uid(9002),20],[70001,"shared",uid(9002),20]],"claim-replay")
	assert(results[0].result.ok and results[0].result==results[1].result and int(results[0].committed)+int(results[1].committed)==1)
	seed_claim(items,true,70000,9003,7000)
	seed_claim(items,true,70000,9004,7000)
	results=await race([[70000,"slot-a",uid(9003),10],[70000,"slot-b",uid(9004),15]],"claim-capacity")
	assert(int(results[0].result.ok)+int(results[1].result.ok)==1)
	assert(results[0].result.get("error","")=="occupied" or results[1].result.get("error","")=="occupied")
	seed_claim(items,true,70000,9005,7000)
	var before:=native_state()
	execute(true,"CREATE CONSTRAINT TRIGGER fixture_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_claim_fault();")
	var unknown: Dictionary=claims.claim_item(70001,"commit-claim",uid(9005),0,30)
	assert(unknown.get("outcome_unknown",false) and not pg.is_open() and not claims.committed)
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	execute(true,"DROP TRIGGER fixture_commit ON economy.market_commands;")
	assert(native_state()==before and claims.receipt(70001,"commit-claim").error=="unknown_command")
	assert(claims.claim_item(70001,"commit-claim",uid(9005),0,30).ok)
	# Cross-account provenance cannot be forged even by direct malformed SQL.
	seed_claim(items,true,70000,9006,7000)
	assert(pg.begin())
	assert(pg.execute("UPDATE economy.item_custody SET claim_account_id=:account WHERE uid=:uid;",{"account":account,"uid":uid(9006)}).ok)
	assert(not pg.commit() and pg.rollback())
	assert(pg.begin())
	assert(not pg.execute("UPDATE economy.item_custody SET claim_account_id=7000 WHERE uid=:uid;",{"uid":uid(9005)}).ok and pg.rollback(),"bag custody cannot retain a claim account")
	assert(pg.begin())
	assert(pg.execute("DELETE FROM economy.item_custody WHERE uid=:uid;",{"uid":uid(9006)}).ok)
	assert(not pg.commit() and pg.rollback(),"a claim cannot lose its unique custody row")
	assert(pg.begin())
	assert(claims.claim_item(70001,"nested",uid(9006),0).error=="storage")
	assert(queries.mine(70000).error=="storage" and queries.visit(1).error=="storage" and pg.in_transaction() and pg.rollback())
	# Keep the existing ordered 200-claim projection; draining exposes the next
	# row without losing it. No new pagination/network contract is introduced.
	for id: int in range(10000,10201): seed_claim(items,true,70000,id,7000,ItemDefinitions.UPGRADE_ORE)
	var view: Dictionary=queries.mine(70001)
	assert(view.claims.size()==200)
	var first: Dictionary=view.claims[0]
	var drained: Dictionary=claims.claim_item(70000,"drain-first",first.uid,int(first.revision),35)
	assert(drained.ok,"drain result: "+str(drained)+" item: "+str(first))
	view=queries.mine(70001)
	assert(view.claims.size()==200 and view.claims[0].uid!=first.uid)
	assert(not pg.in_transaction() and queries.visit(view.shop_id).claims.is_empty() and not pg.in_transaction())
	# Commit metadata/price changes between the public reader's real SELECTs.
	# The returned view must describe one revision, then a new call sees changes.
	seed_item(items,true,70000,13000,60)
	var selling:=Seller.new(pg)
	var listing: Dictionary=selling.list_item(70000,"visitor-offer",uid(13000),0,0,100)
	assert(listing.ok)
	var old_view: Dictionary=queries.visit(listing.shop_id)
	var writer: Object=ClassDB.instantiate("GodotSociDatabase")
	assert(writer.open("postgresql",connection))
	var concurrent_seller:=Seller.new(writer)
	var probe:=VisitBarrier.new(pg,func() -> void:
		assert(concurrent_seller.configure(70000,"during-read-name",0,"Changed","paused").ok)
		assert(concurrent_seller.edit_offer(70000,"during-read-price",listing.offer_id,0,0,200).ok))
	assert(Queries.new(probe).visit(listing.shop_id)==old_view)
	var changed: Dictionary=queries.visit(listing.shop_id)
	assert(changed.name=="Changed" and changed.status=="paused" and changed.offers[0].price==200 and changed.revision==1)
	assert(not pg.in_transaction())
	writer.close()
	var large: int=9007199254741033
	seed_claim(items,true,70000,12000,7000)
	execute(true,"UPDATE economy.item_instances SET revision="+str(large)+" WHERE uid='"+uid(12000)+"';")
	execute(true,"UPDATE economy.account_item_revisions SET revision="+str(large)+" WHERE account_id=7000;")
	var huge: Dictionary=claims.claim_item(70001,"large-claim",uid(12000),large,50)
	assert(huge.ok and huge.item_state.revision==large+2 and claims.receipt(70000,"large-claim")==huge)
	pg.close()
	assert(pg.open("postgresql",connection))
	assert(claims.claim_item(70001,"large-claim",uid(12000),large,50)==huge)
	execute(true,"UPDATE economy.schema_versions SET version=999 WHERE feature='account_claims';")
	assert(not Schema.ensure_schema(pg) and not pg.in_transaction())
	execute(true,"UPDATE economy.schema_versions SET version=1 WHERE feature='account_claims';")
	assert(Schema.ensure_schema(pg))
	print("POSTGRES_ACCOUNT_CLAIMS_NATIVE_OK exclusive UID, receipt replay, footprint race, provenance constraints, COMMIT recovery and bounded projections")

func native_state() -> Array:
	var state: Array=[]
	for table: String in ["item_instances","item_custody","market_commands","account_item_revisions"]:
		state.append(rows(true,"SELECT row_to_json(t)::text AS value FROM economy."+table+" t ORDER BY row_to_json(t)::text;"))
	return state

func race(specs: Array, label: String) -> Array:
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=7000 FOR UPDATE;").ok)
	var ready:=Semaphore.new()
	var workers: Array[Thread]=[]
	for spec: Array in specs:
		var worker:=Thread.new()
		assert(worker.start(race_worker.bind(connection+" application_name="+label,spec,ready))==OK)
		workers.append(worker)
	for index: int in 2: ready.wait()
	var waiting: int=0
	var deadline: int=Time.get_ticks_msec()+500
	while waiting<2 and Time.get_ticks_msec()<deadline:
		assert(pg.execute("SELECT pg_stat_clear_snapshot();").ok)
		waiting=int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name=:label AND wait_event_type='Lock';",{"label":label}).rows[0].n)
		if waiting<2: await get_tree().create_timer(0.005).timeout
	assert(pg.commit())
	var results: Array=[]
	for worker: Thread in workers: results.append(worker.wait_to_finish())
	assert(waiting==2,"both independent sessions actually overlap")
	return results

func race_worker(dsn: String, spec: Array, ready: Semaphore) -> Dictionary:
	var database: Object=ClassDB.instantiate("GodotSociDatabase")
	var opened: bool=database.open("postgresql",dsn)
	ready.post()
	if not opened: return {"result":{"ok":false,"error":"fixture_connection"},"committed":false}
	var claims:=Claims.new(database)
	var result: Dictionary=claims.claim_item(spec[0],spec[1],spec[2],0,spec[3])
	var committed: bool=claims.committed
	database.close()
	return {"result":result,"committed":committed}

func retry_checks(items: RefCounted) -> void:
	assert(Wallet.new(pg).initialize_account(8600).ok)
	assert(pg.execute("CREATE SEQUENCE economy.fixture_claim_attempt;").ok)
	assert(pg.execute("CREATE FUNCTION economy.fixture_claim_retry() RETURNS trigger LANGUAGE plpgsql AS $$ DECLARE attempt BIGINT; BEGIN attempt:=nextval('economy.fixture_claim_attempt'); IF attempt<=TG_ARGV[1]::BIGINT THEN IF TG_NARGS>2 THEN PERFORM pg_advisory_xact_lock(95132); END IF; RAISE EXCEPTION 'claim retry fixture' USING ERRCODE=TG_ARGV[0]; END IF; RETURN NEW; END; $$;").ok)
	var claims:=Claims.new(pg)
	var index: int=0
	for code: String in ["40001","40P01"]:
		for table: String in ["item_instances","item_custody","market_commands"]:
			for explicit_position: bool in [false,true]:
				var owner: int=86000+index*2
				var receiver: int=owner+1
				assert(items.bind_character(owner,8600) and items.bind_character(receiver,8600))
				var definition: ItemDefinition=ItemDefinitions.IRON_SWORD if explicit_position else ItemDefinitions.UPGRADE_ORE
				seed_claim(items,true,owner,900000+index,8600,definition)
				var item_uid: String=uid(900000+index)
				assert(pg.execute("UPDATE economy.item_instances SET amount=:amount,upgrade_level=:upgrade WHERE uid=:uid;",{"uid":item_uid,"amount":1 if explicit_position else 7,"upgrade":3 if explicit_position else 0}).ok)
				var original: Dictionary=pg.query("SELECT amount,upgrade_level,affixes_json,sockets_json FROM economy.item_instances WHERE uid=:uid;",{"uid":item_uid}).rows[0]
				claim_retry_fault(table,code,1)
				var destination: int=20 if explicit_position else -1
				var command_id: String="retry-claim-"+str(index)
				var result: Dictionary=claims.claim_item(receiver,command_id,item_uid,0,destination)
				assert(result.ok and claims.committed and claim_attempts()==2)
				clear_claim_retry(table)
				var inventory: Array=items.inventory(receiver).items
				assert(inventory.size()==1 and inventory[0].uid==item_uid and inventory[0].owner_character_id==receiver and inventory[0].revision==1 and inventory[0].bag_position==result.position)
				assert(inventory[0].affixes==JSON.parse_string(original.affixes_json) and inventory[0].sockets==JSON.parse_string(original.sockets_json))
				assert(inventory[0].amount==int(original.amount) and inventory[0].upgrade_level==int(original.upgrade_level))
				assert(result.position==(20 if explicit_position else 0))
				assert(pg.query("SELECT uid FROM economy.item_custody WHERE uid=:uid AND location='bag' AND owner_id=:owner AND claim_account_id IS NULL;",{"uid":item_uid,"owner":receiver}).rows.size()==1)
				var state:=native_state()
				assert(claims.claim_item(receiver,command_id,item_uid,0,destination)==result and not claims.committed)
				assert(claims.claim_item(owner,command_id,item_uid,0,destination).error=="command_conflict" and claims.receipt(owner,command_id)==result)
				pg.close()
				assert(pg.open("postgresql",connection) and claims.claim_item(receiver,command_id,item_uid,0,destination)==result and not claims.committed and native_state()==state)
				index+=1
	var owner: int=86900
	assert(items.bind_character(owner,8600))
	seed_claim(items,true,owner,910000,8600)
	for code: String in ["40001","40P01","23505","55P03","57014"]:
		claim_retry_fault("market_commands",code,99)
		var state:=native_state()
		assert(claims.claim_item(owner,"exhausted-claim-"+code,uid(910000),0).error=="storage" and not claims.committed)
		assert(claim_attempts()==(3 if code in ["40001","40P01"] else 1) and native_state()==state)
		clear_claim_retry("market_commands")
	for code: String in ["40001","40P01"]:
		claim_retry_fault("market_commands",code,99,true)
		var state:=native_state()
		var command_id: String="commit-retry-claim-"+code
		var result: Dictionary=claims.claim_item(owner,command_id,uid(910000),0)
		assert(result.get("outcome_unknown",false) and not claims.committed and not pg.is_open())
		assert(pg.open("postgresql",connection) and claim_attempts()==1)
		clear_claim_retry("market_commands")
		assert(native_state()==state and claims.receipt(owner,command_id).error=="unknown_command")
	# Storage errors are not permanent rejections: the original ID can recover.
	assert(claims.claim_item(owner,"exhausted-claim-40001",uid(910000),0).ok)
	for scenario: String in ["owner","explicit_capacity","auto_capacity"]:
		await retry_reselection(items,scenario)
	print("POSTGRES_ACCOUNT_CLAIMS_RETRY_OK complete claims, UID/provenance/revisions, fixed receiver/replay, bounded failures, no COMMIT retry and current custody/capacity")

func claim_attempts() -> int:
	return int(pg.query("SELECT last_value FROM economy.fixture_claim_attempt;").rows[0].last_value)

func claim_retry_fault(table: String, code: String, count: int, deferred: bool = false) -> void:
	assert(pg.execute("ALTER SEQUENCE economy.fixture_claim_attempt RESTART WITH 1;").ok)
	var operation: String="INSERT" if table=="market_commands" else "UPDATE"
	var create: String="CREATE CONSTRAINT TRIGGER fixture_retry AFTER "+operation+" ON economy."+table+" DEFERRABLE INITIALLY DEFERRED" if deferred else "CREATE TRIGGER fixture_retry BEFORE "+operation+" ON economy."+table
	assert(pg.execute(create+" FOR EACH ROW EXECUTE FUNCTION economy.fixture_claim_retry('%s','%d');" % [code,count]).ok)

func clear_claim_retry(table: String) -> void:
	assert(pg.execute("DROP TRIGGER fixture_retry ON economy."+table+";").ok)

func retry_reselection(items: RefCounted, scenario: String) -> void:
	var index: int=["owner","explicit_capacity","auto_capacity"].find(scenario)
	var owner: int=86910+index*2
	var receiver: int=owner+1
	assert(items.bind_character(owner,8600) and items.bind_character(receiver,8600))
	seed_claim(items,true,owner,920000+index,8600)
	var item_uid: String=uid(920000+index)
	var blocked: int=InventoryGrid.cells(0,ItemDefinitions.IRON_SWORD.inventory_height).back()
	if scenario!="owner": seed_item(items,true,receiver,930000+index,20,ItemDefinitions.UPGRADE_ORE)
	assert(pg.execute("ALTER SEQUENCE economy.fixture_claim_attempt RESTART WITH 1;").ok)
	assert(pg.execute("CREATE TRIGGER fixture_retry BEFORE INSERT ON economy.market_commands FOR EACH ROW WHEN (current_setting('application_name')='retry-claim') EXECUTE FUNCTION economy.fixture_claim_retry('40001','1','gate');").ok)
	assert(pg.execute("SELECT pg_advisory_lock(95132);").ok)
	# Coordination slack is limited to these diagnostic worker sessions.
	var budgets: String=" options='-c statement_timeout=10000 -c lock_timeout=8000 -c idle_in_transaction_session_timeout=10000'"
	var ready:=Semaphore.new()
	var actor:=Thread.new()
	var command_id: String="reselect-claim-"+scenario
	assert(actor.start(race_worker.bind(connection+" application_name=retry-claim"+budgets,[receiver,command_id,item_uid,-1 if scenario=="auto_capacity" else 0],ready))==OK)
	ready.wait()
	var acting: bool=await claim_waiting("retry-claim")
	var editor:=Thread.new()
	assert(editor.start(claim_editor.bind(connection+" application_name=retry-claim-editor"+budgets,owner if scenario=="owner" else receiver,item_uid if scenario=="owner" else uid(930000+index),scenario=="owner",blocked,ready))==OK)
	ready.wait()
	var editing: bool=await claim_waiting("retry-claim-editor")
	assert(pg.execute("SELECT pg_advisory_unlock(95132);").ok)
	var acted: Dictionary=actor.wait_to_finish()
	var edited: Dictionary=editor.wait_to_finish()
	clear_claim_retry("market_commands")
	assert(acting and editing and edited.result.ok and edited.committed)
	if scenario=="auto_capacity":
		assert(acted.result.ok and acted.committed and acted.result.position!=0 and claim_attempts()==2)
		assert(not InventoryGrid.cells(int(acted.result.position),ItemDefinitions.IRON_SWORD.inventory_height).has(blocked))
		assert(items.inventory(receiver).items.any(func(item: Dictionary) -> bool: return item.uid==item_uid and item.owner_character_id==receiver and item.revision==1))
	else:
		assert(acted.result.error==("owner" if scenario=="owner" else "occupied") and not acted.committed and claim_attempts()==1)
		assert(Claims.new(pg).receipt(receiver,command_id).error=="unknown_command")
		var custody: Dictionary=pg.query("SELECT location,owner_id,claim_account_id FROM economy.item_custody WHERE uid=:uid;",{"uid":item_uid}).rows[0]
		assert((custody.location=="bag" and int(custody.owner_id)==owner) if scenario=="owner" else (custody.location=="account_claim" and int(custody.claim_account_id)==8600))

func claim_waiting(label: String) -> bool:
	var deadline: int=Time.get_ticks_msec()+2000
	while Time.get_ticks_msec()<deadline:
		assert(pg.execute("SELECT pg_stat_clear_snapshot();").ok)
		if int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name=:label AND wait_event_type='Lock';",{"label":label}).rows[0].n)==1: return true
		await get_tree().create_timer(0.005).timeout
	return false

func claim_editor(dsn: String, character: int, item_uid: String, claim: bool, position: int, ready: Semaphore) -> Dictionary:
	var database: Object=ClassDB.instantiate("GodotSociDatabase")
	var opened: bool=database.open("postgresql",dsn)
	ready.post()
	if not opened: return {"result":{"ok":false,"error":"fixture_connection"},"committed":false}
	var store: RefCounted=Claims.new(database) if claim else Items.new(database)
	var result: Dictionary=store.claim_item(character,"claim-editor-"+item_uid,item_uid,0,0) if claim else store.inventory_command(character,"move",item_uid,0,position,"claim-editor-"+item_uid)
	var committed: bool=store.committed
	database.close()
	return {"result":result,"committed":committed}
