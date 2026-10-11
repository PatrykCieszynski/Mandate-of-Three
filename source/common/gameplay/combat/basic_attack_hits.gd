class_name BasicAttackHits
extends RefCounted
const COMBO: Array[AttackHitDefinition] = [
	preload("res://source/common/gameplay/combat/combo_hit_1.tres"),
	preload("res://source/common/gameplay/combat/combo_hit_2.tres"),
	preload("res://source/common/gameplay/combat/combo_hit_3.tres"),
	preload("res://source/common/gameplay/combat/combo_hit_4.tres"),
]
const MOB_MELEE: AttackHitDefinition = preload("res://source/common/gameplay/combat/mob_melee.tres")
static func stage(index: int) -> AttackHitDefinition:
	return COMBO[clampi(index,1,COMBO.size())-1]
