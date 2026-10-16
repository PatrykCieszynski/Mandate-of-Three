class_name MarketRequestRules
extends RefCounted
## Command/query shape and ranges only. No persistence or ownership decisions; shared by exported
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
static func valid_command(action: String, p: Dictionary) -> bool:
	if action == "open": return p.is_empty()
	if not p.get("command_id") is String or p.command_id.is_empty() or p.command_id.length()>96: return false
	var fields: Array
	match action:
		"order": return valid_order(p)
		"cancel_order": fields = ["command_id","order_id","revision"]
		"deposit": fields = ["command_id","uid","revision","amount","source"]
		"withdraw": fields = ["command_id","asset_id","amount","destination"]
		"list": fields = ["command_id","uid","revision","position","price"]
		"buy": fields = ["command_id","shop_id","offer_id","revision","price"]
		"edit": fields = ["command_id","offer_id","revision","position","price"]
		"cancel": fields = ["command_id","offer_id","revision"]
		"claim": fields = ["command_id","uid","revision"]
		"configure": fields = ["command_id","revision","name","status"]
		"receipt", "claim_revenue": fields = ["command_id"]
		_: return false
	if p.size()!=fields.size() or not p.has_all(fields): return false
	if p.has("order_id") and (not p.order_id is String or not ItemInstance.valid_uid(p.order_id)): return false
	if p.has("amount") and (not integer(p.amount,200) or p.amount<=0): return false
	if action=="deposit" and p.source not in ["bag","account_storage"]: return false
	if action=="withdraw" and (not p.asset_id is String or asset_definition(p.asset_id)==null or p.destination not in ["bag","claim"]): return false
	if p.has("shop_id") and (not integer(p.shop_id) or p.shop_id<=0): return false
	if p.has("uid") and (not p.uid is String or not ItemInstance.valid_uid(p.uid)): return false
	if p.has("offer_id") and (not p.offer_id is String or not ItemInstance.valid_uid(p.offer_id)): return false
	if p.has("revision") and not integer(p.revision): return false
	if p.has("position") and not integer(p.position,39): return false
	if p.has("price") and (not integer(p.price) or (p.price<=0 and action not in ["list","edit"])): return false
	if action=="configure" and (not p.name is String or p.name.length()>40 or p.name.strip_edges().is_empty() or p.status not in ["active","paused"]): return false
	return true

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
