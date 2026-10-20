extends Node
const Identity = preload("res://source/server/world/database/postgres/identity_bootstrap_postgres.gd")
var pg: Object
var directory: String
var pids: Array[int]=[]
var request: HTTPRequest
var ports: Array
func _ready() -> void:
	Engine.max_fps=120
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	directory=OS.get_environment("MANDATE_PG_FIXTURE_DIR")
	ports=JSON.parse_string(OS.get_environment("MANDATE_PG_FIXTURE_PORTS"))
	get_tree().create_timer(110).timeout.connect(func()->void:get_tree().quit(1))
	request=HTTPRequest.new();add_child(request)
	call_deferred("run")
func write(path: String, text: String) -> void: FileAccess.open(directory+"/"+path,FileAccess.WRITE).store_string(text)
func start(role: String, resume: bool = false) -> int:
	var args: Array[String]=["--headless","--path",ProjectSettings.globalize_path("res://"),"--mode="+role+"-server","--config="+directory+"/"+role+".cfg","--dashboard-config="+directory+"/dashboard.cfg","--log-file",ProjectSettings.globalize_path(directory+"/"+role+("-restart" if resume else "")+".log"),"res://tests/postgres_process_role.tscn"]
	if role=="client":
		args[3]="--mode=client";args[-1]="res://tests/postgres_process_client.tscn"
		if resume: args.append("--resume=true")
	var pid:=OS.create_process(OS.get_executable_path(),args,false)
	assert(pid>0);pids.append(pid);return pid
func wait_exit(pid: int) -> void:
	var deadline:=Time.get_ticks_msec()+40000
	while OS.is_process_running(pid) and Time.get_ticks_msec()<deadline: await get_tree().process_frame
	assert(not OS.is_process_running(pid),"owned child timed out")
	pids.erase(pid)
func stop(role: String, pid: int) -> void:
	write("stop-"+role,"stop")
	await wait_exit(pid)
	assert(FileAccess.file_exists(directory+"/stopped-"+role))
	DirAccess.remove_absolute(directory+"/stop-"+role)
	DirAccess.remove_absolute(directory+"/stopped-"+role)
func wait_world() -> void:
	var deadline:=Time.get_ticks_msec()+20000
	var ready:=false
	while not ready and Time.get_ticks_msec()<deadline:
		if request.request(OS.get_environment("MANDATE_PG_FIXTURE_GATEWAY")+"/v1/worlds",["Content-Type: application/json"],HTTPClient.METHOD_POST,"{}")==OK:
			var response: Array=await request.request_completed
			if response[0]==HTTPRequest.RESULT_SUCCESS:
				var body: Variant=JSON.parse_string(response[3].get_string_from_utf8())
				ready=body is Dictionary and body.get("w",{}) is Dictionary and body.get("w",{}).size()==1 and not body.has("error")
		if not ready: await get_tree().create_timer(0.2).timeout
	assert(ready,"normal process World readiness")
func wait_marker(path: String) -> void:
	var deadline:=Time.get_ticks_msec()+15000
	while not FileAccess.file_exists(directory+"/"+path) and Time.get_ticks_msec()<deadline: await get_tree().process_frame
	assert(FileAccess.file_exists(directory+"/"+path),"fixture marker "+path)
