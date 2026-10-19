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

## Short-lived, single-use Master tickets, not cached character snapshots.
@export var handoff_ttl_ms: int = 30_000
@export var max_handoff_tickets: int = 1024
var token_list: Dictionary[String, Dictionary] = {}
var _pending_admissions: Dictionary[int, Dictionary] = {}
var _session_tokens: Dictionary[int, String] = {}
## Explicit opt-in owner only; normal gameplay has no PostgreSQL backend switch.
var inventory_runtime: RefCounted
var wallet_runtime: RefCounted
var npc_runtime: RefCounted
var storage_runtime: RefCounted
var ground_item_runtime: RefCounted

func _process(_delta: float) -> void:
	if inventory_runtime!=null: inventory_runtime.poll()
	if wallet_runtime!=null: wallet_runtime.poll(_delta)
	if npc_runtime!=null: npc_runtime.poll()
	if storage_runtime!=null: storage_runtime.poll()
	if ground_item_runtime!=null: ground_item_runtime.poll()

## Nonblocking checkpoint barrier. A failure/unknown result refuses a graceful
## handoff/shutdown; dirty income remains owned in RAM for recovery.
func flush_postgres_wallets(shutdown: bool = false) -> bool:
	if wallet_runtime==null and npc_runtime!=null: return false
	if shutdown and storage_runtime!=null: storage_runtime.begin_drain()
	if shutdown and ground_item_runtime!=null: ground_item_runtime.begin_drain()
	if shutdown and npc_runtime!=null: npc_runtime.begin_drain()
	if wallet_runtime!=null:
		if shutdown: wallet_runtime.begin_drain()
		else: wallet_runtime.checkpoint_all()
	var deadline: int=Time.get_ticks_msec()+8000
	while not _postgres_economy_settled(shutdown) and Time.get_ticks_msec()<deadline:
		await get_tree().process_frame
	return _postgres_economy_settled(shutdown)

func _postgres_economy_settled(shutdown: bool) -> bool:
	var npc_ok: bool=npc_runtime==null or (npc_runtime.shutdown_complete() if shutdown else npc_runtime.drained())
	var wallet_ok: bool=wallet_runtime==null or (wallet_runtime.shutdown_complete() if shutdown else wallet_runtime.drained())
	var storage_ok: bool=storage_runtime==null or (storage_runtime.shutdown_complete() if shutdown else storage_runtime.drained())
	var ground_ok: bool=ground_item_runtime==null or (ground_item_runtime.shutdown_complete() if shutdown else ground_item_runtime.drained())
	return npc_ok and wallet_ok and storage_ok and ground_ok

## {peer_id: PlayerResource}
var connected_players: Dictionary[int, PlayerResource]
## {player_id: peer_id}
var player_id_to_peer_id: Dictionary[int, int]
## Minimal combat view, keyed by persistent character ID. Refreshed only after
## loading inventory or a committed item operation, never by a combat action.
var runtime_equipment: Dictionary[int, Dictionary] = {}
var _equipment_versions: Dictionary[int, Dictionary] = {}
const ItemStateVersion = preload("res://source/common/gameplay/items/domain/item_state_version.gd")
## UTC epoch gives restart/process continuity without a database write per tick.
var world_time := WorldTime.authority(preload("res://source/common/gameplay/world_time/world_time_settings.tres"))

## Server-side identity check for asynchronous delivery owners. A client cannot
## choose the character or reuse a retired peer's token through this helper.
func session_ticket_fingerprint(peer_id: int, character_id: int) -> String:
	if not inventory_master_available(): return ""
	var player: PlayerResource=connected_players.get(peer_id)
	if player==null or player.player_id!=character_id or player.current_peer_id!=peer_id or player_id_to_peer_id.get(character_id,0)!=peer_id: return ""
	var token: String=_session_tokens.get(peer_id,"")
	return "" if token.is_empty() else token.sha256_text()

func update_runtime_equipment(owner_id: int, snapshot: Dictionary) -> bool:
	if not snapshot.get("ok", false):
		runtime_equipment.erase(owner_id)
		return false
	var version: Variant = snapshot.get("item_state")
	if not ItemStateVersion.valid(version) or version.character_id != owner_id:
		runtime_equipment.erase(owner_id)
		return false
	if not ItemStateVersion.accepts(_equipment_versions.get(owner_id,{}),version): return false
	# An unchanged watermark cannot overwrite already accepted combat inputs.
	if _equipment_versions.get(owner_id,{})==version and runtime_equipment.has(owner_id):
		return runtime_equipment[owner_id].equipment==snapshot.equipment and runtime_equipment[owner_id].stats==snapshot.stats
	_equipment_versions[owner_id] = version.duplicate(true)
	runtime_equipment[owner_id] = {"equipment":snapshot.equipment.duplicate(true),"stats":snapshot.stats.duplicate(true),"item_state":version.duplicate(true)}
	return true

