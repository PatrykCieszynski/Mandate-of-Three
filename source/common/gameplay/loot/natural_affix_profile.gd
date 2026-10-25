extends Resource
## Item quality changes affix counts only, never item drop chance or tier eligibility.
const Generator=preload("res://source/common/gameplay/items/affixes/affix_generator.gd")
@export var pool: Array[Resource]=[]
## {quality:String, weight:int, prefixes:int, suffixes:int}
@export var bands: Array[Dictionary]=[]
func valid() -> bool:
	if not Generator.valid_pool(pool) or bands.is_empty() or bands.size()>32: return false
	var names: Dictionary={};var total:=0
	for band: Dictionary in bands:
		if band.size()!=4 or not band.get("quality") is String or band.quality.is_empty() or names.has(band.quality): return false
		for key: String in ["weight","prefixes","suffixes"]:
			if not band.get(key) is int: return false
		if band.weight<1 or band.weight>1000000 or band.prefixes<0 or band.prefixes>3 or band.suffixes<0 or band.suffixes>3: return false
		names[band.quality]=true;total+=band.weight
	return total<=1000000000

func roll(base: ItemDefinition, rng: RandomNumberGenerator) -> Dictionary:
	if not valid() or base==null or rng==null: return {"ok":false,"error":"quality_profile"}
	var total:=0
	for band: Dictionary in bands: total+=band.weight
	var draw: int=rng.randi_range(1,total)
	for band: Dictionary in bands:
		draw-=band.weight
		if draw>0: continue
		var result: Dictionary=Generator.generate(base,band.prefixes,band.suffixes,pool,rng)
		if result.ok: result.quality=band.quality
		return result
	return {"ok":false,"error":"quality_profile"}
