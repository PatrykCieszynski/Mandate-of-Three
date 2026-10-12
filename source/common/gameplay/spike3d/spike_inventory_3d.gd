class_name SpikeInventory3D
extends Node
var services: MandateWorldServices
## UID commands and private inventory snapshots share the authenticated map path.

signal state_changed(state: Dictionary)
signal operation_finished(command_id: String, result: Dictionary)
# Facts are emitted only after authoritative refresh, never to orchestrate it.
signal inventory_changed(owner_id: int)
var _authoritative_snapshots: Dictionary[int, Dictionary] = {}
var state: Dictionary = {}
var public_weapons: Dictionary[int, String] = {}
var _last_action_ms: Dictionary[int, int] = {}
var _world: Node
func _ready() -> void:
	_world = get_parent()
	inventory_changed.connect(_inventory_changed)

func _store() -> ItemStoreSqlite:
	return services.item_store()

func initialize_peer(peer_id: int) -> void:
	var store: ItemStoreSqlite = _store()
	if store == null:
		return # Physics-only fixture has no database or item domain.
	var resource: PlayerResource = services.player_for_peer(peer_id)
	var result: Dictionary = store.initialize_character(resource.player_id)
	if result.ok and OS.has_feature("editor") and OS.get_cmdline_user_args().has("--dev-trace-sword"):
		result = store.grant_dev_trace_sword(resource.player_id)
		print("DEV_TRACE_SWORD owner=",resource.player_id," result=",result)
	resynchronize(peer_id, "" if result.ok else str(result.error))
	for other_id: int in public_weapons:
		receive_weapon.rpc_id(peer_id, other_id, public_weapons[other_id])

func remove_peer(peer_id: int) -> void:
	_authoritative_snapshots.erase(peer_id)
	public_weapons.erase(peer_id)
	_last_action_ms.erase(peer_id)

@rpc("any_peer", "call_remote", "reliable", 1)
func request_equipment(action: String, uid: String, revision: int, command_id: String = "", requested_position: int = -1) -> void:
	_handle_command(action, uid, revision, requested_position, command_id)

@rpc("any_peer", "call_remote", "reliable", 1)
func request_activate_item(uid: String, revision: int, command_id: String) -> void:
	_handle_command("activate", uid, revision, -1, command_id)

@rpc("any_peer", "call_remote", "reliable", 1)
func request_move_item(uid: String, revision: int, x: int, y: int, page: int, command_id: String) -> void:
	var position: int = page * InventoryGrid.PAGE_CELLS + y * InventoryGrid.COLUMNS + x if x >= 0 and x < InventoryGrid.COLUMNS and y >= 0 and y < InventoryGrid.ROWS and page >= 0 and page < InventoryGrid.PAGES else -1
	_handle_command("move", uid, revision, position, command_id)

@rpc("any_peer", "call_remote", "reliable", 1)
# Storage is intentionally available everywhere in this MVP. Authentication,
# account membership and placement are enforced here/in SQL. Client window state
# is presentation only; future NPC/range authorization belongs at this RPC.
func request_storage(uid: String, revision: int, source: String, destination: String, x: int, y: int, page: int, quick: bool, command_id: String) -> void:
	if not GameMode.is_world_server() or command_id.length() > 80: return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if not _world.characters.has(peer_id) or _store() == null: return
	var now: int = Time.get_ticks_msec()
	var result: Dictionary = {"ok":false,"error":"too_fast"}
	if now - _last_action_ms.get(peer_id,-1000) >= 100:
		_last_action_ms[peer_id] = now
		var resource: PlayerResource = services.player_for_peer(peer_id)
		var columns: int = AccountStorageSqlite.COLUMNS if destination == "storage" else InventoryGrid.COLUMNS
		var pages: int = AccountStorageSqlite.PAGES if destination == "storage" else InventoryGrid.PAGES
		var position: int = page * columns * 9 + y * columns + x
		if (source == "inventory" and destination == "inventory") or (not quick and (x < 0 or x >= columns or y < 0 or y >= 9 or page < 0 or page >= pages)):
			result = {"ok":false,"error":"request"}
		else:
			result = services.economy().transfer_storage(resource.player_id,uid,revision,source,destination,-1 if quick else position)
	# Prepare every affected character before the first notification/publication.
	var actor: PlayerResource = services.player_for_peer(peer_id)
	var affected: Array[int] = []
	for other_peer: int in _world.characters:
		var other: PlayerResource = services.player_for_peer(other_peer)
		if other != null and other.account_name == actor.account_name:
			refresh_authoritative_state(other_peer)
			affected.append(other_peer)
	for other_peer: int in affected:
		if result.ok:
			inventory_changed.emit(services.player_for_peer(other_peer).player_id)
		else:
			_send_state(other_peer) # Explicit repair; no committed-change fact.
	if command_id != "": receive_operation.rpc_id(peer_id,command_id,result)

