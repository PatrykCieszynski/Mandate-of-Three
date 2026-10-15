extends Node
## Opt-in synthetic World capacity baseline. Runs the actual Godot World,
## PlayerActor3D.simulate() and MobSystem.tick() without fake RPC recipients.
## This is NOT a 100/250/500-connection multiplayer benchmark.
const PORT := 18109
const WORLD_SCENE := "res://tests/fixtures/world_load_bench_world.tscn"
const DOG := preload("res://source/common/gameplay/mobs/wild_dog.tres")
const BUDGET_US := 16667

class TickProbe extends Node:
	var record: Callable
	func _physics_process(_delta: float) -> void:
		record.call(Time.get_ticks_usec())

var peer := WebSocketMultiplayerPeer.new()
var server: WorldServer
var world: GameWorld3D
var simulated_ids: Array[int] = []
var player_count := 100
var mob_count := 200
var warmup_seconds := 3.0
var measurement_seconds := 12.0
var include_per_peer_encode := false
var _sampling := false
var _previous_tick := 0
var _started_tick := 0
var _input_elapsed := 0.0
var work_us: Array[int] = []
var intervals_us: Array[int] = []

func _fail(reason: String) -> void:
	push_error("WORLD_LOAD_BENCH_FAILED: " + reason)
	get_tree().quit(1)

func _ready() -> void:
	Engine.physics_ticks_per_second = 60
	Engine.max_fps = 60
	if not GameMode.is_world_server():
		_fail("requires --mode=world-server")
		return
	var args := CmdlineUtils.get_parsed_args()
	player_count = clampi(int(args.get("bench-players", "100")), 0, 500)
	mob_count = clampi(int(args.get("bench-mobs", "200")), 0, 2000)
	warmup_seconds = clampf(float(args.get("bench-warmup", "3")), 1.0, 30.0)
	measurement_seconds = clampf(float(args.get("bench-seconds", "12")), 3.0, 120.0)
	include_per_peer_encode = str(args.get("bench-encode-per-peer", "0")) == "1"
	var api := multiplayer as SceneMultiplayer
	api.server_relay = false
	if peer.create_server(PORT, "127.0.0.1") != OK:
		_fail("isolated benchmark port unavailable")
		return
	api.multiplayer_peer = peer
	server = WorldServer.new()
	server.name = "Session"
	server.multiplayer_api = api
	add_child(server)
	ServerInstance.world_server = server
	var host: ServerInstance = preload("res://source/server/world/components/world_instance_3d.gd").new()
	host.name = "Instance"
	host.instance_resource = InstanceResource.new()
	host.instance_resource.instance_name = &"FirstRegion"
	host.load_map(WORLD_SCENE)
	add_child(host)
	world = host.get_node("GameWorld") as GameWorld3D
	world.set("encode_per_peer", include_per_peer_encode)
	# The five-second calendar RPC would target synthetic, nonexistent peers.
	world.world_time.set_process(false)
	# The test owns the mob tick: CombatEndpoint skips simulation when there is
	# no persistence/domain ready; this fixture intentionally has no DB.
	for id: int in world.mob_system.mobs.keys():
		world.mob_system.remove_mob(id)
	_build_players()
	_build_mobs()
	var begin := TickProbe.new()
	begin.process_physics_priority = -1000
	begin.record = _tick_begin
	add_child(begin)
	var end := TickProbe.new()
	end.process_physics_priority = 1000
	end.record = _tick_end
	add_child(end)
	call_deferred("_run_benchmark")

func _position_for(index: int) -> Vector3:
	# Inside the existing 32x32 physics arena, with deterministic density.
	var column := index % 30
	var line := int(index / 30)
	return Vector3(-13.0 + float(column) * 0.85, 0.15, -13.0 + float(line) * 0.85)

func _build_players() -> void:
	for index: int in player_count:
		var peer_id := 10000 + index
		var player := PlayerResource.new()
		player.player_id = index + 1
		player.account_name = "synthetic_%d" % index
		player.display_name = "Synthetic_%d" % index
		server.connected_players[peer_id] = player
		var body: PlayerActor3D = world._add_character(peer_id, player.display_name)
		body.position = _position_for(index)
		world.intentions[peer_id] = {"direction": Vector2.ZERO, "sequence": index, "time": Time.get_ticks_msec()}
		simulated_ids.append(peer_id)

