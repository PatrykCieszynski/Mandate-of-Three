extends Node
const Schema = preload("res://source/server/world/database/postgres/inventory_session_schema_postgres.gd")
const Executor = preload("res://source/server/world/database/postgres/inventory_executor_postgres.gd")
const Inventory = preload("res://source/server/world/database/postgres/inventory_runtime_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_runtime_postgres.gd")
const Npc = preload("res://source/server/world/database/postgres/npc_runtime_postgres.gd")
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
	func _init(value: RefCounted) -> void: inner=value
	func submit_npc(context: Dictionary, kind: String, id: String, body: Dictionary, income: int, token: String) -> Dictionary: return inner.submit_npc(context,kind,id,body,income,token)
	func submit_npc_receipt(context: Dictionary, issuer: int, kind: String, id: String) -> Dictionary: return inner.submit_npc_receipt(context,issuer,kind,id)
	func begin_drain() -> void: inner.begin_drain()
	func is_stopped() -> bool: return inner.is_stopped()
	func poll() -> Array:
		var events: Array=inner.poll()
		for event: Dictionary in events:
			if lose_next and event.intent=="npc_execute" and event.result.get("ok",false):
				lose_next=false
				event.result={"ok":false,"error":"outcome_unknown","outcome_unknown":true}
				event.committed=false
		return events

func _physics_process(_delta: float) -> void: ticks+=1
func wait_for(predicate: Callable) -> void:
	var due: int=Time.get_ticks_msec()+8000
	while not predicate.call() and Time.get_ticks_msec()<due: await get_tree().process_frame
	assert(predicate.call(),"bounded NPC runtime acceptance")

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

func balance(account: int) -> int: return int(WalletStore.new(pg).load_wallet(account).balance)
func items(character: int) -> Array: return Items.new(pg).inventory(character).items
func result(id: String) -> Dictionary:
	var matches: Array=answers.filter(func(value: Dictionary) -> bool: return value.id==id)
	return {} if matches.is_empty() else matches.back().result

