class_name CombatTraceDefinition
extends Resource
## Actor-local baked blade geometry and gameplay Y allowance. No animation dependency.
@export var radius: float = 0.20
@export var vertical_padding_down: float = 0.9
@export var vertical_padding_up: float = 0.3
@export var samples: Array[CombatTraceSample] = []

func valid(start_ms: int, end_ms: int) -> bool:
	if not is_finite(radius) or radius <= 0 or samples.size() < 2 or samples.size() > 32: return false
	if not is_finite(vertical_padding_down) or vertical_padding_down < 0 or not is_finite(vertical_padding_up) or vertical_padding_up < 0: return false
	var previous := -1
	for sample: CombatTraceSample in samples:
		if sample == null or sample.time_ms < start_ms or sample.time_ms > end_ms or sample.time_ms <= previous: return false
		if not sample.base.is_finite() or not sample.tip.is_finite() or sample.base.distance_squared_to(sample.tip) < 0.0001: return false
		previous = sample.time_ms
	return samples[0].time_ms == start_ms and samples.back().time_ms == end_ms

func sweep_padding() -> float:
	var length := 0.0
	for sample: CombatTraceSample in samples: length = maxf(length,sample.base.distance_to(sample.tip))
	return length / 16.0 # Half spacing between the nine swept blade rails.

func bounds() -> AABB:
	var box := AABB(samples[0].base,Vector3.ZERO)
	for sample: CombatTraceSample in samples:
		box = box.expand(sample.base).expand(sample.tip)
	var horizontal_padding := radius+sweep_padding()
	return AABB(box.position-Vector3(horizontal_padding,radius+vertical_padding_down,horizontal_padding),
		box.size+Vector3(2*horizontal_padding,2*radius+vertical_padding_down+vertical_padding_up,2*horizontal_padding))

func vertical_interval(previous: CombatTraceSample, current: CombatTraceSample) -> Vector2:
	var low := minf(minf(previous.base.y,previous.tip.y),minf(current.base.y,current.tip.y))
	var high := maxf(maxf(previous.base.y,previous.tip.y),maxf(current.base.y,current.tip.y))
	return Vector2(low-radius-vertical_padding_down,high+radius+vertical_padding_up)
