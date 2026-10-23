extends RefCounted
## One account lock/session owns validation, consumption, random rewards,
## captured income, receipt and COMMIT. Only server-held quote bodies enter here.
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
var db: Object
var transaction: RefCounted
var income_token: String=""
var committed: bool:
	get: return transaction.committed
var receipt_replay: bool:
	get: return transaction.receipt_replay

func _init(database: Object) -> void:
	db=database;transaction=Commands.new(db)

func authorize_session(context: Dictionary, token: String) -> void:
	transaction.economic_context=context.duplicate(true);income_token=token

func sell(owner: int, pending: int, quote: Dictionary, id: String) -> Dictionary:
	return transaction.run_with_retry(_once.bind(owner,pending,quote.duplicate(true),id))

func _once(owner: int, pending: int, quote: Dictionary, id: String) -> Dictionary:
	if not quote.has_all(["quote_id","lines","version","plan","expires_at","npc","service"]): return {"ok":false,"error":"request"}
	var lines:=VendorResolver.cart(quote.lines)
	if lines.is_empty(): return {"ok":false,"error":"request"}
	# Receipt precedes expiry/custody/randomness: exact replay remains possible
	# after consumed UIDs disappear or a successful quote expires.
	if not transaction.begin(owner,id,"vendor.sell",[owner,quote.quote_id,quote.npc,quote.service,quote.version,lines],true): return transaction.cached
	if int(Time.get_unix_time_from_system())>=int(quote.expires_at): return transaction.rollback("quote_expired")
	if quote.version!=VendorRecipes.version(): return transaction.rollback("quote_stale")
	var rows: Array=[]
	for line: Dictionary in lines:
		var found: Dictionary=db.query(Items.ITEM_SELECT+"WHERE i.uid=:uid AND i.owner_character_id=:owner AND c.owner_id=:owner AND c.location='bag' FOR UPDATE OF i,c;",{"uid":line.uid,"owner":owner})
		if not found.ok: return transaction.rollback("storage")
		if found.rows.is_empty(): return transaction.rollback("owner")
		var item:=ItemInstance.from_row(found.rows[0])
		if item==null or item.owner_character_id!=owner: return transaction.rollback("owner")
		rows.append(item.to_snapshot())
	var plan:=VendorResolver.resolve(lines,rows,VendorRecipes.definitions(),VendorRecipes.pools())
	if not plan.ok: return transaction.rollback(str(plan.error))
	if plan!=quote.plan: return transaction.rollback("quote_stale")
	var funds: Dictionary=Wallet.new(db).load_wallet(transaction.account_id)
	if not funds.ok: return transaction.rollback(str(funds.error))
	var room: int=Wallet.MAX_YANG-int(funds.balance)
	if pending<0 or pending>room or int(plan.yang)>room-pending: return transaction.rollback("overflow")
	# Free consumed footprints first; failed placement or any later statement
	# rolls the entire basket back, including partial stacks and Yang.
	for line: Dictionary in lines:
		var row: Dictionary=rows.filter(func(item: Dictionary)->bool:return item.uid==line.uid)[0]
		var changed: Dictionary
		if row.amount==line.amount:
			changed=db.execute("DELETE FROM economy.item_custody WHERE uid=:uid AND location='bag' AND owner_id=:owner;",{"uid":line.uid,"owner":owner})
			if not changed.ok or int(changed.affected_rows)!=1: return transaction.rollback("storage")
			changed=db.execute("DELETE FROM economy.item_instances WHERE uid=:uid AND revision=:revision;",{"uid":line.uid,"revision":line.revision})
		else:
			changed=db.execute("UPDATE economy.item_instances SET amount=amount-:amount,revision=revision+1 WHERE uid=:uid AND revision=:revision;",line)
		if not changed.ok or int(changed.affected_rows)!=1: return transaction.rollback("storage")
	var rewards: Array=[]
	var crypto:=Crypto.new()
	var pools:=VendorRecipes.pools()
	for reward: Dictionary in plan.rewards:
		var pool: Array=pools[reward.pool].items
		if pool.is_empty(): return transaction.rollback("invalid_definition")
		for index: int in int(reward.quantity):
			# Rejection sampling avoids modulo bias; quote never generates this.
			var bound: int=4294967296-(4294967296%pool.size())
			var draw: int=crypto.generate_random_bytes(4).decode_u32(0)
			while draw>=bound: draw=crypto.generate_random_bytes(4).decode_u32(0)
			var definition:=ItemDefinitions.get_definition(StringName(pool[draw%pool.size()]))
			if definition==null: return transaction.rollback("invalid_definition")
			var item:=ItemInstance.create(definition,owner,[])
			var inserted:=Items.new(db).receive_item_in_transaction(item)
			if not inserted.ok: return transaction.rollback(str(inserted.error))
			rewards.append({"uid":item.uid,"definition_id":str(item.definition_id),"amount":"1"})
	var wallet: Dictionary
	if int(plan.yang)>0: wallet=Wallet.new(db).credit_in_transaction(transaction.account_id,pending,int(plan.yang))
	else: wallet=Wallet.new(db).capture_income_in_transaction(transaction.account_id,pending)
	if not wallet.ok: return transaction.rollback(str(wallet.error))
	return transaction.commit({"ok":true,"yang":str(plan.yang),"rewards":rewards,"balance":wallet.balance,"wallet_states":[wallet.wallet_state],"income_token":income_token})
