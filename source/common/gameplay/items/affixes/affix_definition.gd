extends Resource
## Authored rule, not a live item roll. Tier weights are selection weights.
@export var affix_id: StringName
@export_enum("prefix", "suffix") var kind: String = "prefix"
@export var group: StringName
@export var excludes: Array[StringName] = []
@export var families: Array[StringName] = []
@export var slots: Array[StringName] = []
@export var stat: StringName
## Each tier: {tier:int, min_level:int, weight:int, min_value:int, max_value:int}.
@export var tiers: Array[Dictionary] = []

func valid() -> bool:
	if affix_id.is_empty() or group.is_empty() or stat not in [&"attack", &"attack_speed"] or kind not in ["prefix","suffix"] or families.is_empty() or slots.is_empty() or tiers.is_empty() or tiers.size()>32: return false
	if excludes.has(group) or families.has(&"") or slots.has(&""): return false
	var seen: Dictionary={}
	for t: Dictionary in tiers:
		if t.size()!=5 or not t.has_all(["tier","min_level","weight","min_value","max_value"]): return false
		for key: String in t:
			if not t[key] is int: return false
		if t.tier<1 or t.tier>1000000 or seen.has(t.tier) or t.min_level<1 or t.min_level>1000000 or t.weight<1 or t.weight>1000000 or t.min_value<0 or t.max_value<t.min_value or t.max_value>1000000: return false
		seen[t.tier]=true
	return true

func eligible(base: ItemDefinition, level: int) -> bool:
	return base!=null and base.affix_family in families and base.equipment_slot in slots and level>=1 and base.primary_action==ItemDefinition.PrimaryAction.EQUIP and base.stack_limit==1