func ready(peer: int) -> bool: return world.inventory_runtime.mutations_allowed(peer) and world.wallet_runtime.ready(peer)
func seed_item(character: int, definition: ItemDefinition, position: int) -> String:
	var item:=ItemInstance.create(definition,character,[])
	assert(pg.begin() and Items.new(pg).receive_item_in_transaction(item,position).ok and pg.commit())
	return item.uid

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var connection: String=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	for account: int in [9800,9801]:
		assert(WalletStore.new(pg).initialize_account(account).ok)
		assert(Items.new(pg).bind_character(account*10,account) and Items.new(pg).bind_character(account*10+1,account))
	assert(pg.execute("UPDATE economy.account_wallets SET yang=100;").ok)
	var sword:=seed_item(98000,ItemDefinitions.IRON_SWORD,0)
	seed_item(98000,ItemDefinitions.UPGRADE_ORE,2)
	var a:=grant(9800,98000,"npc-a",0)
	var b:=grant(9801,98010,"npc-b",0)
	bind(100,98000,"npc-a")
	bind(200,98010,"npc-b")
	for index: int in 3:
		var pool:=Executor.new()
		assert(pool.start(connection,2,2))
		pools.append(pool)
	await wait_for(func() -> bool:
		for pool: RefCounted in pools: pool.poll()
		return pools.all(func(pool: RefCounted) -> bool: return pool.is_ready()))
	var boundary:=LostCompletion.new(pools[2])
	world.inventory_runtime=Inventory.new(world,pools[0])
	world.wallet_runtime=Wallet.new(world,pools[1])
	world.npc_runtime=Npc.new(world.wallet_runtime,world.inventory_runtime,boundary)
	world.npc_runtime.finished.connect(func(peer: int, _kind: String, id: String, outcome: Dictionary) -> void: answers.append({"peer":peer,"id":id,"result":outcome}))
	world.npc_runtime.committed.connect(func(_peer: int, _kind: String) -> void: facts+=1)
	add_child(world)
	assert(world.inventory_runtime.attach(100,a) and world.inventory_runtime.attach(200,b))
	assert(world.wallet_runtime.attach(100,a) and world.wallet_runtime.attach(200,b))
	await wait_for(func() -> bool: return ready(100) and ready(200))
	var shop: ShopDefinition=ShopDefinitions.BLACKSMITH_WEAPONS.duplicate(true)
	shop.offers[0].price=100
	var offer: StringName=shop.offers[0].offer_id
	var recipe: UpgradeDefinition=UpgradeDefinitions.get_definition(&"basic_upgrade").duplicate(true)
	recipe.yang_cost=100
	assert(world.wallet_runtime.add_income(100,500) and world.wallet_runtime.add_income(200,200))
	# Full native capacity cannot retain a mutating request for later execution
	# after its NPC authorization expires. Rejected admission preserves the prefix.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9800 FOR NO KEY UPDATE;").ok)
	for index: int in 4: assert(pools[2].submit_npc_receipt(a,98000,"buy","capacity-probe-"+str(index)).queued)
	assert(world.npc_runtime.buy(200,"capacity",shop,offer,0).queued)
	await wait_for(func() -> bool: return not result("capacity").is_empty())
	assert(result("capacity").error=="busy" and balance(9801)==100 and items(98010).is_empty() and world.wallet_runtime.snapshot(200).balance==300)
	assert(pg.commit())
	await wait_for(func() -> bool: return pools[2].pending_count()==0)
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9800 FOR NO KEY UPDATE;").ok)
	assert(world.npc_runtime.buy(100,"buy-a",shop,offer,3).queued)
	assert(not world.wallet_runtime.add_income(100,1) and world.runtime_attack(98000)==-1)
	assert(not world.inventory_runtime.submit(100,"blocked-move","move",sword,0,5).queued)
	assert(world.npc_runtime.buy(200,"buy-b",shop,offer,0).queued)
	shop.offers[0].price=999999 # Accepted content must already be copied.
	var before: int=ticks
	await wait_for(func() -> bool: return result("buy-b").get("ok",false))
	assert(ticks>before and balance(9801)==200 and balance(9800)==100)
	assert(pg.commit())
	await wait_for(func() -> bool: return result("buy-a").get("ok",false))
	assert(balance(9800)==500 and items(98000).size()==3 and facts==2)
	shop.offers[0].price=100
	assert(world.wallet_runtime.add_income(100,50))
	assert(world.npc_runtime.buy(100,"occupied",shop,offer,0).queued)
	await wait_for(func() -> bool: return not result("occupied").is_empty())
	assert(not result("occupied").ok and balance(9800)==500 and world.wallet_runtime.snapshot(100).balance==550 and items(98000).size()==3)
	assert(world.npc_runtime.upgrade(100,"upgrade-a",recipe,sword,0).queued)
	await wait_for(func() -> bool: return result("upgrade-a").get("ok",false))
	assert(balance(9800)==450 and items(98000).size()==2 and items(98000).filter(func(row: Dictionary) -> bool: return row.uid==sword)[0].upgrade_level==1)
	# A real committed purchase loses its completion; receipt recovery consumes
	# only the captured token. Replaying again cannot consume later income.
	assert(pg.execute("CREATE SEQUENCE economy.fixture_npc_ack;").ok)
	assert(pg.execute("CREATE FUNCTION economy.fixture_npc_ack() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.account_id=9800 AND nextval('economy.fixture_npc_ack')=1 THEN RAISE EXCEPTION 'NPC projection ack' USING ERRCODE='40001'; END IF; RETURN NEW; END; $$;").ok)
	assert(pg.execute("CREATE TRIGGER fixture_npc_ack BEFORE UPDATE ON economy.inventory_sessions FOR EACH ROW EXECUTE FUNCTION economy.fixture_npc_ack();").ok)
	assert(world.wallet_runtime.add_income(100,25))
	boundary.lose_next=true
	assert(world.npc_runtime.buy(100,"lost-buy",shop,offer,6).queued)
	await wait_for(func() -> bool: return result("lost-buy").get("error","")=="outcome_unknown")
	assert(balance(9800)==375 and not ready(100))
	assert(world.npc_runtime.receipt(100,"buy","lost-buy").queued)
	await wait_for(func() -> bool: return result("lost-buy").get("ok",false))
	assert(int(pg.query("SELECT last_value FROM economy.fixture_npc_ack;").rows[0].last_value)>=2,"terminal response waits for repaired projection ACK")
	assert(pg.execute("DROP TRIGGER fixture_npc_ack ON economy.inventory_sessions;").ok)
	assert(world.wallet_runtime.snapshot(100).balance==375)
	var facts_before: int=facts
	assert(world.wallet_runtime.add_income(100,37))
	assert(world.npc_runtime.receipt(100,"buy","lost-buy").queued)
	await wait_for(func() -> bool: return ready(100))
	assert(balance(9800)==375 and world.wallet_runtime.snapshot(100).balance==412 and facts==facts_before)
	var ore:=seed_item(98000,ItemDefinitions.UPGRADE_ORE,2)
	assert(world.inventory_runtime.invalidate_item_state(Items.new(pg).inventory(98000).item_state))
	await wait_for(func() -> bool: return ready(100))
	var target: Dictionary=items(98000).filter(func(row: Dictionary) -> bool: return row.definition_id=="iron_sword" and row.upgrade_level==0)[0]
	assert(pg.execute("CREATE FUNCTION economy.fixture_npc_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'NPC commit fixture' USING ERRCODE='40001'; END; $$;").ok)
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_npc_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_npc_commit();").ok)
	assert(world.npc_runtime.upgrade(100,"failed-commit",recipe,target.uid,target.revision).queued)
	await wait_for(func() -> bool: return result("failed-commit").get("error","")=="outcome_unknown")
	assert(world.npc_runtime.receipt(100,"upgrade","failed-commit").queued)
	await wait_for(func() -> bool: return ready(100))
	assert(result("failed-commit").error=="unknown_command" and balance(9800)==375 and items(98000).any(func(row: Dictionary) -> bool: return row.uid==ore))
	assert(pg.execute("DROP TRIGGER fixture_npc_commit ON economy.market_commands;").ok)
	assert(world.npc_runtime.upgrade(100,"failed-commit",recipe,target.uid,target.revision).queued)
	await wait_for(func() -> bool: return result("failed-commit").get("ok",false))
	assert(balance(9800)==312 and not items(98000).any(func(row: Dictionary) -> bool: return row.uid==ore))
	# Same-account alt takeover resolves the OLD issuer's receipt without
	# executing that old body under a new character or publishing its inventory.
	assert(world.wallet_runtime.add_income(100,20))
	boundary.lose_next=true
	assert(world.npc_runtime.buy(100,"old-issuer",shop,offer,9).queued)
	await wait_for(func() -> bool: return result("old-issuer").get("error","")=="outcome_unknown")
	var alt:=grant(9800,98001,"npc-alt",1)
	world.inventory_runtime.detach(100)
	world.wallet_runtime.detach(100)
	bind(101,98001,"npc-alt")
	assert(world.inventory_runtime.attach(101,alt) and world.wallet_runtime.attach(101,alt))
	await wait_for(func() -> bool: return ready(101) and world.npc_runtime.drained())
	assert(balance(9800)==232 and world.wallet_runtime.snapshot(101).balance==232 and items(98001).is_empty())
	world.wallet_runtime.detach(100) # Late old disconnect cannot retire alt.
	assert(ready(101))
	# Vendor shares the SAME worker owner and Inventory/Wallet barriers. Preview
	# is read-only; a lost completion resolves the original random reward receipt.
	var vendor_books: Array=[]
	for index: int in 5: vendor_books.append(seed_item(98001,ItemDefinitions.BOOK_AURA,index))
	assert(world.inventory_runtime.invalidate_item_state(Items.new(pg).inventory(98001).item_state))
	await wait_for(func()->bool:return ready(101))
	var basket: Array=[]
	for uid: String in vendor_books: basket.append({"uid":uid,"revision":0,"amount":1})
	var vendor_before: Array=items(98001)
	var vendor_balance: int=balance(9800)
	var quoted: Dictionary=world.npc_runtime.quote(101,"map/npc","shop",basket)
	assert(quoted.ok and quoted.rewards.size()==1 and quoted.rewards[0].quantity==1 and not quoted.rewards[0].has("definition_id"))
	assert(items(98001)==vendor_before and balance(9800)==vendor_balance)
	assert(not world.npc_runtime.sell(101,"vendor-wrong",quoted.quote_id,"other-map/npc","shop").queued)
	boundary.lose_next=true
	assert(world.npc_runtime.sell(101,"vendor-lost",quoted.quote_id,"map/npc","shop").queued)
	assert(not world.inventory_runtime.submit(101,"vendor-blocked","move",vendor_books[0],0,10).queued)
	await wait_for(func()->bool:return result("vendor-lost").get("error","")=="outcome_unknown")
	assert(world.npc_runtime.receipt(101,"sell","vendor-lost").queued)
	await wait_for(func()->bool:return result("vendor-lost").get("ok",false) and ready(101))
	var vendor_result: Dictionary=result("vendor-lost")
	assert(vendor_result.rewards.size()==1 and items(98001).size()==1 and balance(9800)==vendor_balance)
	assert(world.npc_runtime.receipt(101,"sell","vendor-lost").queued)
	await wait_for(func()->bool:return ready(101))
	assert(result("vendor-lost").rewards==vendor_result.rewards and items(98001).size()==1)
	var remaining_book: Dictionary=items(98001)[0]
	var old_quote: Dictionary=world.npc_runtime.quote(101,"map/npc","shop",[{"uid":remaining_book.uid,"revision":remaining_book.revision,"amount":1}])
	assert(old_quote.ok)
	world.inventory_runtime.detach(101);world.wallet_runtime.detach(101)
	var relog:=grant(9800,98001,"vendor-relog",2)
	bind(102,98001,"vendor-relog")
	assert(world.inventory_runtime.attach(102,relog) and world.wallet_runtime.attach(102,relog))
	await wait_for(func()->bool:return ready(102))
	assert(not world.npc_runtime.sell(102,"retired-quote",old_quote.quote_id,"map/npc","shop").queued,"quote cannot cross session generation")
	assert(await world.flush_postgres_wallets(true))
	pools[0].begin_drain()
	await wait_for(func() -> bool: return pools.all(func(pool: RefCounted) -> bool: return pool.is_stopped()))
	world.free()
	WorldServer.curr=null
	pg.close()
	print("POSTGRES_NPC_RUNTIME_OK atomic item/material/Yang, captured prefix/replay, bounded progress, uncertain COMMIT/receipt recovery, alt fencing and drain")
	get_tree().quit()
