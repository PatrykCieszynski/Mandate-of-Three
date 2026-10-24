extends Node
## Uncovered contract: real manager admission + physics/RPC isolation between
## two copies of one authored map, while durable economy stays shared.
class ForeignMap extends GameWorld3D:
	func _ready() -> void: pass
class ForeignCombat extends CombatEndpoint3D:
	func _ready() -> void: pass
class ForeignCurrency extends CurrencyEndpoint3D:
	func _ready() -> void: pass
class ForeignParty extends "res://source/common/gameplay/party/party_endpoint.gd":
	func _ready() -> void: pass
class FailedCheckpoint extends WorldDatabase:
	var calls := 0
	func flush_character(_owner_id: int = -1) -> bool:
		calls+=1
		return false

var socket := WebSocketMultiplayerPeer.new()
var server: WorldServer
var manager: InstanceManagerServer
var client_manager: InstanceManagerClient
var db := SqliteSoci.new()
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
var reserved_host: ServerInstance
var recovery_items: ItemUiAdapter
var recovery_session: UiCommandSession
var recovery_dispatcher: UiCommandDispatcher
var recovery_directory := ""
var recovery_uid := ""
var recovery_revision := 0

func check(value: bool, message: String) -> void:
	if value: return
	failed=true
	push_error("LOCAL_MAP_FAILED: "+message)
	get_tree().quit(1)

func wait_until(predicate: Callable) -> void:
	while not failed and not predicate.call(): await get_tree().physics_frame

## Extension points for focused real-network contracts sharing this host fixture.
func make_world_server() -> WorldServer: return WorldServer.new()
func entry_channel(index: int) -> int: return index