func runtime_attack(owner_id: int) -> int:
	if not _inventory_combat_ready(owner_id): return -1
	if not runtime_equipment.has(owner_id): return -1
	return int(runtime_equipment[owner_id].stats.get("attack", 10))

func runtime_attack_speed_ratio(owner_id: int) -> float:
	if not _inventory_combat_ready(owner_id): return -1.0
	if not runtime_equipment.has(owner_id): return -1.0
	var speed := float(runtime_equipment[owner_id].stats.get("attack_speed",100.0))
	if not is_finite(speed) or speed <= 0: return -1.0
	return speed/100.0

func _inventory_combat_ready(owner_id: int) -> bool:
	return inventory_runtime==null or inventory_runtime.mutations_allowed(player_id_to_peer_id.get(owner_id,0))

func invalidate_runtime_equipment(owner_id: int) -> void:
	# Preserve the monotonic watermark while denying dependent combat. Only an
	# authoritative snapshot may rebuild this view; a hit never reads persistence.
	runtime_equipment.erase(owner_id)

static var curr: WorldServer

## PG admission depends on the live trusted control connection, not just a
## cached ticket or durable grant. SQLite keeps its existing lifecycle policy.
func inventory_master_available() -> bool:
	return (inventory_runtime==null and wallet_runtime==null) or (world_manager!=null and world_manager.multiplayer_api!=null and world_manager.multiplayer_api.has_multiplayer_peer() and world_manager.multiplayer_api.multiplayer_peer.get_connection_status()==MultiplayerPeer.CONNECTION_CONNECTED)

func invalidate_inventory_admissions() -> void:
	if inventory_runtime==null and wallet_runtime==null: return
	token_list.clear()
	var pending: Array=_pending_admissions.keys()
	_pending_admissions.clear() # Invalidate suspended continuations before closing sockets.
	var live: Array=[]
	if multiplayer_api!=null and multiplayer_api.has_multiplayer_peer():
		live=Array(multiplayer_api.get_peers())
		for peer_id: int in multiplayer_api.get_authenticating_peers():
			live.append(peer_id)
			if not pending.has(peer_id): pending.append(peer_id)
	for peer_id: int in pending:
		if live.has(peer_id): peer.disconnect_peer(peer_id)
	for peer_id: int in connected_players.keys():
		if inventory_runtime!=null: inventory_runtime.detach(peer_id)
		if wallet_runtime!=null: wallet_runtime.detach(peer_id)
		if live.has(peer_id): peer.disconnect_peer(peer_id)

## Internal Master connection only; public clients submit a token, never an ID.
func accept_master_handoff(auth_token: String, username: String, character_id: int, account_id: int, inventory_context: Dictionary = {}) -> bool:
	if not inventory_master_available(): return false
	if inventory_runtime!=null or wallet_runtime!=null:
		if not inventory_context.get("epoch") is int or inventory_context.epoch<=0 or inventory_context.get("account_id")!=account_id or inventory_context.get("character")!=character_id or inventory_context.get("session_fingerprint")!=auth_token.sha256_text(): return false
	elif not inventory_context.is_empty(): return false # Never silently use SQLite for a PG ticket.
	if not database.wallet_ready: return false
	var player: PlayerResource = database.get_player_resource(character_id)
	if auth_token.is_empty() or player == null or player.account_name != username: return false
	if not database.store.bind_account_identity(username,account_id):
		push_warning("Rejected Master account identity mapping for world character %d." % character_id)
		return false
	prune_handoff_tickets()
	# A fresh ticket supersedes unused tickets and pending auth for this account.
	revoke_account_admission(username)
	if token_list.size() + _pending_admissions.size() >= max_handoff_tickets:
		_notify_master_disconnected(username, auth_token)
		return false
	token_list[auth_token] = {
		"account": username, "character_id": character_id,
		"expires_at": Time.get_ticks_msec() + maxi(1, handoff_ttl_ms),
		"inventory_context":inventory_context.duplicate(true),
	}
	return true


