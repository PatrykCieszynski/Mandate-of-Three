extends RefCounted
## Pure item rights decision. Caller advances cursor ONLY after a successful spawn.
const MODES = ["round_robin", "by_damage", "free"]
static func choose(members: Array, mode: String, damage: Dictionary, cursor: int) -> Dictionary:
	var ids: Array = []
	for member: Dictionary in members: ids.append(int(member.id))
	ids.sort()
	if ids.is_empty(): return {}
	if mode == "free": return {"owner":0,"allowed":ids,"advance":false}
	var owner: int = ids[posmod(cursor,ids.size())]
	if mode == "by_damage":
		owner = ids[0]
		for id: int in ids:
			if int(damage.get(id,0))>int(damage.get(owner,0)): owner=id
	return {"owner":owner,"allowed":[owner],"advance":mode=="round_robin"}
