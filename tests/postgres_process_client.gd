extends "res://tests/items_session.gd"
func run() -> void:
	ProjectSettings.set_setting("network/api/base_url",OS.get_environment("MANDATE_PG_FIXTURE_GATEWAY"))
	var resume: bool=CmdlineUtils.get_parsed_args().has("resume")
	var credentials: Dictionary={"a-u":"processfixture","a-p":"Fixture-only-strong-password-1","c-v":GatewayAPI.game_version()}
	if not resume: await api(GatewayAPI.account_create(),credentials)
	var session: Dictionary=await api(GatewayAPI.login(),credentials)
	assert(not session.is_empty() and session.w.size()==1)
	var identity: Dictionary={"w-id":int(session.w.keys()[0]),"t-id":session.session_id,"a-u":session.name}
	if resume:
		await restored(identity);return
	identity.data={"name":"Process"+str(Time.get_ticks_usec()).right(6),"skin":1}
	# The coordinator preinstalled a foreign mapping for character 1. Profile
	# commit succeeds, PG rejects it, and no usable World ticket may escape.
	var rejection:=await rejected(GatewayAPI.world_create_char(),identity)
	assert(rejection.has("error"))
	identity.erase("data")
	var existing: Dictionary=await api(GatewayAPI.world_characters(),identity)
	assert(existing.size()==1)
	identity["c-id"]=int(existing.keys()[0])
	assert((await rejected(GatewayAPI.world_enter(),identity)).has("error"))
	var directory: String=OS.get_environment("MANDATE_PG_FIXTURE_DIR")
	FileAccess.open(directory+"/identity-conflict-observed",FileAccess.WRITE).store_string("ok")
	while not FileAccess.file_exists(directory+"/identity-conflict-cleared"): await get_tree().process_frame
	var handoff: Dictionary=await api(GatewayAPI.world_enter(),identity)
	assert(handoff.has("auth-token"))
	Client.connect_to_server(handoff.address,handoff.port,handoff["auth-token"])
	await wait_inventory()
	assert(world.inventory_endpoint.state.ok and world.inventory_endpoint.state.items.size()==2)
	var item: Dictionary=world.inventory_endpoint.state.items[0].duplicate(true)
	await action("equip",item)
	assert(world.inventory_endpoint.state.equipment.weapon==item.uid)
	var persisted: Dictionary=world.inventory_endpoint.state.duplicate(true)
	Client.close_connection();Client.instance_manager.teardown();world=null
	await get_tree().create_timer(1.5).timeout
	identity.erase("data")
	var characters: Dictionary=await api(GatewayAPI.world_characters(),identity)
	assert(characters.size()==1)
	identity["c-id"]=int(characters.keys()[0])
	handoff=await api(GatewayAPI.world_enter(),identity)
	assert(handoff.has("auth-token"))
	Client.connect_to_server(handoff.address,handoff.port,handoff["auth-token"])
	await wait_inventory()
	for field: String in ["items","equipment","stats","item_state"]: assert(world.inventory_endpoint.state[field]==persisted[field],field)
	var report: Dictionary={"account":session.id,"character":identity["c-id"],"uid":item.uid}
	FileAccess.open(OS.get_environment("MANDATE_PG_FIXTURE_DIR")+"/client-report.json",FileAccess.WRITE).store_string(JSON.stringify(report))
	print("POSTGRES_PROCESS_CLIENT_OK")
	Client.close_connection()
	get_tree().quit()

func rejected(url: String, payload: Dictionary) -> Dictionary:
	assert(request.request(url,["Content-Type: application/json"],HTTPClient.METHOD_POST,JSON.stringify(payload))==OK)
	var response: Array=await request.request_completed
	assert(response[0]==HTTPRequest.RESULT_SUCCESS and response[1]==200)
	return JSON.parse_string(response[3].get_string_from_utf8())

func restored(identity: Dictionary) -> void:
	var report: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("MANDATE_PG_FIXTURE_DIR")+"/client-report.json"))
	identity["c-id"]=int(report.character)
	var handoff: Dictionary=await api(GatewayAPI.world_enter(),identity)
	assert(handoff.has("auth-token"))
	Client.connect_to_server(handoff.address,handoff.port,handoff["auth-token"])
	await wait_inventory()
	assert(world.inventory_endpoint.state.items.size()==2 and world.inventory_endpoint.state.equipment.weapon==report.uid)
	if CmdlineUtils.get_parsed_args().has("maintenance"):
		FileAccess.open(OS.get_environment("MANDATE_PG_FIXTURE_DIR")+"/maintenance-ticket.json",FileAccess.WRITE).store_string(JSON.stringify(handoff))
		process_mode=Node.PROCESS_MODE_ALWAYS
		FileAccess.open(OS.get_environment("MANDATE_PG_FIXTURE_DIR")+"/maintenance-client-ready",FileAccess.WRITE).store_string("ready")
		while Client.is_connected_to_server: await get_tree().process_frame
		get_tree().paused=false
		print("POSTGRES_PROCESS_CLIENT_OK maintenance disconnect")
		get_tree().quit();return
	print("POSTGRES_PROCESS_CLIENT_OK restart")
	Client.close_connection();get_tree().quit()
