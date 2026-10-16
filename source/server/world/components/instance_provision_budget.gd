extends RefCounted
## Local creation guard only. No gameplay or economic authority lives here.
const WINDOW_SIZE := 120
const SETTLE_MS := 2000
const MAX_SAMPLE_AGE_MS := 250
var physics_samples := PackedFloat64Array()
var frame_samples := PackedFloat64Array()
var first_sample_ms: int = -1
var last_sample_ms: int = -1
var settle_until_ms: int = 0


func reset(now_ms: int) -> void:
	physics_samples.clear()
	frame_samples.clear()
	first_sample_ms = -1
	last_sample_ms = -1
	settle_until_ms = now_ms + SETTLE_MS


func record(physics_ms: float, frame_ms: float, now_ms: int) -> void:
	var tick_ms := 1000.0 / Engine.physics_ticks_per_second
	if not is_finite(physics_ms) or not is_finite(frame_ms) or physics_ms < 0 or frame_ms < 0:
		reset(now_ms)
		return
	if last_sample_ms >= 0 and now_ms - last_sample_ms > tick_ms * 2.0:
		reset(now_ms)
	if first_sample_ms < 0:
		first_sample_ms = now_ms
	last_sample_ms = now_ms
	physics_samples.append(physics_ms)
	frame_samples.append(frame_ms)
	if physics_samples.size() > WINDOW_SIZE:
		physics_samples.remove_at(0)
		frame_samples.remove_at(0)


func p95(values: PackedFloat64Array) -> float:
	if values.is_empty():
		return INF
	var ordered := values.duplicate()
	ordered.sort()
	return ordered[ceili(ordered.size() * 0.95) - 1]


func has_headroom(now_ms: int) -> bool:
	if physics_samples.size() < WINDOW_SIZE or now_ms < settle_until_ms:
		return false
	if now_ms - first_sample_ms < 1000 or now_ms - last_sample_ms > MAX_SAMPLE_AGE_MS:
		return false
	var cpu_budget_ms := 0.75 * 1000.0 / Engine.physics_ticks_per_second
	# Sum conservatively: headless idle frames can report very little process time
	# while a physics tick consumes most of the main-thread budget.
	return p95(physics_samples) + p95(frame_samples) < cpu_budget_ms
