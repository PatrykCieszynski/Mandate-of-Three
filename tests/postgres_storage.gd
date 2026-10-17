extends Node
## Shared-account custody risks need native PG coverage; SQLite alone cannot
## demonstrate two-session withdrawal/capacity safety. No real data or UI needed.
const Schema = preload("res://source/server/world/database/postgres/storage_schema_postgres.gd")
const PgStorage = preload("res://source/server/world/database/postgres/account_storage_postgres.gd")
const PgItems = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const PgWallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const Grid = preload("res://source/common/gameplay/items/domain/storage_grid.gd")
var sqlite: SQLite
var pg: Object
var buyer: int
var alternate: int
var stranger: int
var connection: String

func sql(is_pg: bool, statement: String) -> bool:
	return pg.execute(statement).ok if is_pg else sqlite.query(statement)

func prepared(definition: ItemDefinition, character: int, identity: int) -> ItemInstance:
	var item:=ItemInstance.create(definition,character,[{"stat":"attack","value":7}])
	item.uid=str(identity).pad_zeros(32)
	item.upgrade_level=1
	return item

func capture(storage: RefCounted, items: RefCounted, is_pg: bool) -> Dictionary:
	var inventories: Array=[]
	var snapshots: Array=[]
	for character: int in [buyer,alternate,stranger]:
		var inventory: Dictionary=items.inventory(character)
		var stored: Dictionary=storage.snapshot(character)
		assert(inventory.ok and stored.ok)
		inventories.append(inventory)
		snapshots.append(stored)
	var count: int
	if is_pg:
		count=int(pg.query("SELECT COUNT(*) AS n FROM economy.market_commands;").rows[0].n)
	else:
		assert(sqlite.query("SELECT COUNT(*) AS n FROM market_commands;"))
		count=int(sqlite.query_result[0].n)
	return {"inventories":inventories,"storage":snapshots,"receipts":count}

func canonical(state: Dictionary) -> Dictionary:
	var result:=state.duplicate(true)
	for inventory: Dictionary in result.inventories: inventory.item_state.erase("authority_id")
	return result

func fault(is_pg: bool, table: String, event: String) -> void:
	if is_pg:
		assert(sql(is_pg,"CREATE OR REPLACE FUNCTION economy.fixture_storage_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage fixture fault'; END; $$;"))
		assert(sql(is_pg,"CREATE TRIGGER fixture_storage_fault BEFORE %s ON economy.%s FOR EACH ROW EXECUTE FUNCTION economy.fixture_storage_fault();" % [event,table]))
	else:
		assert(sql(is_pg,"CREATE TEMP TRIGGER fixture_storage_fault BEFORE %s ON %s BEGIN SELECT RAISE(ABORT,'storage fixture fault'); END;" % [event,table]))

func clear_fault(is_pg: bool, table: String) -> void:
	assert(sql(is_pg,"DROP TRIGGER fixture_storage_fault ON economy.%s;" % table if is_pg else "DROP TRIGGER fixture_storage_fault;"))

func fill_inventory(items: RefCounted, is_pg: bool, character: int) -> void:
	var occupied: Dictionary={}
	for item: Dictionary in items.inventory(character).items:
		if item.location=="bag":
			for cell: int in InventoryGrid.cells(item.bag_position,item.inventory_height): occupied[cell]=true
	assert(pg.begin() if is_pg else sqlite.query("BEGIN IMMEDIATE;"))
	for cell: int in InventoryGrid.CAPACITY:
		if not occupied.has(cell): assert(items.receive_item_in_transaction(prepared(ItemDefinitions.UPGRADE_ORE,character,1000+cell),cell).ok)
	assert(pg.commit() if is_pg else sqlite.query("COMMIT;"))

