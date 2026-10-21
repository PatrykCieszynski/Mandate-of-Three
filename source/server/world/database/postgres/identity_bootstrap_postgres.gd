extends RefCounted
## Trusted Master identity -> PG mapping. Not exposed to client commands.
## Idempotent convergence after SQLite profile creation / uncertain COMMIT.
var db: Object
var committed:=false
var receipt_replay:=false
func _init(database: Object) -> void: db=database
## This milestone has exactly one profile/character-ID allocator per realm.
## A new/accidentally replaced profile must not alias existing PG character IDs.
func bind_profile(profile: String) -> Dictionary:
	if not ItemInstance.valid_uid(profile): return {"ok":false,"error":"profiles"}
	if db.in_transaction() or not db.begin(): return {"ok":false,"error":"storage"}
	if not db.execute("INSERT INTO economy.meta(key,value) VALUES('world_profile_id',:profile) ON CONFLICT DO NOTHING;",{"profile":profile}).ok: return _rollback("storage")
	var found: Dictionary=db.query("SELECT value FROM economy.meta WHERE key='world_profile_id';")
	if not found.ok: return _rollback("storage")
	if found.rows.size()!=1 or found.rows[0].value!=profile: return _rollback("profile_identity")
	if not db.commit():
		db.close();return {"ok":false,"error":"outcome_unknown"}
	committed=true
	return {"ok":true}

func bind(account: int, character: int) -> Dictionary:
	if account<=0 or character<=0: return {"ok":false,"error":"owner"}
	if db.in_transaction() or not db.begin(): return {"ok":false,"error":"storage"}
	for sql: String in [
		"INSERT INTO economy.accounts(account_id) VALUES(:account) ON CONFLICT DO NOTHING;",
		"SELECT account_id FROM economy.accounts WHERE account_id=:account FOR NO KEY UPDATE;",
		"INSERT INTO economy.account_wallets(account_id) VALUES(:account) ON CONFLICT DO NOTHING;",
		"INSERT INTO economy.characters(character_id,account_id) VALUES(:character,:account) ON CONFLICT DO NOTHING;"
	]:
		if not db.execute(sql,{"account":account,"character":character}).ok: return _rollback("storage")
	var found: Dictionary=db.query("SELECT account_id FROM economy.characters WHERE character_id=:character;",{"character":character})
	if not found.ok: return _rollback("storage")
	if found.rows.size()!=1 or int(found.rows[0].account_id)!=account: return _rollback("identity_conflict")
	if not db.commit():
		db.close() # No assumption that a failed COMMIT means rollback.
		return {"ok":false,"error":"outcome_unknown"}
	committed=true
	return {"ok":true}
func _rollback(reason: String) -> Dictionary:
	if not db.rollback(): db.close()
	return {"ok":false,"error":reason}
