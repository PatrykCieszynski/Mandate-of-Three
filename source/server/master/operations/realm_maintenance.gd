extends RefCounted
## One process-local operator barrier. Not an economic receipt or backup proof.
## Closed admissions are sticky until process restart; ambiguous results never
## authorize reopening, force-joining workers, or declaring a coherent backup.
var master: WorldManagerServer
var operation_id: String
var phase: String="WORLD_DRAIN"
var error: String=""
var world_id: int
var deadline: int
var _finishing:=false
func _init(owner: WorldManagerServer, id: String, target: int) -> void:
	master=owner;operation_id=id;world_id=target
	deadline=Time.get_ticks_msec()+30000
func status() -> Dictionary:
	return {"operation_id":operation_id,"phase":phase,"error":error,"admissions_open":false,"quiesced":phase=="QUIESCED"}
func poll(now: int = -1) -> void:
	if now<0: now=Time.get_ticks_msec()
	if phase!="WORLD_DRAIN": return
	if not master.connected_worlds.has(world_id):
		_block("world_disconnected")
	elif now>=deadline: _block("world_timeout")
func acknowledge(sender: int, id: String, result: Dictionary) -> bool:
	if phase!="WORLD_DRAIN" or sender!=world_id or id!=operation_id: return false
	for key: String in ["ok","profiles_closed","workers_stopped"]:
		if not result.get(key) is bool or not result[key]:
			_block("world_unresolved");return true
	phase="MASTER_DRAIN"
	_finish()
	return true
func _finish() -> void:
	if _finishing: return
	_finishing=true
	if not await master.economy_bootstrap.shutdown_master():
		_block("master_unresolved");return
	if not master.authentication_manager.checkpoint_accounts(true):
		_block("accounts_checkpoint");return
	phase="QUIESCED"
func _block(reason: String) -> void:
	phase="BLOCKED";error=reason
