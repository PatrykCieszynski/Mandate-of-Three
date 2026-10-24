extends "res://tests/local_map_instances.gd"
class StatsSession extends WorldServer:
	var replies: Dictionary={}
	@rpc("authority","call_remote","reliable",1)
	func _data_response(id: int, _type: String, result: Dictionary) -> void: replies[id]=result
var reports: Dictionary={}
var xp_reports: Dictionary={}
func _ready() -> void:
	super._ready()
	if not GameMode.is_world_server(): get_node("Session").set_script(StatsSession)
@rpc("authority","call_remote","reliable",0)
func spend_batch(funded: bool) -> void:
	var session=get_node("Session")
	var payload: Dictionary={"command_id":"same-stats-intent","attribute":"STR"}
	session._data_request.rpc_id(1,1,"attribute.spend",payload,"")
	session._data_request.rpc_id(1,2,"attribute.spend",payload,"")
	session._data_request.rpc_id(1,3,"attribute.spend",{"command_id":"same-stats-intent","attribute":"DEX"},"")
	session._data_request.rpc_id(1,4,"attribute.spend",{"command_id":"bad","attribute":"STR","points":999},"")
	await wait_until(func()->bool:return session.replies.size()==4)
	if funded:
		check(session.replies[1].ok and session.replies[2].ok and session.replies[2].replay,"real repeated RPC returns receipt")
		check(session.replies[3].error=="command_conflict","same intent cannot change attribute")
		check(session.replies[4].error=="payload","client cannot supply points")
		session._data_request.rpc_id(1,5,"attribute.spend",{"command_id":"vitality","attribute":"VIT"},"")
		await wait_until(func()->bool:return session.replies.has(5))
		check(session.replies[5].ok,"second attribute committed")
		# Retained success/conflict resolution precedes the new-command limiter.
		for id: int in range(6,18): session._data_request.rpc_id(1,id,"attribute.spend",payload,"")
		await wait_until(func()->bool:return session.replies.size()==17)
		for id: int in range(6,18): check(session.replies[id].ok and session.replies[id].replay,"retries do not consume admission budget")
	else:
		check(not session.replies[1].ok and not session.replies[2].ok,"other account cannot spend the funded account's points")
	stats_report.rpc_id(1)
@rpc("any_peer","call_remote","reliable",0)
func stats_report() -> void:
	if GameMode.is_world_server(): reports[multiplayer.get_remote_sender_id()]=true
@rpc("authority","call_remote","reliable",0)
func verify_command_xp(funded: bool) -> void:
	if funded:
		await wait_until(func()->bool:return int(world.combat_endpoint.state.get("progression",{}).get("level",0))==2 and "+105 XP" in world.combat_endpoint._experience_label.text)
		check(world.combat_endpoint.state.progression.experience==35,"command XP snapshot includes overflow")
	else:
		check(world.combat_endpoint.state.progression.level==1 and world.combat_endpoint._xp_notice.is_empty(),"other character receives no command XP or notification")
	xp_report.rpc_id(1)
@rpc("any_peer","call_remote","reliable",0)
func xp_report() -> void:
	if GameMode.is_world_server(): xp_reports[multiplayer.get_remote_sender_id()]=true
@rpc("authority","call_remote","reliable",0)
func finish_stats() -> void:
	check(world.characters[world.local_peer].max_hp==int(world.combat_endpoint.state.max_health[world.local_peer]),"client actor consumes authoritative maximum HP")
	print("STATS_CLIENT_OK actual generic World RPC, receipt replay and owner isolation")
	finished.rpc_id(1)
	await get_tree().create_timer(0.2).timeout
	socket.close();get_tree().quit()
