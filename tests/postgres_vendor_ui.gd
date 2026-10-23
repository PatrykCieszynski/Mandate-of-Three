extends Node
## Production client adapter + journals + actual World NPC workers/PG. Transport
## is controlled here; real CEF pointer/DOM acceptance is the browser milestone.
const Schema=preload("res://source/server/world/database/postgres/inventory_session_schema_postgres.gd")
const Executor=preload("res://source/server/world/database/postgres/inventory_executor_postgres.gd")
const Inventory=preload("res://source/server/world/database/postgres/inventory_runtime_postgres.gd")
const Wallet=preload("res://source/server/world/database/postgres/wallet_runtime_postgres.gd")
const Npc=preload("res://source/server/world/database/postgres/npc_runtime_postgres.gd")
const Sessions=preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Items=preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const WalletStore=preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const Adapter=preload("res://source/client/ui_web/vendor_ui_adapter.gd")
var pg: Object
var world:=FixtureWorld.new()
var pools: Array=[]
class FixtureWorld extends WorldServer:
	func inventory_master_available() -> bool: return true
class VendorProjection extends UiCommandDispatcher:
	var value: Dictionary={}
	func set_domain(_domain: String,snapshot: Dictionary) -> void: value=snapshot
class Transport extends Adapter:
	var runtime: RefCounted
	var lose_sell:=false
	var actions: Array=[]
	var outcomes: Dictionary={}
	var sequence: int=0
	func _request(action: String,payload: Dictionary,_npc: Dictionary) -> Dictionary:
		actions.append(action)
		if action=="quote": return runtime.quote(100,"map/npc","shop",payload.items)
		var id: String=payload.command_id
		outcomes.erase(id)
		var queued: Dictionary=runtime.sell(100,id,payload.quote_id,"map/npc","shop") if action=="sell" else runtime.receipt(100,"sell",id)
		if not queued.queued: return {"ok":false,"error":queued.error}
		var due:=Time.get_ticks_msec()+8000
		while not outcomes.has(id) and Time.get_ticks_msec()<due: await _tree.process_frame
		if not outcomes.has(id): return {"ok":false,"error":"timeout"}
		if lose_sell and action=="sell": lose_sell=false;return {"ok":false,"error":"timeout"}
		return outcomes[id]

func wait_for(predicate: Callable) -> void:
	var due:=Time.get_ticks_msec()+8000
	while not predicate.call() and Time.get_ticks_msec()<due: await get_tree().process_frame
	assert(predicate.call(),"bounded vendor UI fixture")

func confirm_async(client: RefCounted, answers: Array) -> void: answers.append(await client.confirm())

