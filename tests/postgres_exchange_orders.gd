extends Node
const Schema = preload("res://source/server/world/database/postgres/exchange_orders_schema_postgres.gd")
const Prior = preload("res://source/server/world/database/postgres/exchange_ledger_schema_postgres.gd")
const Orders = preload("res://source/server/world/database/postgres/exchange_orders_postgres.gd")
const Ledger = preload("res://source/server/world/database/postgres/exchange_ledger_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
var pg: Object
var sqlite: SQLite
var connection: String
var characters: Array[int]=[]
var accounts: Array[int]=[]

func request(side: String, amount: int, num: int, den: int, id: String, asset: String = "upgrade_ore") -> Dictionary:
	return {"command_id":id,"have_asset":asset if side=="sell" else "yang","want_asset":"yang" if side=="sell" else asset,"quantity":amount,"price_num":num,"price_den":den}

func execute(native: bool, sql: String, bindings: Dictionary = {}) -> void:
	if native:
		var result: Dictionary=pg.execute(sql,bindings)
		assert(result.ok,str(result))
	else: assert(sqlite.query_with_bindings(sql,bindings.values()))

func rows(native: bool, sql: String) -> Array:
	if native:
		var result: Dictionary=pg.query(sql,{},10000)
		assert(result.ok and not result.truncated)
		return result.rows
	assert(sqlite.query(sql))
	return sqlite.query_result.duplicate(true)

func result_view(result: Dictionary, names: Dictionary) -> Dictionary:
	var view:=result.duplicate(true)
	if view.has("order_id"): view.order_id=names[view.order_id]
	for field: String in ["remaining","refunded"]:
		if view.has(field): view[field]=int(view[field])
	if view.has("item_state"): view.item_state.erase("authority_id")
	for wallet: Dictionary in view.get("wallet_states",[]): wallet.erase("authority_id")
	if view.has("affected_accounts"): view.affected_accounts=view.affected_accounts.map(func(account: Variant) -> int: return int(account))
	return view

func capture(store: RefCounted, names: Dictionary, native: bool) -> Dictionary:
	var prefix: String="economy." if native else ""
	var sequence: Dictionary={}
	for row: Dictionary in rows(native,"SELECT sequence FROM "+prefix+"exchange_orders ORDER BY sequence;"): sequence[int(row.sequence)]=sequence.size()
	var fills: Dictionary={}
	for row: Dictionary in rows(native,"SELECT fill_id FROM "+prefix+"exchange_fills ORDER BY fill_id;"): fills[int(row.fill_id)]=fills.size()
	var views: Array=[]
	for character: int in characters:
		var view: Dictionary=store.orders_snapshot(character)
		assert(view.ok)
		for order: Dictionary in view.orders:
			order.order_id=names[order.order_id]
			order.sequence=sequence[int(order.sequence)]
		for fill: Dictionary in view.fills:
			fill.fill_id=fills[int(fill.fill_id)]
			fill.maker_id=names[fill.maker_id]
			fill.taker_id=names[fill.taker_id]
		for order: Dictionary in view.depth: order.sequence=sequence[int(order.sequence)]
		views.append(view)
	return {"views":views,"receipts":int(rows(native,"SELECT COUNT(*) AS n FROM "+prefix+"market_commands;")[0].n)}

func placed(store: RefCounted, names: Dictionary, character: int, p: Dictionary, pending: Dictionary = {}) -> Dictionary:
	var result: Dictionary=store.place_order(character,p,pending)
	assert(result.ok,str(result))
	names[result.order_id]=p.command_id
	return result

func fault(native: bool, table: String, event: String) -> void:
	if native:
		execute(true,"CREATE OR REPLACE FUNCTION economy.fixture_order_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'order fixture fault'; END; $$;")
		execute(true,"CREATE TRIGGER fixture_order_fault BEFORE %s ON economy.%s FOR EACH ROW EXECUTE FUNCTION economy.fixture_order_fault();" % [event,table])
	else: execute(false,"CREATE TEMP TRIGGER fixture_order_fault BEFORE %s ON %s BEGIN SELECT RAISE(ABORT,'order fixture fault'); END;" % [event,table])

func clear_fault(native: bool, table: String) -> void:
	execute(native,"DROP TRIGGER fixture_order_fault ON economy."+table+";" if native else "DROP TRIGGER fixture_order_fault;")

func exercise(store: RefCounted, native: bool) -> Array:
	var checkpoints: Array=[]
	var names: Dictionary={}
	var a: int=characters[0]
	var b: int=characters[1]
	var c: int=characters[2]
	var d: int=characters[3]
	var maker:=placed(store,names,a,request("sell",100,10,1,"sell100"))
	var before:=capture(store,names,native)
	for stage: Array in [["account_wallets","UPDATE"],["exchange_orders","INSERT"],["exchange_assets","UPDATE"],["exchange_assets","INSERT"],["exchange_orders","UPDATE"],["exchange_fills","INSERT"],["market_commands","INSERT"]]:
		fault(native,stage[0],stage[1])
		assert(store.place_order(b,request("buy",60,12,1,"buy60"),{accounts[0]:33,accounts[1]:90}).error=="storage")
		assert(capture(store,names,native)==before,"all settlement stages roll back funds, reserves, orders, fills and receipt")
		clear_fault(native,stage[0])
	var bought:=placed(store,names,b,request("buy",60,12,1,"buy60"),{accounts[0]:33,accounts[1]:90})
	assert(bought.remaining==0 and store.committed)
	assert(store.orders_snapshot(a).yang==10633 and store.orders_snapshot(b).yang==9490,"maker price, not taker limit; pending prefix applied once")
	var replay: Dictionary=store.place_order(b,request("buy",60,12,1,"buy60"),{accounts[1]:999})
	assert(result_view(replay,names)==result_view(bought,names) and not store.committed)
	assert(store.orders_snapshot(b).yang==9490)
	assert(store.place_order(b,request("buy",61,12,1,"buy60"),{}).error=="command_conflict")
	placed(store,names,c,request("buy",40,10,1,"buy40"))
	assert(store.cancel_order(a,"stale-cancel",maker.order_id,0,{}).error=="stale")
	assert(store.cancel_order(a,"closed-cancel",maker.order_id,2,{}).error=="closed")
	assert(store.cancel_order(b,"foreign",maker.order_id,2,{}).error=="owner")
	checkpoints.append(capture(store,names,native))
	var offline:=placed(store,names,a,request("sell",50,8,1,"offline"))
	placed(store,names,b,request("buy",20,10,1,"offline20"))
	before=capture(store,names,native)
	for stage: Array in [["exchange_assets","UPDATE"],["exchange_orders","UPDATE"],["market_commands","INSERT"]]:
		fault(native,stage[0],stage[1])
		assert(store.cancel_order(a,"cancel",offline.order_id,1,{}).error=="storage")
		assert(capture(store,names,native)==before)
		clear_fault(native,stage[0])
	var cancelled: Dictionary=store.cancel_order(a,"cancel",offline.order_id,1,{})
	assert(cancelled.ok and cancelled.refunded==30)
	assert(result_view(store.cancel_order(a,"cancel",offline.order_id,1,{}),names)==result_view(cancelled,names) and not store.committed)
	placed(store,names,d,request("sell",20,11,1,"dear"))
	var cheap:=placed(store,names,a,request("sell",20,9,1,"cheap"))
	placed(store,names,c,request("buy",20,12,1,"priority"))
	assert(store.orders_snapshot(a).orders.any(func(o: Dictionary) -> bool: return o.order_id==cheap.order_id and o.status=="filled"))
	placed(store,names,a,request("sell",20,11,1,"second-equal"))
	placed(store,names,c,request("buy",10,11,1,"time-priority"))
	checkpoints.append(capture(store,names,native))
	placed(store,names,a,request("sell",6,3,2,"fraction","forest_resin"))
	placed(store,names,b,request("buy",6,2,1,"fraction-buy","forest_resin"))
	placed(store,names,a,request("sell",3,2,3,"lot-three","forest_resin"))
	var lot:=placed(store,names,b,request("buy",2,1,1,"lot-two","forest_resin"))
	assert(lot.remaining==2,"incompatible whole-item common lot is skipped, never rounded")
	placed(store,names,c,request("buy",3,1,1,"lot-fill","forest_resin"))
	var buy_cancel: Dictionary=store.cancel_order(b,"cancel-buy",lot.order_id,0,{accounts[1]:17})
	assert(buy_cancel.ok and buy_cancel.refunded==2 and buy_cancel.wallet_states[0].pending_applied==17)
	assert(result_view(store.cancel_order(b,"cancel-buy",lot.order_id,0,{accounts[1]:100}),names)==result_view(buy_cancel,names))
	var own_sell:=placed(store,names,a,request("sell",5,10,1,"self-sell","forest_resin"))
	var own_buy:=placed(store,names,a,request("buy",5,10,1,"self-buy","forest_resin"))
	assert(own_buy.remaining==5)
	assert(store.cancel_order(a,"self-cancel-sell",own_sell.order_id,0,{}).ok)
	assert(store.cancel_order(a,"self-cancel-buy",own_buy.order_id,0,{}).ok)
	for invalid: Dictionary in [request("buy",1,3,2,"bad-lot"),request("buy",9000000000000000,1000000000,1,"overflow"),request("buy",1,1000000001,1,"ratio")]:
		assert(store.place_order(a,invalid,{}).error=="request_or_overflow")
	var prefix: String="economy." if native else ""
	assert(int(rows(native,"SELECT SUM(yang) AS n FROM "+prefix+"account_wallets;")[0].n)==40000+33+90+17,"only declared pending income changes total Yang")
	assert(int(rows(native,"SELECT SUM(free+reserved) AS n FROM "+prefix+"exchange_assets;")[0].n)==1600,"material sources conserved across fills/reserves/cancel")
	checkpoints.append(capture(store,names,native))
	if native:
		pg.close()
		assert(pg.open("postgresql",connection))
	else:
		sqlite.close_db()
		assert(sqlite.open_db())
	assert(result_view(store.place_order(b,request("buy",60,12,1,"buy60"),{}),names)==result_view(bought,names))
	assert(result_view(store.receipt(b,"buy60"),names)==result_view(bought,names))
	assert(capture(store,names,native)==checkpoints[-1])
	return checkpoints

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var directory:=OS.get_environment("MANDATE_PG_FIXTURE_DIR")
	assert(directory.begins_with("res://.godot/verification/postgres-readiness/run-") and not ".." in directory)
	sqlite=SQLite.new()
	sqlite.path=directory+"/exchange-orders.db"
	assert(not FileAccess.file_exists(sqlite.path) and sqlite.open_db())
	WorldSchema.ensure_schema(sqlite)
	var identities:=WorldStoreSqlite.new(sqlite)
	for index: int in 4:
		var character:=EconomyFixture.create_character(identities,"orders-"+str(index),{"name":"Order"+str(index),"skin":1})
		characters.append(character)
		accounts.append(identities.resolve_account_id(character))
	var runtime:=WorldDatabase.new()
	runtime.db=sqlite
	runtime.store=identities
	EconomyFixture.prepare(runtime)
	connection=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Prior.ensure_schema(pg))
	for index: int in 4:
		assert(Wallet.new(pg).initialize_account(accounts[index]).ok and Items.new(pg).bind_character(characters[index],accounts[index]))
		for native: bool in [false,true]:
			var prefix: String="economy." if native else ""
			execute(native,"UPDATE "+prefix+"account_wallets SET yang=10000 WHERE account_id="+str(accounts[index])+";")
			for asset: String in ["upgrade_ore","forest_resin"]:
				execute(native,"INSERT INTO "+prefix+"exchange_assets(account_id,asset_id,free) VALUES(:account,:asset,200);",{"account":accounts[index],"asset":asset})
	execute(true,"CREATE FUNCTION economy.fixture_order_schema_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.feature='exchange_orders' THEN RAISE EXCEPTION 'order schema fault'; END IF; RETURN NEW; END; $$;")
	execute(true,"CREATE TRIGGER fixture_order_schema_fault BEFORE INSERT ON economy.schema_versions FOR EACH ROW EXECUTE FUNCTION economy.fixture_order_schema_fault();")
	assert(not Schema.ensure_schema(pg) and not pg.in_transaction())
	assert(pg.query("SELECT to_regclass('economy.exchange_orders')::text AS name;").rows[0].name==null)
	execute(true,"DROP TRIGGER fixture_order_schema_fault ON economy.schema_versions;")
	assert(Schema.ensure_schema(pg) and Schema.ensure_schema(pg))
	var baseline:=exercise(ExchangeStoreSqlite.new(sqlite),false)
	var candidate:=exercise(Orders.new(pg),true)
	assert(baseline==candidate,"wallets/reserves, order/fill priority, snapshots/depth and receipt totals match SQLite")
	await native_checks()
	await retry_checks()
	pg.close()
	runtime.db=null
	runtime.free()
	sqlite.close_db()
	print("POSTGRES_EXCHANGE_ORDERS_OK exact settlement/cancel parity, receipt recovery, conservation and independent-session matching conflicts")
	get_tree().quit()