func _ready() -> void:
	BaseMultiplayerEndpoint.configure_peer(socket)
	var api := multiplayer as SceneMultiplayer
	api.server_relay=false
	if GameMode.is_world_server():
		check(socket.create_server(18098,"127.0.0.1")==OK,"loopback server")
		api.multiplayer_peer=socket
		server=make_world_server();server.name="Session";server.multiplayer_api=api;add_child(server)
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
			var player: PlayerResource=server.database.store.get_player(owner)
			player.current_peer_id=peer
			server.connected_players[peer]=player
			server.player_id_to_peer_id[owner]=peer
			if OS.get_environment("MANDATE_TEST_RESERVED_ENTRY")=="1" and reserved_host==null:
				reserved_host=manager.charge_reserved_instance(manager.default_instance,PackedInt64Array([owner]))
				check(reserved_host!=null and manager.admit_peer(peer,manager.default_instance,reserved_host).ok,"trusted routing publishes reserved initial entry"))
		manager=InstanceManagerServer.new();manager.name="Instances";manager.world_server=server
		server.instance_manager=manager;server.add_child(manager)
		manager.start_instance_manager()
		run_server.call_deferred()
	else:
		number=int(CmdlineUtils.get_parsed_args().get("test-client","0"))
		var session:=Node.new();session.name="Session";add_child(session)
		client_manager=InstanceManagerClient.new();client_manager.name="Instances";session.add_child(client_manager)
		client_manager.auto_select_channel=false
		client_manager.channels_changed.connect(func(catalogue: Dictionary)->void:
			check(catalogue.get("ok",false),"authenticated public catalogue")
			check(catalogue.channels.size()==2 and catalogue.channels.all(func(row: Dictionary)->bool:return row.keys().size()==4 and row.channel_id in [1,2]),"public catalogue excludes reserved IDs, sessions and host metadata")
			client_manager.select_initial_channel(entry_channel(number)))
		client_manager.instance_changed.connect(func(instance: WorldInstanceClient3D)->void:
			if recovery_items!=null:
				recovery_session.close("teardown")
				recovery_items.dispose()
				recovery_items=null
				recovery_dispatcher.dispose()
				recovery_dispatcher.queue_free()
			world=instance.get_node("GameWorld");world.input_enabled=false
			world.market_endpoint.operation_finished.connect(func(id: String,result: Dictionary)->void:operations[id]=result)
			world.inventory_endpoint.operation_finished.connect(func(id: String,result: Dictionary)->void:operations[id]=result))
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
	var legacy_map := InstanceResource.new()
	legacy_map.instance_name = &"LegacyMapRejected"
	legacy_map.use_3d = false
	legacy_map.map_path = "res://tests/fixtures/world3d/test_arena.tscn"
	var before_legacy := manager.loading_instances.size()
	check(manager.charge_instance(legacy_map, 1) == null and manager.prepare_instance(legacy_map) == null
		and manager.select_entry_instance(legacy_map) == null and manager.find_public_instance(legacy_map) == null
		and manager.loading_instances.size() == before_legacy,
		"production instance manager must reject 2D resources before construction")
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
	check(a.get_script() == preload("res://source/server/world/components/world_instance_3d.gd") and b.get_script() == preload("res://source/server/world/components/world_instance_3d.gd"), "production 3D hosts do not inherit legacy 2D gameplay")
	check(a.get_node_or_null("StateSynchronizerManager") == null and b.get_node_or_null("StateSynchronizerManager") == null, "3D instance hosts never start the 2D state synchronizer")
	check(a.instance_resource==b.instance_resource and a.identity.map_id==b.identity.map_id,"two copies of one map definition")
	check(a.identity.instance_id!=b.identity.instance_id and a.identity.channel_id!=b.identity.channel_id,"instance/channel identities distinct")
	check(a.identity.realm_id==b.identity.realm_id and a.identity.host_id==b.identity.host_id,"one local realm and host")
	check(ready_peers[first].identity==a.identity and ready_peers[second].identity==b.identity,"production client receives exact assigned identity")
	if reserved_host==null: check(a.identity.channel_id==1 and b.identity.channel_id==2,"explicit requested channels honored by actual admission")
	if reserved_host!=null:
		check(reserved_host in [a,b] and reserved_host.identity.channel_id==0,"allowlisted client enters reserved copy with no public CH")
		check(manager.select_entry_instance(manager.default_instance)!=reserved_host,"public selection never uses reserved copy")
	var left: GameWorld3D=a.get_node("GameWorld")
	var right: GameWorld3D=b.get_node("GameWorld")
	await observe_live_headroom()
	# A revoked session while a map is still loading must never receive/spawn an
	# assignment. Repeated connection notification must reserve only once.
	var default_map:=manager.default_instance
	var cold:=InstanceResource.new();cold.instance_name=&"ColdFixture";cold.use_3d=true;cold.map_path="res://tests/fixtures/world3d/test_arena.tscn"
	manager.charge_instance(cold) # Explicit server load; admission still awaits ready.
	manager.default_instance=cold
	var obsolete:=PlayerResource.new();obsolete.player_id=999999;obsolete.current_peer_id=999999
	server.connected_players[999999]=obsolete;server.player_id_to_peer_id[999999]=999999
	manager.admit_peer(999999,cold)
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
	await exercise_access_policy()
	await exercise_provisioning()
	exercise_channel_choices()
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
	check(server.party_service.command(owner_a,{"action":"invite","target":owner_b}).ok,"cross-CH party invitation")
	check(server.party_service.command(owner_b,{"action":"accept"}).ok,"cross-CH party acceptance")
	var party_id: int=server.party_service.membership[owner_a]
	var cohort: Dictionary={"party":party_id,"members":[owner_a,owner_b]}
	var party_rows: Array=server.party_service.snapshot(owner_a,left).members
	check(party_rows.any(func(row: Dictionary)->bool: return row.id==owner_b and row.hp>0 and not row.same_instance),"party HP remains visible across CH without sharing rewards")
	check(server.party_service.eligible(cohort,left,left.characters[first].position,100000).size()==1,"party reward never crosses CH despite ample distance radius")

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
	if reserved_host==null:
		await exercise_transfer(first,second,a,b)
	else:
		var private_peer: int = first if a==reserved_host else second
		check(not manager.transfers.start(private_peer,1).ok,"reserved copy cannot use public CH handoff")
	check(db.query("PRAGMA foreign_key_check;") and db.query_result.is_empty(),"shared custody remains integral")
	check(server.database.flush_wallet(),"dirty checkpoint")
	left.process_mode=Node.PROCESS_MODE_DISABLED
	right.process_mode=Node.PROCESS_MODE_DISABLED
	shutdown.rpc()
	await get_tree().create_timer(.2).timeout
	print("LOCAL_MAP_SERVER_OK production manager/identity, two First Region copies, physics/roster/mob/Metin/loot isolation, foreign RPC rejection, shared economic settlement")
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

