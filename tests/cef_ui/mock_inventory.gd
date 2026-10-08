class_name MockInventory
extends RefCounted
## Spike-only authoritative mock. No production inventory or generic dispatch.
var revision: int = 0
var ticks: int = 0
var items: Array[Dictionary] = [
	{"id":"potion","name":"Potion","x":0,"y":0,"height":1},
	{"id":"blade","name":"Blade","x":2,"y":1,"height":2},
	{"id":"spear","name":"Spear","x":4,"y":2,"height":3}]

func snapshot() -> Dictionary:
	return {"columns":6,"rows":7,"revision":revision,"ticks":ticks,"items":items.duplicate(true)}

func move_item(payload: Dictionary) -> Dictionary:
	if payload.size() != 4 or not payload.has_all(["id","x","y","revision"]): return _reject("shape")
	if not payload.id is String or payload.id.length() > 32: return _reject("id")
	for key: String in ["x","y","revision"]:
		if not (payload[key] is int or payload[key] is float): return _reject("integer")
		if not is_finite(float(payload[key])) or float(payload[key]) != floor(float(payload[key])) or absf(float(payload[key])) > 2147483647: return _reject("integer")
	if int(payload.revision) != revision: return _reject("stale")
	var item: Dictionary = {}
	for candidate: Dictionary in items:
		if candidate.id == payload.id: item = candidate
	if item.is_empty(): return _reject("id")
	var x: int = int(payload.x)
	var y: int = int(payload.y)
	if x < 0 or x >= 6 or y < 0 or y + int(item.height) > 7: return _reject("bounds")
	for other: Dictionary in items:
		if other.id != item.id and int(other.x) == x and y < int(other.y) + int(other.height) and y + int(item.height) > int(other.y): return _reject("overlap")
	item.x = x
	item.y = y
	revision += 1
	return {"ok":true,"error":""}

func _reject(reason: String) -> Dictionary:
	return {"ok":false,"error":reason}