func native_state() -> Array:
	var state: Array=[]
	for table: String in ["exchange_orders","exchange_fills","exchange_assets","account_wallets","market_commands"]:
		state.append(rows(true,"SELECT row_to_json(t)::text AS value FROM economy."+table+" t ORDER BY row_to_json(t)::text;"))
	return state

func native_checks() -> void:
	for id: int in range(7000,7004):
		assert(Wallet.new(pg).initialize_account(id).ok and Items.new(pg).bind_character(id*10,id))
		execute(true,"UPDATE economy.account_wallets SET yang=100000 WHERE account_id="+str(id)+";")
		for asset: String in ["beast_hide","bandit_token"]:
			execute(true,"INSERT INTO economy.exchange_assets VALUES(:account,:asset,200,0);",{"account":id,"asset":asset})
	var store:=Orders.new(pg)
	var maker: Dictionary=store.place_order(70000,request("sell",100,10,1,"race-maker","beast_hide"),{})
	assert(maker.ok)
	var results:=await race([[70010,"place",request("buy",100,10,1,"race-buy-a","beast_hide"),{}],[70020,"place",request("buy",100,10,1,"race-buy-b","beast_hide"),{}]],"beast_hide","two-takers")
	assert(results[0].result.ok and results[1].result.ok)
	assert(int(results[0].result.remaining)+int(results[1].result.remaining)==100,"one maker fill; the other buyer rests instead of duplicating it")
	assert(int(rows(true,"SELECT COUNT(*) AS n FROM economy.exchange_fills WHERE maker_id='"+str(maker.order_id)+"';")[0].n)==1)
	# Cancel/fill cannot both consume the same reserved remainder.
	maker=store.place_order(70000,request("sell",20,10,1,"cancel-maker","bandit_token"),{})
	assert(maker.ok)
	results=await race([[70000,"cancel",["race-cancel",maker.order_id,0],{}],[70010,"place",request("buy",20,10,1,"race-fill","bandit_token"),{}]],"bandit_token","cancel-fill")
	assert(results[1].result.ok and (results[0].result.ok or results[0].result.error=="stale"))
	# Same operation, one reservation/order/fill and identical durable replay.
	var same:=request("sell",10,20,1,"same-order","bandit_token")
	results=await race([[70020,"place",same,{}],[70020,"place",same,{}]],"bandit_token","same-id")
	assert(results[0].result.ok and results[0].result==results[1].result and int(results[0].committed)+int(results[1].committed)==1)
	var before:=native_state()
	execute(true,"CREATE CONSTRAINT TRIGGER fixture_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_order_fault();")
	var unknown: Dictionary=store.place_order(70030,request("buy",10,20,1,"commit-match","bandit_token"),{7003:17})
	assert(unknown.get("outcome_unknown",false) and not pg.is_open() and not store.committed)
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	execute(true,"DROP TRIGGER fixture_commit ON economy.market_commands;")
	assert(native_state()==before and store.receipt(70030,"commit-match").error=="unknown_command")
	assert(store.place_order(70030,request("buy",10,20,1,"commit-match","bandit_token"),{7003:17}).ok)
	# Cancellation uses the same uncertain-outcome recovery contract.
	var cancellable: Dictionary=store.place_order(70030,request("buy",7,1,1,"commit-cancel-source","bandit_token"),{})
	assert(cancellable.ok and cancellable.remaining==7)
	before=native_state()
	execute(true,"CREATE CONSTRAINT TRIGGER fixture_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_order_fault();")
	unknown=store.cancel_order(70030,"commit-cancel",cancellable.order_id,0,{7003:13})
	assert(unknown.get("outcome_unknown",false) and not pg.is_open() and not store.committed)
	assert(pg.open("postgresql",connection))
	execute(true,"DROP TRIGGER fixture_commit ON economy.market_commands;")
	assert(native_state()==before and store.receipt(70030,"commit-cancel").error=="unknown_command")
	var cancelled: Dictionary=store.cancel_order(70030,"commit-cancel",cancellable.order_id,0,{7003:13})
	assert(cancelled.ok and cancelled.refunded==7)
	assert(store.cancel_order(70030,"commit-cancel",cancellable.order_id,0,{7003:999})==cancelled and not store.committed)
	# Clear earlier race orders before crossing two books with reversed parties.
	for character: int in [70000,70010,70020,70030]:
		for order: Dictionary in store.orders_snapshot(character).orders:
			if order.status=="active": assert(store.cancel_order(character,"clear-"+order.order_id,order.order_id,int(order.revision),{}).ok)
	assert(store.place_order(70000,request("sell",5,10,1,"cross-maker-a","beast_hide"),{}).ok)
	assert(store.place_order(70010,request("sell",5,10,1,"cross-maker-b","bandit_token"),{}).ok)
	results=await race([[70010,"place",request("buy",5,10,1,"cross-taker-a","beast_hide"),{}],[70000,"place",request("buy",5,10,1,"cross-taker-b","bandit_token"),{}]],"","cross-books")
	assert(results[0].result.ok and results[1].result.ok and results[0].result.remaining==0 and results[1].result.remaining==0,"different books share accounts in one sorted lock order")
	await limits_and_overflow(store)
	assert(pg.begin())
	assert(store.place_order(70000,request("sell",1,20,1,"nested","bandit_token"),{}).error=="storage")
	assert(store.orders_snapshot(70000).error=="storage" and pg.in_transaction() and pg.rollback())
	execute(true,"UPDATE economy.schema_versions SET version=999 WHERE feature='exchange_orders';")
	assert(not Schema.ensure_schema(pg) and not pg.in_transaction())
	execute(true,"UPDATE economy.schema_versions SET version=1 WHERE feature='exchange_orders';")
	assert(Schema.ensure_schema(pg))
	print("POSTGRES_EXCHANGE_ORDERS_NATIVE_OK two takers, cancel/fill, duplicate order, ambiguous COMMIT/reopen and transaction ownership")

