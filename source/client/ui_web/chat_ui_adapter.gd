extends RefCounted
const Chat = preload("res://source/common/gameplay/chat/world_chat.gd")
var _endpoint: Node
var _dispatcher: UiCommandDispatcher
var _session: UiCommandSession
var _tree: SceneTree
var _history: RefCounted
var _lookups: Dictionary={}
func attach(endpoint: Node, dispatcher: UiCommandDispatcher, session: UiCommandSession, tree: SceneTree) -> void:
	_endpoint=endpoint;_dispatcher=dispatcher;_session=session;_tree=tree;_history=ClientState.chat_history
	dispatcher.register_command("chat.send",Chat.valid,_submit)
	dispatcher.register_command("chat.open",func(p: Dictionary)->bool: return p.size()==2 and WebUiBridge.is_integer(p.get("target")) and p.target>0 and p.get("name") is String and p.name.length()<=64,func(p: Dictionary)->Dictionary: return {"ok":true} if _history.open(int(p.target),p.name) else {"ok":false,"error":"conversation_limit"})
	dispatcher.register_command("chat.conversation",_valid_conversation,_conversation)
	dispatcher.register_command("chat.mute",func(p: Dictionary)->bool: return p.size()==2 and WebUiBridge.is_integer(p.get("target")) and p.target>0 and p.get("muted") is bool,_mute)
	endpoint.initialized.connect(_identify);endpoint.message_received.connect(_history.accept);endpoint.operation_finished.connect(_result)
	_history.changed.connect(publish)
	if not endpoint.info.is_empty(): _identify(endpoint.info)
	publish()
func _identify(info: Dictionary) -> void: _history.identify(int(info.self))
func publish() -> void: _dispatcher.set_domain("chat",_history.snapshot())
func focus() -> void: _dispatcher.bridge.send("ui.shortcut",{"key":"Enter"})
func _submit(payload: Dictionary) -> Dictionary:
	var id: String=_session.begin()
	if id.is_empty(): return _session.closed_result()
	if payload.get("action")=="lookup": _lookups[id]=true
	_endpoint.request.rpc_id(1,id,payload)
	var result: Dictionary=await _session.wait(id,_tree)
	_lookups.erase(id)
	return result
func _result(id: String, result: Dictionary) -> void:
	if _lookups.has(id) and result.get("ok",false) and result.has_all(["target","name"]):
		if not _history.open(int(result.target),str(result.name)): result={"ok":false,"error":"conversation_limit"}
	_session.finish(id,{"ok":bool(result.get("ok",false))} if result.get("ok",false) else {"ok":false,"error":str(result.get("error","request"))})
func _valid_conversation(p: Dictionary) -> bool:
	return p.size()==2 and WebUiBridge.is_integer(p.get("target")) and p.target>0 and p.get("mode") in ["open","closed","minimized"]
func _conversation(p: Dictionary) -> Dictionary:
	var convo: Dictionary=_history.conversations.get(int(p.target),{})
	if convo.is_empty(): return {"ok":false,"error":"conversation"}
	_history.set_mode(int(p.target),p.mode);return {"ok":true}
func _mute(p: Dictionary) -> Dictionary:
	if p.muted and not _history.muted.has(int(p.target)) and _history.muted.size()>=1024: return {"ok":false,"error":"mute_limit"}
	if p.muted: _history.muted[int(p.target)]=true
	else: _history.muted.erase(int(p.target))
	_history.changed.emit();return {"ok":true}
func dispose() -> void:
	if _history!=null and _history.changed.is_connected(publish): _history.changed.disconnect(publish)
	if not is_instance_valid(_endpoint): return
	if _endpoint.initialized.is_connected(_identify): _endpoint.initialized.disconnect(_identify)
	if _endpoint.message_received.is_connected(_history.accept): _endpoint.message_received.disconnect(_history.accept)
	if _endpoint.operation_finished.is_connected(_result): _endpoint.operation_finished.disconnect(_result)
