class_name MarketRequestRules
extends RefCounted
## Wire shape/ranges only. No persistence or ownership decisions; shared by exported
## clients and World, so client validation never calls a server-only export stub.
const MAX_YANG := 9000000000000000
const MAX_RATIO_UNIT := 1000000000
const STATS := ItemAffixLabels.STATS
static func integer(value: Variant,maximum: int=MAX_YANG) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and value>=0 and value<=maximum and float(value)==floor(float(value))
static func asset_definition(asset: String) -> ItemDefinition:
	var definition:=ItemDefinitions.get_definition(StringName(asset))
	return definition if definition!=null and definition.tradeable and definition.market_fungible and definition.stack_limit>1 else null
static func gcd(a: int,b: int) -> int:
	while b!=0:
		var remainder:=a%b;a=b;b=remainder
	return a
static func valid_order(p: Dictionary) -> bool:
	if p.size()!=6 or not p.has_all(["command_id","have_asset","want_asset","quantity","price_num","price_den"]): return false
	if not p.have_asset is String or not p.want_asset is String or p.have_asset==p.want_asset: return false
	if not ((p.have_asset=="yang" and asset_definition(p.want_asset)!=null) or (p.want_asset=="yang" and asset_definition(p.have_asset)!=null)): return false
	for key: String in ["quantity","price_num","price_den"]:
		if not integer(p[key],MAX_YANG if key=="quantity" else MAX_RATIO_UNIT) or p[key]<=0: return false
	var numerator:=int(p.price_num);var denominator:=int(p.price_den);var divisor:=gcd(numerator,denominator)
	numerator/=divisor;denominator/=divisor
	return int(p.quantity)%denominator==0 and int(p.quantity)/denominator<=MAX_YANG/numerator
static func valid_search(p: Dictionary) -> bool:
	var keys: Array=["definition_id","upgrade_min","upgrade_max","price_min","price_max","affix_filters","sort","cursor","limit"]
	if p.size()!=keys.size() or not p.has_all(keys): return false
	if not p.definition_id is String or ItemDefinitions.get_definition(StringName(p.definition_id))==null: return false
	if not integer(p.upgrade_min,9) or not integer(p.upgrade_max,9) or p.upgrade_min>p.upgrade_max: return false
	if not integer(p.price_min) or not integer(p.price_max) or p.price_min>p.price_max: return false
	if not integer(p.limit,50) or p.limit<1 or p.sort not in ["price_asc","price_desc"] or not p.cursor is String or p.cursor.length()>64: return false
	if not p.affix_filters is Array or p.affix_filters.size()>4: return false
	var seen: Array=[]
	for filter: Variant in p.affix_filters:
		if not filter is Dictionary or filter.size()!=2 or not filter.has_all(["stat_id","minimum"]) or not filter.stat_id is String or not STATS.has(filter.stat_id) or filter.stat_id in seen: return false
		var stat: Dictionary=STATS[filter.stat_id]
		if not (filter.minimum is int or filter.minimum is float) or not is_finite(float(filter.minimum)) or filter.minimum<stat.min or filter.minimum>stat.max: return false
		seen.append(filter.stat_id)
	return true
