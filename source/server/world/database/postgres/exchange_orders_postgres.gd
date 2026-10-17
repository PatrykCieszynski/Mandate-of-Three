extends RefCounted
## One native owner: pair -> sorted participant accounts -> character/receipt ->
## reservations, settlement, orders/fills, original result. No global order queue.
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const Ledger = preload("res://source/server/world/database/postgres/exchange_ledger_postgres.gd")
const MAX_ACCOUNT_ORDERS: int=20
const MAX_PAIR_ORDERS: int=2048
var db: Object
var rejected: MarketRejectedCommands
var _transaction: RefCounted
var committed: bool:
	get: return _transaction.committed

func _init(database: Object, negative: MarketRejectedCommands = null) -> void:
	db=database
	rejected=negative if negative!=null else MarketRejectedCommands.new()
	_transaction=Commands.new(db,rejected)

func receipt(character: int, command: String) -> Dictionary:
	return Ledger.new(db,rejected).receipt(character,command)

func _begin(character: int, command: String, kind: String, args: Array, base: String, side: String = "") -> Dictionary:
	_transaction.committed=false
	_transaction.receipt_replay=false
	if not Commands.valid_id(command): return {"ok":false,"error":"request"}
	if db.in_transaction() or not db.begin(): return {"ok":false,"error":"storage"}
	var identity: Dictionary=db.query("SELECT account_id FROM economy.characters WHERE character_id=:character;",{"character":character})
	if not identity.ok or identity.rows.is_empty(): return _transaction.rollback("storage" if not identity.ok else "owner")
	var account: int=int(identity.rows[0].account_id)
	var accounts: Array[int]=[account]
	if not base.is_empty():
		if not db.execute("INSERT INTO economy.exchange_books(base_asset) VALUES(:base) ON CONFLICT DO NOTHING;",{"base":base}).ok: return _transaction.rollback("storage")
		var locked: Dictionary=db.query("SELECT base_asset FROM economy.exchange_books WHERE base_asset=:base FOR UPDATE;",{"base":base})
		if not locked.ok or locked.rows.is_empty(): return _transaction.rollback("storage")
		if not side.is_empty():
			var owners: Dictionary=db.query("SELECT DISTINCT account_id FROM economy.exchange_orders WHERE base_asset=:base AND side<>:side AND status='active';",{"base":base,"side":side},MAX_PAIR_ORDERS+1)
			if not owners.ok or owners.truncated: return _transaction.rollback("storage")
			for row: Dictionary in owners.rows:
				if int(row.account_id) not in accounts: accounts.append(int(row.account_id))
	accounts.sort()
	for participant: int in accounts:
		var locked: Dictionary=db.query("SELECT account_id FROM economy.accounts WHERE account_id=:account FOR NO KEY UPDATE;",{"account":participant})
		if not locked.ok or locked.rows.is_empty(): return _transaction.rollback("storage")
	if not _transaction.admit_in_transaction(character,command,kind,args,account): return _transaction.cached
	return {"ok":true,"admitted":true}

static func price_before(a: Dictionary,b: Dictionary,ascending: bool) -> bool:
	var left: int=int(a.price_num)*int(b.price_den)
	var right: int=int(b.price_num)*int(a.price_den)
	if left==right: return int(a.sequence)<int(b.sequence)
	return left<right if ascending else left>right

func place_order(character: int, p: Dictionary, pending: Dictionary) -> Dictionary:
	return _transaction.run_with_retry(_place_order_once.bind(character,p.duplicate(true),pending.duplicate(true)))

