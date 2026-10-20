extends Node
const Schema = preload("res://source/server/world/database/postgres/inventory_session_schema_postgres.gd")
const Executor = preload("res://source/server/world/database/postgres/inventory_executor_postgres.gd")
const Inventory = preload("res://source/server/world/database/postgres/inventory_runtime_postgres.gd")
const SellerRuntime = preload("res://source/server/world/database/postgres/seller_runtime_postgres.gd")
const Seller = preload("res://source/server/world/database/postgres/shop_seller_postgres.gd")
const Claims = preload("res://source/server/world/database/postgres/account_claim_postgres.gd")
const ClaimSchema = preload("res://source/server/world/database/postgres/account_claim_schema_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const WalletStore = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
var pg: Object
var world:=FixtureWorld.new()
var pools: Array=[]
var answers: Array=[]
var facts: int=0
var ticks: int=0

class FixtureWorld extends WorldServer:
	func inventory_master_available() -> bool: return true # Seeded transport only.

class LostCompletion extends RefCounted:
	var inner: RefCounted
	var lose_next:=false
	var hold_next:=false
	var held: Array=[]
	var release_held:=false
	var fail_receipts:=false
	var after_snapshot: Callable
	var after_prepare: Callable
	func _init(value: RefCounted) -> void: inner=value
	func submit_seller(context: Dictionary, action: String, body: Dictionary, income: int = 0, token: String = "", captures: Dictionary = {}, participants: Array = []) -> Dictionary: return inner.submit_seller(context,action,body,income,token,captures,participants)
	func submit_seller_prepare(context: Dictionary, action: String, body: Dictionary) -> Dictionary: return inner.submit_seller_prepare(context,action,body)
	func submit_seller_visit(context: Dictionary, shop: int) -> Dictionary: return inner.submit_seller_visit(context,shop)
	func submit_seller_receipt(context: Dictionary, id: String) -> Dictionary: return inner.submit_seller_receipt(context,id)
	func submit_seller_snapshot(context: Dictionary, include_exchange: bool = false) -> Dictionary: return inner.submit_seller_snapshot(context,include_exchange)
	func begin_drain() -> void: inner.begin_drain()
	func is_stopped() -> bool: return inner.is_stopped()
	func poll() -> Array:
		var events: Array=inner.poll()
		for event: Dictionary in events:
			if lose_next and event.intent=="seller_execute" and event.result.get("ok",false):
				lose_next=false
				event.result={"ok":false,"error":"outcome_unknown","outcome_unknown":true}
				event.committed=false
			if event.intent=="seller_prepare" and after_prepare.is_valid():
				var prepare_callback:=after_prepare
				after_prepare=Callable()
				prepare_callback.call()
			if event.intent=="seller_snapshot" and after_snapshot.is_valid():
				var callback:=after_snapshot
				after_snapshot=Callable()
				callback.call()
			if fail_receipts and event.intent=="seller_receipt": event.result={"ok":false,"error":"storage"}
		var delivered: Array=[]
		for event: Dictionary in events:
			if hold_next and event.intent=="seller_execute" and event.result.get("ok",false):
				hold_next=false;held.append(event)
			else: delivered.append(event)
		if release_held:
			delivered.append_array(held);held.clear();release_held=false
		return delivered

func _physics_process(_delta: float) -> void: ticks+=1
func wait_for(predicate: Callable) -> void:
	var due: int=Time.get_ticks_msec()+8000
	while not predicate.call() and Time.get_ticks_msec()<due: await get_tree().process_frame
	assert(predicate.call(),"bounded seller runtime acceptance")

func bind(peer: int, character: int, token: String) -> void:
	var player:=PlayerResource.new()
	player.player_id=character
	player.current_peer_id=peer
	world.connected_players[peer]=player
	world.player_id_to_peer_id[character]=peer
	world._session_tokens[peer]=token

func grant(account: int, character: int, token: String, epoch: int) -> Dictionary:
	var result: Dictionary=Sessions.new(pg).install_verified_grant(Sessions.identity_from_verified_ticket(account,character,token),epoch)
	assert(result.ok,str(result))
	return result.context

func items(character: int) -> Array: return Items.new(pg).inventory(character).items
func result(id: String) -> Dictionary:
	var matches: Array=answers.filter(func(value: Dictionary) -> bool: return value.id==id)
	return {} if matches.is_empty() else matches.back().result

func ready(peer: int) -> bool: return world.inventory_runtime.mutations_allowed(peer)
func seed_item(character: int, definition: ItemDefinition, position: int) -> String:
	var item:=ItemInstance.create(definition,character,[])
	assert(pg.begin() and Items.new(pg).receive_item_in_transaction(item,position).ok and pg.commit())
	return item.uid

var projections: Dictionary={}
func submit(peer: int, action: String, id: String, payload: Dictionary) -> Dictionary:
	answers=answers.filter(func(row: Dictionary) -> bool: return row.id!=id)
	var body:=payload.duplicate(true)
	body.command_id=id
	assert(world.seller_runtime.submit(peer,action,body).queued)
	await wait_for(func() -> bool: return not result(id).is_empty())
	return result(id)

func list_payload(uid: String, revision: int = 0, position: int = 0, price: int = 100) -> Dictionary:
	return {"uid":uid,"revision":revision,"position":position,"price":price}
func seed_claim(character: int) -> String:
	var item:=ItemInstance.create(ItemDefinitions.UPGRADE_ORE,character,[])
	assert(pg.begin() and Claims.new(pg).receive_in_transaction(item).ok and pg.commit())
	return item.uid

const ExchangeSchema = preload("res://source/server/world/database/postgres/exchange_orders_schema_postgres.gd")
const Orders = preload("res://source/server/world/database/postgres/exchange_orders_postgres.gd")
const WalletRuntime = preload("res://source/server/world/database/postgres/wallet_runtime_postgres.gd")
func wallet_ready(peer: int) -> bool: return world.wallet_runtime.settled(peer)
func order_payload(side: String, amount: int, price: int) -> Dictionary:
	return {"have_asset":"yang" if side=="buy" else "upgrade_ore","want_asset":"upgrade_ore" if side=="buy" else "yang","quantity":amount,"price_num":price,"price_den":1}
func asset(peer: int) -> Dictionary: return projections[peer].exchange.assets.filter(func(row: Dictionary)->bool:return row.asset_id=="upgrade_ore")[0]
func order_view(peer: int, id: String) -> Dictionary: return projections[peer].exchange.orders.filter(func(row: Dictionary)->bool:return row.order_id==id)[0]
func wait_idle() -> void:
	await wait_for(func()->bool:return world.seller_runtime.drained() and [100,200,300].all(func(peer: int)->bool:return world.wallet_runtime.binding(9900+(peer/100-1)).get("peer",0)==0 or wallet_ready(peer)))
func _ready() -> void:
	Engine.max_fps=120
	get_tree().create_timer(50).timeout.connect(func()->void:get_tree().quit(1))
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var connection: String=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg) and ExchangeSchema.ensure_schema(pg))
	var contexts: Array=[]
	for index: int in 3:
		var account: int=9900+index
		assert(WalletStore.new(pg).initialize_account(account).ok and Items.new(pg).bind_character(account*10,account) and Items.new(pg).bind_character(account*10+1,account))
		assert(pg.execute("INSERT INTO economy.exchange_assets(account_id,asset_id,free) VALUES(:account,'upgrade_ore',:amount);",{"account":account,"amount":10 if index==0 else (8 if index==2 else 0)}).ok)
		contexts.append(grant(account,account*10,"matching-"+str(index),0))
		bind((index+1)*100,account*10,"matching-"+str(index))
	for index: int in 3:
		var pool:=Executor.new()
		assert(pool.start(connection,2,2))
		pools.append(pool)
	await wait_for(func()->bool:
		for pool: RefCounted in pools: pool.poll()
		return pools.all(func(pool: RefCounted)->bool:return pool.is_ready()))
	var boundary:=LostCompletion.new(pools[1])
	world.inventory_runtime=Inventory.new(world,pools[0])
	world.wallet_runtime=WalletRuntime.new(world,pools[2])
	world.seller_runtime=SellerRuntime.new(world.inventory_runtime,boundary,world.wallet_runtime,true,true)
	world.seller_runtime.finished.connect(func(peer: int,id: String,outcome: Dictionary)->void:answers.append({"peer":peer,"id":id,"result":outcome}))
	world.seller_runtime.committed.connect(func(_peer: int,_action: String)->void:facts+=1)
	world.seller_runtime.snapshot_applied.connect(func(peer: int,snapshot: Dictionary)->void:projections[peer]=snapshot)
	add_child(world)
	for index: int in 3:
		assert(world.inventory_runtime.attach((index+1)*100,contexts[index]) and world.wallet_runtime.attach((index+1)*100,contexts[index]))
	await wait_for(func()->bool:return [100,200,300].all(func(peer: int)->bool:return ready(peer) and wallet_ready(peer)))
	assert(Orders.new(pg).place_order(99000,dict_id(order_payload("sell",1,100),"bare"),{}).error=="session_required")
	assert(world.wallet_runtime.add_income(100,30) and world.wallet_runtime.add_income(200,800))
	var sell:=await submit(100,"order","sell",order_payload("sell",6,100))
	assert(sell.ok and asset(100).free==4 and asset(100).reserved==6 and world.wallet_runtime.snapshot(100).balance==1530)
	var buy:=await submit(200,"order","buy",order_payload("buy",4,120))
	assert(buy.ok and buy.remaining==0 and world.wallet_runtime.snapshot(200).balance==1900 and world.wallet_runtime.snapshot(100).balance==1930)
	assert(order_view(100,sell.order_id).remaining==2 and asset(200).free==4 and projections[100].exchange.yang==1930)
	var prior: int=facts
	assert(world.wallet_runtime.add_income(100,17))
	assert((await submit(200,"order","buy",order_payload("buy",4,120))).ok and facts==prior and world.wallet_runtime.snapshot(100).balance==1947)
	await wait_idle()
	# Same account lock must not become a global command/physics queue.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9900 FOR NO KEY UPDATE;").ok)
	assert(world.seller_runtime.submit(100,"cancel_order",dict_id({"order_id":sell.order_id,"revision":1},"cancel")).queued)
	var before: int=ticks
	assert((await submit(300,"configure","independent",{"revision":0,"name":"Independent","status":"paused"})).ok)
	assert(ticks>before and result("cancel").is_empty())
	assert(pg.commit())
	await wait_idle()
	assert(result("cancel").ok and asset(100).free==6 and asset(100).reserved==0)
	var resting:=await submit(200,"order","resting",order_payload("buy",3,50))
	assert(resting.ok and projections[200].exchange.reserved_yang==150)
	assert((await submit(200,"cancel_order","cancel-buy",{"order_id":resting.order_id,"revision":0})).ok and projections[200].exchange.reserved_yang==0)
	assert((await submit(100,"order","ask-a",order_payload("sell",2,80))).ok)
	assert((await submit(300,"order","ask-c",order_payload("sell",3,90))).ok)
	assert((await submit(200,"order","multi",order_payload("buy",4,100))).ok)
	assert(world.wallet_runtime.snapshot(200).balance==1560 and world.wallet_runtime.snapshot(100).balance==2107 and world.wallet_runtime.snapshot(300).balance==1680)
	assert(world.wallet_runtime.add_income(200,100))
	assert(pg.execute("CREATE FUNCTION economy.fixture_match_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'match commit fixture' USING ERRCODE='40001'; END; $$;").ok)
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_match_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_match_commit();").ok)
	assert((await submit(200,"order","failed",order_payload("buy",1,90))).error=="outcome_unknown")
	assert(world.seller_runtime.receipt(200,"failed").queued)
	await wait_idle()
	assert(result("failed").error=="unknown_command" and world.wallet_runtime.snapshot(200).balance==1660 and world.wallet_runtime.snapshot(300).balance==1680)
	assert(pg.execute("DROP TRIGGER fixture_match_commit ON economy.market_commands;").ok)
	assert((await submit(200,"order","failed",order_payload("buy",1,90))).ok and world.wallet_runtime.snapshot(200).balance==1570 and world.wallet_runtime.snapshot(300).balance==1770)
	# A maker arriving between discovery and execution cannot receive uncaptured money.
	boundary.after_prepare=func()->void:
		assert(pg.begin())
		assert(pg.execute("UPDATE economy.exchange_assets SET free=free-1,reserved=reserved+1 WHERE account_id=9900 AND asset_id='upgrade_ore';").ok)
		assert(pg.execute("INSERT INTO economy.exchange_orders(order_id,account_id,base_asset,quote_asset,side,quantity,remaining,price_num,price_den,reserved_amount,status) VALUES('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',9900,'upgrade_ore','yang','sell',1,1,70,1,1,'active');").ok and pg.commit())
	assert((await submit(200,"order","changed",order_payload("buy",1,70))).error=="participants_changed")
	assert(int(pg.query("SELECT COUNT(*) AS n FROM economy.market_commands WHERE command_id='changed';").rows[0].n)==0)
	assert((await submit(200,"order","changed",order_payload("buy",1,70))).ok and world.wallet_runtime.snapshot(200).balance==1500)
	# Durable offline orders settle without requiring an online session or RAM wallet.
	assert((await submit(300,"order","offline-ask",order_payload("sell",2,100))).ok)
	world.inventory_runtime.detach(300);world.wallet_runtime.detach(300)
	await wait_for(func()->bool:return world.wallet_runtime.binding(9902).is_empty())
	boundary.hold_next=true
	assert(world.seller_runtime.submit(200,"order",dict_id(order_payload("buy",2,100),"offline-buy")).queued)
	await wait_for(func()->bool:return not boundary.held.is_empty())
	assert(int(WalletStore.new(pg).load_wallet(9902).balance)==1970 and world.wallet_runtime.exchange_held(9902))
	var alt:=grant(9902,99021,"matching-alt",1)
	bind(301,99021,"matching-alt")
	assert(world.inventory_runtime.attach(301,alt) and world.wallet_runtime.attach(301,alt))
	await wait_for(func()->bool:return ready(301))
	assert(not wallet_ready(301) and world.wallet_runtime.snapshot(301).is_empty() and not world.wallet_runtime.add_income(301,10))
	boundary.release_held=true
	await wait_for(func()->bool:return world.seller_runtime.drained() and ready(301) and wallet_ready(301))
	assert(result("offline-buy").ok and world.wallet_runtime.snapshot(301).balance==1970)
	# Unknown success retains every capture until lookup; shutdown cannot discard it.
	boundary.lose_next=true;boundary.fail_receipts=true
	assert((await submit(200,"order","lost",order_payload("buy",3,100))).error=="outcome_unknown")
	world.seller_runtime.begin_drain()
	await wait_for(func()->bool:return world.seller_runtime.drain_status().pending[0].attempts>=3 and world.seller_runtime.drain_status().in_flight==0)
	assert(not world.seller_runtime.shutdown_complete() and world.wallet_runtime.exchange_held(9901))
	boundary.fail_receipts=false
	assert(world.seller_runtime.receipt(200,"lost").queued)
	await wait_for(func()->bool:return world.seller_runtime.drained() and wallet_ready(200))
	assert(result("lost").ok and projections[200].exchange.reserved_yang==300)
	assert(int(pg.query("SELECT SUM(free+reserved) AS n FROM economy.exchange_assets WHERE asset_id='upgrade_ore';").rows[0].n)==18)
	assert(int(pg.query("SELECT SUM(yang) AS n FROM economy.account_wallets;").rows[0].n)==5447)
	assert(await world.flush_postgres_wallets(true))
	pools[0].begin_drain()
	await wait_for(func()->bool:return pools.all(func(pool: RefCounted)->bool:return pool.is_stopped()))
	world.free();WorldServer.curr=null;pg.close()
	print("POSTGRES_MATCHING_RUNTIME_OK participant capture, price-time/partial fills, cancel, replay, COMMIT, offline settlement and drain")
	get_tree().quit()
func dict_id(body: Dictionary, id: String) -> Dictionary:
	var value:=body.duplicate(true);value.command_id=id;return value
