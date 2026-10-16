extends Node
## Uncovered contract: real manager admission + physics/RPC isolation between
## two copies of one authored map, while durable economy stays shared.
class ForeignMap extends GameWorld3D:
	func _ready() -> void: pass
class ForeignCombat extends CombatEndpoint3D:
	func _ready() -> void: pass
class ForeignCurrency extends CurrencyEndpoint3D:
	func _ready() -> void: pass

var socket := WebSocketMultiplayerPeer.new()
var server: WorldServer
var manager: InstanceManagerServer
var client_manager: InstanceManagerClient
var db := SQLite.new()
var world: GameWorld3D
var hosts: Dictionary = {}
var ready_peers: Dictionary = {}
var answers: Dictionary = {}
var operations: Dictionary = {}
var done: Dictionary = {}
var registered := false
var elapsed := 0.0
var failed := false
var number := 0
var database_path := ""

func check(value: bool, message: String) -> void:
	if value: return
	failed=true
	push_error("LOCAL_MAP_FAILED: "+message)
	get_tree().quit(1)

func wait_until(predicate: Callable) -> void:
	while not failed and not predicate.call(): await get_tree().physics_frame

func _ready() -> void:
	BaseMultiplayerEndpoint.configure_peer(socket)
	var api := multiplayer as SceneMultiplayer
	api.server_relay=false
	if GameMode.is_world_server():
		check(socket.create_server(18098,"127.0.0.1")==OK,"loopback server")
		api.multiplayer_peer=socket
		server=WorldServer.new();server.name="Session";server.multiplayer_api=api;add_child(server)
		database_path="res://.godot/verification/local-map-"+Crypto.new().generate_random_bytes(8).hex_encode()+".db"
		db.path=database_path
		check(db.open_db(),"disposable SQLite")
		WorldSchema.ensure_schema(db)
		server.database=WorldDatabase.new();server.add_child(server.database)
		server.database.db=db;server.database.store=WorldStoreSqlite.new(db);server.database.item_store=ItemStoreSqlite.new(db)
		# This fixture supplies authenticated sessions, not Gateway credentials.
		# Production manager routing/loading/join code runs unchanged.
		api.peer_connected.connect(func(peer: int)->void:
			var owner:=EconomyFixture.create_character(server.database.store,"map%d" % peer,{"name":"Map%d" % peer,"skin":1})
			EconomyFixture.prepare(server.database)
			var player:=server.database.store.get_player(owner)
			player.current_peer_id=peer
			server.connected_players[peer]=player
			server.player_id_to_peer_id[owner]=peer)
		manager=InstanceManagerServer.new();manager.name="Instances";manager.world_server=server
		server.instance_manager=manager;server.add_child(manager)
		manager.start_instance_manager()
		run_server.call_deferred()
	else:
		number=int(CmdlineUtils.get_parsed_args().get("test-client","0"))
		var session:=Node.new();session.name="Session";add_child(session)
		client_manager=InstanceManagerClient.new();client_manager.name="Instances";session.add_child(client_manager)
		client_manager.instance_changed.connect(func(instance: InstanceClient)->void:
			world=instance.get_node("GameWorld");world.input_enabled=false
			world.market_endpoint.operation_finished.connect(func(id: String,result: Dictionary)->void:operations[id]=result))
		check(socket.create_client("ws://127.0.0.1:18098")==OK,"loopback client")
		api.multiplayer_peer=socket

func _process(delta: float) -> void:
	elapsed+=delta
	if elapsed>60: check(false,"multi-instance timeout")
	if GameMode.is_world_server() or registered or world==null: return
	if not world.inventory_endpoint.state.get("ok",false) or world.combat_endpoint.state.is_empty(): return
	registered=true
	register.rpc_id(1,number,client_manager.current_instance.identity)

@rpc("any_peer","call_remote","reliable",0)
func register(index: int, identity: Dictionary) -> void:
	if GameMode.is_world_server(): ready_peers[multiplayer.get_remote_sender_id()]={"number":index,"identity":identity}