func race(specs: Array, base: String, label: String) -> Array:
	assert(pg.begin())
	if base.is_empty():
		assert(pg.query("SELECT account_id FROM economy.accounts WHERE account_id=7000 FOR NO KEY UPDATE;").rows.size()==1)
	else:
		assert(pg.query("SELECT base_asset FROM economy.exchange_books WHERE base_asset=:base FOR UPDATE;",{"base":base}).rows.size()==1)
	var ready:=Semaphore.new()
	var threads: Array[Thread]=[]
	for spec: Array in specs:
		var worker:=Thread.new()
		assert(worker.start(race_worker.bind(connection+" application_name="+label,spec,ready))==OK)
		threads.append(worker)
	for index: int in 2: ready.wait()
	var waiting: int=0
	var deadline: int=Time.get_ticks_msec()+500
	while waiting<2 and Time.get_ticks_msec()<deadline:
		assert(pg.execute("SELECT pg_stat_clear_snapshot();").ok)
		waiting=int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name=:label AND wait_event_type='Lock';",{"label":label}).rows[0].n)
		if waiting<2: await get_tree().create_timer(0.005).timeout
	assert(pg.commit())
	var results: Array=[]
	for worker: Thread in threads: results.append(worker.wait_to_finish())
	assert(waiting==2,"two independent native sessions must overlap")
	return results

