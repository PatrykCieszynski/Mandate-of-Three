class_name ExchangeStoreSqlite
extends RefCounted
## Ledger/orderbook SQL. No Shop inheritance or shop-specific APIs/state.
var db: SqliteSoci
var _transaction: EconomyCommandSqlite
var committed: bool:
	get: return _transaction.committed
var commit_usec: int:
	get: return _transaction.commit_usec
var rejected: MarketRejectedCommands:
	get: return _transaction.rejected
func _init(database: SqliteSoci, rejected_commands: MarketRejectedCommands = null) -> void:
	db = database
	_transaction = EconomyCommandSqlite.new(db,rejected_commands)

func receipt(character_id: int, command_id: String) -> Dictionary:
	return _transaction.receipt(character_id,command_id)

static func ensure_ledger_schema(database: SqliteSoci) -> bool:
	if not database.query("SELECT value FROM meta WHERE key='schema_version';"): return false
	if int(database.query_result[0].value)>=21: return preload("res://source/server/world/database/wallet_state_sqlite.gd").ensure_schema(database)
	if int(database.query_result[0].value)!=20 or not database.query("BEGIN IMMEDIATE;"): return false
	for sql: String in [
		"ALTER TABLE account_wallets ADD COLUMN reserved_yang INTEGER NOT NULL DEFAULT 0 CHECK(typeof(reserved_yang)='integer' AND reserved_yang>=0 AND reserved_yang<=yang);",
		"CREATE TABLE exchange_assets(account_id INTEGER NOT NULL REFERENCES accounts(master_account_id),asset_id TEXT NOT NULL,free INTEGER NOT NULL DEFAULT 0 CHECK(typeof(free)='integer' AND free>=0),reserved INTEGER NOT NULL DEFAULT 0 CHECK(typeof(reserved)='integer' AND reserved>=0),PRIMARY KEY(account_id,asset_id),CHECK(free+reserved<=9000000000000000));",
		"INSERT OR REPLACE INTO meta(key,value) VALUES('schema_version','21');","COMMIT;"
	]:
		if not database.query(sql): database.query("ROLLBACK;");return false
	return preload("res://source/server/world/database/wallet_state_sqlite.gd").ensure_schema(database)
static func asset_definition(asset: String) -> ItemDefinition: return MarketRequestRules.asset_definition(asset)

func ledger(character_id: int) -> Dictionary:
	var account:=WorldStoreSqlite.new(db).resolve_account_id(character_id)
	if account<=0: return {"ok":false,"error":"owner"}
	if not db.query_with_bindings("SELECT asset_id,free,reserved FROM exchange_assets WHERE account_id=? ORDER BY asset_id;",[account]): return {"ok":false,"error":"storage"}
	# Publish every asset the same admission policy accepts for deposits,
	# even when its balance is zero. The UI derives its withdraw selector here.
	var balances: Dictionary = {}
	for row: Dictionary in db.query_result:
		balances[str(row.asset_id)] = row
	var assets: Array = []
	for definition: ItemDefinition in ItemDefinitions.all_definitions():
		var asset_id := str(definition.definition_id)
		if asset_definition(asset_id) != definition:
			continue
		var row: Dictionary = balances.get(asset_id, {})
		assets.append({"asset_id": asset_id, "name": definition.item_name,
			"stack_limit": definition.stack_limit,
			"free": int(row.get("free", 0)), "reserved": int(row.get("reserved", 0))})
	if not db.query_with_bindings("SELECT yang,reserved_yang FROM account_wallets WHERE account_id=?;",[account]) or db.query_result.is_empty(): return {"ok":false,"error":"storage"}
	return {"ok":true,"assets":assets,"yang":int(db.query_result[0].yang),"reserved_yang":int(db.query_result[0].reserved_yang)}
