extends Node
## SQLite behavioral parity plus real independent-session settlement conflicts.
const Schema = preload("res://source/server/world/database/postgres/shop_settlement_schema_postgres.gd")
const SellerSchema = preload("res://source/server/world/database/postgres/shop_schema_postgres.gd")
const Settlement = preload("res://source/server/world/database/postgres/shop_settlement_postgres.gd")
const Seller = preload("res://source/server/world/database/postgres/shop_seller_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
var pg: Object
var sqlite: SqliteSoci
var connection: String
var seller: int
var alt: int
var buyer: int
var rival: int
var accounts: Dictionary={}

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
	assert(pg.begin() if native else sqlite.query("BEGIN IMMEDIATE;"))
	assert(items.receive_item_in_transaction(item,position).ok)
	assert(pg.commit() if native else sqlite.query("COMMIT;"))

func state(market: RefCounted, items: RefCounted, native: bool) -> Dictionary:
	var prefix: String="economy." if native else ""
	var inventories: Array=[]
	for character: int in [seller,alt,buyer,rival]:
		var inventory: Dictionary=items.inventory(character)
		inventory.item_state.erase("authority_id")
		inventories.append(inventory)
	var funds: Array=[]
	for character: int in [seller,buyer,rival]:
		var account: int=accounts[character]
		funds.append([rows(native,"SELECT yang,reserved_yang,wallet_revision FROM "+prefix+"account_wallets WHERE account_id="+str(account)+";")[0],market.revenue(account)])
	return {"inventories":inventories,"funds":funds,"offers":int(rows(native,"SELECT COUNT(*) AS n FROM "+prefix+"shop_offers;")[0].n),"cells":int(rows(native,"SELECT COUNT(*) AS n FROM "+prefix+"shop_cells;")[0].n),"receipts":int(rows(native,"SELECT COUNT(*) AS n FROM "+prefix+"market_commands;")[0].n)}

func normalize(result: Dictionary) -> Dictionary:
	var copy:=result.duplicate(true)
	if copy.has("item_state"): copy.item_state.erase("authority_id")
	for wallet: Dictionary in copy.get("wallet_states",[]): wallet.erase("authority_id")
	for key: String in ["buyer_account","seller_account","buyer_balance","shop_id","claimed"]:
		if copy.has(key): copy[key]=int(copy[key])
	return copy

func fault(native: bool, table: String, event: String) -> void:
	if native:
		execute(true,"CREATE OR REPLACE FUNCTION economy.fixture_settlement_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'settlement fixture fault'; END; $$;")
		execute(true,"CREATE TRIGGER fixture_settlement_fault BEFORE %s ON economy.%s FOR EACH ROW EXECUTE FUNCTION economy.fixture_settlement_fault();" % [event,table])
	else: execute(false,"CREATE TEMP TRIGGER fixture_settlement_fault BEFORE %s ON %s BEGIN SELECT RAISE(ABORT,'settlement fault'); END;" % [event,table])

func clear_fault(native: bool, table: String) -> void:
	execute(native,"DROP TRIGGER fixture_settlement_fault ON economy.%s;" % table if native else "DROP TRIGGER fixture_settlement_fault;")

func exercise(market: RefCounted, selling: RefCounted, items: RefCounted, native: bool) -> Array:
	var checkpoints: Array=[]
	var prefix: String="economy." if native else ""
	seed_item(items,native,seller,1,0)
	var listing: Dictionary=selling.list_item(seller,"list-sale",uid(1),0,0,1600)
	assert(listing.ok)
	var shop: int=listing.shop_id
	var offer: String=listing.offer_id
	var before:=state(market,items,native)
	assert(market.purchase(alt,"self",shop,offer,0,1600,{}).error=="self_trade")
	assert(selling.configure(seller,"paused",0,"Shop","paused").ok)
	assert(market.purchase(buyer,"paused",shop,offer,0,1600,{}).error=="paused")
	assert(selling.configure(seller,"resume",1,"Shop","active").ok)
	assert(market.purchase(buyer,"stale-price",shop,offer,0,1601,{}).error=="stale")
	assert(market.purchase(buyer,"stale-revision",shop,offer,1,1600,{}).error=="stale")
	assert(market.purchase(buyer,"funds",shop,offer,0,1600,{}).error=="funds")
	assert(selling.edit_offer(seller,"negotiable",offer,0,0,0).ok)
	assert(market.purchase(buyer,"offer-only",shop,offer,1,1,{}).error=="offer_only")
	assert(selling.edit_offer(seller,"fixed",offer,1,0,1600).ok)
	# Full Inventory rejects before spend; no account Storage/claim fallback.
	for position: int in 180: seed_item(items,native,rival,1000+position,position,ItemDefinitions.UPGRADE_ORE)
	assert(market.purchase(rival,"full",shop,offer,2,1600,{accounts[rival]:200}).error=="inventory_full")
	execute(native,"UPDATE "+prefix+"account_wallets SET reserved_yang=100 WHERE account_id="+str(accounts[buyer])+";")
	assert(market.purchase(buyer,"reserved",shop,offer,2,1600,{accounts[buyer]:100}).error=="funds")
	execute(native,"UPDATE "+prefix+"account_wallets SET reserved_yang=0 WHERE account_id="+str(accounts[buyer])+";")
	before=state(market,items,native)
	for stage: Array in [["account_wallets","UPDATE"],["account_shop_revenue","INSERT"],["shop_cells","DELETE"],["item_instances","UPDATE"],["item_custody","UPDATE"],["shop_offers","DELETE"],["market_commands","INSERT"]]:
		fault(native,stage[0],stage[1])
		assert(market.purchase(buyer,"sale",shop,offer,2,1600,{accounts[buyer]:200}).error=="storage")
		assert(state(market,items,native)==before,"purchase stage rolls back funds, revenue, UID, cells and receipt")
		clear_fault(native,stage[0])
	var bought: Dictionary=market.purchase(buyer,"sale",shop,offer,2,1600,{accounts[buyer]:200,accounts[seller]:999})
	assert(bought.ok and market.committed and bought.buyer_balance==100 and bought.seller_claimable_yang=="1600")
	assert(items.inventory(buyer).items.any(func(i: Dictionary) -> bool: return i.uid==uid(1) and i.owner_character_id==buyer and i.revision==2))
	before=state(market,items,native)
	assert(normalize(market.purchase(buyer,"sale",shop,offer,2,1600,{accounts[buyer]:999}))==normalize(bought) and not market.committed)
	assert(market.purchase(buyer,"sale",shop,offer,2,1601,{}).error=="command_conflict")
	assert(market.purchase(rival,"lost-race",shop,offer,2,1600,{}).error=="unavailable")
	assert(market.purchase(alt,"sale",shop,offer,2,1600,{}).error=="unavailable")
	assert(normalize(market.receipt(buyer,"sale"))==normalize(bought))
	assert(state(market,items,native)==before)
	checkpoints.append(before)
	# Reopen discards negative cache but retains the original sold-offer receipt.
	if native:
		pg.close()
		assert(pg.open("postgresql",connection))
	else:
		sqlite.close_db()
		assert(sqlite.open_db())
	assert(normalize(market.receipt(buyer,"sale"))==normalize(bought))
	assert(normalize(market.purchase(buyer,"sale",shop,offer,2,1600,{}))==normalize(bought))
	# Partial collect: pending income counts toward the cap, reservation survives.
	execute(native,"UPDATE "+prefix+"account_wallets SET yang=8999999999999900,reserved_yang=100 WHERE account_id="+str(accounts[seller])+";")
	before=state(market,items,native)
	for stage: Array in [["account_wallets","UPDATE"],["account_shop_revenue","UPDATE"],["market_commands","INSERT"]]:
		fault(native,stage[0],stage[1])
		assert(market.claim_revenue(alt,"collect",30).error=="storage")
		assert(state(market,items,native)==before)
		clear_fault(native,stage[0])
	var collected: Dictionary=market.claim_revenue(alt,"collect",30)
	assert(collected.ok and collected.claimed==70 and collected.claimable_yang=="1530")
	assert(collected.wallet_states[0].balance==Wallet.MAX_YANG and collected.wallet_states[0].pending_applied==30 and collected.wallet_states[0].reserved_yang==100)
	before=state(market,items,native)
	assert(normalize(market.claim_revenue(alt,"collect",0))==normalize(collected) and not market.committed)
	assert(market.claim_revenue(seller,"collect",0).error=="command_conflict")
	assert(market.claim_revenue(seller,"full-wallet",0).error=="wallet_full")
	assert(market.claim_revenue(seller,"bad-pending",1).error=="storage")
	assert(state(market,items,native)==before)
	checkpoints.append(before)
	execute(native,"UPDATE "+prefix+"account_wallets SET yang=100 WHERE account_id="+str(accounts[seller])+";")
	assert(market.claim_revenue(seller,"rest",0).claimed==1530)
	assert(market.claim_revenue(seller,"empty",0).error=="nothing_to_claim")
	# Revenue overflow must also undo the buyer's pending income and spend.
	seed_item(items,native,seller,2,0)
	listing=selling.list_item(seller,"overflow-list",uid(2),0,0,100)
	assert(listing.ok)
	execute(native,"UPDATE "+prefix+"account_shop_revenue SET yang=9223372036854775800 WHERE account_id="+str(accounts[seller])+";")
	before=state(market,items,native)
	assert(market.purchase(buyer,"overflow",shop,listing.offer_id,0,100,{accounts[buyer]:50}).error=="revenue_capacity")
	assert(state(market,items,native)==before)
	checkpoints.append(before)
	return checkpoints

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var directory:=OS.get_environment("MANDATE_PG_FIXTURE_DIR")
	assert(directory.begins_with("res://.godot/verification/postgres-readiness/run-") and not ".." in directory)
	sqlite=SqliteSoci.new()
	sqlite.path=directory+"/shop-settlement.db"
	assert(not FileAccess.file_exists(sqlite.path) and sqlite.open_db())
	WorldSchema.ensure_schema(sqlite)
	var identities:=WorldStoreSqlite.new(sqlite)
	seller=EconomyFixture.create_character(identities,"seller",{"name":"Seller","skin":1})
	alt=EconomyFixture.create_character(identities,"seller",{"name":"Alt","skin":1})
	buyer=EconomyFixture.create_character(identities,"buyer",{"name":"Buyer","skin":1})
	rival=EconomyFixture.create_character(identities,"rival",{"name":"Rival","skin":1})
	var runtime:=WorldDatabase.new()
	runtime.db=sqlite
	runtime.store=identities
	EconomyFixture.prepare(runtime)
	connection=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and SellerSchema.ensure_schema(pg))
	var items:=Items.new(pg)
	for character: int in [seller,alt,buyer,rival]:
		accounts[character]=identities.resolve_account_id(character)
		assert(Wallet.new(pg).initialize_account(accounts[character]).ok and items.bind_character(character,accounts[character]))
	# Upgrade populated seller custody; no backfill from preexisting receipts.
	seed_item(items,true,seller,99,10)
	var prior: Dictionary=Seller.new(pg).list_item(seller,"prior",uid(99),0,10,100)
	assert(prior.ok and Schema.ensure_schema(pg) and Schema.ensure_schema(pg))
	assert(Settlement.new(pg).revenue(accounts[seller]).amount==0)
	assert(Seller.new(pg).cancel_offer(seller,"prior-cancel",prior.offer_id,0).ok)
	assert(items.inventory_command(seller,"move",uid(99),2,10,"prior-move").ok)
	# Match the populated-upgrade mutations in the SQLite baseline.
	var si:=ItemStoreSqlite.new(sqlite)
	seed_item(si,false,seller,99,10)
	var sm:=MarketStoreSqlite.new(sqlite)
	prior=sm.list_item(seller,"prior",uid(99),0,10,100)
	assert(sm.cancel_offer(seller,"prior-cancel",prior.offer_id,0).ok)
	assert(si.inventory_command(seller,"move",uid(99),2,10,"prior-move").ok)
	var baseline:=exercise(sm,sm,si,false)
	var candidate:=exercise(Settlement.new(pg),Seller.new(pg),items,true)
	assert(baseline==candidate,"Inventory, wallets/reservations/revisions, revenue, cells and receipts match SQLite")
	await native_checks(items)
	pg.close()
	runtime.db=null
	runtime.free()
	sqlite.close_db()
	print("POSTGRES_SHOP_SETTLEMENT_OK purchase/partial collect SQLite parity, rollback, replay/reopen, int64 and native conflicts")
	get_tree().quit()

