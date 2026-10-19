extends Node
const Schema = preload("res://source/server/world/database/postgres/inventory_session_schema_postgres.gd")
const Executor = preload("res://source/server/world/database/postgres/inventory_executor_postgres.gd")
const Inventory = preload("res://source/server/world/database/postgres/inventory_runtime_postgres.gd")
const StorageRuntime = preload("res://source/server/world/database/postgres/storage_runtime_postgres.gd")
const Storage = preload("res://source/server/world/database/postgres/account_storage_postgres.gd")
const StorageSchema = preload("res://source/server/world/database/postgres/storage_schema_postgres.gd")
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
	func submit_storage(context: Dictionary, id: String, body: Dictionary) -> Dictionary: return inner.submit_storage(context,id,body)
	func submit_storage_receipt(context: Dictionary, issuer: int, id: String) -> Dictionary: return inner.submit_storage_receipt(context,issuer,id)
	func begin_drain() -> void: inner.begin_drain()
	func is_stopped() -> bool: return inner.is_stopped()
	func poll() -> Array:
		var events: Array=inner.poll()
		for event: Dictionary in events:
			if lose_next and event.intent=="storage_execute" and event.result.get("ok",false):
				lose_next=false
				event.result={"ok":false,"error":"outcome_unknown","outcome_unknown":true}
				event.committed=false
		return events

func _physics_process(_delta: float) -> void: ticks+=1
func wait_for(predicate: Callable) -> void:
	var due: int=Time.get_ticks_msec()+8000
	while not predicate.call() and Time.get_ticks_msec()<due: await get_tree().process_frame
	assert(predicate.call(),"bounded Storage runtime acceptance")

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

func body(uid: String, revision: int, source: String, destination: String, position: int) -> Dictionary:
	return {"uid":uid,"revision":revision,"source":source,"destination":destination,"position":position}

func submit(peer: int, id: String, payload: Dictionary) -> Dictionary:
	answers=answers.filter(func(row: Dictionary) -> bool: return row.id!=id)
	assert(world.storage_runtime.transfer(peer,id,payload).queued)
	await wait_for(func() -> bool: return not result(id).is_empty())
	return result(id)

