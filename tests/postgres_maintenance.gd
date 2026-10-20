extends "res://tests/postgres_process_startup.gd"
const Barrier = preload("res://source/server/master/operations/realm_maintenance.gd")
var round_number:=0
class Drain extends RefCounted:
	var stopped:=false
	func shutdown_master() -> bool: stopped=true;return true
	func ready() -> bool: return not stopped
	func status() -> Dictionary: return {"stopped":stopped}
class Accounts extends AuthenticationManager:
	var writable:=true
	func _ready() -> void: pass
	func checkpoint_accounts(_freeze: bool = false) -> bool: return writable
class Master extends WorldManagerServer:
	func _ready() -> void: pass
	func _process(_delta: float) -> void: pass
class RejectingProfiles extends WorldStoreSqlite:
	var reject:=true
	var saved_status: String=""
	func _init() -> void: super(null)
	func save_player(player: PlayerResource) -> bool:
		if reject: return false
		saved_status=player.profile_status;return true
class Profiles extends WorldDatabase:
	var closed:=false
	func _ready() -> void: pass
	func save_all_connected(_connected: Dictionary) -> int: return 0
	func shutdown_database() -> bool: closed=true;return true
class ProfileWorld extends WorldServer:
	func _ready() -> void: pass
	func _process(_delta: float) -> void: pass
	func shutdown_economy() -> bool:
		for player: PlayerResource in connected_players.values(): player.profile_status="final disconnect"
		connected_players.clear();economy_bootstrap.stopped=true;return true
func fake() -> Master:
	var master:=Master.new()
	master.authentication_manager=Accounts.new();master.add_child(master.authentication_manager)
	master.economy_bootstrap=Drain.new()
	master.connected_worlds[7]={}
	return master
func failures() -> void:
	var dashboard: Node=preload("res://source/server/master/dashboard/dashboard_server.gd").new()
	assert(dashboard._handle_economy_status({"token":"anything"}).error=="unauthorized")
	assert(dashboard._handle_economy_quiesce({"operation_id":"a".repeat(32)}).error=="unauthorized")
	dashboard.free()
	var id: String="a".repeat(32)
	var master:=fake()
	var barrier:=Barrier.new(master,id,7);master.maintenance=barrier
	assert(not barrier.acknowledge(8,id,{"ok":true,"profiles_closed":true,"workers_stopped":true}))
	assert(not barrier.acknowledge(7,"b".repeat(32),{"ok":true,"profiles_closed":true,"workers_stopped":true}))
	assert(barrier.status().phase=="WORLD_DRAIN" and master.economy_bootstrap.ready())
	barrier.poll(Time.get_ticks_msec()+60000)
	assert(barrier.status().phase=="BLOCKED" and not barrier.status().quiesced and not master.admissions_open())
	assert(not barrier.acknowledge(7,id,{"ok":true,"profiles_closed":true,"workers_stopped":true}))
	assert(master.economy_bootstrap.ready(),"a timeout cannot skip the World barrier")
	assert(master.begin_maintenance(id).maintenance.phase=="BLOCKED")
	assert(master.begin_maintenance("c".repeat(32)).error=="maintenance_active")
	master.free()
	master=fake();barrier=Barrier.new(master,id,7);master.maintenance=barrier
	assert(barrier.acknowledge(7,id,{"ok":false}))
	assert(barrier.status().phase=="BLOCKED" and master.economy_bootstrap.ready())
	master.free()
	master=fake();barrier=Barrier.new(master,id,7);master.maintenance=barrier
	assert(barrier.acknowledge(7,id,{"ok":true,"profiles_closed":"true","workers_stopped":true}))
	assert(barrier.status().phase=="BLOCKED" and master.economy_bootstrap.ready())
	master.free()
	master=fake();barrier=Barrier.new(master,id,7);master.maintenance=barrier
	master.connected_worlds.erase(7);barrier.poll()
	assert(barrier.status().error=="world_disconnected" and not barrier.status().quiesced)
	master.free()
	master=fake();barrier=Barrier.new(master,id,7);master.maintenance=barrier
	master.authentication_manager.writable=false
	assert(barrier.acknowledge(7,id,{"ok":true,"profiles_closed":true,"workers_stopped":true}))
	assert(barrier.status().error=="accounts_checkpoint" and not barrier.status().quiesced)
	master.free()
	var world:=ProfileWorld.new();world.database=Profiles.new();world.add_child(world.database)
	world.database.store=RejectingProfiles.new();world.economy_bootstrap=Drain.new()
	var player:=PlayerResource.new();player.player_id=1;player.current_peer_id=7
	world.connected_players[7]=player;world.player_id_to_peer_id[1]=7
	var operation:=preload("res://source/server/world/operations/world_maintenance.gd").new(world)
	assert(not (await operation.run()).ok and not world.database.closed)
	world.database.store.reject=false
	assert((await operation.run()).ok and world.database.closed)
	assert(world.database.store.saved_status=="final disconnect","failed profile save must retain the latest resource for recovery")
	world.free()
