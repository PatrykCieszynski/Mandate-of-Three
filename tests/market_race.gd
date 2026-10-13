extends "res://tests/web_inventory.gd"
var browser_snapshot: Dictionary={}
var dom_snapshot: Dictionary={}
func run_client() -> void:
	var native: bool=CmdlineUtils.get_parsed_args().has("native-market-check")
	if native:
		web=world.get_node("WebInventory")
		await wait_until(func()->bool:return web.bridge.is_ready)
		web.host.message_received.connect(func(raw: String)->void:
			var m: Variant=JSON.parse_string(raw)
			if m is Dictionary and m.get("fixture")=="market": dom_snapshot=m)
	else:
		web=CoreUiController.new();web.host=HeadlessUiHost.new();world.add_child(web);web.setup(world)
	web.bridge.outgoing.connect(func(json: String)->void:
		var message: Dictionary=JSON.parse_string(json)
		if message.type=="market_browser.updated": browser_snapshot=message.payload
		if message.type=="command.result": web_results[str(message.id)]=message.payload)
	web.bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
	register_ready.rpc_id(1)
	await wait_until(func()->bool:return phase_name=="GO")
	await web.market_browser.open()
	check((await command("market.browser.catalog",{"query":"miecz"})).ok,"normalized catalog through real Web command")
	var filters: Dictionary={"definition_id":"iron_sword","upgrade_min":7,"upgrade_max":9,"price_min":0,"price_max":9000000000000000,"affix_filters":[{"stat_id":"monster_damage","minimum":10},{"stat_id":"critical_chance","minimum":5}],"sort":"price_asc","cursor":"","limit":20}
	check((await command("market.browser.search",filters)).ok,"indexed AND search through native adapter")
	check(browser_snapshot.results.size()==1,"one +9 matching rolled offer")
	var found: Dictionary=browser_snapshot.results[0]
	check((await command("market.browser.visit",{"shop_id":found.shopId,"offer_id":found.offerId})).ok,"result opens full shop without buying")
	check(browser_snapshot.shop.offers.size()==1 and browser_snapshot.highlight==found.offerId,"full shop highlights requested offer")
	if native:
		check(web.host.browser.has_method("eval"),"pinned CEF eval method present (test only)")
		await get_tree().create_timer(.5).timeout
		web.host.browser.call("eval","window.sendIpcMessage(JSON.stringify({fixture:'market',visible:!document.querySelector('#market-browser').hidden,rows:document.querySelectorAll('.market-results tbody tr').length,shop:!document.querySelector('#market-visitor').hidden,highlight:document.querySelectorAll('.market-highlight').length}));")
		await wait_until(func()->bool:return not dom_snapshot.is_empty())
		check(dom_snapshot.visible and dom_snapshot.rows==1 and dom_snapshot.shop and dom_snapshot.highlight==1,"real CEF renders search and full highlighted shop")
		web.host.browser.call("eval","document.querySelector('[aria-label=\"Base item\"]').focus();")
		await wait_until(func()->bool:return ClientState.menu_open)
		web.host.browser.call("eval","document.activeElement.blur();")
		await wait_until(func()->bool:return not ClientState.menu_open)
		DisplayServer.window_set_size(Vector2i(960,640))
		await get_tree().create_timer(.3).timeout
		web.host.reload()
		await wait_until(func()->bool:return web.bridge.is_ready)
		await get_tree().create_timer(.6).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://.godot/verification/market-native.png")
		print("MARKET_NATIVE_OK Vulkan Mobile CEF UI_READY, render, focus lease, resize, reload snapshot")
	if CmdlineUtils.get_parsed_args().has("native-market-peer"): await get_tree().create_timer(3).timeout
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
	check(db.query_with_bindings("UPDATE item_instances SET upgrade_level=9,affixes_json=? WHERE uid=?;",[JSON.stringify([{"stat":"monster_damage","value":15},{"stat":"critical_chance","value":7}]),item.uid]),"rolled search fixture")
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
