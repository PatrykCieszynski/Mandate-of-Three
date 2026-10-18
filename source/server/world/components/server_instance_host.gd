class_name ServerInstanceHost
extends SubViewport
## Transport-neutral world instance: peer membership, admission and lifecycle.
## No legacy Player/Map/StateSynchronizer or 2D gameplay dependencies.

enum AdmissionState { ACCEPTING = 0, DRAINING = 1 }
enum AccessPolicy { PUBLIC = 0, RESERVED = 1 }

var connected_peers: PackedInt64Array = PackedInt64Array()
var awaiting_peers: Dictionary[int, Dictionary] = {}
var instance_resource
var identity: Dictionary = {}
var admission_state: AdmissionState = AdmissionState.ACCEPTING
var access_policy: AccessPolicy = AccessPolicy.PUBLIC
var allowed_character_ids: PackedInt64Array = PackedInt64Array()
var opened_at_ms: int = 0
var idle_since_ms: int = -1
var is_overflow_copy: bool = false

func population() -> int:
	return connected_peers.size() + awaiting_peers.size()

func allows_character(character_id: int) -> bool:
	return InstanceAdmissionRules.allows_character(character_id, access_policy, allowed_character_ids)

func accepts_reservation() -> bool:
	return instance_resource != null and InstanceAdmissionRules.accepts_reservation(
		is_queued_for_deletion(), admission_state, population(), instance_resource.max_players
	)
