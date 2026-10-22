extends "res://tests/pve_network.gd"
## Actual two-client RPC, actor projection and existing transactional UID pickup.
var command_number: int=0
var native_peer: int=0
var _native_tag: String=""
var _native_dom: Dictionary={}
@rpc("authority","call_remote","reliable",0)
func command_party(id: String, payload: Dictionary) -> void:
	if CmdlineUtils.get_parsed_args().has("native-market-check") and payload.action in ["invite","modes"] and (world.party_endpoint.state.id==0 or world.party_endpoint.state.leader==world.party_endpoint.state.self):
		_native_tag=id
		var web=world.get_node("WebInventory")
		await wait_until(func()->bool: return web.bridge.is_ready)
		await get_tree().create_timer(0.3).timeout
		var js: String=""
		if payload.action=="invite": js="const s=document.querySelector('#party [aria-label=\"Invite player\"]');s.value='%d';Array.from(document.querySelectorAll('#party button')).find(b=>b.textContent==='Invite').click();"%int(payload.target)
		else: js="const x=document.querySelector('#party [aria-label=\"EXP mode\"]'),d=document.querySelector('#party [aria-label=\"Drop mode\"]');x.value='%s';d.value='%s';x.dispatchEvent(new Event('change'));d.dispatchEvent(new Event('change'));Array.from(document.querySelectorAll('#party button')).find(b=>b.textContent==='Apply modes').click();"%[payload.xp_mode,payload.drop_mode]
		web.host.browser.call("eval",js)
	else:
		_native_tag=""
		world.party_endpoint.request.rpc_id(1,id,payload)
@rpc("authority","call_remote","reliable",0)
func race_pickup(uid: String) -> void:
	world.combat_endpoint.request_pickup.rpc_id(1,uid)
@rpc("authority","call_remote","reliable",0)
func finish_party() -> void:
	check(world.party_endpoint.state.members.size()==2,"CEF source projection has both party members")
	if CmdlineUtils.get_parsed_args().has("native-market-check"):
		var web=world.get_node("WebInventory")
		web.host.message_received.connect(func(raw: String)->void:
			var message=JSON.parse_string(raw)
			if message is Dictionary and message.get("fixture")=="party": _native_dom=message)
		web.host.reload_ui()
		await wait_until(func()->bool: return web.bridge.is_ready)
		await get_tree().create_timer(0.4).timeout
		web.host.browser.call("eval","window.sendIpcMessage(JSON.stringify({fixture:'party',members:document.querySelectorAll('#party .party-member').length,mode:document.querySelector('#party [aria-label=\"Drop mode\"]').value,visible:!document.querySelector('#party').hidden}));")
		await wait_until(func()->bool: return not _native_dom.is_empty())
		check(int(_native_dom.members)==2 and _native_dom.mode=="free" and _native_dom.visible,"native CEF party snapshot survives reload")
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://.godot/verification/party-native.png")
		web.host.browser.call("eval","Array.from(document.querySelectorAll('#party button')).find(b=>b.textContent==='Leave party').click();")
		await wait_until(func()->bool: return int(world.party_endpoint.state.id)==0)
		print("PARTY_NATIVE_OK real CEF invite/modes/leave, roster and reload; programmatic DOM input")
	print("PARTY_CLIENT_OK commands, membership projection and free-loot race")
	finished.rpc_id(1)
	await get_tree().create_timer(0.3).timeout
	peer.close();get_tree().quit()
func ask(id: int, payload: Dictionary, accepted: bool = true) -> void:
	await get_tree().create_timer(0.22).timeout
	command_number+=1
	var tag: String="party-%d"%command_number
	command_party.rpc_id(id,tag,payload)
	await wait_until(func()->bool: return replies.get(id,{}).get("tag","")==tag)
	check(bool(replies[id].ok)==accepted,"party command admission: "+str(payload))