func run() -> void:
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")))
	assert(preload("res://source/server/world/database/postgres/economy_schema_postgres.gd").ensure_schema(pg))
	var authority: String=pg.query("SELECT value FROM economy.meta WHERE key='economy_authority_id';").rows[0].value
	# Idempotent retry after an unobserved success cannot reset wallet or rebind.
	var identity:=Identity.new(pg)
	assert(identity.bind(900,900).ok)
	assert(pg.execute("UPDATE economy.account_wallets SET yang=1570 WHERE account_id=900;").ok)
	assert(identity.bind(900,900).ok)
	assert(not identity.bind(901,900).ok)
	assert(pg.query("SELECT yang FROM economy.account_wallets WHERE account_id=900;").rows[0].yang==1570)
	assert(pg.query("SELECT account_id FROM economy.accounts WHERE account_id=901;").rows.is_empty())
	var database:=WorldDatabase.new();add_child(database)
	assert(not database.start_profile_database(""))
	assert(database.start_profile_database(directory+"/legacy-refused.db"))
	assert(database.db.query("CREATE TABLE account_wallets(account_id INTEGER,yang INTEGER);"))
	assert(database.db.query("INSERT INTO account_wallets VALUES(1,1500);"))
	database.db.close_db()
	assert(not database.start_profile_database(directory+"/legacy-refused.db"))
	assert(database.economy_backend=="postgresql" and not database.wallet_ready)
	database.db.close_db();database.queue_free()
	var economy: String='\n[economy]\nbackend="postgresql"\nconnection_env="MANDATE_PG_FIXTURE_CONNECTION"\nauthority_id="'+authority+'"\n'
	write("master.cfg",'[gateway-manager-server]\nport='+str(ports[0])+'\nbind_address="127.0.0.1"\n[world-manager-server]\nport='+str(ports[1])+'\nbind_address="127.0.0.1"\n[authentication]\naccount_collection_path="'+directory+'/accounts.tres"\n'+economy)
	write("world.cfg",'[world-server]\nport='+str(ports[2])+'\nbind_address="127.0.0.1"\nname="PG Process Fixture"\n[world-manager-client]\naddress="127.0.0.1"\nport='+str(ports[1])+economy+'profile_path="'+directory+'/profiles.db"\n')
	write("gateway.cfg",'[gateway-server]\nport='+str(ports[3])+'\nbind_address="127.0.0.1"\n[gateway-manager-client]\naddress="127.0.0.1"\nport='+str(ports[0])+'\n')
	write("dashboard.cfg",'[server]\nport='+str(ports[4])+'\nbind="127.0.0.1"\n[auth]\ntoken="fixture-only"\n')
	var master:=start("master")
	await get_tree().create_timer(1).timeout
	var gateway:=start("gateway")
	var world:=start("world")
	await wait_world()
	var profile_read: Dictionary=pg.query("SELECT value FROM economy.meta WHERE key='world_profile_id';")
	assert(profile_read.ok and profile_read.rows.size()==1)
	var profile_id: String=profile_read.rows[0].value
	assert(identity.bind_profile(profile_id).ok)
	assert(not identity.bind_profile("0".repeat(32)).ok)
	assert(pg.query("SELECT value FROM economy.meta WHERE key='world_profile_id';").rows[0].value==profile_id)
	assert(identity.bind(900,1).ok)
	var client:=start("client")
	await wait_marker("identity-conflict-observed")
	assert(pg.query("SELECT account_id FROM economy.characters WHERE character_id=1;").rows[0].account_id==900)
	assert(pg.query("SELECT account_id FROM economy.accounts WHERE account_id=1;").rows.is_empty(),"failed bind rolls back wallet/account creation")
	# Operator repair on the disposable fixture only; no items/grants exist for it.
	assert(pg.execute("DELETE FROM economy.characters WHERE character_id=1;").ok)
	write("identity-conflict-cleared","ok")
	await wait_exit(client)
	assert("POSTGRES_PROCESS_CLIENT_OK" in FileAccess.get_file_as_string(directory+"/client.log"))
	var report: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory+"/client-report.json"))
	var durable: Dictionary=pg.query("SELECT account_id FROM economy.characters WHERE character_id=:character;",{"character":int(report.character)})
	assert(durable.ok and int(durable.rows[0].account_id)==int(report.account))
	await stop("world",world)
	await stop("gateway",gateway)
	await stop("master",master)
	var profiles:=SQLite.new();profiles.path=directory+"/profiles.db";assert(profiles.open_db())
	assert(profiles.query("SELECT name FROM sqlite_master WHERE type='table' AND name='account_wallets';") and profiles.query_result.is_empty())
	assert(profiles.query("SELECT COUNT(*) AS n FROM item_instances;") and profiles.query_result[0].n==0)
	assert(profiles.query("SELECT COUNT(*) AS n FROM players;") and profiles.query_result[0].n==1)
	profiles.close_db()
	# Fresh normal processes, same trusted profile/PG realm. No fixture grants.
	master=start("master",true)
	await get_tree().create_timer(1).timeout
	gateway=start("gateway",true);world=start("world",true)
	await wait_world()
	client=start("client",true);await wait_exit(client)
	assert("POSTGRES_PROCESS_CLIENT_OK restart" in FileAccess.get_file_as_string(directory+"/client-restart.log"))
	await stop("world",world);await stop("gateway",gateway);await stop("master",master)
	pg.close()
	print("POSTGRES_PROCESS_STARTUP_OK: real Gateway/Master/World creation, grant, equip, relog, restart and clean drain")
	get_tree().quit()
func _exit_tree() -> void:
	for pid: int in pids:
		if OS.is_process_running(pid): OS.kill(pid)
