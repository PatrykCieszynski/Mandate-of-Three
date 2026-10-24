extends Node
## Native seller custody/occupancy/receipts require backend parity and overlapping
## sessions. Purchase, revenue and account claims are deliberately separate risks.
const Schema = preload("res://source/server/world/database/postgres/shop_schema_postgres.gd")
const Grid = preload("res://source/common/gameplay/items/domain/shop_grid.gd")
const StorageSchema = preload("res://source/server/world/database/postgres/storage_schema_postgres.gd")
const PgSeller = preload("res://source/server/world/database/postgres/shop_seller_postgres.gd")
const PgItems = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const PgWallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const PgStorage = preload("res://source/server/world/database/postgres/account_storage_postgres.gd")
const SqliteState = preload("res://source/server/world/database/item_state_revision_sqlite.gd")
var sqlite: SqliteSoci
var pg: Object
var buyer: int
var alternate: int
var stranger: int
var account: int
var connection: String

func uid(id: int) -> String: return str(id).pad_zeros(32)

func receipt(seller: RefCounted, character: int, command: String) -> Dictionary:
	# Legacy SQLite read-only receipts parse numeric JSON scalars as floats;
	# compare their integer meanings, as its replay path already does.
	var result: Dictionary=seller.receipt(character,command)
	for field: String in ["revision","position","shop_id","price","balance"]:
		if result.has(field): result[field]=int(result[field])
	return result

func seed_item(items: RefCounted, is_pg: bool, character: int, id: int, position: int, definition: ItemDefinition = ItemDefinitions.IRON_SWORD) -> void:
	var item:=ItemInstance.create(definition,character,[{"stat":"attack","value":3}])
	item.uid=uid(id)
	assert(pg.begin() if is_pg else sqlite.query("BEGIN IMMEDIATE;"))
	assert(items.receive_item_in_transaction(item,position).ok)
	assert(pg.commit() if is_pg else sqlite.query("COMMIT;"))

func rows(is_pg: bool, query: String) -> Array:
	if is_pg:
		var result: Dictionary=pg.query(query)
		assert(result.ok and not result.truncated)
		return result.rows
	assert(sqlite.query(query))
	return sqlite.query_result.duplicate(true)

func capture(seller: RefCounted, items: RefCounted, storage: RefCounted, is_pg: bool) -> Dictionary:
	var shops: Array=[]
	var inventories: Array=[]
	for character: int in [buyer,alternate,stranger]:
		var snapshot: Dictionary=seller.mine(character)
		assert(snapshot.ok)
		# Compare seller projection only, never fabricate unported claims/revenue.
		snapshot.erase("claims")
		snapshot.erase("claimable_yang")
		shops.append(snapshot)
		inventories.append(items.inventory(character))
	var prefix: String="economy." if is_pg else ""
	return {"shops":shops,"inventories":inventories,"storage":storage.snapshot(buyer),"cells":rows(is_pg,"SELECT shop_id,position,item_uid FROM "+prefix+"shop_cells ORDER BY shop_id,position;"),"receipts":int(rows(is_pg,"SELECT COUNT(*) AS n FROM "+prefix+"market_commands;")[0].n)}

func canonical(snapshot: Dictionary) -> Dictionary:
	var result:=snapshot.duplicate(true)
	var ids: Dictionary={int(result.shops[0].shop_id):"seller",int(result.shops[2].shop_id):"foreign"}
	for shop: Dictionary in result.shops:
		shop.shop_id=ids[int(shop.shop_id)]
		for offer: Dictionary in shop.offers: offer.offer_id=offer.item.uid
	for cell: Dictionary in result.cells: cell.shop_id=ids[int(cell.shop_id)]
	for inventory: Dictionary in result.inventories: inventory.item_state.erase("authority_id")
	return result

func fault(is_pg: bool, table: String, event: String, condition: String = "") -> void:
	var guard: String="" if condition.is_empty() else " WHEN ("+condition+")"
	if is_pg:
		assert(pg.execute("CREATE OR REPLACE FUNCTION economy.fixture_seller_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'seller fixture fault'; END; $$;").ok)
		assert(pg.execute("CREATE TRIGGER fixture_seller_fault BEFORE %s ON economy.%s FOR EACH ROW%s EXECUTE FUNCTION economy.fixture_seller_fault();" % [event,table,guard]).ok)
	else:
		assert(sqlite.query("CREATE TEMP TRIGGER fixture_seller_fault BEFORE %s ON %s%s BEGIN SELECT RAISE(ABORT,'seller fixture fault'); END;" % [event,table,guard]))

func clear_fault(is_pg: bool, table: String) -> void:
	assert(pg.execute("DROP TRIGGER fixture_seller_fault ON economy.%s;" % table).ok if is_pg else sqlite.query("DROP TRIGGER fixture_seller_fault;"))