func limits_and_overflow(store: RefCounted) -> void:
	# No receipt, reservation or pending income survives a failed credit.
	execute(true,"UPDATE economy.account_wallets SET yang=9000000000000000 WHERE account_id=7000;")
	assert(store.place_order(70000,request("sell",1,10,1,"overflow-maker","beast_hide"),{}).ok)
	var before:=native_state()
	assert(not store.place_order(70010,request("buy",1,10,1,"overflow-wallet","beast_hide"),{}).ok)
	assert(native_state()==before)
	execute(true,"UPDATE economy.account_wallets SET yang=100000 WHERE account_id=7000;")
	execute(true,"UPDATE economy.exchange_assets SET free=9000000000000000-reserved WHERE account_id=7001 AND asset_id='beast_hide';")
	before=native_state()
	assert(not store.place_order(70010,request("buy",1,10,1,"overflow-asset","beast_hide"),{}).ok)
	assert(native_state()==before)
	# Per-account admission is bounded and replays a prior success at the cap.
	var first: Dictionary={}
	for index: int in 20:
		var result: Dictionary=store.place_order(70020,request("sell",1,100,1,"limit-"+str(index),"bandit_token"),{})
		assert(result.ok)
		if index==0: first=result
	assert(store.place_order(70020,request("sell",1,100,1,"limit-extra","bandit_token"),{}).error=="order_limit")
	assert(store.place_order(70020,request("sell",1,100,1,"limit-0","bandit_token"),{})==first and not store.committed)
	# Account identities exceed JSON's safe integer range; original affected
	# accounts must survive receipt decode/discovery without rounding.
	var large: int=9007199254740993
	assert(Wallet.new(pg).initialize_account(large).ok and Items.new(pg).bind_character(large+10,large))
	execute(true,"INSERT INTO economy.exchange_assets VALUES(:account,'bandit_token',3,0);",{"account":large})
	var original: Dictionary=store.place_order(large+10,request("sell",3,1000,1,"large-identity","bandit_token"),{})
	assert(original.ok and original.affected_accounts==[large])
	assert(store.receipt(large+10,"large-identity")==original)
	assert(store.place_order(large+10,request("sell",3,1000,1,"large-identity","bandit_token"),{})==original and not store.committed)

