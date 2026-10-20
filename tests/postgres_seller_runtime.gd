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

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var connection: String=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg) and ClaimSchema.ensure_schema(pg))
	for account: int in [9800,9801]:
		assert(WalletStore.new(pg).initialize_account(account).ok)
		assert(Items.new(pg).bind_character(account*10,account) and Items.new(pg).bind_character(account*10+1,account))
	var sword:=seed_item(98000,ItemDefinitions.IRON_SWORD,0)
	var second:=seed_item(98000,ItemDefinitions.IRON_SWORD,2)
	var other:=seed_item(98010,ItemDefinitions.IRON_SWORD,0)
	var claim_uid:=seed_claim(98001)
	var a:=grant(9800,98000,"seller-a",0)
	var b:=grant(9801,98010,"seller-b",0)
	bind(100,98000,"seller-a")
	bind(200,98010,"seller-b")
	for index: int in 2:
		var pool:=Executor.new()
		assert(pool.start(connection,2,2))
		pools.append(pool)
	await wait_for(func() -> bool:
		for pool: RefCounted in pools: pool.poll()
		return pools.all(func(pool: RefCounted) -> bool: return pool.is_ready()))
	var boundary:=LostCompletion.new(pools[1])
	world.inventory_runtime=Inventory.new(world,pools[0])
	world.seller_runtime=SellerRuntime.new(world.inventory_runtime,boundary)
	world.seller_runtime.finished.connect(func(peer: int, id: String, outcome: Dictionary) -> void: answers.append({"peer":peer,"id":id,"result":outcome}))
	world.seller_runtime.committed.connect(func(_peer: int, _action: String) -> void: facts+=1)
	world.seller_runtime.snapshot_applied.connect(func(peer: int, snapshot: Dictionary) -> void:
		assert(ready(peer) and snapshot.ok)
		projections[peer]=snapshot)
	add_child(world)
	assert(world.inventory_runtime.attach(100,a) and world.inventory_runtime.attach(200,b))
	await wait_for(func() -> bool: return ready(100) and ready(200))
	assert(Seller.new(pg).list_item(98000,"bare",sword,0,0,100).error=="session_required")
	assert(Claims.new(pg).claim_item(98000,"bare-claim",claim_uid,0).error=="session_required")
	assert(world.seller_runtime.open(100).queued)
	await wait_for(func() -> bool: return projections.has(100) and world.seller_runtime.drained())
	assert(projections[100].claims.size()==1 and facts==0)
	assert((await submit(100,"configure","config",{"revision":0,"name":"Native seller","status":"paused"})).ok)
	assert(projections[100].name=="Native seller" and projections[100].status=="paused")
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9800 FOR NO KEY UPDATE;").ok)
	assert(world.seller_runtime.submit(100,"list",{"command_id":"blocked","uid":sword,"revision":0,"position":0,"price":100}).queued)
	var before: int=ticks
	assert((await submit(200,"list","independent",list_payload(other))).ok)
	assert(ticks>before and result("blocked").is_empty() and world.runtime_attack(98000)==-1)
	assert(pg.commit())
	await wait_for(func() -> bool: return result("blocked").get("ok",false))
	var offer: Dictionary=projections[100].offers[0]
	assert(offer.item.uid==sword and items(98000).size()==1)
	var prior: int=facts
	assert((await submit(100,"list","blocked",list_payload(sword))).ok and facts==prior)
	assert((await submit(100,"list","overlap",list_payload(second))).error=="occupied")
	assert((await submit(100,"edit","edit",{"offer_id":offer.offer_id,"revision":0,"position":3,"price":200})).ok)
	assert(projections[100].offers[0].position==3 and projections[100].offers[0].price==200)
	assert((await submit(100,"cancel","cancel",{"offer_id":offer.offer_id,"revision":1})).ok)
	assert(items(98000).any(func(row: Dictionary) -> bool: return row.uid==sword) and projections[100].offers.is_empty())
	assert((await submit(200,"claim","foreign",{"uid":claim_uid,"revision":0})).error=="owner")
	assert((await submit(100,"claim","claim",{"uid":claim_uid,"revision":0})).ok)
	assert(projections[100].claims.is_empty() and items(98000).any(func(row: Dictionary) -> bool: return row.uid==claim_uid and row.owner_character_id==98000))
	# Native deferred COMMIT rollback and explicit original-ID recovery.
	assert(pg.execute("CREATE FUNCTION economy.fixture_seller_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'seller commit fixture' USING ERRCODE='40001'; END; $$;").ok)
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_seller_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_seller_commit();").ok)
	assert((await submit(100,"list","failed",list_payload(second))).error=="outcome_unknown")
	assert(world.seller_runtime.receipt(100,"failed").queued)
	await wait_for(func() -> bool: return ready(100) and world.seller_runtime.drained())
	assert(result("failed").error=="unknown_command" and projections[100].offers.is_empty())
	assert(pg.execute("DROP TRIGGER fixture_seller_commit ON economy.market_commands;").ok)
	assert(pg.execute("CREATE SEQUENCE economy.fixture_seller_ack;").ok)
	assert(pg.execute("CREATE FUNCTION economy.fixture_seller_ack() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.phase='ready' AND nextval('economy.fixture_seller_ack')=1 THEN RAISE EXCEPTION 'seller ACK fixture' USING ERRCODE='40001'; END IF; RETURN NEW; END; $$;").ok)
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_seller_ack AFTER UPDATE ON economy.inventory_sessions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_seller_ack();").ok)
	assert((await submit(100,"list","failed",list_payload(second))).ok)
	assert(ready(100) and int(pg.query("SELECT last_value FROM economy.fixture_seller_ack;").rows[0].last_value)>=2)
	assert(pg.execute("DROP TRIGGER fixture_seller_ack ON economy.inventory_sessions;").ok)
	# Lost successful result; original issuer's receipt survives retirement and alt.
	offer=projections[100].offers[0]
	boundary.lose_next=true
	assert((await submit(100,"cancel","lost",{"offer_id":offer.offer_id,"revision":0})).error=="outcome_unknown")
	var alt:=grant(9800,98001,"seller-alt",1)
	world.inventory_runtime.detach(100)
	bind(101,98001,"seller-alt")
	assert(world.inventory_runtime.attach(101,alt))
	await wait_for(func() -> bool: return ready(101) and world.seller_runtime.drained())
	assert(items(98001).is_empty() and items(98000).any(func(row: Dictionary) -> bool: return row.uid==second))
	prior=facts
	assert(world.seller_runtime.receipt(101,"lost").queued)
	await wait_for(func() -> bool: return world.seller_runtime.drained() and ready(101))
	assert(result("lost").ok and facts==prior and items(98001).is_empty())
	# A cross-domain claim committed after the private projection was read must
	# invalidate/refresh it before publication alongside the current Inventory ACK.
	var external: Array[String]=[]
	boundary.after_snapshot=func() -> void:
		var uid:=seed_claim(98001)
		external.append(uid)
		assert(world.inventory_runtime.invalidate_item_state(Items.new(pg).inventory(98001).item_state))
	assert(world.seller_runtime.open(101).queued)
	await wait_for(func() -> bool: return world.seller_runtime.drained() and ready(101))
	assert(external.size()==1 and projections[101].claims.any(func(row: Dictionary)->bool:return row.uid==external[0]))
	# A refused mutation is not retained for execution after capacity returns.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9800 FOR NO KEY UPDATE;").ok)
	for index: int in 4: assert(pools[1].submit_seller_receipt(alt,"lost").queued)
	assert((await submit(200,"configure","full-pool",{"revision":int(projections[200].revision),"name":"Must not run later","status":"paused"})).error=="busy")
	assert(pg.commit())
	await wait_for(func() -> bool: return world.seller_runtime.drained() and ready(200))
	assert(projections[200].name!="Must not run later" and int(pg.query("SELECT COUNT(*) AS n FROM economy.market_commands WHERE command_id='full-pool';").rows[0].n)==0)
	assert(world.seller_runtime.submit(101,"buy",{}).error=="unsupported")
	assert(world.seller_runtime.open_exchange(101).error=="unsupported")
	assert(int(WalletStore.new(pg).load_wallet(9800).balance)==1500)
	assert(await world.flush_postgres_wallets(true))
	pools[0].begin_drain()
	await wait_for(func() -> bool: return pools.all(func(pool: RefCounted) -> bool: return pool.is_stopped()))
	world.free()
	WorldServer.curr=null
	pg.close()
	print("POSTGRES_SELLER_RUNTIME_OK seller/claim custody, snapshots before results, independent progress, COMMIT/replay/alt recovery and drain")
	get_tree().quit()
