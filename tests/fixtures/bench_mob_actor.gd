extends MobActor3D
## Test-only replacement that calls the original implementation in baseline.
static var motion_us := 0
static var motion_calls := 0
var no_slide := false

func simulate_mob(delta: float, direction: Vector2, now: int) -> void:
	var started := Time.get_ticks_usec()
	if no_slide:
		# Diagnostic ablation only: skips collision/physics entirely.
		# Never infer correctness or production performance from this mode.
		position += Vector3(direction.x, 0.0, direction.y) * move_speed * delta
	else:
		super.simulate_mob(delta, direction, now)
	motion_us += Time.get_ticks_usec() - started
	motion_calls += 1

static func reset_metrics() -> void:
	motion_us = 0
	motion_calls = 0
