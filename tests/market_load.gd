extends "res://tests/pve_network.gd"
## R0/R2: production physics/combat/replication + legal 10k offers, two real clients.
## Six seconds per phase; emulate 16 query sources at <=8 requests/s/source.
var measuring := false
var searching := false
var next_burst_ms := 0
var previous_tick_us := 0
var intervals: Array[int] = []
var costs: Array[int] = []
var searches: Array[int] = []
var accepted := 0
var denied := 0
var attacks := 0
var seen_damage := false
var hero := 0
var character_id := 0
var attack_sequence := 0
const PARAMS := {"definition_id":"iron_sword","upgrade_min":0,"upgrade_max":9,"price_min":0,"price_max":9000000000000000,"affix_filters":[],"sort":"price_asc","cursor":"","limit":50}

class TickProbe extends Node:
	var record: Callable
	var started_us := 0
	func _physics_process(_delta: float) -> void:
		record.call(Time.get_ticks_usec())

func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size()==2 and ready_peers.size()==2)
	hero=world.characters.keys()[0];character_id=server.connected_players[hero].player_id
	preload("res://tests/fixtures/market_search_fixture.gd").seed(db,character_id)
	# Probe the full production physics traversal, not just SQL or combat method time.
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
	await get_tree().create_timer(0.5).timeout
	for mode: String in ["combat_only","combat_search"]:
		intervals.clear();costs.clear();searches.clear();accepted=0;denied=0;attacks=0;seen_damage=false;previous_tick_us=0;next_burst_ms=0
		searching=mode=="combat_search";measuring=true
		var deadline:=Time.get_ticks_msec()+6000
		while Time.get_ticks_msec()<deadline: await get_tree().physics_frame
		measuring=false
		check(attacks>0 and seen_damage,"real accepted combat impacts continue under search load")
		print("MARKET_LOAD_BENCH ",JSON.stringify({"phase":mode,"offers":10000,"sources":16,"source_limit_per_second":8,"accepted":accepted,"denied":denied,"attacks":attacks,"physics_work":summary(costs),"tick_interval":summary(intervals),"search":summary(searches)}))
	set_phase("DONE")
	await wait_until(func()->bool:return done_peers.size()==2)
	if not failed:
		print("MARKET_LOAD_SERVER_OK production combat/physics, 10k offers, bounded load observations")
		peer.close();db.close_db();get_tree().quit()

static func summary(samples: Array[int]) -> Dictionary:
	if samples.is_empty(): return {"samples":0}
	var sorted:=samples.duplicate();sorted.sort()
	return {"samples":sorted.size(),"p50_ms":sorted[int(sorted.size()*0.5)]/1000.0,"p95_ms":sorted[int(sorted.size()*0.95)]/1000.0,"p99_ms":sorted[mini(int(sorted.size()*0.99),sorted.size()-1)]/1000.0,"max_ms":sorted.back()/1000.0}

func _physics_process(_delta: float) -> void:
	if not measuring or not GameMode.is_world_server() or not world.characters.has(hero): return
	var now:=Time.get_ticks_msec()
	var dog: MobActor3D=world.mob_system.mobs[1]
	seen_damage=seen_damage or dog.hp<dog.max_hp
	# Test-only long-lived combat target; do not alter production balance/timelines.
	if dog.hp<dog.max_hp: dog.hp=dog.max_hp
	var actor: PlayerActor3D=world.characters[hero]
	if world.combat_endpoint.can_move(hero,now):
		actor.position=Vector3(0,0,5);dog.position=Vector3(0,0,3.5);actor.rotation.y=0
		attack_sequence+=1
		if world.combat_endpoint.attacks.begin_attack(hero,attack_sequence,now): attacks+=1
	if searching and now>=next_burst_ms:
		next_burst_ms=now+125 # No synthetic queue/catch-up; each source stays <=8/s.
		for source: int in 16:
			var started:=Time.get_ticks_usec()
			var result:=server.database.market_query(character_id,"search",PARAMS)
			if result.ok: accepted+=1;searches.append(Time.get_ticks_usec()-started)
			else:
				check(result.error=="rate_limited","load shedding uses existing error contract")
				denied+=1

@rpc("authority","call_remote","reliable",0)
func phase(command: String,_uid: String) -> void:
	if command=="DONE":
		print("MARKET_LOAD_CLIENT_OK ",client_number," observer replication")
		finished.rpc_id(1)
		await get_tree().create_timer(0.5).timeout
		peer.close();get_tree().quit()

func _process(delta: float) -> void:
	elapsed+=delta
	if elapsed>40: check(false,"market load timeout");return
	if GameMode.is_world_server() or world==null or world.combat_endpoint.state.is_empty(): return
	if not ready_peers.has(world.local_peer): ready_peers[world.local_peer]=true;register_ready.rpc_id(1)