func _handle_command(action: String, uid: String, revision: int, position: int, command_id: String) -> void:
	if not GameMode.is_world_server() or command_id.length() > 80:
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if not _world.characters.has(peer_id) or _store() == null:
		return
	var result: Dictionary
	var now: int = Time.get_ticks_msec()
	if now - _last_action_ms.get(peer_id, -1000) < 100:
		result = {"ok": false, "error": "too_fast"}
	else:
		_last_action_ms[peer_id] = now
		var resource: PlayerResource = services.player_for_peer(peer_id)
		if action == "activate":
			result = _store().activate_item(resource.player_id,uid,revision)
		else:
			result = _store().move_bag_item(resource.player_id, uid, revision, position) if action == "move" else _store().change_equipment(resource.player_id, uid, revision, action, position)
	if result.ok:
		accept_committed_change(peer_id)
	else:
		resynchronize(peer_id, str(result.error))
	if command_id != "":
		receive_operation.rpc_id(peer_id, command_id, result)

@rpc("authority", "call_remote", "reliable", 1)
func receive_operation(command_id: String, result: Dictionary) -> void:
	if GameMode.is_client(): operation_finished.emit(command_id, result)

func accept_committed_change(peer_id: int) -> void:
	# The caller has committed the item mutation. This endpoint owns refresh/fact.
	refresh_authoritative_state(peer_id)
	var owner_id: int = services.owner_id_for_peer(peer_id)
	if owner_id > 0: inventory_changed.emit(owner_id)

func refresh_authoritative_state(peer_id: int) -> void:
	# Also used to prepare every account peer before Storage fan-out.
	var resource: PlayerResource = services.player_for_peer(peer_id)
	if resource == null or _store() == null: return
	var snapshot: Dictionary = _store().inventory(resource.player_id)
	services.update_runtime_equipment(resource.player_id, snapshot)
	snapshot["storage"] = services.economy().storage_snapshot(resource.player_id)
	_authoritative_snapshots[peer_id] = snapshot
	if not snapshot.ok: return
	var definition_id: String = ""
	var uid: String = str(snapshot.equipment.get("weapon", ""))
	for item: Dictionary in snapshot.items:
		if item.uid == uid:
			definition_id = str(item.definition_id)
	public_weapons[peer_id] = definition_id
	var body: SpikeCharacter3D = _world.characters.get(peer_id)
	if body != null:
		body.set_weapon(definition_id)

func resynchronize(peer_id: int, error: String = "") -> void:
	# Entry and rejected/stale commands repair state without claiming a commit.
	refresh_authoritative_state(peer_id)
	_send_state(peer_id, error)

func _inventory_changed(owner_id: int) -> void:
	for peer_id: int in _world.characters:
		var resource: PlayerResource = services.player_for_peer(peer_id)
		if resource != null and resource.player_id == owner_id: _send_state(peer_id)

func _send_state(peer_id: int, error: String = "") -> void:
	# Publication consumes prepared state; it never refreshes combat stats.
	if not _authoritative_snapshots.has(peer_id): return
	var snapshot: Dictionary = _authoritative_snapshots[peer_id].duplicate(true)
	if error != "": snapshot["error"] = error
	receive_inventory.rpc_id(peer_id, snapshot)
	if _world.upgrade_endpoint != null: _world.upgrade_endpoint.publish(peer_id)
	if not snapshot.ok: return
	var definition_id: String = public_weapons.get(peer_id, "")
	for observer: int in _world.characters:
		receive_weapon.rpc_id(observer, peer_id, definition_id)

@rpc("authority", "call_remote", "reliable", 1)
func receive_inventory(snapshot: Dictionary) -> void:
	if GameMode.is_world_server():
		return
	state = snapshot.duplicate(true)
	state_changed.emit(state)

@rpc("authority", "call_remote", "reliable", 0)
func receive_weapon(peer_id: int, definition_id: String) -> void:
	if GameMode.is_world_server():
		return
	public_weapons[peer_id] = definition_id
	var body: SpikeCharacter3D = _world.characters.get(peer_id)
	if body != null:
		body.set_weapon(definition_id)

func weapon_comparison(item: Dictionary) -> Dictionary:
	# Presentation uses server-calculated instance stats. Equip and damage remain
	# authoritative; this preview never changes or sends stats back to the server.
	var current_attack: int = int(state.get("stats", {}).get("attack", 10))
	var previous_attack: int = 0
	var equipped_uid: String = str(state.get("equipment", {}).get("weapon", ""))
	for equipped: Dictionary in state.get("items", []):
		if str(equipped.uid) == equipped_uid:
			previous_attack = int(equipped.stats.get("attack", 0))
	var attack: int = current_attack - previous_attack + int(item.stats.get("attack", 0))
	return {"attack": attack, "delta": attack - current_attack}
