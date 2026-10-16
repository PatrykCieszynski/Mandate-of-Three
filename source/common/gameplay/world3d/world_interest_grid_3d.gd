class_name WorldInterestGrid3D
extends RefCounted
## Server-only broadphase for replicated 3D actors.
## The grid is rebuilt from authoritative positions before each World snapshot.
## A larger EXIT radius prevents visibility thrashing at the enter boundary.
const CELL_SIZE := 16.0
const ENTER_RADIUS := 48.0
const EXIT_RADIUS := 56.0

var _players: Dictionary = {}
var _mobs: Dictionary = {}
var _player_cells: Dictionary = {}
var _mob_cells: Dictionary = {}

static func _cell(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x / CELL_SIZE), floori(position.z / CELL_SIZE))

static func _insert(grid: Dictionary, cell: Vector2i, identity: int) -> void:
	if not grid.has(cell):
		grid[cell] = []
	grid[cell].append(identity)

func rebuild(characters: Dictionary, mobs: Dictionary) -> void:
	_players.clear()
	_mobs.clear()
	_player_cells.clear()
	_mob_cells.clear()
	for identity: int in characters:
		var body: Node3D = characters[identity]
		_players[identity] = body.position
		_insert(_player_cells, _cell(body.position), identity)
	for identity: int in mobs:
		var mob: Node3D = mobs[identity]
		_mobs[identity] = mob.position
		_insert(_mob_cells, _cell(mob.position), identity)

static func _nearby(center: Vector3, positions: Dictionary, grid: Dictionary, previously_visible: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var origin := _cell(center)
	var reach := ceili(EXIT_RADIUS / CELL_SIZE)
	for gx: int in range(origin.x - reach, origin.x + reach + 1):
		for gy: int in range(origin.y - reach, origin.y + reach + 1):
			var cell := Vector2i(gx, gy)
			if not grid.has(cell):
				continue
			for identity: int in grid[cell]:
				var target: Vector3 = positions[identity]
				var dx := target.x - center.x
				var dz := target.z - center.z
				var radius := EXIT_RADIUS if previously_visible.has(identity) else ENTER_RADIUS
				if dx * dx + dz * dz <= radius * radius:
					result[identity] = true
	return result

func visible_players(viewer: int, previous: Dictionary = {}) -> Dictionary:
	if not _players.has(viewer):
		return {}
	var result := _nearby(_players[viewer], _players, _player_cells, previous)
	# A player must always have their own body to receive own movement snapshots.
	result[viewer] = true
	return result

func visible_mobs(viewer: int, previous: Dictionary = {}) -> Dictionary:
	if not _players.has(viewer):
		return {}
	return _nearby(_players[viewer], _mobs, _mob_cells, previous)