func stored(character: int) -> Array: return Storage.new(pg).snapshot(character).items

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var connection: String=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg) and StorageSchema.ensure_schema(pg))
	for account: int in [9800,9801]:
		assert(WalletStore.new(pg).initialize_account(account).ok)
		assert(Items.new(pg).bind_character(account*10,account) and Items.new(pg).bind_character(account*10+1,account))
	var sword:=seed_item(98000,ItemDefinitions.IRON_SWORD,0)
	var other:=seed_item(98010,ItemDefinitions.IRON_SWORD,0)
	var second:=seed_item(98000,ItemDefinitions.IRON_SWORD,2)
	var a:=grant(9800,98000,"storage-a",0)
	var b:=grant(9801,98010,"storage-b",0)
	bind(100,98000,"storage-a")
	bind(200,98010,"storage-b")
	for index: int in 2:
		var pool:=Executor.new()
		assert(pool.start(connection,2,1))
		pools.append(pool)
	await wait_for(func() -> bool:
		for pool: RefCounted in pools: pool.poll()
		return pools.all(func(pool: RefCounted) -> bool: return pool.is_ready()))
	var boundary:=LostCompletion.new(pools[1])
	world.inventory_runtime=Inventory.new(world,pools[0])
	world.storage_runtime=StorageRuntime.new(world.inventory_runtime,boundary)
	world.storage_runtime.finished.connect(func(peer: int, id: String, outcome: Dictionary) -> void: answers.append({"peer":peer,"id":id,"result":outcome}))
	world.storage_runtime.committed.connect(func(_peer: int) -> void: facts+=1)
	add_child(world)
	assert(world.inventory_runtime.attach(100,a) and world.inventory_runtime.attach(200,b))
	await wait_for(func() -> bool: return ready(100) and ready(200))
	assert(world.inventory_runtime.snapshot_for_peer(100).storage.ok)
	# Legacy bare writes cannot bypass a registered session fence.
	assert(Storage.new(pg).transfer_command(98000,sword,0,"inventory","storage",0,"bare").error=="session_required")
	# Account A waits in SQL while unrelated B and physics make progress.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9800 FOR NO KEY UPDATE;").ok)
	assert(world.storage_runtime.transfer(100,"blocked",body(sword,0,"inventory","storage",0)).queued)
	var before: int=ticks
	assert((await submit(200,"independent",body(other,0,"inventory","storage",0))).ok)
	assert(ticks>before and result("blocked").is_empty() and world.runtime_attack(98000)==-1)
	assert(pg.commit())
	await wait_for(func() -> bool: return result("blocked").get("ok",false))
	assert(stored(98000).size()==1 and items(98000).size()==1)
	assert(world.inventory_runtime.snapshot_for_peer(100).storage.items[0].uid==sword)
	# Saturation is a volatile refusal, not an invisible later mutation.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9800 FOR NO KEY UPDATE;").ok)
	assert(pools[1].submit_storage_receipt(a,98000,"blocked").queued)
	assert(pools[1].submit_storage_receipt(a,98000,"blocked").queued)
	assert((await submit(200,"capacity",body(other,1,"storage","storage",3))).error=="busy")
	assert(stored(98010)[0].bag_position==0 and ready(200))
	assert(pg.commit())
	await wait_for(func() -> bool: return pools[1].pending_count()==0)
	# Different starting cells still overlap the complete 1x2 footprint.
	assert((await submit(100,"overlap",body(second,0,"inventory","storage",15))).error=="occupied")
	assert((await submit(100,"bounds",body(second,0,"inventory","storage",134))).error=="occupied")
	assert((await submit(200,"foreign",body(sword,1,"storage","inventory",-1))).error=="owner")
	var prior: int=facts
	assert(world.storage_runtime.receipt(100,"blocked").queued)
	await wait_for(func() -> bool: return ready(100) and world.storage_runtime.drained())
	assert(facts==prior and stored(98000).size()==1)
	assert((await submit(100,"blocked",body(second,0,"inventory","storage",1))).error=="command_conflict")
	assert((await submit(100,"withdraw",body(sword,1,"storage","inventory",0))).ok)
	# Native COMMIT fails after mutation/receipt statements; everything rolls back.
	assert(pg.execute("CREATE FUNCTION economy.fixture_storage_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage commit fixture' USING ERRCODE='40001'; END; $$;").ok)
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_storage_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_storage_commit();").ok)
	var payload:=body(sword,2,"inventory","storage",0)
	assert((await submit(100,"failed-commit",payload)).error=="outcome_unknown")
	assert(world.storage_runtime.receipt(100,"failed-commit").queued)
	await wait_for(func() -> bool: return ready(100) and world.storage_runtime.drained())
	assert(result("failed-commit").error=="unknown_command" and stored(98000).is_empty())
	assert(pg.execute("DROP TRIGGER fixture_storage_commit ON economy.market_commands;").ok)
	# A failed projection readiness ACK is repaired before the terminal response.
	assert(pg.execute("CREATE SEQUENCE economy.fixture_storage_ack;").ok)
	assert(pg.execute("CREATE FUNCTION economy.fixture_storage_ack() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.phase='ready' AND nextval('economy.fixture_storage_ack')=1 THEN RAISE EXCEPTION 'storage ACK fixture' USING ERRCODE='40001'; END IF; RETURN NEW; END; $$;").ok)
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_storage_ack AFTER UPDATE ON economy.inventory_sessions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_storage_ack();").ok)
	assert((await submit(100,"failed-commit",payload)).ok)
	assert(int(pg.query("SELECT last_value FROM economy.fixture_storage_ack;").rows[0].last_value)>=2 and ready(100))
	assert(pg.execute("DROP TRIGGER fixture_storage_ack ON economy.inventory_sessions;").ok)
	assert((await submit(100,"shared-for-alt",body(second,0,"inventory","storage",3))).ok)
	# Lost successful completion + replacement alt: resolve old issuer, not new bag.
	boundary.lose_next=true
	assert((await submit(100,"old-issuer",body(sword,3,"storage","inventory",0))).error=="outcome_unknown")
	var alt:=grant(9800,98001,"storage-alt",1)
	world.inventory_runtime.detach(100)
	bind(101,98001,"storage-alt")
	assert(world.inventory_runtime.attach(101,alt))
	await wait_for(func() -> bool: return ready(101) and world.storage_runtime.drained())
	assert(items(98001).is_empty() and stored(98001).size()==1 and items(98000).size()==1)
	assert(world.inventory_runtime.snapshot_for_peer(101).storage.items[0].uid==second)
	world.inventory_runtime.detach(100)
	assert(ready(101))
	assert((await submit(101,"alt-withdraw",body(second,1,"storage","inventory",0))).ok)
	assert(items(98001)[0].uid==second and items(98001)[0].owner_character_id==98001 and stored(98001).is_empty())
	# Account B can rearrange and withdraw independently.
	assert((await submit(200,"rearrange",body(other,1,"storage","storage",2))).ok)
	assert((await submit(200,"take-back",body(other,2,"storage","inventory",0))).ok)
	assert(await world.flush_postgres_wallets(true))
	pools[0].begin_drain()
	await wait_for(func() -> bool: return pools.all(func(pool: RefCounted) -> bool: return pool.is_stopped()))
	world.free()
	WorldServer.curr=null
	pg.close()
	print("POSTGRES_STORAGE_RUNTIME_OK account custody/footprint/session fences, independent progress, COMMIT/receipt/alt recovery, projection and drain")
	get_tree().quit()
