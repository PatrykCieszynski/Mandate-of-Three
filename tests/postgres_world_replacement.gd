extends "res://tests/postgres_maintenance.gd"
## Same-host, sequential replacement. Not live cross-World migration/failover.
class Probe extends BaseMultiplayerEndpoint:
	var token: String
	var accepted:=false
	var rejected:=false
	func _connect_multiplayer_api_signals(api: SceneMultiplayer) -> void:
		api.auth_callback=func(_peer: int,_data: PackedByteArray)->void:
			api.send_auth(1,var_to_bytes(token));api.complete_auth(1)
		api.connected_to_server.connect(func()->void:accepted=true)
		api.peer_authentication_failed.connect(func(_peer: int)->void:rejected=true)
		api.connection_failed.connect(func()->void:rejected=true)
		api.server_disconnected.connect(func()->void:rejected=true)
func worlds() -> Dictionary:
	return await post(OS.get_environment("MANDATE_PG_FIXTURE_GATEWAY")+"/v1/worlds",{})
func shutdown_world() -> void:
	var roster: Dictionary=await worlds()
	assert(roster.w.size()==1)
	var result: Dictionary=await post("http://127.0.0.1:"+str(int(ports[4]))+"/v1/worlds/shutdown",{"token":"fixture-only","world_id":int(roster.w.keys()[0])})
	assert(result.ok) # Accepted is not proof of process exit.
func wait_absent() -> void:
	var deadline:=Time.get_ticks_msec()+5000
	while Time.get_ticks_msec()<deadline:
		if (await worlds()).w.is_empty(): return
		await get_tree().process_frame
	assert(false,"draining World must disappear from routing before drain completes")
func wait_revoked(account: int) -> void:
	var deadline:=Time.get_ticks_msec()+5000
	while Time.get_ticks_msec()<deadline:
		if pg.query("SELECT phase FROM economy.inventory_sessions WHERE account_id=:id;",{"id":account}).rows[0].phase=="revoked": return
		await get_tree().process_frame
	assert(false,"old World grant was not retired")
func close_roles(world: int, gateway: int, master: int) -> void:
	round_number+=1
	if round_number==1: await failures()
	var report: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory+"/client-report.json"))
	var balance: int=int(pg.query("SELECT yang FROM economy.account_wallets WHERE account_id=:id;",{"id":int(report.account)}).rows[0].yang)
	var client:=held_client();await wait_marker("maintenance-client-ready")
	write("seed-maintenance","seed");await wait_marker("maintenance-seeded")
	DirAccess.remove_absolute(directory+"/seed-maintenance")
	var expected: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory+"/maintenance-seeded"))
	var old_ticket: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory+"/maintenance-ticket.json"))
	# Actual in-flight SQL: drain must wait, without letting new entry through.
	assert(pg.begin())
	assert(pg.execute("LOCK TABLE economy.account_wallets IN ACCESS EXCLUSIVE MODE;").ok)
	await shutdown_world()
	await wait_absent()
	assert(OS.is_process_running(world) and OS.is_process_running(master))
	var draining: Dictionary=await admin("status")
	assert(draining.master.state=="READY" and draining.worlds.size()==1 and draining.worlds[0].draining and not draining.worlds[0].ready)
	assert(pg.query("SELECT 1;").ok)
	await get_tree().create_timer(0.15).timeout
	assert(pg.rollback())
	await wait_exit(world);await wait_exit(client)
	assert(OS.is_process_running(master) and OS.is_process_running(gateway))
	assert((await admin("status")).master.state=="READY")
	assert(int(pg.query("SELECT yang FROM economy.account_wallets WHERE account_id=:id;",{"id":int(report.account)}).rows[0].yang)==balance+37)
	await wait_revoked(int(report.account))
	assert(int(pg.query("SELECT count(*) AS n FROM pg_stat_activity WHERE application_name LIKE 'mandate-inventory-executor-%';").rows[0].n)==1,"only the live Master's control worker remains")
	var profiles:=SqliteSoci.new();profiles.path=directory+"/profiles.db";assert(profiles.open_db())
	assert(profiles.query_with_bindings("SELECT level,experience,available_attributes_points FROM players WHERE player_id=?;",[int(report.character)]))
	assert(profiles.query_result[0].level==expected.level and profiles.query_result[0].experience==expected.experience and profiles.query_result[0].available_attributes_points==expected.points)
	profiles.close_db()
	# A replacement is started only after confirmed old-process exit. Same files,
	# same port/realm, live Master and Gateway. No fabricated grants or DB repair.
	var replacement:=start("world",true)
	await wait_world()
	var probe:=Probe.new();probe.token=old_ticket["auth-token"];add_child(probe)
	assert(probe.create(BaseMultiplayerEndpoint.Role.CLIENT,"127.0.0.1",int(ports[2]))==OK)
	var deadline:=Time.get_ticks_msec()+5000
	while not probe.rejected and not probe.accepted and Time.get_ticks_msec()<deadline: await get_tree().process_frame
	assert(probe.rejected and not probe.accepted,"old ticket cannot authenticate to replacement")
	probe.peer.close();get_tree().set_multiplayer(null,probe.get_path());probe.queue_free()
	client=start("client",true);await wait_exit(client)
	assert("POSTGRES_PROCESS_CLIENT_OK restart" in FileAccess.get_file_as_string(directory+"/client-restart.log"))
	await shutdown_world();await wait_exit(replacement);await wait_absent()
	assert(DirAccess.copy_absolute(directory+"/world-restart.log",directory+"/world-replacement-"+str(round_number)+".log")==OK)
	await stop("gateway",gateway);await stop("master",master)
	if round_number==2:
		print("POSTGRES_WORLD_REPLACEMENT_OK: dirty drain, routing fence, old-ticket refusal and normal UID login while Master/Gateway stay alive")