@rpc("any_peer","call_remote","reliable",0)
func report(phase: String) -> void:
	if GameMode.is_world_server(): answers[multiplayer.get_remote_sender_id()]=phase

@rpc("any_peer","call_remote","reliable",0)
func finished() -> void:
	if GameMode.is_world_server(): done[multiplayer.get_remote_sender_id()]=true

func run_server() -> void:
	var broken:=InstanceResource.new();broken.instance_name=&"BrokenFixture";broken.use_3d=true;broken.map_path="res://tests/inventory_grid.tscn"
	var loading_before:=manager.loading_instances.size()
	check(manager.prepare_instance(broken)==null and manager.loading_instances.size()==loading_before and broken.charged_instances.is_empty(),"failed map load leaves no half-registered instance")
	await wait_until(func()->bool:return ready_peers.size()==2)
	var peers: Array = ready_peers.keys()
	peers.sort_custom(func(a: int,b: int)->bool:return ready_peers[a].number<ready_peers[b].number)
	var first: int=peers[0];var second: int=peers[1]
	var a:=manager.find_instance_for_peer(first)
	var b:=manager.find_instance_for_peer(second)
	check(a!=null and b!=null and a!=b,"initial admission distributes players between configured copies")
	check(a.instance_resource==b.instance_resource and a.identity.map_id==b.identity.map_id,"two copies of one map definition")
	check(a.identity.instance_id!=b.identity.instance_id and a.identity.channel_id!=b.identity.channel_id,"instance/channel identities distinct")
	check(a.identity.realm_id==b.identity.realm_id and a.identity.host_id==b.identity.host_id,"one local realm and host")
	check(ready_peers[first].identity==a.identity and ready_peers[second].identity==b.identity,"production client receives exact assigned identity")
	var left: GameWorld3D=a.get_node("GameWorld")
	var right: GameWorld3D=b.get_node("GameWorld")
	# A revoked session while a map is still loading must never receive/spawn an
	# assignment. Repeated connection notification must reserve only once.
	var default_map:=manager.default_instance
	var cold:=InstanceResource.new();cold.instance_name=&"ColdFixture";cold.use_3d=true;cold.map_path="res://tests/fixtures/world3d/test_arena.tscn"
	manager.default_instance=cold
	var obsolete:=PlayerResource.new();obsolete.player_id=999999;obsolete.current_peer_id=999999
	server.connected_players[999999]=obsolete;server.player_id_to_peer_id[999999]=999999
	manager._on_peer_connected(999999)
	manager._on_peer_connected(999999)
	var pending:=manager._instances_for(cold)[0]
	check(pending.awaiting_peers.size()==1,"duplicate pending admission reserves once")
	obsolete.current_peer_id=0
	manager.default_instance=default_map
	await wait_until(func()->bool:return pending.is_node_ready())
	check(pending.awaiting_peers.is_empty() and pending.get_node("GameWorld").characters.is_empty(),"revoked load-time assignment cannot spawn")
	server.connected_players.erase(999999);server.player_id_to_peer_id.erase(999999)
	pending.queue_free()
	await exercise_lifecycle()
	check(left.get_world_3d()!=right.get_world_3d(),"separate World3D/physics spaces")
	var obstacle:=StaticBody3D.new();obstacle.position=Vector3(10000,1000,10000)
	var shape:=CollisionShape3D.new();shape.shape=BoxShape3D.new();obstacle.add_child(shape);left.add_child(obstacle)
	await get_tree().physics_frame
	var ray:=PhysicsRayQueryParameters3D.create(obstacle.position+Vector3.UP*3,obstacle.position-Vector3.UP*3)
	check(not left.get_world_3d().direct_space_state.intersect_ray(ray).is_empty() and right.get_world_3d().direct_space_state.intersect_ray(ray).is_empty(),"collider in one copy does not affect the other")
	var now:=Time.get_ticks_msec()
	var counts := [left.mob_system.mobs.size(),right.mob_system.mobs.size()]
	var right_hp: int=right.metin_encounter.runtime.hp
	var threshold: float=left.metin_encounter.definition.waves[0].hp_percent
	var hit:=left.metin_encounter.definition.max_hp-int(left.metin_encounter.definition.max_hp*threshold/100.0)+1
	check(left.metin_encounter.apply_damage(first,hit,now),"local Metin damage")
	check(left.mob_system.mobs.size()>int(counts[0]) and right.mob_system.mobs.size()==int(counts[1]) and right.metin_encounter.runtime.hp==right_hp,"Metin phase/wave stays local")
	for map: GameWorld3D in [left,right]:
		for mob: MobActor3D in map.mob_system.mobs.values(): mob.ai_enabled=false
	var owner_a:=server.connected_players[first].player_id
	var owner_b:=server.connected_players[second].player_id
	var buyer_balance:=server.database.wallet_balance(owner_b)
	var drop_a:=left.ground_loot.spawn_item(left.characters[first].position+Vector3(0,0,1),owner_a,"A",now,&"iron_sword",1)
	var drop_b:=right.ground_loot.spawn_item(right.characters[second].position+Vector3(0,0,1),owner_b,"B",now,&"iron_sword",1)
	left.currency_endpoint.spawn_currency(left.characters[first].position+Vector3(5,0,0),owner_a,"A",now)
	right.currency_endpoint.spawn_currency(right.characters[second].position+Vector3(5,0,0),owner_b,"B",now)
	var hp_a: int=left.metin_encounter.runtime.hp
	var before: Vector3=left.characters[first].position
	exercise.rpc_id(first,b.identity,second,drop_a,drop_b,hp_a)
	exercise.rpc_id(second,a.identity,first,drop_b,drop_a,right_hp)
	await wait_until(func()->bool:return answers.size()==2)
	for tick: int in 6: await get_tree().physics_frame
	check(left.characters.size()==1 and right.characters.size()==1 and not left.characters.has(second) and not right.characters.has(first),"foreign/duplicate join cannot spawn an actor")
	check(left.intentions.size()==1 and right.intentions.size()==1,"foreign input cannot create movement state")
	check(left.characters[first].position.distance_to(before)>0.01,"authorized movement continues")
	check(left.ground_loot.drops.has(drop_a) and right.ground_loot.drops.has(drop_b),"foreign pickup cannot consume either drop")
	check(left.metin_encounter.runtime.hp==hp_a and right.metin_encounter.runtime.hp==right_hp,"foreign attacks cannot damage encounters")
	answers.clear()
	trade.rpc_id(first,"list",{})
	await wait_until(func()->bool:return answers.get(first)=="list")
	var mine:=server.database.market_snapshot(owner_a)
	var offer: Dictionary=mine.offers[0]
	trade.rpc_id(second,"buy",{"command_id":"cross_map_buy","shop_id":mine.shop_id,"offer_id":offer.offer_id,"revision":offer.revision,"price":offer.price})
	await wait_until(func()->bool:return answers.get(second)=="buy")
	check(server.database.item_store.inventory(owner_b).items.any(func(item: Dictionary)->bool:return item.uid==offer.item.uid),"one economy transfers UID across map copies")
	check(server.database.market_snapshot(owner_a).claimable_yang=="25" and server.database.wallet_balance(owner_b)==buyer_balance-25,"cross-copy sale settles common revenue and buyer wallet")
	check(left.characters.size()==1 and right.characters.size()==1,"economy fanout never mixes simulation rosters")
	finish.rpc_id(first,offer.item.uid,false,0)
	finish.rpc_id(second,offer.item.uid,true,buyer_balance-25)
	await wait_until(func()->bool:return done.size()==2)
	check(db.query("PRAGMA foreign_key_check;") and db.query_result.is_empty(),"shared custody remains integral")
	check(server.database.flush_wallet(),"dirty checkpoint")
	print("LOCAL_MAP_SERVER_OK production manager/identity, two First Region copies, physics/roster/mob/Metin/loot isolation, foreign RPC rejection, shared economic settlement")
	left.process_mode=Node.PROCESS_MODE_DISABLED
	right.process_mode=Node.PROCESS_MODE_DISABLED
	socket.close()
	db.close_db()
	for suffix: String in ["","-wal","-shm"]: DirAccess.remove_absolute(ProjectSettings.globalize_path(database_path+suffix))
	get_tree().quit(1 if failed else 0)

