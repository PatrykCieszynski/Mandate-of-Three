class_name AuctionSociReader
extends RefCounted
## Only this adapter knows the native addon. The writer never enters its worker.
const EXTENSION := "res://addons/godot_soci/soci.gdextension"
var dispatcher: Object
var ready := false

func start(path: String) -> bool:
	if dispatcher != null: return false
	path = ProjectSettings.globalize_path(path).replace("\\", "/")
	if not FileAccess.file_exists(path) or "'" in path or "\n" in path: return false
	if not ClassDB.class_exists("SociQueryDispatcher"):
		if GDExtensionManager.load_extension(EXTENSION) != GDExtensionManager.LOAD_STATUS_OK: return false
	dispatcher = ClassDB.instantiate("SociQueryDispatcher")
	if not dispatcher.start("sqlite3", "dbname='"+path+"' readonly=true timeout=1", 1):
		dispatcher = null; return false
	var request: Object = dispatcher.execute_async("PRAGMA query_only=ON;")
	if request == null: return false
	if not request.is_done(): await request.completed
	if not request.get_result().ok: return false
	var version: Dictionary = await query("SELECT value FROM meta WHERE key='schema_version';", {}, 1)
	var journal: Dictionary = await query("PRAGMA journal_mode;", {}, 1)
	ready = version.ok and version.rows.size()==1 and int(version.rows[0].value)>=MarketSearchSqlite.LOOKUP_SCHEMA_VERSION and journal.ok and journal.rows.size()==1 and journal.rows[0].journal_mode=="wal"
	return ready

func query(sql: String, params: Dictionary, max_rows: int) -> Dictionary:
	if dispatcher == null: return {"ok":false,"error":"storage"}
	var request: Object = dispatcher.query_async(sql, params, max_rows)
	if request == null: return {"ok":false,"error":"storage"}
	if not request.is_done(): await request.completed
	return request.get_result()

func poll() -> void:
	if dispatcher != null: dispatcher.poll(1)

func pending() -> int:
	return 0 if dispatcher == null else int(dispatcher.pending())

func stop_if_idle() -> bool:
	ready = false
	if pending()!=0: return false
	if dispatcher != null: dispatcher.stop(); dispatcher = null
	return true