func deposit(character_id: int,command_id: String,uid: String,revision: int,amount: int,source: String) -> Dictionary:
	if not _transaction.begin(character_id,command_id,"exchange.deposit",[character_id,uid,revision,amount,source]): return _transaction.cached
	if source not in ["bag","account_storage"] or amount<=0: return _transaction.commit({"ok":false,"error":"request"})
	if not db.query_with_bindings("SELECT i.*,c.location,c.position AS bag_position,c.equipment_slot,c.owner_id FROM item_instances i JOIN item_custody c ON c.uid=i.uid WHERE i.uid=?;",[uid]): return _transaction.rollback("storage")
	if db.query_result.is_empty(): return _transaction.commit({"ok":false,"error":"owner"})
	var row: Dictionary=db.query_result[0].duplicate(true)
	if row.location!=source or int(row.owner_id)!=(character_id if source=="bag" else _transaction.account_id): return _transaction.commit({"ok":false,"error":"owner"})
	var item:=ItemInstance.from_row(row)
	if item==null or item.revision!=revision: return _transaction.commit({"ok":false,"error":"stale"})
	var definition:=asset_definition(str(item.definition_id))
	if definition==null or item.upgrade_level!=0 or not item.affixes.is_empty() or not item.sockets.is_empty() or amount>item.amount or item.amount>definition.stack_limit: return _transaction.commit({"ok":false,"error":"not_fungible"})
	if not db.query_with_bindings("INSERT INTO exchange_assets(account_id,asset_id,free) VALUES(?,?,?) ON CONFLICT(account_id,asset_id) DO UPDATE SET free=free+excluded.free;",[_transaction.account_id,str(item.definition_id),amount]): return _transaction.rollback("storage")
	if amount==item.amount:
		if not db.query_with_bindings("DELETE FROM item_custody WHERE uid=?;",[uid]) or not db.query_with_bindings("DELETE FROM item_instances WHERE uid=?;",[uid]): return _transaction.rollback("storage")
	elif not db.query_with_bindings("UPDATE item_instances SET amount=amount-?,revision=revision+1 WHERE uid=?;",[amount,uid]): return _transaction.rollback("storage")
	return _transaction.commit({"ok":true,"asset_id":str(item.definition_id),"amount":amount})
func withdraw(character_id: int,command_id: String,asset: String,amount: int,destination: String) -> Dictionary:
	if not _transaction.begin(character_id,command_id,"exchange.withdraw",[character_id,asset,amount,destination]): return _transaction.cached
	var definition:=asset_definition(asset)
	if definition==null or amount<=0 or amount>definition.stack_limit or destination not in ["bag","claim"]: return _transaction.commit({"ok":false,"error":"request"})
	if not db.query_with_bindings("UPDATE exchange_assets SET free=free-? WHERE account_id=? AND asset_id=? AND free>=?;",[amount,_transaction.account_id,asset,amount]): return _transaction.rollback("storage")
	if not db.query("SELECT changes() AS n;"): return _transaction.rollback("storage")
	if int(db.query_result[0].n)!=1: return _transaction.commit({"ok":false,"error":"funds"})
	var item:=ItemInstance.create(definition,character_id,[]);item.amount=amount
	if destination=="bag":
		var inserted:=ItemStoreSqlite.new(db).receive_item_in_transaction(item)
		if not inserted.ok: return _transaction.rollback(str(inserted.error))
	else:
		if not db.query_with_bindings("INSERT INTO item_instances VALUES(?,?,?,?,?,?,?,?);",[item.uid,character_id,asset,amount,0,"[]","[]",0]): return _transaction.rollback("storage")
		if not db.query_with_bindings("INSERT INTO item_custody(uid,location,owner_id,position) VALUES(?,'account_claim',?,-1);",[item.uid,_transaction.account_id]): return _transaction.rollback("storage")
	return _transaction.commit({"ok":true,"uid":item.uid,"amount":amount})