## Authenticated session and membership setup is controlled here. Actual entry,
## foreign RPCs and simulation below/above still run over the two real clients.
func exercise_lifecycle() -> void:
	var resource:=InstanceResource.new()
	resource.instance_name=&"LifecycleFixture";resource.use_3d=true
	resource.map_path="res://tests/fixtures/world3d/test_arena.tscn"
	resource.max_players=1;resource.load_at_startup=true
	manager.instance_collection[resource.instance_name]=resource
	var one:=manager.charge_instance(resource,1)
	var two:=manager.charge_instance(resource,2)
	await wait_until(func()->bool:return one.is_node_ready() and two.is_node_ready())
	for peer_id: int in [900001,900002,900003]:
		var session:=PlayerResource.new();session.player_id=peer_id;session.current_peer_id=peer_id
		server.connected_players[peer_id]=session;server.player_id_to_peer_id[peer_id]=peer_id
	var original: PlayerResource=server.connected_players[900001]
	var first:=manager.reserve_entry(900001,resource)
	var second:=manager.reserve_entry(900002,resource)
	check(first.ok and second.ok and first.instance!=second.instance,"pending entries consume distinct bounded places")
	var deadline: int=one.awaiting_peers[900001].expires_at_ms
	check(manager.reserve_entry(900001,resource).duplicate and one.awaiting_peers[900001].expires_at_ms==deadline,"duplicate entry retains original deadline")
	check(not manager.reserve_entry(900003,resource).ok and manager._instances_for(resource).size()==2,"full copies reject without creating overflow or a queue")
	check(manager.begin_draining(one),"server starts draining owned 3D copy")
	check(server.can_join_map_instance(900001,one),"pre-drain reservation may still complete")
	# An active member survives draining. The manager never relocates it.
	one.awaiting_peers.erase(900001);one.connected_peers.append(900001)
	manager.maintain_instances()
	check(not one.is_queued_for_deletion() and one.connected_peers.has(900001),"drain retains active member")
	one.connected_peers.erase(900001)
	# Test an expired loading client independently from the occupied/draining copy.
	two.awaiting_peers[900002].expires_at_ms=Time.get_ticks_msec()-1
	check(not server.can_join_map_instance(900002,two),"late join rejected before periodic sweep")
	var expired: PlayerResource=server.connected_players[900002]
	manager._on_peer_connected(900002)
	manager.maintain_instances()
	check(one.is_queued_for_deletion() and two.awaiting_peers.is_empty(),"empty draining startup copy closes and expired place is reclaimed")
	check(not manager.reserve_entry(900002,resource).ok,"expired session cannot renew while disconnect is pending")
	# A newer session may use the reclaimed place; the old ready callback cannot
	# erase the new reservation or disconnect the replacement.
	var replacement:=PlayerResource.new();replacement.player_id=900002;replacement.current_peer_id=900002
	expired.current_peer_id=0;server.connected_players[900002]=replacement
	var renewed:=manager.reserve_entry(900002,resource)
	check(renewed.ok and renewed.instance==two,"replacement session can reserve reclaimed space")
	manager._publish_entry(900002,expired,two)
	check(manager.has_valid_entry(two,900002,replacement),"stale ready callback preserves new session reservation")
	resource.max_players=2
	manager.begin_draining(two)
	check(not manager.reserve_entry(900003,resource).ok,"draining blocks fresh entry even with spare capacity")
	manager.maintain_instances()
	check(not two.is_queued_for_deletion(),"pending grandfathered entry protects drain")
	manager._release_pending_peer(900002)
	manager.maintain_instances()
	check(two.is_queued_for_deletion(),"disconnect releases last pending place for retirement")
	await get_tree().process_frame
	check(resource.charged_instances.is_empty() and manager._instances_for(resource).is_empty(),"retirement removes loaded and loading registry entries")
	var idle:=manager.charge_instance(resource,3)
	await wait_until(func()->bool:return idle.is_node_ready())
	manager.maintain_instances()
	check(not idle.is_queued_for_deletion(),"empty startup copy remains accepting")
	resource.load_at_startup=false
	resource.idle_timeout_seconds=0;resource.minimum_lifetime_seconds=60
	manager.maintain_instances()
	check(not idle.is_queued_for_deletion(),"minimum lifetime prevents immediate idle retirement")
	resource.minimum_lifetime_seconds=0;resource.idle_timeout_seconds=60
	manager.maintain_instances()
	check(not idle.is_queued_for_deletion(),"idle grace prevents flapping")
	resource.idle_timeout_seconds=0
	manager.maintain_instances()
	check(idle.is_queued_for_deletion(),"idle non-startup copy retires after both gates")
	await get_tree().process_frame
	for peer_id: int in [900001,900002,900003]:
		manager._release_pending_peer(peer_id)
		server.connected_players.erase(peer_id);server.player_id_to_peer_id.erase(peer_id)
	original.current_peer_id=0
	manager.instance_collection.erase(resource.instance_name)

