extends GameWorld3D
## Strictly benchmark-only overrides: same production actor code except in an
## explicitly selected ablation. No synthetic peer ever receives an RPC.
const BENCH_PLAYERS := preload("res://tests/fixtures/bench_player_actor.gd")
const BENCH_MOBS := preload("res://tests/fixtures/bench_mob_actor.gd")
const BENCH_SYSTEM := preload("res://tests/fixtures/bench_mob_system.gd")
var skip_overlap := false
var use_light_player := false
var wide_arena := OS.get_environment("MANDATE_BENCH_WIDE") == "1"

func _init() -> void:
	mob_system = BENCH_SYSTEM.new()

func _build_arena() -> void:
	if wide_arena:
		_box("Floor", Vector3(0, -0.25, 0), Vector3(512, 0.5, 512), Color("374957"))
	else:
		super._build_arena()

func configure_profile(skip: bool, no_slide: bool, ai_period_ms: int, light_player: bool = false) -> void:
	skip_overlap = skip
	use_light_player = light_player
	mob_system.no_slide = no_slide
	mob_system.ai_period_ms = ai_period_ms

func _add_character(peer_id: int, display_name: String) -> PlayerActor3D:
	var body := BENCH_PLAYERS.new()
	body.name = "Character_%d" % peer_id
	body.setup(display_name, Color.from_hsv(float(peer_id % 360) / 360.0, 0.55, 0.9))
	body.skip_overlap = skip_overlap
	body.lightweight_motion = use_light_player
	add_child(body)
	characters[peer_id] = body
	return body

func reset_profile_metrics() -> void:
	BENCH_PLAYERS.reset_metrics()
	BENCH_MOBS.reset_metrics()
	mob_system.reset_metrics()

func profile_metrics() -> Dictionary:
	return {
		"player_simulate_ms_total": float(BENCH_PLAYERS.simulate_us) / 1000.0,
		"overlap_query_ms_total": float(BENCH_PLAYERS.overlap_us) / 1000.0,
		"overlap_calls": BENCH_PLAYERS.overlap_calls,
		"mob_tick_ms_total": float(mob_system.total_tick_us) / 1000.0,
		"mob_decision_including_motion_ms_total": float(mob_system.decision_us) / 1000.0,
		"mob_decision_calls": mob_system.decision_calls,
		"mob_motion_ms_total": float(BENCH_MOBS.motion_us) / 1000.0,
		"mob_motion_calls": BENCH_MOBS.motion_calls
	}

var encode_per_peer := false
var snapshot_count := 0
var snapshot_build_us := 0
var snapshot_encode_us := 0
var estimated_wire_bytes := 0

func reset_snapshot_metrics() -> void:
	snapshot_count = 0
	snapshot_build_us = 0
	snapshot_encode_us = 0
	estimated_wire_bytes = 0

func _broadcast_snapshot() -> void:
	var started := Time.get_ticks_usec()
	var snapshot: Dictionary = {}
	for peer_id: int in characters:
		var body: PlayerActor3D = characters[peer_id]
		snapshot[peer_id] = [body.position, body.rotation.y]
	snapshot_build_us += Time.get_ticks_usec() - started
	var encode_started := Time.get_ticks_usec()
	var payload := var_to_bytes(snapshot)
	estimated_wire_bytes += payload.size() * characters.size()
	if encode_per_peer:
		# Upper-bound *encoding* proxy for the current full-roster per-peer fan-out.
		# Native RPC encoding/compression, OS sockets and receivers are not tested.
		for index: int in characters.size():
			var_to_bytes(snapshot)
	snapshot_encode_us += Time.get_ticks_usec() - encode_started
	snapshot_count += 1
