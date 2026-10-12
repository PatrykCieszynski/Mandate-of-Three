extends "res://tests/pve_network.gd"
## Reuse the real two-client fixture for the new calendar/authority contract.
var listening: bool = false

func _ready() -> void:
	# A later entry must join the running calendar instead of starting its own day.
	if not GameMode.is_world_server() and CmdlineUtils.get_parsed_args().get("test-client", "0") == "2":
		await get_tree().create_timer(0.8).timeout
	super._ready()

func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size() == 2 and ready_peers.size() == 2)
	check(world.world_time.clock.rate == server.world_time.rate and absf(world.world_time.clock.unix_time()-server.world_time.unix_time()) < 1.0, "map uses World Server calendar/rate")
	var settings: WorldTimeSettings = preload("res://source/common/gameplay/world_time/world_time_settings.tres")
	var real_sample: float = Time.get_unix_time_from_system()
	check(absf(server.world_time.unix_time()-settings.game_time_at(real_sample)) < 1.0, "UTC epoch derives calendar after restart")
	# A second map clock shares the same process calendar instead of resetting it.
	var second_clock := WorldTimeSync3D.new()
	second_clock.services = world.services
	world.add_child(second_clock)
	check(second_clock.clock.rate == server.world_time.rate and absf(second_clock.clock.unix_time()-server.world_time.unix_time()) < 1.0,"second map receives the same authority calendar")
	second_clock.queue_free()
	for id: int in world.characters: world.world_time.publish_to(id)
	set_phase("CHECK")
	await wait_until(func() -> bool: return replies.size() == 2)
	var samples: Array = replies.values()
	check(absf(samples[0].time-samples[1].time) < 2.0,"two clients agree within local transport sampling delay")
	await get_tree().create_timer(WorldTimeSync3D.SYNC_INTERVAL+0.3).timeout
	set_phase("REFRESH")
	await wait_until(func() -> bool: return replies.size() == 2)
	for value: Dictionary in replies.values():
		check(value.progressed and absf(value.time-server.world_time.unix_time()) < 3.0,"periodic resync and hitch-free extrapolation")
	set_phase("DONE")
	await wait_until(func() -> bool: return done_peers.size() == 2)
	print("WORLD_TIME_SERVER_OK: shared epoch, two-client entry/progression/resync and no visual server nodes")
	world.process_mode = Node.PROCESS_MODE_DISABLED
	peer.close()
	db.close_db()
	get_tree().quit(1 if failed else 0)

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed > 25: check(false,"world time network timeout: "+phase_name)
	if GameMode.is_world_server() or world == null or not world.world_time.clock.synchronized: return
	if not listening:
		listening = true
		register_ready.rpc_id(1)
	if phase_name in ["WAIT","DONE"] or attempted: return
	attempted = true
	var clock: WorldTime = world.world_time.clock
	var start: float = clock.unix_time()
	# The client path also rejects a malformed/stale replacement of the calendar.
	world.world_time.receive_time(NAN,clock.rate,2147483646)
	world.world_time.receive_time(0.0,clock.rate,-1)
	check(clock.unix_time() == start,"malformed/stale samples cannot replace time")
	await get_tree().create_timer(0.15).timeout
	report.rpc_id(1,{"ok":true,"time":clock.unix_time(),"progressed":clock.unix_time()>start})

@rpc("authority","call_remote","reliable",0)
func phase(command: String, uid: String) -> void:
	if GameMode.is_world_server(): return
	phase_name = command
	drop_uid = uid
	attempted = false
	if command == "DONE":
		# Absolute calendar interpolation crosses midnight in the forward direction.
		var near_midnight: int = Time.get_unix_time_from_datetime_string("2025-06-21T23:59:59")
		var probe := WorldTime.new()
		check(probe.accept_sample(near_midnight,15.0,1),"initial calendar sample")
		probe.advance(0.2)
		check(probe.unix_time() > near_midnight and Time.get_datetime_dict_from_unix_time(int(probe.unix_time())).day == 22,"midnight rollover preserves date/progression")
		var before: float = probe.unix_time()
		check(probe.accept_sample(before+1,15.0,2) and probe.unix_time()==before,"resync corrects without a presentation jump")
		check(not probe.accept_sample(0,1,1),"out-of-order sample rejected")
		check(probe.accept_sample(before-100,15.0,3),"delayed valid authority sample")
		probe.advance(0.1)
		check(probe.unix_time() >= before,"delayed correction cannot run the calendar backwards")
		print("WORLD_TIME_CLIENT_OK: ",client_number," entry, extrapolation, resync, midnight and invalid sample rejection")
		finished.rpc_id(1)
		await get_tree().create_timer(0.3).timeout
		world.process_mode = Node.PROCESS_MODE_DISABLED
		peer.close()
		get_tree().quit(1 if failed else 0)
