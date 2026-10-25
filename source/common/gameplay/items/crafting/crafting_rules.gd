extends RefCounted
## Pure server decision. Currency identity is content, never client-provided odds.
const Generator=preload("res://source/common/gameplay/items/affixes/affix_generator.gd")
const PROFILE=preload("res://source/common/gameplay/loot/tables/natural_affix_profile.tres")
const CURRENCIES: Dictionary={
	"change_spark":{"action":"transform","name":"Iskra Przemiany","effect":"Normal to Magic: rolls one or two affixes."},
	"renewal_dust":{"action":"renew","name":"Pył Odnowy","effect":"Magic: replaces all affixes with one or two new rolls."},
	"completion_shard":{"action":"complete","name":"Odłamek Dopełnienia","effect":"Magic with one affix: adds the missing prefix or suffix."}
}
static func resolve(item: ItemInstance, currency: String, rng: RandomNumberGenerator, pool: Array=PROFILE.pool) -> Dictionary:
	if item==null or rng==null or not CURRENCIES.has(currency): return {"ok":false,"error":"request"}
	var base:=ItemDefinitions.get_definition(item.definition_id)
	if base==null or base.affix_family.is_empty() or base.primary_action!=ItemDefinition.PrimaryAction.EQUIP or base.stack_limit!=1 or item.amount!=1: return {"ok":false,"error":"unsupported_item"}
	if not ItemInstance.valid_rarity(item.rarity,item.affixes) or not Generator.validate(item.affixes,base,pool): return {"ok":false,"error":"invalid_affixes"}
	var action: String=CURRENCIES[currency].action
	if (action=="transform" and item.rarity!="normal") or (action!="transform" and item.rarity!="magic"): return {"ok":false,"error":"rarity"}
	var rolled: Dictionary
	if action=="complete":
		if item.affixes.size()!=1: return {"ok":false,"error":"affix_capacity"}
		var prefix: bool=item.affixes[0].kind=="prefix"
		rolled=Generator.generate(base,0 if prefix else 1,1 if prefix else 0,pool,rng,item.affixes)
	else:
		# Provisional equal chance of prefix, suffix or both. No retries of RNG.
		var layout: int=rng.randi_range(0,2)
		rolled=Generator.generate(base,0 if layout==1 else 1,0 if layout==0 else 1,pool,rng)
	if rolled.ok: rolled.rarity="magic"
	return rolled
