extends RefCounted
## One explicit owner for preflight, composition and orderly native pool closure.
## This is NOT provisioning, identity import or the normal process backend selector.
const Settings = preload("res://source/server/world/database/postgres/economy_bootstrap_settings.gd")
const Executor = preload("res://source/server/world/database/postgres/inventory_executor_postgres.gd")
enum State { NEW = 0, STARTING = 1, READY = 2, DRAINING = 3, STOPPED = 4, FAILED = 5, BLOCKED = 6 }
var state: State=State.NEW
var error: String=""
var _world: WorldServer
var _master: WorldManagerServer
var _pools: Dictionary={}
var _settings: Dictionary={}
const WORLD_POOLS: Dictionary={"inventory":2,"wallet":1,"npc":1,"storage":1,"ground":1,"market":2}

func stopped() -> bool: return state==State.STOPPED
func authority_id() -> String: return str(_settings.get("authority_id",""))
func ready() -> bool: return state==State.READY
func sessions_valid() -> bool: return state in [State.READY,State.DRAINING,State.BLOCKED]
func status() -> Dictionary:
	var pending: int=0
	var ready_workers: int=0
	for key: String in _pools:
		var pool: RefCounted=_pools[key]
		pending+=pool.pending_count()
		if pool.is_ready(): ready_workers+=WORLD_POOLS.get(key,1)
	var unsettled: Array[String]=[]
	if _world!=null:
		var domains: Dictionary={"wallet":_world.wallet_runtime,"npc":_world.npc_runtime,"storage":_world.storage_runtime,"ground":_world.ground_item_runtime,"market":_world.seller_runtime}
		for key: String in domains:
			if domains[key]!=null and not domains[key].drained(): unsettled.append(key)
	return {"unsettled_domains":unsettled,"database_probe":false,"state":State.keys()[state],"error":error,"pools":_pools.size(),"workers":(8 if _world!=null else 1) if ready() else 0,"workers_ready":ready_workers,"pending":pending,"ready":ready(),"stopped":_pools.values().all(func(pool: RefCounted)->bool:return pool.is_stopped())}

func start_world(world: WorldServer, settings: Dictionary) -> bool:
	if state!=State.NEW or world==null or not world.is_inside_tree() or world.database==null or world.economy_bootstrap!=null or world.inventory_runtime!=null or world.wallet_runtime!=null or world.npc_runtime!=null or world.storage_runtime!=null or world.ground_item_runtime!=null or world.seller_runtime!=null or not world.connected_players.is_empty(): return false
	if world.database!=null and not world.database.dirty_wallet.is_empty(): return false # No hot switch with unsaved SQLite money.
	_world=world
	world.economy_bootstrap=self # Selection is sticky, including a failed startup.
	if world.database!=null:
		world.database.economy_backend="postgresql"
		world.database.wallet_ready=false
		world.database.runtime_wallets.clear()
		if world.database.store!=null: world.database.store.economic_initialization=false
	if not await _prepare(settings,"inventory",2): return false
	if settings.has("profile_id"):
		if not world.database.profile_store_ready(): return await _failed("profiles")
		var queued: Dictionary=_pools.inventory.submit_profile_binding(str(settings.profile_id))
		if not queued.queued: return await _failed("profiles")
		var result: Dictionary={}
		while result.is_empty():
			for event: Dictionary in _pools.inventory.poll():
				if event.ticket==queued.ticket: result=event.result
			if not _pools.inventory.is_ready(): return await _failed("workers")
			if result.is_empty(): await _tree().process_frame
		if not result.get("ok",false): return await _failed(str(result.get("error","profiles")))
		ServerLog.info("PostgreSQL realm/profile binding ready.")
	for name: String in WORLD_POOLS:
		if name!="inventory" and not _start_pool(name,WORLD_POOLS[name]): return await _failed("workers")
	if not await _wait_ready(): return await _failed("workers")
	if not world.database.profile_store_ready(): return await _failed("profiles")
	world.inventory_runtime=preload("res://source/server/world/database/postgres/inventory_runtime_postgres.gd").new(world,_pools.inventory)
	world.inventory_runtime.enable_initialization()
	world.wallet_runtime=preload("res://source/server/world/database/postgres/wallet_runtime_postgres.gd").new(world,_pools.wallet)
	world.npc_runtime=preload("res://source/server/world/database/postgres/npc_runtime_postgres.gd").new(world.wallet_runtime,world.inventory_runtime,_pools.npc)
	world.storage_runtime=preload("res://source/server/world/database/postgres/storage_runtime_postgres.gd").new(world.inventory_runtime,_pools.storage)
	world.ground_item_runtime=preload("res://source/server/world/database/postgres/ground_item_runtime_postgres.gd").new(world.inventory_runtime,_pools.ground)
	world.seller_runtime=preload("res://source/server/world/database/postgres/seller_runtime_postgres.gd").new(world.inventory_runtime,_pools.market,world.wallet_runtime,true,true,true)
	state=State.READY
	if world.database!=null: world.database.wallet_ready=true
	return true

