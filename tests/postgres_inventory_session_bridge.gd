extends Node
## Real Master->World RPCs, native player authentication and PG sessions. Gateway
## credentials/entry initiation, roster handshake and post-auth UI are controlled.
const Schema = preload("res://source/server/world/database/postgres/inventory_session_schema_postgres.gd")
const Executor = preload("res://source/server/world/database/postgres/inventory_executor_postgres.gd")
const Runtime = preload("res://source/server/world/database/postgres/inventory_runtime_postgres.gd")
const Issuer = preload("res://source/server/master/components/master_world_server/inventory_session_issuer_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")

class Master extends WorldManagerServer:
	var responses: Dictionary={}
	var pause_issuer:=false
	func _process(delta: float) -> void:
		if not pause_issuer: super._process(delta)
	func _ready() -> void: pass
	func _on_peer_connected(id: int) -> void:
		connected_worlds[id]={"info":{"name":"BridgeFixture"},"address":"127.0.0.1","port":18098}
	func _on_peer_disconnected(id: int) -> void: connected_worlds.erase(id)
	func _entry_response(_gateway: int, request: int, response: Dictionary) -> void:
		assert(not responses.has(request))
		responses[request]=response

class World extends WorldServer:
	func _ready() -> void: pass
	func _publish_authenticated_state(_id: int, _player: PlayerResource) -> void: pass

class ControlLink extends WorldManagerClient:
	var hold_disconnect:=false
	var disconnect_observed:=false
	func _on_connection_succeeded() -> void: pass
	func _on_server_disconnected() -> void:
		disconnect_observed=true
		while hold_disconnect: await get_tree().process_frame
		super._on_server_disconnected()

class WireClient extends BaseMultiplayerEndpoint:
	var token: String
	var finish_auth:=true
	var connected:=false
	var ended:=false
	func _connect_multiplayer_api_signals(api: SceneMultiplayer) -> void:
		api.auth_callback=func(_peer: int, _data: PackedByteArray) -> void:
			api.send_auth(1,var_to_bytes(token))
			if finish_auth: api.complete_auth(1)
		api.connected_to_server.connect(func() -> void: connected=true)
		api.connection_failed.connect(func() -> void: ended=true)
		api.peer_authentication_failed.connect(func(_id: int) -> void: ended=true)
		api.server_disconnected.connect(func() -> void: ended=true)

var pg: Object
var database:=WorldDatabase.new()
var sqlite:=SQLite.new()
var master:=Master.new()
var world:=World.new()
var link:=ControlLink.new()
var authentication:=AuthenticationManager.new()
var control: RefCounted
var execution: RefCounted
var clients: Array[WireClient]=[]
var character: int
var extra_characters: Dictionary={}
var world_id: int
var physics_ticks: int=0

func _physics_process(_delta: float) -> void: physics_ticks+=1
func _ready() -> void: run.call_deferred()

func wait_for(predicate: Callable) -> void:
	var deadline: int=Time.get_ticks_msec()+8000
	while not predicate.call() and Time.get_ticks_msec()<deadline: await get_tree().process_frame
	assert(predicate.call(),"bounded native bridge wait")

func issue(request: int, username: String = "alpha", selected_character: int = 0) -> String:
	if selected_character==0: selected_character=character
	var attempt: String=master.begin_entry_attempt(username,world_id,42,request,&"login",selected_character)
	assert(not attempt.is_empty())
	link.result_login.rpc_id(1,OK,42,request,username,selected_character,attempt)
	return attempt

func connect_client(token: String, finish_auth: bool = true) -> WireClient:
	var client:=WireClient.new()
	client.name="WireClient"+str(clients.size())
	client.token=token
	client.finish_auth=finish_auth
	clients.append(client)
	add_child(client)
	assert(client.create(BaseMultiplayerEndpoint.Role.CLIENT,"127.0.0.1",18098)==OK)
	return client

func grant_row() -> Dictionary:
	var found: Dictionary=pg.query("SELECT * FROM economy.inventory_sessions WHERE account_id=21;")
	assert(found.ok)
	return {} if found.rows.is_empty() else found.rows[0]

