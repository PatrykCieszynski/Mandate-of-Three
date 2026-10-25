extends RefCounted
## Pure shared loot/crafting decision. No item mutation, SQL, RPC or global RNG.
const Roll=preload("res://source/common/gameplay/items/affixes/affix_roll.gd")
const Definition=preload("res://source/common/gameplay/items/affixes/affix_definition.gd")
static func valid_pool(pool: Array) -> bool:
	if pool.is_empty() or pool.size()>256: return false
	var ids: Dictionary={}
	var weight: int=0
	for d: Variant in pool:
		if not d is Definition or not d.valid() or ids.has(d.affix_id): return false
		ids[d.affix_id]=true
		for tier: Dictionary in d.tiers: weight+=tier.weight
		if weight>1000000000: return false # Bound integer RNG range even for malformed content.
	var groups: Dictionary={"prefix":{},"suffix":{}}
	for d: Resource in pool: groups[d.kind][d.group]=true
	for d: Resource in pool:
		for excluded: StringName in d.excludes:
			if not groups[d.kind].has(excluded): return false
	return true

static func compatible(d: Resource, selected: Array, pool: Array) -> bool:
	for roll: Dictionary in selected:
		if d.kind!=roll.kind: continue
		if d.group==StringName(roll.group) or StringName(roll.group) in d.excludes: return false
		for existing: Resource in pool:
			if existing.kind==d.kind and str(existing.affix_id)==roll.affix_id and d.group in existing.excludes: return false
	return true

static func generate(base: ItemDefinition, prefixes: int, suffixes: int, pool: Array, rng: RandomNumberGenerator) -> Dictionary:
	if base==null or base.affix_level<1 or base.affix_level>1000000 or rng==null or prefixes<0 or prefixes>3 or suffixes<0 or suffixes>3 or not valid_pool(pool): return {"ok":false,"error":"request"}
	var result: Array=[]
	# Authoring order does not change seeded results.
	var sorted: Array=pool.duplicate()
	sorted.sort_custom(func(a: Resource,b: Resource)->bool:return str(a.affix_id)<str(b.affix_id))
	for kind: String in ["prefix","suffix"]:
		for _index: int in (prefixes if kind=="prefix" else suffixes):
			var candidates: Array=[]
			var total: int=0
			for d: Resource in sorted:
				if d.kind!=kind or not d.eligible(base,base.affix_level) or not base.base_stats.has(d.stat) or not compatible(d,result,sorted): continue
				var tiers: Array=d.tiers.duplicate()
				tiers.sort_custom(func(a: Dictionary,b: Dictionary)->bool:return a.tier<b.tier)
				for t: Dictionary in tiers:
					if t.min_level<=base.affix_level:
						candidates.append({"definition":d,"tier":t});total+=t.weight
			if candidates.is_empty(): return {"ok":false,"error":"insufficient_pool"}
			var draw: int=rng.randi_range(1,total)
			for choice: Dictionary in candidates:
				draw-=choice.tier.weight
				if draw>0: continue
				var d: Resource=choice.definition
				var t: Dictionary=choice.tier
				result.append({"affix_version":Roll.VERSION,"affix_id":str(d.affix_id),"kind":d.kind,"group":str(d.group),"tier":t.tier,"level":base.affix_level,"stat":str(d.stat),"value":rng.randi_range(t.min_value,t.max_value)})
				break
	return {"ok":true,"affixes":result}

static func validate(rolls: Array, base: ItemDefinition, pool: Array) -> bool:
	if base==null or base.affix_level<1 or base.affix_level>1000000 or not valid_pool(pool) or not Roll.valid_stored(rolls): return false
	var selected: Array=[]
	for r: Dictionary in rolls:
		if not r.has("affix_version") or r.level!=base.affix_level: return false
		var matches: Array=pool.filter(func(d: Resource)->bool:return str(d.affix_id)==r.affix_id)
		if matches.size()!=1: return false
		var d: Resource=matches[0]
		if not d.eligible(base,base.affix_level) or not base.base_stats.has(d.stat) or d.kind!=r.kind or str(d.group)!=r.group or str(d.stat)!=r.stat or not compatible(d,selected,pool): return false
		var legal:=false
		for t: Dictionary in d.tiers:
			if t.tier==r.tier and t.min_level<=r.level and r.value>=t.min_value and r.value<=t.max_value and float(r.value)==floor(float(r.value)): legal=true
		if not legal: return false
		selected.append(r)
	return true
