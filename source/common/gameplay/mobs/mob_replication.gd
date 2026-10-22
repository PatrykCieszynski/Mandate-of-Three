extends RefCounted
## Per-MapInstance interest and reliable-channel baselines, not simulation state.
## Each packet has complete membership plus changed compact records.

const POSITION_EPSILON_SQUARED: float = 0.0001
const YAW_EPSILON: float = 0.005
var enter_radius: float
var exit_radius: float
var position_interval_ms: int
var cell_size: float
var _cells: Dictionary[Vector2i, Array] = {}
var _records: Dictionary[int, Array] = {}
var _peers: Dictionary[int, Dictionary] = {}

func _init(enter: float, leave: float, interval_ms: int, size: float) -> void:
	assert(enter > 0 and leave >= enter and interval_ms > 0 and size > 0)
	enter_radius = enter
	exit_radius = leave
	position_interval_ms = interval_ms
	cell_size = size

func _cell(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x / cell_size), floori(position.z / cell_size))

func begin_frame(mobs: Dictionary[int, MobActor3D], now: int) -> void:
	_cells.clear()
	_records.clear()
	for id: int in mobs:
		var record := MobSnapshot.capture(mobs[id], now)
		_records[id] = record
		var cell := _cell(record[MobSnapshot.Field.POSITION])
		if not _cells.has(cell):
			_cells[cell] = []
		_cells[cell].append(id)

func remove_peer(peer: int) -> void:
	_peers.erase(peer)

func packet_for(peer: int, position: Vector3, now: int) -> Dictionary:
	var previous: Dictionary = _peers.get(peer, {"sent": {}, "motion_at": {}})
	var sent: Dictionary = previous.sent
	var motion_at: Dictionary = previous.motion_at
	var visible: Array[int] = []
	var updates: Array = []
	var center := _cell(position)
	var reach := ceili(exit_radius / cell_size)
	for cell: Vector2i in _nearby_cells(center, reach):
		for id: int in _cells[cell]:
			var current: Array = _records[id]
			var mob_position: Vector3 = current[MobSnapshot.Field.POSITION]
			var radius := exit_radius if sent.has(id) else enter_radius
			if Vector2(position.x - mob_position.x, position.z - mob_position.z).length_squared() > radius * radius:
				continue
			visible.append(id)
			var record := current.duplicate()
			var include_motion := not sent.has(id)
			if sent.has(id):
				var last: Array = sent[id]
				var moved := mob_position.distance_squared_to(last[MobSnapshot.Field.POSITION]) > POSITION_EPSILON_SQUARED
				var turned := absf(angle_difference(last[MobSnapshot.Field.YAW], record[MobSnapshot.Field.YAW])) > YAW_EPSILON
				if now - int(motion_at[id]) < position_interval_ms or not (moved or turned):
					record[MobSnapshot.Field.POSITION] = last[MobSnapshot.Field.POSITION]
					record[MobSnapshot.Field.YAW] = last[MobSnapshot.Field.YAW]
				else:
					motion_at[id] = now
					include_motion = true
				if record == last:
					continue
			else:
				motion_at[id] = now
			sent[id] = record
			var wire := record.duplicate()
			if not include_motion:
				wire[MobSnapshot.Field.POSITION] = null
				wire[MobSnapshot.Field.YAW] = null
			updates.append(wire)
	var present: Dictionary = {}
	for id: int in visible:
		present[id] = true
	for id: int in sent.keys():
		if not present.has(id):
			sent.erase(id)
			motion_at.erase(id)
	_peers[peer] = {"sent": sent, "motion_at": motion_at}
	return {"mob_ids": visible, "mobs": updates}

func _nearby_cells(center: Vector2i, reach: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var diameter := reach * 2 + 1
	# A large configured radius must not enumerate billions of empty buckets.
	# Choose the smaller search space; both branches use identical cell bounds.
	if _cells.size() < diameter * diameter:
		for cell: Vector2i in _cells:
			if absi(cell.x - center.x) <= reach and absi(cell.y - center.y) <= reach:
				result.append(cell)
	else:
		for x: int in range(center.x - reach, center.x + reach + 1):
			for z: int in range(center.y - reach, center.y + reach + 1):
				var cell := Vector2i(x, z)
				if _cells.has(cell): result.append(cell)
	return result