func exercise_access_policy() -> void:
	var resource:=InstanceResource.new();resource.instance_name=&"AccessFixture";resource.use_3d=true
	resource.map_path="res://tests/fixtures/world3d/test_arena.tscn"
	resource.max_players=1;resource.minimum_lifetime_seconds=0;resource.idle_timeout_seconds=60
	resource.load_at_startup=true
	manager.instance_collection[resource.instance_name]=resource
	var before_count:=manager.loading_instances.size()
	check(manager.charge_reserved_instance(resource,PackedInt64Array())==null,"empty reserved membership fails closed")
	check(manager.charge_reserved_instance(resource,PackedInt64Array([-1]))==null,"invalid reserved identity fails closed")
	check(manager.prepare_instance(resource,0,99)==null,"unknown access policy rejected")
	var legacy:=InstanceResource.new();legacy.map_path=resource.map_path
	check(manager.charge_reserved_instance(legacy,PackedInt64Array([910001]))==null,"legacy 2D path cannot create reserved 3D run")
	check(manager.loading_instances.size()==before_count,"invalid policy registers no half-instance")
	var ids:=PackedInt64Array([910001])
	var private_copy:=manager.charge_reserved_instance(resource,ids)
	ids.append(910002)
	check(not private_copy.allowed_character_ids.has(910002),"membership copied from caller")
	await wait_until(func()->bool:return private_copy.is_node_ready())
	for peer_id: int in [910001,910002]:
		var session:=PlayerResource.new();session.player_id=peer_id;session.current_peer_id=peer_id
		server.connected_players[peer_id]=session;server.player_id_to_peer_id[peer_id]=peer_id
	check(not manager.reserve_entry(910002,resource,private_copy).ok and private_copy.population()==0,"explicit target still requires server membership")
	var other_manager:=InstanceManagerServer.new();other_manager.world_server=server
	check(not other_manager.reserve_entry(910001,resource,private_copy).ok,"another manager cannot reserve this manager's instance")
	other_manager.free()
	var member: PlayerResource=server.connected_players[910001]
	check(manager.reserve_entry(910001,resource,private_copy).ok and server.can_join_map_instance(910001,private_copy),"authorized reserved admission reaches final join gate")
	var original_budget=manager.provision_budget
	manager.provision_budget=healthy_budget()
	var public_entry:=manager.reserve_entry(910002,resource)
	manager.provision_budget=original_budget
	check(public_entry.ok and public_entry.instance!=private_copy and public_entry.instance.access_policy==ServerInstance.AccessPolicy.PUBLIC,"private-only map registry does not suppress creation of public capacity")
	var public_copy: ServerInstance=public_entry.instance
	check(public_copy.identity.channel_id==1 and private_copy.identity.channel_id==0,"private run does not consume public channel numbering")
	await wait_until(func()->bool:return public_copy.is_node_ready())
	var public_second:=manager.charge_instance(resource,2)
	await wait_until(func()->bool:return public_second.is_node_ready())
	resource.charged_instances.erase(private_copy);resource.charged_instances.append(private_copy)
	resource.max_players=2
	check(resource.get_instance()==private_copy,"regression fixture has RESERVED last after PUBLIC CH1/CH2")
	check(manager.find_public_instance(resource) in [public_copy,public_second],"public routing excludes last RESERVED copy")
	check(not manager.reserve_entry(910002,resource,private_copy).ok and public_copy.awaiting_peers.has(910002),"different target cannot replace a pending assignment")
	resource.idle_timeout_seconds=0
	private_copy.allowed_character_ids.clear()
	check(not server.can_join_map_instance(910001,private_copy),"revoked membership blocks join before sweep")
	manager.maintain_instances()
	check(private_copy.awaiting_peers.is_empty() and not manager.reserve_entry(910001,resource,private_copy).ok,"revoked reservation is retired and cannot renew")
	check(private_copy.is_queued_for_deletion(),"reserved run retires even when shared content has public startup copies")
	manager._release_pending_peer(910002)
	manager.maintain_instances()
	check(not public_copy.is_queued_for_deletion(),"public startup policy remains intact")
	manager.begin_draining(public_copy)
	manager.begin_draining(public_second)
	manager.maintain_instances()
	await get_tree().process_frame
	check(resource.charged_instances.is_empty(),"private/public empty copies use same retirement path")
	member.current_peer_id=0
	for peer_id: int in [910001,910002]:
		manager._release_pending_peer(peer_id)
		server.connected_players.erase(peer_id);server.player_id_to_peer_id.erase(peer_id)
	manager.instance_collection.erase(resource.instance_name)

func healthy_budget():
	var budget=preload("res://source/server/world/components/instance_provision_budget.gd").new()
	var now:=Time.get_ticks_msec()
	budget.reset(now-2100)
	for index: int in 120: budget.record(1.0,1.0,now-(119-index)*17)
	return budget