func exercise(seller: RefCounted, items: RefCounted, storage: RefCounted, is_pg: bool) -> Array:
	var checkpoints: Array=[]
	for spec: Array in [[1,0],[2,1],[5,4],[6,10]]: seed_item(items,is_pg,buyer,int(spec[0]),int(spec[1]))
	seed_item(items,is_pg,buyer,3,2,ItemDefinitions.UPGRADE_ORE)
	seed_item(items,is_pg,buyer,4,3,ItemDefinitions.DEV_TRACE_SWORD)
	assert(items.inventory_command(buyer,"equip",uid(5),0,-1,"equip").ok)
	assert(storage.transfer_command(buyer,uid(6),0,"inventory","storage",0,"stored").ok)
	var before:=capture(seller,items,storage,is_pg)
	assert(seller.mine(999999).error=="owner")
	assert(seller.list_item(alternate,"other-bag",uid(1),0,0,10).error=="owner")
	assert(seller.list_item(buyer,"stored",uid(6),1,0,10).error=="command_conflict")
	assert(seller.list_item(buyer,"stored-target",uid(6),1,0,10).error=="owner")
	assert(seller.list_item(buyer,"equipped-target",uid(5),1,0,10).error=="owner")
	assert(seller.list_item(buyer,"not-tradeable",uid(4),0,0,10).error=="not_tradeable")
	assert(seller.list_item(buyer,"edge",uid(1),0,35,10).error=="placement")
	assert(capture(seller,items,storage,is_pg)==before)
	var listed: Dictionary=seller.list_item(buyer,"list-one",uid(1),0,0,0)
	assert(listed.ok and seller.committed)
	var offer: String=listed.offer_id
	assert(seller.mine(alternate).offers[0].price==null and seller.mine(alternate).offers[0].item.owner_character_id==buyer)
	assert(not items.inventory(buyer).items.any(func(i: Dictionary) -> bool: return i.uid==uid(1)))
	assert(items.inventory_command(buyer,"equip",uid(1),1,-1,"escrow-equip").error=="owner")
	assert(seller.list_item(buyer,"overlap",uid(2),0,5,100).error=="occupied", "different starting cell still overlaps the sword footprint")
	assert(seller.configure(alternate,"name",0,"  Seller fixture  ","paused").ok)
	assert(seller.configure(buyer,"bad-name",1,"bad\nname","active").error=="request")
	assert(seller.configure(buyer,"stale-name",0,"Name","active").error=="stale")
	before=capture(seller,items,storage,is_pg)
	for stage: Array in [["item_custody","UPDATE",""],["shop_offers","INSERT",""],["shop_cells","INSERT","NEW.position=7"],["item_instances","UPDATE",""],["market_commands","INSERT",""]]:
		fault(is_pg,stage[0],stage[1],stage[2])
		assert(seller.list_item(buyer,"fault-list-"+stage[0],uid(2),0,2,250).error=="storage")
		assert(capture(seller,items,storage,is_pg)==before, "partial custody/offer/cells/item/receipt writes must roll back")
		clear_fault(is_pg,stage[0])
	var second: Dictionary=seller.list_item(buyer,"fault-list-market_commands",uid(2),0,2,250)
	assert(second.ok)
	assert(seller.edit_offer(alternate,"move",offer,0,1,123).ok)
	var watermark: int=items.read_state(buyer).revision if is_pg else SqliteState.read(sqlite,buyer).revision
	assert(seller.edit_offer(buyer,"price",offer,1,1,200).ok)
	var after_watermark: int=items.read_state(buyer).revision if is_pg else SqliteState.read(sqlite,buyer).revision
	assert(watermark==after_watermark, "price-only edit changes offer revision, not item revision/watermark")
	assert(seller.list_item(buyer,"overlap",uid(2),0,5,100).error=="occupied", "bounded reject remains stable while cached")
	assert(seller.list_item(buyer,"overlap",uid(2),0,5,101).error=="command_conflict")
	before=capture(seller,items,storage,is_pg)
	fault(is_pg,"shop_cells","INSERT","NEW.position=9")
	assert(seller.edit_offer(buyer,"fault-edit",offer,2,4,100).error=="storage")
	assert(capture(seller,items,storage,is_pg)==before)
	clear_fault(is_pg,"shop_cells")
	fault(is_pg,"market_commands","INSERT")
	assert(seller.configure(buyer,"fault-config",1,"New name","active").error=="storage")
	assert(capture(seller,items,storage,is_pg)==before)
	clear_fault(is_pg,"market_commands")
	checkpoints.append(canonical(before))
	# Three-cell item with overlapping old/new footprints; no rotation.
	var ore: ItemDefinition=ItemDefinitions.get_definition(&"upgrade_ore")
	var height: int=ore.inventory_height
	ore.inventory_height=3
	var tall: Dictionary=seller.list_item(buyer,"tall",uid(3),0,29,10)
	assert(tall.ok and seller.edit_offer(alternate,"tall-move",tall.offer_id,0,24,0).ok)
	assert(seller.edit_offer(buyer,"tall-edge",tall.offer_id,1,30,0).error=="placement")
	assert(seller.cancel_offer(alternate,"tall-return",tall.offer_id,1).ok)
	ore.inventory_height=height
	before=capture(seller,items,storage,is_pg)
	for stage: Array in [["item_instances","UPDATE"],["item_custody","UPDATE"],["shop_offers","DELETE"],["market_commands","INSERT"]]:
		fault(is_pg,stage[0],stage[1])
		assert(seller.cancel_offer(alternate,"fault-cancel-"+stage[0],offer,2).error=="storage")
		assert(capture(seller,items,storage,is_pg)==before, "withdrawal rollback restores receiving provenance, cells and offer")
		clear_fault(is_pg,stage[0])
	var returned: Dictionary=seller.cancel_offer(alternate,"return-one",offer,2)
	assert(returned.ok and items.inventory(alternate).items.any(func(i: Dictionary) -> bool: return i.uid==uid(1) and i.owner_character_id==alternate and i.revision==3))
	before=capture(seller,items,storage,is_pg)
	assert(seller.cancel_offer(buyer,"return-one",offer,2)==returned and not seller.committed)
	assert(seller.list_item(alternate,"list-one",uid(1),0,0,0)==listed and not seller.committed)
	assert(receipt(seller,buyer,"return-one")==returned and receipt(seller,stranger,"return-one").error=="unknown_command")
	assert(seller.cancel_offer(buyer,"return-one",offer,3).error=="command_conflict")
	assert(capture(seller,items,storage,is_pg)==before, "account retry must not retarget the original receiving character")
	checkpoints.append(canonical(before))
	# Fill receiving Inventory; failure must not silently send the item to Storage/claims.
	var occupied: Dictionary={}
	for item: Dictionary in items.inventory(alternate).items:
		for cell: int in InventoryGrid.cells(item.bag_position,item.inventory_height): occupied[cell]=true
	for cell: int in InventoryGrid.CAPACITY:
		if not occupied.has(cell): seed_item(items,is_pg,alternate,1000+cell,cell,ItemDefinitions.UPGRADE_ORE)
	before=capture(seller,items,storage,is_pg)
	assert(seller.cancel_offer(alternate,"full-return",second.offer_id,0).error=="inventory_full")
	assert(capture(seller,items,storage,is_pg)==before)
	var prefix: String="economy." if is_pg else ""
	assert(pg.begin() if is_pg else sqlite.query("BEGIN IMMEDIATE;"))
	for cell: int in [2,7]:
		var id: String=uid(1000+cell)
		var query: String="DELETE FROM "+prefix+"item_custody WHERE uid='"+id+"';"
		assert(pg.execute(query).ok if is_pg else sqlite.query(query))
		query="DELETE FROM "+prefix+"item_instances WHERE uid='"+id+"';"
		assert(pg.execute(query).ok if is_pg else sqlite.query(query))
	assert(pg.commit() if is_pg else sqlite.query("COMMIT;"))
	assert(seller.cancel_offer(alternate,"full-return",second.offer_id,0).error=="inventory_full")
	var withdrawn: Dictionary=seller.cancel_offer(alternate,"return-two",second.offer_id,0)
	assert(withdrawn.ok and withdrawn.position==2)
	before=capture(seller,items,storage,is_pg)
	for index: int in 160:
		assert(seller.cancel_offer(buyer,"reject-"+str(index),"missing",0).error=="unavailable")
	assert(seller.rejected.size(account)<=MarketRejectedCommands.MAX_PER_ACCOUNT)
	assert(capture(seller,items,storage,is_pg)==before)
	if is_pg:
		pg.close()
		assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
		seller=PgSeller.new(pg)
	else:
		assert(sqlite.close_db() and sqlite.open_db())
		seller=MarketStoreSqlite.new(sqlite)
	assert(seller.receipt(buyer,"reject-159").error=="unknown_command", "negative results are bounded RAM, not durable rows")
	assert(seller.cancel_offer(buyer,"return-two",second.offer_id,0)==withdrawn)
	assert(seller.list_item(alternate,"list-one",uid(1),0,0,0)==listed)
	assert(receipt(seller,alternate,"return-one")==returned)
	assert(capture(seller,items,storage,is_pg)==before)
	checkpoints.append(canonical(before))
	return checkpoints

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var directory:=OS.get_environment("MANDATE_PG_FIXTURE_DIR")
	assert(directory.begins_with("res://.godot/verification/postgres-readiness/run-") and not ".." in directory)
	sqlite=SqliteSoci.new()
	sqlite.path=directory+"/shop-seller.db"
	assert(not FileAccess.file_exists(sqlite.path) and sqlite.open_db())
	WorldSchema.ensure_schema(sqlite)
	var identities:=WorldStoreSqlite.new(sqlite)
	buyer=EconomyFixture.create_character(identities,"pg-seller-a",{"name":"A","skin":1})
	alternate=EconomyFixture.create_character(identities,"pg-seller-a",{"name":"Alt","skin":1})
	stranger=EconomyFixture.create_character(identities,"pg-seller-b",{"name":"B","skin":1})
	var runtime:=WorldDatabase.new()
	runtime.db=sqlite
	runtime.store=identities
	EconomyFixture.prepare(runtime)
	account=identities.resolve_account_id(buyer)
	connection=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and StorageSchema.ensure_schema(pg))
	var items:=PgItems.new(pg)
	for character: int in [buyer,alternate,stranger]:
		var id:=identities.resolve_account_id(character)
		assert(PgWallet.new(pg).initialize_account(id).ok and items.bind_character(character,id))
	# Upgrade existing populated Inventory/Storage, not only an empty schema.
	seed_item(items,true,stranger,99,0)
	seed_item(ItemStoreSqlite.new(sqlite),false,stranger,99,0)
	assert(PgStorage.new(pg).transfer_command(stranger,uid(99),0,"inventory","storage",0,"prior-storage").ok)
	assert(AccountStorageSqlite.new(sqlite).transfer_command(stranger,uid(99),0,"inventory","storage",0,"prior-storage").ok)
	var prior: Dictionary=PgStorage.new(pg).snapshot(stranger)
	assert(Schema.ensure_schema(pg) and Schema.ensure_schema(pg) and PgStorage.new(pg).snapshot(stranger)==prior)
	var baseline:=exercise(MarketStoreSqlite.new(sqlite),ItemStoreSqlite.new(sqlite),AccountStorageSqlite.new(sqlite),false)
	var candidate:=exercise(PgSeller.new(pg),items,PgStorage.new(pg),true)
	assert(baseline==candidate, "seller snapshots, occupancy, Inventory/Storage, revisions and receipt counts match SQLite")
	await native_checks(items)
	await retry_checks(items)
	pg.close()
	runtime.db=null
	runtime.free()
	sqlite.close_db()
	for suffix: String in ["","-wal","-shm"]: DirAccess.remove_absolute(ProjectSettings.globalize_path(sqlite.path+suffix))
	print("POSTGRES_SHOP_SELLER_OK SQLite parity: listing/edit/configure/withdrawal, escrow/cells/revisions, bounded rejects, receipts/reopen and native faults/races")
	get_tree().quit()