## Only order transactions may reserve/release. These are not exposed UI commands.
func reserve_in_transaction(account: int,asset: String,amount: int,pending: int=0) -> Dictionary:
	if amount<=0 or amount>WalletStoreSqlite.MAX_YANG: return {"ok":false,"error":"request"}
	if asset=="yang":
		var income:=WalletStoreSqlite.new(db)._apply_income(account,pending)
		if not income.ok: return income
		if not db.query_with_bindings("UPDATE account_wallets SET reserved_yang=reserved_yang+? WHERE account_id=? AND yang-reserved_yang>=?;",[amount,account,amount]): return {"ok":false,"error":"storage"}
	else:
		if asset_definition(asset)==null: return {"ok":false,"error":"asset"}
		if not db.query_with_bindings("UPDATE exchange_assets SET free=free-?,reserved=reserved+? WHERE account_id=? AND asset_id=? AND free>=?;",[amount,amount,account,asset,amount]): return {"ok":false,"error":"storage"}
	if not db.query("SELECT changes() AS n;"): return {"ok":false,"error":"storage"}
	return {"ok":true} if int(db.query_result[0].n)==1 else {"ok":false,"error":"funds"}
func release_in_transaction(account: int,asset: String,amount: int) -> bool:
	if amount<=0: return false
	var ok:=db.query_with_bindings("UPDATE account_wallets SET reserved_yang=reserved_yang-? WHERE account_id=? AND reserved_yang>=?;",[amount,account,amount]) if asset=="yang" else db.query_with_bindings("UPDATE exchange_assets SET free=free+?,reserved=reserved-? WHERE account_id=? AND asset_id=? AND reserved>=?;",[amount,amount,account,asset,amount])
	return ok and db.query("SELECT changes() AS n;") and int(db.query_result[0].n)==1


const MAX_RATIO_UNIT := 1000000000 # products <= 1e18, below signed int64 limit
const MAX_PAIR_ORDERS := 2048
const MAX_ACCOUNT_ORDERS := 20
static func ensure_orders_schema(database: SqliteSoci) -> bool:
	if not database.query("SELECT value FROM meta WHERE key='schema_version';"): return false
	if int(database.query_result[0].value)>=22: return true
	if int(database.query_result[0].value)!=21 or not database.query("BEGIN IMMEDIATE;"): return false
	for sql: String in [
		"CREATE TABLE exchange_orders(sequence INTEGER PRIMARY KEY AUTOINCREMENT,order_id TEXT UNIQUE NOT NULL,account_id INTEGER NOT NULL REFERENCES accounts(master_account_id),base_asset TEXT NOT NULL,quote_asset TEXT NOT NULL CHECK(quote_asset='yang'),side TEXT NOT NULL CHECK(side IN ('buy','sell')),quantity INTEGER NOT NULL CHECK(typeof(quantity)='integer' AND quantity>0 AND quantity<=9000000000000000),remaining INTEGER NOT NULL CHECK(typeof(remaining)='integer' AND remaining>=0 AND remaining<=quantity),price_num INTEGER NOT NULL CHECK(typeof(price_num)='integer' AND price_num BETWEEN 1 AND 1000000000),price_den INTEGER NOT NULL CHECK(typeof(price_den)='integer' AND price_den BETWEEN 1 AND 1000000000),reserved_amount INTEGER NOT NULL CHECK(typeof(reserved_amount)='integer' AND reserved_amount>=0 AND reserved_amount<=9000000000000000),received INTEGER NOT NULL DEFAULT 0 CHECK(typeof(received)='integer' AND received>=0 AND received<=9000000000000000),revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0),status TEXT NOT NULL CHECK(status IN ('active','filled','cancelled')),CHECK(quantity%price_den=0 AND remaining%price_den=0),CHECK((side='sell' AND reserved_amount=remaining) OR (side='buy' AND reserved_amount=(remaining/price_den)*price_num)),CHECK((status='active' AND remaining>0) OR (status<>'active' AND remaining=0)));",
		"CREATE INDEX exchange_pair ON exchange_orders(base_asset,quote_asset,status,side,sequence);",
		"CREATE INDEX exchange_account ON exchange_orders(account_id,status,sequence);",
		"CREATE TABLE exchange_fills(fill_id INTEGER PRIMARY KEY AUTOINCREMENT,maker_id TEXT NOT NULL REFERENCES exchange_orders(order_id),taker_id TEXT NOT NULL REFERENCES exchange_orders(order_id),base_quantity INTEGER NOT NULL CHECK(typeof(base_quantity)='integer' AND base_quantity>0),yang_amount INTEGER NOT NULL CHECK(typeof(yang_amount)='integer' AND yang_amount>0 AND yang_amount<=9000000000000000));",
		"INSERT OR REPLACE INTO meta(key,value) VALUES('schema_version','22');","COMMIT;"
	]:
		if not database.query(sql): database.query("ROLLBACK;");return false
	return true
