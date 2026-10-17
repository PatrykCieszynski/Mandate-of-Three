class_name InstanceHost
extends SubViewport
## Data-only admission/lifecycle state shared by instance hosts.
## Keep this base independent of legacy Player, Map and resource class cycles.

var connected_peers: PackedInt64Array = PackedInt64Array()
var awaiting_peers: Dictionary[int, Dictionary] = {}
var identity: Dictionary = {}
var admission_state: int = 0
var access_policy: int = 0
var allowed_character_ids: PackedInt64Array = PackedInt64Array()
var opened_at_ms: int = 0
var idle_since_ms: int = -1
var is_overflow_copy: bool = false

func population() -> int:
	return connected_peers.size() + awaiting_peers.size()

func allows_character(character_id: int) -> bool:
	return character_id > 0 and (
		access_policy == 0
		or (access_policy == 1 and allowed_character_ids.has(character_id))
	)