func native_state(seller: RefCounted, items: RefCounted, a: int, b: int) -> Dictionary:
	return {"shop":seller.mine(a),"a":items.inventory(a),"b":items.inventory(b),"cells":rows(true,"SELECT * FROM economy.shop_cells ORDER BY shop_id,position;"),"receipts":rows(true,"SELECT account_id,command_id,result_json FROM economy.market_commands ORDER BY account_id,command_id;")}

func native_checks(items: RefCounted) -> void:
	var a: int=70001
	var b: int=70002
	assert(PgWallet.new(pg).initialize_account(7000).ok and PgWallet.new(pg).initialize_account(7001).ok)
	assert(items.bind_character(a,7000) and items.bind_character(b,7000))
	seed_item(items,true,a,9001,0)
	seed_item(items,true,b,9002,0)
	seed_item(items,true,a,901,1)
	var seller:=PgSeller.new(pg)
	var listed: Dictionary={}
	for action: String in ["list","edit","cancel"]:
		var before:=native_state(seller,items,a,b)
		assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_seller_fault();").ok)
		var result: Dictionary
		match action:
			"list": result=seller.list_item(a,"commit-list",uid(901),0,20,100)
			"edit": result=seller.edit_offer(b,"commit-edit",listed.offer_id,0,25,200)
			_: result=seller.cancel_offer(b,"commit-cancel",listed.offer_id,0)
		assert(result.get("outcome_unknown",false) and not pg.is_open() and not seller.committed)
		assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
		assert(pg.execute("DROP TRIGGER fixture_commit ON economy.market_commands;").ok)
		assert(native_state(seller,items,a,b)==before)
		assert(seller.receipt(a,"commit-"+action).error=="unknown_command")
		if action=="list":
			listed=seller.list_item(a,"commit-list",uid(901),0,20,100)
			assert(listed.ok, "unknown COMMIT was inspected before explicit same-ID retry")
	assert(seller.cancel_offer(b,"commit-cancel",listed.offer_id,0).ok)
	assert(pg.begin())
	assert(seller.list_item(a,"nested",uid(9001),0,0,100).error=="storage")
	assert(seller.mine(a).error=="storage" and pg.in_transaction() and pg.rollback())
	var results:=await race(a,b,"list",[[uid(9001),0,0,100],[uid(9002),0,5,100]],"cell-race")
	assert(int(results[0].result.ok)+int(results[1].result.ok)==1)
	assert(results[0].result.get("error","")=="occupied" or results[1].result.get("error","")=="occupied")
	var offer: Dictionary=seller.mine(a).offers[0]
	assert(rows(true,"SELECT * FROM economy.shop_cells WHERE item_uid='"+str(offer.item.uid)+"';").size()==2)
	var before:=native_state(seller,items,a,b)
	assert(pg.begin())
	assert(pg.execute("UPDATE economy.item_custody SET escrow_account_id=7001 WHERE uid=:uid;",{"uid":offer.item.uid}).ok)
	assert(not pg.commit() and pg.rollback(), "escrow must match provenance and Shop account")
	assert(pg.begin())
	assert(pg.execute("DELETE FROM economy.shop_offers WHERE offer_id=:offer;",{"offer":offer.offer_id}).ok)
	assert(not pg.commit() and pg.rollback(), "escrow cannot outlive its matching offer")
	assert(native_state(seller,items,a,b)==before)
	results=await race(a,b,"cancel",[[offer.offer_id,0],[offer.offer_id,0]],"cancel-race")
	assert(int(results[0].result.ok)+int(results[1].result.ok)==1)
	assert(results[0].result.get("error","")=="unavailable" or results[1].result.get("error","")=="unavailable")
	var receiver: int=a if results[0].result.ok else b
	var target: String=offer.item.uid
	assert(items.inventory(receiver).items.any(func(i: Dictionary) -> bool: return i.uid==target and i.owner_character_id==receiver and i.revision==2))
	listed=seller.list_item(receiver,"relist",target,2,10,100)
	assert(listed.ok)
	results=await race(a,b,"cancel",[[listed.offer_id,0],[listed.offer_id,0]],"shared-id",true)
	assert(results[0].result.ok and results[0].result==results[1].result)
	assert(int(results[0].committed)+int(results[1].committed)==1, "shared account fingerprint permits one mutation plus identical cross-alt replay")
	receiver=int(results[0].result.item_state.character_id)
	assert(items.inventory(receiver).items.any(func(i: Dictionary) -> bool: return i.uid==target and i.revision==4))
	assert(seller.mine(a).offers.is_empty() and rows(true,"SELECT * FROM economy.shop_cells WHERE shop_id="+str(listed.shop_id)+";").is_empty())
	# Native BIGINT result scalars must not round-trip through JSON doubles.
	var large: int=9007199254741033
	assert(pg.execute("UPDATE economy.account_shops SET shop_id=:large,revision=:large WHERE account_id=7000;",{"large":large}).ok)
	var configured: Dictionary=seller.configure(a,"huge-revision",large,"Large IDs","active")
	assert(configured.ok and configured.revision==large+1 and seller.receipt(b,"huge-revision")==configured)
	listed=seller.list_item(receiver,"huge-shop",target,4,0,100)
	assert(listed.ok and listed.shop_id==large and seller.receipt(a,"huge-shop")==listed)
	assert(seller.list_item(a,"huge-shop",target,4,0,100)==listed)
	assert(pg.execute("UPDATE economy.schema_versions SET version=999 WHERE feature='shop_seller';").ok)
	assert(not Schema.ensure_schema(pg) and not pg.in_transaction())
	assert(pg.execute("UPDATE economy.schema_versions SET version=1 WHERE feature='shop_seller';").ok and Schema.ensure_schema(pg))
	print("POSTGRES_SHOP_SELLER_NATIVE_OK independent overlapping occupancy/withdrawal/replay, mutual escrow constraints, COMMIT unknown and int64 scalar receipts")

