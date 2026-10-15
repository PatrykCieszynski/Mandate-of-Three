class_name MarketplaceService
extends RefCounted
## One service per WorldDatabase. It owns marketplace command routing and
## post-COMMIT wallet reconciliation; connection/runtime ownership stays there.
signal account_changed(account_id: int)
var _runtime: WorldDatabase
var rejected_commands := MarketRejectedCommands.new()

func _init(runtime: WorldDatabase) -> void:
	_runtime = runtime

func snapshot(character_id: int) -> Dictionary:
	return MarketStoreSqlite.new(_runtime.db,rejected_commands).mine(character_id)

## The application boundary validates untrusted shapes independently of RPC/CEF.
## Stores still authorize custody/revisions and own the atomic transaction/receipt.
func _operation(character_id: int, action: String, payload: Dictionary, result: Dictionary, committed: bool = false, affected: Array = []) -> EconomyOperationResult:
	var id: String = payload.command_id if payload.get("command_id") is String else ""
	var account := 0
	if _runtime.db != null and _runtime.wallet_ready and result.get("error", "") not in ["request", "storage"]:
		account = _runtime.wallet_account_id(character_id)
	return EconomyOperationResult.capture(character_id, account, action, id, result, committed, affected,
		action != "receipt" and bool(result.get("ok", false)) and not committed)

func execute(character_id: int, action: String, payload: Dictionary) -> EconomyOperationResult:
	if action == "open" or not MarketRequestRules.valid_command(action, payload):
		return _operation(character_id, action, payload, {"ok": false, "error": "request"})
	if _runtime.db == null or not _runtime.wallet_ready:
		return _operation(character_id, action, payload, {"ok":false,"error":"storage"})
	var result: Dictionary
	var committed := false
	if action in ["order", "cancel_order", "deposit", "withdraw"]:
		var exchange := ExchangeStoreSqlite.new(_runtime.db, rejected_commands)
		result = _exchange_command(exchange, character_id, action, payload)
		committed = exchange.committed
	else:
		var market := MarketStoreSqlite.new(_runtime.db, rejected_commands)
		result = _market_command(market, character_id, action, payload)
		committed = market.committed
	# A successful receipt replay is a successful response, not another commit.
	# Do not consume newer pending income or publish another account change.
	if not result.ok or not committed: return _operation(character_id, action, payload, result)
	if action in ["order", "cancel_order"]:
		_reconcile_wallets(result.wallet_states)
	elif action == "buy":
		_reconcile_wallets([
			{"account_id": result.buyer_account, "balance": result.buyer_balance},
			{"account_id": result.seller_account, "balance": result.seller_balance},
		])
	var affected: Array = result.get("affected_accounts", [_runtime.wallet_account_id(character_id)])
	if action == "buy": affected = [int(result.buyer_account), int(result.seller_account)]
	var operation := _operation(character_id, action, payload, result, true, affected)
	for account: int in operation.changed_accounts:
		account_changed.emit(account)
	return operation

func _pending_wallet_deltas() -> Dictionary:
	var pending := {}
	for account: int in _runtime.runtime_wallets:
		pending[account] = int(_runtime.runtime_wallets[account].pending_currency_delta)
	return pending

## Account IDs, never character IDs. Only a newly committed result reaches here.
## Offline wallets stay offline; their durable settlement already happened in SQL.
func _reconcile_wallets(states: Array) -> void:
	for state: Dictionary in states:
		var account := int(state.account_id)
		if not _runtime.runtime_wallets.has(account): continue
		var wallet: Dictionary = _runtime.runtime_wallets[account]
		wallet.wallet_balance = int(state.balance)
		if state.has("reserved_yang"): wallet.reserved_yang = int(state.reserved_yang)
		wallet.pending_currency_delta = 0
		_runtime.dirty_wallet.erase(account)

func _exchange_command(exchange: ExchangeStoreSqlite, character_id: int, action: String, p: Dictionary) -> Dictionary:
	match action:
		"order": return exchange.place_order(character_id, p, _pending_wallet_deltas())
		"cancel_order": return exchange.cancel_order(character_id, p.command_id, p.order_id, int(p.revision), _pending_wallet_deltas())
		"deposit": return exchange.deposit(character_id, p.command_id, p.uid, int(p.revision), int(p.amount), p.source)
		"withdraw": return exchange.withdraw(character_id, p.command_id, p.asset_id, int(p.amount), p.destination)
	return {"ok": false, "error": "request"}

func _market_command(market: MarketStoreSqlite, character_id: int, action: String, p: Dictionary) -> Dictionary:
	match action:
		"list": return market.list_item(character_id, p.command_id, p.uid, int(p.revision), int(p.position), int(p.price))
		"cancel": return market.cancel_offer(character_id, p.command_id, p.offer_id, int(p.revision))
		"claim": return market.claim_item(character_id, p.command_id, p.uid, int(p.revision))
		"configure": return market.configure(character_id, p.command_id, int(p.revision), p.name, p.status)
		"edit": return market.edit_offer(character_id, p.command_id, p.offer_id, int(p.revision), int(p.position), int(p.price))
		"buy":
			if not _runtime.load_wallet(character_id): return {"ok":false,"error":"wallet"}
			return market.purchase(character_id, p.command_id, int(p.shop_id), p.offer_id, int(p.revision), int(p.price), _pending_wallet_deltas())
		"receipt": return market.receipt(character_id, p.command_id)
	return {"ok": false, "error": "request"}

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
			# Search is admitted through AuctionQueryService with asynchronous correlation.
			return {"ok":false,"error":"request"}
		"visit": return MarketStoreSqlite.new(_runtime.db,rejected_commands).visit(int(payload.shop_id))
	return {"ok":false,"error":"request"}
