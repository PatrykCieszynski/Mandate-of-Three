extends RefCounted
## Delegated Economy fence, NOT a login/token issuer. install_verified_grant is
## privileged control-plane input from the EXISTING Master session authority.
## World/client payloads must never be forwarded to it as proof of authority.
var db: Object
var committed:=false
var receipt_replay:=false

func _init(database: Object) -> void: db=database

static func identity_from_verified_ticket(account: int, character: int, master_token: String) -> Dictionary:
	if account<=0 or character<=0 or master_token.is_empty(): return {}
	return {"account_id":account,"character":character,"session_fingerprint":master_token.sha256_text()}

static func valid_identity(identity: Dictionary) -> bool:
	if not identity.get("account_id") is int or not identity.get("character") is int or not identity.get("session_fingerprint") is String: return false
	if identity.account_id<=0 or identity.character<=0 or identity.session_fingerprint.length()!=64: return false
	for letter: String in identity.session_fingerprint:
		if not "0123456789abcdef".contains(letter): return false
	return true

static func same_context(a: Dictionary, b: Dictionary) -> bool:
	return valid_identity(a) and valid_identity(b) and a.get("epoch") is int and b.get("epoch") is int and a.epoch>0 and a.account_id==b.account_id and a.character==b.character and a.session_fingerprint==b.session_fingerprint and a.epoch==b.epoch

## Caller holds the account lock. Empty context preserves legacy behavior ONLY
## when this optional projection has no registered grant for the account.
static func check_in_transaction(database: Object, account: int, character: int, context: Dictionary, require_ready: bool = true, allow_revoked: bool = false) -> String:
	var exists: Dictionary=database.query("SELECT CASE WHEN to_regclass('economy.inventory_sessions') IS NULL THEN 0 ELSE 1 END AS present;")
	if not exists.ok: return "storage"
	if int(exists.rows[0].present)==0: return "" if context.is_empty() else "session_required"
	var found: Dictionary=database.query("SELECT * FROM economy.inventory_sessions WHERE account_id=:account;",{"account":account})
	if not found.ok: return "storage"
	if found.rows.is_empty(): return "" if context.is_empty() else "stale_session"
	if context.is_empty(): return "session_required"
	var row: Dictionary=found.rows[0]
	if not valid_identity(context) or not context.get("epoch") is int or context.epoch<=0: return "stale_session"
	if int(row.account_id)!=int(context.account_id) or int(row.character_id)!=character or character!=int(context.character) or int(row.epoch)!=int(context.epoch) or str(row.session_fingerprint)!=str(context.session_fingerprint): return "stale_session"
	if row.phase=="revoked" and not allow_revoked: return "stale_session"
	if require_ready and row.phase!="ready": return "recovery_required"
	return ""

func _begin(identity: Dictionary) -> Dictionary:
	if not valid_identity(identity): return {"ok":false,"error":"request"}
	if db.in_transaction() or not db.begin(): return {"ok":false,"error":"storage"}
	var found: Dictionary=db.query("SELECT account_id FROM economy.accounts WHERE account_id=:account FOR NO KEY UPDATE;",{"account":identity.account_id})
	if not found.ok: return _rollback("storage")
	if found.rows.is_empty(): return _rollback("owner")
	found=db.query("SELECT account_id FROM economy.characters WHERE character_id=:character;",{"character":identity.character})
	if not found.ok: return _rollback("storage")
	if found.rows.is_empty() or int(found.rows[0].account_id)!=int(identity.account_id): return _rollback("owner")
	return {"ok":true}

func begin_context(context: Dictionary, require_ready: bool = false, allow_revoked: bool = false) -> Dictionary:
	var begun:=_begin(context)
	if not begun.ok: return begun
	var reason:=check_in_transaction(db,int(context.account_id),int(context.character),context,require_ready,allow_revoked)
	if not reason.is_empty(): return _rollback(reason)
	return {"ok":true} # Explicit transaction composition; caller must commit/rollback.