func start_master(master: WorldManagerServer, settings: Dictionary) -> bool:
	if state!=State.NEW or master==null or not master.is_inside_tree() or master.economy_bootstrap!=null or master.inventory_session_issuer!=null or not master.connected_worlds.is_empty(): return false
	_master=master
	master.economy_bootstrap=self
	if not await _prepare(settings,"control",1): return false
	master.inventory_session_issuer=preload("res://source/server/master/components/master_world_server/inventory_session_issuer_postgres.gd").new(master,_pools.control)
	state=State.READY
	return true

func _tree() -> SceneTree: return _world.get_tree() if _world!=null else _master.get_tree()

func _prepare(settings: Dictionary, first: String, workers: int) -> bool:
	state=State.STARTING
	_settings=Settings.resolve(settings)
	if not _settings.ok or _settings.get("backend","")!="postgresql": return await _failed(str(_settings.get("error","backend")))
	if not _start_pool(first,workers) or not await _wait_ready(): return await _failed("workers")
	var pool: RefCounted=_pools[first]
	var queued: Dictionary=pool.submit_economy_preflight(_settings.authority_id)
	if not queued.queued: return await _failed("preflight")
	while true:
		for event: Dictionary in pool.poll():
			if event.ticket==queued.ticket:
				if not event.result.get("ok",false): return await _failed(str(event.result.get("error","preflight")))
				return true
		if not pool.is_ready(): return await _failed("workers")
		await _tree().process_frame
	return false

func _start_pool(name: String, workers: int) -> bool:
	var pool:=Executor.new()
	_pools[name]=pool
	# Credentials are passed directly to native owners; never stored in status/world_info.
	return pool.start(OS.get_environment(_settings.connection_env)+" connect_timeout=3",workers,_settings.queue_capacity)

func _wait_ready() -> bool:
	while true:
		var complete:=true
		for pool: RefCounted in _pools.values():
			pool.poll()
			if pool.startup_error!="" or pool.is_stopped(): return false
			complete=complete and pool.is_ready()
		if complete: return true
		await _tree().process_frame
	return false

func _failed(reason: String) -> bool:
	error=reason
	state=State.DRAINING
	for pool: RefCounted in _pools.values(): pool.begin_drain()
	await _close_pools()
	state=State.FAILED
	return false

func _close_pools() -> void:
	while not _pools.values().all(func(pool: RefCounted)->bool:return pool.is_stopped()):
		if _world==null or _world.inventory_runtime==null:
			for pool: RefCounted in _pools.values(): pool.poll()
		await _tree().process_frame

## Called by normal owner polling, not a SQL health probe. A dead worker closes
## admissions; unresolved economic results remain with their existing owners.
func check_health() -> void:
	if not ready(): return
	if _pools.values().any(func(pool: RefCounted)->bool:return not pool.is_ready()):
		state=State.BLOCKED;error="workers"
		if _world!=null:
			if _world.database!=null: _world.database.wallet_ready=false
			_world.invalidate_inventory_admissions()

func shutdown_world() -> bool:
	if _world!=null and state==State.FAILED and status().stopped: return true
	if _world==null or state not in [State.READY,State.BLOCKED,State.DRAINING]: return false
	state=State.DRAINING
	if _world.database!=null: _world.database.wallet_ready=false
	_world.token_list.clear()
	_world._pending_admissions.clear()
	_world.inventory_runtime.begin_drain()
	if not await _world.flush_postgres_wallets(true):
		state=State.BLOCKED;error="unresolved"
		return false
	_world.invalidate_inventory_admissions() # Delivery/reconciliation finished before detachment.
	# Domain owners already drained their pools. Inventory detach keeps durable
	# admissions recoverable; finish all its accepted SQL before closing/joining.
	for pool: RefCounted in _pools.values(): pool.begin_drain()
	await _close_pools()
	state=State.STOPPED
	return true

func shutdown_master() -> bool:
	if _master!=null and stopped(): return true
	if _master!=null and state==State.FAILED and status().stopped: return true
	if _master==null or state not in [State.READY,State.BLOCKED,State.DRAINING]: return false
	state=State.DRAINING
	for username: String in _master._world_sessions.keys(): _master.revoke_world_session(username)
	var issuer: RefCounted=_master.inventory_session_issuer
	issuer.begin_drain()
	var deadline:=Time.get_ticks_msec()+8000
	while not issuer.drained() and Time.get_ticks_msec()<deadline: await _tree().process_frame
	if not issuer.drained():
		state=State.BLOCKED;error="unresolved"
		return false
	for pool: RefCounted in _pools.values(): pool.begin_drain()
	await _close_pools()
	state=State.STOPPED
	return true
