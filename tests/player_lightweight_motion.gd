extends Node3D
## Functional checks for the opt-in flat-arena benchmark controller.
const BENCH_PLAYER := preload("res://tests/fixtures/bench_player_actor.gd")
const LIGHT_MOTION := preload("res://tests/fixtures/lightweight_player_motion.gd")
var _failed := false

func check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error("PLAYER_LIGHTWEIGHT_MOTION_FAILED: " + message)

func _box(name: String, pos: Vector3, size: Vector3, layer: int) -> void:
	var body := StaticBody3D.new()
	body.name = name
	body.position = pos
	body.collision_layer = layer
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	add_child(body)

func _ready() -> void:
	Engine.max_fps = 60
	_box("Floor", Vector3(0, -0.25, 0), Vector3(30, 0.5, 30), 17)
	_box("Wall", Vector3(2, 1, 0), Vector3(0.4, 2, 4), 1)
	var body: PlayerActor3D = BENCH_PLAYER.new()
	body.setup("Light experimental", Color.WHITE)
	body.set("lightweight_motion", true)
	body.position = Vector3(0, 0.15, 0)
	add_child(body)
	await get_tree().physics_frame
	for tick: int in 40:
		await get_tree().physics_frame
		body.simulate(1.0 / 60.0, Vector2.RIGHT)
	check(body.position.x > 1.0 and body.position.x < 1.52, "swept capsule stops at wall")
	var z_before := body.position.z
	for tick: int in 25:
		await get_tree().physics_frame
		body.simulate(1.0 / 60.0, Vector2(1, -1).normalized())
	print("LIGHT_PLAYER_WALL_SLIDE x=", body.position.x, " z=", body.position.z, " from=", z_before)
	check(body.position.x < 1.52 and body.position.z < z_before - 0.9,
		"blocked x permits tangential z travel")
	# This experiment intentionally keeps an actor on its current Y plane.
	check(absf(body.position.y - 0.15) < 0.001, "flat height remains constant")
	# A mob movement body still blocks approach through native swept shapes.
	var mob := MobActor3D.new()
	mob.setup_mob(77, Vector3(0, 0.15, 6))
	mob.position = Vector3(0, 0.15, 6)
	add_child(mob)
	body.position = Vector3(-2, 0.15, 6)
	await get_tree().physics_frame
	for tick: int in 35:
		await get_tree().physics_frame
		body.simulate(1.0 / 60.0, Vector2.RIGHT)
	check(body.position.x < -0.83, "sweep blocks approaching mob body")
	var stop_at := body.position.x
	for tick: int in 10:
		await get_tree().physics_frame
		body.simulate(1.0 / 60.0, Vector2.LEFT)
	check(body.position.x < stop_at - 0.5, "player can retreat from mob")
	# Knockback should still advance with the standard impulse damping model.
	body.position = Vector3(-5, 0.15, -5)
	body.apply_knockback(Vector3.RIGHT, 1.0)
	var starting := body.position.x
	for tick: int in 20:
		await get_tree().physics_frame
		body.simulate(1.0 / 60.0, Vector2.RIGHT)
	check(body.position.x > starting + 0.5, "knockback displacement retained")
	if _failed:
		get_tree().quit(1)
	else:
		print("PLAYER_LIGHTWEIGHT_MOTION_OK: wall, slide, height, mob blocking, retreat and knockback")
		get_tree().quit(0)