func race(a: int, b: int, action: String, args: Array, label: String, same_id: bool = false) -> Array:
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=7000 FOR UPDATE;").ok)
	var ready:=Semaphore.new()
	var workers: Array[Thread]=[]
	for index: int in 2:
		var worker:=Thread.new()
		assert(worker.start(race_worker.bind(connection+" application_name="+label,a if index==0 else b,action,args[index],label if same_id else label+"-"+str(index),ready))==OK)
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
	assert(waiting==2, "both native transactions must actually overlap")
	return results

func race_worker(dsn: String, character: int, action: String, args: Array, id: String, ready: Semaphore) -> Dictionary:
	var database: Object=ClassDB.instantiate("GodotSociDatabase")
	var opened: bool=database.open("postgresql",dsn)
	ready.post()
	if not opened: return {"result":{"ok":false,"error":"fixture_connection"},"committed":false}
	var store: RefCounted=PgItems.new(database) if action=="inventory" else (PgStorage.new(database) if action=="storage" else PgSeller.new(database))
	var result: Dictionary
	if action=="inventory": result=store.inventory_command(character,args[0],args[1],args[2],args[3],id)
	elif action=="storage": result=store.transfer_command(character,args[0],args[1],args[2],args[3],args[4],id)
	else: result=retry_call(store,character,action,args,id)
	var committed: bool=store.committed
	database.close()
	return {"result":result,"committed":committed}