func _place_order_once(character: int, p: Dictionary, pending: Dictionary) -> Dictionary:
	if not p.get("command_id") is String or not MarketRequestRules.valid_order(p):
		_transaction.committed=false
		return {"ok":false,"error":"request_or_overflow"}
	var base: String=p.want_asset if p.have_asset=="yang" else p.have_asset
	var side: String="buy" if p.have_asset=="yang" else "sell"
	var admission:=_begin(character,p.command_id,"exchange.order",[p.have_asset,p.want_asset,int(p.quantity),int(p.price_num),int(p.price_den)],base,side)
	if not admission.get("admitted",false): return admission
	var count: Dictionary=db.query("SELECT COUNT(*) AS n FROM economy.exchange_orders WHERE status='active' AND account_id=:account;",{"account":_transaction.account_id})
	if not count.ok: return _transaction.rollback("storage")
	if int(count.rows[0].n)>=MAX_ACCOUNT_ORDERS: return _reject("order_limit")
	count=db.query("SELECT COUNT(*) AS n FROM economy.exchange_orders WHERE status='active' AND base_asset=:base;",{"base":base})
	if not count.ok: return _transaction.rollback("storage")
	if int(count.rows[0].n)>=MAX_PAIR_ORDERS: return _reject("book_full")
	var divisor: int=MarketRequestRules.gcd(int(p.price_num),int(p.price_den))
	var numerator: int=int(p.price_num)/divisor
	var denominator: int=int(p.price_den)/divisor
	var reserve: int=int(p.quantity)/denominator*numerator if side=="buy" else int(p.quantity)
	var touched: Dictionary={}
	if p.have_asset=="yang" and not _flush_pending(_transaction.account_id,pending,touched): return _transaction.rollback("storage")
	var reserved:=reserve_in_transaction(_transaction.account_id,p.have_asset,reserve)
	if not reserved.ok: return _transaction.rollback(str(reserved.error))
	var order: String=Crypto.new().generate_random_bytes(16).hex_encode()
	if not db.execute("INSERT INTO economy.exchange_orders(order_id,account_id,base_asset,quote_asset,side,quantity,remaining,price_num,price_den,reserved_amount,status) VALUES(:order,:account,:base,'yang',:side,:quantity,:remaining,:num,:den,:reserve,'active');",{"order":order,"account":_transaction.account_id,"base":base,"side":side,"quantity":int(p.quantity),"remaining":int(p.quantity),"num":numerator,"den":denominator,"reserve":reserve}).ok: return _transaction.rollback("storage")
	var found: Dictionary=db.query("SELECT * FROM economy.exchange_orders WHERE order_id=:id;",{"id":order})
	if not found.ok or found.rows.is_empty(): return _transaction.rollback("storage")
	var taker: Dictionary=found.rows[0]
	found=db.query("SELECT * FROM economy.exchange_orders WHERE base_asset=:base AND quote_asset='yang' AND side<>:side AND status='active' AND account_id<>:account;",{"base":base,"side":side,"account":_transaction.account_id},MAX_PAIR_ORDERS+1)
	if not found.ok or found.truncated: return _transaction.rollback("storage")
	var makers: Array=found.rows
	makers.sort_custom(func(a: Dictionary,b: Dictionary) -> bool: return price_before(a,b,side=="buy"))
	var affected: Dictionary={_transaction.account_id:true}
	for maker: Dictionary in makers:
		var left: int=int(maker.price_num)*denominator
		var right: int=numerator*int(maker.price_den)
		if (side=="buy" and left>right) or (side=="sell" and left<right): break
		var lot: int=denominator/MarketRequestRules.gcd(denominator,int(maker.price_den))*int(maker.price_den)
		var fill: int=mini(int(taker.remaining),int(maker.remaining))/lot*lot
		if fill==0: continue
		var yang: int=fill/int(maker.price_den)*int(maker.price_num)
		if yang<=0 or yang>Wallet.MAX_YANG: return _transaction.rollback("overflow")
		var buyer: Dictionary=taker if side=="buy" else maker
		var seller: Dictionary=maker if side=="buy" else taker
		var buyer_reserve: int=fill/int(buyer.price_den)*int(buyer.price_num)
		if not _move_reserved(int(buyer.account_id),"yang",buyer_reserve,yang,pending,touched) or not _move_reserved(int(seller.account_id),base,fill,fill,pending,touched): return _transaction.rollback("storage")
		if not _credit_asset(int(buyer.account_id),base,fill,pending,touched) or not _credit_asset(int(seller.account_id),"yang",yang,pending,touched): return _transaction.rollback("storage")
		if not _apply_fill(maker,fill,yang) or not _apply_fill(taker,fill,yang): return _transaction.rollback("storage")
		if not db.execute("INSERT INTO economy.exchange_fills(maker_id,taker_id,base_quantity,yang_amount) VALUES(:maker,:taker,:quantity,:yang);",{"maker":maker.order_id,"taker":taker.order_id,"quantity":fill,"yang":yang}).ok: return _transaction.rollback("storage")
		taker.remaining=int(taker.remaining)-fill
		affected[int(maker.account_id)]=true
		if int(taker.remaining)==0: break
	return _finish({"ok":true,"order_id":order,"remaining":int(taker.remaining),"affected_accounts":affected.keys()},touched,pending)

func cancel_order(character: int, command: String, order: String, revision: int, pending: Dictionary) -> Dictionary:
	return _transaction.run_with_retry(_cancel_order_once.bind(character,command,order,revision,pending.duplicate(true)))

