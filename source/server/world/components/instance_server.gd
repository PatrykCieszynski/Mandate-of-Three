class_name ServerInstance
extends SubViewport
## Neutral instance session/admission host. Runtime worlds may be 3D or
## legacy fixtures; this class does not instantiate Player, Map or 2D sync.

static var world_server
static var global_chat_commands: Dictionary[String, ChatCommand]
static var global_role_definitions: Dictionary[String, Dictionary] = preload("res://source/server/world/data/server_roles.tres").get_roles()

var local_chat_commands: Dictionary[String, ChatCommand]
var local_role_definitions: Dictionary[String, Dictionary]
var local_role_assignments: Dictionary[int, PackedStringArray]

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

## Temporary, data-only bridge for old RPC handlers and isolated 2D fixtures.
## No 3D gameplay consults these fields; remove once legacy dispatch is retired.
var players_by_peer_id: Dictionary = {}
var instance_map: Variant = null

func population() -> int:
	return connected_peers.size() + awaiting_peers.size()

func allows_character(character_id: int) -> bool:
	return InstanceAdmissionRules.allows_character(character_id, access_policy, allowed_character_ids)

func accepts_reservation() -> bool:
	return instance_resource != null and InstanceAdmissionRules.accepts_reservation(
		is_queued_for_deletion(), admission_state, population(), instance_resource.max_players
	)

func load_map(_map_path: String) -> void:
	push_error("Concrete world host must implement load_map")

func get_player(peer_id: int) -> Variant:
	return players_by_peer_id.get(peer_id)

## Retained to preserve the legacy transfer call surface while the 3D manager
## replaces its old 2D admin handlers. Actual 2D despawn lives in the adapter.
@rpc("authority", "call_remote", "reliable", 0)
func despawn_player(_peer_id: int, _delete: bool = false) -> void:
	pass