func native_checks(items: RefCounted) -> void:
	for id: int in [7000,7001,7002]:
		assert(Wallet.new(pg).initialize_account(id).ok and items.bind_character(id*10,id))
	var selling:=Seller.new(pg)
	var market:=Settlement.new(pg)
	seed_item(items,true,70000,9001,0)
	seed_item(items,true,70000,9002,1)
	var a: Dictionary=selling.list_item(70000,"native-a",uid(9001),0,0,100)
	var b: Dictionary=selling.list_item(70000,"native-b",uid(9002),0,1,200)
	assert(a.ok and b.ok)
	var results:=await race([[70010,"buy",[a.shop_id,a.offer_id,0,100,{}]],[70020,"buy",[a.shop_id,a.offer_id,0,100,{}]]],"double-buy")
	assert(int(results[0].result.ok)+int(results[1].result.ok)==1)
	assert(results[0].result.get("error","")=="unavailable" or results[1].result.get("error","")=="unavailable")
	assert(market.revenue(7000).amount==100)
	results=await race([[70010,"buy",[b.shop_id,b.offer_id,0,200,{}]],[70000,"cancel",[b.offer_id,0]]],"buy-cancel")
	assert(int(results[0].result.ok)+int(results[1].result.ok)==1)
	# Two different sales must add, not overwrite, offline seller proceeds.
	seed_item(items,true,70000,9003,2)
	seed_item(items,true,70000,9004,3)
	a=selling.list_item(70000,"native-c",uid(9003),0,2,110)
	b=selling.list_item(70000,"native-d",uid(9004),0,3,120)
	var revenue_before: int=market.revenue(7000).amount
	results=await race([[70010,"buy",[a.shop_id,a.offer_id,0,110,{}]],[70020,"buy",[b.shop_id,b.offer_id,0,120,{}]]],"two-sales")
	assert(results[0].result.ok and results[1].result.ok and market.revenue(7000).amount==revenue_before+230)
	results=await race([[70000,"collect",[0]],[70000,"collect",[0]]],"same-collect",true)
	assert(results[0].result.ok and results[0].result==results[1].result and int(results[0].committed)+int(results[1].committed)==1)
	# Reciprocal buys exercise deterministic ordering, not merely one seller.
	seed_item(items,true,70010,9005,30)
	seed_item(items,true,70000,9006,30)
	a=selling.list_item(70010,"reciprocal-a",uid(9005),0,0,50)
	b=selling.list_item(70000,"reciprocal-b",uid(9006),0,0,50)
	results=await race([[70000,"buy",[a.shop_id,a.offer_id,0,50,{}]],[70010,"buy",[b.shop_id,b.offer_id,0,50,{}]]],"reciprocal")
	assert(results[0].result.ok and results[1].result.ok,"reciprocal account locks cannot deadlock")
	# Duplicate purchase must replay after the first deletes the offer, including
	# exactly one pending-income application. Both workers use the same issuer.
	seed_item(items,true,70000,9008,32)
	a=selling.list_item(70000,"retry-offer",uid(9008),0,0,100)
	var wallet_before: int=Wallet.new(pg).load_wallet(7001).balance
	results=await race([[70010,"buy",[a.shop_id,a.offer_id,0,100,{7001:30}]],[70010,"buy",[a.shop_id,a.offer_id,0,100,{7001:30}]]],"same-buy",true)
	assert(results[0].result.ok and results[0].result==results[1].result and int(results[0].committed)+int(results[1].committed)==1)
	assert(Wallet.new(pg).load_wallet(7001).balance==wallet_before+30-100)
	seed_item(items,true,70000,9009,33)
	a=selling.list_item(70000,"edit-offer",uid(9009),0,0,100)
	results=await race([[70010,"buy",[a.shop_id,a.offer_id,0,100,{}]],[70000,"edit",[a.offer_id,0,0,200]]],"buy-edit")
	assert(int(results[0].result.ok)+int(results[1].result.ok)==1)
	assert(results[0].result.get("error","")=="stale" or results[1].result.get("error","")=="unavailable")
	# Two alts cannot overspend one account wallet through different offers.
	assert(items.bind_character(70011,7001))
	seed_item(items,true,70000,9011,50)
	seed_item(items,true,70000,9012,51)
	a=selling.list_item(70000,"funds-a",uid(9011),0,20,100)
	b=selling.list_item(70000,"funds-b",uid(9012),0,21,100)
	assert(a.ok and b.ok)
	execute(true,"UPDATE economy.account_wallets SET yang=150 WHERE account_id=7001;")
	results=await race([[70010,"buy",[a.shop_id,a.offer_id,0,100,{}]],[70011,"buy",[b.shop_id,b.offer_id,0,100,{}]]],"shared-funds")
	assert(int(results[0].result.ok)+int(results[1].result.ok)==1 and Wallet.new(pg).load_wallet(7001).balance==50)
	assert(results[0].result.get("error","")=="funds" or results[1].result.get("error","")=="funds")
	execute(true,"UPDATE economy.account_wallets SET yang=1000 WHERE account_id=7001;")
	# A deliberately failed deferred COMMIT is unknown; discovery then same-ID retry.
	seed_item(items,true,70000,9007,31)
	a=selling.list_item(70000,"commit-offer",uid(9007),0,30,100)
	assert(a.ok)
	for action: String in ["buy","collect"]:
		var before: Array=rows(true,"SELECT account_id,yang FROM economy.account_wallets ORDER BY account_id;")
		var custody_before:=native_custody()
		var proceeds: int=market.revenue(7000).amount
		execute(true,"CREATE CONSTRAINT TRIGGER fixture_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_settlement_fault();")
		var result: Dictionary=market.purchase(70010,"commit-buy",a.shop_id,a.offer_id,0,100,{7001:30}) if action=="buy" else market.claim_revenue(70000,"commit-collect",30)
		assert(result.get("outcome_unknown",false) and not pg.is_open() and not market.committed)
		assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
		execute(true,"DROP TRIGGER fixture_commit ON economy.market_commands;")
		assert(rows(true,"SELECT account_id,yang FROM economy.account_wallets ORDER BY account_id;")==before and market.revenue(7000).amount==proceeds)
		assert(native_custody()==custody_before,"deferred failure restores item, provenance, cells, offer and durable receipts")
		assert(market.receipt(70010 if action=="buy" else 70000,"commit-"+action).error=="unknown_command")
		if action=="buy": assert(market.purchase(70010,"commit-buy",a.shop_id,a.offer_id,0,100,{7001:30}).ok)
		else: assert(market.claim_revenue(70000,"commit-collect",30).ok)
	# Exact BIGINT receipt scalars (including IDs) survive reopen/discovery.
	var large: int=9007199254741033
	execute(true,"UPDATE economy.account_shop_revenue SET yang="+str(large)+" WHERE account_id=7000;")
	var huge: Dictionary=market.claim_revenue(70000,"huge-collect",0)
	assert(huge.ok and int(huge.claimable_yang)==large-huge.claimed and market.receipt(70000,"huge-collect")==huge)
	# Buyer/seller/Shop identities exceed JSON's exact floating-point range too.
	assert(Wallet.new(pg).initialize_account(large).ok and items.bind_character(large+1,large))
	seed_item(items,true,large+1,9010,0)
	assert(selling.mine(large+1).ok)
	execute(true,"UPDATE economy.account_shops SET shop_id="+str(large+2)+" WHERE account_id="+str(large)+";")
	a=selling.list_item(large+1,"large-list",uid(9010),0,0,1)
	assert(a.ok)
	var large_buy: Dictionary=market.purchase(70010,"large-buy",large+2,a.offer_id,0,1,{})
	assert(large_buy.ok and large_buy.seller_account==large and large_buy.shop_id==large+2)
	pg.close()
	assert(pg.open("postgresql",connection))
	assert(market.receipt(70010,"large-buy")==large_buy and market.purchase(70010,"large-buy",large+2,a.offer_id,0,1,{})==large_buy)
	execute(true,"UPDATE economy.schema_versions SET version=999 WHERE feature='shop_settlement';")
	assert(not Schema.ensure_schema(pg) and not pg.in_transaction())
	execute(true,"UPDATE economy.schema_versions SET version=1 WHERE feature='shop_settlement';")
	assert(Schema.ensure_schema(pg))
	await retry_checks()
	print("POSTGRES_SHOP_SETTLEMENT_NATIVE_OK double-buy, cancel conflict, additive sales, shared receipt, reciprocal locks and COMMIT recovery")