func exercise_channel_choices() -> void:
	var session:=PlayerResource.new();session.player_id=950001;session.current_peer_id=950001
	server.connected_players[950001]=session;server.player_id_to_peer_id[950001]=950001
	var resource:=manager.default_instance
	var first:=manager._instances_for(resource).filter(func(copy: ServerInstance)->bool:return copy.access_policy==ServerInstance.AccessPolicy.PUBLIC)[0] as ServerInstance
	var expires:=Time.get_ticks_msec()+30000
	manager._channel_choices[950001]={"session":session,"expires_at_ms":expires}
	check(manager.public_channels(950001).ok and manager._channel_choices[950001].expires_at_ms==expires,"refresh does not renew choice deadline")
	check(not manager.choose_initial_channel(950001,99999).ok and first.awaiting_peers.get(950001)==null,"unknown channel does not reserve/fallback")
	var capacity:=resource.max_players;resource.max_players=first.population()
	check(not manager.choose_initial_channel(950001,int(first.identity.channel_id)).ok,"full explicit channel does not fall back")
	resource.max_players=capacity
	first.admission_state=ServerInstance.AdmissionState.DRAINING
	check(not manager.choose_initial_channel(950001,int(first.identity.channel_id)).ok,"draining explicit channel rejected")
	first.admission_state=ServerInstance.AdmissionState.ACCEPTING
	var chosen:=manager.choose_initial_channel(950001,int(first.identity.channel_id))
	check(chosen.ok and chosen.instance==first and not manager._channel_choices.has(950001),"accepted choice consumes window and reserves exact target")
	check(manager.choose_initial_channel(950001,int(first.identity.channel_id)).duplicate,"same choice can recover accepted pending entry")
	check(not manager.choose_initial_channel(950001,0).ok,"different choice cannot replace pending target")
	check(manager._admit_channel_request(950001,1) and not manager._admit_channel_request(950001,1),"request IDs deduplicate before rate-limit result")
	manager._release_pending_peer(950001)
	manager._channel_choices[950001]={"session":session,"expires_at_ms":Time.get_ticks_msec()-1}
	check(not manager.choose_initial_channel(950001,1).ok,"expired initial choice cannot reserve")
	manager.maintain_instances()
	check(not manager._channel_choices.has(950001),"expired chooser releases bounded session state")
	manager._release_pending_peer(950001)
	server.connected_players.erase(950001);server.player_id_to_peer_id.erase(950001)
	for peer_id: int in ready_peers:
		var host:=manager.find_instance_for_peer(peer_id)
		var actor: PlayerActor3D=host.get_node("GameWorld").characters[peer_id]
		check(not manager.choose_initial_channel(peer_id,0).ok and host.get_node("GameWorld").characters[peer_id]==actor,"joined actor cannot use initial-choice API to transfer")

func observe_live_headroom() -> void:
	await get_tree().create_timer(3.0).timeout
	print("PROVISION_OBSERVATION ",JSON.stringify({"copies":manager._all_instances().size(),
		"physics_p95_ms":manager.provision_budget.p95(manager.provision_budget.physics_samples),
		"frame_p95_ms":manager.provision_budget.p95(manager.provision_budget.frame_samples),
		"samples":manager.provision_budget.physics_samples.size(),
		"headroom":manager.provision_budget.has_headroom(Time.get_ticks_msec())}))
	if reserved_host!=null: return
	var session:=PlayerResource.new();session.player_id=940001;session.current_peer_id=940001
	server.connected_players[940001]=session;server.player_id_to_peer_id[940001]=940001
	var resource:=manager.default_instance
	var saved_capacity:=resource.max_players;resource.max_players=1
	var saved_copy_limit:=resource.max_public_copies;resource.max_public_copies=3 # Diagnostic only.
	var start:=Time.get_ticks_usec()
	var entry:=manager.reserve_entry(940001,resource)
	var creation_ms: float=(Time.get_ticks_usec()-start)/1000.0
	if entry.ok:
		var overflow: ServerInstance=entry.instance
		check(overflow.is_overflow_copy,"live headroom trial creates bounded overflow")
		await wait_until(func()->bool:return overflow.is_node_ready())
		await get_tree().create_timer(3.0).timeout
		print("PROVISION_LIVE_GROWTH ",JSON.stringify({"copies":manager._all_instances().size(),"construction_ms":creation_ms,
			"physics_p95_ms":manager.provision_budget.p95(manager.provision_budget.physics_samples),
			"frame_p95_ms":manager.provision_budget.p95(manager.provision_budget.frame_samples),
			"samples":manager.provision_budget.physics_samples.size()}))
		manager._release_pending_peer(940001);manager.begin_draining(overflow);manager.maintain_instances()
		await get_tree().process_frame
	else:
		print("PROVISION_LIVE_GROWTH_DENIED insufficient measured headroom")
	resource.max_players=saved_capacity
	resource.max_public_copies=saved_copy_limit
	server.connected_players.erase(940001);server.player_id_to_peer_id.erase(940001)

