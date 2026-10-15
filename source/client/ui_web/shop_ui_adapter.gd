class_name ShopUiAdapter
extends RefCounted
## Shop commands/presentation. Composition decides Inventory visibility.
signal state_updated(snapshot: Dictionary)
var _endpoint: Shop3D
var _dispatcher: UiCommandDispatcher
var _session: UiCommandSession
var _tree: SceneTree
# One unresolved purchase per economy/account/character, journaled before send.
# Business identity is independent of the native/browser RPC correlation IDs.
const PurchaseJournal = preload("res://source/client/ui_web/local_economy_journal.gd")
var journal = PurchaseJournal.new()
var _context: Dictionary = {}
var _journal_ready := false
var _purchase: Dictionary = {}
var _buy_in_flight := false
var _disposed := false
var _last_catalog: Dictionary = {"active":false}
var _recovery_hidden := false

func attach(endpoint: Shop3D, dispatcher: UiCommandDispatcher, session: UiCommandSession, tree: SceneTree) -> void:
	_endpoint = endpoint
	_dispatcher = dispatcher
	_session = session
	_tree = tree
	dispatcher.register_command("shop.open", NpcUiAdapter.valid_service, func(p: Dictionary) -> Dictionary: return await _submit("open", p))
	dispatcher.register_command("shop.buy", valid_buy, func(p: Dictionary) -> Dictionary: return await _submit("buy", p))
	dispatcher.register_command("shop.retry", func(p: Dictionary) -> bool: return p.is_empty(), func(_p: Dictionary) -> Dictionary: return await retry_purchase())
	dispatcher.register_command("shop.dismiss_recovery", func(p: Dictionary) -> bool: return p.is_empty(), func(_p: Dictionary) -> Dictionary:
		_recovery_hidden = true
		publish(_endpoint.state)
		return {"ok":true})
	endpoint.state_changed.connect(publish)
	endpoint.operation_finished.connect(session.finish)
	publish(endpoint.state)

# Only the authenticated private Inventory projection supplies this context.
func accept_context(snapshot: Dictionary) -> void:
	if _disposed or not snapshot.get("ok", false): return
	var context: Dictionary = snapshot.get("economic_context", {})
	if context.is_empty() or context == _context: return
	# An adapter belongs to one world entry. Never retarget an unresolved intent.
	if not _context.is_empty():
		_journal_ready = false
		return
	_context = context.duplicate(true)
	var restored: Dictionary = journal.configure(context)
	if not restored.ok: return
	if not restored.entry.is_empty() and not valid_buy(restored.entry.payload): return
	_journal_ready = true
	if restored.entry.is_empty(): return
	_purchase = restored.entry.duplicate(true)
	_purchase.uncertain = true
	var p: Dictionary = _purchase.payload
	_last_catalog = {"active":true,"npcInstanceId":p.npc_instance_id,"serviceId":p.service_id,"shopId":"purchase_confirmation","name":"Purchase confirmation","currency":"yang","offers":[]}
	publish(_endpoint.state)
	# Discovery can confirm a receipt, never automatically execute a purchase.
	retry_purchase.call_deferred(false)

func _release_purchase() -> bool:
	if not journal.clear_pending(_purchase.id):
		_purchase.uncertain = true
		publish(_endpoint.state)
		return false
	_purchase.clear()
	return true

func dispose() -> void:
	_disposed = true
	if is_instance_valid(_endpoint):
		if _endpoint.state_changed.is_connected(publish): _endpoint.state_changed.disconnect(publish)
		if _endpoint.operation_finished.is_connected(_session.finish): _endpoint.operation_finished.disconnect(_session.finish)

func publish(snapshot: Dictionary) -> void:
	if _disposed: return
	var view := snapshot.duplicate(true)
	var unresolved := not _purchase.is_empty() and bool(_purchase.uncertain)
	if view.get("active", false):
		_last_catalog = snapshot.duplicate(true)
		_recovery_hidden = false
	elif unresolved and not _recovery_hidden and _last_catalog.get("active", false):
		view = _last_catalog.duplicate(true)
		view.name = "Purchase confirmation"
		view.offers = [] # Recovery presentation never advertises a usable catalog.
		view["recoveryOnly"] = true
	if view.get("active", false): view["purchasePending"] = unresolved
	_dispatcher.set_domain("shop", view)
	state_updated.emit(view)

