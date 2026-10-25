extends RefCounted
## One native transaction owns currency, target and frozen receipt outcome.
const Commands=preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Items=preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Wallet=preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const Rules=preload("res://source/common/gameplay/items/crafting/crafting_rules.gd")
var db: Object
var _transaction: RefCounted
var income_token: String=""
var committed: bool:
	get: return _transaction.committed
var receipt_replay: bool:
	get: return _transaction.receipt_replay
func _init(database: Object) -> void:
	db=database;_transaction=Commands.new(db)
func authorize_session(context: Dictionary, token: String) -> void:
	_transaction.economic_context=context.duplicate(true);income_token=token
func execute(owner: int, pending: int, uid: String, revision: int, currency_uid: String, currency_revision: int, id: String) -> Dictionary:
	if not ItemInstance.valid_uid(uid) or not ItemInstance.valid_uid(currency_uid) or uid==currency_uid or revision<0 or currency_revision<0: return {"ok":false,"error":"request"}
	# Fresh server entropy once for this execution, stable across known-aborted
	# serialization retries. Never seeded from client-controlled ID or item UID.
	var rng:=RandomNumberGenerator.new()
	rng.seed=int(Crypto.new().generate_random_bytes(8).decode_s64(0))
	return _transaction.run_with_retry(_once.bind(owner,pending,uid,revision,currency_uid,currency_revision,id,rng.seed))
func _once(owner: int, pending: int, uid: String, revision: int, currency_uid: String, currency_revision: int, id: String, seed_value: int) -> Dictionary:
	if not _transaction.begin(owner,id,"craft",[owner,uid,revision,currency_uid,currency_revision],true): return _transaction.cached
	var found: Dictionary=db.query(Items.ITEM_SELECT+"WHERE i.uid IN (:target,:currency) AND i.owner_character_id=:owner AND c.owner_id=:owner AND c.location='bag' ORDER BY i.uid;",{"target":uid,"currency":currency_uid,"owner":owner})
	if not found.ok or found.truncated: return _transaction.rollback("storage")
	if found.rows.size()!=2: return _transaction.rollback("owner")
	var target: ItemInstance;var currency: ItemInstance
	for row: Dictionary in found.rows:
		var item:=ItemInstance.from_row(row)
		if item==null: return _transaction.rollback("invalid_item")
		if item.uid==uid: target=item
		else: currency=item
	if target.revision!=revision or currency.revision!=currency_revision: return _transaction.rollback("stale")
	if not Rules.CURRENCIES.has(str(currency.definition_id)) or currency.upgrade_level!=0 or not currency.affixes.is_empty() or not currency.sockets.is_empty(): return _transaction.rollback("material")
	var rng:=RandomNumberGenerator.new();rng.seed=seed_value
	var outcome:=Rules.resolve(target,str(currency.definition_id),rng)
	if not outcome.ok: return _transaction.rollback(str(outcome.error))
	# Capture the same pending wallet prefix as the existing NPC lane, even
	# though these consumable actions have no Yang price.
	var spent:=Wallet.new(db).capture_income_in_transaction(_transaction.account_id,pending)
	if not spent.ok: return _transaction.rollback(str(spent.error))
	var changed: Dictionary
	if currency.amount==1:
		changed=db.execute("DELETE FROM economy.item_custody WHERE uid=:uid AND owner_id=:owner AND location='bag';",{"uid":currency_uid,"owner":owner})
		if not changed.ok or int(changed.affected_rows)!=1: return _transaction.rollback("storage")
		changed=db.execute("DELETE FROM economy.item_instances WHERE uid=:uid AND owner_character_id=:owner AND revision=:revision;",{"uid":currency_uid,"owner":owner,"revision":currency_revision})
	else:
		changed=db.execute("UPDATE economy.item_instances SET amount=amount-1,revision=revision+1 WHERE uid=:uid AND owner_character_id=:owner AND revision=:revision;",{"uid":currency_uid,"owner":owner,"revision":currency_revision})
	if not changed.ok or int(changed.affected_rows)!=1: return _transaction.rollback("storage")
	changed=db.execute("UPDATE economy.item_instances SET rarity=:rarity,affixes_json=:affixes,revision=revision+1 WHERE uid=:uid AND owner_character_id=:owner AND revision=:revision;",{"uid":uid,"owner":owner,"revision":revision,"rarity":outcome.rarity,"affixes":JSON.stringify(outcome.affixes)})
	if not changed.ok: return _transaction.rollback("storage")
	if int(changed.affected_rows)!=1: return _transaction.rollback("stale")
	var response: Dictionary={"ok":true,"uid":uid,"revision":revision+1,"rarity":outcome.rarity,"affixes":outcome.affixes,"wallet_states":[spent.wallet_state],"balance":spent.balance}
	if not income_token.is_empty(): response.income_token=income_token
	return _transaction.commit(response)
