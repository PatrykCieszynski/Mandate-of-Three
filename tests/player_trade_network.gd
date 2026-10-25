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
	var trade_state: Dictionary={}
	func register_command(_type: String, _validator: Callable, _handler: Callable) -> void: pass
	func set_domain(domain: String, value: Dictionary) -> void:
		if domain=="trade": trade_state=value.duplicate(true)
class LostCompletion extends RefCounted:
	var inner: RefCounted
	var lost:=false
	var not_committed_reads:=0
	func _init(value: RefCounted) -> void: inner=value
	func submit_trade(c: Dictionary,id: String,p: Array) -> Dictionary: return inner.submit_trade(c,id,p)
	func submit_trade_receipt(c: Dictionary,id: String) -> Dictionary: return inner.submit_trade_receipt(c,id)
	func submit_trade_recover(c: Dictionary,id: String,a: Array) -> Dictionary: return inner.submit_trade_recover(c,id,a)
	func poll() -> Array:
		var events: Array=inner.poll()
		for event: Dictionary in events:
			if event.intent=="trade_receipt" and event.result.get("error","")=="not_committed": not_committed_reads+=1
			if not lost and event.intent=="trade_execute" and event.result.get("ok",false):
				lost=true;event.result={"ok":false,"error":"outcome_unknown","outcome_unknown":true};event.committed=false
		return events
var pg: Object
var pools: Array=[]
var children: Array=[]
var owned: Dictionary={}
var replies: Dictionary={}
var restart_player: PlayerResource
var restarting_peer:=0
var journal_directory: String
var reconnecting:=false
class TradeWorld extends WorldServer:
	func inventory_master_available() -> bool: return true # Transport grant is fixture-owned.
func entry_channel(_index: int) -> int: return 1
func make_fixture_player(peer: int) -> PlayerResource:
	if restart_player==null: return super.make_fixture_player(peer)
	var player:=restart_player
	restart_player=null;reconnecting=true
	return player
func make_world_server() -> WorldServer:
	var w:=TradeWorld.new()
	w.inventory_runtime=Inventory.new(w,pools[0]);w.wallet_runtime=Wallet.new(w,pools[1]);w.trade_runtime=Trade.new(w,LostCompletion.new(pools[2]))
	return w
