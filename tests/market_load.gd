extends "res://tests/pve_network.gd"
## D2: real World physics/RPC plus explicitly simulated account query sources.
## All actors, credits, faults and databases belong to this disposable fixture.
const PARAMS := {"definition_id":"iron_sword","upgrade_min":0,"upgrade_max":9,"price_min":0,"price_max":9000000000000000,"affix_filters":[],"sort":"price_asc","cursor":"","limit":50}
var measuring := false
var searching := false
var next_burst_ms := 0
var next_economy_ms := 0
var previous_tick_us := 0
var intervals: Array[int] = []
var costs: Array[int] = []
var poll_costs: Array[int] = []
var projection_costs: Array[int] = []
var queue_waits: Array[int] = []
var worker_times: Array[int] = []
var end_to_end: Array[int] = []
var depths: Array[int] = []
var errors: Dictionary = {}
var write_costs: Dictionary = {}
var economy_costs: Dictionary = {}
var per_account: Dictionary = {}
var sources: Array[int] = []
var source_sequence := 0
var accepted := 0
var attacks := 0
var seen_damage := false
var hero := 0
var merchant := 0
var attack_sequence := 0
var roles: Dictionary = {}
var cycles := 0
var staged_writes := false
var economy_busy := false
var tested_uid := ""
var item_seller := 0
var expected_sword_owner := 0
var income := 0
var wallet_total := 0
var lifecycle := {}
var reports: Array[Dictionary] = []
var snapshot_plans: Dictionary = {}
var query_replies: Array[Dictionary] = []
var queries_started := false
var client_searching := false
var client_next_ms := 0
var client_requests: Dictionary = {}
var client_times: Array[int] = []
var client_successes := 0
var client_errors: Dictionary = {}
var reconnecting := false
var did_reconnect := false

class TickProbe extends Node:
	var record: Callable
	var started_us := 0
	func _physics_process(_delta: float) -> void: record.call(Time.get_ticks_usec())

func _ready() -> void:
	Engine.max_fps=60 # WorldMain's headless profile, not diagnostic 240/500 FPS.
	database_directory="res://.godot/verification/auction-d2"
	DirAccess.make_dir_recursive_absolute(database_directory)
	super._ready()
	if GameMode.is_world_server():
		# This socket fixture has no Master connection. Use production persistence
		# cleanup APIs; GameWorld's real disconnect handler removes actor/requests.
		multiplayer.peer_disconnected.connect(func(id: int)->void:
			if not server.connected_players.has(id): return
			var owner:=server.connected_players[id].player_id
			check(server.database.flush_character(owner),"disconnect saves dirty state")
			server.database.release_wallet(owner)
			server.runtime_equipment.erase(owner)
			server.connected_players.erase(id))

@rpc("any_peer","call_remote","reliable",0)
func role(number: int) -> void:
	if GameMode.is_world_server(): roles[multiplayer.get_remote_sender_id()]=number

