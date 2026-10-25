extends RefCounted
## Enrich already selected ordinary items once. Does not touch item-selection RNG.
const DEFAULT=preload("res://source/common/gameplay/loot/tables/natural_affix_profile.tres")
const Profile=preload("res://source/common/gameplay/loot/natural_affix_profile.gd")
static func resolve(items: Array, rng: RandomNumberGenerator, profile: Resource=DEFAULT) -> Dictionary:
	if not profile is Profile or not profile.valid() or rng==null: return {"ok":false,"error":"quality_profile"}
	var result: Array=[]
	for raw: Variant in items:
		if not raw is Dictionary or not raw.has_all(["definition_id","amount","affixes"]) or not raw.affixes is Array or not raw.affixes.is_empty(): return {"ok":false,"error":"pre_rolled"}
		if not (raw.definition_id is String or raw.definition_id is StringName) or not raw.amount is int: return {"ok":false,"error":"item"}
		var base:=ItemDefinitions.get_definition(StringName(raw.definition_id))
		if base==null: return {"ok":false,"error":"definition"}
		if raw.amount<1 or raw.amount>base.stack_limit: return {"ok":false,"error":"amount"}
		var item: Dictionary=raw.duplicate(true)
		if not base.affix_family.is_empty() and base.primary_action==ItemDefinition.PrimaryAction.EQUIP and base.stack_limit==1:
			if int(item.amount)!=1: return {"ok":false,"error":"amount"}
			var rolled: Dictionary=profile.roll(base,rng)
			if not rolled.ok: return rolled # No partial batch, fallback or second roll.
			item.affixes=rolled.affixes
		result.append(item)
	return {"ok":true,"items":result}