func exercise_provisioning() -> void:
	var now:=Time.get_ticks_msec()
	var budget=healthy_budget()
	now=budget.last_sample_ms
	check(budget.has_headroom(now),"recent low CPU sample permits creation")
	check(not budget.has_headroom(now+251),"stale headroom fails closed")
	for index: int in 120:
		budget.physics_samples[index]=0.6*0.75*1000.0/Engine.physics_ticks_per_second
		budget.frame_samples[index]=budget.physics_samples[index]
	check(not budget.has_headroom(now),"combined physics and process cost must fit CPU guard")
	budget=healthy_budget()
	budget.record(NAN,1.0,now+17)
	check(not budget.has_headroom(now+17),"invalid monitor sample resets budget")
	budget=healthy_budget();budget.record(1.0,1.0,now+100)
	check(not budget.has_headroom(now+100),"observed tick stall forces resampling/settling")
	var saved_budget=manager.provision_budget
	manager.set_physics_process(false)
	var saved_host_limit:=manager.max_host_instances
	var resource:=InstanceResource.new();resource.instance_name=&"ProvisionFixture";resource.use_3d=true
	resource.map_path="res://tests/fixtures/world3d/test_arena.tscn"
	resource.max_players=1;resource.max_public_copies=3;resource.load_at_startup=true
	resource.idle_timeout_seconds=60;resource.minimum_lifetime_seconds=0
	manager.instance_collection[resource.instance_name]=resource
	for peer_id: int in [930001,930002,930003,930004,930005]:
		var session:=PlayerResource.new();session.player_id=peer_id;session.current_peer_id=peer_id
		server.connected_players[peer_id]=session;server.player_id_to_peer_id[peer_id]=peer_id
	manager.max_host_instances=manager._all_instances().size()+1
	var broken:=InstanceResource.new();broken.use_3d=true;broken.instance_name=&"BrokenProvision"
	broken.map_path="res://tests/inventory_grid.tscn"
	var slots:=manager._all_instances().size()
	check(manager.prepare_instance(broken)==null and manager._all_instances().size()==slots,"failed construction releases claimed host slot")
	var first:=manager.charge_instance(resource,1)
	check(first!=null,"released slot is immediately reusable by valid content")
	manager.max_host_instances=saved_host_limit
	var private_copy:=manager.charge_reserved_instance(resource,PackedInt64Array([930004]))
	await wait_until(func()->bool:return first.is_node_ready() and private_copy.is_node_ready())
	check(manager.reserve_entry(930001,resource).ok and manager.reserve_entry(930004,resource,private_copy).ok,"setup full public and independent private run")
	resource.idle_timeout_seconds=0
	manager.provision_budget=healthy_budget()
	for index: int in 120: manager.provision_budget.physics_samples[index]=100.0
	check(not manager.reserve_entry(930002,resource).ok,"physics CPU saturation rejects growth")
	manager.provision_budget=healthy_budget()
	for index: int in 120: manager.provision_budget.frame_samples[index]=100.0
	check(not manager.reserve_entry(930002,resource).ok,"frame CPU saturation rejects growth")
	manager.provision_budget=healthy_budget()
	manager.max_host_instances=manager._all_instances().size()
	check(not manager.reserve_entry(930002,resource).ok and manager.charge_reserved_instance(resource,PackedInt64Array([930005]))==null,"host limit includes reserved/loaded copies")
	manager.max_host_instances=saved_host_limit
	var second_entry:=manager.reserve_entry(930002,resource)
	check(second_entry.ok and second_entry.instance!=first and second_entry.instance.is_overflow_copy,"full public set grows under headroom and caps")
	var second: ServerInstance=second_entry.instance
	check(manager.reserve_entry(930002,resource).duplicate,"burst duplicate retains one pending copy/place")
	check(not manager.reserve_entry(930003,resource).ok,"creation settles before another expansion")
	resource.max_players=2
	check(manager.reserve_entry(930005,resource).ok and manager._instances_for(resource).size()==3,"burst reuses spare places despite settling; private is not overflow")
	manager._release_pending_peer(930005);resource.max_players=1
	await wait_until(func()->bool:return second.is_node_ready())
	manager.provision_budget=healthy_budget()
	first.admission_state=ServerInstance.AdmissionState.DRAINING
	check(not manager.reserve_entry(930003,resource).ok,"draining public set is not automatically replenished")
	first.admission_state=ServerInstance.AdmissionState.ACCEPTING # Controlled fixture state.
	var third_entry:=manager.reserve_entry(930003,resource)
	check(third_entry.ok and third_entry.instance.is_overflow_copy,"fresh measurements permit next bounded copy")
	var third: ServerInstance=third_entry.instance
	manager.provision_budget=healthy_budget()
	check(not manager.reserve_entry(930005,resource).ok and manager.charge_instance(resource)==null,"map cap counts loading copies and cannot be bypassed by loader")
	manager.max_host_instances=manager._all_instances().size()
	check(manager.charge_reserved_instance(resource,PackedInt64Array([930005]))==null,"host cap counts newly loading copies too")
	manager.max_host_instances=saved_host_limit
	await wait_until(func()->bool:return third.is_node_ready())
	manager._release_pending_peer(930002)
	manager.maintain_instances()
	check(second.is_queued_for_deletion() and not first.is_queued_for_deletion() and not third.is_queued_for_deletion(),"idle overflow retires, startup/pending copies remain")
	for peer_id: int in [930001,930002,930003,930004,930005]: manager._release_pending_peer(peer_id)
	manager.begin_draining(first);manager.begin_draining(private_copy);manager.maintain_instances()
	await get_tree().process_frame
	check(resource.charged_instances.is_empty(),"overflow retirement releases host/map slots")
	for peer_id: int in [930001,930002,930003,930004,930005]:
		server.connected_players.erase(peer_id);server.player_id_to_peer_id.erase(peer_id)
	manager.instance_collection.erase(resource.instance_name)
	manager.provision_budget=saved_budget;manager.set_physics_process(true)

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
	var party:=ForeignParty.new();party.name="Party";fake.add_child(party)
	party.request.rpc_id(1,"foreign-party",{"action":"leave"})
	fake.join_world.rpc_id(1)
	fake.submit_input.rpc_id(1,99,Vector2(1,0))
	combat.request_attack.rpc_id(1,99)
	combat.request_pickup.rpc_id(1,foreign_drop)
	currency.request_pickup.rpc_id(1,1)
	world.join_world.rpc_id(1) # Duplicate own entry cannot create a second actor.
	client_manager.request_initial_channel.rpc_id(1,100000,0) # Post-join RPC must not move/disconnect the actor.
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