func run_server() -> void:
	await wait_until(func()->bool:return ready_peers.size()==2)
	var peers: Array=ready_peers.keys();peers.sort()
	var hero: int=peers[0];var other: int=peers[1]
	var player: PlayerResource=server.connected_players[hero]
	var command=preload("res://source/server/world/components/chat_command/global_commands/xp_command.gd").new()
	var host: ServerInstance=manager.find_instance_for_peer(hero)
	check(command.execute(PackedStringArray(["xp","self","105"]),hero,host).begins_with("Granted"),"real /xp handler accepts online target")
	check(player.level==2 and player.experience==35 and player.available_attributes_points==4 and player.available_skill_points==1,"command crosses milestones and level with overflow")
	check(server.database.dirty_progression.get(player.player_id)==player,"command progression is checkpoint eligible")
	for invalid: String in ["0","-5","oops"]:
		check(command.execute(PackedStringArray(["xp","self",invalid]),hero,host)=="Invalid XP amount.","invalid grant cannot mutate progression")
	check(player.experience==35 and player.available_attributes_points==4,"invalid grants preserve points")
	verify_command_xp.rpc_id(hero,true);verify_command_xp.rpc_id(other,false)
	await wait_until(func()->bool:return xp_reports.size()==2)
	var initial_attack: int=server.runtime_attack(player.player_id)
	var map: GameWorld3D=manager.find_instance_for_peer(hero).get_node("GameWorld")
	var body: PlayerActor3D=map.characters[hero]
	for instance: ServerInstance in [manager.find_instance_for_peer(hero),manager.find_instance_for_peer(other)]:
		for mob: MobActor3D in instance.get_node("GameWorld").mob_system.mobs.values(): mob.ai_enabled=false;mob.proximity_aggro=false
	var initial_hp: int=body.hp;var initial_max: int=body.max_hp
	spend_batch.rpc_id(hero,true);spend_batch.rpc_id(other,false)
	await wait_until(func()->bool:return reports.size()==2)
	check(player.attributes.get(&"STR",0)==1 and player.attributes.get(&"VIT",0)==1 and player.available_attributes_points==2,"simultaneous retries spent exactly two points")
	check(server.runtime_attack(player.player_id)==initial_attack+1,"allocation changes authoritative damage")
	check(body.max_hp==initial_max+10 and body.hp<=initial_hp,"VIT changes max HP without healing")
	# Real physics regeneration consumes the projection, including buff changes and
	# expiry, without depending on the legacy instance StatusTick.
	var base_mp: float=body.max_mp
	var base_regen: float=server.runtime_combat_stats(player.player_id)[Stat.MANA_REGEN]
	BuffService.apply(player,Stat.MANA_MAX,10.0,0.5)
	BuffService.apply(player,Stat.MANA_REGEN,10.0,0.5)
	check(body.max_mp==base_mp+10,"buff application refreshes live maximum MP")
	body.mp=0
	await wait_until(func()->bool:return body.mp>0)
	check(body.mp>0,"physics regenerates MP from the derived projection")
	body.mp=body.max_mp
	await wait_until(func()->bool:return body.max_mp==base_mp)
	check(body.mp<=base_mp,"expiry refreshes and clamps MP without StatusTick")
	await wait_until(func()->bool:return server.runtime_combat_stats(player.player_id)[Stat.MANA_REGEN]==base_regen)
	BuffService.tick(player)
	check(player.active_buffs.is_empty(),"expired buff data is pruned")
	check(not server.database.dirty_progression.has(player.player_id),"allocation committed pending EXP in same transaction")
	var restored: PlayerResource=server.database.store.get_player(player.player_id)
	check(restored.attributes==player.attributes and restored.available_skill_points==1 and restored.exp_thresholds_claimed==1,"relogin/checkpoint state persisted together")
	var runtime: RefCounted=server.inventory_runtime
	server.inventory_runtime=RefCounted.new() # PG admission without a trusted Master link.
	var refused: Dictionary=server.character_stats.execute(server,hero,{"command_id":"same-stats-intent","attribute":"STR"})
	check(not refused.ok and refused.error=="session","Master loss rejects even cached allocation receipts")
	server.inventory_runtime=runtime
	map.combat_endpoint._send_snapshot()
	for peer: int in peers: finish_stats.rpc_id(peer)
	await wait_until(func()->bool:return done.size()==2)
	print("STATS_SERVER_OK real RPC authorization, burst replay, conflict, RAM stats and persisted progression")
	db.close_db();get_tree().quit()
