extends RefCounted
## One Master owns the in-memory account directory. IDs are allocated in PG.
## Failed writes never publish credentials in RAM or silently save a .tres file.
var db: Object
var _saved: Dictionary={}

func _init(database: Object) -> void: db=database

func load_accounts() -> AccountResourceCollection:
	var result: Dictionary=db.query("SELECT account_name,master_account_id,password_hash,last_world_name,last_character_id FROM realm.accounts;",{},100000)
	if not result.ok or result.get("truncated",false): return null
	var collection:=AccountResourceCollection.new()
	for row: Dictionary in result.rows:
		var account:=AccountResource.new()
		account.init(int(row.master_account_id),str(row.account_name),str(row.password_hash))
		account.last_world_name=str(row.last_world_name)
		account.last_character_id=int(row.last_character_id)
		collection.collection[account.username]=account
		_saved[account.id]=_fields(account)
	return collection

func create(username: String, password: String, guest: bool) -> AccountResource:
	if not db.begin(): return null
	var next: Dictionary=db.query("SELECT nextval('realm.account_ids') AS id;")
	if not next.ok: return _reject()
	var id: int=int(next.rows[0].id)
	if guest: username="guest%d" % id
	var account:=AccountResource.new()
	account.init(id,username,PasswordHasher.hash_password(password))
	var result: Dictionary=db.execute("INSERT INTO realm.accounts(account_name,master_account_id,password_hash) VALUES(:name,:id,:password);",{"name":username,"id":id,"password":account.password})
	if not result.ok: return _reject()
	if not db.commit():
		# COMMIT unknown: do not claim success or retry creation automatically.
		db.close();return null
	_saved[id]=_fields(account)
	return account

func _reject() -> AccountResource:
	if not db.rollback(): db.close()
	return null

func _fields(account: AccountResource) -> Array:
	return [account.username,account.password,account.last_world_name,account.last_character_id]

func checkpoint(collection: AccountResourceCollection) -> bool:
	var changed: Array[AccountResource]=[]
	for account: AccountResource in collection.collection.values():
		if _saved.get(account.id,[])!=_fields(account): changed.append(account)
	if changed.is_empty(): return true
	if not db.begin(): return false
	for account: AccountResource in changed:
		var result: Dictionary=db.execute("UPDATE realm.accounts SET password_hash=:password,last_world_name=:world,last_character_id=:character WHERE master_account_id=:id AND account_name=:name;",{"password":account.password,"world":account.last_world_name,"character":account.last_character_id,"id":account.id,"name":account.username})
		if not result.ok or int(result.affected_rows)!=1:
			if not db.rollback(): db.close()
			return false
	if not db.commit():
		db.close();return false
	for account: AccountResource in changed: _saved[account.id]=_fields(account)
	return true