@rpc("authority","call_remote","reliable",0)
func shutdown() -> void:
	if recovery_items!=null:
		recovery_session.close("teardown")
		recovery_items.dispose()
		recovery_dispatcher.dispose()
	get_tree().quit(1 if failed else 0)

## Controlled failure injection plus a real client map recreation/activation.
## Assert conservation/membership, not the implementation's dictionary layout.
func exercise_transfer(peer: int, other: int, source: ServerInstance, target: ServerInstance) -> void:
	var map: GameWorld3D=source.get_node("GameWorld")
	var destination: GameWorld3D=target.get_node("GameWorld")
	var party_before: int=server.party_service.membership.get(server.connected_players[peer].player_id,0)
	var session: PlayerResource=server.connected_players[peer]
	var owner:=session.player_id
	var channel:=int(target.identity.channel_id)
	var body: PlayerActor3D=map.characters[peer]
	var transfer=manager.transfers
	map.npc_endpoint.close_for_peer(peer)
	map.intentions[peer].direction=Vector2.ZERO
	body.hp=73
	map.combat_endpoint.set_combo_skill_level(peer,1)
	map.combat_endpoint.set_combo_enabled(peer,true)
	var capacity:=source.instance_resource.max_players
	source.instance_resource.max_players=1
	check(not transfer.start(peer,channel).ok,"full channel rejects without removing source")
	source.instance_resource.max_players=capacity
	target.admission_state=ServerInstance.AdmissionState.DRAINING
	check(not transfer.start(peer,channel).ok,"draining channel rejects transfer")
	target.admission_state=ServerInstance.AdmissionState.ACCEPTING
	map.combat_endpoint.last_combat_ms[peer]=Time.get_ticks_msec()
	check(transfer.start(peer,channel).get("error")=="combat","recent damage/attack cooldown gates transfer")
	map.combat_endpoint.last_combat_ms.erase(peer)
	var npc: NeutralNpc3D=map.npc_endpoint.actors.values()[0]
	var original_position:=body.position
	body.position=npc.position
	check(map.npc_endpoint.interact_for_peer(peer,npc.instance_id).ok,"authoritative NPC interaction before transfer")
	check(transfer.start(peer,channel).get("error")=="interaction","open NPC interaction gates transfer")
	map.npc_endpoint.close_for_peer(peer)
	body.position=original_position
	check(transfer.start(peer,channel).ok,"reserve destination while source remains active")
	var attempt: Dictionary=transfer.snapshot(peer)
	check(not server.can_join_map_instance(peer,target),"countdown reservation cannot activate destination")
	check(transfer.start(peer,channel).ok and transfer.snapshot(peer).attempt==attempt.attempt,"duplicate start retains original attempt")
	check(not transfer.cancel(peer,attempt.attempt,attempt.epoch+1).ok,"wrong epoch cannot cancel")
	check(transfer.cancel(peer,attempt.attempt,attempt.epoch).ok and transfer.cancel(peer,attempt.attempt,attempt.epoch).ok,"cancel replay safe")
	check(not target.awaiting_peers.has(peer) and source.connected_peers.has(peer) and map.characters[peer]==body,"cancel releases only destination")
	check(transfer.start(peer,channel).ok,"new attempt after cancel")
	check(not transfer.cancel(peer,attempt.attempt,attempt.epoch).ok,"stale cancel cannot affect new attempt")
	var balance:=server.database.wallet_balance(owner)
	var drop:=map.currency_endpoint.spawn_currency(body.position,owner,"transfer",Time.get_ticks_msec(),17)
	check(map.currency_endpoint.pickup_for_peer(peer,drop,Time.get_ticks_msec()).get("error")=="transfer_pending","autoloot/new currency income gated")
	check(map.currency_endpoint.spend_for_peer(peer,11,Time.get_ticks_msec()).get("error")=="transfer_pending" and server.database.wallet_balance(owner)==balance,"critical spend gated without debit")
	probe_transfer.rpc_id(peer)
	await wait_until(func()->bool:return answers.get(peer)=="transfer_gated")
	map.currency_endpoint.ground.erase(drop)
	map.combat_endpoint.hurt_player(peer,1,Time.get_ticks_msec())
	check(not transfer.gated(peer) and map.characters[peer]==body and transfer.snapshot(peer).error=="damage","actual damage interrupts countdown and preserves source")
	map.combat_endpoint.last_combat_ms.erase(peer)
	body.hit_reaction.clear()
	body.knockback_velocity=Vector3.ZERO
	body.hp=73
	await exercise_transfer_movement(peer,source,target)
	check(transfer.start(peer,channel).ok,"restart for movement")
	body.position.x+=1
	transfer.tick()
	check(not transfer.gated(peer) and map.characters[peer]==body,"movement aborts countdown")
	check(transfer.start(peer,channel).ok,"restart for target loss")
	target.admission_state=ServerInstance.AdmissionState.DRAINING
	transfer.tick()
	check(not transfer.gated(peer) and not target.awaiting_peers.has(peer),"target drain aborts and releases reservation")
	target.admission_state=ServerInstance.AdmissionState.ACCEPTING
	check(transfer.start(peer,channel).ok,"restart for checkpoint failure")
	var real_db:=server.database
	var failure:=FailedCheckpoint.new()
	server.database=failure
	transfer.tick(Time.get_ticks_msec()+6000)
	server.database=real_db
	check(failure.calls==1 and not transfer.gated(peer) and map.characters[peer]==body and body.hp==73,"checkpoint failure leaves live source and HP intact")
	failure.free()
	prepare_transfer_receipt.rpc_id(peer)
	await wait_until(func()->bool:return answers.get(peer)=="transfer_receipt")
	check(real_db.add_yang(owner,37),"dirty Yang before handoff")
	real_db.award_experience(session,10)
	var final_xp:=session.experience
	var final_balance:=real_db.wallet_balance(owner)
	check(transfer.start(peer,channel).ok,"final controlled handoff admitted")
	# Exercise start over the real RPC as well: it must replay the same countdown.
	start_transfer.rpc_id(peer,channel)
	await wait_until(func()->bool:return answers.get(peer)=="transfer_started")
	transfer.tick(Time.get_ticks_msec()+6000)
	check(not map.characters.has(peer) and not source.connected_peers.has(peer),"source fenced before destination activation")
	await wait_until(func()->bool:return destination.characters.has(peer))
	check(destination.characters.size()==2 and destination.characters.has(other) and target.connected_peers.count(peer)==1,"exactly one destination actor alongside other client")
	check(destination.characters[peer].hp==73 and destination.combat_endpoint.combo_state(peer).combo_enabled,"handoff preserves HP/combat options")
	check(real_db.wallet_balance(owner)==final_balance and real_db.runtime_wallets[real_db.wallet_account_id(owner)].pending_currency_delta==0,"pending Yang checkpointed without loss/duplication")
	check(real_db.store.get_player(owner).experience==final_xp,"progression checkpointed before handoff")
	check(transfer.snapshot(peer).phase=="completed" and not transfer.gated(peer),"destination completion opens mutations")
	check(not transfer.cancel(peer,transfer.snapshot(peer).attempt,transfer.snapshot(peer).epoch).ok,"late cancel never resurrects source")
	confirm_transfer.rpc_id(peer,str(target.name),final_balance)
	await wait_until(func()->bool:return answers.get(peer)=="transfer_confirmed")
	check(server.party_service.membership.get(owner,0)==party_before and party_before>0,"party survives completed production channel handoff")
	print("LOCAL_TRANSFER_OK cancel/movement/combat/drain/failure/gates/checkpoint, client recreation, single activation and retained HP/Yang")