func retry_checks() -> void:
	assert(pg.has_method("get_last_error_details"),"Installed release must expose structured native failures")
	for account: int in [8000,8001]:
		assert(Wallet.new(pg).initialize_account(account).ok and Items.new(pg).bind_character(account*10,account))
		execute(true,"UPDATE economy.account_wallets SET yang=1000 WHERE account_id="+str(account)+";")
	execute(true,"CREATE SEQUENCE economy.fixture_retry_attempt;")
	execute(true,"CREATE FUNCTION economy.fixture_retry_fault() RETURNS trigger LANGUAGE plpgsql AS $$ DECLARE attempt BIGINT; BEGIN attempt:=nextval('economy.fixture_retry_attempt'); IF attempt<=TG_ARGV[1]::BIGINT THEN IF TG_NARGS>2 THEN PERFORM pg_advisory_xact_lock(95124); END IF; RAISE EXCEPTION 'fixture 40001 text is not a classification' USING ERRCODE=TG_ARGV[0]; END IF; RETURN NEW; END; $$;")
	var market:=Settlement.new(pg)
	var selling:=Seller.new(pg)
	var index: int=0
	for code: String in ["40001","40P01"]:
		for stage: String in ["item_custody","market_commands"]:
			var listed:=retry_listing(index)
			var before:=retry_state()
			retry_fault(stage,code,1)
			var result: Dictionary=market.purchase(80010,"retry-buy-"+str(index),listed.shop_id,listed.offer_id,0,100,{8001:17})
			assert(result.ok and market.committed and retry_attempts()==2)
			assert(Wallet.new(pg).load_wallet(8001).balance==int(before["wallets"][1].yang)-83)
			assert(int(market.revenue(8000).amount)==int(before.revenue)+100)
			assert(int(rows(true,"SELECT owner_character_id FROM economy.item_instances WHERE uid='"+listed.uid+"';")[0].owner_character_id)==80010)
			assert(market.receipt(80010,"retry-buy-"+str(index))==result)
			assert(market.purchase(80010,"retry-buy-"+str(index),listed.shop_id,listed.offer_id,0,100,{8001:999})==result and not market.committed and retry_attempts()==2)
			clear_retry_fault(stage)
			index+=1
	# Exhaustion, constraints, lock timeout, cancellation and generic failures do
	# not become durable/cached business rejection or leak pending income.
	for code: String in ["40001","40P01","23505","55P03","57014","P0001"]:
		var listed:=retry_listing(index)
		var before:=retry_state()
		retry_fault("item_custody",code,100)
		assert(market.purchase(80010,"retry-budget-"+str(index),listed.shop_id,listed.offer_id,0,100,{8001:17}).error=="storage")
		assert(retry_attempts()==(3 if code in ["40001","40P01"] else 1))
		assert(retry_state()==before and market.receipt(80010,"retry-budget-"+str(index)).error=="unknown_command")
		clear_retry_fault("item_custody")
		assert(selling.cancel_offer(80000,"clear-budget-"+str(index),listed.offer_id,0).ok)
		index+=1
	for code: String in ["40001","40P01"]:
		# Same code at COMMIT is not the statement-rollback retry path.
		var listed:=retry_listing(index)
		var before:=retry_state()
		retry_fault("market_commands",code,100,true)
		var result: Dictionary=market.purchase(80010,"retry-commit-"+str(index),listed.shop_id,listed.offer_id,0,100,{8001:17})
		assert(result.get("outcome_unknown",false) and not pg.is_open() and not market.committed)
		assert(pg.open("postgresql",connection) and retry_attempts()==1)
		clear_retry_fault("market_commands")
		assert(retry_state()==before and market.receipt(80010,"retry-commit-"+str(index)).error=="unknown_command")
		assert(selling.cancel_offer(80000,"clear-commit-"+str(index),listed.offer_id,0).ok)
		index+=1
	await retry_reselection(index)
	# Collection retries its entire headroom/income/revenue operation too.
	for code: String in ["40001","40P01"]:
		execute(true,"UPDATE economy.account_shop_revenue SET yang=100 WHERE account_id=8000;")
		var before: int=Wallet.new(pg).load_wallet(8000).balance
		retry_fault("account_shop_revenue",code,1)
		var result: Dictionary=market.claim_revenue(80000,"retry-collect-"+code,23)
		assert(result.ok and result.claimed==100 and market.committed and retry_attempts()==2)
		assert(Wallet.new(pg).load_wallet(8000).balance==before+123 and market.revenue(8000).amount==0)
		assert(market.claim_revenue(80000,"retry-collect-"+code,999)==result and not market.committed and retry_attempts()==2)
		clear_retry_fault("account_shop_revenue")
	# Caller-owned work is refused, never committed/rolled back by the wrapper.
	assert(pg.begin())
	assert(market.claim_revenue(80000,"retry-nested",0).error=="storage" and not market.committed and pg.in_transaction())
	assert(pg.rollback())
	# A retryable statement code is insufficient when cleanup itself fails.
	var before_cleanup:=retry_state()
	var killer: Object=ClassDB.instantiate("GodotSociDatabase")
	assert(killer.open("postgresql",connection))
	var pid: int=int(rows(true,"SELECT pg_backend_pid() AS pid;")[0].pid)
	var calls: Array[int]=[0]
	var owner:=preload("res://source/server/world/database/postgres/economy_command_postgres.gd").new(pg)
	var failed: Dictionary=owner.run_with_retry(func() -> Dictionary:
		calls[0]+=1
		if not owner.begin(80010,"rollback-failed","buy",[],true): return owner.cached
		assert(not pg.execute("DO $$ BEGIN RAISE EXCEPTION 'statement abort' USING ERRCODE='40001'; END; $$;").ok)
		assert(killer.query("SELECT pg_terminate_backend(:pid);",{"pid":pid}).ok)
		return owner.rollback("storage"))
	assert(failed.error=="storage" and calls[0]==1 and not pg.is_open() and not owner.committed)
	killer.close()
	assert(pg.open("postgresql",connection) and retry_state()==before_cleanup)
	print("POSTGRES_SHOP_RETRY_OK full purchase/collect, exact pending prefix, durable replay, bounded rollback retry and no COMMIT retry")

