class_name HornTaunt
extends RefCounted
## Server-owned horn tiers and cooldown. Target selection remains in MobSystem.
const RANGE_METERS: float = 12.0
const COOLDOWN_MS: int = 4000
const BASIC: StringName = &"basic"
const IMPROVED: StringName = &"improved"
const ADVANCED: StringName = &"advanced"
const LIMITS: Dictionary = {BASIC: 15, IMPROVED: 25, ADVANCED: 40}
var _tiers: Dictionary[int, StringName] = {}
var _ready_at: Dictionary[int, int] = {}

## Only trusted server gameplay code may assign a better tier.
func set_tier(peer_id: int, tier: StringName) -> bool:
	if peer_id <= 0 or not LIMITS.has(tier):
		return false
	_tiers[peer_id] = tier
	return true

func clear_peer(peer_id: int) -> void:
	_tiers.erase(peer_id)
	_ready_at.erase(peer_id)

func tier_for(peer_id: int) -> StringName:
	return _tiers.get(peer_id, BASIC)

func try_use(peer_id: int, now_ms: int, mob_system: MobSystem, services: MandateWorldServices) -> Dictionary:
	if not GameMode.is_world_server() or peer_id <= 0 or now_ms < 0 or mob_system == null or services == null:
		return {"ok": false, "error": "invalid"}
	if not services.mutations_allowed(peer_id):
		return {"ok": false, "error": "transfer_pending"}
	if mob_system._world == null or not mob_system._world.characters.has(peer_id) or not mob_system._endpoint.is_player_alive(peer_id):
		return {"ok": false, "error": "player"}
	if now_ms < _ready_at.get(peer_id, 0):
		return {"ok": false, "error": "cooldown"}
	var cap: int = LIMITS[tier_for(peer_id)]
	var attracted: int = mob_system.taunt_nearby_packs(peer_id, RANGE_METERS, cap)
	_ready_at[peer_id] = now_ms + COOLDOWN_MS
	return {"ok": true, "attracted": attracted, "cap": cap, "cooldown_ms": COOLDOWN_MS}