func deliver(client: RefCounted, snapshot: Dictionary) -> void:
	var state:=snapshot.duplicate(true)
	var marker: Dictionary=state.item_state
	state.economic_context={"authority_id":marker.authority_id,"account_id":marker.account_id,"character_id":marker.character_id}
	client.accept_inventory(state)

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var connection: String=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	assert(WalletStore.new(pg).initialize_account(9920).ok and Items.new(pg).bind_character(99200,9920))
	var uid: String=""
	for i: int in 5:
		var item:=ItemInstance.create(ItemDefinitions.BOOK_AURA,99200,[])
		assert(pg.begin() and Items.new(pg).receive_item_in_transaction(item).ok and pg.commit())
		uid=item.uid
	var context: Dictionary=Sessions.new(pg).install_verified_grant(Sessions.identity_from_verified_ticket(9920,99200,"vendor-ui"),0).context
	var player:=PlayerResource.new();player.player_id=99200;player.current_peer_id=100
	world.connected_players[100]=player;world.player_id_to_peer_id[99200]=100;world._session_tokens[100]="vendor-ui"
	for i: int in 3:
		var pool:=Executor.new();assert(pool.start(connection,2,2));pools.append(pool)
	await wait_for(func()->bool:
		for pool: RefCounted in pools: pool.poll()
		return pools.all(func(pool: RefCounted)->bool:return pool.is_ready()))
	world.inventory_runtime=Inventory.new(world,pools[0]);world.wallet_runtime=Wallet.new(world,pools[1]);world.npc_runtime=Npc.new(world.wallet_runtime,world.inventory_runtime,pools[2])
	add_child(world)
	assert(world.inventory_runtime.attach(100,context) and world.wallet_runtime.attach(100,context))
	await wait_for(func()->bool:return world.inventory_runtime.mutations_allowed(100) and world.wallet_runtime.ready(100))
	var endpoint:=Shop3D.new();endpoint.state={"active":true,"npcInstanceId":"map_npc","serviceId":"shop"}
	var view:=VendorProjection.new();view.bridge=WebUiBridge.new()
	var session:=UiCommandSession.new()
	var client:=Transport.new();client.runtime=world.npc_runtime
	client.journal.directory="res://.godot/verification/vendor-pg-ui-"+Crypto.new().generate_random_bytes(8).hex_encode()
	var directory: String=client.journal.directory
	world.npc_runtime.finished.connect(func(_peer: int,kind: String,id: String,result: Dictionary)->void:if kind=="sell": client.outcomes[id]=result)
	client.attach(endpoint,view,session,get_tree());deliver(client,world.inventory_runtime.snapshot_for_peer(100));assert(client.open().ok)
	world.inventory_runtime.snapshot_applied.connect(func(_peer: int,snapshot: Dictionary)->void:deliver(client,snapshot))
	var before: Dictionary=Items.new(pg).inventory(99200)
	for item: Dictionary in before.items: assert(client.edit({"id":item.uid,"amount":1}).ok)
	assert((await client.refresh()).ok and view.value.quote.rewards[0].quantity==1 and Items.new(pg).inventory(99200)==before)
	client.lose_sell=true
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9920 FOR NO KEY UPDATE;").ok)
	var answers: Array=[]
	confirm_async.call_deferred(client,answers)
	await wait_for(func()->bool:return client._busy)
	assert(not (await client.confirm()).ok and not client.edit({"id":uid,"amount":0}).ok,"a second confirmation or edit cannot replace a pending intention")
	assert(pg.commit())
	await wait_for(func()->bool:return answers.size()==1)
	assert(not answers[0].ok and view.value.pending)
	assert(Items.new(pg).inventory(99200).items.size()==1 and not view.value.items[0].available,"committed Inventory arrived before the lost response")
	var reward: String=Items.new(pg).inventory(99200).items[0].uid
	var operation: String=client.journal.load_pending().entry.id
	client.dispose()
	var restored:=Transport.new();restored.runtime=world.npc_runtime;restored.journal.directory=directory
	var restored_view:=VendorProjection.new();restored_view.bridge=WebUiBridge.new()
	world.npc_runtime.finished.connect(func(_peer: int,kind: String,id: String,result: Dictionary)->void:if kind=="sell": restored.outcomes[id]=result)
	restored.attach(endpoint,restored_view,session,get_tree());deliver(restored,world.inventory_runtime.snapshot_for_peer(100))
	await wait_for(func()->bool:return not restored_view.value.pending)
	assert(restored.actions==["receipt"] and Items.new(pg).inventory(99200).items[0].uid==reward and restored.journal.load_pending().entry.is_empty())
	assert(int(pg.query("SELECT COUNT(*) AS n FROM economy.market_commands WHERE command_id=:id;",{"id":operation}).rows[0].n)==1)
	assert(await world.flush_postgres_wallets(true))
	pools[0].begin_drain();await wait_for(func()->bool:return pools.all(func(pool: RefCounted)->bool:return pool.is_stopped()))
	restored.dispose();endpoint.free();view.bridge.free();view.free();restored_view.bridge.free();restored_view.free();world.free();WorldServer.curr=null;pg.close()
	print("POSTGRES_VENDOR_UI_OK real workers, client basket purity, Inventory-ahead lost response, recreated journal and exact reward receipt")
	get_tree().quit()