static func gcd(a: int,b: int) -> int: return MarketRequestRules.gcd(a,b)
static func valid_order(p: Dictionary) -> bool: return MarketRequestRules.valid_order(p)
static func price_before(a: Dictionary,b: Dictionary,ascending: bool) -> bool:
	var left:=int(a.price_num)*int(b.price_den);var right:=int(b.price_num)*int(a.price_den)
	if left==right: return int(a.sequence)<int(b.sequence)
	return left<right if ascending else left>right
func _flush_pending(account: int,pending: Dictionary,touched: Dictionary) -> bool:
	if touched.has(account): return true
	if not WalletStoreSqlite.new(db)._apply_income(account,int(pending.get(account,0))).ok: return false
	touched[account]=true;return true
func _move_reserved(account: int,asset: String,reserved: int,spent: int,pending: Dictionary,touched: Dictionary) -> bool:
	if asset=="yang":
		if not _flush_pending(account,pending,touched): return false
		return db.query_with_bindings("UPDATE account_wallets SET reserved_yang=reserved_yang-?,yang=yang-? WHERE account_id=? AND reserved_yang>=?;",[reserved,spent,account,reserved]) and db.query("SELECT changes() AS n;") and int(db.query_result[0].n)==1
	return db.query_with_bindings("UPDATE exchange_assets SET reserved=reserved-? WHERE account_id=? AND asset_id=? AND reserved>=?;",[spent,account,asset,spent]) and db.query("SELECT changes() AS n;") and int(db.query_result[0].n)==1
func _credit_asset(account: int,asset: String,amount: int,pending: Dictionary,touched: Dictionary) -> bool:
	if asset=="yang":
		if not _flush_pending(account,pending,touched): return false
		return WalletStoreSqlite.new(db).credit_in_transaction(account,0,amount).ok
	return db.query_with_bindings("INSERT INTO exchange_assets(account_id,asset_id,free) VALUES(?,?,?) ON CONFLICT(account_id,asset_id) DO UPDATE SET free=free+excluded.free;",[account,asset,amount])
func _apply_fill(order: Dictionary,base: int,yang: int) -> bool:
	var reserve:=base if order.side=="sell" else int(base/int(order.price_den))*int(order.price_num)
	var received:=yang if order.side=="sell" else base
	return db.query_with_bindings("UPDATE exchange_orders SET remaining=remaining-?,reserved_amount=reserved_amount-?,received=received+?,revision=revision+1,status=CASE WHEN remaining=? THEN 'filled' ELSE 'active' END WHERE order_id=?;",[base,reserve,received,base,order.order_id])