func _cancel_order_once(character: int, command: String, order: String, revision: int, pending: Dictionary) -> Dictionary:
	_transaction.committed=false
	if db.in_transaction(): return {"ok":false,"error":"storage"}
	# Identity hint survives filled/cancelled orders. Recheck ownership/revision
	# after admission; discovery remains independent of current order status.
	var found: Dictionary=db.query("SELECT base_asset FROM economy.exchange_orders WHERE order_id=:order;",{"order":order})
	if not found.ok: return {"ok":false,"error":"storage"}
	var base: String="" if found.rows.is_empty() else str(found.rows[0].base_asset)
	var admission:=_begin(character,command,"exchange.cancel",[order,revision],base)
	if not admission.get("admitted",false): return admission
	found=db.query("SELECT * FROM economy.exchange_orders WHERE order_id=:order AND account_id=:account;",{"order":order,"account":_transaction.account_id})
	if not found.ok: return _transaction.rollback("storage")
	if found.rows.is_empty(): return _reject("owner")
	var row: Dictionary=found.rows[0]
	if row.base_asset!=base: return _transaction.rollback("storage")
	if int(row.revision)!=revision: return _reject("stale")
	if row.status!="active": return _reject("closed")
	var touched: Dictionary={}
	var asset: String="yang" if row.side=="buy" else str(row.base_asset)
	if asset=="yang" and not _flush_pending(_transaction.account_id,pending,touched): return _transaction.rollback("storage")
	if not release_in_transaction(_transaction.account_id,asset,int(row.reserved_amount)): return _transaction.rollback("storage")
	if not db.execute("UPDATE economy.exchange_orders SET remaining=0,reserved_amount=0,status='cancelled',revision=revision+1 WHERE order_id=:order;",{"order":order}).ok: return _transaction.rollback("storage")
	return _finish({"ok":true,"order_id":order,"refunded":int(row.reserved_amount),"affected_accounts":[_transaction.account_id]},touched,pending)

func reserve_in_transaction(account: int, asset: String, amount: int, pending: int = 0) -> Dictionary:
	if not db.in_transaction(): return {"ok":false,"error":"transaction"}
	if amount<=0 or amount>Wallet.MAX_YANG: return {"ok":false,"error":"request"}
	var changed: Dictionary
	if asset=="yang":
		var income:=Wallet.new(db)._apply_income(account,pending)
		if not income.ok: return income
		changed=db.execute("UPDATE economy.account_wallets SET reserved_yang=reserved_yang+:amount WHERE account_id=:account AND yang-reserved_yang>=:required;",{"amount":amount,"account":account,"required":amount})
	else:
		if Ledger.asset_definition(asset)==null: return {"ok":false,"error":"asset"}
		changed=db.execute("UPDATE economy.exchange_assets SET free=free-:amount,reserved=reserved+:reserve WHERE account_id=:account AND asset_id=:asset AND free>=:required;",{"amount":amount,"reserve":amount,"account":account,"asset":asset,"required":amount})
	return {"ok":true} if changed.ok and int(changed.affected_rows)==1 else {"ok":false,"error":"storage" if not changed.ok else "funds"}

func release_in_transaction(account: int, asset: String, amount: int) -> bool:
	if not db.in_transaction() or amount<=0: return false
	var changed: Dictionary=db.execute("UPDATE economy.account_wallets SET reserved_yang=reserved_yang-:amount WHERE account_id=:account AND reserved_yang>=:required;",{"amount":amount,"account":account,"required":amount}) if asset=="yang" else db.execute("UPDATE economy.exchange_assets SET free=free+:amount,reserved=reserved-:release WHERE account_id=:account AND asset_id=:asset AND reserved>=:required;",{"amount":amount,"release":amount,"account":account,"asset":asset,"required":amount})
	return changed.ok and int(changed.affected_rows)==1

func _flush_pending(account: int, pending: Dictionary, touched: Dictionary) -> bool:
	if touched.has(account): return true
	if not Wallet.new(db)._apply_income(account,int(pending.get(account,0))).ok: return false
	touched[account]=true
	return true

func _move_reserved(account: int, asset: String, reserve: int, spent: int, pending: Dictionary, touched: Dictionary) -> bool:
	var changed: Dictionary
	if asset=="yang":
		if not _flush_pending(account,pending,touched): return false
		changed=db.execute("UPDATE economy.account_wallets SET reserved_yang=reserved_yang-:reserve,yang=yang-:spent WHERE account_id=:account AND reserved_yang>=:required;",{"reserve":reserve,"spent":spent,"account":account,"required":reserve})
	else:
		changed=db.execute("UPDATE economy.exchange_assets SET reserved=reserved-:spent WHERE account_id=:account AND asset_id=:asset AND reserved>=:required;",{"spent":spent,"account":account,"asset":asset,"required":spent})
	return changed.ok and int(changed.affected_rows)==1