func run() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var connection: String=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	var root: String=OS.get_environment("MANDATE_PG_FIXTURE_DIR")
	assert(root.begins_with("res://.godot/verification/postgres-readiness/run-"))
	sqlite.path=root+"/identity.db"
	assert(sqlite.open_db())
	WorldSchema.ensure_schema(sqlite)
	database.db=sqlite
	database.store=WorldStoreSqlite.new(sqlite)
	assert(WalletStoreSqlite.migrate_accounts(sqlite,{}).ok)
	assert(database.store.bind_account_identity("alpha",21,true))
	character=database.store.create_player_character("alpha",{"name":"Bridge","skin":1})
	assert(character>0 and database.prepare_account_wallets({"alpha":21}).ok)
	for username: String in ["beta","gamma"]:
		var account_id: int=22 if username=="beta" else 23
		assert(database.store.bind_account_identity(username,account_id,true))
		extra_characters[username]=database.store.create_player_character(username,{"name":username,"skin":1})
		assert(extra_characters[username]>0)
		assert(Wallet.new(pg).initialize_account(account_id).ok and Items.new(pg).bind_character(extra_characters[username],account_id))
	assert(database.prepare_account_wallets({"alpha":21,"beta":22,"gamma":23}).ok)
	# SQLite carries identity/soft-character metadata only in this fixture. No
	# Inventory initializer, legacy map endpoint or economy mutation is installed.
	assert(Wallet.new(pg).initialize_account(21).ok and Items.new(pg).bind_character(character,21))
	var sword:=ItemInstance.create(ItemDefinitions.IRON_SWORD,character,[])
	assert(pg.begin() and Items.new(pg).receive_item_in_transaction(sword,0).ok and pg.commit())
	authentication.account_collection=AccountResourceCollection.new()
	var account:=AccountResource.new()
	account.id=21
	account.username="alpha"
	authentication.account_collection.collection["alpha"]=account
	authentication.active_accounts["alpha"]=account
	for username: String in ["beta","gamma"]:
		var extra:=AccountResource.new()
		extra.id=22 if username=="beta" else 23
		extra.username=username
		authentication.account_collection.collection[username]=extra
		authentication.active_accounts[username]=extra
	master.authentication_manager=authentication
	master.name="Master"
	add_child(master)
	assert(master.create(BaseMultiplayerEndpoint.Role.SERVER,"127.0.0.1",18099)==OK)
	world.name="World"
	world.database=database
	world.world_manager=link
	add_child(world)
	assert(world.create(BaseMultiplayerEndpoint.Role.SERVER,"127.0.0.1",18098)==OK)
	link.name="ControlLink"
	link.database=database
	link.world_server=world
	add_child(link)
	assert(link.create(BaseMultiplayerEndpoint.Role.CLIENT,"127.0.0.1",18099)==OK)
	await wait_for(func() -> bool: return master.connected_worlds.size()==1)
	world_id=link.multiplayer_api.get_unique_id()
	control=Executor.new()
	execution=Executor.new()
	assert(control.start(connection,2,2) and execution.start(connection,2,2))
	while not control.is_ready() or not execution.is_ready():
		control.poll()
		execution.poll()
		await get_tree().process_frame
	master.inventory_session_issuer=Issuer.new(master,control)
	world.inventory_runtime=Runtime.new(world,execution)
	assert(not master.inventory_session_issuer.request_grant(world_id,"alpha","forged").queued)
	assert(not world.accept_master_handoff("no-grant","alpha",character,21),"PG World refuses a contextless legacy ticket")
	# Hold the old INSTALL itself (not just inspection) inside native SQL. It may
	# commit after supersession, but must never publish its ticket or beat B.
	assert(pg.execute("CREATE FUNCTION economy.fixture_bridge_wait() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_advisory_xact_lock(940021); RETURN NEW; END; $$;").ok)
	assert(pg.execute("CREATE TRIGGER fixture_bridge_wait BEFORE INSERT ON economy.inventory_sessions FOR EACH ROW EXECUTE FUNCTION economy.fixture_bridge_wait();").ok)
	assert(pg.execute("SELECT pg_advisory_lock(940021);").ok)
	issue(100)
	await wait_for(func() -> bool:
		pg.execute("SELECT pg_stat_clear_snapshot();")
		return int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name LIKE 'mandate-inventory-executor-%' AND wait_event_type='Lock';").rows[0].n)>0)
	var obsolete: String=master._world_sessions.alpha.token
	assert(not master.inventory_session_issuer.request_grant(world_id+1,"alpha",obsolete).queued)
	assert(master.verified_inventory_ticket(world_id,"missing",obsolete).is_empty())
	var before: int=physics_ticks
	issue(101)
	await wait_for(func() -> bool: return master.responses.has(100))
	assert(master.responses[100].has("error") and not master.responses[100].has("auth-token"))
	await get_tree().physics_frame # A supersession reply can arrive within one physics tick.
	await get_tree().process_frame # physics_frame is emitted before _physics_process.
	assert(world.token_list.is_empty() and grant_row().is_empty() and physics_ticks>before)
	assert(pg.execute("SELECT pg_advisory_unlock(940021);").ok)
	await wait_for(func() -> bool: return master.responses.has(101))
	assert(master.responses[101].has("auth-token"))
	var token: String=master.responses[101]["auth-token"]
	assert(grant_row().session_fingerprint==token.sha256_text() and int(grant_row().epoch)==2)
	assert(pg.execute("DROP TRIGGER fixture_bridge_wait ON economy.inventory_sessions;").ok)
	var old:=connect_client(obsolete)
	await wait_for(func() -> bool: return old.ended)
	assert(not old.connected)
	var first:=connect_client(token)
	await wait_for(func() -> bool: return first.connected and world.inventory_runtime.mutations_allowed(first.multiplayer_api.get_unique_id()))
	var first_peer: int=first.multiplayer_api.get_unique_id()
	assert(grant_row().phase=="ready")
	assert(world.inventory_runtime.submit(first_peer,"bridge-equip","equip",sword.uid,0,-1).queued)
	await wait_for(func() -> bool: return world.inventory_runtime.mutations_allowed(first_peer))
	assert(world.runtime_equipment[character].equipment.get("weapon","")==sword.uid)
	# A real relogin replaces the grant, then native old cleanup cannot retire it.
	issue(102)
	await wait_for(func() -> bool: return master.responses.has(102))
	var replacement: String=master.responses[102]["auth-token"]
	assert(not world.inventory_runtime.mutations_allowed(first_peer))
	var second:=connect_client(replacement)
	await wait_for(func() -> bool: return second.connected and first.ended and world.inventory_runtime.mutations_allowed(second.multiplayer_api.get_unique_id()))
	world._on_peer_disconnected(first_peer) # Delayed duplicate cleanup.
	assert(grant_row().session_fingerprint==replacement.sha256_text() and int(grant_row().epoch)==3 and grant_row().phase=="ready")
	assert(master._world_sessions.alpha.token==replacement)
	second.peer.close()
	await wait_for(func() -> bool: return not grant_row().is_empty() and grant_row().phase=="revoked")
	assert(not master._world_sessions.has("alpha"))
	# No ticket is delivered when the delegated grant COMMIT is uncertain.
	assert(pg.execute("CREATE SEQUENCE economy.fixture_bridge_attempt;").ok)
	assert(pg.execute("CREATE FUNCTION economy.fixture_bridge_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM nextval('economy.fixture_bridge_attempt'); RAISE EXCEPTION 'bridge commit fixture' USING ERRCODE='40001'; END; $$;").ok)
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_bridge AFTER UPDATE ON economy.inventory_sessions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_bridge_commit();").ok)
	issue(103)
	await wait_for(func() -> bool: return master.responses.has(103))
	assert(master.responses[103].has("error") and not master.responses[103].has("auth-token") and world.token_list.is_empty())
	assert(pg.query("SELECT last_value FROM economy.fixture_bridge_attempt;").rows[0].last_value==1)
	assert(grant_row().phase=="revoked" and int(grant_row().epoch)==3)
	assert(pg.execute("DROP TRIGGER fixture_bridge ON economy.inventory_sessions;").ok)
	issue(104) # New explicit login can recover after the failed old request.
	await wait_for(func() -> bool: return master.responses.has(104))
	var third:=connect_client(master.responses[104]["auth-token"])
	await wait_for(func() -> bool: return third.connected and world.inventory_runtime.mutations_allowed(third.multiplayer_api.get_unique_id()))
	assert(int(grant_row().epoch)==4)
	# Preserve an unused grant and another half-open native auth, alongside the
	# active alpha peer. Freeze the issuer to model a crash with NO DB revocation.
	issue(105,"beta",extra_characters.beta)
	await wait_for(func() -> bool: return master.responses.has(105))
	var unused: String=master.responses[105]["auth-token"]
	assert(world.token_list.has(unused))
	issue(106,"gamma",extra_characters.gamma)
	await wait_for(func() -> bool: return master.responses.has(106))
	var pending:=connect_client(master.responses[106]["auth-token"],false)
	await wait_for(func() -> bool: return not world._pending_admissions.is_empty())
	assert(not pending.connected and world.token_list.has(unused) and control.pending_count()==0)
	master.pause_issuer=true
	link.hold_disconnect=true
	master.peer.disconnect_peer(world_id)
	await wait_for(func() -> bool: return link.disconnect_observed)
	# Delay cleanup to prove checks are also at admission, not just the callback.
	assert(world.token_list.has(unused) and not world.is_valid_authentication_token(unused))
	assert(not world.accept_master_handoff(unused,"beta",extra_characters.beta,22,world.token_list[unused].inventory_context))
	var late_before_cleanup:=connect_client(unused)
	await wait_for(func() -> bool: return late_before_cleanup.ended)
	assert(not late_before_cleanup.connected and not world.inventory_runtime.mutations_allowed(late_before_cleanup.multiplayer_api.get_unique_id()))
	link.hold_disconnect=false
	await wait_for(func() -> bool: return third.ended and pending.ended and world.connected_players.is_empty() and world._pending_admissions.is_empty() and world.token_list.is_empty() and world.multiplayer_api.get_authenticating_peers().is_empty())
	var retained: Dictionary=pg.query("SELECT session_fingerprint,phase FROM economy.inventory_sessions WHERE account_id=22;").rows[0]
	assert(retained.session_fingerprint==unused.sha256_text() and retained.phase=="recovering" and grant_row().phase=="ready","test must not rely on successful PG revocation")
	var late_after_cleanup:=connect_client(unused)
	await wait_for(func() -> bool: return late_after_cleanup.ended)
	assert(not late_after_cleanup.connected and world.connected_players.is_empty())
	assert(sqlite.query("SELECT COUNT(*) AS n FROM item_instances;") and int(sqlite.query_result[0].n)==0,"no dual economic writes to SQLite")
	control.begin_drain()
	execution.begin_drain()
	# The crashed issuer remains frozen; only consume its already drained pool.
	while not control.is_stopped() or not execution.is_stopped():
		control.poll()
		await get_tree().process_frame
	for endpoint: BaseMultiplayerEndpoint in clients+[link,world,master]:
		endpoint.peer.close()
		endpoint.multiplayer_api.auth_callback=Callable()
		get_tree().set_multiplayer(null,endpoint.get_path())
		endpoint.queue_free()
	await get_tree().process_frame
	database.db=null
	database.free()
	authentication.free()
	assert(sqlite.close_db())
	pg.close()
	print("POSTGRES_INVENTORY_SESSION_BRIDGE_OK current Master ticket grant COMMIT before delivery, superseded attempts, native authentication/relogin/revoke, World recovery and no SQLite item writes")
	get_tree().quit()