func retry_call(seller: RefCounted, character: int, action: String, args: Array, command_id: String) -> Dictionary:
	match action:
		"list": return seller.list_item(character,command_id,args[0],args[1],args[2],args[3])
		"edit": return seller.edit_offer(character,command_id,args[0],args[1],args[2],args[3])
		"configure": return seller.configure(character,command_id,args[0],args[1],args[2])
		_: return seller.cancel_offer(character,command_id,args[0],args[1])

func retry_checks(items: RefCounted) -> void:
	assert(PgWallet.new(pg).initialize_account(8500).ok)
	assert(pg.execute("CREATE SEQUENCE economy.fixture_seller_attempt;").ok)
	assert(pg.execute("CREATE FUNCTION economy.fixture_seller_retry() RETURNS trigger LANGUAGE plpgsql AS $$ DECLARE attempt BIGINT; BEGIN attempt:=nextval('economy.fixture_seller_attempt'); IF attempt>=TG_ARGV[1]::BIGINT AND attempt<=TG_ARGV[2]::BIGINT THEN IF TG_NARGS>3 THEN PERFORM pg_advisory_xact_lock(95131); END IF; RAISE EXCEPTION 'seller retry fixture' USING ERRCODE=TG_ARGV[0]; END IF; RETURN NEW; END; $$;").ok)
	var seller:=PgSeller.new(pg)
	var index: int=0
	for code: String in ["40001","40P01"]:
		for receipt_fault: bool in [false,true]:
			var owner: int=85000+index*2
			var alt: int=owner+1
			assert(items.bind_character(owner,8500) and items.bind_character(alt,8500))
			var item_uid: String=uid(500000+index)
			seed_item(items,true,owner,500000+index,0)
			var original: Dictionary=items.inventory(owner).items[0]
			# Fail at the last cell after custody/offer and earlier cells were written.
			var cells: int=ItemDefinitions.IRON_SWORD.inventory_height
			var table: String="market_commands" if receipt_fault else "shop_cells"
			var fault_at: int=1 if receipt_fault else cells
			seller_retry_fault(table,"INSERT",code,fault_at,fault_at)
			var listed: Dictionary=seller.list_item(owner,"cycle-list-"+str(index),item_uid,0,0,100)
			assert(listed.ok and seller.committed and seller_attempts()==(2 if receipt_fault else cells*2))
			clear_seller_retry(table)
			var state:=retry_state()
			assert(seller.list_item(alt,"cycle-list-"+str(index),item_uid,0,0,100)==listed and not seller.committed and retry_state()==state)
			assert(seller.receipt(alt,"cycle-list-"+str(index))==listed)
			var shop_revision: int=int(seller.mine(owner).revision)
			table="market_commands" if receipt_fault else "account_shops"
			seller_retry_fault(table,"INSERT" if receipt_fault else "UPDATE",code,1,1)
			var configured: Dictionary=seller.configure(alt,"cycle-config-"+str(index),shop_revision,"Retry shop","paused")
			assert(configured.ok and seller.committed and configured.revision==shop_revision+1 and seller_attempts()==2)
			clear_seller_retry(table)
			state=retry_state()
			assert(seller.configure(owner,"cycle-config-"+str(index),shop_revision,"Retry shop","paused")==configured and not seller.committed and retry_state()==state)
			assert(seller.mine(owner).status=="paused")
			table="market_commands" if receipt_fault else "shop_cells"
			seller_retry_fault(table,"INSERT",code,fault_at,fault_at)
			var edited: Dictionary=seller.edit_offer(alt,"cycle-edit-"+str(index),listed.offer_id,0,10,0)
			assert(edited.ok and seller.committed and edited.revision==1 and seller_attempts()==(2 if receipt_fault else cells*2))
			clear_seller_retry(table)
			assert(seller.mine(owner).offers[0].price==null and seller.mine(owner).offers[0].item.revision==2)
			state=retry_state()
			assert(seller.edit_offer(owner,"cycle-edit-"+str(index),listed.offer_id,0,10,0)==edited and not seller.committed and retry_state()==state)
			# A retried price-only edit changes the offer, not item/custody revisions.
			var watermark: Dictionary=items.read_state(owner)
			seller_retry_fault("market_commands","INSERT",code,1,1)
			assert(seller.edit_offer(owner,"cycle-price-"+str(index),listed.offer_id,1,10,200).ok and seller_attempts()==2)
			clear_seller_retry("market_commands")
			assert(items.read_state(owner)==watermark and seller.mine(alt).offers[0].item.revision==2)
			table="market_commands" if receipt_fault else "item_custody"
			seller_retry_fault(table,"INSERT" if receipt_fault else "UPDATE",code,1,1)
			var returned: Dictionary=seller.cancel_offer(alt,"cycle-cancel-"+str(index),listed.offer_id,2)
			assert(returned.ok and seller.committed and seller_attempts()==2)
			clear_seller_retry(table)
			var inventory: Array=items.inventory(alt).items
			assert(inventory.size()==1 and inventory[0].uid==item_uid and inventory[0].owner_character_id==alt and inventory[0].revision==3 and inventory[0].bag_position==returned.position)
			assert(inventory[0].affixes==original.affixes and inventory[0].sockets==original.sockets and seller.mine(owner).offers.is_empty())
			assert(rows(true,"SELECT * FROM economy.shop_cells WHERE item_uid='"+item_uid+"';").is_empty())
			state=retry_state()
			assert(seller.cancel_offer(owner,"cycle-cancel-"+str(index),listed.offer_id,2)==returned and not seller.committed and retry_state()==state)
			index+=1
	var owner: int=85900
	assert(items.bind_character(owner,8500))
	seed_item(items,true,owner,600000,0)
	seed_item(items,true,owner,600001,1)
	var offer: Dictionary=seller.list_item(owner,"budget-source",uid(600001),0,20,100)
	assert(offer.ok)
	var commands: Dictionary={"list":[uid(600000),0,0,100],"configure":[int(seller.mine(owner).revision),"Updated shop","active"],"edit":[offer.offer_id,0,10,0],"cancel":[offer.offer_id,0]}
	for action: String in commands:
		for code: String in ["40001","40P01","23505","55P03","57014"]:
			seller_retry_fault("market_commands","INSERT",code,1,99)
			var state:=retry_state()
			var result: Dictionary=retry_call(seller,owner,action,commands[action],"exhausted-"+action+code)
			assert(result.error=="storage" and not seller.committed and not pg.in_transaction() and retry_state()==state)
			assert(seller_attempts()==(3 if code in ["40001","40P01"] else 1))
			clear_seller_retry("market_commands")
		for code: String in ["40001","40P01"]:
			seller_retry_fault("market_commands","INSERT",code,1,99,true)
			var state:=retry_state()
			var result: Dictionary=retry_call(seller,owner,action,commands[action],"unknown-"+action+code)
			assert(result.get("outcome_unknown",false) and not seller.committed and not pg.is_open())
			assert(pg.open("postgresql",connection) and seller_attempts()==1)
			clear_seller_retry("market_commands")
			assert(retry_state()==state and seller.receipt(owner,"unknown-"+action+code).error=="unknown_command")
	assert(seller.cancel_offer(owner,"clear-budget",offer.offer_id,0).ok)
	for scenario: String in ["owner","revision","shop_capacity","inventory_capacity","configuration"]: await retry_reselection(items,scenario)
	print("POSTGRES_SHOP_SELLER_RETRY_OK full seller lifecycle, partial cells/provenance/revisions, account replay, bounded attempts, no COMMIT retry and current custody/capacity")