func run_server() -> void:
	await wait_until(func()->bool:return world.characters.size()==2 and ready_peers.size()==2 and roles.size()==2)
	server.database._economy()._marketplace.observe = observe_economy
	world.market_endpoint.observe = observe_economy
	world.inventory_endpoint.observe = observe_economy
	for id: int in roles:
		if roles[id]==1: hero=id
		else: merchant=id
	var persistence:=server.database
	persistence.database_path=db.path
	var owner:=server.connected_players[hero].player_id
	check(db.query("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;"),"production WAL/FULL")
	preload("res://tests/fixtures/market_search_fixture.gd").seed(db,owner,true)
	# Enrolled test Master identities, NOT sixteen physical/network clients.
	for n: int in 16:
		var character:=EconomyFixture.create_character(persistence.store,"load%d" % n,{"name":"Load%d" % n,"skin":1})
		sources.append(persistence.store.resolve_account_id(character))
	EconomyFixture.prepare(persistence)
	# A/B only in this owned disposable database, before reader startup. Never a
	# production feature flag and never applied to runtime/player stores.
	if OS.get_cmdline_args().has("--without-projection-indexes"):
		check(db.query("DROP INDEX shop_offers_shop_position; DROP INDEX custody_account_claim_owner;"),"remove fixture indexes for A/B baseline")
	for label: String in ["offers","claims"]:
		var sql := "SELECT i.*,c.location,o.offer_id FROM shop_offers o JOIN item_custody c ON c.uid=o.item_uid JOIN item_instances i ON i.uid=o.item_uid WHERE o.shop_id=? ORDER BY o.position;" if label=="offers" else "SELECT i.*,c.location FROM item_custody c JOIN item_instances i ON i.uid=c.uid WHERE c.location='account_claim' AND c.owner_id=? ORDER BY c.uid LIMIT 200;"
		check(db.query_with_bindings("EXPLAIN QUERY PLAN "+sql,[1 if label=="offers" else 1000]),"snapshot plan observable")
		snapshot_plans[label] = db.query_result.duplicate(true)
	check(await persistence.start_auction_queries(),"native readonly startup after migrations")
	persistence.auction_queries.observation.connect(observe)
	for id: int in [hero,merchant]:
		var character:=server.connected_players[id].player_id
		check(persistence.load_wallet(character) and persistence.add_yang(character,100000),"runtime pending buyer/seller funding")
	check(persistence.flush_wallet(),"initial funding checkpoint")
	check(db.query("SELECT SUM(yang) AS total FROM account_wallets;"),"initial wallet sum")
	wallet_total=int(db.query_result[0].total)
	var sword: Dictionary=persistence.item_store.inventory(owner).items.filter(func(i: Dictionary)->bool:return i.definition_id=="iron_sword")[0]
	tested_uid=sword.uid;item_seller=hero;expected_sword_owner=owner
	var begin:=TickProbe.new();begin.process_physics_priority=-1000;begin.record=func(now: int)->void:
		begin.started_us=now
		if measuring:
			if previous_tick_us>0: intervals.append(now-previous_tick_us)
			previous_tick_us=now
	add_child(begin)
	var end:=TickProbe.new();end.process_physics_priority=1000;end.record=func(now: int)->void:
		if measuring: costs.append(now-begin.started_us)
	add_child(end)
	world.combat_endpoint.dev_god_mode=true
	for dog: MobActor3D in world.mob_system.mobs.values(): dog.ai_enabled=true
	await get_tree().create_timer(.5).timeout
	for mode: String in ["combat_only","combat_search","combat_search_writes","combat_search_write_burst"]:
		reset_metrics();searching=mode!="combat_only";measuring=true
		staged_writes=mode=="combat_search_writes"
		if searching: set_phase("LOAD")
		if mode=="combat_search": phase_name="READS_ONLY"
		var phase_started:=Time.get_ticks_usec()
		var deadline:=Time.get_ticks_msec()+6000
		while Time.get_ticks_msec()<deadline: await get_tree().physics_frame
		searching=false
		await wait_until(func()->bool:return not economy_busy)
		if mode!="combat_only":
			set_phase("PAUSE")
			await wait_until(func()->bool:return persistence.auction_queries.active.is_empty() and persistence.auction_queries.queued.is_empty())
		measuring=false
		check(attacks>0 and seen_damage,"authoritative impacts continue in "+mode)
		if mode!="combat_only":
			check(accepted>30 and errors.get("rate_limited",0)>0,"async throughput plus visible load shedding")
			for account: int in sources: check(per_account.get(account,0)>0,"fair progress for every simulated account")
			check(end_to_end.max()<2001000,"successful deadline includes queue, within 1ms clock precision")
			check(depths.max()<=AuctionQueryService.MAX_PENDING,"bounded global backlog")
			if mode in ["combat_search_writes","combat_search_write_burst"]: check(cycles>=3,"listing/edit/buy/replay run concurrently")
		var result:={"phase":mode,"offered_duration_ms":6000,"measured_duration_ms":(Time.get_ticks_usec()-phase_started)/1000.0,"write_operations":write_summary(),"economy_stages":economy_summary(),"offers":10000,"simulated_sources":16,"network_clients":2,"mobs":world.mob_system.mobs.size(),"physics_hz":Engine.physics_ticks_per_second,"max_fps":Engine.max_fps,"source_limit_per_second":8,"completed_ok":accepted,"errors":errors.duplicate(),"per_account_ok":per_account.duplicate(),"attacks":attacks,"physics_work":summary(costs),"tick_interval":summary(intervals),"e2e":summary(end_to_end),"queue_wait":summary(queue_waits),"worker_roundtrip":summary(worker_times),"native_sql":null,"poll_including_callbacks":summary(poll_costs),"projection":summary(projection_costs),"max_pending":depths.max() if not depths.is_empty() else 0,"economy_cycles":cycles}
		reports.append(result);print("AUCTION_D2_BENCH ",JSON.stringify(result))
	# Lifecycle with normal sixteen-source traffic and combat still running.
	reset_metrics()
	searching=true;measuring=true;next_burst_ms=0
	await get_tree().create_timer(.25).timeout
	var started:=Time.get_ticks_usec()
	check(await persistence.coordinated_backup(),"backup drains active traffic and resumes")
	lifecycle.backup_ms=(Time.get_ticks_usec()-started)/1000.0
	var backup_dir:=DirAccess.open("user://db_backups")
	var backup_prefix:=db.path.get_file().get_basename()+"_"
	var backups:=Array(backup_dir.get_files()).filter(func(name: String)->bool:return name.begins_with(backup_prefix))
	check(not backups.is_empty(),"backup file actually created")
	var copy:=SQLite.new();copy.path=ProjectSettings.globalize_path("user://db_backups/"+backups[-1])
	check(copy.open_db(),"backup can be opened independently")
	check(copy.query("PRAGMA integrity_check;") and copy.query_result[0].values()[0]=="ok","backup integrity")
	check(copy.query("SELECT COUNT(*) AS n FROM shop_offers;") and int(copy.query_result[0].n)==10000,"backup contains settled catalogue")
	check(copy.query("PRAGMA foreign_key_check;") and copy.query_result.is_empty(),"backup custody")
	check(copy.close_db(),"backup connection closes")
	lifecycle.backup_verified=true
	check(persistence.auction_queries.admissions,"reader admissions restored")
	started=Time.get_ticks_usec()
	check(await persistence.coordinated_backup(10,false,true),"restart quiesces reader and checkpoints wallet")
	check(await persistence.start_auction_queries(),"restart recreates reader safely")
	lifecycle.restart_ms=(Time.get_ticks_usec()-started)/1000.0
	# Separately labelled 65 enrolled catalog accounts actually saturate the cap.
	searching=false
	await wait_until(func()->bool:return persistence.auction_queries.active.is_empty() and persistence.auction_queries.queued.is_empty())
	var cap_results: Array[Dictionary]=[]
	for account: int in range(2000,2065):
		persistence.auction_queries.submit(account,"cap:%d" % account,PARAMS,func(r: Dictionary)->void:cap_results.append(r),func()->bool:return true)
	check(persistence.auction_queries.queued.size()==64 and cap_results.size()==1 and cap_results[0].error=="rate_limited","65 accounts saturate bounded queue")
	check(await persistence.coordinated_backup(),"saturated queue drains while physics runs")
	check(cap_results.size()==65,"each burst request settles once")
	lifecycle.capacity_burst={"accounts":65,"ok":cap_results.filter(func(r: Dictionary)->bool:return r.ok).size(),"errors":cap_results.filter(func(r: Dictionary)->bool:return not r.ok).size()}
	# Actual endpoint destruction/new peer; old session must not receive late data.
	searching=true;next_burst_ms=0;replies.clear()
	var disconnected_peer:=merchant
	phase.rpc_id(merchant,"RECONNECT","")
	await wait_until(func()->bool:return replies.values().any(func(r: Dictionary)->bool:return r.get("reconnected",false)))
	check(not world.characters.has(disconnected_peer),"old actor/session removed on real disconnect")
	lifecycle.reconnect=true
	lifecycle.traffic_errors=errors.duplicate()
	lifecycle.max_pending=depths.max()
	searching=false;measuring=false
	await wait_until(func()->bool:return persistence.auction_queries.active.is_empty() and persistence.auction_queries.queued.is_empty())
	check(persistence.flush_wallet(),"final pending income checkpoint")
	check(db.query("SELECT (SELECT SUM(yang) FROM account_wallets)+(SELECT COALESCE(SUM(yang),0) FROM account_shop_revenue) AS total,(SELECT SUM(reserved_yang) FROM account_wallets) AS reserved;"),"final wallet plus unclaimed revenue sum")
	print("AUCTION_D2_WALLET ",JSON.stringify({"before":wallet_total,"declared_income":income,"actual":db.query_result[0].total,"reserved":db.query_result[0].reserved}))
	check(int(db.query_result[0].total)==wallet_total+income and int(db.query_result[0].reserved)==0,"Yang conserved across purchases, Exchange, income and reconnect")
	check(db.query_with_bindings("SELECT COUNT(*) AS n FROM item_instances WHERE uid=?;",[tested_uid]) and int(db.query_result[0].n)==1,"one persistent sword UID")
	check(db.query_with_bindings("SELECT location,owner_id FROM item_custody WHERE uid=?;",[tested_uid]) and db.query_result.size()==1 and db.query_result[0].location=="bag" and int(db.query_result[0].owner_id)==expected_sword_owner,"final sword custody follows last purchase")
	check(db.query("SELECT SUM(free+reserved) AS total,SUM(reserved) AS reserved FROM exchange_assets;") and int(db.query_result[0].total)==10 and int(db.query_result[0].reserved)==0,"partial fill/cancel conserves materials")
	check(db.query("SELECT COUNT(*) AS n FROM shop_offers;") and int(db.query_result[0].n)==10000,"temporary offers settled, catalogue unchanged")
	check(db.query("PRAGMA integrity_check;") and db.query_result[0].values()[0]=="ok","SQLite integrity")
	check(db.query("PRAGMA foreign_key_check;") and db.query_result.is_empty(),"global foreign-key custody")
	check(db.query("SELECT COUNT(*) AS n FROM market_commands WHERE kind='buy' AND command_id LIKE 'load%_buy';") and int(db.query_result[0].n)==cycles,"one durable buy receipt per cycle despite replay")
	set_phase("DONE")
	await wait_until(func()->bool:return done_peers.size()==2)
	check(await persistence.auction_queries.pause(),"clean reader drain before writer close")
	var release: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tools/soci/release.json"))
	var output:={"platform":OS.get_name(),"godot":Engine.get_version_info().string,"soci":str(release.tag).trim_prefix("v"),"projection_indexes":not OS.get_cmdline_args().has("--without-projection-indexes"),"snapshot_plans":snapshot_plans,"phases":reports,"lifecycle":lifecycle,"economy":{"cycles":cycles,"added_income":income,"yang_total":wallet_total+income,"unique_uid":true,"material_total":10,"rollback_and_receipt_replay":true},"native_sql_timing":"not collected by this fixture; worker round-trip is not SQL time"}
	var file:=FileAccess.open("res://.godot/verification/auction-d2/results.json",FileAccess.WRITE)
	check(file!=null,"report writable");file.store_string(JSON.stringify(output,"\t"));file.close()
	print("AUCTION_D2_LIFECYCLE ",JSON.stringify(lifecycle))
	print("MARKET_LOAD_SERVER_OK native async, 10k catalogue, 16 simulated sources, two RPC clients, combat/AI, writes, backup/restart/reconnect")
	peer.close();db.close_db()
	for suffix: String in ["","-wal","-shm"]: DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path+suffix))
	get_tree().quit(1 if failed else 0)

