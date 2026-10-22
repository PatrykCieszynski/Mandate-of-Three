extends RefCounted
## Session-only projection survives local map/UI recreation, never a World reconnect.
signal changed
# Exact per-message JSON cost plus a conservative reserve for bounded metadata.
# No full history copy/serialization is needed to admit or prune a message.
const MESSAGE_BUDGET: int=98304
var owner: int=0
var messages: Array=[]
var conversations: Dictionary={}
var muted: Dictionary={}
var _seen: Dictionary={}
var _message_sizes: Dictionary={}
var _message_bytes: int=0
func identify(id: int) -> void:
	if owner!=id:
		clear();owner=id
	changed.emit()
func clear() -> void:
	owner=0;messages.clear();conversations.clear();muted.clear();_seen.clear()
	_message_sizes.clear();_message_bytes=0;changed.emit()
func _ensure_conversation(id: int, display_name: String) -> bool:
	if id<=0 or id==owner: return false
	if not conversations.has(id):
		if conversations.size()>=16:
			# Keep the conversation cache bounded, preferring closed histories for eviction.
			var evict: int=0
			for other: int in conversations:
				if evict==0 or conversations[other].mode=="closed": evict=other
				if conversations[other].mode=="closed": break
			while not conversations[evict].messages.is_empty(): _remove_first(conversations[evict].messages)
			conversations.erase(evict)
		conversations[id]={"id":id,"name":display_name,"mode":"minimized","unread":0,"messages":[]}
	conversations[id].name=display_name
	return true
func open(id: int, display_name: String, notify: bool = true) -> bool:
	if not _ensure_conversation(id,display_name): return false
	set_mode(id,"open",false)
	if notify: changed.emit()
	return true
func set_mode(id: int, mode: String, notify: bool=true) -> bool:
	if not conversations.has(id): return false
	if mode=="open":
		for other: int in conversations:
			if other!=id and conversations[other].mode=="open": conversations[other].mode="minimized"
		conversations[id].unread=0
	conversations[id].mode=mode
	if notify: changed.emit()
	return true
func _remove_first(list: Array) -> void:
	var message: Dictionary=list.pop_front()
	_message_bytes-=int(_message_sizes.get(int(message.id),0))
	_message_sizes.erase(int(message.id))
func _append(list: Array, message: Dictionary, count_limit: int) -> void:
	var size: int=JSON.stringify(message).to_utf8_buffer().size()+1
	_message_sizes[int(message.id)]=size;_message_bytes+=size
	list.append(message.duplicate(true))
	if list.size()>count_limit: _remove_first(list)
func accept(message: Dictionary) -> void:
	if muted.has(int(message.sender)) or _seen.has(int(message.id)): return
	_seen[int(message.id)]=true
	if _seen.size()>2000: _seen.erase(_seen.keys()[0])
	if message.channel=="whisper":
		var other: int=int(message.target) if int(message.sender)==owner else int(message.sender)
		if not conversations.has(other): _ensure_conversation(other,str(message.get("target_name","Player")) if int(message.sender)==owner else str(message.name))
		if not conversations.has(other): return
		var convo: Dictionary=conversations[other]
		_append(convo.messages,message,100)
		if convo.mode=="closed": convo.mode="minimized"
		if convo.mode!="open" and int(message.sender)!=owner: convo.unread+=1
	else:
		_append(messages,message,200)
	# The remaining 32 KiB of the 128 KiB cache budget covers conversation/mute metadata.
	while _message_bytes>MESSAGE_BUDGET:
		var oldest: Array=messages
		for convo: Dictionary in conversations.values():
			if not convo.messages.is_empty() and (oldest.is_empty() or int(convo.messages[0].id)<int(oldest[0].id)): oldest=convo.messages
		if oldest.is_empty(): break
		_remove_first(oldest)
	changed.emit()
func snapshot() -> Dictionary:
	return {"self":owner,"messages":messages.duplicate(true),"conversations":conversations.values().duplicate(true),"muted":muted.keys(),"guild_available":false}
