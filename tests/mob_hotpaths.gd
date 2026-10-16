extends Node3D
## Production physics/collision smoke, not a synthetic performance benchmark.
const WILD := preload("res://source/common/gameplay/mobs/wild_dog.tres")
var _failed := false

func check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error("MOB_HOTPATHS_FAILED: " + message)

func _ready() -> void:
	# Headless smoke uses --quit-after measured in rendered/process frames;
	# cap idle FPS so 158 awaited physics frames can complete before the guard.
	Engine.max_fps = 60
	var server := WorldServer.new()
	WorldServer.curr = server
	var world := preload("res://tests/fixtures/world3d/test_arena.tscn").instantiate() as GameWorld3D
	add_child(world)
	world.set_physics_process(false)
	world.combat_endpoint.set_physics_process(false)
	for id: int in world.mob_system.mobs.keys():
		world.mob_system.remove_mob(id)
	world.mob_system.packs.clear()
	var entry := MobSpawnEntry.new()
	entry.mob = WILD
	var pack := world.mob_system.create_pack([entry], Vector3.ZERO, 0.0, 0.0, 20.0, 0.0)
	check(pack != null, "mob spawn")
	if pack == null:
		get_tree().quit(1)
		return
	var dog: MobActor3D = world.mob_system.mobs[pack.actor_ids[0]]
	var player := PlayerActor3D.new()
	player.setup("Smoke", Color.WHITE)
	player.position = Vector3.ZERO
	world.add_child(player)
	world.characters[7] = player
	dog.position = Vector3(0.25, 0.1, 0)
	await get_tree().physics_frame
	var overlaps: Array[PhysicsBody3D] = player._overlapping_mob_bodies()
	check(overlaps.has(dog), "native physics query detects overlapping mob body")
	dog.position = Vector3(8, 0.1, 0)
	await get_tree().physics_frame
	overlaps = player._overlapping_mob_bodies()
	check(not overlaps.has(dog), "native physics query rejects distant mob")
	# Exercise the real motion solver against the floor, not just algebra.
	dog.position = Vector3(0, 0.1, 0)
	for index: int in 8:
		await get_tree().physics_frame
		dog.simulate_mob(1.0 / 60.0, Vector2.ZERO, Time.get_ticks_msec())
	check(dog.is_on_floor(), "mob settles on physics floor")
	var before := dog.position
	for index: int in 120:
		await get_tree().physics_frame
		dog.simulate_mob(1.0 / 60.0, Vector2.RIGHT, Time.get_ticks_msec())
	var moved := dog.position.x - before.x
	check(absf(moved - dog.move_speed * 2.0) < 0.30, "grounded 30Hz motion preserves distance over 120 ticks")
	var idle := dog.position
	for index: int in 30:
		await get_tree().physics_frame
		dog.simulate_mob(1.0 / 60.0, Vector2.ZERO, Time.get_ticks_msec())
	check(dog.position.distance_to(idle) < 0.05, "grounded idle remains stationary")
	world.free()
	WorldServer.curr = null
	server.free()
	if _failed:
		get_tree().quit(1)
	else:
		print("MOB_HOTPATHS_OK: native overlap, grounded movement and idle")
		get_tree().quit(0)
