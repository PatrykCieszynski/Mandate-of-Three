class_name InstanceHost
extends SubViewport
## 2D-independent admission and lifecycle state shared by map hosts.
## Legacy ServerInstance retains gameplay/RPC compatibility during migration.

var connected_peers: PackedInt64Array = PackedInt64Array()
var awaiting_peers: Dictionary[int, Dictionary] = {}
var instance_resource: InstanceResource
var identity: Dictionary = {}
enum AdmissionState { ACCEPTING = 0, DRAINING = 1 }
enum AccessPolicy { PUBLIC = 0, RESERVED = 1 }
var admission_state: AdmissionState = AdmissionState.ACCEPTING
var access_policy: AccessPolicy = AccessPolicy.PUBLIC
var allowed_character_ids: PackedInt64Array = PackedInt64Array()
var opened_at_ms: int = 0
var idle_since_ms: int = -1
var is_overflow_copy: bool = false

func population() -> int:
	return connected_peers.size() + awaiting_peers.size()

func allows_character(character_id: int) -> bool:
	return character_id > 0 and (
		access_policy == AccessPolicy.PUBLIC
		or (access_policy == AccessPolicy.RESERVED and allowed_character_ids.has(character_id))
	)

func accepts_reservation() -> bool:
	return (
		not is_queued_for_deletion()
		and admission_state == AdmissionState.ACCEPTING
		and instance_resource != null
		and population() < instance_resource.max_players
	)
