class_name GroundLootSystem
extends RefCounted
## Live item drops and claim orchestration. Currency keeps its existing endpoint.
## Current spike policy: weapon + attack roll (1..9), not a generic item payload.
## Generalize at the first real non-weapon ground drop; SQL already accepts items.
const PICKUP_REACH: float = 2.5
const PROTECTION_MS: int = 15000
const LOOT_LIFETIME_MS: int = 120000
var drops: Dictionary[String, Dictionary] = {}
var _world: Node3D
var _services: MandateWorldServices

func setup(world: Node3D, services: MandateWorldServices) -> void:
	_world = world
	_services = services

func owner_name_for_owner(owner_id: int) -> String:
	for peer_id: int in _world.characters:
		if _services.owner_id_for_peer(peer_id)==owner_id:
			return _services.player_for_peer(peer_id).display_name
	return ""

func spawn_item(position: Vector3, owner_id: int, owner_name: String, now: int, definition_id: StringName, bonus: int) -> String:
	var uid: String = Crypto.new().generate_random_bytes(16).hex_encode()
	drops[uid] = {"position":position,"definition_id":str(definition_id),"bonus":bonus,
		"owner":owner_id,"owner_name":owner_name,"protected_until":now+PROTECTION_MS,"expires":now+LOOT_LIFETIME_MS}
	return uid

func expire(now: int) -> void:
	for uid: String in drops.keys():
		if now >= int(drops[uid].expires): drops.erase(uid)

func snapshot_for_peer(peer_id: int, now: int) -> Dictionary:
	var snapshot: Dictionary = {}
	for uid: String in drops:
		var drop: Dictionary = drops[uid]
		var definition: ItemDefinition = ItemDefinitions.get_definition(StringName(drop.definition_id))
		snapshot[uid] = {"position":drop.position,"definition_id":drop.definition_id,
			"item_name":definition.item_name,"weapon_attack":int(definition.base_stats.get(&"attack",0))+int(drop.bonus),
			"reserved_for":drop.owner_name if now<int(drop.protected_until) else "",
			"allowed":now>=int(drop.protected_until) or _services.owner_id_for_peer(peer_id)==int(drop.owner)}
	return snapshot

func pickup_for_peer(peer_id: int, uid: String, now: int) -> Dictionary:
	if not _world.combat_endpoint.is_player_alive(peer_id) or _services.item_store()==null:
		return {"ok":false,"error":"player"}
	if not ItemInstance.valid_uid(uid) or not drops.has(uid): return {"ok":false,"error":"gone"}
	var drop: Dictionary = drops[uid]
	if now >= int(drop.expires):
		drops.erase(uid)
		return {"ok":false,"error":"gone"}
	var owner_id := _services.owner_id_for_peer(peer_id)
	if now<int(drop.protected_until) and owner_id!=int(drop.owner): return {"ok":false,"error":"reserved"}
	var body: Node3D = _world.characters[peer_id]
	if body.position.distance_to(drop.position)>PICKUP_REACH or not _world.has_line_of_sight(body.position,drop.position):
		return {"ok":false,"error":"distance"}
	var definition: ItemDefinition = ItemDefinitions.get_definition(StringName(drop.definition_id))
	var bonus: int = int(drop.bonus)
	if definition==null or bonus<1 or bonus>9: return {"ok":false,"error":"request"}
	var item := ItemInstance.create(definition,owner_id,[{"stat":"attack","value":bonus}])
	item.uid = uid
	var result: Dictionary = _services.item_store().claim_ground_item(owner_id,uid,item)
	if result.ok or result.get("error","")=="claimed": drops.erase(uid)
	if result.ok:
		result["item_name"] = definition.item_name
		result["weapon_attack"] = int(definition.base_stats.get(&"attack",0))+bonus
		# Commit and ground erase precede cache and notification/publication.
		_world.inventory_endpoint.accept_committed_change(peer_id)
	return result