func place_order(character_id: int,p: Dictionary,pending: Dictionary) -> Dictionary:
	if not valid_order(p): return {"ok":false,"error":"request_or_overflow"}
	if not _transaction.begin(character_id,p.command_id,"exchange.order",[p.have_asset,p.want_asset,int(p.quantity),int(p.price_num),int(p.price_den)]): return _transaction.cached
	var base: String=p.want_asset if p.have_asset=="yang" else p.have_asset
	var side: String="buy" if p.have_asset=="yang" else "sell"
	if not db.query_with_bindings("SELECT COUNT(*) AS n FROM exchange_orders WHERE status='active' AND account_id=?;",[_transaction.account_id]): return _transaction.rollback("storage")
	if int(db.query_result[0].n)>=MAX_ACCOUNT_ORDERS: return _transaction.commit({"ok":false,"error":"order_limit"})
	if not db.query_with_bindings("SELECT COUNT(*) AS n FROM exchange_orders WHERE status='active' AND base_asset=?;",[base]): return _transaction.rollback("storage")
	if int(db.query_result[0].n)>=MAX_PAIR_ORDERS: return _transaction.commit({"ok":false,"error":"book_full"})
	var divisor:=gcd(int(p.price_num),int(p.price_den));var numerator:=int(p.price_num)/divisor;var denominator:=int(p.price_den)/divisor
	var reserve:=int(p.quantity)/denominator*numerator if side=="buy" else int(p.quantity)
	var touched: Dictionary={}
	if p.have_asset=="yang" and not _flush_pending(_transaction.account_id,pending,touched): return _transaction.rollback("storage")
	var reserved:=reserve_in_transaction(_transaction.account_id,p.have_asset,reserve)
	if not reserved.ok: return _transaction.rollback(str(reserved.error))
	var order_id:=Crypto.new().generate_random_bytes(16).hex_encode()
	if not db.query_with_bindings("INSERT INTO exchange_orders(order_id,account_id,base_asset,quote_asset,side,quantity,remaining,price_num,price_den,reserved_amount,status) VALUES(?,?,?,'yang',?,?,?,?,?,?,'active');",[order_id,_transaction.account_id,base,side,int(p.quantity),int(p.quantity),numerator,denominator,reserve]): return _transaction.rollback("storage")
	if not db.query_with_bindings("SELECT * FROM exchange_orders WHERE order_id=?;",[order_id]): return _transaction.rollback("storage")
	var taker: Dictionary=db.query_result[0].duplicate(true)
	if not db.query_with_bindings("SELECT * FROM exchange_orders WHERE base_asset=? AND quote_asset='yang' AND side<>? AND status='active' AND account_id<>?;",[base,side,_transaction.account_id]): return _transaction.rollback("storage")
	var makers:=db.query_result.duplicate(true)
	makers.sort_custom(func(a: Dictionary,b: Dictionary)->bool:return price_before(a,b,side=="buy"))
	var affected: Dictionary={_transaction.account_id:true}
	for maker: Dictionary in makers:
		var left:=int(maker.price_num)*denominator;var right:=numerator*int(maker.price_den)
		if (side=="buy" and left>right) or (side=="sell" and left<right): break
		var lot:=denominator/gcd(denominator,int(maker.price_den))*int(maker.price_den)
		var fill:=mini(int(taker.remaining),int(maker.remaining))/lot*lot
		if fill==0: continue
		var yang:=fill/int(maker.price_den)*int(maker.price_num)
		# The validated taker reserve / maker reserve bounds prove this multiplication
		# fits MAX_YANG; still reject before ledger writes if the price-side bound fails.
		if yang<=0 or yang>WalletStoreSqlite.MAX_YANG: return _transaction.rollback("overflow")
		var buyer: Dictionary=taker if side=="buy" else maker
		var seller: Dictionary=maker if side=="buy" else taker
		var buyer_reserve:=fill/int(buyer.price_den)*int(buyer.price_num)
		if not _move_reserved(int(buyer.account_id),"yang",buyer_reserve,yang,pending,touched) or not _move_reserved(int(seller.account_id),base,fill,fill,pending,touched): return _transaction.rollback("storage")
		if not _credit_asset(int(buyer.account_id),base,fill,pending,touched) or not _credit_asset(int(seller.account_id),"yang",yang,pending,touched): return _transaction.rollback("storage")
		if not _apply_fill(maker,fill,yang) or not _apply_fill(taker,fill,yang): return _transaction.rollback("storage")
		if not db.query_with_bindings("INSERT INTO exchange_fills(maker_id,taker_id,base_quantity,yang_amount) VALUES(?,?,?,?);",[maker.order_id,taker.order_id,fill,yang]): return _transaction.rollback("storage")
		taker.remaining=int(taker.remaining)-fill
		affected[int(maker.account_id)]=true
		if int(taker.remaining)==0: break
	return _finish_exchange({"ok":true,"order_id":order_id,"remaining":int(taker.remaining),"affected_accounts":affected.keys()},touched,pending)
