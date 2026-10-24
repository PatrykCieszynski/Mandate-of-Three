extends "res://tests/local_map_instances.gd"
const Schema = preload("res://source/server/world/database/postgres/inventory_session_schema_postgres.gd")
const Executor = preload("res://source/server/world/database/postgres/inventory_executor_postgres.gd")
const Inventory = preload("res://source/server/world/database/postgres/inventory_runtime_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_runtime_postgres.gd")
const Trade = preload("res://source/server/world/database/postgres/player_trade_runtime_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const WalletStore = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
class SilentDispatcher extends UiCommandDispatcher:
	func register_command(_type: String, _validator: Callable, _handler: Callable) -> void: pass
	func set_domain(_domain: String, _state: Dictionary) -> void: pass
class LostCompletion extends RefCounted:
	var inner: RefCounted
	var lost:=false
	func _init(value: RefCounted) -> void: inner=value
	func submit_trade(c: Dictionary,id: String,p: Array) -> Dictionary: return inner.submit_trade(c,id,p)
	func submit_trade_receipt(c: Dictionary,id: String) -> Dictionary: return inner.submit_trade_receipt(c,id)
	func submit_trade_recover(c: Dictionary,id: String,a: Array) -> Dictionary: return inner.submit_trade_recover(c,id,a)
	func poll() -> Array:
		var events: Array=inner.poll()
		for event: Dictionary in events:
			if not lost and event.intent=="trade_execute" and event.result.get("ok",false):
				lost=true;event.result={"ok":false,"error":"outcome_unknown","outcome_unknown":true};event.committed=false
		return events
var pg: Object
var pools: Array=[]
var children: Array=[]
var owned: Dictionary={}
var replies: Dictionary={}
class TradeWorld extends WorldServer:
	func inventory_master_available() -> bool: return true # Transport grant is fixture-owned.
func entry_channel(_index: int) -> int: return 1
func make_world_server() -> WorldServer:
	var w:=TradeWorld.new()
	w.inventory_runtime=Inventory.new(w,pools[0]);w.wallet_runtime=Wallet.new(w,pools[1]);w.trade_runtime=Trade.new(w,LostCompletion.new(pools[2]))
	return w
func _ready() -> void:
	if GameMode.is_world_server():
		assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
		pg=ClassDB.instantiate("GodotSociDatabase")
		assert(pg.open("postgresql",OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")) and Schema.ensure_schema(pg))
		for index: int in 3:
			var pool:=Executor.new();assert(pool.start(OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION"),1,4));pools.append(pool)
		while not pools.all(func(p: RefCounted)->bool:return p.is_ready()):
			for pool: RefCounted in pools: pool.poll()
			await get_tree().process_frame
	super._ready()
	if GameMode.is_world_server():
		multiplayer.peer_connected.connect(func(peer: int)->void:
			var player: PlayerResource=server.connected_players[peer]
			var account: int=20000+player.player_id
			assert(WalletStore.new(pg).initialize_account(account).ok and Items.new(pg).bind_character(player.player_id,account))
			var token: String="trade-network-%d"%peer
			var grant: Dictionary=Sessions.new(pg).install_verified_grant(Sessions.identity_from_verified_ticket(account,player.player_id,token),0)
			assert(grant.ok)
			server._session_tokens[peer]=token
			var item:=ItemInstance.create(ItemDefinitions.IRON_SWORD,player.player_id,[])
			assert(pg.begin() and Items.new(pg).receive_item_in_transaction(item,0).ok and pg.commit())
			owned[player.player_id]=item.uid
			assert(server.inventory_runtime.attach(peer,grant.context) and server.wallet_runtime.attach(peer,grant.context)))
func _process(delta: float) -> void:
	elapsed+=delta
	if elapsed>45: check(false,"trade network timeout")
	if GameMode.is_world_server() or registered or world==null: return
	# Trade needs authenticated membership and the committed private bag, not a
	# mob/ground-combat fixture or its unrelated combat snapshot producer.
	if not world.inventory_endpoint.state.get("ok",false) or world.trade_endpoint.state.get("self",0)<=0: return
	registered=true
	register.rpc_id(1,number,client_manager.current_instance.identity)
func _exit_tree() -> void:
	for pid: int in children:
		if OS.is_process_running(pid): OS.kill(pid)
@rpc("authority","call_remote","reliable",0)
func trade_action(payload: Dictionary) -> void:
	await wait_until(func()->bool:return world!=null and world.trade_endpoint.state.get("self",0)>0)
	if payload.action=="close_ui":
		var dispatcher:=SilentDispatcher.new()
		var adapter:=preload("res://source/client/ui_web/player_trade_ui_adapter.gd").new()
		adapter.attach(world.trade_endpoint,dispatcher,UiCommandSession.new(),get_tree())
		var closed: Dictionary=await adapter._close({})
		check(closed.get("ok",false),"native X handler cancels over production RPC")
		adapter.dispose();dispatcher.free()
		report.rpc_id(1,"close_ui")
		return
	if not world.trade_endpoint.operation_finished.is_connected(_reply): world.trade_endpoint.operation_finished.connect(_reply)
	var id: String="network-"+Crypto.new().generate_random_bytes(8).hex_encode()
	world.trade_endpoint.request.rpc_id(1,id,payload)
	await wait_until(func()->bool:return replies.has(id))
	check(replies[id].get("ok",false),"real trade RPC: "+JSON.stringify(replies[id]))
	report.rpc_id(1,str(payload.action))
func _reply(id: String, result: Dictionary) -> void: replies[id]=result
@rpc("authority","call_remote","reliable",0)
func finish_trade_network(uid: String) -> void:
	await wait_until(func()->bool:return world.trade_endpoint.state.get("phase","")=="complete")
	await wait_until(func()->bool:return world.inventory_endpoint.state.get("items",[]).any(func(i: Dictionary)->bool:return i.uid==uid))
	print("TRADE_CLIENT_OK real negotiation RPC and committed private Inventory")
	finished.rpc_id(1)
	await get_tree().create_timer(0.3).timeout
	get_tree().quit()
func send(peer: int, payload: Dictionary) -> void:
	answers.erase(peer);trade_action.rpc_id(peer,payload)
	await wait_until(func()->bool:return answers.get(peer,"")==payload.action)
	await get_tree().create_timer(0.25).timeout # Independent new-command limiter.
func run_server() -> void:
	for index: int in [1,2]:
		children.append(OS.create_process(OS.get_executable_path(),["--headless","--path",ProjectSettings.globalize_path("res://"),"--mode=client","res://tests/player_trade_network.tscn","--test-client="+str(index),"--log-file",ProjectSettings.globalize_path("res://.godot/verification/trade-network-client%d.log"%index)],false))
	await wait_until(func()->bool:return ready_peers.size()==2)
	var peers: Array=ready_peers.keys();peers.sort()
	var a: int=peers[0];var b: int=peers[1]
	await wait_until(func()->bool:return server.inventory_runtime.mutations_allowed(a) and server.inventory_runtime.mutations_allowed(b) and server.wallet_runtime.settled(a) and server.wallet_runtime.settled(b))
	var ca: int=server.connected_players[a].player_id;var cb: int=server.connected_players[b].player_id
	await send(a,{"action":"invite","target":cb})
	await send(b,{"action":"join","trade_id":server.trade_runtime.snapshot(a).id})
	await send(a,{"action":"close_ui"})
	check(server.trade_runtime.trades.is_empty(),"X cancels rather than leaving a hidden negotiation")
	await send(a,{"action":"invite","target":cb})
	var id: String=server.trade_runtime.snapshot(a).id
	await send(b,{"action":"join","trade_id":id})
	await send(a,{"action":"offer","trade_id":id,"version":1,"items":[{"uid":owned[ca],"revision":"0"}],"yang":"10"})
	await send(a,{"action":"confirm","trade_id":id,"version":2})
	check(server.trade_runtime.snapshot(a).accepted[0],"first participant accepts")
	# A separate committed Inventory change invalidates the visible trade line.
	check(pg.execute("UPDATE economy.item_instances SET revision=revision+1 WHERE uid=:uid;",{"uid":owned[ca]}).ok,"external revision update")
	check(server.inventory_runtime.invalidate_item_state(Commands.read_state(pg,ca)),"invalidate committed projection")
	await wait_until(func()->bool:return server.trade_runtime.snapshot(a).version==3)
	check(server.trade_runtime.snapshot(a).accepted==[false,false] and server.trade_runtime.snapshot(a).offers[0].items.is_empty(),"external item change resets acceptance and removes stale offer")
	await send(a,{"action":"offer","trade_id":id,"version":3,"items":[{"uid":owned[ca],"revision":"1"}],"yang":"10"})
	await send(b,{"action":"offer","trade_id":id,"version":4,"items":[{"uid":owned[cb],"revision":"0"}],"yang":"0"})
	check(server.trade_runtime.snapshot(a).accepted==[false,false],"any edit clears both acceptances")
	await send(a,{"action":"confirm","trade_id":id,"version":5})
	await send(b,{"action":"confirm","trade_id":id,"version":5})
	await wait_until(func()->bool:return server.trade_runtime.trades.is_empty())
	check(WalletStore.new(pg).load_wallet(20000+ca).balance==1490 and WalletStore.new(pg).load_wallet(20000+cb).balance==1510,"real trade conserves account Yang")
	finish_trade_network.rpc_id(a,owned[cb]);finish_trade_network.rpc_id(b,owned[ca])
	await wait_until(func()->bool:return done.size()==2)
	for pool: RefCounted in pools: pool.begin_drain()
	while not pools.all(func(p: RefCounted)->bool:return p.is_stopped()):
		for pool: RefCounted in pools: pool.poll()
		await get_tree().process_frame
	pg.close()
	print("PLAYER_TRADE_NETWORK_OK server/two clients, changed-offer reset, dual confirmation, lost completion recovery and PG custody/wallet reconciliation")
	get_tree().quit()
