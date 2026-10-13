extends "res://tests/web_inventory.gd"
func run_client() -> void:
	web=CoreUiController.new();web.host=HeadlessUiHost.new();world.add_child(web);web.setup(world)
	web.bridge.outgoing.connect(func(json: String)->void:
		var message: Dictionary=JSON.parse_string(json)
		if message.type=="command.result": web_results[str(message.id)]=message.payload)
	web.bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
	register_ready.rpc_id(1)
	await wait_until(func()->bool:return phase_name=="GO")
	var result:=await command("market.buy",{"command_id":"race","shop_id":int(drop_uid.split(":")[0]),"offer_id":drop_uid.split(":")[1],"revision":0,"price":100})
	report.rpc_id(1,result)
	check(result.ok or result.error=="unavailable","two buyers receive one committed outcome")
	check(world.inventory_endpoint.state.items.size()==(3 if result.ok else 2),"winner alone receives UID")
	print("MARKET_RACE_CLIENT_OK ",client_number)
	finished.rpc_id(1);await get_tree().create_timer(.4).timeout;get_tree().quit(1 if failed else 0)
func run_server() -> void:
	await wait_until(func()->bool:return world.characters.size()==2 and ready_peers.size()==2)
	for dog: MobActor3D in world.mob_system.mobs.values(): dog.ai_enabled=false
	var seller:=EconomyFixture.create_character(server.database.store,"offline_seller",{"name":"Offline","skin":1})
	check(server.database.item_store.initialize_character(seller).ok,"offline fixture items")
	var item: Dictionary=server.database.item_store.inventory(seller).items[0]
	var market:=MarketStoreSqlite.new(db)
	var offer:=market.list_item(seller,"list",item.uid,0,0,100)
	check(offer.ok,"offline offer")
	for id: int in world.characters:
		check(server.database.add_yang(server.connected_players[id].player_id,500),"pending buyer income")
		phase.rpc_id(id,"GO",str(offer.shop_id)+":"+offer.offer_id)
	await wait_until(func()->bool:return replies.size()==2 and done_peers.size()==2)
	check(replies.values().filter(func(r: Dictionary)->bool:return r.ok).size()==1,"exactly one buyer wins over real concurrent RPC")
	check(market.mine(seller).offers.is_empty(),"sold escrow removed")
	check(db.query_with_bindings("SELECT yang FROM account_wallets WHERE account_id=?;",[server.database.wallet_account_id(seller)]) and db.query_result[0].yang==1600,"offline seller credited once")
	check(db.query("PRAGMA foreign_key_check;") and db.query_result.is_empty(),"single custody after race")
	print("MARKET_RACE_SERVER_OK two buyers, one UID, one spend/credit, offline seller")
	await get_tree().create_timer(.5).timeout;get_tree().quit(1 if failed else 0)
