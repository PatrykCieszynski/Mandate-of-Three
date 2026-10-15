extends GameWorld3D
## Test-only World: production movement/simulation still run, but synthetic peer IDs
## have no real sockets. Replace only RPC fan-out with an explicit encoding proxy.
## This measures serialization CPU, NOT ENet/WebSocket delivery or real players.
var encode_per_peer := false
var snapshot_count := 0
var snapshot_build_us := 0
var snapshot_encode_us := 0
var estimated_wire_bytes := 0

func reset_snapshot_metrics() -> void:
	snapshot_count = 0
	snapshot_build_us = 0
	snapshot_encode_us = 0
	estimated_wire_bytes = 0

func _broadcast_snapshot() -> void:
	var started := Time.get_ticks_usec()
	var snapshot: Dictionary = {}
	for peer_id: int in characters:
		var body: PlayerActor3D = characters[peer_id]
		snapshot[peer_id] = [body.position, body.rotation.y]
	snapshot_build_us += Time.get_ticks_usec() - started
	var encode_started := Time.get_ticks_usec()
	var payload := var_to_bytes(snapshot)
	estimated_wire_bytes += payload.size() * characters.size()
	if encode_per_peer:
		# Upper-bound *encoding* proxy for the current full-roster per-peer fan-out.
		# Native RPC encoding/compression, OS sockets and receivers are not tested.
		for index: int in characters.size():
			var_to_bytes(snapshot)
	snapshot_encode_us += Time.get_ticks_usec() - encode_started
	snapshot_count += 1
