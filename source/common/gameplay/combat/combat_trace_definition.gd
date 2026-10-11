class_name CombatTraceDefinition
extends Resource
## Actor-local blade geometry only. No animation or presentation dependency.
@export var radius: float = 0.20
@export var samples: Array[CombatTraceSample] = []

func valid(start_ms: int, end_ms: int) -> bool:
	if not is_finite(radius) or radius <= 0 or samples.size() < 2 or samples.size() > 32: return false
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
	return box.grow(radius+sweep_padding())
