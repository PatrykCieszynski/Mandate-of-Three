extends RefCounted
## Pure server decision. Currency identity is content, never client-provided odds.
const Generator=preload("res://source/common/gameplay/items/affixes/affix_generator.gd")
const PROFILE=preload("res://source/common/gameplay/loot/tables/natural_affix_profile.tres")
const CURRENCIES: Dictionary={
	"change_spark":{"action":"transform","name":"Iskra Przemiany","effect":"Normal to Magic: rolls one or two affixes."},
	"renewal_dust":{"action":"renew","name":"Pył Odnowy","effect":"Magic: replaces all affixes with one or two new rolls."},
	"completion_shard":{"action":"complete","name":"Odłamek Dopełnienia","effect":"Magic with one affix: adds the missing prefix or suffix."},
	"ascension_ember":{"action":"rarefy","name":"Żar Wyniesienia","effect":"Normal to Rare: rolls four to six affixes."},
	"renewal_prism":{"action":"reforge","name":"Pryzmat Odnowy","effect":"Rare: replaces all affixes with four to six new rolls."},
	"awakening_seal":{"action":"awaken","name":"Pieczęć Przebudzenia","effect":"Magic to Rare: preserves all existing affixes and adds exactly one new roll."},
	"cleansing_salt":{"action":"cleanse","name":"Sól Oczyszczenia","effect":"Magic or Rare to Normal: removes all affixes, preserving upgrades and sockets."}
}
static func resolve(item: ItemInstance, currency: String, rng: RandomNumberGenerator, pool: Array=PROFILE.pool) -> Dictionary:
	if item==null or rng==null or not CURRENCIES.has(currency): return {"ok":false,"error":"request"}
	var base:=ItemDefinitions.get_definition(item.definition_id)
	if base==null or base.affix_family.is_empty() or base.primary_action!=ItemDefinition.PrimaryAction.EQUIP or base.stack_limit!=1 or item.amount!=1: return {"ok":false,"error":"unsupported_item"}
	if not ItemInstance.valid_rarity(item.rarity,item.affixes) or not Generator.validate(item.affixes,base,pool): return {"ok":false,"error":"invalid_affixes"}
	var action: String=CURRENCIES[currency].action
	if action=="cleanse":
		if item.rarity not in ["magic","rare"]: return {"ok":false,"error":"rarity"}
		if item.affixes.is_empty(): return {"ok":false,"error":"affix_capacity"}
		return {"ok":true,"rarity":"normal","affixes":[]}
	var required: String="normal" if action in ["transform","rarefy"] else ("rare" if action=="reforge" else "magic")
	if item.rarity!=required: return {"ok":false,"error":"rarity"}
	var rolled: Dictionary
	if action in ["rarefy","reforge"]:
		# Provisional alpha balance: equal chance of 4/5/6 affixes, then equal
		# chance of each legal split. Never reroll a failed/insufficient pool.
		var count: int=rng.randi_range(4,6)
		var prefixes: int=rng.randi_range(maxi(1,count-3),mini(3,count-1))
		rolled=Generator.generate(base,prefixes,count-prefixes,pool,rng)
	elif action=="awaken":
		# Retained rolls participate in the same kind-local conflict checks.
		# Pick once; an exhausted chosen kind fails without fallback or consumption.
		var prefix: bool=rng.randi_range(0,1)==0
		rolled=Generator.generate(base,1 if prefix else 0,0 if prefix else 1,pool,rng,item.affixes)
	elif action=="complete":
		if item.affixes.size()!=1: return {"ok":false,"error":"affix_capacity"}
		var prefix: bool=item.affixes[0].kind=="prefix"
		rolled=Generator.generate(base,0 if prefix else 1,1 if prefix else 0,pool,rng,item.affixes)
	else:
		# Provisional equal chance of prefix, suffix or both. No retries of RNG.
		var layout: int=rng.randi_range(0,2)
		rolled=Generator.generate(base,0 if layout==1 else 1,0 if layout==0 else 1,pool,rng)
	if rolled.ok: rolled.rarity="rare" if action in ["rarefy","reforge","awaken"] else "magic"
	return rolled
