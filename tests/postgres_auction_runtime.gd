extends "res://tests/postgres_auction_search.gd"
## Actual PostgreSQL workers, existing World/Inventory owner, 10k indexed offers.
const SessionSchema = preload("res://source/server/world/database/postgres/inventory_session_schema_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Executor = preload("res://source/server/world/database/postgres/inventory_executor_postgres.gd")
const Inventory = preload("res://source/server/world/database/postgres/inventory_runtime_postgres.gd")
const SellerRuntime = preload("res://source/server/world/database/postgres/seller_runtime_postgres.gd")
var world:=FixtureWorld.new()
var pool: RefCounted
var reads: RefCounted
var answers: Dictionary={}
var boundary: DelayedRead
class DelayedRead extends RefCounted:
	var inner: RefCounted
	var hold_next:=false
	var held: Array=[]
	var release:=false
	var submitted:=0
	func _init(value: RefCounted) -> void: inner=value
	func submit_auction_search(context: Dictionary, payload: Dictionary) -> Dictionary:
		submitted+=1
		return inner.submit_auction_search(context,payload)
	func submit_seller(context: Dictionary, action: String, body: Dictionary, income: int = 0, token: String = "", captures: Dictionary = {}, participants: Array = []) -> Dictionary: return inner.submit_seller(context,action,body,income,token,captures,participants)
	func submit_seller_snapshot(context: Dictionary, exchange: bool = false) -> Dictionary: return inner.submit_seller_snapshot(context,exchange)
	func begin_drain() -> void: inner.begin_drain()
	func is_stopped() -> bool: return inner.is_stopped()
	func poll() -> Array:
		var result: Array=[]
		for event: Dictionary in inner.poll():
			if hold_next and event.intent=="auction_search": held.append(event);hold_next=false
			else: result.append(event)
		if release: result.append_array(held);held.clear();release=false
		return result
var ticks:=0
var gaps: Array[int]=[]
var previous_tick:=0
var measured:=false
var roundtrips: Array[int]=[]
class FixtureWorld extends WorldServer:
	func inventory_master_available() -> bool: return true
func _physics_process(_delta: float) -> void:
	ticks+=1
	var now:=Time.get_ticks_usec()
	if measured and previous_tick>0: gaps.append(now-previous_tick)
	previous_tick=now
func wait_for(predicate: Callable) -> void:
	var due:=Time.get_ticks_msec()+8000
	while not predicate.call() and Time.get_ticks_msec()<due: await get_tree().process_frame
	assert(predicate.call(),"bounded Auction runtime wait")
func ask(peer: int,id: String,payload: Dictionary) -> void:
	world.seller_runtime.auction.submit(peer,id,payload,func(result: Dictionary)->void:answers[id]=result,func()->bool:return world.inventory_runtime.mutations_allowed(peer))
class SyntheticContexts extends RefCounted:
	func context_for_peer(peer: int) -> Dictionary:
		return {"account_id":peer,"character":peer,"epoch":1,"session_fingerprint":"a".repeat(64)}
class SyntheticExecutor extends RefCounted:
	var submitted:=0
	func submit_auction_search(_context: Dictionary,_payload: Dictionary) -> Dictionary:
		submitted+=1;return {"queued":true,"ticket":submitted}
func admission_contract() -> void:
	var transport:=SyntheticExecutor.new()
	var scheduler:=preload("res://source/server/world/database/postgres/auction_runtime_postgres.gd").new(SyntheticContexts.new(),transport)
	var rejected: Dictionary={}
	for peer: int in range(1,66):
		scheduler.submit(peer,"bounded-"+str(peer),params(),func(result: Dictionary)->void:rejected[peer]=result,func()->bool:return true)
	assert(rejected.size()==1 and rejected[65].error=="rate_limited")
	scheduler.tick();scheduler.tick()
	assert(transport.submitted==1)
	for duplicate: int in 20: scheduler.submit(1,"bounded-1",{},func(_result: Dictionary)->void:assert(false),func()->bool:return true)
	assert(transport.submitted==1)
	scheduler.begin_drain()
	assert(not scheduler.drained() and rejected.size()==64)
	scheduler.consume({"ticket":1,"result":{"ok":true,"rows":[]}})
	assert(scheduler.drained() and rejected[1].ok)

func _ready() -> void:
	admission_contract()
	Engine.max_fps=120
	get_tree().create_timer(55).timeout.connect(func()->void:get_tree().quit(1))
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	connection=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and SessionSchema.ensure_schema(pg) and Schema.ensure_schema(pg))
	var contexts: Array=[]
	for index: int in 3:
		var account: int=9000+index
		var character: int=90000+index
		characters.append(character);accounts.append(account)
		assert(Wallet.new(pg).initialize_account(account).ok and Items.new(pg).bind_character(character,account))
		var token: String="auction-"+str(index)
		var grant: Dictionary=Sessions.new(pg).install_verified_grant(Sessions.identity_from_verified_ticket(account,character,token),0)
		assert(grant.ok);contexts.append(grant.context)
		var player:=PlayerResource.new()
		player.player_id=character;player.current_peer_id=(index+1)*100
		world.connected_players[player.current_peer_id]=player
		world.player_id_to_peer_id[character]=player.current_peer_id
		world._session_tokens[player.current_peer_id]=token
	seed_offers(true)
	benchmark() # Existing legal 500-shop/10k-offer fixture and backend observations.
	pool=Executor.new();reads=Executor.new()
	assert(pool.start(connection,2,2) and reads.start(connection,2,2))
	await wait_for(func()->bool:
		pool.poll();reads.poll();return pool.is_ready() and reads.is_ready())
	world.inventory_runtime=Inventory.new(world,pool)
	boundary=DelayedRead.new(reads)
	world.seller_runtime=SellerRuntime.new(world.inventory_runtime,boundary,null,false,false,true)
	var disposed_endpoint:=MarketEndpoint3D.new()
	var disposed_adapter:=preload("res://source/common/gameplay/world3d/endpoints/seller_postgres_adapter.gd").new(disposed_endpoint,world.seller_runtime)
	disposed_adapter.dispose();disposed_endpoint.free()
	assert(not disposed_adapter.admit_query(100,"disposed"))
	add_child(world)
	for index: int in 3: assert(world.inventory_runtime.attach((index+1)*100,contexts[index]))
	await wait_for(func()->bool:return [100,200,300].all(func(peer: int)->bool:return world.inventory_runtime.mutations_allowed(peer)))
	var p:=params();p.limit=50
	ask(100,"first",p)
	await wait_for(func()->bool:return answers.has("first"))
	assert(answers.first==Search.new(pg).search(p))
	var invalid:=p.duplicate(true);invalid.cursor="broken"
	ask(100,"invalid",invalid);assert(answers.invalid.error=="cursor")
	# Hold the caller account lock: active read remains native, another account's
	# seller command and physics must progress on the existing second worker.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9000 FOR NO KEY UPDATE;").ok)
	ask(100,"blocked",p)
	await wait_for(func()->bool:return int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name LIKE 'mandate-inventory-executor-%' AND wait_event_type='Lock';").rows[0].n)>0)
	for duplicate: int in 20: ask(100,"blocked",{})
	ask(200,"queued",p)
	var before: int=ticks
	var mutation: Dictionary={}
	world.seller_runtime.finished.connect(func(_peer: int,id: String,result: Dictionary)->void:
		if id=="unrelated": mutation.merge(result))
	assert(world.seller_runtime.submit(300,"configure",{"command_id":"unrelated","revision":0,"name":"Independent","status":"paused"}).queued)
	await wait_for(func()->bool:return not mutation.is_empty())
	assert(mutation.ok and ticks>before and not answers.has("blocked"))
	assert(pg.commit())
	await wait_for(func()->bool:return answers.has("blocked") and answers.has("queued") and world.seller_runtime.drained())
	assert(answers.blocked.ok and answers.queued.ok)
	# Deadline replies once but keeps the native slot reserved until completion.
	boundary.hold_next=true
	ask(100,"deadline",p)
	await wait_for(func()->bool:return not boundary.held.is_empty())
	await wait_for(func()->bool:return answers.has("deadline"))
	assert(answers.deadline.error=="timeout" and not world.seller_runtime.auction.drained())
	var submitted: int=boundary.submitted
	ask(100,"deadline",{}) # Same ID cannot acquire a second native slot.
	ask(200,"after-timeout",p)
	await get_tree().create_timer(0.05).timeout
	assert(boundary.submitted==submitted and not answers.has("after-timeout"))
	boundary.release=true
	await wait_for(func()->bool:return answers.has("after-timeout") and world.seller_runtime.auction.drained())
	assert(answers.deadline.error=="timeout" and answers["after-timeout"].ok)
	# Backend lock timeout rolls back only the read and leaves the worker usable.
	assert(pg.begin() and pg.execute("LOCK TABLE economy.shop_offers IN ACCESS EXCLUSIVE MODE;").ok)
	ask(100,"sql-failure",p)
	await wait_for(func()->bool:return answers.has("sql-failure"))
	assert(answers["sql-failure"].error=="storage" and pg.commit())
	ask(100,"sql-recovered",p)
	await wait_for(func()->bool:return answers.has("sql-recovered"))
	assert(answers["sql-recovered"].ok)
	# Session replacement must suppress old completion, even when SQL finishes.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9000 FOR NO KEY UPDATE;").ok)
	ask(100,"stale",p)
	await wait_for(func()->bool:return int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE wait_event_type='Lock' AND application_name LIKE 'mandate-inventory-executor-%';").rows[0].n)>0)
	world.inventory_runtime.detach(100)
	assert(pg.commit())
	await wait_for(func()->bool:return world.seller_runtime.auction.drained())
	assert(not answers.has("stale"))
	assert(world.inventory_runtime.attach(100,contexts[0]))
	await wait_for(func()->bool:return world.inventory_runtime.mutations_allowed(100))
	# Sustained sequential cohort: real worker round trip, World physics gaps.
	measured=true
	for sample: int in 30:
		var peer: int=100+(sample%3)*100
		p.affix_filters=[] if sample%3==0 else ([{"stat_id":"monster_damage","minimum":15}] if sample%3==1 else [{"stat_id":"monster_damage","minimum":15},{"stat_id":"critical_chance","minimum":7}])
		var id: String="load-"+str(sample)
		var started:=Time.get_ticks_usec()
		ask(peer,id,p)
		await wait_for(func()->bool:return answers.has(id))
		if answers[id].get("error","")=="rate_limited":
			await get_tree().create_timer(1.05).timeout
			id+="-retry";started=Time.get_ticks_usec();ask(peer,id,p)
			await wait_for(func()->bool:return answers.has(id))
		assert(answers[id].ok)
		roundtrips.append(Time.get_ticks_usec()-started)
	measured=false
	gaps.sort();roundtrips.sort()
	print("POSTGRES_AUCTION_RUNTIME_OBSERVATION ",JSON.stringify({"offers":10000,"reads":30,"worker_e2e_p50_ms":roundtrips[15]/1000.0,"worker_e2e_p95_ms":roundtrips[28]/1000.0,"physics_gap_p95_ms":gaps[int(gaps.size()*0.95)]/1000.0,"physics_gap_max_ms":gaps.back()/1000.0,"physics_samples":gaps.size(),"combat":false}))
	await get_tree().create_timer(1.05).timeout
	# Runtime context alone cannot authorize a revoked backend grant.
	assert(pg.execute("UPDATE economy.inventory_sessions SET phase='revoked' WHERE account_id=9000;").ok)
	ask(100,"revoked",p)
	await wait_for(func()->bool:return answers.has("revoked"))
	assert(answers.revoked.error=="stale_session")
	boundary.hold_next=true
	ask(200,"drain-active",p)
	await wait_for(func()->bool:return not boundary.held.is_empty())
	ask(300,"drain-queued",p)
	world.seller_runtime.begin_drain()
	await wait_for(func()->bool:return boundary.is_stopped())
	assert(answers["drain-queued"].error=="unavailable" and not world.seller_runtime.shutdown_complete())
	assert(world.seller_runtime.drain_status().public_reads_pending)
	boundary.release=true
	await wait_for(func()->bool:return world.seller_runtime.shutdown_complete())
	assert(answers["drain-active"].ok)
	pool.begin_drain()
	await wait_for(func()->bool:pool.poll();return pool.is_stopped())
	world.free();WorldServer.curr=null;pg.close()
	print("POSTGRES_AUCTION_RUNTIME_OK native bounded search, independent mutation, session fencing and 10k World observations")
	get_tree().quit()
