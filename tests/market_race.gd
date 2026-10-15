extends "res://tests/web_inventory.gd"
var browser_snapshot: Dictionary={}
var dom_snapshot: Dictionary={}
var native_buy_id := ""
var native_focus_observed := false
var native_peer := 0
var native_command_ids: Dictionary={}
var browsed_peers: Dictionary={}
var inventory_commits := 0
@rpc("any_peer","call_remote","reliable",0)
func register_browsed() -> void:
	if GameMode.is_world_server(): browsed_peers[multiplayer.get_remote_sender_id()]=true
@rpc("any_peer","call_remote","reliable",0)
func register_native() -> void:
	if GameMode.is_world_server(): native_peer=multiplayer.get_remote_sender_id()
func run_client() -> void:
	var native: bool=CmdlineUtils.get_parsed_args().has("native-market-check")
	if native:
		web=world.get_node("WebInventory")
		print("MARKET_NATIVE_START client fixture, browser=",is_instance_valid(web.host.browser))
		web.host.keyboard_owner_changed.connect(func(owner: String)->void:
			if owner=="web" and ClientState.menu_open: native_focus_observed=true)
		web.bridge.rejected.connect(func(reason: String)->void: print("MARKET_NATIVE_REJECT ",reason))
		web.bridge.ui_ready.connect(func()->void:print("MARKET_NATIVE_READY"))
		web.host.navigation_started.connect(func()->void:print("MARKET_NATIVE_NAV generation=",web.bridge.generation()))
		web.host.message_received.connect(func(raw: String)->void:
			var m: Variant=JSON.parse_string(raw)
			if m is Dictionary and m.get("type")=="ui.ready": print("MARKET_NATIVE_IN_READY ",web.bridge.is_ready)
			if m is Dictionary and m.get("fixture")=="market": dom_snapshot.merge(m,true)
			elif m is Dictionary and m.has("id"):
				native_command_ids[str(m.type)]=str(m.id)
				if m.type=="market.buy": native_buy_id=str(m.id))
		await get_tree().create_timer(2).timeout
		web.host.browser.call("eval","window.sendIpcMessage(JSON.stringify({fixture:'market',startup:true,ready:document.readyState,roots:document.querySelectorAll('main').length,windows:document.querySelectorAll('.window-chrome').length,skin:getComputedStyle(document.documentElement).getPropertyValue('--skin-window-frame'),resources:performance.getEntriesByType('resource').map(r=>({name:r.name,end:r.responseEnd})).slice(-8),text:document.body.innerText.slice(0,100)}));")
		web.host.browser.call("eval","import(new URL('game.js',location.href).href).catch(e=>window.sendIpcMessage(JSON.stringify({fixture:'market',error:String(e),stack:e.stack}))); ")
		await get_tree().create_timer(.3).timeout
		print("MARKET_NATIVE_BOOT ",dom_snapshot)
		dom_snapshot={}
		await wait_until(func()->bool:return web.bridge.is_ready)
	else:
		web=CoreUiController.new();web.host=HeadlessUiHost.new();world.add_child(web);web.setup(world)
	web.bridge.outgoing.connect(func(json: String)->void:
		var message: Dictionary=JSON.parse_string(json)
		if message.type=="market_browser.updated": browser_snapshot=message.payload
		if message.type=="command.result": web_results[str(message.id)]=message.payload)
	if not native: web.bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
	fixture_checkpoint="waiting GO"
	if native: register_native.rpc_id(1)
	register_ready.rpc_id(1)
	await wait_until(func()->bool:return phase_name=="GO")
	fixture_checkpoint="open browser"
	await web.market_browser.open()
	fixture_checkpoint="catalog"
	check((await command("market.browser.catalog",{"query":"miecz"})).ok,"normalized catalog through real Web command")
	fixture_checkpoint="search"
	var filters: Dictionary={"definition_id":"iron_sword","upgrade_min":7,"upgrade_max":9,"price_min":0,"price_max":9000000000000000,"affix_filters":[{"stat_id":"monster_damage","minimum":10},{"stat_id":"critical_chance","minimum":5}],"sort":"price_asc","cursor":"","limit":20}
	var searched:=await command("market.browser.search",filters)
	# Aggregate World budget may reject one of the simultaneous clients. Retry is
	# a new read, never an economic mutation or an unbounded queued job.
	for retry: int in 3:
		if searched.get("error","")!="rate_limited": break
		await get_tree().create_timer(0.25).timeout
		searched=await command("market.browser.search",filters)
	check(searched.ok,"indexed AND search through native adapter after bounded load shedding")
	check(browser_snapshot.results.size()==1,"one +9 matching rolled offer")
	fixture_checkpoint="visit"
	var found: Dictionary=browser_snapshot.results[0]
	check((await command("market.browser.visit",{"shop_id":found.shopId,"offer_id":found.offerId})).ok,"result opens full shop without buying")
	check(browser_snapshot.shop.offers.size()==1 and browser_snapshot.highlight==found.offerId,"full shop highlights requested offer")
	if native:
		fixture_checkpoint="DOM presentation"
		check(web.host.browser.has_method("eval"),"pinned CEF eval method present (test only)")
		await get_tree().create_timer(.5).timeout
		web.host.browser.call("eval","window.sendIpcMessage(JSON.stringify({fixture:'market',visible:!document.querySelector('#market-browser').hidden,rows:document.querySelectorAll('.market-results tbody tr').length,shop:!document.querySelector('#market-visitor').hidden,highlight:document.querySelectorAll('.market-highlight').length,focusX:document.querySelector('[aria-label=\"Base item\"]').getBoundingClientRect().x+10,focusY:document.querySelector('[aria-label=\"Base item\"]').getBoundingClientRect().y+10}));")
		await wait_until(func()->bool:return not dom_snapshot.is_empty())
		check(dom_snapshot.visible and dom_snapshot.rows==1 and dom_snapshot.shop and dom_snapshot.highlight==1,"real CEF renders search and full highlighted shop")
		fixture_checkpoint="focus lease"
		var point:=Vector2(float(dom_snapshot.focusX),float(dom_snapshot.focusY))
		var motion:=InputEventMouseMotion.new();motion.position=point;motion.global_position=point;Input.parse_input_event(motion)
		for pressed: bool in [true,false]:
			var click:=InputEventMouseButton.new();click.position=point;click.global_position=point;click.button_index=MOUSE_BUTTON_LEFT;click.pressed=pressed;Input.parse_input_event(click)
			await get_tree().process_frame
		# Background/offscreen fixture: establish native control focus explicitly.
		# The subsequent DOM field focus must request its real presentation lease.
		web.host.browser.focus_mode=Control.FOCUS_ALL;web.host.browser.grab_focus()
		await get_tree().process_frame
		web.host.browser.call("eval","document.querySelector('[aria-label=\"Base item\"]').focus();")
		await wait_until(func()->bool:return native_focus_observed)
		web.host.browser.call("eval","document.activeElement.blur();")
		await wait_until(func()->bool:return not ClientState.menu_open)
		fixture_checkpoint="resize/reload"
		DisplayServer.window_set_size(Vector2i(960,640))
		await get_tree().create_timer(.3).timeout
		web.host.reload_ui()
		await wait_until(func()->bool:return web.bridge.is_ready)
		await get_tree().create_timer(.6).timeout
		fixture_checkpoint="frame readback"
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://.godot/verification/market-native.png")
		print("MARKET_NATIVE_OK Vulkan Mobile CEF UI_READY, render, focus lease, resize, reload snapshot")
	register_browsed.rpc_id(1)
	await wait_until(func()->bool:return phase_name=="RACE")
	if CmdlineUtils.get_parsed_args().has("native-market-peer"): await get_tree().create_timer(3).timeout
	var result: Dictionary
	if native:
		web.host.browser.call("eval","Array.from(document.querySelectorAll('button')).find(b=>b.textContent==='Buy selected item').click();")
		await wait_until(func()->bool:return not native_buy_id.is_empty() and web_results.has(native_buy_id))
		result=web_results[native_buy_id]
		await get_tree().create_timer(.12).timeout
	else:
		result=await command("market.buy",{"command_id":"race","shop_id":int(drop_uid.split(":")[0]),"offer_id":drop_uid.split(":")[1],"revision":0,"price":100})
	if result.ok and not native:
		var retried := await command("market.buy", {"command_id":"race","shop_id":int(drop_uid.split(":")[0]),"offer_id":drop_uid.split(":")[1],"revision":0,"price":100})
		check(retried.ok and world.inventory_endpoint.state.items.size() == 3, "replay repairs current inventory without granting another item")
	report.rpc_id(1,result)
	check(result.ok or result.error=="unavailable","two buyers receive one committed outcome")
	check(world.inventory_endpoint.state.items.size()==(3 if result.ok else 2),"winner alone receives UID")
	if native: await native_exchange_flow()
	print("MARKET_RACE_CLIENT_OK ",client_number)
	finished.rpc_id(1);await get_tree().create_timer(.4).timeout;get_tree().quit(1 if failed else 0)