func race_worker(dsn: String, spec: Array, ready: Semaphore) -> Dictionary:
	var database: Object=ClassDB.instantiate("GodotSociDatabase")
	var opened: bool=database.open("postgresql",dsn)
	ready.post()
	if not opened: return {"result":{"ok":false,"error":"fixture_connection"},"committed":false}
	var store:=Orders.new(database)
	var result: Dictionary=store.place_order(spec[0],spec[2],spec[3]) if spec[1]=="place" else store.cancel_order(spec[0],spec[2][0],spec[2][1],spec[2][2],spec[3])
	var committed: bool=store.committed
	database.close()
	return {"result":result,"committed":committed}

func retry_checks() -> void:
	var store:=Orders.new(pg)
	# Isolate the book from earlier parity/race cases without bypassing cancellation.
	for row: Dictionary in rows(true,"SELECT o.order_id,o.revision,MIN(c.character_id) AS character FROM economy.exchange_orders o JOIN economy.characters c ON c.account_id=o.account_id WHERE o.status='active' AND o.base_asset IN ('beast_hide','bandit_token') GROUP BY o.sequence;"):
		assert(store.cancel_order(int(row.character),"retry-clear-"+row.order_id,row.order_id,int(row.revision),{}).ok)
	for id: int in range(8000,8004):
		assert(Wallet.new(pg).initialize_account(id).ok and Items.new(pg).bind_character(id*10,id))
		execute(true,"UPDATE economy.account_wallets SET yang=10000 WHERE account_id="+str(id)+";")
		for asset: String in ["beast_hide","bandit_token"]:
			execute(true,"INSERT INTO economy.exchange_assets VALUES(:account,:asset,200,0);",{"account":id,"asset":asset})
	execute(true,"CREATE SEQUENCE economy.fixture_order_attempt;")
	execute(true,"CREATE FUNCTION economy.fixture_order_retry() RETURNS trigger LANGUAGE plpgsql AS $$ DECLARE attempt BIGINT; BEGIN attempt:=nextval('economy.fixture_order_attempt'); IF attempt>=TG_ARGV[1]::BIGINT AND attempt<=TG_ARGV[2]::BIGINT THEN IF TG_NARGS>3 THEN PERFORM pg_advisory_xact_lock(95125); END IF; RAISE EXCEPTION 'order retry fixture' USING ERRCODE=TG_ARGV[0]; END IF; RETURN NEW; END; $$;")
	# The pair admission precedes the common character/receipt owner.
	order_retry_fault("exchange_books","INSERT","40P01",1,1)
	var admission: Dictionary=store.place_order(80030,request("sell",2,100,1,"retry-pair","bandit_token"),{})
	assert(admission.ok and store.committed and order_retry_attempts()==2)
	clear_order_retry("exchange_books")
	# Material refunds use the same transaction contract as Yang reservations.
	order_retry_fault("exchange_assets","UPDATE","40001",1,1)
	var refund: Dictionary=store.cancel_order(80030,"retry-material-refund",admission.order_id,0,{})
	assert(refund.ok and refund.refunded==2 and order_retry_attempts()==2)
	clear_order_retry("exchange_assets")
	var restored: Dictionary=pg.query("SELECT free,reserved FROM economy.exchange_assets WHERE account_id=8003 AND asset_id='bandit_token';").rows[0]
	assert(int(restored.free)==200 and int(restored.reserved)==0)
	for code: String in ["40001","40P01"]:
		assert(store.place_order(80000,request("sell",5,10,1,"maker-a-"+code,"beast_hide"),{}).ok)
		assert(store.place_order(80010,request("sell",5,11,1,"maker-b-"+code,"beast_hide"),{}).ok)
		var balances: Array=[]
		for id: int in [8000,8001,8002]: balances.append(Wallet.new(pg).load_wallet(id).balance)
		var held: int=int(rows(true,"SELECT free FROM economy.exchange_assets WHERE account_id=8002 AND asset_id='beast_hide';")[0].free)
		# Abort the SECOND fill, after the first maker and all wallet writes.
		order_retry_fault("exchange_fills","INSERT",code,2,2)
		var p:=request("buy",10,12,1,"retry-match-"+code,"beast_hide")
		var bought: Dictionary=store.place_order(80020,p,{8000:7,8001:11,8002:17})
		assert(bought.ok and bought.remaining==0 and store.committed and order_retry_attempts()==4)
		assert(int(rows(true,"SELECT COUNT(*) AS n FROM economy.exchange_fills WHERE taker_id='"+bought.order_id+"';")[0].n)==2,"aborted first fill must not survive the retry")
		assert(Wallet.new(pg).load_wallet(8000).balance==balances[0]+50+7)
		assert(Wallet.new(pg).load_wallet(8001).balance==balances[1]+55+11)
		assert(Wallet.new(pg).load_wallet(8002).balance==balances[2]-105+17)
		assert(Wallet.new(pg).load_wallet(8002).reserved_yang==0)
		assert(int(rows(true,"SELECT free FROM economy.exchange_assets WHERE account_id=8002 AND asset_id='beast_hide';")[0].free)==held+10)
		var before:=native_state()
		assert(store.place_order(80020,p,{8002:999})==bought and not store.committed and native_state()==before and order_retry_attempts()==4)
		clear_order_retry("exchange_fills")
	# Re-run reservation and receipt creation from scratch; only one order survives.
	for table: String in ["account_wallets","market_commands"]:
		order_retry_fault(table,"INSERT" if table=="market_commands" else "UPDATE","40001",1,1)
		var p:=request("buy",3,1,1,"retry-reserve-"+table,"bandit_token")
		var before_balance: int=Wallet.new(pg).load_wallet(8003).balance
		var placed: Dictionary=store.place_order(80030,p,{8003:13})
		assert(placed.ok and store.committed and Wallet.new(pg).load_wallet(8003).balance==before_balance+13)
		assert(int(rows(true,"SELECT COUNT(*) AS n FROM economy.market_commands WHERE command_id='"+p.command_id+"';")[0].n)==1)
		clear_order_retry(table)
		# Abort after refund and order mutation, at receipt persistence.
		order_retry_fault("market_commands","INSERT","40P01",1,1)
		var cancelled: Dictionary=store.cancel_order(80030,"retry-cancel-"+table,placed.order_id,0,{8003:19})
		assert(cancelled.ok and cancelled.refunded==3 and store.committed and order_retry_attempts()==2)
		assert(Wallet.new(pg).load_wallet(8003).balance==before_balance+13+19 and Wallet.new(pg).load_wallet(8003).reserved_yang==0)
		var before:=native_state()
		assert(store.cancel_order(80030,"retry-cancel-"+table,placed.order_id,0,{8003:999})==cancelled and not store.committed and native_state()==before and order_retry_attempts()==2)
		clear_order_retry("market_commands")
	# Both order creation and cancellation stop at the shared three-attempt cap;
	# unrelated storage codes are not silently retried.
	for code: String in ["40001","40P01","23505","55P03","57014"]:
		var source: Dictionary=store.place_order(80030,request("buy",2,1,1,"budget-source-"+code,"bandit_token"),{})
		assert(source.ok)
		for cancel: bool in [false,true]:
			order_retry_fault("market_commands","INSERT",code,1,99)
			var before:=native_state()
			var result: Dictionary=store.cancel_order(80030,"budget-cancel-"+code,source.order_id,0,{8003:23}) if cancel else store.place_order(80030,request("buy",2,1,1,"budget-place-"+code,"bandit_token"),{8003:23})
			assert(result.error=="storage" and not store.committed and native_state()==before and not pg.in_transaction())
			assert(order_retry_attempts()==(3 if code in ["40001","40P01"] else 1))
			clear_order_retry("market_commands")
		assert(store.cancel_order(80030,"clear-budget-"+code,source.order_id,0,{}).ok)
	# Even a retryable code at COMMIT is ambiguous, never a retry authorization.
	for code: String in ["40001","40P01"]:
		var source: Dictionary=store.place_order(80030,request("buy",2,1,1,"commit-source-"+code,"bandit_token"),{})
		assert(source.ok)
		for cancel: bool in [false,true]:
			order_retry_fault("market_commands","INSERT",code,1,99,true)
			var before:=native_state()
			var command: String="unknown-"+code+str(cancel)
			var result: Dictionary=store.cancel_order(80030,command,source.order_id,0,{8003:29}) if cancel else store.place_order(80030,request("buy",2,1,1,command,"bandit_token"),{8003:29})
			assert(result.get("outcome_unknown",false) and not store.committed and not pg.is_open())
			assert(pg.open("postgresql",connection) and order_retry_attempts()==1)
			clear_order_retry("market_commands")
			assert(native_state()==before and store.receipt(80030,command).error=="unknown_command")
		assert(store.cancel_order(80030,"clear-commit-"+code,source.order_id,0,{}).ok)
	await retry_book_reselection()
	await retry_cancel_reselection()
	print("POSTGRES_EXCHANGE_ORDER_RETRY_OK multi-maker rollback, pending once, reserve/refund/replay, bounded attempts, no COMMIT retry and current-book reselection")