func retry_state() -> Array:
	var state: Array=[]
	for table: String in ["item_instances","item_custody","account_item_revisions","account_wallets","account_shops","shop_offers","shop_cells","market_commands"]:
		var result: Dictionary=pg.query("SELECT row_to_json(t)::text AS value FROM economy."+table+" t ORDER BY row_to_json(t)::text;",{},10000)
		assert(result.ok and not result.truncated)
		state.append(result.rows)
	return state

func seller_retry_fault(table: String, event: String, code: String, first: int, last: int, deferred: bool = false) -> void:
	assert(pg.execute("ALTER SEQUENCE economy.fixture_seller_attempt RESTART WITH 1;").ok)
	var create: String="CREATE CONSTRAINT TRIGGER fixture_retry AFTER INSERT ON economy.%s DEFERRABLE INITIALLY DEFERRED" % table if deferred else "CREATE TRIGGER fixture_retry BEFORE %s ON economy.%s" % [event,table]
	assert(pg.execute(create+" FOR EACH ROW EXECUTE FUNCTION economy.fixture_seller_retry('%s','%d','%d');" % [code,first,last]).ok)

func clear_seller_retry(table: String) -> void:
	assert(pg.execute("DROP TRIGGER fixture_retry ON economy."+table+";").ok)

func seller_attempts() -> int:
	return int(pg.query("SELECT last_value FROM economy.fixture_seller_attempt;").rows[0].last_value)