func run_server() -> void:
	await wait_until(func()->bool:return world.characters.size()==2 and ready_peers.size()==2)
	for dog: MobActor3D in world.mob_system.mobs.values(): dog.ai_enabled=false
	world.inventory_endpoint.inventory_changed.connect(func(_owner: int) -> void: inventory_commits += 1)
	var seller:=EconomyFixture.create_character(server.database.store,"offline_seller",{"name":"Offline","skin":1})
	check(server.database.item_store.initialize_character(seller).ok,"offline fixture items")
	var item: Dictionary=server.database.item_store.inventory(seller).items[0]
	check(db.query_with_bindings("UPDATE item_instances SET upgrade_level=9,affixes_json=? WHERE uid=?;",[JSON.stringify([{"stat":"monster_damage","value":15},{"stat":"critical_chance","value":7}]),item.uid]),"rolled search fixture")
	var market:=MarketStoreSqlite.new(db)
	var offer:=market.list_item(seller,"list",item.uid,0,0,100)
	check(offer.ok,"offline offer")
	if CmdlineUtils.get_parsed_args().has("native-market-server"):
		await wait_until(func()->bool:return native_peer>0)
		var owner: int=server.connected_players[native_peer].player_id
		var ore:=ItemInstance.create(ItemDefinitions.UPGRADE_ORE,owner,[]);ore.amount=40
		var slot:=server.database.item_store._free_bag_position(owner,1)
		check(EconomyFixture.insert_item(server.database.item_store,ore,slot),"native UI fixture material source")
		check(ExchangeStoreSqlite.new(db).deposit(owner,"native_seed",ore.uid,0,40,"bag").ok,"real fixture deposit to ledger")
	# Match production startup: the retired fixture had no native auction reader,
	# so all searches returned storage before reaching the purchase race.
	server.database.database_path = db.path
	check(db.query("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;"), "race WAL writer")
	check(await server.database.start_auction_queries(), "race native reader startup")
	for id: int in world.characters:
		check(server.database.add_yang(server.connected_players[id].player_id,500),"pending buyer income")
		phase.rpc_id(id,"GO",str(offer.shop_id)+":"+offer.offer_id)
	# Barrier: both buyers must browse before either may consume the shared offer.
	# Load shedding changes read completion order, not the purchase-race contract.
	await wait_until(func()->bool:return browsed_peers.size()==2)
	for id: int in world.characters: phase.rpc_id(id,"RACE",str(offer.shop_id)+":"+offer.offer_id)
	await wait_until(func()->bool:return replies.size()==2 and done_peers.size()==2)
	check(replies.values().filter(func(r: Dictionary)->bool:return r.ok).size()==1,"exactly one buyer wins over real concurrent RPC")
	check(market.mine(seller).offers.is_empty(),"sold escrow removed")
	check(db.query_with_bindings("SELECT yang FROM account_wallets WHERE account_id=?;",[server.database.wallet_account_id(seller)]) and db.query_result[0].yang==1600,"offline seller credited once")
	check(db.query("PRAGMA foreign_key_check;") and db.query_result.is_empty(),"single custody after race")
	if not CmdlineUtils.get_parsed_args().has("native-market-server"):
		check(inventory_commits == 1, "one real inventory commit across successful buy and replay")
	check(await server.database.auction_queries.pause(), "race reader drained before fixture DB teardown")
	print("MARKET_RACE_SERVER_OK two buyers, one UID, one spend/credit, offline seller")
	await get_tree().create_timer(.5).timeout;get_tree().quit(1 if failed else 0)

