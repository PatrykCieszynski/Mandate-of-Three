extends Node
const Service = preload("res://source/common/gameplay/party/party_service.gd")
const Exp = preload("res://source/common/gameplay/party/party_exp.gd")
const Drop = preload("res://source/common/gameplay/party/party_drop.gd")
class TestWorld extends Node3D:
	var characters: Dictionary={}
	var services := MandateWorldServices.new()
func create_server() -> WorldServer:
	var server := WorldServer.new()
	WorldServer.curr=server
	for id: int in range(1,21):
		var p:=PlayerResource.new();p.player_id=id;p.current_peer_id=100+id;p.level=10;p.display_name="Player%d"%id
		server.connected_players[100+id]=p;server.player_id_to_peer_id[id]=100+id
	return server
func total(values: Dictionary) -> int:
	var sum: int=0
	for value: int in values.values(): sum+=value
	return sum
func _ready() -> void:
	var server:=create_server()
	var service=server.party_service
	assert(not service.command(1,{"action":"kick","target":2},1000).ok)
	assert(service.command(1,{"action":"invite","target":2},1000).ok)
	assert(service.command(2,{"action":"decline"},1000).ok)
	assert(not service.command(2,{"action":"accept"},1000).ok)
	for id: int in range(2,9):
		assert(service.command(1,{"action":"invite","target":id},1000).ok)
		if id==8: assert(service.command(1,{"action":"invite","target":9},1000).ok)
		assert(service.command(id,{"action":"accept"},1000).ok)
	assert(not service.command(9,{"action":"accept"},1000).ok)
	assert(not service.membership.has(9))
	assert(not service.command(1,{"action":"invite","target":9},1000).ok)
	assert(not service.command(2,{"action":"modes","xp_mode":"carry","drop_mode":"free"},1000).ok)
	assert(not service.command(2,{"action":"kick","target":3},1000).ok)
	assert(service.command(1,{"action":"leader","target":2},1000).ok)
	assert(not service.command(1,{"action":"kick","target":3},1000).ok)
	assert(service.command(2,{"action":"leave"},1000).ok)
	assert(service.parties[service.membership[1]].leader==1)
	assert(service.command(1,{"action":"kick","target":3},1000).ok)
	assert(not service.membership.has(3))
	server.connected_players[110].level=20;server.connected_players[111].level=36
	assert(not service.command(10,{"action":"invite","target":11},1000).ok)
	server.connected_players[111].level=35
	assert(service.command(10,{"action":"invite","target":11},1000).ok)
	server.connected_players[111].level=36
	assert(not service.command(11,{"action":"accept"},1000).ok)
	server.connected_players[111].level=35
	assert(service.command(11,{"action":"accept"},1000).ok)
	server.connected_players[111].level=80
	service.sweep(1000)
	assert(service.membership.has(11)) # Level-up never ejects existing members.
	assert(not service.command(10,{"action":"invite","target":12},1000).ok)
	# Same persistent character reconnects with a different peer, preserving membership.
	var pid: int=service.membership[1]
	var player: PlayerResource=server.connected_players[101]
	player.level=12
	service.remember_disconnect(1,2000)
	server.connected_players.erase(101);player.current_peer_id=0
	assert(service.profile(1).level==12)
	service.sweep(2000)
	assert(service.membership[1]==pid)
	player.current_peer_id=999;server.connected_players[999]=player;server.player_id_to_peer_id[1]=999
	service.sweep(2100)
	assert(service.peer_for(1)==999 and service.membership[1]==pid)
	server.connected_players.erase(999);player.current_peer_id=0
	service.sweep(3000);service.sweep(3000+Service.OFFLINE_GRACE_MS)
	assert(not service.membership.has(1))
	assert(service.parties[pid].leader==4)
	WorldServer.curr=null;server.free()

	var previous: int=-1
	for gap: int in [0,5,10,15]:
		var members: Array=[{"id":1,"level":10},{"id":2,"level":10+gap}]
		for mode: String in Exp.MODES:
			var shares: Dictionary=Exp.split(1001,members,mode)
			assert(total(shares)==1001)
			if mode=="equal" or gap==0: assert(absi(shares[1]-shares[2])<=1)
			if mode=="by_level" and gap>0: assert(shares[2]>shares[1])
		var carry: Dictionary=Exp.split(1001,members,"carry")
		assert(carry[1]-carry[2]>=previous);previous=carry[1]-carry[2]
		assert(total(Exp.split(31,members))==31)
	var members: Array=[{"id":1,"level":1},{"id":2,"level":1}]
	assert(Drop.choose(members,"round_robin",{},0).owner==1)
	assert(Drop.choose(members,"round_robin",{},1).owner==2)
	assert(Drop.choose(members,"by_damage",{1:5,2:6},0).owner==2)
	assert(Drop.choose(members,"by_damage",{1:5,2:5},0).owner==1)
	assert(Drop.choose(members,"by_damage",{},0).owner==1)
	assert(Drop.choose(members,"free",{},0).allowed==[1,2])
	assert(Drop.choose(members,"free",{},0).owner==0)

	server=create_server();service=server.party_service
	for pair: Array in [[1,2],[3,4]]:
		assert(service.command(pair[0],{"action":"invite","target":pair[1]},1000).ok)
		assert(service.command(pair[1],{"action":"accept"},1000).ok)
	var world:=TestWorld.new()
	for id: int in range(1,6):
		var actor:=Node3D.new();world.add_child(actor);world.characters[100+id]=actor
	var claims: Dictionary={}
	service.record(claims,1,60);service.record(claims,2,60);service.record(claims,5,100)
	var contexts: Array=service.contenders(claims,world,Vector3.ZERO,40,false)
	assert(contexts.size()==1 and contexts[0].party==service.membership[1])
	service.record(claims,3,80);service.record(claims,4,80)
	contexts=service.contenders(claims,world,Vector3.ZERO,40,false)
	assert(contexts[0].party==service.membership[3])
	# First hit freezes the distribution mode for that cohort/encounter.
	assert(service.command(3,{"action":"modes","xp_mode":"carry","drop_mode":"free"},1000).ok)
	service.record(claims,3,1)
	assert(service.contenders(claims,world,Vector3.ZERO,40,false)[0].xp_mode=="equal")
	# Joining cannot rewrite old damage or add recipients to an earlier cohort.
	assert(service.command(3,{"action":"invite","target":6},1000).ok)
	assert(service.command(6,{"action":"accept"},1000).ok)
	service.record(claims,3,10)
	assert(claims.size()==3) # Still one competitor per party, not one per roster revision.
	assert(contexts[0].members==[3,4])
	assert(service.contenders(claims,world,Vector3.ZERO,40,false)[0].damage==171)
	var prior_peer: int=server.player_id_to_peer_id[4]
	server.player_id_to_peer_id[4]=999
	assert(service.eligible(contexts[0],world,Vector3.ZERO,40).size()==1) # Stale actor is not a current session.
	server.player_id_to_peer_id[4]=prior_peer
	world.characters[104].position=Vector3(100,0,0)
	assert(service.eligible(contexts[0],world,Vector3.ZERO,40).size()==1)
	world.characters.erase(104) # Another instance/CH has no representation here.
	assert(service.eligible(contexts[0],world,Vector3.ZERO,40).size()==1)
	var shared: Array=service.contenders(claims,world,Vector3.ZERO,40,true)
	assert(shared.size()==3) # Party, other party and independent significant solo.
	assert(service.command(3,{"action":"leave"},1000).ok)
	service.record(claims,3,1)
	assert(claims.has("solo:3"))
	world.free();WorldServer.curr=null;server.free()
	print("PARTY_V1_OK core, reconnect, limits, frozen claims, strategies and conserved pools")
	get_tree().quit()