@rpc("authority","call_remote","reliable",0)
func exercise(foreign: Dictionary, other_peer: int, own_drop: String, foreign_drop: String, metin_hp: int) -> void:
	await wait_until(func()->bool:return world.combat_endpoint.state.drops.has(own_drop) and world.combat_endpoint.state.metin.hp==metin_hp)
	check(world.characters.size()==1 and not world.characters.has(other_peer),"only assigned roster replicated")
	check(not world.combat_endpoint.state.drops.has(foreign_drop),"foreign loot not replicated")
	# Mirror guessed node paths with inert local stubs solely to send real RPCs.
	var shell:=Node.new();shell.name=foreign.instance_id;shell.process_mode=Node.PROCESS_MODE_DISABLED;client_manager.add_child(shell)
	var fake:=ForeignMap.new();fake.name="GameWorld";shell.add_child(fake)
	var combat:=ForeignCombat.new();combat.name="Combat";fake.add_child(combat)
	var currency:=ForeignCurrency.new();currency.name="Currency";fake.add_child(currency)
	fake.join_world.rpc_id(1)
	fake.submit_input.rpc_id(1,99,Vector2(1,0))
	combat.request_attack.rpc_id(1,99)
	combat.request_pickup.rpc_id(1,foreign_drop)
	currency.request_pickup.rpc_id(1,1)
	world.join_world.rpc_id(1) # Duplicate own entry cannot create a second actor.
	world.submit_input.rpc_id(1,1,Vector2(1,0))
	report.rpc_id(1,"forged")