func order_retry_fault(table: String, event: String, code: String, first: int, last: int, deferred: bool = false) -> void:
	execute(true,"ALTER SEQUENCE economy.fixture_order_attempt RESTART WITH 1;")
	var create: String="CREATE CONSTRAINT TRIGGER fixture_retry AFTER INSERT ON economy.%s DEFERRABLE INITIALLY DEFERRED" % table if deferred else "CREATE TRIGGER fixture_retry BEFORE %s ON economy.%s" % [event,table]
	execute(true,create+" FOR EACH ROW EXECUTE FUNCTION economy.fixture_order_retry('%s','%d','%d');" % [code,first,last])

func clear_order_retry(table: String) -> void:
	execute(true,"DROP TRIGGER fixture_retry ON economy."+table+";")

func order_retry_attempts() -> int:
	return int(rows(true,"SELECT last_value FROM economy.fixture_order_attempt;")[0].last_value)

func retry_book_reselection() -> void:
	var store:=Orders.new(pg)
	var maker: Dictionary=store.place_order(80000,request("sell",5,10,1,"reselect-maker","beast_hide"),{})
	assert(maker.ok)
	execute(true,"ALTER SEQUENCE economy.fixture_order_attempt RESTART WITH 1;")
	execute(true,"CREATE TRIGGER fixture_retry BEFORE INSERT ON economy.exchange_fills FOR EACH ROW WHEN (current_setting('application_name')='retry-order-buyer') EXECUTE FUNCTION economy.fixture_order_retry('40001','1','1','gate');")
	execute(true,"SELECT pg_advisory_lock(95125);")
	# Diagnostic barriers only; normal runner timeouts remain unchanged.
	var budgets: String=" options='-c statement_timeout=10000 -c lock_timeout=8000 -c idle_in_transaction_session_timeout=10000'"
	var ready:=Semaphore.new()
	var buyer:=Thread.new()
	assert(buyer.start(race_worker.bind(connection+" application_name=retry-order-buyer"+budgets,[80020,"place",request("buy",5,10,1,"reselect-buyer","beast_hide"),{8002:31}],ready))==OK)
	ready.wait()
	var buyer_waiting: bool=await order_retry_waiting("retry-order-buyer")
	var editor:=Thread.new()
	assert(editor.start(race_worker.bind(connection+" application_name=retry-order-editor"+budgets,[80000,"cancel",["reselect-cancel",maker.order_id,0],{}],ready))==OK)
	ready.wait()
	var editor_waiting: bool=await order_retry_waiting("retry-order-editor")
	execute(true,"SELECT pg_advisory_unlock(95125);")
	var bought: Dictionary=buyer.wait_to_finish()
	var cancelled: Dictionary=editor.wait_to_finish()
	clear_order_retry("exchange_fills")
	assert(buyer_waiting and editor_waiting and cancelled.result.ok and cancelled.result.refunded==5)
	assert(bought.result.ok and bought.result.remaining==5 and bought.committed and order_retry_attempts()==1,"retry must reacquire the pair and reselect makers after the earlier cancellation")
	assert(rows(true,"SELECT * FROM economy.exchange_fills WHERE maker_id='"+maker.order_id+"';").is_empty())
	assert(store.receipt(80020,"reselect-buyer")==bought.result)
	assert(store.cancel_order(80020,"clear-reselect",bought.result.order_id,0,{}).ok)

