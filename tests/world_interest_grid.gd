extends Node
## Pure interest selection regression tests; no peers or database needed.

func _ready() -> void:
	var grid := WorldInterestGrid3D.new()
	var viewer := Node3D.new()
	var remote := Node3D.new()
	var mob := Node3D.new()
	add_child(viewer)
	add_child(remote)
	add_child(mob)
	viewer.position = Vector3.ZERO
	remote.position = Vector3(80, 0, 0)
	mob.position = Vector3(-80, 0, 0)
	var players := {1: viewer, 2: remote}
	var mobs := {100: mob}
	grid.rebuild(players, mobs)
	_expect(grid.visible_players(1).has(1), "viewer must see self")
	_expect(not grid.visible_players(1).has(2), "far player hidden")
	_expect(not grid.visible_mobs(1).has(100), "far mob hidden")
	# Cross 16m grid boundaries, including negative world coordinates.
	remote.position = Vector3(47.0, 0, 0)
	mob.position = Vector3(-47.0, 0, 0)
	grid.rebuild(players, mobs)
	var seen_players := grid.visible_players(1)
	var seen_mobs := grid.visible_mobs(1)
	_expect(seen_players.has(2), "player enters at 47m")
	_expect(seen_mobs.has(100), "mob enters at -47m")
	remote.position = Vector3(54.0, 0, 0)
	mob.position = Vector3(-54.0, 0, 0)
	grid.rebuild(players, mobs)
	seen_players = grid.visible_players(1, seen_players)
	seen_mobs = grid.visible_mobs(1, seen_mobs)
	_expect(seen_players.has(2), "player stays during exit hysteresis")
	_expect(seen_mobs.has(100), "mob stays during exit hysteresis")
	# New observers do not acquire entities within the outer/exit-only radius.
	_expect(not grid.visible_players(1).has(2), "not a new entry at 54m")
	remote.position = Vector3(57.0, 0, 0)
	mob.position = Vector3(-57.0, 0, 0)
	grid.rebuild(players, mobs)
	seen_players = grid.visible_players(1, seen_players)
	seen_mobs = grid.visible_mobs(1, seen_mobs)
	_expect(not seen_players.has(2), "player exits at 57m")
	_expect(not seen_mobs.has(100), "mob exits at -57m")
	_expect(grid.visible_players(1).has(1), "self retained after AOI exit")
	_expect(grid.visible_players(999).is_empty(), "invalid viewer sees nothing")
	print("WORLD_INTEREST_GRID_OK")
	get_tree().quit(0)

func _expect(condition: bool, description: String) -> void:
	if not condition:
		push_error("WORLD_INTEREST_GRID_FAILED: " + description)
		get_tree().quit(1)