func reset_metrics() -> void:
	intervals.clear();costs.clear();poll_costs.clear();projection_costs.clear();queue_waits.clear();worker_times.clear();end_to_end.clear();depths.clear();errors.clear();per_account.clear();write_costs.clear();economy_costs.clear()
	accepted=0;attacks=0;seen_damage=false;previous_tick_us=0;next_burst_ms=0;next_economy_ms=0

func observe(sample: Dictionary) -> void:
	if not measuring: return
	match sample.kind:
		"poll": poll_costs.append(int(sample.cost_us));depths.append(int(sample.depth))
		"start": queue_waits.append(int(sample.queue_us))
		"read": worker_times.append(int(sample.worker_roundtrip_us))
		"projection": projection_costs.append(int(sample.cost_us))
		"reply":
			if sample.ok:
				accepted+=1;end_to_end.append(int(sample.e2e_us));per_account[sample.account]=int(per_account.get(sample.account,0))+1
			else: errors[sample.error]=int(errors.get(sample.error,0))+1

static func summary(samples: Array[int]) -> Dictionary:
	if samples.is_empty(): return {"samples":0}
	var sorted:=samples.duplicate();sorted.sort()
	return {"samples":sorted.size(),"p50_ms":sorted[int(sorted.size()*.5)]/1000.0,"p95_ms":sorted[int(sorted.size()*.95)]/1000.0,"p99_ms":sorted[mini(int(sorted.size()*.99),sorted.size()-1)]/1000.0,"max_ms":sorted.back()/1000.0}

