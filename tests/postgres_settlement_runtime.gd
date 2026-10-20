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
	var fail_receipts:=false
	var after_snapshot: Callable
	func _init(value: RefCounted) -> void: inner=value
	func submit_seller(context: Dictionary, action: String, body: Dictionary, income: int = 0, token: String = "") -> Dictionary: return inner.submit_seller(context,action,body,income,token)
	func submit_seller_visit(context: Dictionary, shop: int) -> Dictionary: return inner.submit_seller_visit(context,shop)
	func submit_seller_receipt(context: Dictionary, id: String) -> Dictionary: return inner.submit_seller_receipt(context,id)
	func submit_seller_snapshot(context: Dictionary) -> Dictionary: return inner.submit_seller_snapshot(context)
	func begin_drain() -> void: inner.begin_drain()
	func is_stopped() -> bool: return inner.is_stopped()
	func poll() -> Array:
		var events: Array=inner.poll()
		for event: Dictionary in events:
			if lose_next and event.intent=="seller_execute" and event.result.get("ok",false):
				lose_next=false
				event.result={"ok":false,"error":"outcome_unknown","outcome_unknown":true}
				event.committed=false
			if event.intent=="seller_snapshot" and after_snapshot.is_valid():
				var callback:=after_snapshot
				after_snapshot=Callable()
				callback.call()
			if fail_receipts and event.intent=="seller_receipt": event.result={"ok":false,"error":"storage"}
		return events

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

const Settlement = preload("res://source/server/world/database/postgres/shop_settlement_postgres.gd")
const WalletRuntime = preload("res://source/server/world/database/postgres/wallet_runtime_postgres.gd")

func wallet_ready(peer: int) -> bool: return world.wallet_runtime.settled(peer)
func purchase_payload(offer: Dictionary, shop: int) -> Dictionary:
	return {"shop_id":shop,"offer_id":offer.offer_id,"revision":int(offer.revision),"price":int(offer.price)}

