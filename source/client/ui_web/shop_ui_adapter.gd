class_name ShopUiAdapter
extends RefCounted
## Shop commands/presentation. Composition decides Inventory visibility.
signal state_updated(snapshot: Dictionary)
var _endpoint: Shop3D
var _dispatcher: UiCommandDispatcher
var _session: UiCommandSession
var _tree: SceneTree
# One unresolved purchase per adapter. Survives browser reload, not client exit.
# Business identity is independent of the native/browser RPC correlation IDs.
var _purchase: Dictionary = {}
var _buy_in_flight := false

func attach(endpoint: Shop3D, dispatcher: UiCommandDispatcher, session: UiCommandSession, tree: SceneTree) -> void:
	_endpoint = endpoint
	_dispatcher = dispatcher
	_session = session
	_tree = tree
	dispatcher.register_command("shop.open", NpcUiAdapter.valid_service, func(p: Dictionary) -> Dictionary: return await _submit("open", p))
	dispatcher.register_command("shop.buy", valid_buy, func(p: Dictionary) -> Dictionary: return await _submit("buy", p))
	endpoint.state_changed.connect(publish)
	endpoint.operation_finished.connect(session.finish)
	publish(endpoint.state)

func dispose() -> void:
	if is_instance_valid(_endpoint):
		if _endpoint.state_changed.is_connected(publish): _endpoint.state_changed.disconnect(publish)
		if _endpoint.operation_finished.is_connected(_session.finish): _endpoint.operation_finished.disconnect(_session.finish)

func publish(snapshot: Dictionary) -> void:
	_dispatcher.set_domain("shop", snapshot)
	state_updated.emit(snapshot)

static func valid_buy(p: Dictionary) -> bool:
	if p.size() not in [3, 6] or not p.has_all(["npc_instance_id", "service_id", "offer_id"]): return false
	if not NpcUiAdapter.valid_service({"npc_instance_id":p.npc_instance_id, "service_id":p.service_id}) or not p.offer_id is String or not GameplayContentId.valid(StringName(p.offer_id)): return false
	if p.size() == 3: return true
	return p.has_all(["x", "y", "page"]) and WebUiBridge.is_integer(p.x) and WebUiBridge.is_integer(p.y) and WebUiBridge.is_integer(p.page) and p.x >= 0 and p.x < InventoryGrid.COLUMNS and p.y >= 0 and p.y < InventoryGrid.ROWS and p.page >= 0 and p.page < InventoryGrid.PAGES

func _submit(action: String, p: Dictionary) -> Dictionary:
	if action == "buy":
		if _buy_in_flight: return {"ok":false,"error":"too_fast"}
		if not _purchase.is_empty() and _purchase.payload != p: return {"ok":false,"error":"purchase_pending"}
	var id: String = _session.begin()
	if id.is_empty(): return _session.closed_result()
	var operation_id := ""
	if action == "buy":
		if _purchase.is_empty():
			_purchase = {"id":"npc-buy-" + Crypto.new().generate_random_bytes(16).hex_encode(), "payload":p.duplicate(true), "uncertain":false}
		operation_id = _purchase.id
		_buy_in_flight = true
	var position: int = int(p.page) * InventoryGrid.PAGE_CELLS + int(p.y) * InventoryGrid.COLUMNS + int(p.x) if p.has("x") else -1
	_endpoint.request_shop.rpc_id(1, action, p.npc_instance_id, p.service_id, p.get("offer_id", ""), position, id, operation_id)
	var result := await _session.wait(id, _tree)
	if action == "buy":
		_buy_in_flight = false
		if result.ok or result.get("error", "") in ["funds", "occupied", "inventory_full", "unknown_offer", "request"]:
			# These store rejections follow receipt lookup. A prior committed purchase
			# would have replayed success, so a definitive rejection can be released.
			_purchase.clear()
		elif bool(_purchase.uncertain) or result.get("error", "") in ["timeout", "ui_reload", "disconnected", "storage"]:
			# An authorization/transport failure on retry is not proof that the
			# earlier purchase failed. Reopen that service and retry the same item.
			_purchase.uncertain = true
			return {"ok":false,"error":"purchase_pending"}
		else:
			_purchase.clear()
	return result