func write_summary() -> Dictionary:
	var result:={}
	for action: String in write_costs:
		var samples: Array[int]=[];samples.assign(write_costs[action])
		result[action]=summary(samples)
	return result

func observe_economy(sample: Dictionary) -> void:
	if not measuring: return
	var key: String = sample.kind
	if not economy_costs.has(key): economy_costs[key] = []
	economy_costs[key].append(int(sample.cost_us))
	if key == "store" and sample.committed:
		if not economy_costs.has("commit"): economy_costs.commit = []
		economy_costs.commit.append(int(sample.commit_us))

func economy_summary() -> Dictionary:
	var result := {}
	for key: String in economy_costs:
		var samples: Array[int] = []
		samples.assign(economy_costs[key])
		result[key] = summary(samples)
		result[key]["total_ms"] = samples.reduce(func(total: int, cost: int) -> int: return total+cost, 0)/1000.0
	return result

func measured_mutation(id: int, action: String, payload: Dictionary) -> Dictionary:
	var started:=Time.get_ticks_usec()
	var result:=world.market_endpoint.perform_for_peer(id,action,payload)
	if not write_costs.has(action): write_costs[action]=[]
	write_costs[action].append(Time.get_ticks_usec()-started)
	return result

func economy_cycle() -> void:
	economy_busy=true
	var other:=merchant if item_seller==hero else hero
	var persistence:=server.database
	var owner:=server.connected_players[item_seller].player_id
	var buyer:=server.connected_players[other].player_id
	var item: Dictionary=persistence.item_store.inventory(owner).items.filter(func(i: Dictionary)->bool:return i.uid==tested_uid)[0]
	var prefix:="load%d_" % cycles
	var listed:=measured_mutation(item_seller,"list",{"command_id":prefix+"list","uid":item.uid,"revision":item.revision,"position":0,"price":100})
	check(listed.ok,"concurrent listing")
	if staged_writes: await get_tree().physics_frame
	check(measured_mutation(item_seller,"edit",{"command_id":prefix+"edit","offer_id":listed.offer_id,"revision":0,"position":1,"price":120}).ok,"concurrent edit")
	if staged_writes: await get_tree().physics_frame
	check(persistence.add_yang(buyer,5),"pending income before atomic purchase");income+=5
	var payload:={"command_id":prefix+"buy","shop_id":listed.shop_id,"offer_id":listed.offer_id,"revision":1,"price":120}
	if cycles==0:
		var before:=persistence.wallet_balance(buyer)
		check(db.query("CREATE TEMP TRIGGER fail_load_sale BEFORE DELETE ON shop_cells BEGIN SELECT RAISE(ABORT,'D2 fixture rollback'); END;"),"fault injection")
		check(measured_mutation(other,"buy",payload).get("error")=="storage" and persistence.wallet_balance(buyer)==before,"failed purchase retains pending income")
		check(db.query("DROP TRIGGER fail_load_sale;"),"remove fixture fault")
		if staged_writes: await get_tree().physics_frame
	check(measured_mutation(other,"buy",payload).ok,"concurrent purchase")
	var balance:=persistence.wallet_balance(buyer)
	if staged_writes: await get_tree().physics_frame
	check(measured_mutation(other,"buy",payload).ok and persistence.wallet_balance(buyer)==balance,"receipt retry never charges twice")
	if staged_writes: await get_tree().physics_frame
	check(measured_mutation(item_seller,"claim_revenue",{"command_id":prefix+"collect"}).ok,"explicit atomic collection after sale")
	item_seller=other;expected_sword_owner=buyer;cycles+=1
	if cycles==1:
		if staged_writes: await get_tree().physics_frame
		var ore:=ItemInstance.create(ItemDefinitions.UPGRADE_ORE,owner,[]);ore.amount=10
		check(EconomyFixture.insert_item(persistence.item_store,ore,persistence.item_store._free_bag_position(owner,1)),"exchange material fixture")
		check(measured_mutation(hero,"deposit",{"command_id":"load_deposit","uid":ore.uid,"revision":0,"amount":10,"source":"bag"}).ok,"concurrent deposit")
		if staged_writes: await get_tree().physics_frame
		var sell:=measured_mutation(hero,"order",{"command_id":"load_sell","have_asset":"upgrade_ore","want_asset":"yang","quantity":10,"price_num":10,"price_den":1})
		check(sell.ok,"concurrent maker")
		if staged_writes: await get_tree().physics_frame
		check(measured_mutation(merchant,"order",{"command_id":"load_fill","have_asset":"yang","want_asset":"upgrade_ore","quantity":5,"price_num":10,"price_den":1}).ok,"concurrent partial fill")
		if staged_writes: await get_tree().physics_frame
		check(measured_mutation(hero,"cancel_order",{"command_id":"load_cancel","order_id":sell.order_id,"revision":1}).ok,"concurrent reserve cancellation")
	economy_busy=false

