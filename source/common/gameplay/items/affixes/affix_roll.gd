extends RefCounted
## Persist resolved effects. Reading old items never rerolls or resolves live tiers.
const VERSION: int=1
static func valid_stored(rolls: Array) -> bool:
	var counts: Dictionary={"prefix":0,"suffix":0}
	var groups: Dictionary={}
	var ids: Dictionary={}
	var versioned:=false
	var legacy:=false
	for value: Variant in rolls:
		if not value is Dictionary or not value.get("stat") is String or not (value.get("value") is int or value.get("value") is float) or not is_finite(float(value.value)): return false
		if not value.has("affix_version"):
			legacy=true;continue
		versioned=true
		if value.stat.is_empty(): return false
		if float(value.value)!=floor(float(value.value)) or absf(float(value.value))>1000000: return false
		if value.affix_version!=VERSION or not value.get("affix_id") is String or value.affix_id.is_empty() or not value.get("group") is String or value.group.is_empty() or value.get("kind","") not in counts: return false
		for key: String in ["tier","level"]:
			if not (value.get(key) is int or value.get(key) is float) or not is_finite(float(value[key])) or float(value[key])!=floor(float(value[key])) or value[key]<1 or value[key]>1000000: return false
		if groups.has(value.group) or ids.has(value.affix_id): return false
		groups[value.group]=true
		ids[value.affix_id]=true
		counts[value.kind]+=1
		if counts[value.kind]>3: return false
	# Legacy items remain untouched; mixing formats requires an explicit migration.
	return not (versioned and legacy)

static func canonical(rolls: Array) -> Array:
	var result: Array=rolls.duplicate(true)
	for r: Dictionary in result:
		if r.has("affix_version"):
			for key: String in ["affix_version","tier","level","value"]: r[key]=int(r[key])
	return result