static func valid_buy(p: Dictionary) -> bool:
	if p.size() not in [3, 6] or not p.has_all(["npc_instance_id", "service_id", "offer_id"]): return false
	if not NpcUiAdapter.valid_service({"npc_instance_id":p.npc_instance_id, "service_id":p.service_id}) or not p.offer_id is String or not GameplayContentId.valid(StringName(p.offer_id)): return false
	if p.size() == 3: return true
	return p.has_all(["x", "y", "page"]) and WebUiBridge.is_integer(p.x) and WebUiBridge.is_integer(p.y) and WebUiBridge.is_integer(p.page) and p.x >= 0 and p.x < InventoryGrid.COLUMNS and p.y >= 0 and p.y < InventoryGrid.ROWS and p.page >= 0 and p.page < InventoryGrid.PAGES

func retry_purchase(allow_purchase: bool = true) -> Dictionary:
	if _disposed: return _session.closed_result()
	if not _journal_ready: return {"ok":false,"error":"journal_unavailable"}
	if _purchase.is_empty(): return {"ok":false,"error":"no_pending_purchase"}
	if _buy_in_flight: return {"ok":false,"error":"too_fast"}
	var id := _session.begin()
	if id.is_empty(): return _session.closed_result()
	_buy_in_flight = true
	_endpoint.request_shop.rpc_id(1, "receipt", "", "", "", -1, id, _purchase.id)
	var result := await _session.wait(id, _tree)
	if _disposed: return result
	_buy_in_flight = false
	if result.ok:
		if not _release_purchase(): return {"ok":false,"error":"journal_unavailable"}
		publish(_endpoint.state)
		return result
	if result.get("error", "") == "unknown_command" and allow_purchase:
		# Absence is not economic failure. A retry may execute only through the
		# original mutation path, which reauthorizes the NPC/service/range.
		return await _submit("buy", _purchase.payload.duplicate(true))
	_purchase.uncertain = true
	publish(_endpoint.state)
	return {"ok":false,"error":"purchase_pending"}

func _submit(action: String, p: Dictionary) -> Dictionary:
	if action == "buy":
		if not _journal_ready: return {"ok":false,"error":"journal_unavailable"}
		if _buy_in_flight: return {"ok":false,"error":"too_fast"}
		if not _purchase.is_empty() and _purchase.payload != p: return {"ok":false,"error":"purchase_pending"}
	if action == "buy" and _purchase.is_empty():
		var intention := "npc-buy-" + Crypto.new().generate_random_bytes(16).hex_encode()
		if not journal.save_pending(intention, p):
			_journal_ready = false
			return {"ok":false,"error":"journal_unavailable"}
		_purchase = {"id":intention,"payload":p.duplicate(true),"uncertain":false}
	var id: String = _session.begin()
	if id.is_empty(): return _session.closed_result()
	var operation_id := ""
	if action == "buy":
		operation_id = _purchase.id
		_buy_in_flight = true
	var position: int = int(p.page) * InventoryGrid.PAGE_CELLS + int(p.y) * InventoryGrid.COLUMNS + int(p.x) if p.has("x") else -1
	_endpoint.request_shop.rpc_id(1, action, p.npc_instance_id, p.service_id, p.get("offer_id", ""), position, id, operation_id)
	var result := await _session.wait(id, _tree)
	if _disposed: return result # No publication into a torn-down UI.
	if action == "buy":
		_buy_in_flight = false
		if result.ok or result.get("error", "") in ["funds", "occupied", "inventory_full", "unknown_offer", "request"]:
			# These store rejections follow receipt lookup. A prior committed purchase
			# would have replayed success, so a definitive rejection can be released.
			if not _release_purchase(): return {"ok":false,"error":"journal_unavailable"}
		elif bool(_purchase.uncertain) or result.get("error", "") in ["timeout", "ui_reload", "disconnected", "storage"]:
			# An authorization/transport failure on retry is not proof that the
			# earlier purchase failed. Reopen that service and retry the same item.
			_purchase.uncertain = true
			publish(_endpoint.state)
			return {"ok":false,"error":"purchase_pending"}
		else:
			if not _release_purchase(): return {"ok":false,"error":"journal_unavailable"}
		publish(_endpoint.state)
	return result
