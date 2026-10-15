class_name WorldServer
extends BaseMultiplayerEndpoint
## Server autoload. Keep it clean and minimal.
## Should only care about connection and authentication stuff.

@export var database: WorldDatabase
@export var world_manager: WorldManagerClient
@export var chat_service: ChatService

## The full-DB backup (WAL checkpoint TRUNCATE + whole-file copy) is the heaviest
## periodic op and its cost grows with DB size, so it runs on a MULTIPLE of the save
## interval instead of every save. Player saves still flush every 5 min (cheap per
## player, keeps the data-loss window short); the backup folds in every Nth save. Side
## benefit: with keep_last=10 the retained history stretches from ~50 min to ~5 h.
## See docs/netcode_perf_audit.md.
const BACKUP_EVERY_N_SAVES: int = 6  # 6 × 5 min = 30 min
var _periodic_save_count: int = 0

var token_list: Dictionary[String, PlayerResource]

## {peer_id: PlayerResource}
var connected_players: Dictionary[int, PlayerResource]
## {player_id: peer_id}
var player_id_to_peer_id: Dictionary[int, int]
## Minimal combat view, keyed by persistent character ID. Refreshed only after
## loading inventory or a committed item operation, never by a combat action.
var runtime_equipment: Dictionary[int, Dictionary] = {}
## UTC epoch gives restart/process continuity without a database write per tick.
var world_time := WorldTime.authority(preload("res://source/common/gameplay/world_time/world_time_settings.tres"))

func update_runtime_equipment(owner_id: int, snapshot: Dictionary) -> void:
	if not snapshot.get("ok", false):
		runtime_equipment.erase(owner_id)
		return
	runtime_equipment[owner_id] = {"equipment": snapshot.equipment.duplicate(true), "stats": snapshot.stats.duplicate(true)}

func runtime_attack(owner_id: int) -> int:
	if not runtime_equipment.has(owner_id): return -1
	return int(runtime_equipment[owner_id].stats.get("attack", 10))

func runtime_attack_speed_ratio(owner_id: int) -> float:
	if not runtime_equipment.has(owner_id): return -1.0
	var speed := float(runtime_equipment[owner_id].stats.get("attack_speed",100.0))
	if not is_finite(speed) or speed <= 0: return -1.0
	return speed/100.0

static var curr: WorldServer

## Internal Master connection only; public clients submit a token, never an ID.
func accept_master_handoff(auth_token: String, username: String, character_id: int, account_id: int) -> bool:
	if not database.wallet_ready: return false
	var player: PlayerResource = database.get_player_resource(character_id)
	if auth_token.is_empty() or player == null or player.account_name != username: return false
	if not database.store.bind_account_identity(username,account_id):
		push_warning("Rejected Master account identity mapping for world character %d." % character_id)
		return false
	token_list[auth_token] = player
	return true

## Zero means unknown/unbound. Character IDs are local to this World's database.
func resolve_account_id(character_id: int) -> int:
	return database.store.resolve_account_id(character_id)

func resolve_peer_account_id(peer_id: int) -> int:
	var player: PlayerResource = connected_players.get(peer_id)
	return resolve_account_id(player.player_id) if player != null else 0


func start_world_server() -> void:
	world_manager.token_received.connect(accept_master_handoff)

	var configuration: Dictionary = ConfigFileUtils.load_section(
		"world-server",
		CmdlineUtils.get_parsed_args().get("config", "res://data/config/world_config.cfg")
	)
	if configuration.has("error"):
		# Error case
		pass
	else:
		create(Role.SERVER, configuration.bind_address, configuration.port)

	chat_service.setup_with_db(database.db)
	$InstanceManager.start_instance_manager()

	# Periodic save + backup. 5 minutes balances "low data loss on crash"
	# against "no churning the disk every second." backup_database keeps the
	# last 10 snapshots, so we get ~50 minutes of recoverable history.
	var save_timer: Timer = Timer.new()
	save_timer.name = "PeriodicSaveTimer"
	save_timer.wait_time = 5.0 * 60.0
	save_timer.autostart = true
	save_timer.timeout.connect(_on_periodic_save)
	add_child(save_timer)

	# Network/tick profiler report — one aggregate [NET] line per second across the
	# whole world process (docs/netcode_perf_audit.md, F0). Cheap; toggle the output
	# with NetProfiler.enabled. This is the measurement backbone for load testing.
	var net_report_timer: Timer = Timer.new()
	net_report_timer.name = "NetProfilerTimer"
	net_report_timer.wait_time = 1.0
	net_report_timer.autostart = true
	net_report_timer.timeout.connect(
		func() -> void: NetProfiler.report_and_reset(connected_players.size(), 1.0)
	)
	add_child(net_report_timer)


