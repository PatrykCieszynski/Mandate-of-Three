extends RefCounted
## D0 ONLY: one-slot thread/SQLite proof, not the production dispatcher or queue.
var _thread := Thread.new()
var _mutex := Mutex.new()
var _wake := Semaphore.new()
var _hold := Semaphore.new()
var _path := ""
var _plugin_vfs := false
var _stop := false
var _pause := false
var _state := "new"
var _info: Dictionary = {}
var _job: Dictionary = {}
var _result: Dictionary = {}

func start(path: String, plugin_vfs: bool = false) -> Error:
	if _thread.is_started(): return ERR_ALREADY_IN_USE
	_path=path;_plugin_vfs=plugin_vfs;_stop=false;_pause=false
	_state="starting";_info={};_job={};_result={}
	_wake=Semaphore.new();_hold=Semaphore.new()
	return _thread.start(_run)

func status() -> Dictionary:
	_mutex.lock()
	var view:=_info.duplicate(true);view.state=_state
	_mutex.unlock()
	return view

func submit(sql: String, args: Array = [], repeats: int = 1, hold_snapshot: bool = false) -> bool:
	_mutex.lock()
	var accepted:=_state=="idle" and _result.is_empty() and not _stop and not _pause and repeats>=1 and repeats<=8
	if accepted:
		_job={"sql":sql,"args":args.duplicate(true),"repeats":repeats,"hold":hold_snapshot}
		_state="queued"
	_mutex.unlock()
	if accepted: _wake.post()
	return accepted

func take_result() -> Dictionary:
	_mutex.lock()
	var result:=_result;_result={}
	_mutex.unlock()
	return result

func request_pause() -> void:
	_mutex.lock();_pause=true;_mutex.unlock();_wake.post()

func resume() -> void:
	_mutex.lock();_pause=false;_mutex.unlock();_wake.post()

func release_hold() -> void: _hold.post()

func request_stop() -> void:
	_mutex.lock();_stop=true;_mutex.unlock()
	_hold.post();_wake.post()

func join_if_finished() -> bool:
	if _thread.is_alive(): return false
	if _thread.is_started(): _thread.wait_to_finish()
	return true

func emergency_stop() -> void:
	request_stop()
	if _thread.is_started(): _thread.wait_to_finish()

func _publish(state: String, info: Dictionary = {}) -> void:
	_mutex.lock();_state=state;_info.merge(info,true);_mutex.unlock()

func _open() -> SQLite:
	# Creation, all use, close and last SQLite reference release happen here.
	var reader:=SQLite.new()
	reader.path=_path;reader.default_extension="";reader.read_only=_plugin_vfs
	reader.verbosity_level=SQLite.VerbosityLevel.QUIET
	if not reader.open_db():
		_publish("failed",{"error":reader.error_message,"stage":"open","closed":reader.close_db(),"close_thread_id":OS.get_thread_caller_id()})
		return null
	if not reader.query("PRAGMA query_only=ON; SELECT value FROM meta WHERE key='schema_version';"):
		_publish("failed",{"error":reader.error_message,"stage":"schema_read","closed":reader.close_db()})
		return null
	var schema:=int(reader.query_result[0].value)
	var proofs: Dictionary={}
	for sql: String in ["INSERT INTO meta(key,value) VALUES('d0_forbidden','1');","UPDATE meta SET value=value WHERE key='schema_version';","CREATE TABLE d0_forbidden_table(value INTEGER);"]:
		var denied:=not reader.query(sql)
		proofs[sql]=denied and "readonly" in reader.error_message.to_lower()
	# Native mode=ro must remain read-only even without the additional PRAGMA.
	if not reader.query("PRAGMA query_only=OFF;"): return _open_failure(reader)
	proofs.native_read_only=not reader.query("INSERT INTO meta(key,value) VALUES('d0_forbidden','2');") and "readonly" in reader.error_message.to_lower()
	if not reader.query("PRAGMA query_only=ON; PRAGMA compile_options;"): return _open_failure(reader)
	var options:=reader.query_result.duplicate(true)
	if not reader.query("SELECT sqlite_version() AS version;"): return _open_failure(reader)
	var version: String=reader.query_result[0].version
	if not reader.query("PRAGMA journal_mode;"): return _open_failure(reader)
	var journal: String=reader.query_result[0].journal_mode
	if not proofs.values().all(func(value: bool)->bool:return value):
		_publish("failed",{"error":"read_only_proof","closed":reader.close_db()});return null
	_publish("idle",{"schema":schema,"journal":journal,"sqlite":version,"options":options,"proofs":proofs,"connection_instance":reader.get_instance_id(),"thread_id":OS.get_thread_caller_id(),"closed":false})
	return reader

func _open_failure(reader: SQLite) -> SQLite:
	_publish("failed",{"error":reader.error_message,"stage":"configuration","closed":reader.close_db()})
	return null

func _run() -> void:
	var reader:=_open()
	if reader==null: return
	while true:
		_wake.wait()
		_mutex.lock()
		var stopping:=_stop;var pausing:=_pause
		var job:=_job;_job={}
		_mutex.unlock()
		if stopping:
			var closed:=reader.close_db() if reader!=null else true
			reader=null
			_publish("stopped",{"closed":closed,"close_thread_id":OS.get_thread_caller_id()})
			return
		if pausing and job.is_empty():
			var closed:=reader.close_db() if reader!=null else true
			reader=null
			_publish("paused",{"closed":closed,"close_thread_id":OS.get_thread_caller_id()})
			continue
		if reader==null:
			reader=_open()
			if reader==null: return
		if job.is_empty(): continue
		_publish("busy")
		var rows: Array=[];var timings: Array=[];var error:=""
		if job.hold and not reader.query("BEGIN;"): error=reader.error_message
		if error.is_empty():
			for iteration: int in int(job.repeats):
				var started:=Time.get_ticks_usec()
				var ok:=reader.query_with_bindings(job.sql,job.args)
				timings.append({"start":started,"end":Time.get_ticks_usec()})
				if not ok: error=reader.error_message;break
				rows=reader.query_result.duplicate(true)
		if job.hold:
			_publish("holding")
			_hold.wait() # Controlled test barrier: deliberately retain a WAL snapshot.
			if not reader.query("ROLLBACK;"): error=reader.error_message
		_mutex.lock()
		_result={"ok":error.is_empty(),"error":error,"rows":rows,"timings":timings,"thread_id":OS.get_thread_caller_id()}
		_state="idle"
		_mutex.unlock()
