extends Node
var db:=SqliteSoci.new()
var store: WorldStoreSqlite
var exchange: ExchangeStoreSqlite
var persistence: WorldDatabase
var observed_accounts: Array[int] = []
var fact_wallets: Array[Dictionary]=[]
var items: ItemStoreSqlite
func request(side: String,amount: int,num: int,den: int,id: String) -> Dictionary:
	return {"command_id":id,"have_asset":"upgrade_ore" if side=="sell" else "yang","want_asset":"yang" if side=="sell" else "upgrade_ore","quantity":amount,"price_num":num,"price_den":den}
func seed_ore(owner: int,amount: int,id: String) -> void:
	var item:=ItemInstance.create(ItemDefinitions.UPGRADE_ORE,owner,[]);item.amount=amount
	assert(EconomyFixture.insert_item(items,item,0));assert(exchange.deposit(owner,id,item.uid,0,amount,"bag").ok)
func _ready() -> void:
	db.path="res://.godot/verification/exchange-orders.db";DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path));assert(db.open_db());WorldSchema.ensure_schema(db)
	store=WorldStoreSqlite.new(db)
	var a:=EconomyFixture.create_character(store,"maker",{"name":"Maker","skin":1})
	var b:=EconomyFixture.create_character(store,"buyer",{"name":"Buyer","skin":1})
	var c:=EconomyFixture.create_character(store,"second",{"name":"Second","skin":1})
	assert(MarketSearchSqlite.ensure_schema(db) and ExchangeStoreSqlite.ensure_ledger_schema(db))
	assert(db.query("CREATE TEMP TRIGGER fail_orders BEFORE INSERT ON meta WHEN NEW.value='22' BEGIN SELECT RAISE(ABORT,'order migration fault'); END;"))
	assert(not ExchangeStoreSqlite.ensure_orders_schema(db));assert(db.query("DROP TRIGGER fail_orders;"));assert(ExchangeStoreSqlite.ensure_orders_schema(db))
	items=ItemStoreSqlite.new(db);exchange=ExchangeStoreSqlite.new(db)
	persistence=WorldDatabase.new();add_child(persistence);persistence.db=db;persistence.store=store;persistence.item_store=items;persistence.wallet_store=WalletStoreSqlite.new(db);EconomyFixture.prepare(persistence)
	assert(persistence.load_wallet(a) and persistence.load_wallet(b));assert(persistence.add_yang(a,33) and persistence.add_yang(b,90))
	persistence.market_account_changed.connect(func(account: int) -> void:
		fact_wallets.append(persistence.runtime_wallets.duplicate(true))
		observed_accounts.append(account))
	seed_ore(a,100,"seed")
	var sell:=persistence.market_command(a,"order",request("sell",100,10,1,"sell"));assert(sell.ok and sell.remaining==100)
	assert(exchange.ledger(a).assets[0].free==0 and exchange.ledger(a).assets[0].reserved==100)
	var before_faults := observed_accounts.size()
	for fault: String in ["BEFORE UPDATE ON account_wallets","BEFORE INSERT ON exchange_orders","BEFORE UPDATE ON exchange_assets","BEFORE INSERT ON exchange_assets","BEFORE UPDATE ON exchange_orders","BEFORE INSERT ON exchange_fills","BEFORE INSERT ON market_commands"]:
		assert(db.query("CREATE TEMP TRIGGER fail_fill %s BEGIN SELECT RAISE(ABORT,'matching stage fault'); END;" % fault))
		assert(persistence.market_command(b,"order",request("buy",60,12,1,"buy60")).error=="storage")
		assert(exchange.ledger(a).assets[0].reserved==100 and exchange.ledger(b).assets[0].free==0)
		assert(persistence.wallet_balance(a)==1533 and persistence.wallet_balance(b)==1590,"failed settlement preserves newer pending incomes")
		assert(db.query("SELECT COUNT(*) AS n FROM exchange_fills;") and db.query_result[0].n==0)
		assert(observed_accounts.size() == before_faults, "rolled back Exchange work emits no committed fact")
		assert(db.query("DROP TRIGGER fail_fill;"))
	fact_wallets.clear()
	var operation := persistence.market_operation(b, "order", request("buy",60,12,1,"buy60"))
	var bought := operation.response()
	assert(operation.operation_id == "buy60" and operation.new_commit and not operation.receipt_replay)
	assert(store.resolve_account_id(a) in operation.changed_accounts and store.resolve_account_id(b) in operation.changed_accounts)
	assert(bought.ok and bought.remaining==0)
	for notification: Dictionary in fact_wallets:
		for state: Dictionary in bought.wallet_states:
			assert(notification[int(state.account_id)].wallet_state==state,"all settlement wallets reconcile before first Exchange account fact")
	assert(persistence.wallet_balance(b)==990 and persistence.wallet_balance(a)==2133,"maker 10 instead of limit 12; reserve difference is free, not burned")
	assert(persistence.wallet_available(b)==990 and exchange.ledger(b).assets[0].free==60 and exchange.ledger(a).assets[0].reserved==40)
	assert(persistence.market_command(c,"order",request("buy",40,10,1,"buy40")).ok)
	assert(exchange.ledger(a).assets[0].reserved==0 and exchange.ledger(c).assets[0].free==40)
	assert(persistence.market_command(a,"cancel_order",{"command_id":"stale_cancel","order_id":sell.order_id,"revision":0}).error=="stale")
	assert(persistence.add_yang(b,17))
	var before_replay := observed_accounts.size()
	var replay := persistence.market_operation(b, "order", request("buy",60,12,1,"buy60"))
	assert(replay.response().ok and not replay.new_commit and replay.receipt_replay and replay.changed_accounts.is_empty())
	assert(persistence.wallet_balance(b)==1007,"receipt does not reset newer RAM")
	assert(replay.response().wallet_states==bought.wallet_states,"Exchange retry retains original revision and consumed pending prefix")
	assert(observed_accounts.size() == before_replay, "Exchange replay emits no fresh account commit")
	assert(persistence.flush_wallet());persistence.release_wallet(a)
	seed_ore(a,50,"offline_seed")
	var offline:=persistence.market_command(a,"order",request("sell",50,8,1,"offline"));assert(offline.ok)
	assert(persistence.market_command(b,"order",request("buy",20,10,1,"offline20")).ok)
	assert(not persistence.runtime_wallets.has(store.resolve_account_id(a)) and exchange.ledger(a).yang==2693,"offline maker credited")
	var before:=exchange.ledger(a)
	for fault: String in ["BEFORE UPDATE ON exchange_assets","BEFORE UPDATE ON exchange_orders","BEFORE INSERT ON market_commands"]:
		assert(db.query("CREATE TEMP TRIGGER fail_cancel %s BEGIN SELECT RAISE(ABORT,'cancel stage fault'); END;" % fault))
		assert(persistence.market_command(a,"cancel_order",{"command_id":"cancel","order_id":offline.order_id,"revision":1}).error=="storage")
		assert(exchange.ledger(a)==before);assert(db.query("DROP TRIGGER fail_cancel;"))
	assert(persistence.market_command(a,"cancel_order",{"command_id":"cancel","order_id":offline.order_id,"revision":1}).refunded==30)
	assert(exchange.ledger(a).assets[0].free==30 and exchange.ledger(a).assets[0].reserved==0)
	# Price first, then monotonic sequence at identical exact rational price.
	var d:=EconomyFixture.create_character(store,"dear",{"name":"Dear","skin":1})
	seed_ore(a,20,"cheap_more");seed_ore(d,20,"dear_seed")
	var dear:=exchange.place_order(d,request("sell",20,11,1,"dear"),{})
	var cheap:=exchange.place_order(a,request("sell",20,9,1,"cheap"),{})
	assert(dear.ok and cheap.ok)
	assert(exchange.place_order(c,request("buy",20,12,1,"priority"),{}).ok)
	assert(db.query_with_bindings("SELECT remaining FROM exchange_orders WHERE order_id=?;",[cheap.order_id]) and db.query_result[0].remaining==0)
	assert(db.query_with_bindings("SELECT remaining FROM exchange_orders WHERE order_id=?;",[dear.order_id]) and db.query_result[0].remaining==20)
	var second:=exchange.place_order(a,request("sell",20,11,1,"second_equal"),{});assert(second.ok)
	assert(exchange.place_order(c,request("buy",10,11,1,"time_priority"),{}).ok)
	assert(db.query_with_bindings("SELECT remaining FROM exchange_orders WHERE order_id=?;",[dear.order_id]) and db.query_result[0].remaining==10)
	# Fractions use a common whole-item lot, no hidden float/rounding.
	assert(not ExchangeStoreSqlite.valid_order(request("buy",1,3,2,"badlot")))
	assert(not ExchangeStoreSqlite.valid_order(request("buy",9000000000000000,1000000000,1,"overflow")))
	assert(not ExchangeStoreSqlite.valid_order(request("buy",100,1000000001,1,"ratio_overflow")))
	assert(db.query("SELECT SUM(yang) AS total FROM account_wallets;") and int(db.query_result[0].total)==6140,"all Yang including committed pending income conserved")
	assert(db.query("SELECT SUM(free+reserved) AS total FROM exchange_assets;") and int(db.query_result[0].total)==190,"all declared material sources conserved")
	assert(db.query("PRAGMA foreign_key_check;") and db.query_result.is_empty())
	assert(db.close_db() and db.open_db() and ExchangeStoreSqlite.ensure_orders_schema(db))
	assert(exchange.place_order(b,request("buy",60,12,1,"buy60"),{}).order_id==bought.order_id)
	assert(exchange.orders_snapshot(a).orders.size()>0 and exchange.orders_snapshot(a).fills.size()>0)
	assert(db.query("SELECT COUNT(*) AS n FROM market_commands;"));var receipts_before:=int(db.query_result[0].n)
	for id: int in 256:
		assert(persistence.market_command(a,"cancel_order",{"command_id":"denied_%d" % id,"order_id":"%032x" % 999999,"revision":0}).error=="owner")
	assert(db.query("SELECT COUNT(*) AS n FROM market_commands;") and int(db.query_result[0].n)==receipts_before,"Exchange rejection spam cannot grow durable receipts")
	assert(persistence.market_command(a,"receipt",{"command_id":"denied_255"}).error=="owner","Shop receipt lookup shares Exchange negative response cache")
	assert(persistence.market_command(a,"cancel_order",{"command_id":"denied_255","order_id":"%032x" % 999998,"revision":0}).error=="command_conflict")
	print("EXCHANGE_ORDERS_OK exact maker price/refund, 60+40, price-time, offline, cancel/fill revision, fault rollback, pending RAM, int64 bounds, reopen")
	db.close_db();DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path));get_tree().quit()
