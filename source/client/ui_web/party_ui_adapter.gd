extends RefCounted
## Client projection and request correlation only; party rules remain on World.
const Service = preload("res://source/common/gameplay/party/party_service.gd")
var _endpoint: Node
var _dispatcher: UiCommandDispatcher
var _session: UiCommandSession
var _tree: SceneTree
var _opened: bool = true
var _inviter: int = 0
func attach(endpoint: Node, dispatcher: UiCommandDispatcher, session: UiCommandSession, tree: SceneTree) -> void:
	_endpoint=endpoint;_dispatcher=dispatcher;_session=session;_tree=tree
	dispatcher.register_command("party.command",Service.valid,_submit)
	dispatcher.register_command("party.close",func(p: Dictionary)->bool: return p.is_empty(),func(_p: Dictionary)->Dictionary: _opened=false;publish(_endpoint.state);return {"ok":true})
	endpoint.state_changed.connect(publish)
	endpoint.operation_finished.connect(session.finish)
	publish(endpoint.state)
func publish(snapshot: Dictionary) -> void:
	if snapshot.is_empty(): return
	var inviter: int=int(snapshot.get("invite",{}).get("from",0))
	if inviter>0 and inviter!=_inviter: _opened=true
	_inviter=inviter
	var value: Dictionary=snapshot.duplicate(true);value.opened=_opened
	_dispatcher.set_domain("party",value)
func toggle() -> void:
	_opened=not _opened;publish(_endpoint.state)
func _submit(payload: Dictionary) -> Dictionary:
	var id: String=_session.begin()
	if id.is_empty(): return _session.closed_result()
	_endpoint.request.rpc_id(1,id,payload)
	return await _session.wait(id,_tree)
func dispose() -> void:
	if not is_instance_valid(_endpoint): return
	if _endpoint.state_changed.is_connected(publish): _endpoint.state_changed.disconnect(publish)
	if _endpoint.operation_finished.is_connected(_session.finish): _endpoint.operation_finished.disconnect(_session.finish)
