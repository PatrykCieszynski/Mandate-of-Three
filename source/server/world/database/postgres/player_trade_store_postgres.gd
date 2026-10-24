extends RefCounted
## One native transaction owns both accounts, UIDs, wallets and participant receipts.
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const Codec = preload("res://source/server/world/database/economy_receipt_codec.gd")
var db: Object
var committed:=false
var receipt_replay:=false
func _init(database: Object) -> void: db=database

func execute(id: String, participants: Array) -> Dictionary:
	if participants.size()!=2 or not Commands.valid_id(id): return {"ok":false,"error":"request"}
	var a: Dictionary=participants[0];var b: Dictionary=participants[1]
	if a.context.account_id==b.context.account_id or a.context.character==b.context.character: return {"ok":false,"error":"owner"}
	var tx:=Commands.new(db)
	tx.economic_context=a.context
	if not tx.begin(a.context.character,id,"player.trade",[participants],true,b.context.account_id):
		receipt_replay=tx.receipt_replay
		return tx.cached
	var reason:=Sessions.check_in_transaction(db,b.context.account_id,b.context.character,b.context)
	if not reason.is_empty(): return tx.rollback(reason)
	var other: Dictionary=db.query("SELECT command_id FROM economy.market_commands WHERE account_id=:account AND command_id=:id;",{"account":b.context.account_id,"id":id})
	if not other.ok: return tx.rollback("storage")
	if not other.rows.is_empty(): return tx.rollback("command_conflict")
	var selected: Array=[];var seen: Dictionary={};var incomes: Dictionary={}
	for side: Dictionary in participants:
		var account: int=side.context.account_id
		if not side.get("yang") is int or side.yang<0 or side.yang>Wallet.MAX_YANG or side.items.size()>8: return tx.rollback("request")
		var captured: Dictionary=Wallet.new(db).capture_income_in_transaction(account,side.income)
		if not captured.ok: return tx.rollback(str(captured.error))
		if side.yang>captured.balance-captured.reserved_yang: return tx.rollback("funds")
		incomes[account]=captured
		for offer: Dictionary in side.items:
			if seen.has(offer.uid): return tx.rollback("duplicate_item")
			seen[offer.uid]=true
			var found: Dictionary=db.query(Items.ITEM_SELECT+"WHERE i.uid=:uid FOR UPDATE OF i,c;",{"uid":offer.uid})
			if not found.ok: return tx.rollback("storage")
			if found.rows.size()!=1: return tx.rollback("item")
			var item:=ItemInstance.from_row(found.rows[0])
			var definition:=ItemDefinitions.get_definition(item.definition_id) if item!=null else null
			if item==null or definition==null or not definition.tradeable or item.owner_character_id!=side.context.character or item.location!="bag" or item.revision!=offer.revision: return tx.rollback("item_changed")
			selected.append({"item":item,"height":definition.inventory_height,"recipient":b.context.character if side==a else a.context.character})
	if selected.is_empty() and a.yang==0 and b.yang==0: return tx.rollback("empty_trade")
	# Free all outgoing footprints before allocating incoming ones, allowing full-bag swaps.
	for choice: Dictionary in selected:
		if not db.execute("DELETE FROM economy.item_custody WHERE uid=:uid;",{"uid":choice.item.uid}).ok: return tx.rollback("storage")
	for choice: Dictionary in selected:
		var item: ItemInstance=choice.item
		var position:=Items.new(db).resolve_inventory_position(choice.recipient,choice.height)
		if not position.ok: return tx.rollback(str(position.error))
		var changed: Dictionary=db.execute("UPDATE economy.item_instances SET owner_character_id=:owner,revision=revision+1 WHERE uid=:uid AND revision=:revision;",{"owner":choice.recipient,"uid":item.uid,"revision":item.revision})
		if not changed.ok or changed.affected_rows!=1: return tx.rollback("storage")
		if not db.execute("INSERT INTO economy.item_custody(uid,owner_id,location,position) VALUES(:uid,:owner,'bag',:position);",{"uid":item.uid,"owner":choice.recipient,"position":position.position}).ok: return tx.rollback("storage")
	var tokens: Dictionary={}
	for side: Dictionary in participants:
		var account: int=side.context.account_id
		var incoming: int=b.yang if side==a else a.yang
		var balance: int=incomes[account].balance-side.yang
		if incoming>Wallet.MAX_YANG-balance: return tx.rollback("wallet_full")
		if not db.execute("UPDATE economy.account_wallets SET yang=:amount WHERE account_id=:account;",{"amount":balance+incoming,"account":account}).ok: return tx.rollback("storage")
		tokens[str(account)]=side.token
	var result: Dictionary={"ok":true,"trade_id":id,"income_tokens":tokens}
	var second:=result.duplicate(true)
	second.item_state=Commands.read_state(db,b.context.character)
	if second.item_state.is_empty(): return tx.rollback("storage")
	if not db.execute("INSERT INTO economy.market_commands(account_id,command_id,character_id,kind,request_json,result_json) VALUES(:account,:id,:character,'player.trade',:request,:result);",{"account":b.context.account_id,"id":id,"character":b.context.character,"request":JSON.stringify([participants]),"result":Codec.encode_result(second)}).ok: return tx.rollback("storage")
	result=tx.commit(result)
	committed=tx.committed
	return result

func receipt(context: Dictionary, id: String) -> Dictionary:
	if not Commands.valid_id(id): return {"ok":false,"error":"request"}
	var begun:=Sessions.new(db).begin_context(context)
	if not begun.ok: return begun
	var found: Dictionary=db.query("SELECT result_json FROM economy.market_commands WHERE account_id=:account AND command_id=:id AND kind='player.trade';",{"account":context.account_id,"id":id})
	if not found.ok:
		if not db.rollback(): db.close()
		return {"ok":false,"error":"storage"}
	var result: Dictionary={"ok":false,"error":"not_committed","resolved":true} if found.rows.is_empty() else Commands.decode(found.rows[0].result_json)
	if not db.commit():
		db.close();return {"ok":false,"error":"outcome_unknown","outcome_unknown":true}
	receipt_replay=result.get("ok",false)
	return result

## Trusted coordinator-only recovery after a worker completion was uncertain.
## This reads outcomes under both original account locks, even after logout/relogin.
func recover(id: String, accounts: Array) -> Dictionary:
	if not Commands.valid_id(id) or accounts.size()!=2 or db.in_transaction() or not db.begin(): return {"ok":false,"error":"storage"}
	var sorted: Array=accounts.duplicate();sorted.sort()
	for account: int in sorted:
		if not db.query("SELECT account_id FROM economy.accounts WHERE account_id=:account FOR NO KEY UPDATE;",{"account":account}).ok:
			db.rollback();return {"ok":false,"error":"storage"}
	var found: Dictionary=db.query("SELECT result_json FROM economy.market_commands WHERE account_id=:account AND command_id=:id AND kind='player.trade';",{"account":accounts[0],"id":id})
	if not found.ok:
		db.rollback();return {"ok":false,"error":"storage"}
	var result: Dictionary={"ok":false,"error":"not_committed","resolved":true} if found.rows.is_empty() else Commands.decode(str(found.rows[0].result_json))
	if not db.commit():
		db.close();return {"ok":false,"error":"outcome_unknown","outcome_unknown":true}
	receipt_replay=result.get("ok",false)
	return result