func install_verified_grant(identity: Dictionary, expected_epoch: int) -> Dictionary:
	if expected_epoch<0: return {"ok":false,"error":"request"}
	var begun:=_begin(identity)
	if not begun.ok: return begun
	var found: Dictionary=db.query("SELECT * FROM economy.inventory_sessions WHERE account_id=:account;",{"account":identity.account_id})
	if not found.ok: return _rollback("storage")
	var epoch: int=0
	if not found.rows.is_empty():
		var row: Dictionary=found.rows[0]
		epoch=int(row.epoch)
		if int(row.character_id)==int(identity.character) and str(row.session_fingerprint)==str(identity.session_fingerprint):
			if row.phase=="revoked": return _rollback("stale_session")
			if expected_epoch not in [epoch,epoch-1]: return _rollback("epoch_conflict")
			return _finish({"ok":true,"context":_context(row),"phase":row.phase})
	if epoch!=expected_epoch or epoch==9223372036854775807: return _rollback("epoch_conflict")
	var updated: Dictionary=db.query("INSERT INTO economy.inventory_sessions(account_id,character_id,epoch,session_fingerprint,phase) VALUES(:account,:character,:epoch,:fingerprint,'recovering') ON CONFLICT(account_id) DO UPDATE SET character_id=EXCLUDED.character_id,epoch=EXCLUDED.epoch,session_fingerprint=EXCLUDED.session_fingerprint,phase='recovering' RETURNING *;",{"account":identity.account_id,"character":identity.character,"epoch":epoch+1,"fingerprint":identity.session_fingerprint})
	if not updated.ok: return _rollback("storage")
	return _finish({"ok":true,"context":_context(updated.rows[0]),"phase":"recovering"})

## Privileged issuer recovery/read, never a client session lookup. Account lock
## orders inspection after an earlier uncertain grant/revoke attempt.
func inspect_grant(identity: Dictionary) -> Dictionary:
	var begun:=_begin(identity)
	if not begun.ok: return begun
	var found: Dictionary=db.query("SELECT * FROM economy.inventory_sessions WHERE account_id=:account;",{"account":identity.account_id})
	if not found.ok: return _rollback("storage")
	return _finish({"ok":true,"context":{} if found.rows.is_empty() else _context(found.rows[0]),"phase":"absent" if found.rows.is_empty() else str(found.rows[0].phase)})

func revoke(context: Dictionary) -> Dictionary:
	var begun:=begin_context(context,false,true)
	if not begun.ok: return begun
	if not db.execute("UPDATE economy.inventory_sessions SET phase='revoked' WHERE account_id=:account;",{"account":context.account_id}).ok: return _rollback("storage")
	return _finish({"ok":true})

func finish_recovery(context: Dictionary, applied_item_state: Dictionary) -> Dictionary:
	var begun:=begin_context(context)
	if not begun.ok: return begun
	var pending: Dictionary=db.query("SELECT COUNT(*) AS n FROM economy.inventory_intents WHERE account_id=:account AND state='pending';",{"account":context.account_id})
	if not pending.ok: return _rollback("storage")
	if int(pending.rows[0].n)>0: return _rollback("operations_pending")
	var current: Dictionary=db.query("SELECT COALESCE(r.revision,0) AS revision,m.value AS authority_id FROM economy.meta m LEFT JOIN economy.account_item_revisions r ON r.account_id=:account WHERE m.key='economy_authority_id';",{"account":context.account_id})
	if not current.ok or current.rows.is_empty(): return _rollback("storage")
	var marker:=applied_item_state
	if marker.get("account_id")!=context.account_id or marker.get("character_id")!=context.character or marker.get("authority_id")!=str(current.rows[0].authority_id) or marker.get("revision")!=int(current.rows[0].revision): return _rollback("stale_snapshot")
	if not db.execute("UPDATE economy.inventory_sessions SET phase='ready' WHERE account_id=:account;",{"account":context.account_id}).ok: return _rollback("storage")
	return _finish({"ok":true,"phase":"ready"})

func _context(row: Dictionary) -> Dictionary:
	return {"account_id":int(row.account_id),"character":int(row.character_id),"epoch":int(row.epoch),"session_fingerprint":str(row.session_fingerprint)}

func _finish(result: Dictionary) -> Dictionary:
	if not db.commit():
		db.close()
		return {"ok":false,"error":"outcome_unknown","outcome_unknown":true}
	return result

func _rollback(reason: String) -> Dictionary:
	if not db.rollback():
		db.close()
		return {"ok":false,"error":"storage"}
	return {"ok":false,"error":reason}
