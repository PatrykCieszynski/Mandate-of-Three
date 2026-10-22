extends RefCounted
## Opt-in purchase/proceeds port. One caller-owned native session, no World I/O.
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const Seller = preload("res://source/server/world/database/postgres/shop_seller_postgres.gd")
const MAX_REVENUE: int=9223372036854775807
var db: Object
var income_token: String=""
var receipt_replay: bool:
	get: return _transaction.receipt_replay

func authorize_session(context: Dictionary, token: String) -> void:
	_transaction.economic_context=context.duplicate(true)
	income_token=token

var rejected: MarketRejectedCommands
var _transaction: RefCounted
var committed: bool:
	get: return _transaction.committed

func _init(database: Object, rejected_commands: MarketRejectedCommands = null) -> void:
	db=database
	rejected=rejected_commands if rejected_commands!=null else MarketRejectedCommands.new()
	_transaction=Commands.new(db,rejected)

func revenue(account: int) -> Dictionary:
	var found: Dictionary=db.query("SELECT yang FROM economy.account_shop_revenue WHERE account_id=:account;",{"account":account})
	if not found.ok: return _error("storage")
	return {"ok":true,"amount":0 if found.rows.is_empty() else int(found.rows[0].yang)}

func receipt(character: int, command: String) -> Dictionary:
	return Seller.new(db,rejected).receipt(character,command)

func purchase(character: int, command: String, shop: int, offer: String, revision: int, price: int, pending: Dictionary) -> Dictionary:
	# Capture the server-owned prefix once; each failed attempt rolls it back.
	return _transaction.run_with_retry(_purchase_once.bind(character,command,shop,offer,revision,price,pending.duplicate(true)))

func _purchase_once(character: int, command: String, shop: int, offer: String, revision: int, price: int, pending: Dictionary) -> Dictionary:
	_transaction.committed=false
	# This hint is independent of the offer: sold offers must still replay.
	# Shop ownership is immutable in this port and checked again after admission.
	if db.in_transaction(): return _error("storage")
	var identity: Dictionary=db.query("SELECT account_id FROM economy.account_shops WHERE shop_id=:shop;",{"shop":shop})
	if not identity.ok: return _error("storage")
	var seller: int=0 if identity.rows.is_empty() else int(identity.rows[0].account_id)
	if not _transaction.begin(character,command,"buy",[character,shop,offer,revision,price],true,seller): return _transaction.cached
	var found: Dictionary=db.query("SELECT o.*,s.status,i.definition_id FROM economy.shop_offers o JOIN economy.account_shops s ON s.shop_id=o.shop_id JOIN economy.item_instances i ON i.uid=o.item_uid WHERE o.offer_id=:offer AND o.shop_id=:shop;",{"offer":offer,"shop":shop})
	if not found.ok: return _transaction.rollback("storage")
	if found.rows.is_empty(): return _reject("unavailable")
	var row: Dictionary=found.rows[0]
	if int(row.account_id)!=seller: return _transaction.rollback("storage")
	if seller==_transaction.account_id: return _reject("self_trade")
	if row.status!="active": return _reject("paused")
	if int(row.offer_only)==1: return _reject("offer_only")
	if int(row.revision)!=revision or int(row.price_yang)!=price: return _reject("stale")
	var definition:=ItemDefinitions.get_definition(StringName(row.definition_id))
	if definition==null: return _reject("unknown_definition")
	var receiving:=Items.new(db).resolve_inventory_position(character,definition.inventory_height,-1)
	if not receiving.ok: return _reject(str(receiving.error))
	var spent:=Wallet.new(db).spend_in_transaction(_transaction.account_id,int(pending.get(_transaction.account_id,0)),price)
	if not spent.ok: return _transaction.rollback(str(spent.error))
	# Conditional additive UPDATE/UPSERT, never read then overwrite an old total.
	var credited: Dictionary=db.query("INSERT INTO economy.account_shop_revenue(account_id,yang) VALUES(:account,:amount) ON CONFLICT(account_id) DO UPDATE SET yang=economy.account_shop_revenue.yang+EXCLUDED.yang WHERE economy.account_shop_revenue.yang<=:maximum-EXCLUDED.yang RETURNING yang;",{"account":seller,"amount":price,"maximum":MAX_REVENUE})
	if not credited.ok: return _transaction.rollback("storage")
	if credited.rows.is_empty(): return _reject("revenue_capacity")
	if not db.execute("DELETE FROM economy.shop_cells WHERE item_uid=:uid;",{"uid":row.item_uid}).ok: return _transaction.rollback("storage")
	if not db.execute("UPDATE economy.item_instances SET owner_character_id=:owner,revision=revision+1 WHERE uid=:uid;",{"owner":character,"uid":row.item_uid}).ok: return _transaction.rollback("storage")
	if not db.execute("UPDATE economy.item_custody SET location='bag',owner_id=:owner,position=:position,escrow_account_id=NULL,shop_id=NULL,offer_id=NULL WHERE uid=:uid;",{"owner":character,"position":receiving.position,"uid":row.item_uid}).ok: return _transaction.rollback("storage")
	if not db.execute("DELETE FROM economy.shop_offers WHERE offer_id=:offer;",{"offer":offer}).ok: return _transaction.rollback("storage")
	return _commit({"ok":true,"uid":str(row.item_uid),"buyer_account":_transaction.account_id,"seller_account":seller,"buyer_balance":int(spent.balance),"seller_claimable_yang":str(credited.rows[0].yang),"wallet_states":[spent.wallet_state],"shop_id":shop})

func claim_revenue(character: int, command: String, pending_income: int) -> Dictionary:
	return _transaction.run_with_retry(_claim_revenue_once.bind(character,command,pending_income))

func _claim_revenue_once(character: int, command: String, pending_income: int) -> Dictionary:
	if not _transaction.begin(character,command,"claim_revenue",[character],true): return _transaction.cached
	var account: int=_transaction.account_id
	var funds:=revenue(account)
	if not funds.ok: return _transaction.rollback("storage")
	if int(funds.amount)==0: return _reject("nothing_to_claim")
	# Lock before computing headroom; direct wallet credit/spend helpers also
	# serialize on this row and cannot invalidate partial collection's capacity.
	var wallet: Dictionary=db.query("SELECT yang FROM economy.account_wallets WHERE account_id=:account FOR NO KEY UPDATE;",{"account":account})
	if not wallet.ok or wallet.rows.is_empty(): return _transaction.rollback("storage")
	var balance: int=int(wallet.rows[0].yang)
	if pending_income<0 or pending_income>Wallet.MAX_YANG-balance: return _transaction.rollback("storage")
	var amount: int=mini(int(funds.amount),Wallet.MAX_YANG-balance-pending_income)
	if amount<=0: return _reject("wallet_full")
	var credited:=Wallet.new(db).credit_in_transaction(account,pending_income,amount)
	if not credited.ok: return _transaction.rollback(str(credited.error))
	if not db.execute("UPDATE economy.account_shop_revenue SET yang=yang-:amount WHERE account_id=:account;",{"amount":amount,"account":account}).ok: return _transaction.rollback("storage")
	return _commit({"ok":true,"claimed":amount,"claimable_yang":str(int(funds.amount)-amount),"wallet_states":[credited.wallet_state]})

func _reject(reason: String) -> Dictionary:
	return _transaction.commit(_error(reason))

func _error(reason: String) -> Dictionary:
	return {"ok":false,"error":reason}

func _commit(result: Dictionary) -> Dictionary:
	if not income_token.is_empty(): result.income_token=income_token
	return _transaction.commit(result)
