class_name WorldEconomyService
extends RefCounted
## Local application boundary. Stores own SQL transactions; World owns simulation
## and NPC authorization. The runtime still owns the connection and wallet RAM.
signal market_account_changed(account_id: int)
var _runtime: WorldDatabase
var _marketplace: MarketplaceService

func _init(runtime: WorldDatabase) -> void:
	_runtime = runtime
	_marketplace = MarketplaceService.new(runtime)
	_marketplace.account_changed.connect(market_account_changed.emit)

func market_snapshot(character_id: int) -> Dictionary:
	return _marketplace.snapshot(character_id)

func market_operation(character_id: int, action: String, payload: Dictionary) -> EconomyOperationResult:
	return _marketplace.execute(character_id, action, payload)

func market_query(character_id: int, action: String, payload: Dictionary) -> Dictionary:
	return _marketplace.query(character_id, action, payload)

func purchase_shop_operation(character_id: int, shop: ShopDefinition, offer_id: StringName, requested_position: int = -1) -> EconomyOperationResult:
	var account := _runtime.wallet_account_id(character_id)
	var response: Dictionary
	if _runtime.db == null or not _runtime.runtime_wallets.has(account):
		response = {"ok":false, "error":"storage"}
	else:
		# Store resolves the authoritative offer and capacity before wallet writes.
		response = ShopStoreSqlite.new(_runtime.db).purchase(character_id,
			int(_runtime.runtime_wallets[account].pending_currency_delta), shop, offer_id, requested_position)
	var committed := bool(response.get("ok", false))
	if committed:
		_runtime.accept_committed_wallet_balance(character_id, int(response.balance))
	# No receipts here: each successful call commits a distinct purchase.
	return EconomyOperationResult.capture(character_id, account, "npc_shop.buy", "",
		response, committed, [account] if committed else [])

func upgrade_candidate(character_id: int, uid: String, revision: int, recipe: UpgradeDefinition) -> Dictionary:
	if _runtime.db == null: return {"ok":false,"error":"storage"}
	if recipe == null or not recipe.validation_errors().is_empty(): return {"ok":false,"error":"invalid_definition"}
	return UpgradeStoreSqlite.new(_runtime.db).candidate(character_id, uid, revision, recipe)

func upgrade_operation(character_id: int, recipe: UpgradeDefinition, uid: String, revision: int) -> EconomyOperationResult:
	var account := _runtime.wallet_account_id(character_id)
	var response: Dictionary
	if _runtime.db == null or not _runtime.runtime_wallets.has(account):
		response = {"ok":false, "error":"storage"}
	elif recipe == null or not recipe.validation_errors().is_empty():
		response = {"ok":false, "error":"invalid_definition"}
	elif _runtime.wallet_available(character_id) < recipe.yang_cost:
		response = {"ok":false, "error":"funds"}
	else:
		response = UpgradeStoreSqlite.new(_runtime.db).upgrade(character_id,
			int(_runtime.runtime_wallets[account].pending_currency_delta), recipe, uid, revision)
	var committed := bool(response.get("ok", false))
	if committed:
		_runtime.accept_committed_wallet_balance(character_id, int(response.balance))
	# Upgrades currently use expected UID/revision, not durable operation receipts.
	# Empty operation_id is intentional: UI transport IDs are not durable IDs.
	return EconomyOperationResult.capture(character_id, account, "upgrade", "",
		response, committed, [account] if committed else [])