func exercise(storage: RefCounted, items: RefCounted, is_pg: bool) -> Array:
	var checkpoints: Array=[]
	assert(pg.begin() if is_pg else sqlite.query("BEGIN IMMEDIATE;"))
	for spec: Array in [[buyer,1,0],[buyer,2,1],[buyer,4,2],[buyer,5,3],[alternate,3,0]]:
		var definition: ItemDefinition=ItemDefinitions.IRON_SWORD if int(spec[1]) in [1,2,4] else ItemDefinitions.UPGRADE_ORE
		assert(items.receive_item_in_transaction(prepared(definition,int(spec[0]),int(spec[1])),int(spec[2])).ok)
	assert(pg.commit() if is_pg else sqlite.query("COMMIT;"))
	var uid: String=str(1).pad_zeros(32)
	var second: String=str(2).pad_zeros(32)
	var ore_uid: String=str(3).pad_zeros(32)
	var equipped: String=str(4).pad_zeros(32)
	var spare: String=str(5).pad_zeros(32)
	assert(items.inventory_command(buyer,"equip",equipped,0,-1,"equipped").ok)
	var before:=capture(storage,items,is_pg)
	assert(storage.snapshot(999999).error=="owner")
	assert(storage.transfer_command(buyer,equipped,1,"inventory","storage",-1,"equipped-deposit").error=="owner")
	assert(storage.transfer_command(alternate,uid,0,"inventory","storage",-1,"other-bag").error=="owner")
	assert(storage.transfer_command(buyer,uid,0,"inventory","inventory",-1,"bad-route").error=="request")
	assert(capture(storage,items,is_pg)==before)
	var deposited: Dictionary=storage.transfer_command(buyer,uid,0,"inventory","storage",0,"deposit")
	assert(deposited.ok and storage.committed and not storage.receipt_replay)
	assert(storage.snapshot(alternate).items[0].owner_character_id==buyer)
	assert(not items.inventory(buyer).items.any(func(i: Dictionary) -> bool: return i.uid==uid), "stored provenance must not leak into Inventory")
	assert(items.inventory_command(buyer,"equip",uid,1,-1,"stored-equip").error=="owner")
	assert(items.inventory_command(buyer,"activate",uid,1,-1,"stored-activate").error=="owner")
	assert(storage.transfer_command(stranger,uid,1,"storage","inventory",-1,"foreign").error=="owner")
	assert(storage.transfer_command(alternate,uid,0,"storage","storage",2,"stale").error=="stale")
	assert(storage.transfer_command(alternate,uid,1,"storage","storage",2,"move").ok)
	assert(storage.snapshot(buyer).items[0].owner_character_id==buyer, "moving by alt preserves provenance")
	var no_op: Dictionary=storage.transfer_command(alternate,uid,2,"storage","storage",2,"no-op")
	assert(no_op.ok and not storage.committed and not storage.receipt_replay)
	assert(storage.transfer_command(alternate,uid,2,"storage","storage",2,"no-op")==no_op and storage.receipt_replay and not storage.committed)
	assert(storage.transfer_receipt(alternate,"deposit").error=="unknown_command")
	assert(storage.transfer_receipt(stranger,"deposit").error=="unknown_command")
	assert(storage.transfer_receipt(buyer,"equipped").error=="unknown_command")
	assert(items.inventory_receipt(buyer,"deposit").error=="unknown_command")
	assert(storage.transfer_command(alternate,uid,0,"inventory","storage",0,"deposit").error=="command_conflict")
	assert(storage.transfer_command(buyer,uid,0,"inventory","storage",1,"deposit").error=="command_conflict")
	checkpoints.append(canonical(capture(storage,items,is_pg)))
	var withdrawn: Dictionary=storage.transfer_command(alternate,uid,2,"storage","inventory",1,"withdraw")
	assert(withdrawn.ok and items.inventory(alternate).items.any(func(i: Dictionary) -> bool: return i.uid==uid and i.owner_character_id==alternate and i.revision==3))
	assert(storage.snapshot(buyer).items.is_empty())
	assert(storage.transfer_command(buyer,uid,2,"storage","inventory",-1,"second-withdraw").error=="owner")
	before=capture(storage,items,is_pg)
	assert(storage.transfer_command(buyer,uid,0,"inventory","storage",0,"deposit")==deposited)
	assert(storage.transfer_receipt(buyer,"deposit")==deposited and capture(storage,items,is_pg)==before)
	# Lost-response recovery survives a new session and later account operations.
	if is_pg:
		pg.close()
		assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
		storage=PgStorage.new(pg)
	else:
		assert(sqlite.close_db() and sqlite.open_db())
		storage=AccountStorageSqlite.new(sqlite)
	assert(storage.transfer_command(alternate,uid,2,"storage","inventory",1,"withdraw")==withdrawn)
	assert(storage.transfer_receipt(alternate,"withdraw")==withdrawn)
	assert(storage.receipt_replay and not storage.committed and capture(storage,items,is_pg)==before)
	for table: String in ["item_instances","item_custody","market_commands"]:
		fault(is_pg,table,"UPDATE" if table=="item_instances" else "INSERT")
		assert(storage.transfer_command(buyer,second,0,"inventory","storage",0,"fault-deposit-"+table).error=="storage")
		assert(capture(storage,items,is_pg)==before, "custody/revision/receipt roll back after partial deposit")
		clear_fault(is_pg,table)
	assert(storage.transfer_command(alternate,uid,3,"inventory","storage",135,"redeposit").ok)
	before=capture(storage,items,is_pg)
	for table: String in ["item_instances","item_custody","market_commands"]:
		fault(is_pg,table,"UPDATE" if table=="item_instances" else "INSERT")
		assert(storage.transfer_command(buyer,uid,4,"storage","inventory",10,"fault-withdraw-"+table).error=="storage")
		assert(capture(storage,items,is_pg)==before, "receiving provenance is not reassigned on rollback")
		clear_fault(is_pg,table)
	assert(storage.transfer_command(buyer,second,0,"inventory","storage",-1,"second-deposit").ok)
	assert(storage.snapshot(buyer).items[0].uid==second and storage.snapshot(buyer).items[0].bag_position==0)
	assert(storage.transfer_command(alternate,second,1,"storage","storage",-1,"first-fit-noop").ok and not storage.committed)
	# Shared 15-column geometry must handle heights 1/2/3 and both page edges.
	var ore: ItemDefinition=ItemDefinitions.get_definition(&"upgrade_ore")
	var original_height: int=ore.inventory_height
	ore.inventory_height=3
	before=capture(storage,items,is_pg)
	assert(storage.transfer_command(alternate,ore_uid,0,"inventory","storage",120,"edge").error=="occupied")
	assert(capture(storage,items,is_pg)==before)
	assert(storage.transfer_command(alternate,ore_uid,0,"inventory","storage",3,"three").ok)
	assert(storage.transfer_command(alternate,ore_uid,1,"storage","storage",18,"three-move").ok, "self footprint is excluded")
	assert(storage.transfer_command(alternate,ore_uid,2,"storage","inventory",35,"bag-edge").error=="occupied")
	assert(storage.transfer_command(alternate,ore_uid,2,"storage","inventory",20,"three-withdraw").ok)
	ore.inventory_height=original_height
	checkpoints.append(canonical(capture(storage,items,is_pg)))
	fill_inventory(items,is_pg,alternate)
	before=capture(storage,items,is_pg)
	assert(storage.transfer_command(alternate,second,1,"storage","inventory",-1,"full-bag").error=="full")
	assert(capture(storage,items,is_pg)==before)
	# Fill Storage using real transfers; each is independently receipt-backed.
	var occupied: Dictionary={}
	for item: Dictionary in storage.snapshot(buyer).items:
		for cell: int in Grid.cells(item.bag_position,item.inventory_height): occupied[cell]=true
	for cell: int in Grid.CAPACITY:
		if occupied.has(cell): continue
		var filler:=prepared(ItemDefinitions.UPGRADE_ORE,buyer,2000+cell)
		assert(pg.begin() if is_pg else sqlite.query("BEGIN IMMEDIATE;"))
		assert(items.receive_item_in_transaction(filler,10).ok)
		assert(pg.commit() if is_pg else sqlite.query("COMMIT;"))
		assert(storage.transfer_command(buyer,filler.uid,0,"inventory","storage",cell,"fill-"+str(cell)).ok)
	before=capture(storage,items,is_pg)
	assert(storage.transfer_command(buyer,spare,0,"inventory","storage",-1,"full-store").error=="full")
	assert(storage.transfer_command(buyer,spare,0,"inventory","storage",0,"occupied-store").error=="occupied")
	assert(storage.transfer_command(buyer,uid,0,"inventory","storage",0,"deposit")==deposited)
	assert(storage.transfer_command(alternate,uid,2,"storage","inventory",1,"withdraw")==withdrawn)
	for index: int in 30:
		assert(storage.transfer_command(buyer,spare,0,"inventory","storage",0,"reject-"+str(index)).error=="occupied")
	assert(capture(storage,items,is_pg)==before, "full destinations/rejects/replay cannot change custody or add receipts")
	checkpoints.append(canonical(before))
	return checkpoints

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var directory:=OS.get_environment("MANDATE_PG_FIXTURE_DIR")
	assert(directory.begins_with("res://.godot/verification/postgres-readiness/run-") and not ".." in directory)
	sqlite=SQLite.new()
	sqlite.path=directory+"/storage.db"
	assert(not FileAccess.file_exists(sqlite.path) and sqlite.open_db())
	WorldSchema.ensure_schema(sqlite)
	var identities:=WorldStoreSqlite.new(sqlite)
	buyer=EconomyFixture.create_character(identities,"pg-storage-a",{"name":"A","skin":1})
	alternate=EconomyFixture.create_character(identities,"pg-storage-a",{"name":"Alt","skin":1})
	stranger=EconomyFixture.create_character(identities,"pg-storage-b",{"name":"B","skin":1})
	var runtime:=WorldDatabase.new()
	runtime.db=sqlite
	runtime.store=identities
	EconomyFixture.prepare(runtime)
	connection=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection))
	# Upgrade the populated P1d schema, not only a brand-new Storage schema.
	assert(preload("res://source/server/world/database/postgres/inventory_schema_postgres.gd").ensure_schema(pg))
	var items:=PgItems.new(pg)
	for character: int in [buyer,alternate,stranger]:
		var account:=identities.resolve_account_id(character)
		assert(PgWallet.new(pg).initialize_account(account).ok and items.bind_character(character,account))
	for pair: Array in [[ItemStoreSqlite.new(sqlite),false],[items,true]]:
		var is_pg: bool=pair[1]
		assert(pg.begin() if is_pg else sqlite.query("BEGIN IMMEDIATE;"))
		assert(pair[0].receive_item_in_transaction(prepared(ItemDefinitions.UPGRADE_ORE,stranger,99),0).ok)
		assert(pair[0].receive_item_in_transaction(prepared(ItemDefinitions.IRON_SWORD,stranger,98),1).ok)
		assert(pg.commit() if is_pg else sqlite.query("COMMIT;"))
		assert(pair[0].inventory_command(stranger,"equip",str(98).pad_zeros(32),0,-1,"prior-equip").ok)
	var prior_inventory:=items.inventory(stranger)
	assert(Schema.ensure_schema(pg) and Schema.ensure_schema(pg))
	assert(items.inventory(stranger)==prior_inventory, "schema extension preserves existing Inventory/equipment/revisions")
	var baseline:=exercise(AccountStorageSqlite.new(sqlite),ItemStoreSqlite.new(sqlite),false)
	var candidate:=exercise(PgStorage.new(pg),items,true)
	assert(baseline==candidate, "account snapshots, provenance, item/account revisions, stats and receipts match SQLite")
	await native_checks(items)
	pg.close()
	runtime.db=null
	runtime.free()
	sqlite.close_db()
	for suffix: String in ["","-wal","-shm"]: DirAccess.remove_absolute(ProjectSettings.globalize_path(sqlite.path+suffix))
	print("POSTGRES_STORAGE_OK SQLite parity: deposit/move/withdraw, provenance, receipts/reopen, full destinations, rollback and independent-session races")
	get_tree().quit()

