extends Node
const Schema = preload("res://source/server/world/database/postgres/exchange_orders_schema_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const Storage = preload("res://source/server/world/database/postgres/account_storage_postgres.gd")
const Seller = preload("res://source/server/world/database/postgres/shop_seller_postgres.gd")
const Claims = preload("res://source/server/world/database/postgres/account_claim_postgres.gd")
const Ledger = preload("res://source/server/world/database/postgres/exchange_ledger_postgres.gd")
const Npc = preload("res://source/server/world/database/postgres/npc_shop_store_postgres.gd")
const StorageGrid = preload("res://source/common/gameplay/items/domain/storage_grid.gd")
var pg: Object
var connection: String

func sql(query: String, params: Dictionary = {}) -> void:
	var result: Dictionary=pg.execute(query,params)
	assert(result.ok,str(result))

func identity(account: int) -> void:
	assert(Wallet.new(pg).initialize_account(account).ok)
	for character: int in [account*10,account*10+1]: assert(Items.new(pg).bind_character(character,account))
	sql("UPDATE economy.account_wallets SET yang=1000 WHERE account_id=:account;",{"account":account})

func seed_item(character: int, definition: StringName, position: int, claim: bool = false) -> ItemInstance:
	var item:=ItemInstance.create(ItemDefinitions.get_definition(definition),character,[])
	assert(pg.begin())
	var result: Dictionary=Claims.new(pg).receive_in_transaction(item) if claim else Items.new(pg).receive_item_in_transaction(item,position)
	assert(result.ok and pg.commit())
	return item

func item(uid: String) -> Dictionary:
	var found: Dictionary=pg.query(Items.ITEM_SELECT+"WHERE i.uid=:uid;",{"uid":uid})
	assert(found.ok)
	return {} if found.rows.is_empty() else found.rows[0]

func invariants() -> void:
	var found: Dictionary=pg.query("SELECT COALESCE(i.uid,c.uid) AS uid,i.definition_id,i.owner_character_id,c.owner_id,c.location,c.position,c.storage_account_id FROM economy.item_instances i FULL JOIN economy.item_custody c ON c.uid=i.uid;",{},10000)
	assert(found.ok and not found.truncated)
	var occupied: Dictionary={}
	var ids: Dictionary={}
	for row: Dictionary in found.rows:
		assert(row.uid!=null and row.owner_id!=null and row.owner_character_id==row.owner_id and not ids.has(row.uid))
		ids[row.uid]=true
		var definition:=ItemDefinitions.get_definition(StringName(row.definition_id))
		assert(definition!=null)
		var cells: Array[int]=[]
		var scope: String=""
		match row.location:
			"bag":
				cells=InventoryGrid.cells(int(row.position),definition.inventory_height)
				scope="bag-"+str(row.owner_id)
			"account_storage":
				cells=StorageGrid.cells(int(row.position),definition.inventory_height)
				scope="storage-"+str(row.storage_account_id)
			_: continue
		assert(not cells.is_empty())
		for cell: int in cells:
			var key:=scope+":"+str(cell)
			assert(not occupied.has(key),"entire footprints must remain disjoint, not only starting cells")
			occupied[key]=row.uid

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	connection=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	await receipt_collision()
	await same_uid_custody()
	await receiving_capacity()
	await unreceipted_admission()
	invariants()
	pg.close()
	print("POSTGRES_INVENTORY_CONCURRENCY_OK cross-alt receipts, move/equip/list/deposit, full footprint and last-space receiving, starter/pickup and original outcome recovery")
	get_tree().quit()

func receipt_collision() -> void:
	identity(200)
	var a:=seed_item(2000,&"upgrade_ore",0)
	var b:=seed_item(2001,&"upgrade_ore",0)
	# First worker blocks after receipt lookup; the second either waits at
	# account admission or (pre-fix) races the account watermark/receipt PK.
	sql("CREATE FUNCTION economy.fixture_inventory_gate() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF current_setting('application_name') IN ('inventory-receipt','ground-race') THEN PERFORM pg_advisory_xact_lock(95123); END IF; RETURN NEW; END; $$;")
	sql("CREATE TRIGGER fixture_inventory_gate BEFORE UPDATE ON economy.item_instances FOR EACH ROW EXECUTE FUNCTION economy.fixture_inventory_gate();")
	var results:=await race([["move",2000,[a.uid,0,1,"same-id"]],["move",2001,[b.uid,0,1,"same-id"]]],200,"inventory-receipt",true)
	assert(int(results[0].ok)+int(results[1].ok)==1)
	var winner: int=0 if results[0].ok else 1
	assert(results[1-winner].error=="command_conflict","losing alt must discover the original account receipt, not fail at INSERT")
	var original: Dictionary=results[winner].duplicate(true)
	original.erase("committed")
	assert(int(item(a.uid).bag_position)+int(item(b.uid).bag_position)==1)
	sql("DROP TRIGGER fixture_inventory_gate ON economy.item_instances;")
	pg.close()
	assert(pg.open("postgresql",connection))
	var store:=Items.new(pg)
	var uid: String=a.uid if winner==0 else b.uid
	assert(store.inventory_receipt(2000+winner,"same-id")==original)
	assert(store.inventory_command(2000+winner,"move",uid,0,1,"same-id")==original and store.receipt_replay and not store.committed)
	invariants()

func same_uid_custody() -> void:
	identity(201)
	var sword:=seed_item(2010,&"iron_sword",0)
	var results:=await race([["equip",2010,[sword.uid,0,-1,"equip-list"]],["list",2010,[sword.uid,0,0,"list-equip"]]],201,"equip-list")
	assert(int(results[0].ok)+int(results[1].ok)==1)
	assert((results[0] if not results[0].ok else results[1]).error=="owner")
	assert(item(sword.uid).location==("equipment" if results[0].ok else "shop_escrow"))
	var material:=seed_item(2010,&"upgrade_ore",10)
	results=await race([["move",2010,[material.uid,0,20,"move-deposit"]],["storage",2010,[material.uid,0,"inventory","storage",0,"deposit-move"]]],201,"move-deposit")
	assert(int(results[0].ok)+int(results[1].ok)==1)
	assert((results[0] if not results[0].ok else results[1]).error in ["owner","stale"])
	assert(item(material.uid).location==("bag" if results[0].ok else "account_storage"))
	var converted:=seed_item(2010,&"forest_resin",30)
	results=await race([["move",2010,[converted.uid,0,40,"move-convert"]],["deposit",2010,[converted.uid,0,"convert-move"]]],201,"move-convert")
	assert(int(results[0].ok)+int(results[1].ok)==1)
	var ledger: Dictionary=Ledger.new(pg).ledger(2010)
	var free: int=int(ledger.assets.filter(func(row: Dictionary) -> bool: return row.asset_id=="forest_resin")[0].free)
	assert(free==int(results[1].ok) and item(converted.uid).is_empty()==results[1].ok)
	invariants()

func receiving_capacity() -> void:
	identity(202)
	var sword:=seed_item(2020,&"iron_sword",50)
	var stored:=seed_item(2021,&"upgrade_ore",0)
	assert(Storage.new(pg).transfer_command(2021,stored.uid,0,"inventory","storage",0,"prepare-storage").ok)
	# Starts 0 and 5 differ, but a two-high sword at 0 also occupies 5.
	var results:=await race([["move",2020,[sword.uid,0,0,"move-overlap"]],["storage",2020,[stored.uid,1,"storage","inventory",5,"receive-overlap"]]],202,"footprint-overlap")
	assert(int(results[0].ok)+int(results[1].ok)==1)
	assert((results[0] if not results[0].ok else results[1]).error=="occupied")
	invariants()
	identity(203)
	# Only one vertical two-cell space remains. Producers compete through the
	# existing receiving contract; no raw Storage/Claims custody shortcut.
	for cell: int in InventoryGrid.CAPACITY:
		if cell not in [0,5]: seed_item(2030,&"upgrade_ore",cell)
	var claim:=seed_item(2031,&"iron_sword",-1,true)
	results=await race([["claim",2030,[claim.uid,0,0,"last-space-claim"]],["npc",2030,"last-space-npc"]],203,"last-space")
	assert(int(results[0].ok)+int(results[1].ok)==1)
	var failure: Dictionary=results[0] if not results[0].ok else results[1]
	assert(failure.error in ["inventory_full","occupied"])
	assert(Wallet.new(pg).load_wallet(203).balance==1000-100*int(results[1].ok))
	assert(item(claim.uid).location==("bag" if results[0].ok else "account_claim"))
	var original: Dictionary=results[0].duplicate(true)
	original.erase("committed")
	assert(Claims.new(pg).claim_item(2030,"last-space-claim",claim.uid,0,0)==original,"accepted/rejected receipt survives changed receiving capacity")
	invariants()

func unreceipted_admission() -> void:
	identity(204)
	var results:=await race([["initialize",2040,null],["initialize",2040,null]],204,"starter-once")
	assert(results[0].ok and results[1].ok and int(results[0].committed)+int(results[1].committed)==1)
	assert(Items.new(pg).inventory(2040).items.size()==2)
	identity(205)
	var drop:=ItemInstance.create(ItemDefinitions.UPGRADE_ORE,2050,[])
	var row:=drop.to_snapshot()
	row.affixes_json=JSON.stringify(drop.affixes)
	row.sockets_json=JSON.stringify(drop.sockets)
	results=await race([["pickup",2050,row],["pickup",2050,row]],205,"pickup-once")
	assert(int(results[0].ok)+int(results[1].ok)==1)
	assert((results[0] if not results[0].ok else results[1]).error=="claimed")
	assert(Items.new(pg).inventory(2050).items.size()==1)
	assert(Items.new(pg).claim_ground_item(2050,drop.uid,drop).error=="claimed")
	# Different accounts do not share admission; the global drop UID constraint
	# still permits only one durable receiving item and marker.
	identity(206)
	identity(207)
	drop=ItemInstance.create(ItemDefinitions.UPGRADE_ORE,2060,[])
	row=drop.to_snapshot()
	row.affixes_json="[]"
	row.sockets_json="[]"
	var other:=row.duplicate(true)
	other.owner_character_id=2070
	sql("CREATE TRIGGER fixture_ground_gate BEFORE INSERT ON economy.ground_item_claims FOR EACH ROW EXECUTE FUNCTION economy.fixture_inventory_gate();")
	results=await race([["pickup",2060,row],["pickup",2070,other]],206,"ground-race",true)
	assert(int(results[0].ok)+int(results[1].ok)==1)
	assert((results[0] if not results[0].ok else results[1]).error in ["claimed","storage"])
	var holder: int=2060 if results[0].ok else 2070
	assert(int(item(drop.uid).owner_character_id)==holder)
	assert(Items.new(pg).inventory(2060).items.size()+Items.new(pg).inventory(2070).items.size()==1)
	assert(pg.query("SELECT owner_character_id FROM economy.ground_item_claims WHERE drop_uid=:uid;",{"uid":drop.uid}).rows==[{"owner_character_id":holder}])
	var loser: int=2070 if holder==2060 else 2060
	drop.owner_character_id=loser
	assert(Items.new(pg).claim_ground_item(loser,drop.uid,drop).error=="claimed")
	sql("DROP TRIGGER fixture_ground_gate ON economy.ground_item_claims;")
	invariants()

func race(specs: Array, account: int, label: String, advisory: bool = false) -> Array:
	if advisory: sql("SELECT pg_advisory_lock(95123);")
	else:
		assert(pg.begin())
		assert(pg.query("SELECT account_id FROM economy.accounts WHERE account_id=:account FOR NO KEY UPDATE;",{"account":account}).rows.size()==1)
	var ready:=Semaphore.new()
	var threads: Array[Thread]=[]
	for spec: Array in specs:
		var thread:=Thread.new()
		assert(thread.start(worker.bind(connection+" application_name="+label,spec,ready))==OK)
		threads.append(thread)
	for index: int in specs.size(): ready.wait()
	var waiting: int=0
	var deadline: int=Time.get_ticks_msec()+500
	while waiting<specs.size() and Time.get_ticks_msec()<deadline:
		sql("SELECT pg_stat_clear_snapshot();")
		waiting=int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name=:label AND wait_event_type='Lock';",{"label":label}).rows[0].n)
		if waiting<specs.size(): await get_tree().create_timer(0.005).timeout
	if advisory: sql("SELECT pg_advisory_unlock(95123);")
	else: assert(pg.commit())
	var results: Array=[]
	for thread: Thread in threads: results.append(thread.wait_to_finish())
	assert(waiting==specs.size(),"independent sessions must actually overlap")
	return results

func worker(dsn: String, spec: Array, ready: Semaphore) -> Dictionary:
	var database: Object=ClassDB.instantiate("GodotSociDatabase")
	var opened: bool=database.open("postgresql",dsn)
	ready.post()
	if not opened: return {"ok":false,"error":"fixture_connection"}
	var args: Variant=spec[2]
	var store: RefCounted
	var result: Dictionary
	match spec[0]:
		"move","equip":
			store=Items.new(database)
			result=store.inventory_command(spec[1],spec[0],args[0],args[1],args[2],args[3])
		"list":
			store=Seller.new(database)
			result=store.list_item(spec[1],args[3],args[0],args[1],args[2],100)
		"storage":
			store=Storage.new(database)
			result=store.transfer_command(spec[1],args[0],args[1],args[2],args[3],args[4],args[5])
		"deposit":
			store=Ledger.new(database)
			result=store.deposit(spec[1],args[2],args[0],args[1],1,"inventory")
		"claim":
			store=Claims.new(database)
			result=store.claim_item(spec[1],args[3],args[0],args[1],args[2])
		"npc":
			store=Npc.new(database)
			var shop:=ShopDefinition.new()
			shop.shop_id=&"custody_fixture"
			shop.display_name="Custody fixture"
			var offer:=ShopOfferDefinition.new()
			offer.offer_id=&"ore"
			offer.item_definition_id=&"upgrade_ore"
			offer.price=100
			shop.offers.append(offer)
			result=store.purchase(spec[1],0,shop,&"ore",-1,args)
		"initialize":
			store=Items.new(database)
			result=store.initialize_character(spec[1])
		"pickup":
			store=Items.new(database)
			var drop:=ItemInstance.from_row(args)
			result=store.claim_ground_item(spec[1],drop.uid,drop)
	result.committed=store.committed
	database.close()
	return result
