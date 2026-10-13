extends "res://tests/web_inventory.gd"
var exchange_snapshot: Dictionary={}
var fixture_roles: Dictionary={}
@rpc("any_peer","call_remote","reliable",0)
func role(number: int) -> void:
	if GameMode.is_world_server(): fixture_roles[multiplayer.get_remote_sender_id()]=number
func run_client() -> void:
	web=CoreUiController.new();web.host=HeadlessUiHost.new();world.add_child(web);web.setup(world)
	web.bridge.outgoing.connect(func(json: String)->void:
		var m: Dictionary=JSON.parse_string(json)
		if m.type=="command.result": web_results[str(m.id)]=m.payload
		elif m.type=="exchange.updated": exchange_snapshot=m.payload
		elif m.type=="ui.snapshot": exchange_snapshot=m.payload.get("exchange",{}))
	web.bridge.receive('{"v":1,"type":"ui.ready","payload":{}}');role.rpc_id(1,client_number);register_ready.rpc_id(1)
	await wait_until(func()->bool:return phase_name=="LIST")
	await web.exchange.open()
	if client_number==1:
		await wait_until(func()->bool:return world.inventory_endpoint.state.items.any(func(i: Dictionary)->bool:return i.definition_id=="upgrade_ore"))
		var ore: Dictionary=world.inventory_endpoint.state.items.filter(func(i: Dictionary)->bool:return i.definition_id=="upgrade_ore")[0]
		check((await command("exchange.deposit",{"command_id":"deposit","uid":ore.uid,"revision":0,"amount":100,"source":"bag"})).ok,"deposit through Web bridge")
		check((await command("exchange.order",{"command_id":"sell","have_asset":"upgrade_ore","want_asset":"yang","quantity":100,"price_num":10,"price_den":1})).ok,"real sell reserves materials")
		report.rpc_id(1,{"order_id":exchange_snapshot.orders[0].id})
	await wait_until(func()->bool:return phase_name=="CANCEL_FILL")
	var result: Dictionary
	if client_number==1: result=await command("exchange.cancel_order",{"command_id":"race_cancel","order_id":drop_uid,"revision":0})
	else: result=await command("exchange.order",{"command_id":"race_buy","have_asset":"yang","want_asset":"upgrade_ore","quantity":60,"price_num":10,"price_den":1})
	check(result.ok or result.get("error")=="stale","cancel/fill has only valid revision outcomes")
	report.rpc_id(1,result)
	await wait_until(func()->bool:return phase_name=="FINALIZE")
	for order: Dictionary in exchange_snapshot.orders.duplicate(true):
		if order.status=="active": check((await command("exchange.cancel_order",{"command_id":"finalize_"+order.id,"order_id":order.id,"revision":order.revision})).ok,"cancel only current remaining reserve")
	if client_number==2:
		# Browser reload discards transport reply, not the native economic intention.
		web.bridge.receive(JSON.stringify({"v":1,"type":"exchange.order","id":"lost","payload":{"command_id":"reload_order","have_asset":"yang","want_asset":"upgrade_ore","quantity":1,"price_num":1,"price_den":1}}))
		web.host.navigation_started.emit();web.bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
		await wait_until(func()->bool:return exchange_snapshot.get("retryAvailable",false))
		check((await command("exchange.retry",{})).ok,"reload retries native retained command ID")
		var active: Array=exchange_snapshot.orders.filter(func(o: Dictionary)->bool:return o.status=="active")
		check(active.size()==1,"retry after lost reply does not create a second order")
		check((await command("exchange.cancel_order",{"command_id":"reload_cancel","order_id":active[0].id,"revision":active[0].revision})).ok,"return retained one-unit reserve")
	print("EXCHANGE_NETWORK_CLIENT_OK ",client_number)
	finished.rpc_id(1);await get_tree().create_timer(.4).timeout;get_tree().quit(1 if failed else 0)
func run_server() -> void:
	await wait_until(func()->bool:return world.characters.size()==2 and ready_peers.size()==2 and fixture_roles.size()==2)
	for dog: MobActor3D in world.mob_system.mobs.values(): dog.ai_enabled=false
	var ids: Array=world.characters.keys()
	ids.sort_custom(func(a: int,b: int)->bool:return fixture_roles[a]<fixture_roles[b])
	# Explicit fixture role registration avoids assumptions about connection timing.
	var seller:=server.connected_players[ids[0]].player_id
	var buyer:=server.connected_players[ids[1]].player_id
	var ore:=ItemInstance.create(ItemDefinitions.UPGRADE_ORE,seller,[]);ore.amount=100
	check(EconomyFixture.insert_item(server.database.item_store,ore,2),"material fixture")
	world.inventory_endpoint.accept_committed_change(ids[0]);check(server.database.add_yang(buyer,1000),"runtime buyer funds")
	for id: int in ids: phase.rpc_id(id,"LIST","")
	await wait_until(func()->bool:return replies.size()==1)
	var order_id: String=replies.values()[0].order_id
	replies.clear()
	for id: int in ids: phase.rpc_id(id,"CANCEL_FILL",order_id)
	await wait_until(func()->bool:return replies.size()==2)
	check(replies.values().all(func(r: Dictionary)->bool:return r.ok or r.get("error")=="stale"),"atomic cancel/fill race")
	for id: int in ids: phase.rpc_id(id,"FINALIZE","")
	await wait_until(func()->bool:return done_peers.size()==2)
	check(db.query("SELECT SUM(free+reserved) AS total,SUM(reserved) AS reserved FROM exchange_assets;") and db.query_result[0].total==100 and db.query_result[0].reserved==0,"race/retry conserve materials and release remainder")
	check(db.query("SELECT SUM(yang) AS total,SUM(reserved_yang) AS reserved FROM account_wallets;") and db.query_result[0].total==1000 and db.query_result[0].reserved==0,"one settlement, no Yang lost/minted")
	check(db.query("SELECT COUNT(*) AS n FROM exchange_orders WHERE status='active';") and db.query_result[0].n==0,"no orphan reservations after finalization")
	print("EXCHANGE_NETWORK_SERVER_OK real bridge/RPC, cancel/fill race, reload lost-reply retry, conservation")
	await get_tree().create_timer(.5).timeout;get_tree().quit(1 if failed else 0)