func revoke_account_admission(username: String) -> void:
	if inventory_runtime!=null or wallet_runtime!=null:
		for peer_id: int in connected_players:
			if connected_players[peer_id].account_name==username:
				if inventory_runtime!=null: inventory_runtime.detach(peer_id)
				if wallet_runtime!=null: wallet_runtime.detach(peer_id)
	for token: String in token_list.keys():
		if token_list[token].account == username:
			token_list.erase(token)
	for pending_peer: int in _pending_admissions.keys():
		if _pending_admissions[pending_peer].account == username:
			_pending_admissions.erase(pending_peer)
			peer.disconnect_peer(pending_peer)


func prune_handoff_tickets() -> void:
	var now := Time.get_ticks_msec()
	for token: String in token_list.keys():
		if int(token_list[token].expires_at) <= now:
			var account: String = token_list[token].account
			token_list.erase(token)
			_notify_master_disconnected(account, token)
	for pending_peer: int in _pending_admissions.keys():
		if int(_pending_admissions[pending_peer].expires_at) <= now:
			peer.disconnect_peer(pending_peer)


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
	var ticket_timer := Timer.new()
	ticket_timer.name = "HandoffExpiryTimer"
	ticket_timer.wait_time = 1.0
	ticket_timer.autostart = true
	ticket_timer.timeout.connect(prune_handoff_tickets)
	add_child(ticket_timer)


