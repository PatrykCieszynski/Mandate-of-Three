extends Node
## Cross-use-case wallet invariants on independent native sessions, not a load test.
const Schema = preload("res://source/server/world/database/postgres/exchange_orders_schema_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Npc = preload("res://source/server/world/database/postgres/npc_shop_store_postgres.gd")
const Upgrade = preload("res://source/server/world/database/postgres/upgrade_store_postgres.gd")
const Orders = preload("res://source/server/world/database/postgres/exchange_orders_postgres.gd")
const Settlement = preload("res://source/server/world/database/postgres/shop_settlement_postgres.gd")
const MAX_YANG: int=9000000000000000
var pg: Object
var connection: String

func shop() -> ShopDefinition:
	var definition:=ShopDefinition.new()
	definition.shop_id=&"wallet_concurrency"
	definition.display_name="Wallet fixture"
	var offer:=ShopOfferDefinition.new()
	offer.offer_id=&"ore"
	offer.item_definition_id=&"upgrade_ore"
	offer.price=100
	offer.quantity=1
	definition.offers.append(offer)
	return definition

func recipe() -> UpgradeDefinition:
	var definition: UpgradeDefinition=load("res://source/common/gameplay/upgrades/domain/basic_upgrade.tres").duplicate()
	definition.yang_cost=100
	return definition

func request(side: String, command: String, amount: int = 1) -> Dictionary:
	return {"command_id":command,"have_asset":"upgrade_ore" if side=="sell" else "yang","want_asset":"yang" if side=="sell" else "upgrade_ore","quantity":amount,"price_num":100,"price_den":1}

func sql(query: String, params: Dictionary = {}) -> void:
	var result: Dictionary=pg.execute(query,params)
	assert(result.ok,str(result))

func identity(account: int, balance: int) -> void:
	assert(Wallet.new(pg).initialize_account(account).ok)
	for character: int in [account*10,account*10+1]: assert(Items.new(pg).bind_character(character,account))
	sql("UPDATE economy.account_wallets SET yang=:balance WHERE account_id=:account;",{"balance":balance,"account":account})

func balance(account: int) -> Dictionary:
	return Wallet.new(pg).load_wallet(account)

func inventory(character: int) -> Array:
	var result: Dictionary=Items.new(pg).inventory(character)
	assert(result.ok)
	return result.items

func state() -> Array:
	var result: Array=[]
	for table: String in ["account_wallets","account_shop_revenue","exchange_assets","exchange_orders","exchange_fills","item_instances","item_custody","market_commands","account_item_revisions"]:
		var found: Dictionary=pg.query("SELECT row_to_json(t)::text AS value FROM economy."+table+" t ORDER BY row_to_json(t)::text;",{},10000)
		assert(found.ok and not found.truncated)
		result.append(found.rows)
	return result

func seed_item(character: int, definition: StringName, position: int) -> String:
	var item:=ItemInstance.create(ItemDefinitions.get_definition(definition),character,[])
	assert(pg.begin() and Items.new(pg).receive_item_in_transaction(item,position).ok and pg.commit())
	return item.uid

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	connection=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	await spends_and_reservations()
	await receipt_namespace()
	await checkpoint_matching()
	await checkpoint_recovery()
	pg.close()
	print("POSTGRES_WALLET_CONCURRENCY_OK cross-operation funds/reservations, partial collection, account receipts, checkpoint lock order and explicit timeout recovery")
	get_tree().quit()

func spends_and_reservations() -> void:
	identity(100,100)
	var results:=await race([["npc",1000,"npc-reserve"],["order",1001,request("buy","reserve-npc")]],100,"npc-reservation")
	assert(int(results[0].ok)+int(results[1].ok)==1)
	var failed: Dictionary=results[0] if not results[0].ok else results[1]
	assert(failed.error=="funds")
	var wallet:=balance(100)
	assert(wallet.balance-wallet.reserved_yang==0)
	assert(inventory(1000).size()==int(results[0].ok))
	if results[1].ok:
		assert(Orders.new(pg).cancel_order(1001,"cancel-reservation",results[1].order_id,0,{}).ok)
	# Different characters share funds even though their receiving bags differ.
	identity(101,100)
	var sword:=seed_item(1010,&"iron_sword",0)
	var material:=seed_item(1010,&"upgrade_ore",2)
	results=await race([["upgrade",1010,["upgrade-npc",sword]],["npc",1011,"npc-upgrade"]],101,"upgrade-npc")
	assert(int(results[0].ok)+int(results[1].ok)==1 and balance(101).balance==0)
	failed=results[0] if not results[0].ok else results[1]
	assert(failed.error=="funds")
	var own:=inventory(1010)
	var target: Dictionary=own.filter(func(item: Dictionary) -> bool: return item.uid==sword)[0]
	assert(int(target.upgrade_level)==int(results[0].ok))
	assert(own.any(func(item: Dictionary) -> bool: return item.uid==material)==(not results[0].ok))
	assert(inventory(1011).size()==int(results[1].ok))
	# Collection calculates capacity against the wallet locked by this transaction.
	identity(102,MAX_YANG-50)
	sql("INSERT INTO economy.account_shop_revenue VALUES(102,100);")
	results=await race([["collect",1020,"collect-spend"],["npc",1021,"spend-collect"]],102,"collect-spend")
	assert(results[0].ok and results[1].ok)
	var revenue: Dictionary=Settlement.new(pg).revenue(102)
	assert(balance(102).balance+int(revenue.amount)==MAX_YANG-50)
	assert(results[0].claimed in [50,100] and inventory(1021).size()==1)

func receipt_namespace() -> void:
	identity(103,1000)
	var results:=await race([["npc",1030,"same-account-id"],["npc",1031,"same-account-id"]],103,"receipt-conflict")
	assert(int(results[0].ok)+int(results[1].ok)==1)
	var winner: int=0 if results[0].ok else 1
	assert(results[1-winner].error=="command_conflict")
	assert(balance(103).balance==900 and inventory(1030).size()+inventory(1031).size()==1)
	var original: Dictionary=results[winner].duplicate(true)
	original.erase("committed")
	pg.close()
	assert(pg.open("postgresql",connection))
	var npc:=Npc.new(pg)
	assert(npc.purchase_receipt(1030+winner,"same-account-id")==original)
	assert(npc.purchase(1030+winner,999,shop(),&"ore",-1,"same-account-id")==original and not npc.committed)
	# Different use cases also share the account receipt namespace.
	results=await race([["npc",1030,"cross-kind-id"],["order",1031,request("buy","cross-kind-id")]],103,"receipt-kind")
	assert(int(results[0].ok)+int(results[1].ok)==1)
	assert((results[0] if not results[0].ok else results[1]).error=="command_conflict")
	if results[1].ok:
		assert(Orders.new(pg).cancel_order(1031,"clear-cross-kind",results[1].order_id,0,{}).ok)

func checkpoint_matching() -> void:
	identity(104,1000)
	identity(105,1000)
	sql("INSERT INTO economy.exchange_assets VALUES(104,'upgrade_ore',2,0);")
	assert(Orders.new(pg).place_order(1040,request("sell","checkpoint-maker"),{}).ok)
	# Hold the match after it locks taker's (higher-ID) wallet. A checkpoint
	# must wait at account admission before it can take maker's lower wallet.
	sql("CREATE FUNCTION economy.fixture_match_barrier() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF current_setting('application_name')='checkpoint-match' AND NEW.account_id=105 THEN PERFORM pg_advisory_xact_lock(94123); END IF; RETURN NEW; END; $$;")
	sql("CREATE TRIGGER fixture_match_barrier BEFORE UPDATE ON economy.account_wallets FOR EACH ROW EXECUTE FUNCTION economy.fixture_match_barrier();")
	sql("SELECT pg_advisory_lock(94123);")
	var ready:=Semaphore.new()
	var match_thread:=Thread.new()
	assert(match_thread.start(worker.bind(connection+" application_name=checkpoint-match",["order",1050,request("buy","checkpoint-taker")],ready))==OK)
	ready.wait()
	assert(await wait_locked(["checkpoint-match"])==1)
	var checkpoint:=Thread.new()
	assert(checkpoint.start(worker.bind(connection+" application_name=checkpoint-income",["checkpoint",0,{104:7,105:11}],ready))==OK)
	ready.wait()
	assert(await wait_locked(["checkpoint-match","checkpoint-income"],2)==2)
	sql("SELECT pg_advisory_unlock(94123);")
	var matched: Dictionary=match_thread.wait_to_finish()
	var saved: Dictionary=checkpoint.wait_to_finish()
	assert(matched.ok and saved.ok,"checkpoint and reverse-wallet matching complete without deadlock/timeout")
	assert(balance(104).balance==1107 and balance(105).balance==911)
	assert(balance(105).reserved_yang==0)
	sql("DROP TRIGGER fixture_match_barrier ON economy.account_wallets;")
	# Two reverse input dictionaries still checkpoint all accounts in one order.
	var results:=await race([["checkpoint",0,{105:13,104:17}],["checkpoint",0,{104:19,105:23}]],104,"reverse-checkpoints")
	assert(results[0].ok and results[1].ok)
	assert(balance(104).balance==1143 and balance(105).balance==947)

func checkpoint_recovery() -> void:
	identity(106,1000)
	var before:=state()
	assert(not Wallet.new(pg).checkpoint({106:3,999999:4}).ok)
	assert(state()==before,"missing later account cannot partially save earlier income")
	# Lock timeout is a known uncommitted failure, never a durable rejection.
	assert(pg.begin())
	assert(pg.query("SELECT account_id FROM economy.accounts WHERE account_id=106 FOR NO KEY UPDATE;").ok)
	var ready:=Semaphore.new()
	var blocked:=Thread.new()
	assert(blocked.start(worker.bind(connection+" application_name=wallet-timeout",["npc",1060,"timeout-npc"],ready))==OK)
	ready.wait()
	var timed_out: Dictionary=blocked.wait_to_finish()
	assert(not timed_out.ok and timed_out.error=="storage" and not timed_out.committed)
	assert(pg.commit() and state()==before)
	var npc:=Npc.new(pg)
	assert(npc.purchase_receipt(1060,"timeout-npc").error=="unknown_command")
	var original: Dictionary=npc.purchase(1060,0,shop(),&"ore",-1,"timeout-npc")
	assert(original.ok and npc.committed)
	assert(npc.purchase(1060,0,shop(),&"ore",-1,"timeout-npc")==original and not npc.committed)
	assert(balance(106).balance==900 and inventory(1060).size()==1)

func race(specs: Array, account: int, label: String) -> Array:
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=:account FOR NO KEY UPDATE;",{"account":account}).rows.size()==1)
	var ready:=Semaphore.new()
	var threads: Array[Thread]=[]
	for spec: Array in specs:
		var thread:=Thread.new()
		assert(thread.start(worker.bind(connection+" application_name="+label,spec,ready))==OK)
		threads.append(thread)
	for index: int in specs.size(): ready.wait()
	var waiting: int=await wait_locked([label],specs.size())
	assert(pg.commit())
	var results: Array=[]
	for thread: Thread in threads: results.append(thread.wait_to_finish())
	assert(waiting==specs.size(),"independent sessions must overlap before release")
	return results

func wait_locked(labels: Array, expected: int = 1) -> int:
	var waiting: int=0
	var deadline: int=Time.get_ticks_msec()+500
	while waiting<expected and Time.get_ticks_msec()<deadline:
		sql("SELECT pg_stat_clear_snapshot();")
		waiting=0
		for label: String in labels:
			waiting+=int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name=:label AND wait_event_type='Lock';",{"label":label}).rows[0].n)
		if waiting<expected: await get_tree().create_timer(0.005).timeout
	return waiting

func worker(dsn: String, spec: Array, ready: Semaphore) -> Dictionary:
	var database: Object=ClassDB.instantiate("GodotSociDatabase")
	var opened: bool=database.open("postgresql",dsn)
	ready.post()
	if not opened: return {"ok":false,"error":"fixture_connection"}
	var result: Dictionary
	var store: RefCounted
	match spec[0]:
		"npc":
			store=Npc.new(database)
			result=store.purchase(spec[1],0,shop(),&"ore",-1,spec[2])
		"upgrade":
			store=Upgrade.new(database)
			result=store.upgrade(spec[1],0,recipe(),spec[2][1],0,spec[2][0])
		"order":
			store=Orders.new(database)
			result=store.place_order(spec[1],spec[2],{})
		"collect":
			store=Settlement.new(database)
			result=store.claim_revenue(spec[1],spec[2],0)
		"checkpoint": result=Wallet.new(database).checkpoint(spec[2])
	result.committed=false if store==null else store.committed
	database.close()
	return result
