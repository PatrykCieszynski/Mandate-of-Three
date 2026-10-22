extends RefCounted
## Pure allocation. Largest remainders, then persistent character ID; no lost XP/Yang.
const MODES = ["equal", "by_level", "carry"]
const CARRY_STRENGTH: int = 3 # At a 15-level gap the lower player has 4x weight.
static func split(pool: int, members: Array, mode: String = "equal") -> Dictionary:
	var weights: Dictionary = {}
	var highest: int = 1
	for member: Dictionary in members: highest = maxi(highest, int(member.level))
	for member: Dictionary in members:
		var level: int = maxi(1, int(member.level))
		weights[int(member.id)] = level if mode == "by_level" else 15 + CARRY_STRENGTH * maxi(0, highest-level) if mode == "carry" else 1
	return weighted(pool, weights)
static func weighted(pool: int, weights: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var total: int = 0
	for id: Variant in weights: total += int(weights[id])
	if pool < 0 or total <= 0: return result
	var remainder: Array = []
	var allocated: int = 0
	for id: Variant in weights:
		var numerator: int = pool * int(weights[id])
		@warning_ignore("integer_division")
		var share: int = numerator / total
		result[id] = share
		allocated += share
		remainder.append({"id":id,"rest":numerator % total})
	remainder.sort_custom(func(a: Dictionary,b: Dictionary)->bool: return a.rest>b.rest if a.rest!=b.rest else a.id<b.id)
	for i: int in pool-allocated: result[remainder[i].id] += 1
	return result
