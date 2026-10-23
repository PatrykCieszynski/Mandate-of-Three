extends RefCounted
## Explicit NPC Shop/Upgrade worker boundary. Only server-authored definitions
## cross as copied primitive data; no live NPC/World objects or client prices.
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Shop = preload("res://source/server/world/database/postgres/npc_shop_store_postgres.gd")
const Vendor = preload("res://source/server/world/database/postgres/vendor_sell_store_postgres.gd")
const Upgrade = preload("res://source/server/world/database/postgres/upgrade_store_postgres.gd")
var db: Object
var committed:=false
var receipt_replay:=false

func _init(database: Object) -> void: db=database

static func shop_content(shop: ShopDefinition) -> Dictionary:
	var offers: Array=[]
	for offer: ShopOfferDefinition in shop.offers:
		offers.append({"id":str(offer.offer_id),"item":str(offer.item_definition_id),"quantity":offer.quantity,"price":offer.price,"stock":int(offer.stock_policy)})
	return {"id":str(shop.shop_id),"name":shop.display_name,"currency":str(shop.currency_id),"offers":offers}

static func upgrade_content(recipe: UpgradeDefinition) -> Dictionary:
	return {"id":str(recipe.upgrade_id),"item":str(recipe.item_definition_id),"from":recipe.from_level,"to":recipe.to_level,"cost":recipe.yang_cost,"material":str(recipe.material_definition_id),"amount":recipe.material_amount,"success":recipe.success_rate}

func execute(context: Dictionary, kind: String, id: String, body: Dictionary, income: int, token: String) -> Dictionary:
	if kind=="sell":
		var store:=Vendor.new(db)
		store.authorize_session(context,token)
		var result: Dictionary=store.sell(context.character,income,body.quote,id)
		committed=store.committed;receipt_replay=store.receipt_replay
		return result
	if kind=="buy":
		var content: Dictionary=body.content
		var definition:=ShopDefinition.new()
		definition.shop_id=StringName(content.id)
		definition.display_name=content.name
		definition.currency_id=StringName(content.currency)
		for entry: Dictionary in content.offers:
			var offer:=ShopOfferDefinition.new()
			offer.offer_id=StringName(entry.id)
			offer.item_definition_id=StringName(entry.item)
			offer.quantity=entry.quantity
			offer.price=entry.price
			offer.stock_policy=entry.stock
			definition.offers.append(offer)
		var store:=Shop.new(db)
		store.authorize_session(context,token)
		var result: Dictionary=store.purchase(context.character,income,definition,StringName(body.offer),body.position,id)
		committed=store.committed
		receipt_replay=store.receipt_replay
		return result
	if kind=="upgrade":
		var content: Dictionary=body.content
		var definition:=UpgradeDefinition.new()
		definition.upgrade_id=StringName(content.id)
		definition.item_definition_id=StringName(content.item)
		definition.from_level=content.from
		definition.to_level=content.to
		definition.yang_cost=content.cost
		definition.material_definition_id=StringName(content.material)
		definition.material_amount=content.amount
		definition.success_rate=content.success
		var store:=Upgrade.new(db)
		store.authorize_session(context,token)
		var result: Dictionary=store.upgrade(context.character,income,definition,body.uid,body.revision,id)
		committed=store.committed
		receipt_replay=store.receipt_replay
		return result
	return {"ok":false,"error":"request"}

## Read-only original-character lookup; current same-account authority is still
## required. Account lock orders this after any older in-flight mutation.
func receipt(context: Dictionary, issuer: int, kind: String, id: String) -> Dictionary:
	if kind not in ["buy","upgrade","sell"] or not Commands.valid_id(id) or issuer<=0: return {"ok":false,"error":"request"}
	var begun:=Sessions.new(db).begin_context(context)
	if not begun.ok: return begun
	var found: Dictionary=db.query("SELECT result_json FROM economy.market_commands WHERE account_id=:account AND character_id=:issuer AND command_id=:id AND kind=:kind;",{"account":context.account_id,"issuer":issuer,"id":id,"kind":"vendor.sell" if kind=="sell" else ("npc_shop.buy" if kind=="buy" else "upgrade")})
	if not found.ok:
		if not db.rollback(): db.close()
		return {"ok":false,"error":"storage"}
	var result: Dictionary={"ok":false,"error":"unknown_command"} if found.rows.is_empty() else Commands.decode(str(found.rows[0].result_json))
	if not db.commit():
		db.close()
		return {"ok":false,"error":"outcome_unknown","outcome_unknown":true}
	receipt_replay=result.get("ok",false)
	return result