func retry_reselection(index: int) -> void:
	var listed:=retry_listing(index)
	var before:=retry_state()
	execute(true,"ALTER SEQUENCE economy.fixture_retry_attempt RESTART WITH 1;")
	execute(true,"CREATE TRIGGER fixture_retry BEFORE UPDATE ON economy.item_custody FOR EACH ROW WHEN (current_setting('application_name')='retry-selection-buyer') EXECUTE FUNCTION economy.fixture_retry_fault('40001','1','gate');")
	execute(true,"SELECT pg_advisory_lock(95124);")
	# Only this coordinated diagnostic uses larger per-session budgets; normal
	# production/fixture limits and the three-attempt policy are unchanged.
	var budgets: String=" options='-c statement_timeout=10000 -c lock_timeout=8000 -c idle_in_transaction_session_timeout=10000'"
	var ready:=Semaphore.new()
	var buyer_thread:=Thread.new()
	assert(buyer_thread.start(race_worker.bind(connection+" application_name=retry-selection-buyer"+budgets,[80010,"buy",[listed.shop_id,listed.offer_id,0,100,{8001:17}]],"retry-selection-buy",ready))==OK)
	ready.wait()
	var buyer_waiting: bool=await retry_waiting("retry-selection-buyer")
	var editor_thread:=Thread.new()
	assert(editor_thread.start(race_worker.bind(connection+" application_name=retry-selection-editor"+budgets,[80000,"edit",[listed.offer_id,0,index,101]],"retry-selection-edit",ready))==OK)
	ready.wait()
	var editor_waiting: bool=await retry_waiting("retry-selection-editor")
	# Editor is queued ahead of the retried buyer on the seller account row.
	execute(true,"SELECT pg_advisory_unlock(95124);")
	var bought: Dictionary=buyer_thread.wait_to_finish()
	var edited: Dictionary=editor_thread.wait_to_finish()
	clear_retry_fault("item_custody")
	assert(buyer_waiting and editor_waiting and edited.result.ok)
	assert(bought.result.error=="stale" and not bought.committed and retry_attempts()==1,"retry must reselect current price/revision, not reuse first attempt's SQL decisions")
	assert(retry_state().wallets==before.wallets and Settlement.new(pg).revenue(8000).amount==int(before.revenue))
	assert(Settlement.new(pg).receipt(80010,"retry-selection-buy").error=="unknown_command")
	assert(Seller.new(pg).cancel_offer(80000,"clear-selection",listed.offer_id,1).ok)

