extends RefCounted
## Isolate World-thread idle/cache cost. Mock executor never returns or executes SQL.
const Inventory = preload("res://source/server/world/database/postgres/inventory_runtime_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_runtime_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
class ProbeWorld extends WorldServer:
	func inventory_master_available() -> bool: return true
class IdleExecutor extends RefCounted:
	func poll() -> Array: return []

static func run() -> Array:
	var results: Array=[]
	for requested: int in [0,24,64,65]:
		for item_count: int in [0,12,InventoryGrid.CAPACITY]:
			var world:=ProbeWorld.new()
			var inventory:=Inventory.new(world,IdleExecutor.new())
			var wallet:=Wallet.new(world,IdleExecutor.new())
			var admitted:=0
			var before:=OS.get_static_memory_usage()
			for i: int in requested:
				var id:=i+1
				var player:=PlayerResource.new();player.player_id=id;player.current_peer_id=id+1
				world.connected_players[id+1]=player;world.player_id_to_peer_id[id]=id+1;world._session_tokens[id+1]="probe%d" % id
				var context:=Sessions.identity_from_verified_ticket(id,id,world._session_tokens[id+1]);context.epoch=1
				var attached: bool=inventory.attach(id+1,context)
				assert(wallet.attach(id+1,context)==attached)
				if not attached: continue
				admitted+=1
				# Explicitly seed ready projections: this probe excludes native loading/recovery.
				var items: Array=[]
				for slot: int in item_count:
					var item:=ItemInstance.create(ItemDefinitions.UPGRADE_ORE,id,[])
					item.bag_position=slot
					var snapshot:=item.to_snapshot()
					snapshot.merge({"item_name":ItemDefinitions.UPGRADE_ORE.item_name,"icon_id":str(ItemDefinitions.UPGRADE_ORE.icon_id),"stats":item.effective_stats(ItemDefinitions.UPGRADE_ORE),"inventory_height":1})
					items.append(snapshot)
				inventory._bindings[id].stage="ready"
				inventory._bindings[id].snapshot={"ok":true,"items":items,"equipment":{},"stats":{"attack":10},"item_state":{"authority_id":"probe","account_id":id,"character_id":id,"revision":1}}
				wallet._accounts[id].stage="ready"
				wallet._accounts[id].state={"balance":0,"reserved_yang":0,"authority_id":"probe","revision":1}
			var retained:=OS.get_static_memory_usage()-before
			var started:=Time.get_ticks_usec()
			for iteration: int in 200:
				inventory.poll();wallet.poll(0)
			var poll_us: float=(Time.get_ticks_usec()-started)/200.0
			started=Time.get_ticks_usec()
			for iteration: int in 10:
				for id: int in admitted: inventory.snapshot_for_peer(id+2)
			var copy_us: float=(Time.get_ticks_usec()-started)/float(maxi(admitted*10,1))
			var payload:=inventory.snapshot_for_peer(2)
			for id: int in admitted:
				inventory.detach(id+2);wallet.detach(id+2)
			wallet.poll(0)
			assert(inventory._bindings.is_empty() and wallet._accounts.is_empty())
			results.append({"requested":requested,"admitted":admitted,"items_per_inventory":item_count,"retained_static_bytes":retained,"idle_inventory_wallet_poll_mean_us":poll_us,"snapshot_copy_mean_us":copy_us,"one_snapshot_serialized_bytes":var_to_bytes(payload).size(),"clean_detach":true})
			world.free()
	return results
