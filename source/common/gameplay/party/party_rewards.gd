extends RefCounted
## World reward orchestration. Strategies return allocations; existing owners apply them.
const Exp = preload("res://source/common/gameplay/party/party_exp.gd")
const Drop = preload("res://source/common/gameplay/party/party_drop.gd")
var _resolver: WeakRef
var resolver: RefCounted:
	get: return _resolver.get_ref()
func _init(owner: RefCounted) -> void: _resolver=weakref(owner)
func contexts(claims: Dictionary, position: Vector3, shared: bool) -> Array:
	var service = resolver._services.party()
	if service==null: return []
	return service.contenders(claims,resolver._ground._world,position,resolver._services.startup_limits().value("party_reward_radius"),shared)
func handle_mob(result: MobDeathResult) -> bool:
	if result.party_claims.is_empty(): return false
	var shared: bool=result.rank==&"boss"
	var has_party: bool=false
	for claim: Dictionary in result.party_claims.values(): has_party=has_party or int(claim.party)>0
	if not has_party and not shared: return false # Preserve unchanged solo policy/fixtures.
	var competitors: Array=contexts(result.party_claims,result.position,shared)
	if competitors.is_empty(): return true
	var items: Array=[]
	if resolver._region_key.is_empty():
		items=[{"definition_id":ItemDefinitions.IRON_SWORD.definition_id,"amount":1,"affixes":[{"stat":"attack","value":resolver._rng.randi_range(1,9)}]}]
	else:
		var owner: int=Drop.choose(competitors[0].eligible,"by_damage",competitors[0].by_id,0).owner
		var luck: int=clampi(int(resolver._services.runtime_stats(owner).get(&"loot_luck_bp",0)),0,LootResolver.BASIS_POINTS)
		var outcome: Dictionary=resolver.resolve_ordinary(result,luck)
		if outcome.ok: items=outcome.items
		else: push_error("Invalid party loot content: "+str(outcome.error))
	items.append_array(resolver.event_drops.resolve_drops())
	distribute(competitors,result.position,result.timestamp_ms,result.experience_reward,CurrencyEndpoint3D.DOG_YANG,items)
	return true
func encounter(claims: Dictionary, position: Vector3, now: int, yang: int) -> void:
	var competitors: Array=contexts(claims,position,true)
	if competitors.is_empty(): return
	# Exactly the existing one-sword pool; no extra guaranteed item per competitor.
	var items: Array=[{"definition_id":ItemDefinitions.IRON_SWORD.definition_id,"amount":1,"affixes":[{"stat":"attack","value":resolver._rng.randi_range(1,9)}]}]
	distribute(competitors,position,now,0,yang,items)
func distribute(competitors: Array, position: Vector3, now: int, experience: int, yang: int, items: Array) -> void:
	var weights: Dictionary={}
	for c: Dictionary in competitors: weights[c.key]=int(c.damage)
	var xp_pools: Dictionary=Exp.weighted(experience,weights)
	var yang_pools: Dictionary=Exp.weighted(yang,weights)
	for c: Dictionary in competitors:
		var xp: Dictionary=Exp.split(int(xp_pools[c.key]),c.eligible,c.xp_mode)
		var coins: Dictionary=Exp.split(int(yang_pools[c.key]),c.eligible)
		for member: Dictionary in c.eligible:
			var owner: int=member.id
			var player = resolver._services.current_player(owner)
			if int(xp.get(owner,0))>0 and player!=null and resolver._services.progression()!=null:
				resolver._services.progression().award_experience(player,int(xp[owner]))
			if int(coins.get(owner,0))>0:
				resolver._currency.spawn_currency(position,owner,resolver._ground.owner_name_for_owner(owner),now,int(coins[owner]))
	for item: Dictionary in items:
		# Damage-weighted World RNG chooses one competitor from the qualified pool.
		var roll: int=resolver._rng.randi_range(1,_total_damage(competitors))
		var selected: Dictionary=competitors[0]
		for c: Dictionary in competitors:
			roll-=int(c.damage)
			if roll<=0: selected=c;break
		var service = resolver._services.party()
		var party: Dictionary=service.parties.get(int(selected.party),{})
		var decision: Dictionary=Drop.choose(selected.eligible,selected.drop_mode,selected.by_id,int(party.get("cursor",0)))
		if decision.is_empty(): continue
		var owner: int=decision.owner
		var uid: String=resolver._ground.spawn_resolved_item(position,owner,resolver._ground.owner_name_for_owner(owner),now,StringName(item.definition_id),int(item.amount),item.affixes)
		if uid.is_empty(): continue
		resolver._ground.protect_party_item(uid,decision,int(selected.party))
		if decision.advance and not party.is_empty(): party.cursor+=1
func _total_damage(competitors: Array) -> int:
	var total: int=0
	for c: Dictionary in competitors: total+=int(c.damage)
	return total
