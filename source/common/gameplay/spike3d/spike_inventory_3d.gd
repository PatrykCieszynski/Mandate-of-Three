class_name SpikeInventory3D
extends Node
## UID commands and private inventory snapshots share the authenticated map path.

signal state_changed(state: Dictionary)
signal operation_finished(command_id: String, result: Dictionary)
var state: Dictionary = {}
var public_weapons: Dictionary[int, String] = {}
var _last_action_ms: Dictionary[int, int] = {}
var _world: Node
func _ready() -> void:
	_world = get_parent()

func _store() -> ItemStoreSqlite:
	if WorldServer.curr == null or WorldServer.curr.database == null:
		return null
	return WorldServer.curr.database.item_store

func initialize_peer(peer_id: int) -> void:
	var store: ItemStoreSqlite = _store()
	if store == null:
		return # Physics-only fixture has no database or item domain.
	var resource: PlayerResource = WorldServer.curr.connected_players.get(peer_id)
	var result: Dictionary = store.initialize_character(resource.player_id)
	_send_state(peer_id, "" if result.ok else str(result.error))
	for other_id: int in public_weapons:
		receive_weapon.rpc_id(peer_id, other_id, public_weapons[other_id])

func remove_peer(peer_id: int) -> void:
	public_weapons.erase(peer_id)
	_last_action_ms.erase(peer_id)

@rpc("any_peer", "call_remote", "reliable", 1)
func request_equipment(action: String, uid: String, revision: int, command_id: String = "") -> void:
	_handle_command(action, uid, revision, -1, command_id)

@rpc("any_peer", "call_remote", "reliable", 1)
func request_move_item(uid: String, revision: int, x: int, y: int, page: int, command_id: String) -> void:
	var position: int = page * InventoryGrid.PAGE_CELLS + y * InventoryGrid.COLUMNS + x if x >= 0 and x < InventoryGrid.COLUMNS and y >= 0 and y < InventoryGrid.ROWS and page >= 0 and page < InventoryGrid.PAGES else -1
	_handle_command("move", uid, revision, position, command_id)

@rpc("any_peer", "call_remote", "reliable", 1)
func request_storage(uid: String, revision: int, source: String, destination: String, x: int, y: int, page: int, quick: bool, command_id: String) -> void:
	if not GameMode.is_world_server() or command_id.length() > 80: return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if not _world.characters.has(peer_id) or _store() == null: return
	var now: int = Time.get_ticks_msec()
	var result: Dictionary = {"ok":false,"error":"too_fast"}
	if now - _last_action_ms.get(peer_id,-1000) >= 100:
		_last_action_ms[peer_id] = now
		var resource: PlayerResource = WorldServer.curr.connected_players.get(peer_id)
		var columns: int = AccountStorageSqlite.COLUMNS if destination == "storage" else InventoryGrid.COLUMNS
		var pages: int = AccountStorageSqlite.PAGES if destination == "storage" else InventoryGrid.PAGES
		var position: int = page * columns * 9 + y * columns + x
		if not quick and (x < 0 or x >= columns or y < 0 or y >= 9 or page < 0 or page >= pages):
			result = {"ok":false,"error":"request"}
		else:
			result = AccountStorageSqlite.new(_store().db).transfer(resource.player_id,uid,revision,source,destination,-1 if quick else position)
	# Active characters of this account on this map receive the new shared state.
	var actor: PlayerResource = WorldServer.curr.connected_players.get(peer_id)
	for other_peer: int in _world.characters:
		var other: PlayerResource = WorldServer.curr.connected_players.get(other_peer)
		if other != null and other.account_name == actor.account_name: _send_state(other_peer)
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
		var resource: PlayerResource = WorldServer.curr.connected_players.get(peer_id)
		result = _store().move_bag_item(resource.player_id, uid, revision, position) if action == "move" else _store().change_equipment(resource.player_id, uid, revision, action)
	_send_state(peer_id, "" if result.ok else str(result.error))
	if command_id != "":
		receive_operation.rpc_id(peer_id, command_id, result)

@rpc("authority", "call_remote", "reliable", 1)
func receive_operation(command_id: String, result: Dictionary) -> void:
	if GameMode.is_client(): operation_finished.emit(command_id, result)

func _send_state(peer_id: int, error: String = "") -> void:
	var resource: PlayerResource = WorldServer.curr.connected_players.get(peer_id)
	if resource == null:
		return
	var snapshot: Dictionary = _store().inventory(resource.player_id)
	WorldServer.curr.update_runtime_equipment(resource.player_id, snapshot)
	snapshot["storage"] = AccountStorageSqlite.new(_store().db).snapshot(resource.player_id)
	if error != "":
		snapshot["error"] = error
	receive_inventory.rpc_id(peer_id, snapshot)
	if not snapshot.ok:
		return
	var definition_id: String = ""
	var uid: String = str(snapshot.equipment.get("weapon", ""))
	for item: Dictionary in snapshot.items:
		if item.uid == uid:
			definition_id = str(item.definition_id)
	public_weapons[peer_id] = definition_id
	var body: SpikeCharacter3D = _world.characters.get(peer_id)
	if body != null:
		body.set_weapon(definition_id)
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
