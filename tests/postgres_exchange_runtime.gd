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

const Ledger = preload("res://source/server/world/database/postgres/exchange_ledger_postgres.gd")
const ExchangeSchema = preload("res://source/server/world/database/postgres/exchange_orders_schema_postgres.gd")
const Storage = preload("res://source/server/world/database/postgres/account_storage_postgres.gd")
func free_asset(peer: int) -> int:
	return int(projections[peer].exchange.assets.filter(func(row: Dictionary)->bool:return row.asset_id=="upgrade_ore")[0].free)
func deposit_payload(uid: String, revision: int, amount: int, source: String = "bag") -> Dictionary:
	return {"uid":uid,"revision":revision,"amount":amount,"source":source}
func ore(character: int, position: int) -> String:
	var item:=ItemInstance.create(ItemDefinitions.UPGRADE_ORE,character,[])
	item.amount=6
	assert(pg.begin() and Items.new(pg).receive_item_in_transaction(item,position).ok and pg.commit())
	return item.uid
func _ready() -> void:
	Engine.max_fps=120
	get_tree().create_timer(45).timeout.connect(func()->void:get_tree().quit(1))
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var connection: String=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg) and ExchangeSchema.ensure_schema(pg))
	for account: int in [9800,9801]:
		assert(WalletStore.new(pg).initialize_account(account).ok)
		assert(Items.new(pg).bind_character(account*10,account) and Items.new(pg).bind_character(account*10+1,account))
	var bag_ore:=ore(98000,0)
	var stored_ore:=ore(98000,1)
	var other:=ore(98010,0)
	assert(Storage.new(pg).transfer_command(98000,stored_ore,0,"inventory","storage",0,"seed-storage").ok)
	var a:=grant(9800,98000,"ledger-a",0)
	var b:=grant(9801,98010,"ledger-b",0)
	bind(100,98000,"ledger-a")
	bind(200,98010,"ledger-b")
	for index: int in 2:
		var pool:=Executor.new()
		assert(pool.start(connection,2,2))
		pools.append(pool)
	await wait_for(func()->bool:
		for pool: RefCounted in pools: pool.poll()
		return pools.all(func(pool: RefCounted)->bool:return pool.is_ready()))
	var boundary:=LostCompletion.new(pools[1])
	world.inventory_runtime=Inventory.new(world,pools[0])
	world.seller_runtime=SellerRuntime.new(world.inventory_runtime,boundary,null,true)
	world.seller_runtime.finished.connect(func(peer: int,id: String,outcome: Dictionary)->void:answers.append({"peer":peer,"id":id,"result":outcome}))
	world.seller_runtime.committed.connect(func(_peer: int,_action: String)->void:facts+=1)
	world.seller_runtime.snapshot_applied.connect(func(peer: int,snapshot: Dictionary)->void:
		assert(ready(peer) and snapshot.exchange.ledger_only)
		projections[peer]=snapshot)
	add_child(world)
	assert(world.inventory_runtime.attach(100,a) and world.inventory_runtime.attach(200,b))
	await wait_for(func()->bool:return ready(100) and ready(200))
	assert(Ledger.new(pg).deposit(98000,"bare",bag_ore,0,1,"bag").error=="session_required")
	assert(world.seller_runtime.open_exchange(100).queued)
	await wait_for(func()->bool:return world.seller_runtime.drained())
	assert(free_asset(100)==0 and facts==0)
	assert((await submit(200,"deposit","foreign",deposit_payload(bag_ore,0,1))).error=="owner")
	assert((await submit(100,"deposit","bag-deposit",deposit_payload(bag_ore,0,2))).ok)
	assert(free_asset(100)==2 and items(98000)[0].amount==4)
	var prior: int=facts
	assert((await submit(100,"deposit","bag-deposit",deposit_payload(bag_ore,0,2))).ok and facts==prior and free_asset(100)==2)
	assert((await submit(100,"deposit","bad-stack",deposit_payload(bag_ore,0,1))).error=="stale")
	assert((await submit(100,"deposit","storage-deposit",deposit_payload(stored_ore,1,3,"account_storage"))).ok)
	assert(free_asset(100)==5 and Storage.new(pg).snapshot(98000).items[0].amount==3)
	assert(world.inventory_runtime.snapshot_for_peer(100).storage.items[0].amount==3)
	var withdrawal: Dictionary={"asset_id":"upgrade_ore","amount":2,"destination":"bag"}
	var received:=await submit(100,"withdraw","withdraw-bag",withdrawal)
	assert(received.ok and items(98000).any(func(row: Dictionary)->bool:return row.uid==received.uid and row.amount==2) and free_asset(100)==3)
	var claimed:=await submit(100,"withdraw","withdraw-claim",{"asset_id":"upgrade_ore","amount":1,"destination":"claim"})
	assert(claimed.ok and projections[100].claims.any(func(row: Dictionary)->bool:return row.uid==claimed.uid) and free_asset(100)==2)
	assert((await submit(100,"withdraw","overspend",withdrawal)).ok and free_asset(100)==0)
	assert((await submit(100,"withdraw","empty",withdrawal)).error=="funds")
	# A blocked account does not block another account or physics.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9800 FOR NO KEY UPDATE;").ok)
	assert(world.seller_runtime.submit(100,"deposit",dict_with_id(deposit_payload(bag_ore,1,1),"blocked")).queued)
	var before: int=ticks
	assert((await submit(200,"deposit","independent",deposit_payload(other,0,1))).ok)
	assert(ticks>before and result("blocked").is_empty())
	assert(pg.commit())
	await wait_for(func()->bool:return world.seller_runtime.drained())
	assert(result("blocked").ok and free_asset(100)==1)
	# Real failed COMMIT: no partial consume or credit, read-only recovery first.
	assert(pg.execute("CREATE FUNCTION economy.fixture_exchange_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'ledger commit fixture' USING ERRCODE='40001'; END; $$;").ok)
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_exchange_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_exchange_commit();").ok)
	assert((await submit(100,"deposit","failed",deposit_payload(bag_ore,2,1))).error=="outcome_unknown")
	assert(world.seller_runtime.receipt(100,"failed").queued)
	await wait_for(func()->bool:return world.seller_runtime.drained())
	assert(result("failed").error=="unknown_command" and free_asset(100)==1)
	assert(pg.execute("DROP TRIGGER fixture_exchange_commit ON economy.market_commands;").ok)
	assert((await submit(100,"deposit","failed",deposit_payload(bag_ore,2,1))).ok and free_asset(100)==2)
	# Original withdrawal outcome survives RAM retirement and an account alt.
	boundary.lose_next=true
	assert((await submit(100,"withdraw","lost",withdrawal)).error=="outcome_unknown")
	world.inventory_runtime.detach(100)
	var alt:=grant(9800,98001,"ledger-alt",1)
	bind(101,98001,"ledger-alt")
	assert(world.inventory_runtime.attach(101,alt))
	await wait_for(func()->bool:return ready(101) and world.seller_runtime.drained())
	prior=facts
	assert(world.seller_runtime.receipt(101,"lost").queued)
	await wait_for(func()->bool:return world.seller_runtime.drained())
	assert(result("lost").ok and items(98001).is_empty() and facts==prior)
	assert(world.seller_runtime.receipt(200,"lost").queued)
	await wait_for(func()->bool:return world.seller_runtime.drained())
	assert(result("lost").error=="unknown_command")
	assert(world.seller_runtime.submit(101,"order",{}).error=="unsupported")
	var conserved: Dictionary=pg.query("SELECT COALESCE(SUM(i.amount),0) AS n FROM economy.item_instances i JOIN economy.characters c ON c.character_id=i.owner_character_id WHERE c.account_id=9800 AND i.definition_id='upgrade_ore';")
	assert(conserved.ok and int(conserved.rows[0].n)==12 and free_asset(101)==0)
	assert(int(WalletStore.new(pg).load_wallet(9800).balance)==1500)
	assert(await world.flush_postgres_wallets(true))
	pools[0].begin_drain()
	await wait_for(func()->bool:return pools.all(func(pool: RefCounted)->bool:return pool.is_stopped()))
	world.free();WorldServer.curr=null;pg.close()
	print("POSTGRES_EXCHANGE_RUNTIME_OK custody, Storage, current views, independent progress and COMMIT/alt recovery")
	get_tree().quit()
func dict_with_id(body: Dictionary, id: String) -> Dictionary:
	var value:=body.duplicate(true)
	value.command_id=id
	return value