func _on_periodic_save() -> void:
	# Refresh last-seen for everyone online so a crash only loses at most one
	# save interval of it (the authoritative stamp is on disconnect).
	var now_unix_ms: int = int(Time.get_unix_time_from_system() * 1000.0)
	for pid: int in connected_players:
		var p: PlayerResource = connected_players[pid]
		if p != null:
			p.lb_stats["last_seen_ms"] = now_unix_ms
	var saved: int = database.save_all_connected(connected_players)
	# The backup (checkpoint + full-file copy) only runs every Nth save — see
	# BACKUP_EVERY_N_SAVES. Shutdown / master-triggered saves back up separately.
	_periodic_save_count += 1
	if _periodic_save_count % BACKUP_EVERY_N_SAVES != 0:
		ServerLog.info("Periodic save: %d player(s) flushed." % saved)
		return
	var ok: bool = await database.coordinated_backup()
	ServerLog.info("Periodic save: %d player(s) flushed, backup %s." % [saved, "ok" if ok else "FAILED"])


## Best-effort save on a window-manager close (editor run / windowed build).
## NOTE: Godot headless does NOT deliver _notification on SIGINT/SIGTERM, so this
## does NOT fire on `systemctl stop` (verified). The reliable production save path
## is master-triggered (master_save / master_restart, RPC-driven so it's signal-
## free) — the deploy calls /v1/save_all before stopping. This handler stays only
## for the interactive/windowed case; it's harmless and never the sole safety net.
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_CLOSE_REQUEST:
		return
	if database == null:
		return
	get_tree().auto_accept_quit=false
	if database.save_all_connected(connected_players)<0 or not await database.shutdown_database():
		push_error("Window shutdown refused: checkpoint or auction reader drain failed.")
		return
	get_tree().quit()


func _connect_multiplayer_api_signals(api: SceneMultiplayer) -> void:
	api.peer_connected.connect(_on_peer_connected)
	api.peer_disconnected.connect(_on_peer_disconnected)
	
	api.peer_authenticating.connect(_on_peer_authenticating)
	api.peer_authentication_failed.connect(_on_peer_authentication_failed)
	api.set_auth_callback(_authentication_callback)


