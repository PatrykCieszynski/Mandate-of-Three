extends Node
## Native Master/World ACK + account-slot lifecycle, disposable SQLite profiles.
## SQL recovery remains in the real PostgreSQL process/runtime suites.
const Settings = preload("res://source/server/runtime/runtime_capacity_settings.gd")
const Inventory = preload("res://source/server/world/database/postgres/inventory_runtime_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_runtime_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Issuer = preload("res://source/server/master/components/master_world_server/inventory_session_issuer_postgres.gd")
class Master extends WorldManagerServer:
	var registration_checks:=0
	var expire_at_ack:=false
	func _ready() -> void: pass
	func _on_peer_disconnected(_peer: int) -> void: pass
	@rpc("any_peer")
	func fetch_server_info(info: Dictionary) -> void:
		super.fetch_server_info(info)
		registration_checks+=1
	@rpc("any_peer","call_remote","reliable")
	func handoff_accepted(token: String, accepted: bool) -> void:
		if expire_at_ack and _handoff_waiters.has(token):
			_handoff_waiters[token].deadline=Time.get_ticks_msec()-1
			expire_at_ack=false
		super.handoff_accepted(token,accepted)
class World extends WorldServer:
	var published: Array[int]=[]
	func inventory_master_available() -> bool: return true # Fixture-only control trust.
	func _notify_master_disconnected(_account: String, _token: String = "") -> void: pass
	func _publish_authenticated_state(peer_id: int, _player: PlayerResource) -> void:
		published.append(peer_id)
class WireClient extends BaseMultiplayerEndpoint:
	var token: String
	var connected:=false
	var ended:=false
	func _connect_multiplayer_api_signals(api: SceneMultiplayer) -> void:
		api.auth_callback=func(_id: int, _data: PackedByteArray)->void:
			api.send_auth(1,var_to_bytes(token))
			api.complete_auth(1)
		api.connected_to_server.connect(func()->void:connected=true)
		api.peer_authentication_failed.connect(func(_id: int)->void:ended=true)
		api.connection_failed.connect(func()->void:ended=true)
		api.server_disconnected.connect(func()->void:ended=true)
# Only durable grant issuance is controlled; production Master/World RPC,
# native authentication and both runtime attach methods execute unchanged.
class GrantedContext extends RefCounted:
	var master: WorldManagerServer
	func _init(owner: WorldManagerServer) -> void: master=owner
	func poll() -> void: pass
	func retire(_username: String, _token: String) -> void: pass
	func request_grant(world_id: int, username: String, token: String) -> Dictionary:
		var context:=master.verified_inventory_ticket(world_id,username,token)
		assert(not context.is_empty())
		context.epoch=1
		return {"queued":false,"done":true,"result":{"ok":true,"context":context}}
class Link extends WorldManagerClient:
	var connected:=false
	var drop_ack:=false
	func _on_connection_succeeded() -> void: connected=true
	func _on_server_disconnected() -> void: pass
	@rpc("authority")
	func fetch_token(token: String, username: String, character: int, account: int, context: Dictionary = {}) -> void:
		if not drop_ack:
			super.fetch_token(token,username,character,account,context)
		else:
			world_server.accept_master_handoff(token,username,character,account,context)
class Idle extends RefCounted:
	func poll() -> Array: return []
	func is_ready() -> bool: return true

var master:=Master.new()
var world:=World.new()
var link:=Link.new()
var database:=WorldDatabase.new()
var db:=SQLite.new()
var characters: Array[int]=[]
var world_id: int

func _ready() -> void:
	get_tree().create_timer(20).timeout.connect(func()->void:get_tree().quit(1))
	run.call_deferred()

func wait_until(predicate: Callable) -> void:
	var end:=Time.get_ticks_msec()+3000
	while not predicate.call() and Time.get_ticks_msec()<end: await get_tree().process_frame
	assert(predicate.call(),"bounded capacity fixture wait")

func prepare(token: String, result: Dictionary) -> void:
	result.value=await master._prepare_world_ticket(world_id,"alpha",token,characters[0],21)

func run() -> void:
	assert(Settings.resolve({}).ok)
	assert(Settings.load_config("res://data/config/world_config.cfg","world").ok,"checked-in World sample parses")
	assert(Settings.load_config("res://data/config/master_config.cfg","master").ok,"checked-in Master sample parses")
	assert(not GatewayError.is_connection_error({"error":ERR_BUSY}))
	assert(GatewayError.humanize({"error":ERR_BUSY})!=GatewayError.humanize({"error":GatewayAPI.ERR_BAD_CREDENTIALS}))
	for invalid: Dictionary in [{"version":2},{"inventory_bindings":0},{"wallet_accounts":true},{"unknown":1},{"handoff_ack_timeout_ms":30000},{"master_grants":1.5}]:
		assert(not Settings.resolve(invalid).ok,"invalid startup budget refused")
	assert(not Settings.resolve({},65).ok,"session cap must fit owner budgets")
	assert(not Settings.resolve({"mob_aoi_enter_radius":40,"mob_aoi_exit_radius":39}).ok)
	assert(not Settings.resolve({"mob_position_interval_ms":49}).ok)
	assert(not Settings.resolve({"mob_aoi_cell_size":0}).ok)
	var one: Dictionary=Settings.resolve({"inventory_bindings":1,"wallet_accounts":1,"master_grants":1,"handoff_ack_timeout_ms":500,"handoff_tickets":1},1)
	assert(one.ok and one.settings.value("world_sessions")==1)
	db.path="res://.godot/verification/runtime-capacity.db"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path))
	assert(db.open_db());WorldSchema.ensure_schema(db)
	database.db=db;database.store=WorldStoreSqlite.new(db)
	assert(WalletStoreSqlite.migrate_accounts(db,{}).ok)
	var accounts:=AuthenticationManager.new()
	accounts.account_collection=AccountResourceCollection.new()
	for username: String in ["alpha","beta"]:
		var id:=21 if username=="alpha" else 22
		assert(database.store.bind_account_identity(username,id,true))
		characters.append(database.store.create_player_character(username,{"name":username,"skin":1}))
		var account:=AccountResource.new();account.username=username;account.id=id
		accounts.account_collection.collection[username]=account
	assert(database.prepare_account_wallets({"alpha":21,"beta":22}).ok)
	world.database=database;world.runtime_settings=one.settings
	master.authentication_manager=accounts;master.runtime_settings=one.settings
	master.name="Master";link.name="Link"
	add_child(master);add_child(link)
	link.world_server=world;link.database=database
	assert(master.create(BaseMultiplayerEndpoint.Role.SERVER,"127.0.0.1",18099)==OK)
	assert(link.create(BaseMultiplayerEndpoint.Role.CLIENT,"127.0.0.1",18099)==OK)
	await wait_until(func()->bool:return link.connected)
	world_id=link.multiplayer_api.get_unique_id()
	link.fetch_server_info.rpc_id(1,{"info":[]})
	await wait_until(func()->bool:return master.registration_checks==1)
	assert(master.connected_worlds.is_empty(),"malformed metadata never reaches capacity lookup")
	link.fetch_server_info.rpc_id(1,{"info":{"max_players":2,"handoff_ttl_ms":30000}})
	await wait_until(func()->bool:return master.registration_checks==2)
	assert(master.connected_worlds.is_empty(),"incompatible World capacity never becomes available")
	link.fetch_server_info.rpc_id(1,{"info":{"max_players":1,"handoff_ttl_ms":500}})
	await wait_until(func()->bool:return master.registration_checks==3)
	assert(master.connected_worlds.is_empty(),"actual World TTL must outlive Master's ACK window")
	master.connected_worlds[world_id]={"info":{"name":"fixture"},"address":"127.0.0.1","port":18098}
	var first: Dictionary=await master._prepare_world_ticket(world_id,"alpha","first",characters[0],21)
	assert(first.ok and world.token_list.has("first"),"ACK reserves before returning a usable ticket")
	var expires: int=world.token_list.first.expires_at
	assert(world.accept_master_handoff("first","alpha",characters[0],21))
	assert(world.token_list.first.expires_at==expires,"duplicate reservation never extends TTL")
	var rejected: Dictionary=await master._prepare_world_ticket(world_id,"beta","full",characters[1],22)
	assert(not rejected.ok and rejected.error==ERR_BUSY and not world.token_list.has("full"))
	assert(not master._world_sessions.has("beta"),"refusal retires provisional authority")
	var replacement: Dictionary=await master._prepare_world_ticket(world_id,"alpha","replacement",characters[0],21)
	assert(replacement.ok and world.token_list.size()==1 and not world.token_list.has("first"))
	# A newer login wins while the older ACK is lost. Old cleanup cannot revoke it.
	link.drop_ack=true
	var old: Dictionary={}
	prepare("old",old)
	await wait_until(func()->bool:return world.token_list.has("old"))
	var wait_full: Dictionary=await master._prepare_world_ticket(world_id,"beta","queue-full",characters[1],22)
	assert(not wait_full.ok and wait_full.error==ERR_BUSY,"in-flight acknowledgements are bounded")
	link.drop_ack=false
	var newest: Dictionary=await master._prepare_world_ticket(world_id,"alpha","new",characters[0],21)
	await wait_until(func()->bool:return old.has("value"))
	assert(newest.ok and not old.value.ok and world.token_list.has("new") and master._world_sessions.alpha.token=="new")
	# Lost acceptance reply is never assumed to be success; late ACK is ignored.
	link.drop_ack=true
	var unknown: Dictionary=await master._prepare_world_ticket(world_id,"alpha","unknown",characters[0],21)
	assert(not unknown.ok and not master._world_sessions.has("alpha"))
	await wait_until(func()->bool:return not world.token_list.has("unknown"))
	link.handoff_accepted.rpc_id(1,"unknown",true)
	await get_tree().process_frame
	assert(master._handoff_waiters.is_empty())
	# Deterministic deadline boundary: expired at RPC receipt, before continuation.
	link.drop_ack=false;master.expire_at_ack=true
	var expired_ack: Dictionary=await master._prepare_world_ticket(world_id,"alpha","expired-ack",characters[0],21)
	assert(not expired_ack.ok,"late ACK cannot win merely by waking the coroutine")
	await wait_until(func()->bool:return not world.token_list.has("expired-ack"))
	# Issuer budget includes grant/revoke ownership, not just executing SQL.
	var issuer:=Issuer.new(master,Idle.new(),1)
	master.register_world_session(world_id,"alpha","issuer-a",characters[0],21)
	master.register_world_session(world_id,"beta","issuer-b",characters[1],22)
	assert(issuer.request_grant(world_id,"alpha","issuer-a").queued)
	assert(issuer.request_grant(world_id,"alpha","issuer-a").queued,"duplicate control request reuses owner")
	assert(not issuer.request_grant(world_id,"beta","issuer-b").queued)
	issuer.retire("alpha","issuer-a")
	assert(not issuer.request_grant(world_id,"beta","issuer-b").queued,"unconfirmed revoke retains control slot")
	# Native pending/auth slot is counted independently from free online capacity.
	world._pending_admissions[999]={"account":"alpha","account_id":21}
	assert(not world.has_entry_capacity("beta",22))
	world._pending_admissions.clear()
	# Expired tickets return their reservations; a replacement account can enter.
	world.handoff_ttl_ms=1
	assert(world.accept_master_handoff("expire","alpha",characters[0],21))
	await get_tree().create_timer(0.01).timeout
	world.prune_handoff_tickets()
	assert(world.accept_master_handoff("beta","beta",characters[1],22))
	world.revoke_account_admission("beta")
	# Real runtime ownership is exercised with ready cache fixtures, no native SQL.
	world.inventory_runtime=Inventory.new(world,Idle.new(),1)
	world.wallet_runtime=Wallet.new(world,Idle.new(),1)
	var player: PlayerResource=database.get_player_resource(characters[0]);player.current_peer_id=100
	world.connected_players[100]=player;world.player_id_to_peer_id[player.player_id]=100;world._session_tokens[100]="wallet"
	var context:=Sessions.identity_from_verified_ticket(21,player.player_id,"wallet");context.epoch=1
	assert(world.inventory_runtime.attach(100,context) and world.wallet_runtime.attach(100,context))
	var account: Dictionary=world.wallet_runtime._accounts[21]
	account.stage="ready";account.state={"balance":100,"reserved_yang":0,"authority_id":"fixture","revision":1}
	assert(world.wallet_runtime.add_income(100,37))
	world.inventory_runtime.detach(100);world.wallet_runtime.detach(100)
	world.connected_players.clear();world._session_tokens.clear()
	assert(not world.has_entry_capacity("beta",22),"dirty detached wallet reserves capacity")
	assert(world.has_entry_capacity("alpha",21),"same-account replacement reuses its retained slot")
	account.stage="paused";account.error="outcome_unknown"
	assert(not world.has_entry_capacity("beta",22) and account.pending==37)
	# Explicit fixture acknowledgement, not a simulated durable SQL receipt.
	account.pending=0;account.stage="ready"
	world.wallet_runtime.poll(0)
	assert(world.has_entry_capacity("beta",22),"clean acknowledgement releases capacity")
	# ACK -> competing refusal -> actual native auth must preserve both owner slots.
	world.handoff_ttl_ms=30000
	world.name="GameSession";add_child(world)
	# No SQL execution in this admission fixture. Native transport still polls;
	# attach must install the real owners before post-auth publication is reached.
	world.set_process(false)
	assert(world.create(BaseMultiplayerEndpoint.Role.SERVER,"127.0.0.1",18098)==OK)
	master.inventory_session_issuer=GrantedContext.new(master)
	var accepted_a: Dictionary=await master._prepare_world_ticket(world_id,"alpha","native-a",characters[0],21)
	assert(accepted_a.ok and world.token_list.has("native-a"),"A receives ACK with a reserved place")
	assert(world.inventory_runtime.binding(21).is_empty() and world.wallet_runtime.binding(21).is_empty(),"ACK precedes actual attach")
	var rejected_b: Dictionary=await master._prepare_world_ticket(world_id,"beta","native-b",characters[1],22)
	assert(not rejected_b.ok and rejected_b.error==ERR_BUSY and not world.token_list.has("native-b"),"B cannot steal A's reservation")
	assert(world.token_list.has("native-a") and world.token_list["native-a"].expires_at>Time.get_ticks_msec(),"A remains valid after B's refusal")
	var client:=WireClient.new();client.name="PlayerA";client.token="native-a";add_child(client)
	assert(client.create(BaseMultiplayerEndpoint.Role.CLIENT,"127.0.0.1",18098)==OK)
	await wait_until(func()->bool:return client.connected and not world.published.is_empty())
	var native_peer: int=client.multiplayer_api.get_unique_id()
	assert(not client.ended and world.published.has(native_peer),"A reaches post-attach publication through native auth")
	assert(world.inventory_runtime.binding(21).get("peer",0)==native_peer,"Inventory attaches A despite competing B")
	assert(world.wallet_runtime.binding(21).get("peer",0)==native_peer,"Wallet attaches the same A")
	assert(Sessions.same_context(world.inventory_runtime.context_for_peer(native_peer),accepted_a.context))
	assert(Sessions.same_context(world.wallet_runtime.context_for_peer(native_peer),accepted_a.context))
	assert(not world.token_list.has("native-a") and world._pending_admissions.is_empty(),"reservation becomes a live session")
	client.multiplayer_api.multiplayer_peer.close()
	await wait_until(func()->bool:return world.connected_players.is_empty())
	client.multiplayer_api.auth_callback=Callable()
	world.multiplayer_api.multiplayer_peer.close()
	master.inventory_session_issuer=null
	master.multiplayer_api.multiplayer_peer.close();link.multiplayer_api.multiplayer_peer.close()
	db.close_db();world.free();database.free();accounts.free()
	print("RUNTIME_CAPACITY_OK: validation, bounded ACK, reservation/replacement/expiry, competing refusal then native auth + both owner attaches, dirty ownership and clean release")
	get_tree().quit()