func _on_periodic_save() -> void:
	if not await flush_postgres_wallets():
		push_error("Periodic save refused: PostgreSQL wallet checkpoint unresolved.")
		return
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
	if not await flush_postgres_wallets(true):
		push_error("Window shutdown refused: PostgreSQL wallet checkpoint unresolved.")
		return
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
	# Both sides completed native authentication. Until this signal there is no
	# gameplay authority, even if our complete_auth has already succeeded.
	var ticket: Dictionary = _pending_admissions.get(peer_id, {})
	if ticket.is_empty() or not inventory_master_available():
		_pending_admissions.erase(peer_id)
		peer.disconnect_peer(peer_id)
		return
	_pending_admissions.erase(peer_id)
	var player := database.get_player_resource(int(ticket.character_id))
	if player == null or player.account_name != ticket.account or int(ticket.expires_at) <= Time.get_ticks_msec():
		_notify_master_disconnected(ticket.account, ticket.token)
		peer.disconnect_peer(peer_id)
		return
	_session_tokens[peer_id] = ticket.token
	connected_players[peer_id] = player
	player.current_peer_id = peer_id
	player.session_start_ms = Time.get_ticks_msec()
	player_id_to_peer_id[player.player_id] = peer_id
	BlockList.set_for(player.player_id, player.blocked_ids)
	if inventory_runtime!=null and not inventory_runtime.attach(peer_id,ticket.get("inventory_context",{})):
		peer.disconnect_peer(peer_id)
		return
	if wallet_runtime!=null and not wallet_runtime.attach(peer_id,ticket.get("inventory_context",{})):
		peer.disconnect_peer(peer_id)
		return
	_publish_authenticated_state(peer_id, player)
	ServerLog.info("Peer %d connected." % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if inventory_runtime!=null: inventory_runtime.detach(peer_id)
	if wallet_runtime!=null: wallet_runtime.detach(peer_id)
	var session_token: String = _session_tokens.get(peer_id, "")
	_session_tokens.erase(peer_id)
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
	_equipment_versions.erase(player.player_id)

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
		_notify_master_disconnected(player.account_name, session_token)



func _notify_master_disconnected(account_name: String, session_token: String = "") -> void:
	if world_manager != null and world_manager.multiplayer_api != null and world_manager.multiplayer_api.has_multiplayer_peer() and world_manager.multiplayer_api.multiplayer_peer.get_connection_status()==MultiplayerPeer.CONNECTION_CONNECTED:
		world_manager.player_disconnected.rpc_id(1, account_name, session_token)


func _on_peer_authenticating(peer_id: int) -> void:
	if not inventory_master_available():
		peer.disconnect_peer(peer_id)
		return
	print("Peer: %d is trying to authenticate." % peer_id)
	multiplayer.send_auth(peer_id, "data_from_server".to_ascii_buffer())


func _on_peer_authentication_failed(peer_id: int) -> void:
	var ticket: Dictionary = _pending_admissions.get(peer_id, {})
	_pending_admissions.erase(peer_id)
	if not ticket.is_empty():
		_notify_master_disconnected(ticket.account, ticket.token)
	print("Peer: %d failed to authenticate." % peer_id)


func _authentication_callback(peer_id: int, data: PackedByteArray) -> void:
	if not inventory_master_available():
		_pending_admissions.erase(peer_id)
		peer.disconnect_peer(peer_id)
		return
	# A duplicate packet cannot start another continuation for an admitted ticket.
	if _pending_admissions.has(peer_id): return
	if data.size() > 1024:
		peer.disconnect_peer(peer_id)
		return
	var decoded: Variant = bytes_to_var(data)
	if not decoded is String or not is_valid_authentication_token(decoded):
		peer.disconnect_peer(peer_id)
		return
	var auth_token: String = decoded
	var ticket: Dictionary = token_list[auth_token]
	token_list.erase(auth_token) # Consume before yielding; replay cannot win.
	ticket.token = auth_token
	_pending_admissions[peer_id] = ticket
	# Disconnect at the transport layer: SceneMultiplayer.disconnect_peer
	# intentionally suppresses its local disconnect signals and skips cleanup.
	for old_peer: int in connected_players.keys():
		if connected_players[old_peer].account_name == ticket.account:
			peer.disconnect_peer(old_peer)
	# Let every instance's disconnect subscriber retire actors, intents and
	# checkpoints. WebSocket close may take more than one poll; never overlap
	# authority or wait beyond the native authentication deadline.
	var cleanup_deadline := mini(int(ticket.expires_at), Time.get_ticks_msec() + 2000)
	while true:
		await get_tree().process_frame
		if _pending_admissions.get(peer_id, {}).get("token", "") != auth_token: return
		if not inventory_master_available():
			_pending_admissions.erase(peer_id)
			peer.disconnect_peer(peer_id)
			return
		if Time.get_ticks_msec() >= cleanup_deadline or not multiplayer_api.get_authenticating_peers().has(peer_id):
			peer.disconnect_peer(peer_id)
			return
		var previous_owner := false
		for current: PlayerResource in connected_players.values():
			if current.account_name == ticket.account:
				previous_owner = true
				break
		if not previous_owner: break
	if multiplayer_api.complete_auth(peer_id) != OK:
		peer.disconnect_peer(peer_id)


func _publish_authenticated_state(peer_id: int, player: PlayerResource) -> void:
	data_push.rpc_id.call_deferred(peer_id, &"player_id.set", {"player_id": player.player_id})
	data_push.rpc_id.call_deferred(peer_id, &"active_guild_id.set", {"active_guild_id": player.active_guild_id})
	QuestService.backfill_wardstones(player)
	data_push.rpc_id.call_deferred(peer_id, &"wardstones.set", {"wardstones": player.wardstones})


func is_valid_authentication_token(auth_token: String) -> bool:
	if not inventory_master_available(): return false
	prune_handoff_tickets()
	return token_list.has(auth_token)


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
		var legacy: ServerInstance = instance as ServerInstance
		var actor: Player = legacy.players_by_peer_id.get(peer_id) if legacy != null else null
		if actor == null or actor.player_resource != player:
			return null
	return instance

## Initial 3D join must match both the current session and its server assignment.
## Standalone hosts use the same session-qualified pending assignment.
func can_join_map_instance(peer_id: int, instance: ServerInstance) -> bool:
	var player: PlayerResource = connected_players.get(peer_id)
	if peer_id<=1 or player==null or player.player_id<=0 or player.current_peer_id!=peer_id or player_id_to_peer_id.get(player.player_id,0)!=peer_id: return false
	if instance==null or not instance.awaiting_peers.has(peer_id) or instance.connected_peers.has(peer_id): return false
	if instance.awaiting_peers[peer_id].get("session")!=player: return false
	if instance.awaiting_peers[peer_id].has("transfer_attempt") and (instance_manager==null or not instance_manager.transfers.permits_join(peer_id,instance)): return false
	if instance_manager!=null:
		if instance_manager.get_instance_server_by_id(str(instance.name))!=instance or instance_manager.find_instance_for_peer(peer_id)!=null: return false
		if not instance_manager.has_valid_entry(instance,peer_id,player): return false
	return true


func dispatch_data_request(peer_id: int, type: StringName, args: Dictionary, instance_id: String = "") -> Dictionary:
	if instance_manager!=null and instance_manager.transfers.gated(peer_id):
		return {"ok":false,"error":ERR_BUSY}
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
