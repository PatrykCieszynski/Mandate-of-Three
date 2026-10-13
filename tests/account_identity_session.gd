extends Node
## Opt-in production Gateway/Master/World path; registered + guest account, four alts.
var request := HTTPRequest.new()
var world_ready := false
var elapsed := 0.0
var db := SQLite.new()

func _ready() -> void:
	add_child(request)
	ClientState.world_ready.connect(func(_player: Node) -> void: world_ready = true)
	run.call_deferred()

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed > 60:
		push_error("ACCOUNT_SESSION_FAILED timeout")
		get_tree().quit(1)

func api(url: String, payload: Dictionary) -> Dictionary:
	assert(request.request(url,["Content-Type: application/json"],HTTPClient.METHOD_POST,JSON.stringify(payload))==OK)
	var response: Array = await request.request_completed
	assert(response[0]==HTTPRequest.RESULT_SUCCESS and response[1]==200)
	var result: Variant = JSON.parse_string(response[3].get_string_from_utf8())
	assert(result is Dictionary)
	return result

func run() -> void:
	var accounts: Array[Dictionary] = []
	var ids: Array[Array] = []
	for index: int in 2:
		var session: Dictionary
		if index == 0:
			var credentials := {"a-u":"identity"+str(Time.get_ticks_usec()).right(6),"a-p":"IdentityTest!2026","c-v":GatewayAPI.game_version()}
			assert(not (await api(GatewayAPI.account_create(),credentials)).has("error"))
			session = await api(GatewayAPI.login(),credentials)
		else:
			session = await api(GatewayAPI.guest(),{})
		assert(not session.has("error") and not session.w.is_empty())
		accounts.append(session)
		var identity := {"t-id":session.session_id,"a-u":session.name,"a-id":-999,"w-id":int(session.w.keys()[0])}
		for alt: int in 2:
			identity.data = {"name":"Ident%s%s%s" % [index,alt,str(Time.get_ticks_usec()).right(6)],"skin":1}
			var created := await api(GatewayAPI.world_create_char(),identity)
			assert(created.has("auth-token") and not created.has("error"),"forged numeric account ID cannot replace trusted session owner")
		identity.erase("data")
		var characters := await api(GatewayAPI.world_characters(),identity)
		assert(characters.size()==2 and not characters.has("error"))
		ids.append(characters.keys())
	var forged := {"t-id":accounts[0].session_id,"a-u":accounts[1].name,"w-id":int(accounts[0].w.keys()[0])}
	assert((await api(GatewayAPI.world_characters(),forged)).has("error"),"valid token cannot impersonate another account name")
	forged["a-u"] = accounts[0].name
	forged["t-id"] = "not-a-session"
	assert((await api(GatewayAPI.world_characters(),forged)).has("error"),"unknown token is rejected")
	var foreign := {"t-id":accounts[0].session_id,"a-u":accounts[0].name,"w-id":int(accounts[0].w.keys()[0]),"c-id":int(ids[1][0])}
	assert((await api(GatewayAPI.world_enter(),foreign)).has("error"),"valid account session cannot enter another account's character")
	# Read-only connection to the configured dev World; never modifies game rows.
	db.path = "res://source/server/world/data/classic.db"
	assert(FileAccess.file_exists(db.path) and db.open_db() and db.query("PRAGMA query_only=ON;"))
	var store := WorldStoreSqlite.new(db)
	for index: int in 2:
		for raw_id: Variant in ids[index]:
			var character_id := int(raw_id)
			assert(store.resolve_account_id(character_id)==int(accounts[index].id),"real Master handoff persisted the global account ID")
			var handoff := await api(GatewayAPI.world_enter(),{"t-id":accounts[index].session_id,"a-u":accounts[index].name,"a-id":int(accounts[1-index].id),"w-id":int(accounts[index].w.keys()[0]),"c-id":character_id})
			assert(handoff.has("auth-token") and not handoff.has("error"))
			world_ready = false
			Client.connect_to_server(handoff.address,handoff.port,handoff["auth-token"])
			while not world_ready: await get_tree().process_frame
			assert(ClientState.player_id==character_id,"token authentication enters the correct character")
			Client.close_connection()
			Client.instance_manager.teardown()
			await get_tree().create_timer(.3).timeout
	assert(db.close_db())
	print("ACCOUNT_IDENTITY_SESSION_OK two verified accounts/four characters, spoof rejection, real token enter/reentry")
	get_tree().quit()
