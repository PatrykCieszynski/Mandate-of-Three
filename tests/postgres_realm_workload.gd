extends Node
## Player-paced stories, distinct from the adversarial mixed-load case.
const Support = preload("res://tests/support/postgres_workload_support.gd")
const Bootstrap = preload("res://source/server/world/database/postgres/economy_bootstrap_postgres.gd")
const Schema = preload("res://source/server/world/database/postgres/economy_schema_postgres.gd")
const Identity = preload("res://source/server/world/database/postgres/identity_bootstrap_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Catalogue = preload("res://tests/postgres_auction_search.gd")
const ROLE_WEIGHTS: Dictionary={"farmer":60.0,"passive":20.0,"browser":10.0,"trader":6.7,"power_trader":3.3}
const TRANSIENT: Array[String]=["storage","outcome_unknown","recovery_required","operation_pending","busy","unavailable"]
const CONFLICTS: Array[String]=["offer","revision","stale","closed","occupied","bag_full","capacity","nothing_to_claim","participants_changed","participant_busy","unknown_command","funds","distance","reserved","gone","claimed","transfer_pending"]
const SEARCH: Dictionary={"definition_id":"iron_sword","upgrade_min":0,"upgrade_max":9,"price_min":0,"price_max":9000000000000000,"affix_filters":[],"sort":"price_asc","cursor":"","limit":5}

class RealmMap extends Support.SimMap:
	var span:=32.0
	func _ready() -> void:
		var target:=extra_mobs;extra_mobs=0
		super._ready();extra_mobs=target
		var groups:=ceili(target/6.0);var columns:=ceili(sqrt(groups))
		for index: int in groups:
			var entry:=MobSpawnEntry.new();entry.mob=MobDefinitions.resolve(&"wild_dog");entry.count=mini(6,target-index*6)
			var anchor:=Vector3((index%columns-(columns-1)/2.0)*6,0,(index/columns-(columns-1)/2.0)*6)
			mob_system.create_pack([entry],anchor,1.0,3.0,9.0,0)
		for mob: MobActor3D in mob_system.mobs.values(): mob.proximity_aggro=false
	func _build_arena() -> void:
		_box("RealmFloor",Vector3(0,-0.25,0),Vector3(span,0.5,span),Color("374957"))

var world:=Support.SimWorld.new()
var simulation:=RealmMap.new()
var bootstrap:=Bootstrap.new()
var pg: Object
var actors: Array[Dictionary]=[]
var by_peer: Dictionary={}
var jobs: Dictionary={}
var views: Dictionary={}
var successful_ids: Dictionary={}
var expected_uids: Array=[]
var picked: Dictionary={}
var histograms: Dictionary={}
var errors: Dictionary={}
var role_counts: Dictionary={}
var requested_roles: Dictionary={}
var refused_actors: Array=[]
var connections: Dictionary={}
var native_jobs: Dictionary={}
var action_successes: Dictionary={}
var stats: Dictionary={"searches":0,"searches_ok":0,"attempts":0,"admitted":0,"completed":0,"conflicts":0,"admission_rejected":0,"admission_retries":0,"recoveries":0,"income_events":0,"income_deferred":0,"pending_income_buy_successes":0,"pending_income_applied_by_buys":0,"income":0,"ground_pickups":0,"rebinds":0,"stories_started":0,"stories_completed":0,"stories_failed":0,"physics_ticks":0,"max_native_pending":0}
var directory: String
var duration:=180
var requested:=24
var workload_seed:=1729
var serial:=0
var active_loops:=0
var window_open:=false
var running:=false
var measuring:=false
var failed:=false
var previous_tick:=0
var tick_started:=0
var initial_money:=0
var material_total:=0
var memory_samples: Array=[]
var trace: FileAccess

func die(message: String) -> void:
	failed=true;push_error("POSTGRES_REALM_WORKLOAD_FAILED "+message);get_tree().quit(1)
func sample(key: String, us: int) -> void:
	if not measuring: return
	if not histograms.has(key): histograms[key]=Support.Histogram.new(0)
	histograms[key].add(us)
func event(actor: Dictionary, action: String, detail: Dictionary = {}) -> void:
	actor.events+=1
	trace.store_line(JSON.stringify({"actor":actor.index,"role":actor.role,"event":actor.events,"action":action,"at_us":Time.get_ticks_usec(),"detail":detail}))
func error(action: String, reason: String) -> void:
	var key:=action+":"+reason;errors[key]=int(errors.get(key,0))+1
func pause(actor: Dictionary, low: float, high: float) -> void:
	var seconds: float=actor.rng.randf_range(low,high)
	event(actor,"think",{"seconds":seconds})
	await get_tree().create_timer(seconds).timeout
func until(predicate: Callable, description: String) -> void:
	# Liveness/cleanup safety, never a p95/TPS acceptance threshold.
	var deadline:=Time.get_ticks_msec()+90000
	while not predicate.call() and Time.get_ticks_msec()<deadline and not failed: await get_tree().process_frame
	if not predicate.call(): die("unresolved "+description)
func ready(peer: int) -> bool: return world.inventory_runtime.mutations_allowed(peer) and world.wallet_runtime.settled(peer)
func _physics_process(_delta: float) -> void:
	if not measuring: return
	var now:=Time.get_ticks_usec()
	if previous_tick>0: sample("physics_gap",now-previous_tick)
	previous_tick=now;tick_started=now;stats.physics_ticks+=1
	for actor: Dictionary in actors:
		var body: PlayerActor3D=simulation.characters[actor.peer]
		var direction: Vector2=actor.direction
		if body.position.distance_to(actor.home)>3.0:
			direction=Vector2(actor.home.x-body.position.x,actor.home.z-body.position.z).normalized()
		simulation.intentions[actor.peer]={"direction":direction,"time":Time.get_ticks_msec(),"sequence":0}
func tail() -> void: sample("physics_callback_span",Time.get_ticks_usec()-tick_started)
func observe(pool: String, value: Dictionary) -> void:
	if measuring:
		var key: String=pool+":"+value.intent
		native_jobs[key]=int(native_jobs.get(key,0))+1
	for key: String in ["queue_us","worker_us","delivery_us"]: sample(pool+":"+value.intent+":"+key,int(value[key]))
func finished(peer: int, id: String, result: Dictionary) -> void:
	var job: Dictionary=jobs.get(peer,{})
	if job.is_empty() or (not job.id.is_empty() and job.id!=id): return
	job.answer=result.duplicate(true);job.received_us=Time.get_ticks_usec()
func ground_finished(peer: int, _ground: RefCounted, id: String, result: Dictionary) -> void: finished(peer,id,result)

func enqueue(actor: Dictionary, action: String, payload: Dictionary, id: String, domain: String) -> Dictionary:
	if domain=="ground": return world.ground_item_runtime.pickup(actor.peer,simulation.ground_loot,id,Time.get_ticks_msec())
	if action=="visit": return world.seller_runtime.visit(actor.peer,int(payload.shop_id))
	return world.seller_runtime.submit(actor.peer,action,payload)

func command(actor: Dictionary, action: String, body: Dictionary = {}, domain: String = "market") -> Dictionary:
	await until(func()->bool:return ready(actor.peer),"actor readiness")
	serial+=1
	var id: String=str(body.uid) if domain=="ground" else "realm-"+str(serial)
	var payload:=body.duplicate(true);payload.command_id=id
	var job: Dictionary={"id":"" if action=="visit" else id,"answer":{}}
	jobs[actor.peer]=job
	var started:=Time.get_ticks_usec()
	stats.attempts+=1;actor.actions+=1
	if window_open: actor.window_actions+=1
	event(actor,action,{"id":id})
	var queued: Dictionary=enqueue(actor,action,payload,id,domain)
	var admission_deadline:=Time.get_ticks_msec()+90000
	while not queued.get("queued",false) and str(queued.get("error","")) in TRANSIENT and action!="visit" and Time.get_ticks_msec()<admission_deadline:
		stats.admission_rejected+=1;stats.admission_retries+=1;error(action,"admission:"+str(queued.error))
		await pause(actor,0.15,0.5)
		await until(func()->bool:return ready(actor.peer),"retry admission readiness")
		queued=enqueue(actor,action,payload,id,domain) # SAME intent/UID, no accepted work is re-executed.
	if not queued.get("queued",false):
		jobs.erase(actor.peer);stats.admission_rejected+=1;error(action,str(queued.get("error","unknown")))
		if str(queued.get("error","unknown")) not in TRANSIENT+CONFLICTS: die("unexpected admission "+str(queued))
		return {"ok":false,"error":queued.get("error","unknown")}
	stats.admitted+=1
	var deadline:=Time.get_ticks_msec()+90000
	while Time.get_ticks_msec()<deadline and not failed:
		if job.answer.is_empty(): await get_tree().process_frame;continue
		var result: Dictionary=job.answer;var received_us: int=job.received_us;job.answer={}
		var reason:=str(result.get("error",""))
		if not result.get("ok",false) and reason in TRANSIENT:
			stats.recoveries+=1;error(action,reason)
			await pause(actor,0.15,0.5)
			if domain=="ground": world.ground_item_runtime.receipt(actor.peer,id)
			elif action=="visit":
				# A visit is a read, not an economic intention. Retry only that read.
				world.seller_runtime.visit(actor.peer,int(body.shop_id))
			else: world.seller_runtime.receipt(actor.peer,id)
			continue
		jobs.erase(actor.peer);sample("action:"+action,received_us-started)
		if result.get("ok",false):
			if action=="buy":
				for state: Dictionary in result.get("wallet_states",[]):
					if int(state.account_id)==int(actor.context.account_id) and int(state.get("pending_applied",0))>0:
						stats.pending_income_buy_successes+=1;stats.pending_income_applied_by_buys+=int(state.pending_applied)
			sample("action_ok:"+action,received_us-started)
			stats.completed+=1;action_successes[action]=int(action_successes.get(action,0))+1
			if domain=="ground":
				picked[id]=actor.character;expected_uids.append(id);stats.ground_pickups+=1
			elif action!="visit": successful_ids[id]=action
		else:
			sample("action_conflict:"+action,received_us-started)
			error(action,reason)
			if reason not in CONFLICTS: die("unexpected "+action+" result "+str(result))
			stats.conflicts+=1
		return result
	die("accepted operation unresolved: "+action+" / "+id)
	return {"ok":false,"error":"unresolved"}

func search(actor: Dictionary, cursor: String = "", filtered: bool = false) -> Dictionary:
	serial+=1
	var payload:=SEARCH.duplicate(true);payload.cursor=cursor
	if filtered: payload.affix_filters=[{"stat_id":"monster_damage","minimum":5}]
	var box: Dictionary={};var started:=Time.get_ticks_usec()
	actor.actions+=1;stats.searches+=1
	if window_open: actor.window_actions+=1
	event(actor,"search",{"cursor":cursor,"filtered":filtered})
	world.seller_runtime.auction.submit(actor.peer,"realm-query-"+str(serial),payload,func(result: Dictionary)->void:box.result=result;box.received_us=Time.get_ticks_usec(),func()->bool:return world.inventory_runtime.mutations_allowed(actor.peer))
	await until(func()->bool:return box.has("result"),"Auction response")
	sample("action:search",int(box.received_us)-started)
	if box.result.get("ok",false): stats.searches_ok+=1
	else: error("search",str(box.result.get("error","unknown")))
	return box.result

func shopping(actor: Dictionary, bulk: bool) -> bool:
	var first: Dictionary=await search(actor)
	if not first.get("ok",false): return false
	await pause(actor,0.3,1.2)
	var page: Dictionary=await search(actor,"",true)
	if not page.get("ok",false) or page.results.is_empty(): return false
	if not str(page.next_cursor).is_empty(): await search(actor,str(page.next_cursor),true)
	await pause(actor,0.3,1.2)
	var cleared: Dictionary=await search(actor) # Clear the filter before choosing a live seller.
	var choices: Array=cleared.get("results",[]).filter(func(row: Dictionary)->bool:return int(row.shop_id)<10000)
	if choices.is_empty(): choices=page.results
	var chosen: Dictionary=choices[actor.index%choices.size()]
	var visit: Dictionary=await command(actor,"visit",{"shop_id":int(chosen.shop_id)})
	if not visit.get("ok",false): return false
	var purchased:=0
	for offer: Dictionary in visit.offers:
		if purchased>=(5 if bulk else 1): break
		if offer.get("offer_only",false) or offer.get("price",null)==null: continue
		await pause(actor,0.3,1.2)
		var result: Dictionary=await command(actor,"buy",{"shop_id":int(chosen.shop_id),"offer_id":offer.offer_id,"revision":int(offer.revision),"price":int(offer.price)})
		if result.get("ok",false): purchased+=1
	return purchased==(5 if bulk else 1)

func selling(actor: Dictionary) -> bool:
	var snapshot: Dictionary=world.inventory_runtime.snapshot_for_peer(actor.peer)
	var candidates: Array=snapshot.items.filter(func(item: Dictionary)->bool:return item.definition_id=="iron_sword" and item.get("equipment_slot","")=="")
	if not actor.configured:
		var configured: Dictionary=await command(actor,"configure",{"revision":int(views.get(actor.peer,{}).get("revision",0)),"name":"Realm seller "+str(actor.index),"status":"active"})
		if not configured.get("ok",false): return false
		actor.configured=true
	var listed:=0
	for item: Dictionary in candidates:
		if listed>=5: break
		var result: Dictionary=await command(actor,"list",{"uid":item.uid,"revision":int(item.revision),"position":listed%5,"price":1+listed})
		if result.get("ok",false): listed+=1
		await pause(actor,0.3,1.0)
	var offers: Array=views.get(actor.peer,{}).get("offers",[])
	if not offers.is_empty(): await command(actor,"edit",{"offer_id":offers[0].offer_id,"revision":int(offers[0].revision),"position":int(offers[0].position),"price":2})
	if int(views.get(actor.peer,{}).get("claimable_yang","0"))>0: await command(actor,"claim_revenue")
	return true

func exchange(actor: Dictionary) -> bool:
	var sell: bool=actor.role=="trader"
	var placed: Dictionary=await command(actor,"order",{"have_asset":"upgrade_ore" if sell else "yang","want_asset":"yang" if sell else "upgrade_ore","quantity":3 if sell else 2,"price_num":100,"price_den":1})
	if not placed.get("ok",false): return false
	await pause(actor,1.0,3.0)
	var active: Array=views.get(actor.peer,{}).get("exchange",{}).get("orders",[]).filter(func(row: Dictionary)->bool:return row.order_id==placed.order_id and row.status=="active")
	if not active.is_empty(): await command(actor,"cancel_order",{"order_id":active[0].order_id,"revision":int(active[0].revision)})
	return true

func rebind(actor: Dictionary) -> void:
	world.wallet_runtime.checkpoint(actor.peer)
	await until(func()->bool:return ready(actor.peer),"pre-rebind checkpoint")
	var before: Dictionary=world.inventory_runtime.snapshot_for_peer(actor.peer)
	var balance: int=world.wallet_runtime.snapshot(actor.peer).balance
	world.inventory_runtime.detach(actor.peer);world.wallet_runtime.detach(actor.peer)
	await pause(actor,0.2,0.8)
	if not world.inventory_runtime.attach(actor.peer,actor.context) or not world.wallet_runtime.attach(actor.peer,actor.context): die("reattach rejected")
	await until(func()->bool:return ready(actor.peer),"runtime rebind")
	if world.wallet_runtime.snapshot(actor.peer).balance!=balance or world.inventory_runtime.snapshot_for_peer(actor.peer).items!=before.items: die("rebind changed persisted Inventory/wallet")
	stats.rebinds+=1;actor.rebound=true

func grind(actor: Dictionary) -> bool:
	# Scripted domain reward arrivals, not fabricated SQL per kill. Combat/death
	# generation itself is explicitly outside this first representative slice.
	for index: int in 80:
		if not world.wallet_runtime.ready(actor.peer):
			stats.income_deferred+=1
			await until(func()->bool:return world.wallet_runtime.ready(actor.peer),"deferred reward income")
		if world.wallet_runtime.add_income(actor.peer,1): stats.income+=1;stats.income_events+=1;actor.income_events+=1;actor.window_income+=int(window_open)
		else: die("ready farmer income rejected")
		await pause(actor,0.25,0.5)
	if actor.stories==1: await shopping(actor,false) # Farm -> spend the captured RAM income -> pickup/rebind.
	var uid: String=simulation.ground_loot.spawn_resolved_item(simulation.characters[actor.peer].position,actor.character,"Farmer",Time.get_ticks_msec(),&"upgrade_ore",1,[])
	var result: Dictionary=await command(actor,"pickup",{"uid":uid},"ground")
	if not actor.rebound: await rebind(actor)
	return result.get("ok",false)

func actor_loop(actor: Dictionary) -> void:
	active_loops+=1
	await pause(actor,0.1,3.0)
	while running and not failed:
		actor.direction=Vector2.ZERO if actor.role=="passive" else Vector2.from_angle(actor.rng.randf_range(0,TAU))*0.4
		if actor.role=="passive": await pause(actor,3.0,10.0);continue
		stats.stories_started+=1;actor.stories+=1
		var started:=Time.get_ticks_usec();var ok:=false
		match actor.role:
			"farmer": ok=await grind(actor)
			"browser":
				ok=await shopping(actor,actor.stories%2==0)
				if ok and not actor.rebound: await rebind(actor)
			"trader": ok=await selling(actor) if actor.stories%2==1 else await exchange(actor)
			"power_trader": ok=await exchange(actor) if actor.stories%2==1 else await shopping(actor,true)
		sample("story:"+actor.role,Time.get_ticks_usec()-started)
		if ok: stats.stories_completed+=1;actor.completed+=1
		else: stats.stories_failed+=1
		await pause(actor,1.0 if actor.role=="power_trader" else 4.0,3.0 if actor.role=="power_trader" else 12.0)
	active_loops-=1

func population() -> Array[String]:
	var counts: Dictionary={};var fractions: Dictionary={};var total:=0
	for role: String in ROLE_WEIGHTS:
		var exact: float=requested*ROLE_WEIGHTS[role]/100.0
		counts[role]=floori(exact);fractions[role]=exact-floor(exact);total+=int(counts[role])
	while total<requested:
		var best: String=fractions.keys()[0]
		for role: String in fractions:
			if fractions[role]>fractions[best]: best=role
		counts[best]+=1;fractions[best]=-1.0;total+=1
	var roles: Array[String]=[]
	for role: String in counts:
		for _i: int in int(counts[role]): roles.append(role)
	# Interleave roles before admission, so a real runtime capacity limit cannot
	# accidentally admit only the leading farmer group.
	var chooser:=RandomNumberGenerator.new();chooser.seed=workload_seed ^ 24301
	for index: int in range(roles.size()-1,0,-1):
		var other:=chooser.randi_range(0,index);var role: String=roles[index]
		roles[index]=roles[other];roles[other]=role
	return roles

func _ready() -> void:
	Engine.max_fps=60;Engine.physics_ticks_per_second=60
	if OS.get_environment("MANDATE_PG_FIXTURE")!="owned-local-cluster": die("owned fixture required");return
	directory=OS.get_environment("MANDATE_PG_FIXTURE_DIR")
	duration=int(OS.get_environment("MANDATE_REALM_SECONDS"));requested=int(OS.get_environment("MANDATE_REALM_PLAYERS"));workload_seed=int(OS.get_environment("MANDATE_REALM_SEED"))
	get_tree().create_timer(duration+requested*3+240).timeout.connect(func()->void:die("fixture safety deadline"))
	call_deferred("run")
func run() -> void:
	pg=ClassDB.instantiate("GodotSociDatabase")
	if not pg.open("postgresql",OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")) or not Schema.ensure_schema(pg): die("database setup");return
	var catalogue:=Catalogue.new();catalogue.pg=pg;catalogue.benchmark();catalogue.free()
	world.database=WorldDatabase.new();add_child(world);world.add_child(world.database)
	if not world.database.start_profile_database(directory+"/profiles.db"): die("profiles");return
	var authority: String=pg.query("SELECT value FROM economy.meta WHERE key='economy_authority_id';").rows[0].value
	if not await bootstrap.start_world(world,{"backend":"postgresql","connection_env":"MANDATE_PG_FIXTURE_CONNECTION","authority_id":authority,"queue_capacity":2}): die("bootstrap");return
	world.observe_poll=func(us: int)->void:sample("world_poll_projection",us)
	for name: String in bootstrap._pools:
		bootstrap._pools[name].profiling_enabled=true
		bootstrap._pools[name].observation.connect(func(row: Dictionary)->void:observe(name,row))
	world.seller_runtime.finished.connect(finished)
	world.seller_runtime.snapshot_applied.connect(func(peer: int,snapshot: Dictionary)->void:views[peer]=snapshot)
	world.ground_item_runtime.finished.connect(ground_finished)
	var roles:=population();var rejected:=0
	for role: String in roles: requested_roles[role]=int(requested_roles.get(role,0))+1
	for index: int in requested:
		var account:=50000+index;var character:=60000+index;var peer:=100+index;var token: String="realm-"+str(workload_seed)+"-"+str(index)
		if not Identity.new(pg).bind(account,character).ok: die("identity");return
		if not pg.execute("UPDATE economy.account_wallets SET yang=100000 WHERE account_id=:id;",{"id":account}).ok: die("wallet seed");return
		var context: Dictionary=Sessions.new(pg).install_verified_grant(Sessions.identity_from_verified_ticket(account,character,token),0).context
		var player:=PlayerResource.new();player.player_id=character;player.current_peer_id=peer;player.display_name="Realm "+str(index)
		world.connected_players[peer]=player;world.player_id_to_peer_id[character]=peer;world._session_tokens[peer]=token
		if not world.inventory_runtime.attach(peer,context):
			refused_actors.append({"index":index,"role":roles[index],"reason":"inventory_binding_refused"})
			rejected+=1;world.connected_players.erase(peer);world.player_id_to_peer_id.erase(character);world._session_tokens.erase(peer);continue
		if not world.wallet_runtime.attach(peer,context): die("wallet attach");return
		await until(func()->bool:return ready(peer),"initial character hydration")
		if roles[index] in ["trader","power_trader"]:
			if not pg.execute("INSERT INTO economy.exchange_assets VALUES(:id,'upgrade_ore',10000,0);",{"id":account}).ok: die("material seed");return
			for _extra: int in 4:
				var item:=ItemInstance.create(ItemDefinitions.IRON_SWORD,character,[])
				if not pg.begin() or not Items.new(pg).receive_item_in_transaction(item).ok or not pg.commit(): die("stock seed");return
			world.inventory_runtime.detach(peer)
			if not world.inventory_runtime.attach(peer,context): die("seed refresh");return
			await until(func()->bool:return ready(peer),"seed hydration")
		var rng:=RandomNumberGenerator.new();rng.seed=workload_seed+index*104729
		var actor: Dictionary={"index":index,"peer":peer,"character":character,"role":roles[index],"rng":rng,"context":context,"events":0,"actions":0,"window_actions":0,"window_income":0,"income_events":0,"stories":0,"completed":0,"configured":false,"rebound":false,"direction":Vector2.ZERO,"home":Vector3.ZERO}
		actors.append(actor);by_peer[peer]=actor;role_counts[roles[index]]=int(role_counts.get(roles[index],0))+1
	if actors.is_empty(): die("no runtime sessions admitted");return
	initial_money=int(pg.query("SELECT sum(yang)::bigint AS n FROM economy.account_wallets;").rows[0].n)
	material_total=int(pg.query("SELECT coalesce(sum(free+reserved),0)::bigint AS n FROM economy.exchange_assets;").rows[0].n)
	expected_uids=Support.item_rows(pg).map(func(row: Dictionary)->String:return row.uid)
	connections.before=int(pg.query("SELECT count(*) AS n FROM pg_stat_activity WHERE datname=current_database();").rows[0].n)
	simulation.span=maxf(32,ceil(sqrt(actors.size()))*4+12);simulation.extra_mobs=actors.size()*2;add_child(simulation)
	if simulation.mob_system.mobs.size()!=actors.size()*2+4: die("mob population not created");return
	var columns:=ceili(sqrt(actors.size()))
	for actor: Dictionary in actors:
		var body:=simulation._add_character(actor.peer,"Realm "+str(actor.index))
		body.position=Vector3((actor.index%columns-columns/2.0)*3,0.1,(actor.index/columns-columns/2.0)*3)
		actor.home=body.position
		simulation.intentions[actor.peer]={"direction":Vector2.ZERO,"time":Time.get_ticks_msec(),"sequence":0}
	var tail_probe:=Support.Tail.new();tail_probe.process_physics_priority=10000;tail_probe.record=tail;add_child(tail_probe)
	trace=FileAccess.open(directory+"/schedule.jsonl",FileAccess.WRITE)
	await get_tree().create_timer(1).timeout
	var started:=Time.get_ticks_usec();var next_memory:=started
	measuring=true;window_open=true;running=true
	for actor: Dictionary in actors: actor_loop(actor)
	while Time.get_ticks_usec()-started<duration*1000000 and not failed:
		var pending:=0
		for pool: RefCounted in bootstrap._pools.values(): pending+=pool.pending_count()
		stats.max_native_pending=maxi(stats.max_native_pending,pending)
		if Time.get_ticks_usec()>=next_memory:
			memory_samples.append({"seconds":(Time.get_ticks_usec()-started)/1000000.0,"godot_static_bytes":OS.get_static_memory_usage(),"native_pending":pending,"active_stories":jobs.size()});next_memory+=5000000
		await get_tree().process_frame
	var window_successes: int=stats.completed
	running=false;window_open=false
	await until(func()->bool:return active_loops==0 and jobs.is_empty() and world.seller_runtime.drained() and world.ground_item_runtime.drained(),"all accepted operations and current stories")
	var tail_seconds: float=(Time.get_ticks_usec()-started)/1000000.0-duration
	measuring=false;trace.close()
	if not await world.flush_postgres_wallets(): die("final money checkpoint");return
	simulation.set_physics_process(false);simulation.combat_endpoint.set_physics_process(false)
	connections.pre_shutdown=int(pg.query("SELECT count(*) AS n FROM pg_stat_activity WHERE datname=current_database();").rows[0].n)
	# Keep the material conservation invariant exact for both ledger and picked items.
	var picked_amount:=int(pg.query("SELECT coalesce(sum(amount),0)::bigint AS n FROM economy.item_instances WHERE definition_id='upgrade_ore';").rows[0].n)
	if picked_amount!=picked.size(): die("ground material conservation");return
	expected_uids.sort()
	var audit: Dictionary=Support.audit_economy(pg,expected_uids,initial_money+int(stats.income),material_total,successful_ids,"realm-",directory)
	if not audit.get("ok",false): die("economic invariants");return
	var claims: Dictionary={};var after: String=""
	while true:
		var page: Dictionary=pg.query("SELECT drop_uid,owner_character_id FROM economy.ground_item_claims WHERE drop_uid>:after ORDER BY drop_uid LIMIT 1024;",{"after":after},1024)
		if not page.ok or page.truncated: die("ground audit scan");return
		for row: Dictionary in page.rows: claims[row.drop_uid]=int(row.owner_character_id)
		if page.rows.size()<1024: break
		after=page.rows.back().drop_uid
	if claims!=picked: die("pickup ownership/duplicate receipt");return
	var exchange_outcomes: Dictionary=pg.query("SELECT (SELECT count(*) FROM economy.exchange_fills) AS fills,(SELECT count(*) FROM economy.exchange_orders WHERE received>0 AND status='cancelled') AS partial_then_cancelled;").rows[0]
	if not await world.shutdown_economy(): die("economy drain");return
	world.connected_players.clear()
	if not await world.database.shutdown_database(): die("profile close");return
	connections.after=int(pg.query("SELECT count(*) AS n FROM pg_stat_activity WHERE datname=current_database();").rows[0].n)
	var timings: Dictionary={}
	for key: String in histograms: timings[key]=histograms[key].summary()
	var report: Dictionary={"case":"MMO Integration & Load","schema":1,"metrics_version":3,"scenario_version":3,"environment":{"os":OS.get_name(),"processors":OS.get_processor_count(),"godot":Engine.get_version_info().string},"seed":workload_seed,"requested_players":requested,"admitted_players":actors.size(),"admission_rejected_players":rejected,"connected_clients":0,"requested_roles":requested_roles,"refused_actors":refused_actors,"roles":role_counts,"mobs":simulation.mob_system.mobs.size(),"workers":Bootstrap.WORLD_POOLS,"queue_capacity_per_worker":2,"active_economic_accounts":actors.filter(func(a: Dictionary)->bool:return a.actions>0).size(),"actor_activity":actors.map(func(a: Dictionary)->Dictionary:return {"index":a.index,"role":a.role,"actions":a.actions,"window_action_attempts":a.window_actions,"window_action_hz":a.window_actions/float(duration),"income_events":a.income_events,"window_income_events":a.window_income,"window_income_hz":a.window_income/float(duration),"stories":a.stories,"completed":a.completed}),"duration_seconds":duration,"tail_seconds":tail_seconds,"successful_actions_in_window":window_successes,"stats":stats,"action_successes":action_successes,"native_jobs":native_jobs,"errors":errors,"timings":timings,"memory_samples":memory_samples,"connections":connections,"audit":audit,"exchange_outcomes":exchange_outcomes,"workers_stopped":bootstrap.status().stopped,"invariants":"PASS","limits":{"synthetic_sessions":true,"connected_clients":0,"combat_damage":false,"scripted_rewards":true,"network_relogin":false,"allocator_memory_not_rss":true},"mechanisms":["movement","passive_mob_ai","scripted_grind_income","ground_pickup","auction_filters_pages","shop_visit","single_bulk_purchase","seller_list_edit_collect","exchange_place_cancel","runtime_rebind"]}
	FileAccess.open(directory+"/realm-workload.json",FileAccess.WRITE).store_string(JSON.stringify(report,"  "))
	pg.close();print("POSTGRES_REALM_WORKLOAD_OK");get_tree().quit()
