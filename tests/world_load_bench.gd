extends Node
## W0 opt-in control: production movement/AI, synthetic actors, no sockets or DB.
const Support = preload("res://tests/support/postgres_workload_support.gd")
const Bindings = preload("res://tests/support/world_binding_probe.gd")
const Profile = preload("res://tests/support/world_profile.gd")

class BenchMap extends Support.SimMap:
	var wide:=false
	var snapshots:=0
	var snapshot_bytes:=0
	func _build_arena() -> void:
		if wide: _box("Floor",Vector3(0,-0.25,0),Vector3(512,0.5,512),Color.WHITE)
		else: super._build_arena()
	func _broadcast_snapshot() -> void:
		# Same roster construction as production; one encoding proxy, no RPC fan-out.
		var started:=Time.get_ticks_usec()
		var roster: Dictionary={}
		for peer: int in characters:
			var body: PlayerActor3D=characters[peer]
			roster[peer]=[body.position,body.rotation.y]
		Profile.add("snapshot_roster",started)
		started=Time.get_ticks_usec()
		snapshot_bytes=var_to_bytes(roster).size()
		Profile.add("snapshot_encode_proxy",started)
		snapshots+=1

class Probe extends Node:
	var callback: Callable
	func _physics_process(_delta: float) -> void: callback.call()

var world: BenchMap
var players:=0
var mobs:=0
var wide:=false
var measuring:=false
var previous:=0
var tick_start:=0
var input_clock:=0.0
var simulation_time:=0.0
var work: Array[int]=[]
var intervals: Array[int]=[]
var frames: Array[int]=[]
var previous_frame:=0
var profiled:=false
var displacement:=false
var action_phase: int=-1

func _ready() -> void:
	assert(GameMode.is_world_server())
	Engine.physics_ticks_per_second=60
	Engine.max_fps=60
	var args:=CmdlineUtils.get_parsed_args()
	if args.get("bench-cohort","")=="bindings":
		print("WORLD_BASELINE_RESULT "+JSON.stringify({"cohort":"mock_ready_binding_cost_no_sql","cases":Bindings.run()}))
		get_tree().quit();return
	players=int(args.get("bench-players","100"))
	mobs=int(args.get("bench-mobs","200"))
	wide=args.get("bench-wide","0")=="1"
	profiled=args.get("bench-profile","0")=="1"
	displacement=args.get("bench-displacement","0")=="1"
	assert(players>=0 and mobs>=0)
	seed(1729)
	if profiled:
		var directory: String=args["bench-profile-dir"]
		world=load(directory+"/map.gd").new()
		world.mob_system=load(directory+"/mobs.gd").new()
	else: world=BenchMap.new()
	world.wide=wide;world.extra_mobs=0
	add_child(world)
	for id: int in world.mob_system.mobs.keys(): world.mob_system.remove_mob(id)
	for i: int in players:
		var peer:=10000+i
		var body:=world._add_character(peer,"Synthetic")
		body.position=spawn_position(i)
		world.intentions[peer]={"direction":Vector2.ZERO,"sequence":0,"time":Time.get_ticks_msec()}
	for i: int in mobs:
		var entry:=MobSpawnEntry.new();entry.mob=MobDefinitions.resolve(&"wild_dog")
		var anchor:=spawn_position(i%maxi(players,1))+Vector3(0.4,0,2)
		var pack:=world.mob_system.create_pack([entry],anchor,0,0,10000,0)
		pack.rng.seed=1729+i
		var dog: MobActor3D=world.mob_system.mobs[pack.actor_ids[0]]
		dog.proximity_aggro=false
		if players>0:
			dog.target_peer=10000+i%players;dog.ai_state=MobState.Value.CHASE
			# Movement-only control. No hits/deaths/rewards or synthetic RPC targets.
			dog.last_attack_ms=Time.get_ticks_msec()+3600000
	var begin:=Probe.new();begin.process_physics_priority=-1000;begin.callback=begin_tick;add_child(begin)
	var end:=Probe.new();end.process_physics_priority=1000;end.callback=end_tick;add_child(end)
	await get_tree().create_timer(float(args.get("bench-warmup","3"))).timeout
	world.snapshots=0;work.clear();intervals.clear();frames.clear();previous=0;previous_frame=0
	Profile.reset();Profile.enabled=profiled;measuring=true
	var started:=Time.get_ticks_usec()
	await get_tree().create_timer(float(args.get("bench-seconds","12"))).timeout
	measuring=false
	Profile.enabled=false
	var elapsed: float=(Time.get_ticks_usec()-started)/1000000.0
	var over:=0
	for us: int in work:
		if us>16667: over+=1
	print("WORLD_BASELINE_RESULT "+JSON.stringify({"cohort":"synthetic_movement_no_clients_no_sql","profiled":profiled,"displacement":displacement,"profile":Profile.report(),"frame_interval":summary(frames),"players":players,"mobs":world.mob_system.mobs.size(),"packs":world.mob_system.packs.size(),"wide":wide,"seed":1729,"seconds":elapsed,"physics_work":summary(work),"tick_interval":summary(intervals),"observed_hz":work.size()/elapsed,"over_budget_ticks":over,"static_memory_bytes":OS.get_static_memory_usage(),"player_snapshot_bytes":world.snapshot_bytes,"mob_snapshot_bytes":var_to_bytes(world.mob_system.snapshot()).size(),"snapshot_count":world.snapshots,"actual_network_bytes":0,"debug_build":OS.is_debug_build(),"editor_binary":OS.has_feature("editor")}))
	world.queue_free()
	await get_tree().process_frame
	get_tree().quit()

func spawn_position(i: int) -> Vector3:
	return Vector3(-120+(i%30)*8,0.15,-120+(i/30)*8) if wide else Vector3(-13+(i%30)*0.85,0.15,-13+(i/30)*0.85)

func _physics_process(delta: float) -> void:
	if world==null: return
	world.mob_system.tick(delta,Time.get_ticks_msec())
	simulation_time+=delta;input_clock+=delta
	if displacement and int(simulation_time/2)!=action_phase:
		action_phase=int(simulation_time/2)
		for body: PlayerActor3D in world.characters.values():
			if action_phase%2==0: body.start_attack_advance(0,0.4,0.3)
			else: body.apply_knockback(Vector3.RIGHT,1)
	if input_clock<GameWorld3D.INPUT_INTERVAL: return
	input_clock=fmod(input_clock,GameWorld3D.INPUT_INTERVAL)
	for peer: int in world.characters:
		var angle: float=(peer%12)*PI/6+simulation_time*0.1
		world.intentions[peer]={"direction":Vector2(cos(angle),sin(angle)),"sequence":0,"time":Time.get_ticks_msec()}

func begin_tick() -> void:
	if not measuring: return
	Profile.begin_tick()
	var now:=Time.get_ticks_usec()
	if previous>0: intervals.append(now-previous)
	previous=now;tick_start=now

func end_tick() -> void:
	if measuring and tick_start>0:
		work.append(Time.get_ticks_usec()-tick_start)
		Profile.end_tick()

func _process(_delta: float) -> void:
	if not measuring: return
	var now:=Time.get_ticks_usec()
	if previous_frame>0: frames.append(now-previous_frame)
	previous_frame=now

static func summary(values: Array[int]) -> Dictionary:
	assert(not values.is_empty())
	var ordered:=values.duplicate();ordered.sort()
	var result: Dictionary={"samples":values.size(),"max_ms":ordered[-1]/1000.0}
	for p: int in [50,95,99]: result["p%d_ms" % p]=ordered[ceili(values.size()*p/100.0)-1]/1000.0
	return result