func _ready() -> void:
	if GameMode.is_world_server():
		assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
		pg=ClassDB.instantiate("GodotSociDatabase")
		journal_directory=ProjectSettings.globalize_path("res://.godot/verification/trade-restart-"+Crypto.new().generate_random_bytes(8).hex_encode())
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
			var epoch:=1 if reconnecting else 0
			reconnecting=false
			var account: int=20000+player.player_id
			assert(WalletStore.new(pg).initialize_account(account).ok and Items.new(pg).bind_character(player.player_id,account))
			var token: String="trade-network-%d"%peer
			var grant: Dictionary=Sessions.new(pg).install_verified_grant(Sessions.identity_from_verified_ticket(account,player.player_id,token),epoch)
			assert(grant.ok)
			server._session_tokens[peer]=token
			if not owned.has(player.player_id):
				var item:=ItemInstance.create(ItemDefinitions.IRON_SWORD,player.player_id,[])
				assert(pg.begin() and Items.new(pg).receive_item_in_transaction(item,0).ok and pg.commit())
				owned[player.player_id]=item.uid
			assert(server.inventory_runtime.attach(peer,grant.context) and server.wallet_runtime.attach(peer,grant.context)))
		multiplayer.peer_disconnected.connect(func(peer: int)->void:
			if peer!=restarting_peer: return
			# This fixture supplies login identities; retire the old transport binding.
			server.inventory_runtime.detach(peer);server.wallet_runtime.detach(peer)
			var host: ServerInstance=manager.find_instance_for_peer(peer)
			if host!=null: host.get_node("GameWorld").remove_peer(peer,true);host.connected_peers.erase(peer)
			var player: PlayerResource=server.connected_players[peer]
			server.player_id_to_peer_id.erase(player.player_id);server.connected_players.erase(peer);server._session_tokens.erase(peer))
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
	if payload.action in ["persist_accept","restore_pending"]:
		var dispatcher:=SilentDispatcher.new()
		var adapter:=preload("res://source/client/ui_web/player_trade_ui_adapter.gd").new()
		adapter.journal=preload("res://source/client/ui_web/local_economy_journal.gd").new("trade-",str(CmdlineUtils.get_parsed_args().get("trade-journal-dir","")))
		adapter.attach(world.trade_endpoint,dispatcher,UiCommandSession.new(),get_tree())
		if payload.action=="persist_accept":
			adapter.accept_inventory(world.inventory_endpoint.state)
			check((await adapter._submit({"action":"confirm","trade_id":payload.trade_id,"version":payload.version})).get("ok",false),"first acceptance through native adapter")
			check(adapter.journal.load_pending().entry.get("id","")==payload.trade_id,"first acceptance persisted on disk")
		else:
			# Check the disk record before configuring triggers automatic recovery.
			var scope: Dictionary=world.inventory_endpoint.state.item_state
			check(adapter.journal.configure(scope).entry.get("id","")==payload.trade_id,"new client process loads original pending ID")
			adapter.accept_inventory(world.inventory_endpoint.state)
			await wait_until(func()->bool:return dispatcher.trade_state.get("id","")==payload.trade_id and not dispatcher.trade_state.get("pending",true))
			check(dispatcher.trade_state.phase=="cancelled" and adapter.journal.load_pending().entry.is_empty(),"not_committed clears disk and UI pending after reconnect")
			print("TRADE_RESTART_NOT_COMMITTED_OK")
		adapter.dispose();dispatcher.free() # No cancellation snapshot reaches the old adapter.
		report.rpc_id(1,str(payload.action));return
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
func stop_client() -> void: get_tree().quit()
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
		children.append(OS.create_process(OS.get_executable_path(),["--headless","--path",ProjectSettings.globalize_path("res://"),"--mode=client","res://tests/player_trade_network.tscn","--test-client="+str(index),"--trade-journal-dir="+journal_directory,"--log-file",ProjectSettings.globalize_path("res://.godot/verification/trade-network-client%d.log"%index)],false))
	await wait_until(func()->bool:return ready_peers.size()==2)
	var peers: Array=ready_peers.keys();peers.sort()
	var a: int=peers[0];var b: int=peers[1]
	await wait_until(func()->bool:return server.inventory_runtime.mutations_allowed(a) and server.inventory_runtime.mutations_allowed(b) and server.wallet_runtime.settled(a) and server.wallet_runtime.settled(b))
	var ca: int=server.connected_players[a].player_id;var cb: int=server.connected_players[b].player_id
	await send(a,{"action":"invite","target":cb})
	await send(b,{"action":"join","trade_id":server.trade_runtime.snapshot(a).id})
	await send(a,{"action":"close_ui"})
	check(server.trade_runtime.trades.is_empty(),"X cancels rather than leaving a hidden negotiation")
	# First Accept journals an intention although no SQL trade has been submitted.
	await send(a,{"action":"invite","target":cb})
	var interrupted: String=server.trade_runtime.snapshot(a).id
	await send(b,{"action":"join","trade_id":interrupted})
	await send(a,{"action":"offer","trade_id":interrupted,"version":1,"items":[{"uid":owned[ca],"revision":"0"}],"yang":"10"})
	await send(a,{"action":"persist_accept","trade_id":interrupted,"version":2})
	check(server.trade_runtime.trades[interrupted].phase=="offer","one acceptance cannot submit settlement")
	await send(b,{"action":"cancel","trade_id":interrupted})
	restart_player=server.connected_players[a];restarting_peer=a
	stop_client.rpc_id(a)
	await wait_until(func()->bool:return not server.connected_players.has(a))
	ready_peers.erase(a)
	children.append(OS.create_process(OS.get_executable_path(),["--headless","--path",ProjectSettings.globalize_path("res://"),"--mode=client","res://tests/player_trade_network.tscn","--test-client=3","--trade-journal-dir="+journal_directory,"--log-file",ProjectSettings.globalize_path("res://.godot/verification/trade-network-client3.log")],false))
	await wait_until(func()->bool:return ready_peers.size()==2)
	for peer: int in ready_peers:
		if peer!=b: a=peer
	check(server.connected_players[a].player_id==ca and a!=restarting_peer,"same character reconnects from a fresh client process/peer")
	await send(a,{"action":"restore_pending","trade_id":interrupted})
	check(server.trade_runtime.executor.not_committed_reads==1,"reconnect resolves via PostgreSQL not_committed lookup")
	check(pg.query("SELECT command_id FROM economy.market_commands WHERE command_id=:id;",{"id":interrupted}).rows.is_empty(),"unsubmitted negotiation has no durable receipt")
	check(WalletStore.new(pg).load_wallet(20000+ca).balance==1500 and WalletStore.new(pg).load_wallet(20000+cb).balance==1500,"aborted negotiation preserves both balances")
	check(Items.new(pg).inventory(ca).items[0].uid==owned[ca] and Items.new(pg).inventory(cb).items[0].uid==owned[cb],"aborted negotiation preserves both original UIDs")
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
	print("PLAYER_TRADE_NETWORK_OK client-process restart/not_committed journal cleanup, changed-offer reset, dual confirmation, lost completion recovery and PG custody/wallet reconciliation")
	get_tree().quit()