func _credit_asset(account: int, asset: String, amount: int, pending: Dictionary, touched: Dictionary) -> bool:
	if asset=="yang":
		if not _flush_pending(account,pending,touched): return false
		return Wallet.new(db).credit_in_transaction(account,0,amount).ok
	var changed: Dictionary=db.execute("INSERT INTO economy.exchange_assets(account_id,asset_id,free) VALUES(:account,:asset,:amount) ON CONFLICT(account_id,asset_id) DO UPDATE SET free=economy.exchange_assets.free+EXCLUDED.free WHERE economy.exchange_assets.free<=:maximum-economy.exchange_assets.reserved-EXCLUDED.free;",{"account":account,"asset":asset,"amount":amount,"maximum":Wallet.MAX_YANG})
	return changed.ok and int(changed.affected_rows)==1

func _apply_fill(order: Dictionary, base: int, yang: int) -> bool:
	var reserve: int=base if order.side=="sell" else base/int(order.price_den)*int(order.price_num)
	var received: int=yang if order.side=="sell" else base
	return db.execute("UPDATE economy.exchange_orders SET remaining=remaining-:base,reserved_amount=reserved_amount-:reserve,received=received+:received,revision=revision+1,status=CASE WHEN remaining=:quantity THEN 'filled' ELSE 'active' END WHERE order_id=:order;",{"base":base,"reserve":reserve,"received":received,"quantity":base,"order":order.order_id}).ok

func _finish(result: Dictionary, touched: Dictionary, pending: Dictionary) -> Dictionary:
	var states: Array=[]
	for account: int in touched:
		var wallet:=Wallet.new(db).load_wallet(account)
		if not wallet.ok: return _transaction.rollback("storage")
		var state: Dictionary=wallet.wallet_state
		state.pending_applied=int(pending.get(account,0))
		states.append(state)
	result.wallet_states=states
	return _transaction.commit(result)

func _reject(error: String) -> Dictionary:
	return _transaction.commit({"ok":false,"error":error})

func orders_snapshot(character: int, pending_yang: int = 0) -> Dictionary:
	if db.in_transaction() or not db.begin(): return {"ok":false,"error":"storage"}
	if not db.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;").ok: return _transaction.rollback("storage")
	var snapshot:=Ledger.new(db).read_in_transaction(character)
	if not snapshot.ok: return _transaction.rollback(str(snapshot.error))
	if pending_yang<0 or pending_yang>Wallet.MAX_YANG-int(snapshot.yang): return _transaction.rollback("storage")
	snapshot.yang+=pending_yang
	var identity: Dictionary=db.query("SELECT account_id FROM economy.characters WHERE character_id=:character;",{"character":character})
	if not identity.ok or identity.rows.is_empty(): return _transaction.rollback("storage")
	var account: int=int(identity.rows[0].account_id)
	var found: Dictionary=db.query("SELECT * FROM economy.exchange_orders WHERE account_id=:account ORDER BY (status='active') DESC,sequence DESC LIMIT 50;",{"account":account})
	if not found.ok or found.truncated: return _transaction.rollback("storage")
	snapshot.orders=found.rows
	found=db.query("SELECT f.*,m.base_asset FROM economy.exchange_fills f JOIN economy.exchange_orders m ON m.order_id=f.maker_id JOIN economy.exchange_orders t ON t.order_id=f.taker_id WHERE m.account_id=:maker OR t.account_id=:taker ORDER BY f.fill_id DESC LIMIT 20;",{"maker":account,"taker":account})
	if not found.ok or found.truncated: return _transaction.rollback("storage")
	snapshot.fills=found.rows
	found=db.query("SELECT base_asset,side,remaining,price_num,price_den,sequence FROM economy.exchange_orders WHERE status='active';",{},mini(100000,MAX_PAIR_ORDERS*ItemDefinitions.all_definitions().size()+1))
	if not found.ok or found.truncated: return _transaction.rollback("storage")
	var active: Array=found.rows
	snapshot.depth=[]
	for side: String in ["buy","sell"]:
		var book:=active.filter(func(row: Dictionary) -> bool: return row.side==side)
		book.sort_custom(func(a: Dictionary,b: Dictionary) -> bool: return price_before(a,b,side=="sell"))
		for row: Dictionary in book.slice(0,10): snapshot.depth.append(row)
	if db.commit(): return snapshot
	db.close()
	return {"ok":false,"error":"storage"}
