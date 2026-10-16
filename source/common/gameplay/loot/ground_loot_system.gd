class_name GroundLootSystem
extends RefCounted
## Live ground-item custody, owner rights and pickup; no RNG or mob-specific drop policy.
## World resolves items before spawn; SQL commits each prepared UID only once.
const PICKUP_REACH: float = 2.5
const PROTECTION_MS: int = 15000
const LOOT_LIFETIME_MS: int = 120000
const MAX_AFFIXES: int = 6
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

## Temporary adapter for the old prototype sword/attack-roll caller.
## Remove only when KillRewardResolver switches to fully resolved loot.
func spawn_item(position: Vector3, owner_id: int, owner_name: String, now: int, definition_id: StringName, bonus: int) -> String:
	if bonus < 1 or bonus > 9:
		return ""
	return spawn_resolved_item(position, owner_id, owner_name, now, definition_id, 1, [{"stat": "attack", "value": bonus}])

## One already-rolled item outcome -> one immutable ground UID. Materials and stacks work.
## The caller never supplies a persistent item instance or arbitrary DB values.
func spawn_resolved_item(position: Vector3, owner_id: int, owner_name: String, now: int, definition_id: StringName, amount: int, affixes: Array) -> String:
	var definition := ItemDefinitions.get_definition(definition_id)
	if definition == null or not position.is_finite() or owner_id < 0 or now < 0:
		return ""
	if amount < 1 or amount > definition.stack_limit or not valid_affixes(definition, affixes):
		return ""
	var uid: String = Crypto.new().generate_random_bytes(16).hex_encode()
	drops[uid] = {"position": position, "definition_id": str(definition.definition_id),
		"amount": amount, "affixes": affixes.duplicate(true),
		"owner": owner_id, "owner_name": owner_name,
		"protected_until": now + PROTECTION_MS, "expires": now + LOOT_LIFETIME_MS}
	return uid

static func valid_affixes(definition: ItemDefinition, affixes: Array) -> bool:
	if affixes.size() > MAX_AFFIXES:
		return false
	for value: Variant in affixes:
		if not value is Dictionary:
			return false
		var roll: Dictionary = value
		if not roll.has_all(["stat", "value"]):
			return false
		if not roll.stat is String and not roll.stat is StringName:
			return false
		var stat := StringName(str(roll.stat))
		if not definition.base_stats.has(stat):
			return false
		if not roll.value is int and not roll.value is float:
			return false
		if not is_finite(float(roll.value)) or absf(float(roll.value)) > 100000.0:
			return false
	return true

## Reconstruct the SAME frozen contents/UID on pickup retries. Only ownership changes.
static func prepare_claim_item(uid: String, owner_id: int, drop: Dictionary) -> ItemInstance:
	if owner_id <= 0 or not ItemInstance.valid_uid(uid):
		return null
	var definition := ItemDefinitions.get_definition(StringName(drop.get("definition_id", "")))
	if definition == null:
		return null
	var amount: int = int(drop.get("amount", 0))
	var affixes: Variant = drop.get("affixes", null)
	if amount < 1 or amount > definition.stack_limit or not affixes is Array:
		return null
	if not valid_affixes(definition, affixes):
		return null
	var item := ItemInstance.create(definition, owner_id, affixes)
	item.uid = uid
	item.amount = amount
	return item

static func attack_for_drop(definition: ItemDefinition, drop: Dictionary) -> int:
	var attack: int = int(definition.base_stats.get(&"attack", 0))
	for roll: Dictionary in drop.affixes:
		if StringName(str(roll.stat)) == &"attack":
			attack += int(roll.value)
	return attack

func expire(now: int) -> void:
	for uid: String in drops.keys():
		if now >= int(drops[uid].expires):
			drops.erase(uid)

func snapshot_for_peer(peer_id: int, now: int) -> Dictionary:
	var snapshot: Dictionary = {}
	for uid: String in drops:
		var drop: Dictionary = drops[uid]
		var definition := ItemDefinitions.get_definition(StringName(drop.definition_id))
		if definition == null:
			continue
		snapshot[uid] = {"position": drop.position, "definition_id": drop.definition_id,
			"item_name": definition.item_name, "amount": int(drop.amount),
			"weapon_attack": attack_for_drop(definition, drop),
			"reserved_for": drop.owner_name if now < int(drop.protected_until) else "",
			"allowed": now >= int(drop.protected_until) or _services.owner_id_for_peer(peer_id) == int(drop.owner)}
	return snapshot

func pickup_for_peer(peer_id: int, uid: String, now: int) -> Dictionary:
	if not _services.mutations_allowed(peer_id):
		return {"ok": false, "error": "transfer_pending"}

	if not _world.combat_endpoint.is_player_alive(peer_id) or _services.item_store() == null:
		return {"ok": false, "error": "player"}

	if not ItemInstance.valid_uid(uid) or not drops.has(uid):
		return {"ok": false, "error": "gone"}

	var drop: Dictionary = drops[uid]
	if now >= int(drop.expires):
		drops.erase(uid)
		return {"ok": false, "error": "gone"}
	var owner_id: int = _services.owner_id_for_peer(peer_id)
	if now < int(drop.protected_until) and owner_id != int(drop.owner):
		return {"ok": false, "error": "reserved"}
	var body: Node3D = _world.characters[peer_id]
	if body.position.distance_to(drop.position) > PICKUP_REACH or not _world.has_line_of_sight(body.position, drop.position):
		return {"ok": false, "error": "distance"}
	var item := prepare_claim_item(uid, owner_id, drop)
	if item == null:
		return {"ok": false, "error": "request"}
	var operation := _services.economy().claim_ground_item_operation(owner_id, uid, item)
	var result: Dictionary = operation.response()
	if result.ok or result.get("error", "") == "claimed":
		drops.erase(uid)
	if operation.new_commit:
		var definition := ItemDefinitions.get_definition(item.definition_id)
		result["item_name"] = definition.item_name
		result["amount"] = item.amount
		result["weapon_attack"] = attack_for_drop(definition, drop)
		# A committed UID/placement precedes cache refresh and all publication.
		_world.inventory_endpoint.accept_committed_change(peer_id)
	return result
