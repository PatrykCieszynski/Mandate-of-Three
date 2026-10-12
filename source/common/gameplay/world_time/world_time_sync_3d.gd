class_name WorldTimeSync3D
extends Node
## Authority-only calendar publication under the authenticated map RPC path.
const SYNC_INTERVAL: float = 5.0
var services: MandateWorldServices
var clock := WorldTime.new()
var _world: GameWorld3D
var _server: bool = false
var _elapsed: float = 0.0
var _sequence: int = 0

func _ready() -> void:
	_world = get_parent() as GameWorld3D
	_server = GameMode.is_world_server()
	if _server:
		var shared: WorldTime = services.world_time()
		if shared != null: clock = shared

func _process(delta: float) -> void:
	if not _server:
		clock.advance(delta)
		return
	_elapsed += delta
	if _elapsed < SYNC_INTERVAL: return
	_elapsed = fmod(_elapsed,SYNC_INTERVAL)
	for peer_id: int in _world.characters: publish_to(peer_id)

func publish_to(peer_id: int) -> void:
	if not _server or not _world.characters.has(peer_id) or not clock.synchronized: return
	_sequence += 1
	receive_time.rpc_id(peer_id,clock.unix_time(),clock.rate,_sequence)

@rpc("authority","call_remote","reliable",0)
func receive_time(game_unix: float, game_rate: float, sequence: int) -> void:
	if _server: return
	clock.accept_sample(game_unix,game_rate,sequence)