func native_checks(items: RefCounted) -> void:
	var a: int=70001
	var b: int=70002
	var foreign: int=70003
	assert(PgWallet.new(pg).initialize_account(7000).ok and PgWallet.new(pg).initialize_account(7001).ok)
	assert(items.bind_character(a,7000) and items.bind_character(b,7000) and items.bind_character(foreign,7001))
	assert(pg.begin())
	for spec: Array in [[a,30001,0],[b,30002,0],[a,30003,1]]:
		assert(items.receive_item_in_transaction(prepared(ItemDefinitions.IRON_SWORD if int(spec[1])==30003 else ItemDefinitions.UPGRADE_ORE,int(spec[0]),int(spec[1])),int(spec[2])).ok)
	assert(pg.commit())
	var storage:=PgStorage.new(pg)
	var uid: String=str(30001).pad_zeros(32)
	assert(storage.transfer_command(a,uid,0,"inventory","storage",0,"native-deposit").ok)
	var before: Dictionary={"a":items.inventory(a),"b":items.inventory(b),"storage":storage.snapshot(a)}
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_storage_fault();").ok)
	var uncertain: Dictionary=storage.transfer_command(b,uid,1,"storage","inventory",1,"deferred-withdraw")
	assert(uncertain.get("outcome_unknown",false) and not pg.is_open() and not storage.committed)
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	assert(pg.execute("DROP TRIGGER fixture_commit ON economy.market_commands;").ok)
	assert({"a":items.inventory(a),"b":items.inventory(b),"storage":storage.snapshot(a)}==before)
	assert(storage.transfer_receipt(b,"deferred-withdraw").error=="unknown_command")
	assert(storage.transfer_command(b,uid,1,"storage","inventory",1,"deferred-withdraw").ok)
	assert(storage.transfer_command(b,uid,2,"inventory","storage",0,"native-back").ok)
	assert(pg.begin())
	assert(storage.transfer_command(a,uid,3,"storage","inventory",-1,"nested").error=="storage")
	assert(pg.in_transaction() and pg.rollback())
	var winners:=await race(a,b,uid,uid,3,3,"storage","inventory",-1,"withdraw-race")
	assert(int(winners[0].ok)+int(winners[1].ok)==1)
	assert(winners[0].get("error","")=="owner" or winners[1].get("error","")=="owner")
	assert(storage.snapshot(a).items.is_empty())
	var holders: int=0
	for character: int in [a,b]:
		for item: Dictionary in items.inventory(character).items:
			if item.uid==uid:
				holders+=1
				assert(item.owner_character_id==character and item.revision==4)
	assert(holders==1, "two sessions cannot withdraw the same UID twice")
	var winner: int=a if winners[0].ok else b
	var id: String="withdraw-race-0" if winners[0].ok else "withdraw-race-1"
	var original: Dictionary=winners[0] if winners[0].ok else winners[1]
	assert(storage.transfer_command(winner,uid,3,"storage","inventory",-1,id)==original and storage.receipt_replay)
	var sword: String=str(30003).pad_zeros(32)
	var material: String=str(30002).pad_zeros(32)
	winners=await race(a,b,sword,material,0,0,"inventory","storage",4,"capacity-race")
	assert(int(winners[0].ok)+int(winners[1].ok)==1)
	assert(winners[0].get("error","")=="occupied" or winners[1].get("error","")=="occupied")
	assert(storage.snapshot(a).items.size()==1 and storage.snapshot(b)==storage.snapshot(a))
	# Both commands retain the other alt as provenance. Shared admission and FK
	# checks must compose without deadlock or an ambiguous loser result.
	var remaining: String=material if winners[0].ok else sword
	var remaining_owner: int=b if winners[0].ok else a
	assert(storage.transfer_command(remaining_owner,remaining,0,"inventory","storage",20,"other-provenance").ok)
	winners=await race(a,b,material,sword,1,1,"storage","storage",40,"provenance-race")
	assert(int(winners[0].ok)+int(winners[1].ok)==1)
	assert(winners[0].get("error","")=="occupied" or winners[1].get("error","")=="occupied")
	assert(storage.snapshot(a).items.size()==2)
	var shared_item: Dictionary=storage.snapshot(a).items[0]
	winners=await race(a,b,shared_item.uid,shared_item.uid,shared_item.revision,shared_item.revision,"storage","storage",60,"shared-id-race",true)
	assert(int(winners[0].ok)+int(winners[1].ok)==1)
	assert(winners[0].get("error","")=="command_conflict" or winners[1].get("error","")=="command_conflict", "same account ID is resolved after shared admission, before mutation")
	var stored_uid: String=storage.snapshot(a).items[0].uid
	var stored_revision: int=storage.snapshot(a).items[0].revision
	assert(storage.transfer_command(foreign,stored_uid,1,"storage","inventory",-1,"foreign-native").error=="owner")
	# DB constraints reject direct cross-account custody, orphan destinations and
	# duplicate starts as well as service-level checks. Failures leave all state.
	before={"a":items.inventory(a),"b":items.inventory(b),"storage":storage.snapshot(a)}
	assert(pg.begin())
	assert(pg.execute("UPDATE economy.item_custody SET storage_account_id=7001 WHERE uid=:uid;",{"uid":stored_uid}).ok)
	assert(not pg.commit() and pg.rollback(), "Storage account must match item provenance account")
	assert(pg.begin())
	assert(not pg.execute("UPDATE economy.item_custody SET storage_account_id=NULL WHERE uid=:uid;",{"uid":stored_uid}).ok and pg.rollback())
	assert(pg.begin())
	assert(not pg.execute("UPDATE economy.item_custody SET location='shop_escrow' WHERE uid=:uid;",{"uid":stored_uid}).ok and pg.rollback())
	assert({"a":items.inventory(a),"b":items.inventory(b),"storage":storage.snapshot(a)}==before)
	# BIGINT issuer column prevents JSON-double retargeting during discovery.
	var large: int=9007199254741133
	assert(items.bind_character(large,7000))
	var recovered: Dictionary=storage.transfer_command(large,stored_uid,stored_revision,"storage","inventory",-1,"large-issuer")
	assert(recovered.ok and storage.transfer_receipt(large,"large-issuer")==recovered)
	assert(storage.transfer_receipt(a,"large-issuer").error=="unknown_command")
	assert(pg.execute("UPDATE economy.schema_versions SET version=999 WHERE feature='storage';").ok)
	assert(not Schema.ensure_schema(pg) and not pg.in_transaction())
	assert(pg.execute("UPDATE economy.schema_versions SET version=1 WHERE feature='storage';").ok and Schema.ensure_schema(pg))
	print("POSTGRES_STORAGE_NATIVE_OK two independent sessions: single UID winner, shared cell winner, COMMIT unknown, custody constraints and exact issuer")