func _physics_process(_delta: float) -> void:
	if not measuring or not GameMode.is_world_server() or not world.characters.has(hero): return
	var now:=Time.get_ticks_msec()
	var dog: MobActor3D=world.mob_system.mobs[1]
	seen_damage=seen_damage or dog.hp<dog.max_hp
	# A sustained combat fixture must not mint unrelated kill/autoloot income.
	# Reset every target, since the directional trace can hit multiple actors.
	for target: MobActor3D in world.mob_system.mobs.values():
		if target.hp>0 and target.hp<target.max_hp: target.hp=target.max_hp
	var actor: PlayerActor3D=world.characters[hero]
	if world.combat_endpoint.can_move(hero,now):
		actor.position=Vector3(0,0,5);dog.position=Vector3(0,0,3.5);actor.rotation.y=0
		world.combat_endpoint.remember_next_facing(hero,Vector2(0,-1))
		attack_sequence+=1
		if world.combat_endpoint.attacks.begin_attack(hero,attack_sequence,now): attacks+=1
	if searching and now>=next_burst_ms:
		next_burst_ms=now+125
		for source: int in sources:
			source_sequence+=1
			var p:=PARAMS.duplicate(true)
			p.affix_filters=[{"stat_id":"monster_damage","minimum":0}] if source_sequence%2==0 else [{"stat_id":"monster_damage","minimum":15},{"stat_id":"critical_chance","minimum":7}]
			server.database.auction_queries.submit(source,"load:%d" % source_sequence,p,func(_r: Dictionary)->void:pass,func()->bool:return server.database.auction_binding_current())
	if searching and phase_name=="LOAD" and not economy_busy and now>=next_economy_ms:
		next_economy_ms=now+1000;economy_cycle()

