extends "res://tests/spike3d_network.gd"
## Real three-process transport regression for player AOI entry/exit/re-entry.
## Reuses production GameWorld3D and the existing authenticated test fixture.
var _phase := 0
var _moved_peer := 0
var _observed_near := false
var _observed_hidden := false
var _observed_return := false
var _report_sent := false
var _reports: Dictionary[int, bool] = {}

@rpc("any_peer", "call_remote", "reliable", 0)
func report_aoi_pass() -> void:
	if GameMode.is_world_server():
		_reports[multiplayer.get_remote_sender_id()] = true

func _server_checks(_delta: float) -> void:
	if _phase == 0 and elapsed > 4.0:
		_check(world.characters.size() == 2, "two peers joined before AOI transition")
		if failed: return
		_moved_peer = world.characters.keys()[1]
		world.characters[_moved_peer].position = Vector3(120, 0.2, 0)
		_phase = 1
	if _phase == 1 and elapsed > 7.0:
		for id: int in world.characters:
			_check(world.interest_players_for(id).size() == 1, "distant peers must each see only self")
		if failed: return
		world.characters[_moved_peer].position = Vector3(-3, 0.2, 3)
		_phase = 2
	if _phase == 2 and elapsed > 10.0:
		for id: int in world.characters:
			_check(world.interest_players_for(id).size() == 2, "AOI membership restores on re-entry")
		if failed: return
		_phase = 3
	if _phase == 3 and _reports.size() == 2:
		print("AOI_SERVER_OK: reliable roster exit/re-entry and two real client acknowledgments")
		peer.close()
		get_tree().quit(0)
	if elapsed > 19.0:
		_check(false, "AOI reports missing after transitions: %d" % _reports.size())

func _client_checks(_delta: float) -> void:
	if not world.characters.has(world.local_peer) or not world.characters[world.local_peer].has_snapshot:
		return
	if world.characters.size() == 2:
		if _observed_hidden:
			_observed_return = true
		else:
			_observed_near = true
	if _observed_near and world.characters.size() == 1:
		_observed_hidden = true
	if _observed_near and _observed_hidden and _observed_return and not _report_sent:
		_report_sent = true
		report_aoi_pass.rpc_id(1)
		print("AOI_CLIENT_OK: near -> culled -> reentered, self retained")
		_close_client.call_deferred()

func _close_client() -> void:
	await get_tree().create_timer(0.8).timeout
	peer.close()
	get_tree().quit(0)