func retry_reselection(items: RefCounted, scenario: String) -> void:
	var index: int=["owner","revision","shop_capacity","inventory_capacity","configuration"].find(scenario)
	var owner: int=85910+index*2
	var alt: int=owner+1
	assert(items.bind_character(owner,8500) and items.bind_character(alt,8500))
	seed_item(items,true,owner,800000+index*2,0)
	var item_uid: String=uid(800000+index*2)
	var seller:=PgSeller.new(pg)
	var actor_action: String="configure" if scenario=="configuration" else ("list" if scenario in ["owner","shop_capacity"] else "cancel")
	var args: Array=[item_uid,0,0,100]
	var shop_revision: int=int(seller.mine(owner).revision)
	if actor_action=="configure": args=[shop_revision,"Old request","active"]
	var listed: Dictionary={}
	if actor_action=="cancel":
		listed=seller.list_item(owner,"race-source-"+scenario,item_uid,0,0,100)
		assert(listed.ok)
		args=[listed.offer_id,0]
	if scenario in ["shop_capacity","inventory_capacity"]: seed_item(items,true,alt,800001+index*2,20,ItemDefinitions.UPGRADE_ORE)
	assert(pg.execute("ALTER SEQUENCE economy.fixture_seller_attempt RESTART WITH 1;").ok)
	assert(pg.execute("CREATE TRIGGER fixture_retry BEFORE INSERT ON economy.market_commands FOR EACH ROW WHEN (current_setting('application_name')='retry-seller') EXECUTE FUNCTION economy.fixture_seller_retry('40001','1','1','gate');").ok)
	assert(pg.execute("SELECT pg_advisory_lock(95131);").ok)
	# Per-session synchronization slack only; normal fixture budgets are unchanged.
	var budgets: String=" options='-c statement_timeout=10000 -c lock_timeout=8000 -c idle_in_transaction_session_timeout=10000'"
	var ready:=Semaphore.new()
	var actor:=Thread.new()
	assert(actor.start(race_worker.bind(connection+" application_name=retry-seller"+budgets,owner if actor_action=="list" else alt,actor_action,args,"reselect-"+scenario,ready))==OK)
	ready.wait()
	var acting: bool=await seller_waiting("retry-seller")
	var edit_action: String
	var edit_args: Array
	var edit_character: int=owner
	var blocked: int=InventoryGrid.cells(0,ItemDefinitions.IRON_SWORD.inventory_height).back() if scenario=="inventory_capacity" else Grid.cells(0,ItemDefinitions.IRON_SWORD.inventory_height).back()
	match scenario:
		"configuration":
			edit_action="configure"
			edit_args=[shop_revision,"Editor shop","paused"]
		"owner":
			edit_action="storage"
			edit_args=[item_uid,0,"inventory","storage",0]
		"revision":
			edit_action="edit"
			edit_args=[listed.offer_id,0,0,101]
		"shop_capacity":
			edit_character=alt
			edit_action="list"
			edit_args=[uid(800001+index*2),0,blocked,100]
		_:
			edit_character=alt
			edit_action="inventory"
			edit_args=["move",uid(800001+index*2),0,blocked]
	var editor:=Thread.new()
	assert(editor.start(race_worker.bind(connection+" application_name=retry-seller-editor"+budgets,edit_character,edit_action,edit_args,"editor-"+scenario,ready))==OK)
	ready.wait()
	var editing: bool=await seller_waiting("retry-seller-editor")
	assert(pg.execute("SELECT pg_advisory_unlock(95131);").ok)
	var acted: Dictionary=actor.wait_to_finish()
	var edited: Dictionary=editor.wait_to_finish()
	clear_seller_retry("market_commands")
	assert(acting and editing and edited.result.ok and edited.committed)
	if scenario=="inventory_capacity":
		assert(acted.result.ok and acted.committed and acted.result.position!=0 and seller_attempts()==2)
		assert(not InventoryGrid.cells(int(acted.result.position),ItemDefinitions.IRON_SWORD.inventory_height).has(blocked))
		assert(items.inventory(alt).items.any(func(item: Dictionary) -> bool: return item.uid==item_uid and item.owner_character_id==alt and item.revision==2))
	else:
		assert(acted.result.error=={"owner":"owner","revision":"stale","shop_capacity":"occupied","configuration":"stale"}[scenario] and not acted.committed and seller_attempts()==1)
		assert(pg.query("SELECT command_id FROM economy.market_commands WHERE account_id=8500 AND command_id=:id;",{"id":"reselect-"+scenario}).rows.is_empty())
		if scenario=="owner": assert(PgStorage.new(pg).snapshot(alt).items.any(func(item: Dictionary) -> bool: return item.uid==item_uid and item.revision==1))
		elif scenario=="revision": assert(seller.mine(owner).offers[0].item.uid==item_uid and seller.mine(owner).offers[0].price==101 and items.inventory(alt).items.is_empty())
		else: assert(items.inventory(owner).items.any(func(item: Dictionary) -> bool: return item.uid==item_uid and item.revision==0))
		if scenario=="configuration": assert(seller.mine(owner).name=="Editor shop" and seller.mine(owner).status=="paused" and int(seller.mine(owner).revision)==shop_revision+1)
	# Clear the remaining offer for the next independent shared-Shop scenario.
	for offer: Dictionary in seller.mine(owner).offers: assert(seller.cancel_offer(owner,"clear-"+offer.offer_id,offer.offer_id,int(offer.revision)).ok)

func seller_waiting(label: String) -> bool:
	var deadline: int=Time.get_ticks_msec()+2000
	while Time.get_ticks_msec()<deadline:
		assert(pg.execute("SELECT pg_stat_clear_snapshot();").ok)
		if int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name=:label AND wait_event_type='Lock';",{"label":label}).rows[0].n)==1: return true
		await get_tree().create_timer(0.005).timeout
	return false