func client_reply(id: String, result: Dictionary) -> void:
	if id.begins_with("client_limit_"): query_replies.append(result);return
	check(client_requests.has(id),"reply correlation belongs to current session")
	if not client_requests.has(id): return
	client_times.append(Time.get_ticks_usec()-int(client_requests[id]));client_requests.erase(id)
	if result.ok: client_successes+=1
	else:
		check(result.get("error") in ["rate_limited","timeout","storage"],"controlled RPC overload error")
		client_errors[result.error]=int(client_errors.get(result.error,0))+1
	if did_reconnect and result.ok: report.rpc_id(1,{"reconnected":true})

@rpc("authority","call_remote","reliable",0)
func phase(command: String,_uid: String) -> void:
	phase_name=command;client_searching=command=="LOAD"
	if command=="RECONNECT":
		world.market_endpoint.request_query.rpc_id(1,"search",PARAMS,"abandoned")
		client_requests.abandoned=Time.get_ticks_usec()
		await get_tree().create_timer(.03).timeout
		reconnecting=true;peer.close()
		var instance:=get_node("Instance");remove_child(instance);instance.queue_free();world=null
		await get_tree().process_frame
		peer=WebSocketMultiplayerPeer.new();BaseMultiplayerEndpoint.configure_peer(peer)
		check(peer.create_client("ws://127.0.0.1:%d" % PORT)==OK,"reconnect socket")
		multiplayer.multiplayer_peer=peer
		queries_started=false;query_replies.clear();client_requests.clear();did_reconnect=true;reconnecting=false
		client_searching=true
	elif command=="DONE":
		check(client_successes>0,"real RPC client searches succeeded")
		print("AUCTION_D2_RPC_BENCH ",JSON.stringify({"client":client_number,"ok":client_successes,"errors":client_errors,"e2e":summary(client_times),"reconnected":did_reconnect}))
		print("MARKET_LOAD_CLIENT_OK ",client_number," async RPC correlation/replication")
		finished.rpc_id(1)
		await get_tree().create_timer(.5).timeout
		peer.close();get_tree().quit(1 if failed else 0)

func _process(delta: float) -> void:
	elapsed+=delta
	if elapsed>75: check(false,"D2 timeout phase="+phase_name);return
	if GameMode.is_world_server() or reconnecting or world==null or world.combat_endpoint.state.is_empty(): return
	if not queries_started:
		queries_started=true
		world.market_endpoint.query_finished.connect(client_reply)
		role.rpc_id(1,client_number)
		for request: int in 9: world.market_endpoint.request_query.rpc_id(1,"catalog",{"query":"sword"},"client_limit_%d" % request)
	if query_replies.size()==9 and not ready_peers.has(world.local_peer):
		check(query_replies.filter(func(r: Dictionary)->bool:return r.ok).size()==8 and query_replies.back().get("error")=="rate_limited","independent per-client budget")
		ready_peers[world.local_peer]=true;register_ready.rpc_id(1)
	if client_searching and Time.get_ticks_msec()>=client_next_ms and query_replies.size()==9:
		client_next_ms=Time.get_ticks_msec()+250
		var key:="rpc:%d:%d" % [world.local_peer,Time.get_ticks_usec()]
		client_requests[key]=Time.get_ticks_usec()
		world.market_endpoint.request_query.rpc_id(1,"search",PARAMS,key)
