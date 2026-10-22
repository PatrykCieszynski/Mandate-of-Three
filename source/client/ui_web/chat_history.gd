extends RefCounted
## Session-only projection survives local map/UI recreation, never a World reconnect.
signal changed
var owner: int=0
var messages: Array=[]
var conversations: Dictionary={}
var muted: Dictionary={}
var _seen: Dictionary={}
func identify(id: int) -> void:
	if owner!=id:
		clear();owner=id
	changed.emit()
func clear() -> void:
	owner=0;messages.clear();conversations.clear();muted.clear();_seen.clear();changed.emit()
func open(id: int, display_name: String) -> bool:
	if id<=0 or id==owner: return false
	if not conversations.has(id):
		if conversations.size()>=16:
			# Keep the conversation cache bounded, preferring closed histories for eviction.
			var evict: int=0
			for other: int in conversations:
				if evict==0 or conversations[other].mode=="closed": evict=other
				if conversations[other].mode=="closed": break
			conversations.erase(evict)
		conversations[id]={"id":id,"name":display_name,"mode":"open","unread":0,"messages":[]}
	conversations[id].name=display_name;conversations[id].mode="open";conversations[id].unread=0
	changed.emit()
	return true
func accept(message: Dictionary) -> void:
	if muted.has(int(message.sender)) or _seen.has(int(message.id)): return
	_seen[int(message.id)]=true
	if _seen.size()>2000: _seen.erase(_seen.keys()[0])
	if message.channel=="whisper":
		var other: int=int(message.target) if int(message.sender)==owner else int(message.sender)
		if not conversations.has(other): open(other,str(message.get("target_name","Player")) if int(message.sender)==owner else str(message.name))
		if not conversations.has(other): return
		var convo: Dictionary=conversations[other]
		convo.messages.append(message.duplicate(true))
		if convo.messages.size()>100: convo.messages.pop_front()
		if convo.mode=="closed": convo.mode="open"
		if convo.mode=="minimized": convo.unread+=1
	else:
		messages.append(message.duplicate(true))
		if messages.size()>200: messages.pop_front()
	# Bound reload IPC and long-lived session memory even with many Unicode whispers.
	while JSON.stringify(snapshot()).to_utf8_buffer().size()>131072:
		var oldest: Array=messages
		for convo: Dictionary in conversations.values():
			if not convo.messages.is_empty() and (oldest.is_empty() or int(convo.messages[0].id)<int(oldest[0].id)): oldest=convo.messages
		if oldest.is_empty(): break
		oldest.pop_front()
	changed.emit()
func snapshot() -> Dictionary:
	return {"self":owner,"messages":messages.duplicate(true),"conversations":conversations.values().duplicate(true),"muted":muted.keys(),"guild_available":false}