func exercise_transfer_movement(peer: int, source: ServerInstance, target: ServerInstance) -> void:
	var map: GameWorld3D=source.get_node("GameWorld")
	var body: PlayerActor3D=map.characters[peer]
	var origin:=body.position
	var channel:=int(target.identity.channel_id)
	var transfer=manager.transfers
	var sequence:=int(map.intentions[peer].sequence)+1
	var map_processing:=map.is_physics_processing()
	var manager_processing:=manager.is_physics_processing()
	# Hold physics/countdown scheduling only: real input RPC admission stays live.
	# This reproduces a wall/deadline boundary without relying on frame timing.
	map.set_physics_process(false)
	manager.set_physics_process(false)
	transfer_movement.rpc_id(peer,sequence,Vector2.RIGHT)
	await wait_until(func()->bool:return map.intentions[peer].sequence==sequence)
	check(transfer.start(peer,channel).get("error")=="movement" and not target.awaiting_peers.has(peer),"held WASD rejects start before reserving destination")
	map.intentions[peer].time=Time.get_ticks_msec()-GameWorld3D.INPUT_TIMEOUT_MS-1
	check(transfer.start(peer,channel).ok,"expired movement intent does not permanently block transfer")
	var attempt: Dictionary=transfer.snapshot(peer)
	transfer.cancel(peer,attempt.attempt,attempt.epoch)
	sequence+=1
	transfer_movement.rpc_id(peer,sequence,Vector2.ZERO)
	await wait_until(func()->bool:return map.intentions[peer].sequence==sequence)
	check(transfer.start(peer,channel).ok,"zero movement input permits countdown")
	var deadline: int=transfer.attempts[peer].due
	sequence+=1
	transfer_movement.rpc_id(peer,sequence,Vector2.RIGHT)
	await wait_until(func()->bool:return map.intentions[peer].sequence==sequence)
	check(body.position==origin and transfer.snapshot(peer).phase=="aborted" and transfer.snapshot(peer).error=="movement","accepted input cancels before any displacement or manager tick")
	transfer.tick(deadline)
	check(source.connected_peers.has(peer) and map.characters[peer]==body and not target.awaiting_peers.has(peer),"deadline cannot complete an input-cancelled transfer")
	sequence+=1
	transfer_movement.rpc_id(peer,sequence,Vector2.ZERO)
	await wait_until(func()->bool:return map.intentions[peer].sequence==sequence)
	map.set_physics_process(map_processing)
	manager.set_physics_process(manager_processing)