func _on_peer_connected(peer_id: int) -> void:
	ServerLog.info("Peer %d connected." % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	ServerLog.info("Peer %d disconnected." % peer_id)
	# Sparring: if mid-match, end it before we tear down so the survivor gets
	# the win + teleport instead of being stranded in the arena.
	# Dungeon: sweep them from any lobby queue / live run so the group + run maps
	# don't keep a phantom member (and the private instance can free when empty).
	DungeonService.on_peer_disconnected(peer_id)
	# Drop rate-limit counters so a reconnect starts with a clean window.
	RateLimiter.forget(peer_id)

	var player: PlayerResource = connected_players.get(peer_id)
	if player == null:
		return
	# Last-login-wins may already have installed a newer peer, sometimes sharing
	# this very PlayerResource. Retire only the old peer entry, never its current
	# character authority, progression timestamp, combat cache or account status.
	if player_id_to_peer_id.get(player.player_id, 0) != peer_id or player.current_peer_id != peer_id:
		connected_players.erase(peer_id)
		return

	# Bank the elapsed session time before persisting. Stored as a flat key on
	# lb_stats so it rides existing stats_json serialization (no schema change).
	if player.session_start_ms > 0:
		@warning_ignore("integer_division")
		var session_seconds: int = (Time.get_ticks_msec() - player.session_start_ms) / 1000
		if session_seconds > 0:
			player.lb_stats["played_seconds"] = int(player.lb_stats.get("played_seconds", 0)) + session_seconds

	# Last-seen stamp (unix ms). Rides lb_stats/stats_json like played_seconds —
	# no schema change; profile.get buckets it into coarse "last seen" text.
	player.lb_stats["last_seen_ms"] = int(Time.get_unix_time_from_system() * 1000.0)

	database.save_player(player)
	runtime_equipment.erase(player.player_id)

	player_id_to_peer_id.erase(player.player_id)
	BlockList.clear_player(player.player_id)

	player.current_peer_id = 0
	connected_players.erase(peer_id)
	var shared_wallet_in_use := false
	var account_still_connected := false
	var account_id := database.wallet_account_id(player.player_id)
	for other_peer: int in connected_players:
		var other: PlayerResource = connected_players[other_peer]
		if other.current_peer_id != other_peer or player_id_to_peer_id.get(other.player_id, 0) != other_peer:
			continue
		if database.wallet_account_id(other.player_id) == account_id:
			shared_wallet_in_use = true
		if other.account_name == player.account_name:
			account_still_connected = true
	if not shared_wallet_in_use: database.release_wallet(player.player_id)
	# Another character can have replaced this account's login too. Stale peer
	# entries neither keep a wallet alive nor count as an active account at Master.
	if not account_still_connected:
		_notify_master_disconnected(player.account_name)



func _notify_master_disconnected(account_name: String) -> void:
	world_manager.player_disconnected.rpc_id(1, account_name)


func _on_peer_authenticating(peer_id: int) -> void:
	print("Peer: %d is trying to authenticate." % peer_id)
	multiplayer.send_auth(peer_id, "data_from_server".to_ascii_buffer())


func _on_peer_authentication_failed(peer_id: int) -> void:
	print("Peer: %d failed to authenticate." % peer_id)


func _authentication_callback(peer_id: int, data: PackedByteArray) -> void:
	# Cast as String if not returns empty String
	var auth_token: String = bytes_to_var(data) as String
	print("Peer: %d is trying to authenticate." % peer_id)
	if is_valid_authentication_token(auth_token):
		multiplayer.complete_auth(peer_id)
		connected_players[peer_id] = token_list[auth_token]
		var owner_id: int = connected_players[peer_id].player_id
		if database.dirty_progression.has(owner_id):
			connected_players[peer_id] = database.dirty_progression[owner_id]
		connected_players[peer_id].current_peer_id = peer_id
		# Stamp the session start so the played_seconds counter can advance on
		# disconnect. Reset on every fresh login.
		connected_players[peer_id].session_start_ms = Time.get_ticks_msec()
		player_id_to_peer_id[connected_players[peer_id].player_id] = peer_id
		# Hydrate the per-player block-list cache so chat filtering is a
		# dictionary lookup, not a JSON parse per message.
		BlockList.set_for(connected_players[peer_id].player_id, connected_players[peer_id].blocked_ids)
		token_list.erase(auth_token)
		data_push.rpc_id.call_deferred(peer_id, &"player_id.set", {"player_id": connected_players[peer_id].player_id})
		data_push.rpc_id.call_deferred(peer_id, &"active_guild_id.set", {"active_guild_id": connected_players[peer_id].active_guild_id})
		# Wardstone mirror: lets sealed portals render + explain locally with zero
		# round trips (docs/wardstones.md). Re-pushed on every grant. Backfill
		# first: finales turned in before the system shipped still owe their stone.
		QuestService.backfill_wardstones(connected_players[peer_id])
		data_push.rpc_id.call_deferred(peer_id, &"wardstones.set", {"wardstones": connected_players[peer_id].wardstones})
	else:
		peer.disconnect_peer(peer_id)


func is_valid_authentication_token(auth_token: String) -> bool:
	if token_list.has(auth_token):
		return true
	return false


@export var instance_manager: InstanceManagerServer

# Public operation names are a protocol allowlist, never arbitrary resource paths.
# New handlers require explicit admission here; the base class is not an operation.
const DATA_REQUEST_TYPES: Array[StringName] = [
	"action.perform",
	"attribute.get",
	"attribute.reset",
	"attribute.spend",
	"channel.cancel",
	"chat.bootstrap",
	"chat.command.exec",
	"chat.dm.history",
	"chat.guild.history",
	"chat.message.send",
	"chat.typing.set",
	"dungeon.info",
	"dungeon.leave",
	"dungeon.queue",
	"dungeon.rooms",
	"friend.accept",
	"friend.list",
	"friend.remove",
	"friend.request",
	"friend.search",
	"guild.banner.color",
	"guild.create",
	"guild.disband",
	"guild.edit",
	"guild.get",
	"guild.get.joined_guilds",
	"guild.get.members",
	"guild.hall.upgrade",
	"guild.invite",
	"guild.invite.accept",
	"guild.kick",
	"guild.log.get",
	"guild.logo.buy",
	"guild.perms",
	"guild.quit",
	"guild.rank",
	"guild.search",
	"guild.tag",
	"guild.transfer",
	"guild.treasury.deposit",
	"guild.trophies.display",
	"guild.trophies.get",
	"inventory.get",
	"item.equip",
	"item.pin",
	"item.unequip",
	"mail.claim",
	"mail.delete",
	"mail.list",
	"mail.read",
	"mail.send",
	"mail.unread_count",
	"name.change",
	"npc.interact",
	"profile.get",
	"profile.update",
	"progression.get",
	"quest.accept",
	"quest.board.claim",
	"quest.board.info",
	"quest.list",
	"quest.turn_in",
	"recall.start",
	"redeem.code",
	"shop.buy.item",
	"shop.open",
	"shop.trade.item",
	"social.block.add",
	"social.block.list",
	"social.block.remove",
	"trade.accept",
	"trade.join",
	"trade.leave",
	"trade.offer",
	"trade.state",
	"wardrobe.buy",
	"wardrobe.equip",
	"wardrobe.state",
]

var data_handlers: Dictionary[StringName, DataRequestHandler]


func _ready() -> void:
	if GameMode.is_world_server(): get_tree().auto_accept_quit=false
	# Publish the live world-server singleton. Common-side code reaches it as the
	# typed `WorldServer.curr` (the export plugin stubs this static, so naming the
	# class in common/ stays client-export-safe).
	curr = self


## If no instance_id is provided, will use all peers connected in the world.
func propagate_rpc(callable: Callable, instance_id: String = "") -> void:
	var instance: ServerInstance = instance_manager.get_instance_server_by_id(instance_id)
	if instance:
		for peer_id: int in instance.connected_peers:
			callable.rpc_id(peer_id)
	else:
		for peer_id: int in instance_manager.world_server.connected_players:
			callable.rpc_id(peer_id)


## Recall payoff (called via WorldServer.curr from RecallAbility.channel_complete): send
## [param player] home to the town hub. Delegates to the InstanceManager by peer,
## which resolves the current instance authoritatively and reuses the warper/jail
## travel path.
func recall_player(player: Player) -> void:
	if player == null or player.player_resource == null:
		return
	instance_manager.recall_player(int(player.player_resource.current_peer_id))


@rpc("any_peer", "call_remote", "reliable", 1)
func _data_request(
	request_id: int,
	type: StringName,
	args: Dictionary = {},
	instance_id: String = ""
) -> void:
	if not GameMode.is_world_server():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if peer_id <= 1:
		return
	_data_response.rpc_id(peer_id, request_id, type, dispatch_data_request(peer_id, type, args, instance_id))


## Shared admission for the generic World request protocol. Identity comes only
## from authenticated server session maps; omitted instance means the peer's own
## joined instance, never a configured default or client-selected path.
func request_instance(peer_id: int, instance_id: String = "") -> ServerInstance:
	var player: PlayerResource = connected_players.get(peer_id)
	if peer_id <= 1 or player == null or player.player_id <= 0 or player.account_name.is_empty():
		return null
	if player.current_peer_id != peer_id or player_id_to_peer_id.get(player.player_id, 0) != peer_id:
		return null
	if instance_manager == null:
		return null
	var instance: ServerInstance = instance_manager.find_instance_for_peer(peer_id) if instance_id.is_empty() else instance_manager.get_instance_server_by_id(instance_id)
	if instance == null or instance.instance_resource == null or not instance.connected_peers.has(peer_id):
		return null
	if instance.instance_resource.use_3d:
		var world := instance.get_node_or_null("GameWorld") as GameWorld3D
		if world == null or not world.characters.has(peer_id):
			return null
	else:
		var actor: Player = instance.players_by_peer_id.get(peer_id)
		if actor == null or actor.player_resource != player:
			return null
	return instance


func dispatch_data_request(peer_id: int, type: StringName, args: Dictionary, instance_id: String = "") -> Dictionary:
	var instance := request_instance(peer_id, instance_id)
	if instance == null:
		return {"ok": false, "error": ERR_UNAUTHORIZED}
	if not DATA_REQUEST_TYPES.has(type):
		return {"ok": false, "error": ERR_INVALID_PARAMETER}
	if not data_handlers.has(type):
		# `type` is now a member of the server-owned literal allowlist.
		var script: GDScript = load("res://source/server/world/components/data_request_handlers/" + str(type) + ".gd")
		if script == null:
			return {"ok": false, "error": ERR_UNAVAILABLE}
		var handler := script.new() as DataRequestHandler
		if handler == null:
			return {"ok": false, "error": ERR_UNAVAILABLE}
		data_handlers[type] = handler
	return data_handlers[type].data_request_handler(peer_id, instance, args)



@rpc("authority", "call_remote", "reliable", 1)
func _data_response(request_id: int, type: String, data: Dictionary) -> void:
	# Client only
	pass


@rpc("authority", "call_remote", "reliable", 1)
func data_push(type: StringName, data: Dictionary) -> void:
	# Client only
	pass