func retry_waiting(label: String) -> bool:
	var deadline: int=Time.get_ticks_msec()+2000
	while Time.get_ticks_msec()<deadline:
		execute(true,"SELECT pg_stat_clear_snapshot();")
		var result: Dictionary=pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name=:label AND wait_event_type='Lock';",{"label":label})
		if int(result.rows[0].n)==1: return true
		await get_tree().create_timer(0.005).timeout
	return false

func retry_listing(index: int) -> Dictionary:
	seed_item(Items.new(pg),true,80000,9200+index,90)
	var result: Dictionary=Seller.new(pg).list_item(80000,"retry-list-"+str(index),uid(9200+index),0,index,100)
	assert(result.ok)
	return result

func retry_state() -> Dictionary:
	return {"wallets":rows(true,"SELECT * FROM economy.account_wallets WHERE account_id IN (8000,8001) ORDER BY account_id;"),"revenue":Settlement.new(pg).revenue(8000).amount,"custody":native_custody()}

func retry_fault(table: String, code: String, failures: int, deferred: bool = false) -> void:
	execute(true,"ALTER SEQUENCE economy.fixture_retry_attempt RESTART WITH 1;")
	var create: String="CREATE CONSTRAINT TRIGGER fixture_retry AFTER INSERT ON economy.%s DEFERRABLE INITIALLY DEFERRED" % table if deferred else "CREATE TRIGGER fixture_retry BEFORE %s ON economy.%s" % ["INSERT" if table=="market_commands" else "UPDATE",table]
	execute(true,create+" FOR EACH ROW EXECUTE FUNCTION economy.fixture_retry_fault('%s','%d');" % [code,failures])