func kill_for(peer_id: int) -> void:
	var mob: MobActor3D=world.mob_system.mobs.values()[0]
	mob.position=Vector3.ZERO
	mob.contributions.clear();mob.reward_claims.clear()
	var hit:=CombatHitResult.new();hit.damage=mob.hp
	world.mob_system.apply_hit(mob,peer_id,hit,Vector3.FORWARD,Time.get_ticks_msec())
	world.mob_system.remove_mob(mob.mob_id)
func run_server() -> void:
	await wait_until(func()->bool: return world.characters.size()==2 and ready_peers.size()==2)
	var peers: Array=world.characters.keys()
	if native_peer>0 and peers[0]!=native_peer: peers.reverse()
	var first: int=world.services.owner_id_for_peer(peers[0])
	var second: int=world.services.owner_id_for_peer(peers[1])
	for mob: MobActor3D in world.mob_system.mobs.values(): mob.ai_enabled=false;mob.proximity_aggro=false
	world.currency_endpoint.set_physics_process(false)
	for id: int in peers: world.characters[id].position=Vector3.ZERO
	check(not world.party_endpoint.perform(99999,{"action":"leave"}).ok,"unbound peer cannot act on party")
	await ask(peers[0],{"action":"invite","target":second})
	await ask(peers[1],{"action":"accept"})
	await ask(peers[1],{"action":"kick","target":first},false)
	await ask(peers[1],{"action":"modes","xp_mode":"carry","drop_mode":"free"},false)
	var service=server.party_service
	var pid: int=service.membership[first]
	check(pid==service.membership[second],"one party for persistent identities")
	var expected_xp: Dictionary={}
	var passive: PlayerResource=server.connected_players[peers[1]]
	passive.experience=passive.level_xp_to_next()-1
	var passive_level: int=passive.level
	var definition: MobDefinition=world.mob_system.mobs.values()[0].definition
	var allocation: Dictionary=preload("res://source/common/gameplay/party/party_exp.gd").split(definition.experience_reward,[{"id":first,"level":1},{"id":second,"level":1}])
	for id: int in peers:
		var player: PlayerResource=server.connected_players[id]
		var expected: PlayerResource=player.duplicate()
		expected.add_experience(int(allocation[player.player_id]))
		expected_xp[player.player_id]=expected
	kill_for(peers[0])
	for id: int in peers:
		var player: PlayerResource=server.connected_players[id]
		var expected: PlayerResource=expected_xp[player.player_id]
		check(player.level==expected.level and player.experience==expected.experience and player.available_attributes_points==expected.available_attributes_points,"party XP uses authoritative curve and awards passive member")
	check(passive.level>passive_level,"passive party member levels up immediately")
	check(world.ground_loot.drops.size()==1,"one generated item, not one per member")
	var original_uid: String=world.ground_loot.drops.keys()[0]
	check(service.parties[pid].cursor==1,"round robin advances on actual item generation")
	var context: Array=service.contenders({"party":{"key":"party","party":pid,"members":[first,second],"damage":1,"by_id":{},"xp_mode":"equal","drop_mode":"round_robin"}},world,Vector3.ZERO,40,false)
	world.kill_rewards.party_rewards.distribute(context,Vector3.ZERO,Time.get_ticks_msec(),0,0,[])
	check(service.parties[pid].cursor==1,"no drop does not advance round robin")
	var reserved: Dictionary=world.ground_loot.drops[original_uid]
	var other: int=peers[1] if int(reserved.owner)==first else peers[0]
	check(world.ground_loot.pickup_for_peer(other,original_uid,Time.get_ticks_msec()).error=="reserved","reserved item excludes other party member")
	await ask(peers[0],{"action":"modes","xp_mode":"equal","drop_mode":"free"})
	kill_for(peers[0])
	check(world.ground_loot.drops.size()==2,"second kill generates only one additional item")
	var free_uid: String=""
	for uid: String in world.ground_loot.drops:
		if uid!=original_uid: free_uid=uid
	check(not free_uid.is_empty(),"free drop exists")
	await ask(peers[0],{"action":"kick","target":second})
	check(world.ground_loot.pickup_for_peer(peers[1],free_uid,Time.get_ticks_msec()).error=="reserved","kicked member cannot pick up an existing free drop during reservation")
	check(world.ground_loot.drops.has(free_uid),"denied pickup leaves the unique item on the ground")
	await ask(peers[0],{"action":"invite","target":second})
	await ask(peers[1],{"action":"accept"})
	var sum: int=0
	for drop: Dictionary in world.currency_endpoint.ground.values(): sum+=int(drop.amount)
	check(sum==CurrencyEndpoint3D.DOG_YANG*2,"Yang pool conserved across two party kills")
	var income: Dictionary={first:0,second:0}
	for id: int in world.currency_endpoint.ground.keys():
		var drop: Dictionary=world.currency_endpoint.ground[id]
		var peer_id: int=peers[0] if int(drop.owner)==first else peers[1]
		var result: Dictionary=world.currency_endpoint.pickup_for_peer(peer_id,id,Time.get_ticks_msec())
		check(result.ok,"party Yang uses existing wallet income path")
		income[int(drop.owner)]+=int(result.amount)
	check(income[first]==income[second],"equal Yang independent of drop mode")
	# Keep the transport alive but remove session authority: even a stale actor
	# must not make the offline seat eligible for new rewards.
	var offline_player: PlayerResource=server.connected_players[peers[1]]
	var offline_level: int=offline_player.level
	var offline_xp: int=offline_player.experience
	service.remember_disconnect(second)
	server.connected_players.erase(peers[1]);server.player_id_to_peer_id.erase(second)
	service.sweep(Time.get_ticks_msec()+365*24*60*60*1000)
	var offline_claims: Dictionary={};service.record(offline_claims,first,100)
	var offline_context: Array=service.contenders(offline_claims,world,Vector3.ZERO,40,false)
	check(service.membership[second]==pid and service.parties[pid].members.size()==2,"offline membership has no timeout")
	var offline_snapshot: Dictionary=service.snapshot(first,world)
	for row: Dictionary in offline_snapshot.members:
		if int(row.id)==second: check(not row.online,"retained member is presented as offline")
	check(offline_context.size()==1 and offline_context[0].eligible==[{"id":first,"level":server.connected_players[peers[0]].level}],"offline member does not dilute XP or Yang shares")
	var online_expected: PlayerResource=server.connected_players[peers[0]].duplicate()
	online_expected.add_experience(101)
	var prior_drops: Array=world.ground_loot.drops.keys()
	world.kill_rewards.party_rewards.distribute(offline_context,Vector3.ZERO,Time.get_ticks_msec(),101,101,[{"definition_id":ItemDefinitions.IRON_SWORD.definition_id,"amount":1,"affixes":[]}])
	var offline_drop_uid: String=""
	for uid: String in world.ground_loot.drops:
		if uid not in prior_drops: offline_drop_uid=uid
	check(not offline_drop_uid.is_empty() and world.ground_loot.drops[offline_drop_uid].allowed_owners==[first],"offline seat receives no rights to newly generated free loot")
	check(offline_player.level==offline_level and offline_player.experience==offline_xp,"offline member receives no EXP")
	check(server.connected_players[peers[0]].level==online_expected.level and server.connected_players[peers[0]].experience==online_expected.experience,"online member receives the entire XP pool")
	check(world.currency_endpoint.ground.size()==1,"offline reward produces only one Yang share")
	var offline_yang: Dictionary=world.currency_endpoint.ground.values()[0]
	check(int(offline_yang.owner)==first and int(offline_yang.amount)==101,"online member receives the entire Yang pool")
	check(world.currency_endpoint.pickup_for_peer(peers[0],world.currency_endpoint.ground.keys()[0],Time.get_ticks_msec()).ok,"offline-excluded Yang uses existing wallet")
	server.connected_players[peers[1]]=offline_player;server.player_id_to_peer_id[second]=peers[1]
	service.sweep()
	check(service.membership[second]==pid and not service.parties[pid].offline.has(second),"same character restores the retained seat")
	check(world.ground_loot.pickup_for_peer(peers[1],offline_drop_uid,Time.get_ticks_msec()).error=="reserved","reconnect does not add retroactive drop rights")
	replies.clear()
	for id: int in peers: race_pickup.rpc_id(id,free_uid)
	await wait_until(func()->bool: return replies.size()==2)
	var successes: int=0
	for result: Dictionary in replies.values():
		if result.ok: successes+=1
	check(successes==1,"one winner for concurrent free pickup")
	check(not world.ground_loot.drops.has(free_uid),"committed free UID leaves ground custody")
	check(db.query_with_bindings("SELECT COUNT(*) AS n FROM item_instances WHERE uid=?;",[free_uid]),"UID query")
	check(int(db.query_result[0].n)==1,"exactly one persistent ItemInstance UID")
	# One Metin pool shared with a significant independent competitor, without
	# creating additional guaranteed swords. This fixture actor has no transport.
	var outsider:=PlayerResource.new();outsider.player_id=999003;outsider.current_peer_id=999030;outsider.level=1
	server.connected_players[999030]=outsider;server.player_id_to_peer_id[999003]=999030
	var outsider_body:=PlayerActor3D.new();world.add_child(outsider_body);world.characters[999030]=outsider_body
	var claims: Dictionary={};service.record(claims,first,60);service.record(claims,999003,80)
	var item_count: int=world.ground_loot.drops.size()
	world.kill_rewards.party_rewards.encounter(claims,Vector3.ZERO,Time.get_ticks_msec(),301)
	check(world.ground_loot.drops.size()==item_count+1,"one Metin sword across party and solo")
	var metin_yang: int=0;var outsider_yang: int=0;var party_yang: int=0
	for drop: Dictionary in world.currency_endpoint.ground.values():
		metin_yang+=int(drop.amount)
		if int(drop.owner)==999003: outsider_yang+=int(drop.amount)
		else: party_yang+=int(drop.amount)
	check(metin_yang==301 and outsider_yang>0 and party_yang>0,"significant solo and party share existing Metin Yang pool")
	world.characters.erase(999030);server.connected_players.erase(999030);server.player_id_to_peer_id.erase(999003);outsider_body.queue_free()
	# Preserve membership when the map-local representation goes away/reappears.
	var actor = world.characters[peers[1]]
	world.characters.erase(peers[1])
	check(service.membership[second]==pid,"MapInstance detach does not erase membership")
	check(service.eligible(context[0],world,Vector3.ZERO,40).size()==1,"other map instance excluded")
	world.characters[peers[1]]=actor
	await get_tree().create_timer(0.5).timeout
	for id: int in peers: finish_party.rpc_id(id)
	await wait_until(func()->bool: return done_peers.size()==2)
	print("PARTY_SERVER_OK two-client authority, shared XP/Yang, reservations and one UID")
	db.close_db();get_tree().quit()
func _process(delta: float) -> void:
	elapsed+=delta
	if elapsed>35: check(false,"party network timeout command="+str(command_number));return
	if GameMode.is_world_server() or world==null or world.party_endpoint.state.is_empty(): return
	if not ready_peers.has(world.local_peer):
		ready_peers[world.local_peer]=true
		world.party_endpoint.operation_finished.connect(func(id: String,result: Dictionary)->void:
			var reply: Dictionary=result.duplicate();reply.tag=_native_tag if id.begins_with("web-") else id;report.rpc_id(1,reply))
		if CmdlineUtils.get_parsed_args().has("native-market-check"): register_native.rpc_id(1)
		register_ready.rpc_id(1)

@rpc("any_peer","call_remote","reliable",0)
func register_native() -> void:
	if GameMode.is_world_server(): native_peer=multiplayer.get_remote_sender_id()