func post(url: String, payload: Dictionary) -> Dictionary:
	assert(request.request(url,["Content-Type: application/json"],HTTPClient.METHOD_POST,JSON.stringify(payload))==OK)
	var reply: Array=await request.request_completed
	assert(reply[0]==HTTPRequest.RESULT_SUCCESS and reply[1]==200)
	return JSON.parse_string(reply[3].get_string_from_utf8())
func admin(path: String, payload: Dictionary = {}) -> Dictionary:
	var body:=payload.duplicate(true);body.token="fixture-only"
	return await post("http://127.0.0.1:"+str(int(ports[4]))+"/v1/economy/"+path,body)
func held_client() -> int:
	for file: String in ["maintenance-client-ready","maintenance-seeded"]:
		if FileAccess.file_exists(directory+"/"+file): DirAccess.remove_absolute(directory+"/"+file)
	var pid:=OS.create_process(OS.get_executable_path(),["--headless","--path",ProjectSettings.globalize_path("res://"),"--mode=client","--resume=true","--maintenance=true","--log-file",ProjectSettings.globalize_path(directory+"/maintenance-client-"+str(round_number)+".log"),"res://tests/postgres_process_client.tscn"],false)
	assert(pid>0);pids.append(pid);return pid
func close_roles(world: int, gateway: int, master: int) -> void:
	round_number+=1
	if round_number==1: await failures()
	var base: String="http://127.0.0.1:"+str(int(ports[4]))+"/v1/economy/"
	assert((await post(base+"status",{})).error=="unauthorized")
	assert((await post(base+"quiesce",{"operation_id":"d".repeat(32)})).error=="unauthorized")
	var before: Dictionary=await admin("status")
	assert(before.admissions_open and before.master.state=="READY" and before.maintenance.is_empty())
	assert(not JSON.stringify(before).contains(OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")))
	var report: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory+"/client-report.json"))
	var balance: int=int(pg.query("SELECT yang FROM economy.account_wallets WHERE account_id=:id;",{"id":int(report.account)}).rows[0].yang)
	var client:=held_client();await wait_marker("maintenance-client-ready")
	write("seed-maintenance","seed")
	await wait_marker("maintenance-seeded")
	DirAccess.remove_absolute(directory+"/seed-maintenance")
	var expected: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory+"/maintenance-seeded"))
	assert(int(pg.query("SELECT yang FROM economy.account_wallets WHERE account_id=:id;",{"id":int(report.account)}).rows[0].yang)==balance,"income must still be dirty before operator barrier")
	var id: String=Crypto.new().generate_random_bytes(16).hex_encode()
	var started: Dictionary=await admin("quiesce",{"operation_id":id})
	assert(started.ok and not started.maintenance.admissions_open)
	assert((await admin("quiesce",{"operation_id":id})).ok)
	assert((await admin("quiesce",{"operation_id":"f".repeat(32)})).error=="maintenance_active")
	# New identity mutations must fail, even with a valid Gateway connection.
	var refused: Dictionary=await post(OS.get_environment("MANDATE_PG_FIXTURE_GATEWAY")+"/v1/guest",{})
	assert(refused.has("error"))
	var deadline:=Time.get_ticks_msec()+20000
	var status: Dictionary=await admin("status")
	while status.maintenance.phase not in ["QUIESCED","BLOCKED"] and Time.get_ticks_msec()<deadline:
		await get_tree().create_timer(0.1).timeout
		status=await admin("status")
	assert(status.maintenance.quiesced and status.master.stopped and status.master.pending==0)
	assert(not status.admissions_open)
	var worlds: Dictionary=await post(OS.get_environment("MANDATE_PG_FIXTURE_GATEWAY")+"/v1/worlds",{})
	assert(worlds.w.is_empty())
	await wait_exit(client)
	assert("POSTGRES_PROCESS_CLIENT_OK maintenance disconnect" in FileAccess.get_file_as_string(directory+"/maintenance-client-"+str(round_number)+".log"))
	assert(int(pg.query("SELECT yang FROM economy.account_wallets WHERE account_id=:id;",{"id":int(report.account)}).rows[0].yang)==balance+37)
	assert(int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name LIKE 'mandate-inventory-executor-%';").rows[0].n)==0)
	var profiles:=SQLite.new();profiles.path=directory+"/profiles.db";assert(profiles.open_db())
	assert(profiles.query_with_bindings("SELECT level,experience,available_attributes_points FROM players WHERE player_id=?;",[int(report.character)]))
	assert(profiles.query_result[0].level==expected.level and profiles.query_result[0].experience==expected.experience and profiles.query_result[0].available_attributes_points==expected.points)
	profiles.close_db()
	var accounts_hash: String=FileAccess.get_sha256(directory+"/accounts.tres")
	var refused_admin: Dictionary=await post("http://127.0.0.1:"+str(int(ports[4]))+"/v1/accounts/reset_password",{"token":"fixture-only","username":"processfixture","new_password":"Must-not-be-written"})
	assert(refused_admin.error=="maintenance" and FileAccess.get_sha256(directory+"/accounts.tres")==accounts_hash)
	# Lost operator response: same ID reports the completed barrier, no new drain.
	assert((await admin("quiesce",{"operation_id":id})).maintenance.quiesced)
	await super.close_roles(world,gateway,master)
	assert(FileAccess.get_sha256(directory+"/accounts.tres")==accounts_hash,"tree exit must not rewrite a frozen checkpoint")
	if round_number==2:
		await blocked_native()
		print("POSTGRES_MAINTENANCE_OK: authenticated status, active-session dirty drain, operator replay, restart and fail-closed SQL/timeout contracts")

func blocked_native() -> void:
	# Only the owned fixture is forcibly cleaned after the EXPECTED refusal.
	# The production operator API has no force/resume/discard-money path.
	round_number=3
	var master:=start("master",true)
	await get_tree().create_timer(1).timeout
	var gateway:=start("gateway",true);var world:=start("world",true)
	await wait_world()
	var report: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory+"/client-report.json"))
	var old_balance: int=int(pg.query("SELECT yang FROM economy.account_wallets WHERE account_id=:id;",{"id":int(report.account)}).rows[0].yang)
	var client:=held_client();await wait_marker("maintenance-client-ready")
	write("seed-maintenance","seed");await wait_marker("maintenance-seeded")
	DirAccess.remove_absolute(directory+"/seed-maintenance")
	assert(pg.begin())
	assert(pg.execute("LOCK TABLE economy.account_wallets IN ACCESS EXCLUSIVE MODE;").ok)
	var id: String=Crypto.new().generate_random_bytes(16).hex_encode()
	assert((await admin("quiesce",{"operation_id":id})).ok)
	var deadline:=Time.get_ticks_msec()+18000
	var status: Dictionary=await admin("status")
	while status.maintenance.phase not in ["BLOCKED","QUIESCED"] and Time.get_ticks_msec()<deadline:
		# The controller deliberately holds a live lock; do not let the fixture's
		# idle-transaction guard release it and accidentally turn this into recovery.
		assert(pg.query("SELECT 1;").ok)
		await get_tree().create_timer(0.1).timeout;status=await admin("status")
	assert(status.maintenance.phase=="BLOCKED" and not status.maintenance.quiesced and not status.admissions_open)
	assert(status.master.state=="READY" and not status.master.stopped,"Master cannot revoke/checkpoint ahead of the failed World barrier")
	assert(pg.rollback())
	assert(int(pg.query("SELECT yang FROM economy.account_wallets WHERE account_id=:id;",{"id":int(report.account)}).rows[0].yang)==old_balance)
	write("observe-blocked","observe");await wait_marker("blocked-wallet-report")
	var blocked: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory+"/blocked-wallet-report"))
	assert(blocked.state=="BLOCKED" and not blocked.drained and blocked.players==1 and not blocked.workers_stopped)
	assert((await admin("quiesce",{"operation_id":id})).maintenance.phase=="BLOCKED")
	assert((await admin("quiesce",{"operation_id":"f".repeat(32)})).error=="maintenance_active")
	print("POSTGRES_MAINTENANCE_BLOCKED_OK: dirty money retained, no success certificate or premature Master drain")
	# Dispose this failed simulation only. No DB/player data survives the fixture.
	for pid: int in [client,world,gateway,master]:
		if OS.is_process_running(pid): OS.kill(pid)
		pids.erase(pid)