func _ready() -> void:
	Engine.max_fps=120
	get_tree().create_timer(50).timeout.connect(func()->void:get_tree().quit(1))
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var connection: String=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg) and ClaimSchema.ensure_schema(pg))
	for account: int in [9800,9801]:
		assert(WalletStore.new(pg).initialize_account(account).ok)
		assert(Items.new(pg).bind_character(account*10,account) and Items.new(pg).bind_character(account*10+1,account))
	var sword:=seed_item(98000,ItemDefinitions.IRON_SWORD,0)
	var second:=seed_item(98000,ItemDefinitions.IRON_SWORD,2)
	var a:=grant(9800,98000,"settlement-a",0)
	var b:=grant(9801,98010,"settlement-b",0)
	bind(100,98000,"settlement-a")
	bind(200,98010,"settlement-b")
	for index: int in 3:
		var pool:=Executor.new()
		assert(pool.start(connection,2,2))
		pools.append(pool)
	await wait_for(func() -> bool:
		for pool: RefCounted in pools: pool.poll()
		return pools.all(func(pool: RefCounted) -> bool: return pool.is_ready()))
	var boundary:=LostCompletion.new(pools[1])
	world.inventory_runtime=Inventory.new(world,pools[0])
	world.wallet_runtime=WalletRuntime.new(world,pools[2])
	world.seller_runtime=SellerRuntime.new(world.inventory_runtime,boundary,world.wallet_runtime)
	world.seller_runtime.finished.connect(func(peer: int,id: String,outcome: Dictionary)->void:answers.append({"peer":peer,"id":id,"result":outcome}))
	world.seller_runtime.committed.connect(func(_peer: int,_action: String)->void:facts+=1)
	world.seller_runtime.snapshot_applied.connect(func(peer: int,snapshot: Dictionary)->void:projections[peer]=snapshot)
	add_child(world)
	assert(world.inventory_runtime.attach(100,a) and world.inventory_runtime.attach(200,b))
	assert(world.wallet_runtime.attach(100,a) and world.wallet_runtime.attach(200,b))
	await wait_for(func()->bool:return ready(100) and ready(200) and wallet_ready(100) and wallet_ready(200))
	assert((await submit(100,"configure","config",{"revision":0,"name":"Settlement seller","status":"active"})).ok)
	assert((await submit(100,"list","listing",list_payload(sword,0,0,2000))).ok)
	var offer: Dictionary=projections[100].offers[0]
	var shop: int=int(projections[100].shop_id)
	assert(Settlement.new(pg).purchase(98010,"bare",shop,offer.offer_id,0,2000,{}).error=="session_required")
	assert((await submit(100,"buy","self",purchase_payload(offer,shop))).error=="self_trade")
	assert((await submit(200,"buy","poor",purchase_payload(offer,shop))).error=="funds")
	assert(world.wallet_runtime.add_income(200,800))
	assert(int(WalletStore.new(pg).load_wallet(9801).balance)==1500)
	assert(world.seller_runtime.visit(200,shop).queued)
	await wait_for(func()->bool:return world.seller_runtime.drained())
	assert(answers.back().result.offers.size()==1 and not answers.back().result.has("claimable_yang") and answers.back().result.claims.is_empty())
	# Native successful COMMIT completion lost: capture retained until receipt.
	boundary.lose_next=true
	assert((await submit(200,"buy","purchase",purchase_payload(offer,shop))).error=="outcome_unknown")
	await wait_for(func()->bool:return world.seller_runtime.drained() and wallet_ready(200) and ready(100))
	assert(items(98010).size()==1 and items(98010)[0].uid==sword and items(98000).size()==1)
	assert(world.wallet_runtime.snapshot(200).balance==300 and int(WalletStore.new(pg).load_wallet(9801).balance)==300)
	assert(projections[100].offers.is_empty() and projections[100].claimable_yang=="2000")
	var prior: int=facts
	assert(world.wallet_runtime.add_income(200,37))
	assert((await submit(200,"buy","purchase",purchase_payload(offer,shop))).ok)
	assert(facts==prior and world.wallet_runtime.snapshot(200).balance==337 and int(WalletStore.new(pg).load_wallet(9801).balance)==300)
	# Receipt remains discoverable after a different character owns the account.
	world.inventory_runtime.detach(200)
	world.wallet_runtime.detach(200)
	var alt:=grant(9801,98011,"settlement-alt",1)
	bind(201,98011,"settlement-alt")
	assert(world.inventory_runtime.attach(201,alt) and world.wallet_runtime.attach(201,alt))
	await wait_for(func()->bool:return ready(201) and wallet_ready(201))
	assert(world.seller_runtime.receipt(201,"purchase").queued)
	await wait_for(func()->bool:return world.seller_runtime.drained() and wallet_ready(201))
	assert(result("purchase").ok and items(98011).is_empty() and items(98010).size()==1 and facts==prior)
	# Offline seller's durable proceeds and partial collection headroom including pending income.
	assert(pg.execute("UPDATE economy.account_wallets SET yang=:balance WHERE account_id=9800;",{"balance":WalletStore.MAX_YANG-100}).ok)
	# A fresh wallet projection is requested explicitly as an external-domain fence.
	var capture: Dictionary=world.wallet_runtime.reserve_npc(100,"fixture-reload")
	assert(not capture.is_empty())
	world.wallet_runtime.finish_npc(9800,"fixture-reload",{"ok":false})
	await wait_for(func()->bool:return wallet_ready(100))
	assert(world.wallet_runtime.add_income(100,30))
	assert((await submit(100,"claim_revenue","collect",{})).claimed==70)
	assert(world.wallet_runtime.snapshot(100).balance==WalletStore.MAX_YANG and Settlement.new(pg).revenue(9800).amount==1930)
	assert((await submit(100,"claim_revenue","collect-replay-full",{})).error=="wallet_full")
	prior=facts
	assert((await submit(100,"claim_revenue","collect",{})).claimed==70 and facts==prior)
	# Native deferred COMMIT failure is not evidence of a committed debit/item move.
	assert((await submit(100,"list","listing2",list_payload(second,0,0,100))).ok)
	var next_offer: Dictionary=projections[100].offers[0]
	assert(pg.execute("CREATE FUNCTION economy.fixture_settlement_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'settlement commit fixture' USING ERRCODE='40001'; END; $$;").ok)
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_settlement_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_settlement_commit();").ok)
	assert((await submit(201,"buy","failed",purchase_payload(next_offer,shop))).error=="outcome_unknown")
	assert(world.seller_runtime.receipt(201,"failed").queued)
	await wait_for(func()->bool:return world.seller_runtime.drained() and wallet_ready(201))
	assert(result("failed").error=="unknown_command" and items(98011).is_empty() and Settlement.new(pg).revenue(9800).amount==1930)
	assert(pg.execute("DROP TRIGGER fixture_settlement_commit ON economy.market_commands;").ok)
	assert((await submit(201,"buy","failed",purchase_payload(next_offer,shop))).ok)
	assert(world.wallet_runtime.snapshot(201).balance==237 and items(98011).size()==1)
	await wait_for(func()->bool:return world.seller_runtime.drained() and ready(100) and wallet_ready(100))
	# Account A's lock must not stall independent seller/physics progress.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9800 FOR NO KEY UPDATE;").ok)
	assert(world.seller_runtime.submit(100,"claim_revenue",{"command_id":"locked-collect"}).queued)
	var before: int=ticks
	assert((await submit(201,"configure","independent",{"revision":int(projections[201].revision),"name":"Independent","status":"paused"})).ok)
	assert(ticks>before and result("locked-collect").is_empty())
	assert(pg.commit())
	await wait_for(func()->bool:return world.seller_runtime.drained() and wallet_ready(100))
	assert(result("locked-collect").error=="wallet_full")
	# A wallet capture cannot be deferred as if it were pure item delivery.
	assert(pg.execute("UPDATE economy.account_wallets SET yang=:balance WHERE account_id=9800;",{"balance":WalletStore.MAX_YANG-50}).ok)
	capture=world.wallet_runtime.reserve_npc(100,"fixture-final-refresh")
	assert(not capture.is_empty())
	world.wallet_runtime.finish_npc(9800,"fixture-final-refresh",{"ok":false})
	await wait_for(func()->bool:return wallet_ready(100))
	assert(world.wallet_runtime.add_income(100,10))
	boundary.lose_next=true
	boundary.fail_receipts=true
	assert((await submit(100,"claim_revenue","drain-unknown",{})).error=="outcome_unknown")
	world.seller_runtime.begin_drain()
	await wait_for(func()->bool:
		var status: Dictionary=world.seller_runtime.drain_status()
		return not status.pending.is_empty() and status.pending[0].attempts>=3 and status.in_flight==0)
	assert(not world.seller_runtime.shutdown_complete() and not world.seller_runtime.drain_status().safe_to_stop)
	boundary.fail_receipts=false
	assert(world.seller_runtime.receipt(100,"drain-unknown").queued)
	await wait_for(func()->bool:return world.seller_runtime.drained() and wallet_ready(100))
	assert(result("drain-unknown").claimed==40 and world.wallet_runtime.snapshot(100).balance==WalletStore.MAX_YANG)
	assert(await world.flush_postgres_wallets(true))
	pools[0].begin_drain()
	await wait_for(func()->bool:return pools.all(func(pool: RefCounted)->bool:return pool.is_stopped()))
	world.free()
	WorldServer.curr=null
	pg.close()
	print("POSTGRES_SETTLEMENT_RUNTIME_OK pending income, lost COMMIT, replay/alt, partial proceeds, private refresh and drain")
	get_tree().quit()
