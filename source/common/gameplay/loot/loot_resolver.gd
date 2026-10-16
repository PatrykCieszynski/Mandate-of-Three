class_name LootResolver
extends RefCounted
## Pure ordinary item selection. Sources combine; they do not cause separate rolls.
## Inputs (including player Luck) must be resolved by authoritative World callers.
const BASIS_POINTS: int = 10000
const MAX_BASE_ATTEMPTS: int = 4

static func resolve(tables: Array[LootTable], base_attempts: int, luck_chance_bp: int, rng: RandomNumberGenerator) -> Dictionary:
	if rng == null or base_attempts < 1 or base_attempts > MAX_BASE_ATTEMPTS:
		return {"ok": false, "error": "attempts"}
	if luck_chance_bp < 0 or luck_chance_bp > BASIS_POINTS:
		return {"ok": false, "error": "luck"}

	# Reject the full content set before consuming RNG or producing partial outcomes.
	var entries: Array[LootEntry] = []
	var sum_bp: int = 0
	for table: LootTable in tables:
		if table == null:
			continue # Missing optional scope: e.g. no per-mob table.
		if not table.valid():
			return {"ok": false, "error": "entry"}
		for entry: LootEntry in table.entries:
			if sum_bp + entry.chance_bp > BASIS_POINTS:
				return {"ok": false, "error": "probability_overflow"}
			sum_bp += entry.chance_bp
			entries.append(entry)

	# Luck is evaluated once per kill, not once per base attempt.
	var bonus_attempt: bool = rng.randi_range(0, BASIS_POINTS - 1) < luck_chance_bp
	var attempt_count: int = base_attempts + int(bonus_attempt)
	var outcomes: Array[Dictionary] = []
	for attempt: int in attempt_count:
		var number: int = rng.randi_range(0, BASIS_POINTS - 1)
		var cumulative: int = 0
		var chosen: LootEntry = null
		for entry: LootEntry in entries:
			cumulative += entry.chance_bp
			if number < cumulative:
				chosen = entry
				break
		# The unassigned probability remainder represents no ordinary item.
		if chosen == null:
			continue
		var amount: int = rng.randi_range(chosen.min_amount, chosen.max_amount)
		outcomes.append({"definition_id": chosen.item.definition_id, "amount": amount, "affixes": []})
	return {"ok": true, "items": outcomes, "attempts": attempt_count, "bonus_attempt": bonus_attempt, "pool_weight_bp": sum_bp}