func clear_retry_fault(table: String) -> void:
	execute(true,"DROP TRIGGER fixture_retry ON economy."+table+";")

func retry_attempts() -> int:
	return int(rows(true,"SELECT last_value FROM economy.fixture_retry_attempt;")[0].last_value)

func native_custody() -> Array:
	var snapshot: Array=[]
	for table: String in ["item_instances","item_custody","shop_offers","shop_cells","market_commands","account_item_revisions"]:
		snapshot.append(rows(true,"SELECT row_to_json(t)::text AS value FROM economy."+table+" t ORDER BY row_to_json(t)::text;"))
	return snapshot

func race(specs: Array, label: String, same_id: bool = false) -> Array:
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=7000 FOR UPDATE;").ok)
	var ready:=Semaphore.new()
	var workers: Array[Thread]=[]
	for index: int in 2:
		var worker:=Thread.new()
		assert(worker.start(race_worker.bind(connection+" application_name="+label,specs[index],label if same_id else label+"-"+str(index),ready))==OK)
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
	assert(waiting==2,"both independent native sessions must overlap")
	return results

func race_worker(dsn: String, spec: Array, command: String, ready: Semaphore) -> Dictionary:
	var database: Object=ClassDB.instantiate("GodotSociDatabase")
	var opened: bool=database.open("postgresql",dsn)
	ready.post()
	if not opened: return {"result":{"ok":false,"error":"fixture_connection"},"committed":false}
	var store: RefCounted=Seller.new(database) if spec[1] in ["cancel","edit"] else Settlement.new(database)
	var args: Array=spec[2]
	var result: Dictionary
	match spec[1]:
		"cancel": result=store.cancel_offer(spec[0],command,args[0],args[1])
		"edit": result=store.edit_offer(spec[0],command,args[0],args[1],args[2],args[3])
		"collect": result=store.claim_revenue(spec[0],command,args[0])
		_: result=store.purchase(spec[0],command,args[0],args[1],args[2],args[3],args[4])
	var committed: bool=store.committed
	database.close()
	return {"result":result,"committed":committed}
