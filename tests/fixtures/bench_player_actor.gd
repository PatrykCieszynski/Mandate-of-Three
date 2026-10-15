extends PlayerActor3D
## Profiling-only actor. Production movement remains inherited.
static var overlap_calls := 0
static var overlap_us := 0
static var simulate_us := 0
static var simulate_calls := 0
var skip_overlap := false
var lightweight_motion := false
var _light_controller := preload("res://tests/fixtures/lightweight_player_motion.gd").new()

func simulate(delta: float, direction: Vector2) -> void:
	var started := Time.get_ticks_usec()
	if lightweight_motion:
		_light_controller.simulate(self, delta, direction)
	else:
		super.simulate(delta, direction)
	simulate_us += Time.get_ticks_usec() - started
	simulate_calls += 1

func _overlapping_mob_bodies() -> Array[PhysicsBody3D]:
	var started := Time.get_ticks_usec()
	var result: Array[PhysicsBody3D] = []
	if not skip_overlap:
		result = super._overlapping_mob_bodies()
	overlap_us += Time.get_ticks_usec() - started
	overlap_calls += 1
	return result

static func reset_metrics() -> void:
	overlap_calls = 0
	overlap_us = 0
	simulate_us = 0
	simulate_calls = 0
