class_name UiCommandSession
extends RefCounted
## Native RPC correlation only. Browser command IDs/generations belong to transport.
var _sequence: int = 0
var _request_epoch: String = Crypto.new().generate_random_bytes(8).hex_encode()
var _pending: Dictionary[String, Dictionary] = {}
var _closed_reason: String = ""

func begin() -> String:
	if not _closed_reason.is_empty(): return ""
	_sequence += 1
	var id: String = "web-%s-%d" % [_request_epoch, _sequence]
	_pending[id] = {"result":{}}
	return id

func wait(id: String, tree: SceneTree, timeout_ms: int = 2500) -> Dictionary:
	if id.is_empty(): return closed_result()
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	# Capture SceneTree before suspension; the composition Node may leave the tree.
	while _pending.has(id) and _pending[id].result.is_empty() and Time.get_ticks_msec() < deadline:
		await tree.create_timer(0.025).timeout
	var result: Dictionary = _pending.get(id, {"result":{}}).result.duplicate(true)
	_pending.erase(id)
	return result if not result.is_empty() else {"ok":false,"error":"timeout"}

func finish(id: String, result: Dictionary) -> void:
	if _pending.has(id) and _pending[id].result.is_empty():
		_pending[id].result = result.duplicate(true)

func cancel(reason: String) -> void:
	for entry: Dictionary in _pending.values():
		if entry.result.is_empty(): entry.result = {"ok":false,"error":reason}

func close(reason: String) -> void:
	if not _closed_reason.is_empty(): return
	_closed_reason = reason
	cancel(reason)

func closed_result() -> Dictionary:
	return {"ok":false,"error":_closed_reason}
