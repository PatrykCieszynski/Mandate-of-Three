extends RefCounted
const MAX_ITEMS: int=8
const MAX_YANG: int=9000000000000000
static func valid(p: Dictionary) -> bool:
	if var_to_bytes(p).size()>4096 or not p.get("action") is String: return false
	if p.action=="invite": return p.size()==2 and p.get("target") is int and p.target>0
	if p.action not in ["join","cancel","offer","confirm","recover"] or not p.get("trade_id") is String or not p.trade_id.begins_with("trade-") or not ItemInstance.valid_uid(p.trade_id.trim_prefix("trade-")): return false
	if p.action in ["join","cancel","recover"]: return p.size()==2
	if not p.get("version") is int or p.version<1: return false
	if p.action=="confirm": return p.size()==3
	if p.size()!=5 or not p.get("items") is Array or p.items.size()>MAX_ITEMS or not p.get("yang") is String or not p.yang.is_valid_int() or p.yang.length()>16 or int(p.yang)<0 or int(p.yang)>MAX_YANG: return false
	var seen: Dictionary={}
	for line: Variant in p.items:
		if not line is Dictionary or line.size()!=2 or not line.get("uid") is String or not ItemInstance.valid_uid(line.uid) or not line.get("revision") is String or not line.revision.is_valid_int() or line.revision.length()>18 or int(line.revision)<0 or seen.has(line.uid): return false
		seen[line.uid]=true
	return true