func cancel_order(character_id: int,command_id: String,order_id: String,revision: int,pending: Dictionary) -> Dictionary:
	if not _transaction.begin(character_id,command_id,"exchange.cancel",[order_id,revision]): return _transaction.cached
	if not db.query_with_bindings("SELECT * FROM exchange_orders WHERE order_id=? AND account_id=?;",[order_id,_transaction.account_id]): return _transaction.rollback("storage")
	if db.query_result.is_empty(): return _transaction.commit({"ok":false,"error":"owner"})
	var order: Dictionary=db.query_result[0].duplicate(true)
	if int(order.revision)!=revision: return _transaction.commit({"ok":false,"error":"stale"})
	if order.status!="active": return _transaction.commit({"ok":false,"error":"closed"})
	var touched: Dictionary={}
	var asset: String="yang" if order.side=="buy" else order.base_asset
	if asset=="yang" and not _flush_pending(_transaction.account_id,pending,touched): return _transaction.rollback("storage")
	if not release_in_transaction(_transaction.account_id,asset,int(order.reserved_amount)): return _transaction.rollback("storage")
	if not db.query_with_bindings("UPDATE exchange_orders SET remaining=0,reserved_amount=0,status='cancelled',revision=revision+1 WHERE order_id=?;",[order_id]): return _transaction.rollback("storage")
	return _finish_exchange({"ok":true,"order_id":order_id,"refunded":int(order.reserved_amount),"affected_accounts":[_transaction.account_id]},touched,pending)
func orders_snapshot(character_id: int,pending_yang: int=0) -> Dictionary:
	var snapshot:=ledger(character_id)
	if not snapshot.ok: return snapshot
	var account:=WorldStoreSqlite.new(db).resolve_account_id(character_id)
	snapshot.yang+=pending_yang
	if not db.query_with_bindings("SELECT * FROM exchange_orders WHERE account_id=? ORDER BY status='active' DESC,sequence DESC LIMIT 50;",[account]): return {"ok":false,"error":"storage"}
	snapshot.orders=db.query_result.duplicate(true)
	if not db.query_with_bindings("SELECT f.*,m.base_asset FROM exchange_fills f JOIN exchange_orders m ON m.order_id=f.maker_id JOIN exchange_orders t ON t.order_id=f.taker_id WHERE m.account_id=? OR t.account_id=? ORDER BY f.fill_id DESC LIMIT 20;",[account,account]): return {"ok":false,"error":"storage"}
	snapshot.fills=db.query_result.duplicate(true)
	if not db.query("SELECT base_asset,side,remaining,price_num,price_den,sequence FROM exchange_orders WHERE status='active';"): return {"ok":false,"error":"storage"}
	var orders:=db.query_result.duplicate(true)
	snapshot.depth=[]
	for side: String in ["buy","sell"]:
		var book:=orders.filter(func(row: Dictionary)->bool:return row.side==side)
		book.sort_custom(func(a: Dictionary,b: Dictionary)->bool:return price_before(a,b,side=="sell"))
		for row: Dictionary in book.slice(0,10): snapshot.depth.append(row)
	return snapshot

func _finish_exchange(result: Dictionary,touched: Dictionary,pending: Dictionary) -> Dictionary:
	# Read final totals before COMMIT. Runtime reconciliation cannot depend on a
	# fallible database read after the economic mutation has already committed.
	var states: Array=[]
	var wallets:=WalletStoreSqlite.new(db)
	for account: int in touched:
		var wallet:=wallets.load_wallet(account)
		if not wallet.ok: return _transaction.rollback("storage")
		var state: Dictionary = wallet.wallet_state
		state.pending_applied = int(pending.get(account,0))
		states.append(state)
	result.wallet_states=states
	return _transaction.commit(result)
