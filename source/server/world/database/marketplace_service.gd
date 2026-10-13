class_name MarketplaceService
extends RefCounted
## One service per WorldDatabase. It owns marketplace routing, shared read budget
## and post-COMMIT wallet reconciliation; connection/runtime ownership stays there.
signal account_changed(account_id: int)
var _runtime: WorldDatabase
var rejected_commands := MarketRejectedCommands.new()

func _init(runtime: WorldDatabase) -> void:
	_runtime = runtime

func snapshot(character_id: int) -> Dictionary:
	return MarketStoreSqlite.new(_runtime.db,rejected_commands).mine(character_id)

func command(character_id: int, action: String, payload: Dictionary) -> Dictionary:
	if _runtime.db==null or not _runtime.wallet_ready: return {"ok":false,"error":"storage"}
	var result:=_perform_command(character_id,action,payload)
	if result.ok and action!="receipt":
		var affected: Array=result.get("affected_accounts",[_runtime.wallet_account_id(character_id)])
		if action=="buy": affected=[int(result.buyer_account),int(result.seller_account)]
		for account: Variant in affected: account_changed.emit(int(account))
	return result

func _perform_command(character_id: int, action: String, payload: Dictionary) -> Dictionary:
	var market := MarketStoreSqlite.new(_runtime.db,rejected_commands)
	var command_id: String = payload.get("command_id","")
	match action:
		"order", "cancel_order":
			var exchange:=ExchangeStoreSqlite.new(_runtime.db,rejected_commands)
			var pending: Dictionary={}
			for account: int in _runtime.runtime_wallets: pending[account]=int(_runtime.runtime_wallets[account].pending_currency_delta)
			var result:=exchange.place_order(character_id,payload,pending) if action=="order" else exchange.cancel_order(character_id,command_id,payload.order_id,int(payload.revision),pending)
			if result.ok and exchange.committed:
				for wallet: Dictionary in result.wallet_states:
					var account:=int(wallet.account_id)
					if _runtime.runtime_wallets.has(account):
						_runtime.runtime_wallets[account]={"wallet_balance":int(wallet.balance),"reserved_yang":int(wallet.reserved_yang),"pending_currency_delta":0};_runtime.dirty_wallet.erase(account)
			return result
		"deposit": return ExchangeStoreSqlite.new(_runtime.db,rejected_commands).deposit(character_id,command_id,payload.uid,int(payload.revision),int(payload.amount),payload.source)
		"withdraw": return ExchangeStoreSqlite.new(_runtime.db,rejected_commands).withdraw(character_id,command_id,payload.asset_id,int(payload.amount),payload.destination)
		"list": return market.list_item(character_id,command_id,payload.uid,int(payload.revision),int(payload.position),int(payload.price))
		"cancel": return market.cancel_offer(character_id,command_id,payload.offer_id,int(payload.revision))
		"claim": return market.claim_item(character_id,command_id,payload.uid,int(payload.revision))
		"configure": return market.configure(character_id,command_id,int(payload.revision),payload.name,payload.status)
		"edit": return market.edit_offer(character_id,command_id,payload.offer_id,int(payload.revision),int(payload.position),int(payload.price))
		"buy":
			if not _runtime.wallet_ready or not _runtime.load_wallet(character_id): return {"ok":false,"error":"wallet"}
			var pending := {}
			for account: int in _runtime.runtime_wallets: pending[account] = int(_runtime.runtime_wallets[account].pending_currency_delta)
			var result := market.purchase(character_id,command_id,int(payload.shop_id),payload.offer_id,int(payload.revision),int(payload.price),pending)
			if result.ok and market.committed:
				for party: String in ["buyer","seller"]:
					var account := int(result[party+"_account"])
					if _runtime.runtime_wallets.has(account):
						_runtime.runtime_wallets[account].wallet_balance=int(result[party+"_balance"])
						_runtime.runtime_wallets[account].pending_currency_delta=0
						_runtime.dirty_wallet.erase(account)
			return result
		"receipt": return market.receipt(character_id,command_id)
	return {"ok":false,"error":"request"}

# Synchronous reads have no application queue. Shared across every instance/account.
# One admission / 200 ms (5/s), burst one, and never twice in the same physics frame.
const MARKET_SEARCH_INTERVAL_MS := 200
var _market_search_after_ms := 0
var _market_search_frame := -1

func query(character_id: int, action: String, payload: Dictionary) -> Dictionary:
	if _runtime.db==null or not _runtime.wallet_ready: return {"ok":false,"error":"storage"}
	if _runtime.wallet_account_id(character_id)<=0: return {"ok":false,"error":"owner"}
	match action:
		"exchange":
			var account:=_runtime.wallet_account_id(character_id)
			var snapshot:=ExchangeStoreSqlite.new(_runtime.db,rejected_commands).orders_snapshot(character_id,int(_runtime.runtime_wallets.get(account,{}).get("pending_currency_delta",0)))
			return snapshot
		"catalog": return MarketSearchSqlite.catalog(payload.query)
		"search":
			if not MarketSearchSqlite.valid(payload): return {"ok":false,"error":"request"}
			var now:=Time.get_ticks_msec()
			var frame:=Engine.get_physics_frames()
			if now<_market_search_after_ms or frame==_market_search_frame: return {"ok":false,"error":"rate_limited"}
			_market_search_after_ms=now+MARKET_SEARCH_INTERVAL_MS
			_market_search_frame=frame
			return MarketSearchSqlite.new(_runtime.db).search(payload)
		"visit": return MarketStoreSqlite.new(_runtime.db,rejected_commands).visit(int(payload.shop_id))
	return {"ok":false,"error":"request"}
