extends Node
const Chat = preload("res://source/common/gameplay/chat/world_chat.gd")
const History = preload("res://source/client/ui_web/chat_history.gd")
class Host extends Node:
	var connected_peers: Array=[]
class ChatMap extends Node3D:
	var characters: Dictionary={}
class Server extends Node:
	var connected_players: Dictionary={}
	var player_id_to_peer_id: Dictionary={}
	var instance_manager = null
	var runtime_settings = null
	var party_service = preload("res://source/common/gameplay/party/party_service.gd").new(self)
	var hosts: Dictionary={}
	func request_instance(peer: int): return hosts.get(peer)
var delivered: Array=[]
func _ready() -> void:
	var server:=Server.new()
	var hosts: Array=[]
	for i: int in 2:
		var host:=Host.new();var map:=ChatMap.new();map.name="GameWorld";host.add_child(map);hosts.append(host)
	for id: int in [1,2,3]:
		var peer: int=id+100
		var player:=PlayerResource.new();player.player_id=id;player.current_peer_id=peer;player.display_name="Player%d"%id
		server.connected_players[peer]=player;server.player_id_to_peer_id[id]=peer
		var host: Host=hosts[0 if id<3 else 1];server.hosts[peer]=host;host.connected_peers.append(peer)
		var body:=Node3D.new();host.get_child(0).add_child(body);host.get_child(0).characters[peer]=body
	var chat=Chat.new(server)
	chat.message_ready.connect(func(peer: int,message: Dictionary)->void: delivered.append({"peer":peer,"message":message.duplicate(true)}))
	assert(chat.attempt(101,0))
	assert(chat.handle(101,{"action":"send","channel":"general","text":" hello "},0).ok)
	assert(delivered.size()==3 and delivered[0].message.sender==1 and delivered[0].message.text=="hello")
	assert(not chat.handle(101,{"action":"send","channel":"general","text":"again"},1).ok)
	assert(chat.handle(101,{"action":"send","channel":"trade","text":"sell"},1).ok)
	assert(not chat.handle(101,{"action":"send","channel":"trade","text":"sell"},19999).ok)
	assert(chat.handle(101,{"action":"send","channel":"trade","text":"sell"},20001).ok)
	delivered.clear()
	assert(chat.handle(101,{"action":"send","channel":"local","text":"near"},30000).ok)
	assert(delivered.size()==2)
	hosts[0].get_child(0).characters[102].position.x=41
	delivered.clear();assert(chat.handle(101,{"action":"send","channel":"local","text":"far"},31000).ok)
	assert(delivered.size()==1)
	assert(not chat.handle(101,{"action":"send","channel":"party","text":"no party"},32000).ok)
	assert(not chat.handle(101,{"action":"send","channel":"guild","text":"no guild"},32000).ok)
	assert(server.party_service.command(1,{"action":"invite","target":3}).ok)
	assert(server.party_service.command(3,{"action":"accept"}).ok)
	delivered.clear();assert(chat.handle(101,{"action":"send","channel":"party","text":"other CH"},32000).ok)
	assert(delivered.size()==2 and delivered[1].peer==103)
	assert(chat.handle(101,{"action":"lookup","name":"player3"},32000).target==3)
	delivered.clear();assert(chat.handle(101,{"action":"send","channel":"whisper","target":3,"text":"private"},33000).ok)
	assert(delivered.size()==2 and delivered[1].message.target==3)
	BlockList.set_for(3,PackedInt64Array([1]));delivered.clear()
	assert(chat.handle(101,{"action":"send","channel":"whisper","target":3,"text":"blocked"},39000).ok)
	assert(delivered.size()==1);BlockList.clear_player(3)
	server.connected_players[103].current_peer_id=0
	assert(not chat.handle(101,{"action":"send","channel":"whisper","target":3,"text":"offline"},40000).ok)
	delivered.clear();assert(chat.handle(101,{"action":"send","channel":"party","text":"offline excluded"},40000).ok)
	assert(delivered.size()==1 and server.party_service.membership.has(3))
	server.connected_players[103].current_peer_id=203;server.connected_players[203]=server.connected_players[103];server.player_id_to_peer_id[3]=203;server.hosts[203]=hosts[1];hosts[1].connected_peers.append(203);hosts[1].get_child(0).characters[203]=hosts[1].get_child(0).characters[103]
	delivered.clear();assert(chat.handle(101,{"action":"send","channel":"party","text":"new session"},46000).ok)
	assert(delivered.size()==2 and delivered[1].peer==203)
	assert(not chat.handle(103,{"action":"send","channel":"general","text":"stale"},46000).ok)
	for text: String in ["","  ","x".repeat(257),"x\ny","x\ty",String.chr(0x202e)]:
		assert(not chat.handle(101,{"action":"send","channel":"local","text":text},50000).ok)
	assert(Chat.normalize("😀".repeat(256)).length()==256)
	for payload: Dictionary in [{"action":"send","channel":"system","text":"GM"},{"action":"send","channel":"general","text":"x","sender":2},{"action":"send","channel":"whisper","text":"x","target":2.5},{"action":"lookup","name":"x".repeat(5000)}]: assert(not Chat.valid(payload))
	for i: int in 12: assert(chat.attempt(101,60000))
	assert(not chat.attempt(101,60000));assert(chat.attempt(101,61000))
	for i: int in 5: assert(chat.handle(101,{"action":"send","channel":"local","text":"x"},70000+i).ok)
	assert(not chat.handle(101,{"action":"send","channel":"party","text":"x"},70005).ok)
	delivered.clear();chat.system("trusted notice",[101,101,203]);assert(delivered.size()==2 and delivered[0].message.sender==0)
	delivered.clear()
	var retry: Dictionary={"action":"send","channel":"general","text":"once"}
	assert(chat.execute(101,"same",retry,80000).ok)
	assert(chat.execute(101,"same",retry,80001).ok and delivered.size()==3)
	assert(chat.execute(101,"same",{"action":"send","channel":"general","text":"conflict"},80002).error=="command_conflict")
	for i: int in 50: assert(chat.execute(101,"same",retry,90000).ok)
	for i: int in 12: assert(chat.execute(101,"bad%d"%i,{"junk":true},90000).error=="payload")
	assert(chat.execute(101,"blocked",retry,90000).error=="rate_limited")
	assert(chat.execute(101,"same",retry,90000).ok and delivered.size()==3)
	assert(chat.execute(101,"same",{"junk":true},90000).error=="command_conflict")
	server.connected_players[101].current_peer_id=0
	assert(chat.execute(101,"same",retry,90000).error=="session")
	server.connected_players[101].current_peer_id=101
	var history=History.new();history.identify(1)
	var msg: Dictionary={"id":1,"channel":"whisper","sender":3,"name":"Player3","target":1,"text":"private"}
	history.accept(msg);history.accept(msg);assert(history.conversations[3].messages.size()==1)
	history.conversations[3].mode="minimized";msg.id=2;history.accept(msg)
	assert(history.conversations[3].mode=="minimized" and history.conversations[3].unread==2)
	# One selected conversation; incoming PMs cannot change the selected tab.
	history.open(4,"Fourth");assert(history.conversations[3].mode=="minimized")
	msg.id=3;history.accept(msg)
	assert(history.conversations[4].mode=="open" and history.conversations[3].unread==3)
	history.set_mode(3,"open")
	assert(history.conversations[3].unread==0 and history.conversations[4].mode=="minimized")
	history.set_mode(3,"closed");msg.id=4;history.accept(msg)
	assert(history.conversations[3].mode=="minimized" and history.conversations[3].unread==1)
	history.identify(1);assert(history.conversations.size()==2)
	history.identify(2);assert(history.conversations.is_empty())
	for i: int in 400:
		history.accept({"id":i+10,"channel":"general","sender":3,"name":"Unicode","target":0,"text":"😀".repeat(256)})
	assert(history.messages.size()<=200 and JSON.stringify(history.snapshot()).to_utf8_buffer().size()<=131072)
	for i: int in 20: history.open(1000+i,"Conversation%d"%i)
	assert(history.conversations.size()==16)
	# Mixed Unicode histories exercise count, byte and whole-conversation eviction.
	for i: int in 2000:
		history.accept({"id":i+1000,"channel":"whisper","sender":1000+i%20,"name":"Whisper","target":2,"text":"😀\\\"".repeat(64)})
	assert(JSON.stringify(history.snapshot()).to_utf8_buffer().size()<=131072)
	history.clear();history.identify(2)
	for i: int in 200: history.accept({"id":i+5000,"channel":"general","sender":3,"name":"After clear","target":0,"text":"hello"})
	assert(history.messages.size()==200)
	for host: Node in hosts: host.free()
	server.free()
	print("CHAT_V1_OK authoritative channels, limits, identity, offline and session history")
	get_tree().quit()