@rpc("authority","call_remote","reliable",0)
func trade(action: String, payload: Dictionary) -> void:
	if action=="list":
		var sword: Dictionary=world.inventory_endpoint.state.items.filter(func(item: Dictionary)->bool:return item.definition_id=="iron_sword")[0]
		payload={"command_id":"cross_map_list","uid":sword.uid,"revision":sword.revision,"position":0,"price":25}
	world.market_endpoint.request_market.rpc_id(1,action,payload,action)
	await wait_until(func()->bool:return operations.has(action))
	check(operations[action].ok,"cross-copy "+action+" RPC")
	report.rpc_id(1,action)

@rpc("authority","call_remote","reliable",0)
func finish(uid: String, bought: bool, expected_balance: int) -> void:
	if bought:
		await wait_until(func()->bool:return world.inventory_endpoint.state.items.any(func(item: Dictionary)->bool:return item.uid==uid) and world.currency_endpoint.state.balance==expected_balance)
	else:
		await wait_until(func()->bool:return world.market_endpoint.state.get("claimable_yang","")=="25")
	check(world.characters.size()==1,"private roster remains isolated after trade")
	print("LOCAL_MAP_CLIENT_OK assigned instance, isolated simulation and shared economy")
	finished.rpc_id(1)
	await get_tree().create_timer(.3).timeout
	get_tree().quit(1 if failed else 0)
