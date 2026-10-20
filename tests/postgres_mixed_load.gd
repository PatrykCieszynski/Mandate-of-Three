extends Node
## P4a: real bounded World runtimes/native transactions + production movement/AI.
## Session maps and arrival sources are synthetic; no connected-client capacity claim.
const Bootstrap = preload("res://source/server/world/database/postgres/economy_bootstrap_postgres.gd")
const Schema = preload("res://source/server/world/database/postgres/economy_schema_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const Identity = preload("res://source/server/world/database/postgres/identity_bootstrap_postgres.gd")
const SearchFixture = preload("res://tests/postgres_auction_search.gd")
const ShopCells = preload("res://source/common/gameplay/items/domain/shop_grid.gd")
const SOURCE_COUNT:=20 # 16 mutation accounts + four independent read sources.
const QUERY: Dictionary={"definition_id":"iron_sword","upgrade_min":0,"upgrade_max":9,"price_min":0,"price_max":9000000000000000,"affix_filters":[],"sort":"price_asc","cursor":"","limit":50}
const WRITE_RATES: Array[int]=[0,10,30,100]

class Histogram extends RefCounted:
	var buckets: Dictionary={}
	var count:=0
	var maximum:=0
	var total:=0
	func add(us: int) -> void:
		us=maxi(us,0);count+=1;total+=us;maximum=maxi(maximum,us)
		var bucket:=mini(100000,ceili(us/100.0))
		buckets[bucket]=int(buckets.get(bucket,0))+1
	func summary() -> Dictionary:
		var result: Dictionary={"samples":count,"max_ms":maximum/1000.0,"mean_ms":total/float(maxi(count,1))/1000.0,"bucket_ms":0.1}
		var keys:=buckets.keys();keys.sort()
		for p: int in [50,95,99]:
			var cumulative:=0
			result["p%d_ms" % p]=0.0
			for key: int in keys:
				cumulative+=int(buckets[key])
				if cumulative>=ceili(count*p/100.0): result["p%d_ms" % p]=key/10.0;break
		return result

class SimWorld extends WorldServer:
	var observe_poll: Callable
	func inventory_master_available() -> bool: return true # Fixture grants only.
	func _process(delta: float) -> void:
		var started:=Time.get_ticks_usec()
		super._process(delta)
		if observe_poll.is_valid(): observe_poll.call(Time.get_ticks_usec()-started)
class NoWireCombat extends CombatEndpoint3D:
	func _send_snapshot() -> void: pass # No synthetic peers passed to RPC transport.
class SimMap extends GameWorld3D:
	func _ready() -> void:
		_server=true;input_enabled=false;_build_arena()
		ground_loot.setup(self,services)
		combat_endpoint=NoWireCombat.new();combat_endpoint.services=services
		mob_system.setup(self,combat_endpoint,services);add_child(combat_endpoint)
		var entry:=MobSpawnEntry.new();entry.mob=MobDefinitions.resolve(&"wild_dog");entry.count=32
		mob_system.create_pack([entry],Vector3(-7,0,-7),3,6,12,0)
		for mob: MobActor3D in mob_system.mobs.values(): mob.proximity_aggro=false
	func _broadcast_snapshot() -> void: pass
class Tail extends Node:
	var record: Callable
	func _physics_process(_delta: float) -> void: record.call()

var pg: Object
var world:=SimWorld.new()
var simulation:=SimMap.new()
var bootstrap:=Bootstrap.new()
var actors: Array[Dictionary]=[]
var jobs: Dictionary={}
var views: Dictionary={}
var reports: Array=[]
var current: Dictionary={}
var histograms: Dictionary={}
var measuring:=false
var previous_tick:=0
var tick_started:=0
var serial:=0
var source_cursor:=0
var search_cursor:=0
var injected_income:=0
var faults:=false
var commit_armed:=false
var loss_armed:=false
var fault_ids: Array[String]=[]
var lost_ids: Array[String]=[]
var duration:=8
var repeats:=3
var directory: String
var initial_money:=0
var expected_uids: Array=[]
var metrics: Dictionary={}

func fail(message: String) -> void:
	push_error("POSTGRES_MIXED_LOAD_FAILED "+message);get_tree().quit(1)
func wait_for(predicate: Callable, seconds: int = 15) -> void:
	var due:=Time.get_ticks_msec()+seconds*1000
	while not predicate.call() and Time.get_ticks_msec()<due: await get_tree().process_frame
	assert(predicate.call(),"bounded mixed-load completion/drain")
func sample(key: String, us: int) -> void:
	if not measuring: return
	if not histograms.has(key): histograms[key]=Histogram.new()
	histograms[key].add(us)
func observe(pool: String, value: Dictionary) -> void:
	assert(value.queue_us>=0 and value.worker_us>=0 and value.delivery_us>=0)
	for key: String in ["queue_us","worker_us","delivery_us"]:
		sample(pool+":"+value.intent+":"+key,int(value[key]))
	if measuring: current.native_jobs+=1
func _physics_process(_delta: float) -> void:
	var now:=Time.get_ticks_usec()
	if previous_tick>0: sample("physics_gap",now-previous_tick)
	previous_tick=now;tick_started=now
	if measuring: current.physics_ticks+=1
	for peer: int in simulation.characters:
		var angle:=now/1000000.0+peer
		simulation.intentions[peer]={"direction":Vector2(sin(angle),cos(angle)),"time":Time.get_ticks_msec(),"sequence":0}
func tail() -> void: sample("physics_callback_span",Time.get_ticks_usec()-tick_started)
func count_error(category: String, reason: String) -> void:
	var key:=category+":"+reason
	current.errors[key]=int(current.errors.get(key,0))+1
func next_id() -> String:
	serial+=1;return "mixed-"+str(serial)
func ready(peer: int) -> bool:
	return world.inventory_runtime.mutations_allowed(peer) and world.wallet_runtime.settled(peer)
func finished(_peer: int, id: String, result: Dictionary) -> void:
	if not jobs.has(id): return
	var job: Dictionary=jobs[id]
	if faults and job.action=="buy" and result.get("ok",false) and loss_armed:
		loss_armed=false;lost_ids.append(id);current.lost_replies+=1
		job.recover=true;job.retry_at=Time.get_ticks_msec()+100
		return # Drop application delivery only, after runtime committed reconciliation.
	if id in lost_ids: assert(result.get("ok",false),"lost success recovered by original ID")
	if id in fault_ids and result.get("error","")=="unknown_command": current.failed_commits_recovered+=1
	if not result.get("ok",false) and result.get("error","") in ["outcome_unknown","storage","recovery_required"]:
		job.recover=true;job.retry_at=Time.get_ticks_msec()+100
		count_error("uncertain",str(result.error));return
	jobs.erase(id);job.actor.busy=false
	sample("operation_e2e",Time.get_ticks_usec()-int(job.scheduled_us))
	sample("operation:"+job.action,Time.get_ticks_usec()-int(job.admitted_us))
	if result.get("ok",false):
		sample("successful_e2e",Time.get_ticks_usec()-int(job.scheduled_us))
		current.completed+=1
		current.by_action[job.action]=int(current.by_action.get(job.action,0))+1
		var actor: Dictionary=job.actor
		match job.action:
			"list": actor.offer=result.offer_id;actor.shop=int(result.shop_id);actor.offer_revision=0;actor.step="edit"
			"edit": actor.offer_revision=int(result.revision);actor.step="cancel" if int(actor.cycles)%3==0 else "buy"
			"cancel": actor.step="list";actor.cycles+=1
			"buy": actor.step="claim_revenue"
			"claim_revenue":
				var old: int=actor.owner;actor.owner=actor.buyer;actor.buyer=old;actor.step="list";actor.cycles+=1
	else:
		current.terminal_rejected+=1;count_error("terminal",str(result.get("error","unknown")))
		assert(result.get("error","") in ["busy","stale","unavailable","revision","unknown_command","offer","participant_busy","participants_changed","closed"],"unexpected definitive error "+str(result))
func submit_actor(actor: Dictionary, scheduled: int) -> void:
	if actor.busy: current.source_busy+=1;return
	var peer: int=actor.owner
	var action: String=actor.step
	var body: Dictionary={}
	if actor.exchange:
		var active: Array=views.get(peer,{}).get("exchange",{}).get("orders",[]).filter(func(row: Dictionary)->bool:return row.status=="active")
		if active.is_empty():
			action="order";body={"have_asset":"upgrade_ore" if actor.sell else "yang","want_asset":"yang" if actor.sell else "upgrade_ore","quantity":1,"price_num":100,"price_den":1}
		else:
			action="cancel_order";body={"order_id":active[0].order_id,"revision":int(active[0].revision)}
	else:
		match action:
			"list":
				var found: Array=world.inventory_runtime.snapshot_for_peer(peer).get("items",[]).filter(func(item: Dictionary)->bool:return item.uid==actor.uid)
				if found.is_empty(): current.source_busy+=1;return
				body={"uid":actor.uid,"revision":int(found[0].revision),"position":0,"price":100}
			"edit": body={"offer_id":actor.offer,"revision":actor.offer_revision,"position":0,"price":101}
			"cancel": body={"offer_id":actor.offer,"revision":actor.offer_revision}
			"buy": peer=actor.buyer;body={"shop_id":actor.shop,"offer_id":actor.offer,"revision":actor.offer_revision,"price":101}
			"claim_revenue": pass
	if not ready(peer): current.source_busy+=1;return
	var id:=next_id()
	if faults and commit_armed and action=="list":
		commit_armed=false;id="mixed-fault-"+id;fault_ids.append(id)
	body.command_id=id
	var job: Dictionary={"actor":actor,"peer":peer,"action":action,"body":body,"scheduled_us":scheduled,"admitted_us":Time.get_ticks_usec(),"recover":false}
	jobs[id]=job;actor.busy=true
	var admitted: Dictionary=world.seller_runtime.submit(peer,action,body)
	if not admitted.queued:
		if id in fault_ids:
			fault_ids.erase(id);commit_armed=true # Admission rejection did not reach COMMIT.
		jobs.erase(id);actor.busy=false;current.admission_rejected+=1;count_error("admission",str(admitted.error))
	else: current.admitted+=1
func ask(scheduled: int) -> void:
	search_cursor=(search_cursor+1)%4
	var peer:=116+search_cursor
	var p: Dictionary=QUERY.duplicate(true)
	# Rotate broad/indexed one- and two-affix filters without arbitrary SQL.
	p.affix_filters=[] if serial%3==0 else ([{"stat_id":"monster_damage","minimum":15}] if serial%3==1 else [{"stat_id":"monster_damage","minimum":15},{"stat_id":"critical_chance","minimum":7}])
	current.search_offered+=1
	world.seller_runtime.auction.submit(peer,next_id(),p,func(result: Dictionary)->void:
		sample("search_e2e",Time.get_ticks_usec()-scheduled)
		if result.get("ok",false): current.search_completed+=1
		else: count_error("search",str(result.get("error","unknown"))),func()->bool:return world.inventory_runtime.mutations_allowed(peer))
func update_recovery() -> void:
	for id: String in jobs.keys():
		var job: Dictionary=jobs[id]
		if job.recover and Time.get_ticks_msec()>=int(job.retry_at):
			job.retry_at=Time.get_ticks_msec()+100
			world.seller_runtime.receipt(job.peer,id) # Lookup only; never re-execute/new ID.
func empty() -> bool:
	return jobs.is_empty() and world.seller_runtime.drained() and range(SOURCE_COUNT).all(func(i: int)->bool:return world.wallet_runtime.settled(100+i))
func audit() -> void:
	assert(pg.query("SELECT count(*) AS n FROM economy.item_instances i LEFT JOIN economy.item_custody c USING(uid) WHERE c.uid IS NULL;").rows[0].n==0)
	assert(pg.query("SELECT count(*) AS n FROM economy.item_instances;").rows[0].n==expected_uids.size())
	assert(pg.query("SELECT uid FROM economy.item_instances ORDER BY uid;",{},20000).rows.map(func(row: Dictionary)->String:return row.uid)==expected_uids)
	assert(pg.query("SELECT coalesce(sum(yang),0)::bigint AS n FROM (SELECT yang FROM economy.account_wallets UNION ALL SELECT yang FROM economy.account_shop_revenue) t;").rows[0].n==initial_money+injected_income)
	assert(pg.query("SELECT count(*) AS n FROM economy.account_wallets w WHERE reserved_yang<>coalesce((SELECT sum(reserved_amount) FROM economy.exchange_orders o WHERE o.account_id=w.account_id AND o.side='buy' AND o.status='active'),0);").rows[0].n==0)
	assert(pg.query("SELECT count(*) AS n FROM economy.exchange_assets a WHERE reserved<>coalesce((SELECT sum(reserved_amount) FROM economy.exchange_orders o WHERE o.account_id=a.account_id AND o.base_asset=a.asset_id AND o.side='sell' AND o.status='active'),0);").rows[0].n==0)
	assert(pg.query("SELECT coalesce(sum(free+reserved),0)::bigint AS n FROM economy.exchange_assets;").rows[0].n==2000)
	assert(pg.query("SELECT count(*) AS n FROM economy.shop_cells c LEFT JOIN economy.shop_offers o ON c.item_uid=o.item_uid WHERE o.offer_id IS NULL;").rows[0].n==0)
	var occupied: Dictionary={}
	var rows: Dictionary=pg.query("SELECT c.*,i.definition_id FROM economy.item_custody c JOIN economy.item_instances i USING(uid);",{},20000)
	assert(rows.ok and not rows.truncated)
	for row: Dictionary in rows.rows:
		var definition: ItemDefinition=ItemDefinitions.get_definition(StringName(row.definition_id))
		assert(definition!=null and row.location in ["bag","shop_escrow"])
		var cells: Array[int]=InventoryGrid.cells(int(row.position),definition.inventory_height) if row.location=="bag" else ShopCells.cells(int(row.position),definition.inventory_height)
		assert(not cells.is_empty())
		for cell: int in cells:
			var key: String=row.location+":"+str(row.owner_id if row.location=="bag" else row.shop_id)+":"+str(cell)
			assert(not occupied.has(key),"full item footprint overlap")
			occupied[key]=true
	var successful:=int(current.get("completed",0))
	for report: Dictionary in reports: successful+=int(report.completed)
	assert(pg.query("SELECT count(*) AS n FROM economy.market_commands WHERE command_id LIKE 'mixed-%' AND result_json::jsonb->>'ok'='true';").rows[0].n==successful,"successful stable IDs correspond to durable receipts exactly once")
func cohort(rate: int, repeat_index: int) -> void:
	await wait_for(empty)
	current={"target_writes_per_second":rate,"repeat":repeat_index,"offered":0,"admitted":0,"completed":0,"source_busy":0,"admission_rejected":0,"terminal_rejected":0,"search_offered":0,"search_completed":0,"native_jobs":0,"physics_ticks":0,"max_native_pending":0,"max_active_accounts":0,"errors":{},"by_action":{}}
	current.lost_replies=0;current.failed_commits_recovered=0
	commit_armed=faults and rate>0;loss_armed=faults and rate>0
	histograms.clear();previous_tick=0;measuring=true
	var started:=Time.get_ticks_usec();var next_write:=started;var next_search:=started
	var stop:=started+duration*1000000
	var next_income:=started+250000
	var first_action:=serial
	while Time.get_ticks_usec()<stop:
		var now:=Time.get_ticks_usec()
		# Open-loop offered arrivals; missed/source-busy attempts are counted, never
		# hidden by waiting for completion or growing a test-side command queue.
		while rate>0 and next_write<=now:
			current.offered+=1;source_cursor=(source_cursor+1)%actors.size()
			submit_actor(actors[source_cursor],next_write);next_write+=1000000/rate
		if rate>0 and next_search<=now: ask(next_search);next_search+=125000
		if rate>0 and next_income<=now:
			var income_peer:=100+(serial%16)
			if world.wallet_runtime.add_income(income_peer,1): injected_income+=1
			next_income+=250000
		update_recovery()
		var pending:=0
		for pool: RefCounted in bootstrap._pools.values(): pending+=pool.pending_count()
		current.max_native_pending=maxi(current.max_native_pending,pending)
		current.max_active_accounts=maxi(current.max_active_accounts,world.seller_runtime._active.size())
		assert(pending<=16 and world.seller_runtime._active.size()<=64)
		await get_tree().process_frame
	current.completed_in_window=current.completed
	current.arrival_seconds=(Time.get_ticks_usec()-started)/1000000.0
	# Keep recording terminal latency/ticks through bounded tail drain, separately
	# report achieved window throughput so the tail cannot inflate offered rate.
	var deadline:=Time.get_ticks_msec()+15000
	while not empty() and Time.get_ticks_msec()<deadline:
		update_recovery();await get_tree().process_frame
	assert(empty(),"no unresolved accepted economic intent may disappear")
	current.tail_seconds=(Time.get_ticks_usec()-stop)/1000000.0
	current.completed_per_second=current.completed_in_window/current.arrival_seconds
	assert(current.offered==current.source_busy+current.admission_rejected+current.admitted)
	assert(current.admitted==current.completed+current.terminal_rejected)
	current.search_errors=current.errors.keys().filter(func(key: String)->bool:return key.begins_with("search:")).reduce(func(sum: int,key: String)->int:return sum+int(current.errors[key]),0)
	assert(current.search_offered==current.search_completed+int(current.search_errors),"every independent search source gets a terminal result")
	if faults and rate>0:
		assert(not commit_armed and not loss_armed and current.failed_commits_recovered==1 and current.lost_replies==1,"both fault paths must execute and recover during every write cohort")
	current.last_operation_serial=serial;current.first_operation_serial=first_action
	for key: String in histograms: current[key]=histograms[key].summary()
	measuring=false
	assert(await world.flush_postgres_wallets())
	audit()
	reports.append(current.duplicate(true))
	print("POSTGRES_MIXED_LOAD_SAMPLE ",JSON.stringify(current))

func _ready() -> void:
	Engine.max_fps=60;Engine.physics_ticks_per_second=60
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	faults=OS.get_environment("MANDATE_PG_LOAD_FAULTS")=="1"
	directory=OS.get_environment("MANDATE_PG_FIXTURE_DIR")
	duration=int(OS.get_environment("MANDATE_PG_LOAD_SECONDS")) if OS.has_environment("MANDATE_PG_LOAD_SECONDS") else 8
	repeats=int(OS.get_environment("MANDATE_PG_LOAD_REPEATS")) if OS.has_environment("MANDATE_PG_LOAD_REPEATS") else 3
	assert(duration>=2 and duration<=1800 and repeats>=1 and repeats<=3)
	get_tree().create_timer(duration*repeats*WRITE_RATES.size()+180).timeout.connect(func()->void:get_tree().quit(1))
	call_deferred("run")
func run() -> void:
	pg=ClassDB.instantiate("GodotSociDatabase");assert(pg.open("postgresql",OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")) and Schema.ensure_schema(pg))
	if faults:
		assert(pg.execute("CREATE FUNCTION economy.fixture_mixed_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.command_id LIKE 'mixed-fault-%' THEN RAISE EXCEPTION 'mixed load commit fixture' USING ERRCODE='40001'; END IF; RETURN NEW; END; $$;").ok)
		assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_mixed_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_mixed_commit();").ok)
	var seed:=SearchFixture.new();seed.pg=pg;seed.benchmark();seed.free()
	world.database=WorldDatabase.new();add_child(world);world.add_child(world.database)
	assert(world.database.start_profile_database(directory+"/profiles.db"))
	var authority: String=pg.query("SELECT value FROM economy.meta WHERE key='economy_authority_id';").rows[0].value
	assert(await bootstrap.start_world(world,{"backend":"postgresql","connection_env":"MANDATE_PG_FIXTURE_CONNECTION","authority_id":authority,"queue_capacity":2}))
	world.observe_poll=func(us: int)->void:sample("world_poll_projection",us)
	for name: String in bootstrap._pools:
		bootstrap._pools[name].profiling_enabled=true
		bootstrap._pools[name].observation.connect(func(row: Dictionary)->void:observe(name,row))
	world.inventory_runtime.recovery_failed.connect(func(_peer: int,reason: String)->void:fail("initialization/reconciliation: "+reason))
	world.seller_runtime.finished.connect(finished)
	world.seller_runtime.snapshot_applied.connect(func(peer: int,snapshot: Dictionary)->void:views[peer]=snapshot)
	for i: int in SOURCE_COUNT:
		var account:=900+i;var character:=30000+i;var peer:=100+i;var token: String="mixed-token-"+str(i)
		assert(Identity.new(pg).bind(account,character).ok)
		assert(pg.execute("UPDATE economy.account_wallets SET yang=1000000 WHERE account_id=:account;",{"account":account}).ok)
		if i>=12 and i<16: assert(pg.execute("INSERT INTO economy.exchange_assets VALUES(:account,'upgrade_ore',:amount,0);",{"account":account,"amount":1000 if i%2==0 else 0}).ok)
		var context: Dictionary=Sessions.new(pg).install_verified_grant(Sessions.identity_from_verified_ticket(account,character,token),0).context
		var player:=PlayerResource.new();player.player_id=character;player.current_peer_id=peer
		world.connected_players[peer]=player;world.player_id_to_peer_id[character]=peer;world._session_tokens[peer]=token
		assert(world.inventory_runtime.attach(peer,context) and world.wallet_runtime.attach(peer,context))
		await wait_for(func()->bool:return ready(peer))
		if i<12 and i%2==0:
			var item: Dictionary=world.inventory_runtime.snapshot_for_peer(peer).items[0]
			actors.append({"owner":peer,"buyer":peer+1,"uid":item.uid,"step":"list","exchange":false,"cycles":0,"busy":false})
		elif i>=12 and i<16: actors.append({"owner":peer,"step":"order","exchange":true,"sell":i%2==0,"busy":false})
	initial_money=int(pg.query("SELECT sum(yang)::bigint AS n FROM economy.account_wallets;").rows[0].n)
	expected_uids=pg.query("SELECT uid FROM economy.item_instances ORDER BY uid;",{},20000).rows.map(func(row: Dictionary)->String:return row.uid)
	add_child(simulation)
	for peer: int in range(100,104):
		var body:=simulation._add_character(peer,"Load")
		body.position=Vector3(8+(peer%2)*2,0.1,8+(peer%3))
		simulation.intentions[peer]={"direction":Vector2.ZERO,"time":Time.get_ticks_msec(),"sequence":0}
	var probe:=Tail.new();probe.process_physics_priority=10000;probe.record=tail;add_child(probe)
	await get_tree().create_timer(1).timeout
	for repeat_index: int in repeats:
		for rate: int in WRITE_RATES: await cohort(rate,repeat_index+1)
	simulation.set_physics_process(false);simulation.combat_endpoint.set_physics_process(false)
	assert(await world.shutdown_economy())
	current={};audit();assert(bootstrap.status().stopped)
	world.connected_players.clear();assert(await world.database.shutdown_database())
	var report: Dictionary={"fixture":"same-host synthetic sessions, real World runtime and native PG","connected_clients":0,"mutation_accounts":16,"read_accounts":4,"moving_players":4,"mobs":simulation.mob_system.mobs.size(),"workers":Bootstrap.WORLD_POOLS,"queue_capacity_per_worker":2,"offers":10000,"cohorts":reports,"invariants":"PASS","native_workers_stopped":true,"injected_income":injected_income,"postgres_deadlocks":int(pg.query("SELECT deadlocks FROM pg_stat_database WHERE datname=current_database();").rows[0].deadlocks),"combat":false}
	if faults:
		for id: String in fault_ids:
			assert(pg.query("SELECT count(*) AS n FROM economy.market_commands WHERE command_id=:id;",{"id":id}).rows[0].n==0,"failed commit left no durable receipt")
		for id: String in lost_ids:
			assert(pg.query("SELECT count(*) AS n FROM economy.market_commands WHERE command_id=:id;",{"id":id}).rows[0].n==1,"lost reply recovered one committed receipt")
		report.faults={"failed_commit_ids":fault_ids,"lost_reply_ids":lost_ids,"recovery":"PASS"}
	FileAccess.open(directory+"/mixed-load.json",FileAccess.WRITE).store_string(JSON.stringify(report,"  "))
	pg.close();print("POSTGRES_MIXED_LOAD_OK");get_tree().quit()
