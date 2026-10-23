class_name VendorResolver
extends RefCounted
## No SQL, RPC, random draws or item mutations. Priority desc, recipe ID asc,
## requirement specificity desc, UID asc make drag order irrelevant.
const MAX_LINES: int = 32
const MAX_UNITS: int = 1000
const MAX_YANG: int = 9000000000000000

static func cart(values: Variant) -> Array:
	if not values is Array or values.is_empty() or values.size()>MAX_LINES: return []
	var seen: Dictionary={}
	var result: Array=[]
	var units: int=0
	for entry: Variant in values:
		if not entry is Dictionary or entry.size()!=3 or not entry.has_all(["uid","revision","amount"]): return []
		if not entry.uid is String or not ItemInstance.valid_uid(entry.uid) or seen.has(entry.uid): return []
		if not entry.revision is int or entry.revision<0 or not entry.amount is int or entry.amount<1 or entry.amount>200: return []
		units+=entry.amount
		if units>MAX_UNITS: return []
		seen[entry.uid]=true
		result.append(entry.duplicate())
	result.sort_custom(func(a: Dictionary,b: Dictionary)->bool:return a.uid<b.uid)
	return result

static func resolve(selection: Array, inventory: Array, recipes: Array, pools: Dictionary) -> Dictionary:
	var lines:=cart(selection)
	if lines.is_empty(): return {"ok":false,"error":"request"}
	var available: Dictionary={}
	for item: Dictionary in inventory: available[str(item.uid)]=item
	var remaining: Dictionary={}
	var metadata: Dictionary={}
	for line: Dictionary in lines:
		var item: Dictionary=available.get(line.uid,{})
		if item.is_empty() or item.get("location","")!="bag": return {"ok":false,"error":"owner"}
		if item.revision!=line.revision: return {"ok":false,"error":"stale"}
		if item.amount<line.amount: return {"ok":false,"error":"amount"}
		var definition:=ItemDefinitions.get_definition(StringName(item.definition_id))
		if definition==null or definition.vendor_price<0 or definition.vendor_price>MAX_YANG or item.get("locked",false): return {"ok":false,"error":"unsellable"}
		remaining[line.uid]=line.amount
		metadata[line.uid]=definition
	var ordered:=recipes.duplicate()
	ordered.sort_custom(func(a: VendorRecipeDefinition,b: VendorRecipeDefinition)->bool:return a.priority>b.priority if a.priority!=b.priority else a.recipe_id<b.recipe_id)
	var rewards: Array=[]
	var used: Dictionary={}
	for recipe: VendorRecipeDefinition in ordered:
		if recipe.inputs.is_empty() or recipe.reward_quantity<1 or recipe.reward_quantity>MAX_LINES or not pools.has(str(recipe.reward_pool)): return {"ok":false,"error":"invalid_definition"}
		var requirements:=recipe.inputs.duplicate(true)
		for requirement: Dictionary in requirements:
			if not requirement.get("quantity") is int or requirement.quantity<1 or requirement.quantity>MAX_UNITS: return {"ok":false,"error":"invalid_definition"}
			if requirement.size()!=2 or not (requirement.has("definition_id") or requirement.has("tag") or requirement.has("category")): return {"ok":false,"error":"invalid_definition"}
		requirements.sort_custom(func(a: Dictionary,b: Dictionary)->bool:return _specificity(a)>_specificity(b))
		var count: int=0
		while true:
			var next:=remaining.duplicate()
			var matched:=true
			for requirement: Dictionary in requirements:
				var needed: int=requirement.quantity
				for uid: String in next:
					if not _matches(metadata[uid],requirement): continue
					var take:=mini(needed,int(next[uid]))
					next[uid]-=take;needed-=take
					if needed==0: break
				if needed>0: matched=false;break
			if not matched: break
			remaining=next;count+=1
		if count>0:
			if count*recipe.reward_quantity>MAX_UNITS: return {"ok":false,"error":"invalid_definition"}
			used[str(recipe.recipe_id)]=count
			rewards.append({"type":"random_pool","pool":str(recipe.reward_pool),"quantity":count*recipe.reward_quantity,"icon_id":str(pools[str(recipe.reward_pool)].icon_id)})
	var yang: int=0
	for uid: String in remaining:
		var price: int=metadata[uid].vendor_price
		if remaining[uid]>0 and price>(MAX_YANG-yang)/int(remaining[uid]): return {"ok":false,"error":"overflow"}
		yang+=price*int(remaining[uid])
	return {"ok":true,"yang":yang,"rewards":rewards,"recipes":used}

static func _specificity(value: Dictionary) -> int:
	return 3 if value.has("definition_id") else (2 if value.has("tag") else 1)

static func _matches(item: ItemDefinition, requirement: Dictionary) -> bool:
	if requirement.has("definition_id"): return str(item.definition_id)==requirement.definition_id
	if requirement.has("tag"): return StringName(requirement.tag) in item.recipe_tags
	return str(item.recipe_category)==requirement.category
