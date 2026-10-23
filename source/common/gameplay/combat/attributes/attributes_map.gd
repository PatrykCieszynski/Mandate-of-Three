class_name AttributeMap
## A profile is a narrow coefficient matrix: stat -> {attribute: weight}.
## Skills can evaluate their own STR/DEX/VIT/INT weights through weighted().
const KEYS: Array[StringName] = [&"STR",&"DEX",&"VIT",&"INT"]
const WARRIOR: Dictionary = {
	Stat.AD: {&"STR":1.0,&"DEX":0.25},
	Stat.ATTACK_SPEED: {&"DEX":0.1},
	Stat.HEALTH_MAX: {&"VIT":10.0},
	Stat.ARMOR: {&"VIT":0.25},
	Stat.MANA_MAX: {&"INT":5.0},
	Stat.MANA_REGEN: {&"INT":0.05},
}
static func weighted(attributes: Dictionary, weights: Dictionary) -> float:
	var result: float = 0
	for key: StringName in KEYS: result += float(attributes.get(key,0))*float(weights.get(key,0))
	return result
static func attr_to_stats(attributes: Dictionary[StringName,int], profile: Dictionary = WARRIOR) -> Dictionary[StringName,float]:
	var result: Dictionary[StringName,float] = {}
	for stat: StringName in profile: result[stat] = weighted(attributes,profile[stat])
	return result