var native_diagnostic_printed := false
func _process(delta: float) -> void:
	super(delta)
	if CmdlineUtils.get_parsed_args().has("native-market-check") and not native_diagnostic_printed and elapsed>5:
		native_diagnostic_printed=true
		print("MARKET_NATIVE_WAIT world=",world!=null," inventory=",world.inventory_endpoint.state.get("ok",false) if world!=null else false," wallet=",world.currency_endpoint.state if world!=null else {}," running=",running," phase=",phase_name," checkpoint=",fixture_checkpoint," ui_ready=",web.bridge.is_ready if web!=null else false)

func native_exchange_flow() -> void:
	fixture_checkpoint="native Exchange open"
	await web.exchange.open();await get_tree().create_timer(.3).timeout
	web.host.browser.call("eval","document.querySelector('[aria-label=\"Have asset\"]').value='upgrade_ore';document.querySelector('[aria-label=\"Want asset\"]').value='yang';document.querySelector('[aria-label=\"Ore quantity\"]').value='40';document.querySelector('[aria-label=\"Yang numerator\"]').value='10';document.querySelector('[aria-label=\"Ore denominator\"]').value='1';Array.from(document.querySelectorAll('#exchange button')).find(b=>b.textContent==='Place limit order').click();")
	await wait_until(func()->bool:return native_command_ids.has("exchange.order") and web_results.has(native_command_ids["exchange.order"]))
	check(web_results[native_command_ids["exchange.order"]].ok,"actual CEF Exchange button commits an order")
	await get_tree().create_timer(.3).timeout
	web.host.browser.call("eval","Array.from(document.querySelectorAll('#exchange button')).find(b=>b.textContent==='Cancel remaining').click();")
	await wait_until(func()->bool:return native_command_ids.has("exchange.cancel_order") and web_results.has(native_command_ids["exchange.cancel_order"]))
	check(web_results[native_command_ids["exchange.cancel_order"]].ok,"actual CEF cancellation returns reservation")
	await get_tree().create_timer(.3).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://.godot/verification/exchange-native.png")
	print("EXCHANGE_NATIVE_OK actual order/cancel through CEF JS bridge/RPC/SQL, ledger free/reserved")