@rpc("authority","call_remote","reliable",0)
func transfer_movement(sequence: int, direction: Vector2) -> void:
	world.submit_input.rpc_id(1,sequence,direction)

@rpc("authority","call_remote","reliable",0)
func probe_transfer() -> void:
	var item: Dictionary=world.inventory_endpoint.state.items[0]
	world.inventory_endpoint.request_move_item.rpc_id(1,item.uid,item.revision,0,0,0,"transfer_gate","transfer-gate-operation")
	await wait_until(func()->bool:return operations.has("transfer_gate"))
	check(operations.transfer_gate.get("error")=="transfer_pending","actual Inventory RPC blocked during countdown")
	report.rpc_id(1,"transfer_gated")

@rpc("authority","call_remote","reliable",0)
func start_transfer(channel: int) -> void:
	# The earlier forged-path test installed inert foreign RPC stubs. They are
	# fixture-only nodes, and must not collide with a subsequently legitimate map.
	for child: Node in client_manager.get_children():
		if child!=client_manager.current_instance:
			client_manager.remove_child(child)
			child.queue_free()
	client_manager._next_channel_request=100001 # Earlier forged-selector regression used request 100000.
	client_manager.channel_transfer("start",channel)
	await wait_until(func()->bool:return client_manager.transfer.get("phase")=="countdown")
	report.rpc_id(1,"transfer_started")

@rpc("authority","call_remote","reliable",0)
func confirm_transfer(instance_id: String, balance: int) -> void:
	await wait_until(func()->bool:return str(client_manager.current_instance.name)==instance_id and world.characters.size()==2 and world.currency_endpoint.state.get("balance",-1)==balance and world.combat_endpoint.state.get("health",{}).get(multiplayer.get_unique_id(),-1)==73)
	compose_recovery()
	await wait_until(func()->bool:return recovery_items.journal.load_pending().entry.is_empty())
	var recovered: Array=world.inventory_endpoint.state.items.filter(func(item: Dictionary)->bool:return item.uid==recovery_uid)
	check(recovered.size()==1 and recovered[0].revision==recovery_revision,"lost-response Inventory receipt recovers across CH without another mutation")
	world.join_world.rpc_id(1) # Duplicate ready cannot heal or create another actor.
	client_manager.channel_transfer("status")
	await wait_until(func()->bool:return client_manager.transfer.get("phase")=="completed")
	report.rpc_id(1,"transfer_confirmed")

func compose_recovery() -> void:
	recovery_dispatcher=UiCommandDispatcher.new()
	add_child(recovery_dispatcher)
	var bridge:=WebUiBridge.new()
	recovery_dispatcher.add_child(bridge)
	recovery_dispatcher.attach(bridge)
	recovery_session=UiCommandSession.new()
	recovery_items=ItemUiAdapter.new()
	recovery_items.journal.directory=recovery_directory
	recovery_items.attach(world.inventory_endpoint,recovery_dispatcher,recovery_session,get_tree())

@rpc("authority","call_remote","reliable",0)
func prepare_transfer_receipt() -> void:
	recovery_directory="res://.godot/verification/transfer-journal-%d" % multiplayer.get_unique_id()
	compose_recovery()
	var item: Dictionary=world.inventory_endpoint.state.items.filter(func(row: Dictionary)->bool:return row.location=="bag")[0]
	recovery_uid=item.uid
	world.inventory_endpoint.operation_finished.disconnect(recovery_session.finish)
	var result:=await recovery_items._move({"id":item.uid,"revision":item.revision,"x":4,"y":6,"page":3})
	world.inventory_endpoint.operation_finished.connect(recovery_session.finish)
	check(result.get("error")=="inventory_pending" and not recovery_items.journal.load_pending().entry.is_empty(),"committed Inventory move with lost response retains durable client intent before CH")
	var moved: Dictionary=world.inventory_endpoint.state.items.filter(func(row: Dictionary)->bool:return row.uid==recovery_uid)[0]
	check(moved.revision==int(item.revision)+1,"move committed before transfer; response deliberately lost")
	recovery_revision=moved.revision
	report.rpc_id(1,"transfer_receipt")