func _build_mobs() -> void:
	if mob_count == 0:
		return
	# No real players means no valid target; that scenario measures idle mobs.
	for index: int in mob_count:
		var entry := MobSpawnEntry.new()
		entry.mob = DOG
		var anchor := _position_for(index % maxi(1, player_count)) + Vector3(0.4, 0.0, 2.0)
		var pack: MobPackRuntime = world.mob_system.create_pack([entry], anchor, 0.0, 0.0, 12.0, 0.0)
		if pack == null:
			_fail("failed to create mob pack")
			return
		var dog: MobActor3D = world.mob_system.mobs[pack.actor_ids[0]]
		dog.proximity_aggro = false
		if player_count > 0:
			dog.target_peer = simulated_ids[index % player_count]
			dog.ai_state = MobState.Value.CHASE
			# Exercise real chase/physics without sending combat RPC to a fake peer.
			dog.last_attack_ms = Time.get_ticks_msec() + 3600000

func _physics_process(delta: float) -> void:
	if world == null:
		return
	# Real MobSystem.tick() (the production CombatEndpoint calls this normally).
	world.mob_system.tick(delta, Time.get_ticks_msec())
	_input_elapsed += delta
	if _input_elapsed >= GameWorld3D.INPUT_INTERVAL:
		_input_elapsed = fmod(_input_elapsed, GameWorld3D.INPUT_INTERVAL)
		var now := Time.get_ticks_msec()
		for id: int in simulated_ids:
			var angle := float(id % 12) * PI / 6.0 + float(now % 10000) * 0.0001
			world.intentions[id] = {"direction": Vector2(cos(angle), sin(angle)), "sequence": 0, "time": now}

func _tick_begin(now: int) -> void:
	if not _sampling:
		return
	if _previous_tick > 0:
		intervals_us.append(now - _previous_tick)
	_previous_tick = now
	_started_tick = now

func _tick_end(now: int) -> void:
	if _sampling and _started_tick > 0:
		work_us.append(now - _started_tick)

func _percentiles(values: Array[int]) -> Dictionary:
	if values.is_empty():
		return {"n": 0, "p50_ms": 0.0, "p95_ms": 0.0, "p99_ms": 0.0, "max_ms": 0.0}
	var sorted := values.duplicate()
	sorted.sort()
	return {
		"n": sorted.size(),
		"p50_ms": float(sorted[clampi(ceili(sorted.size() * 0.50) - 1, 0, sorted.size() - 1)]) / 1000.0,
		"p95_ms": float(sorted[clampi(ceili(sorted.size() * 0.95) - 1, 0, sorted.size() - 1)]) / 1000.0,
		"p99_ms": float(sorted[clampi(ceili(sorted.size() * 0.99) - 1, 0, sorted.size() - 1)]) / 1000.0,
		"max_ms": float(sorted[-1]) / 1000.0
	}

func _run_benchmark() -> void:
	await get_tree().create_timer(warmup_seconds).timeout
	work_us.clear()
	intervals_us.clear()
	_previous_tick = 0
	_started_tick = 0
	world.call("reset_snapshot_metrics")
	var wall_started := Time.get_ticks_usec()
	_sampling = true
	await get_tree().create_timer(measurement_seconds).timeout
	_sampling = false
	var wall_seconds := float(Time.get_ticks_usec() - wall_started) / 1000000.0
	var late_ticks := 0
	for cost: int in work_us:
		if cost > BUDGET_US:
			late_ticks += 1
	var result := {
		"mode": "synthetic_world_no_clients",
		"players": player_count,
		"mobs": world.mob_system.mobs.size(),
		"physics_hz_target": Engine.physics_ticks_per_second,
		"max_fps": Engine.max_fps,
		"warmup_seconds": warmup_seconds,
		"duration_seconds": wall_seconds,
		"physics_work": _percentiles(work_us),
		"tick_interval": _percentiles(intervals_us),
		"physics_samples_over_16_67_ms": late_ticks,
		"observed_ticks_per_second": float(work_us.size()) / maxf(0.001, wall_seconds),
		"snapshot_count": world.get("snapshot_count"),
		"snapshot_build_ms_total": float(world.get("snapshot_build_us")) / 1000.0,
		"snapshot_encode_ms_total": float(world.get("snapshot_encode_us")) / 1000.0,
		"estimated_outbound_mib_per_second": float(world.get("estimated_wire_bytes")) / (1048576.0 * maxf(0.001, wall_seconds)),
		"encode_per_peer_proxy": include_per_peer_encode,
		"static_memory_mib": float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0,
		"caveat": "No network sockets per synthetic player, real RPC encode, client CPU, DB or economy; proxy must not be quoted as connected-client capacity."
	}
	print("WORLD_LOAD_RESULT ", JSON.stringify(result))
	peer.close()
	get_tree().quit(0)