func order_retry_waiting(label: String) -> bool:
	var deadline: int=Time.get_ticks_msec()+2000
	while Time.get_ticks_msec()<deadline:
		execute(true,"SELECT pg_stat_clear_snapshot();")
		if int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name=:label AND wait_event_type='Lock';",{"label":label}).rows[0].n)==1: return true
		await get_tree().create_timer(0.005).timeout
	return false

func retry_cancel_reselection() -> void:
	var store:=Orders.new(pg)
	var source: Dictionary=store.place_order(80020,request("buy",5,10,1,"reselect-cancel-source","beast_hide"),{})
	assert(source.ok and source.remaining==5)
	var balance: int=Wallet.new(pg).load_wallet(8002).balance
	execute(true,"ALTER SEQUENCE economy.fixture_order_attempt RESTART WITH 1;")
	execute(true,"CREATE TRIGGER fixture_retry BEFORE INSERT ON economy.market_commands FOR EACH ROW WHEN (current_setting('application_name')='retry-order-cancel') EXECUTE FUNCTION economy.fixture_order_retry('40P01','1','1','gate');")
	execute(true,"SELECT pg_advisory_lock(95125);")
	var budgets: String=" options='-c statement_timeout=10000 -c lock_timeout=8000 -c idle_in_transaction_session_timeout=10000'"
	var ready:=Semaphore.new()
	var canceller:=Thread.new()
	assert(canceller.start(race_worker.bind(connection+" application_name=retry-order-cancel"+budgets,[80020,"cancel",["reselect-refund",source.order_id,0],{8002:37}],ready))==OK)
	ready.wait()
	var cancel_waiting: bool=await order_retry_waiting("retry-order-cancel")
	var seller:=Thread.new()
	assert(seller.start(race_worker.bind(connection+" application_name=retry-order-fill"+budgets,[80000,"place",request("sell",5,10,1,"reselect-fill","beast_hide"),{}],ready))==OK)
	ready.wait()
	var seller_waiting: bool=await order_retry_waiting("retry-order-fill")
	execute(true,"SELECT pg_advisory_unlock(95125);")
	var cancelled: Dictionary=canceller.wait_to_finish()
	var sold: Dictionary=seller.wait_to_finish()
	clear_order_retry("market_commands")
	assert(cancel_waiting and seller_waiting and sold.result.ok and sold.result.remaining==0)
	assert(cancelled.result.error=="stale" and not cancelled.committed and order_retry_attempts()==1,"cancel retry must recheck revision after a queued fill, not refund a filled order")
	assert(Wallet.new(pg).load_wallet(8002).balance==balance-50 and Wallet.new(pg).load_wallet(8002).reserved_yang==0)
	assert(store.receipt(80020,"reselect-refund").error=="unknown_command")