func race(a: int, b: int, first: String, second: String, first_revision: int, second_revision: int, source: String, destination: String, position: int, label: String, same_id: bool = false) -> Array:
	# Hold a real database barrier until BOTH independent sessions are waiting.
	# There is no frame-duration or scheduling-order success assertion.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=7000 FOR UPDATE;").ok)
	var ready:=Semaphore.new()
	var workers: Array[Thread]=[]
	for index: int in 2:
		var worker:=Thread.new()
		assert(worker.start(race_worker.bind(connection+" application_name="+label,a if index==0 else b,first if index==0 else second,first_revision if index==0 else second_revision,source,destination,position,label if same_id else label+"-"+str(index),ready))==OK)
		workers.append(worker)
	for index: int in 2: ready.wait()
	var waiting: int=0
	var deadline: int=Time.get_ticks_msec()+500
	while waiting<2 and Time.get_ticks_msec()<deadline:
		assert(pg.execute("SELECT pg_stat_clear_snapshot();").ok)
		var activity: Dictionary=pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name=:label AND wait_event_type='Lock';",{"label":label})
		assert(activity.ok)
		waiting=int(activity.rows[0].n)
		if waiting<2: await get_tree().create_timer(0.005).timeout
	assert(pg.commit())
	var results: Array=[]
	for worker: Thread in workers: results.append(worker.wait_to_finish())
	assert(waiting==2, "fixture must actually overlap two native transactions")
	return results

func race_worker(dsn: String, character: int, uid: String, revision: int, source: String, destination: String, position: int, id: String, ready: Semaphore) -> Dictionary:
	# Native session is created, used and destroyed on this worker only.
	var database: Object=ClassDB.instantiate("GodotSociDatabase")
	var opened: bool=database.open("postgresql",dsn)
	ready.post()
	if not opened: return {"ok":false,"error":"fixture_connection"}
	var result: Dictionary=PgStorage.new(database).transfer_command(character,uid,revision,source,destination,position,id)
	database.close()
	return result
