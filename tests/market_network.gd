extends "res://tests/web_inventory.gd"
## Existing real bridge/session harness, new marketplace ownership/reload contracts.
func run_client() -> void:
	web = CoreUiController.new()
	web.host = HeadlessUiHost.new()
	world.add_child(web)
	web.setup(world)
	web.bridge.outgoing.connect(func(json: String) -> void:
		var message: Dictionary = JSON.parse_string(json)
		if message.type=="command.result": web_results[str(message.id)] = message.payload)
	web.bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
	register_ready.rpc_id(1)
	await wait_until(func() -> bool: return phase_name=="GO")
	check((await web.market.open()).ok,"open own account shop")
	var original: Dictionary = world.inventory_endpoint.state.items[0].duplicate(true)
	check((await command("market.list",{"command_id":"list_a","uid":original.uid,"revision":original.revision,"position":0,"price":100})).ok,"real bridge lists bag item")
	await wait_until(func() -> bool: return world.market_endpoint.state.offers.size()==1)
	check(not world.inventory_endpoint.state.items.any(func(i: Dictionary) -> bool: return i.uid==original.uid),"authoritative inventory removes escrow UID")
	var offer: Dictionary = world.market_endpoint.state.offers[0].duplicate(true)
	check((await command("market.edit",{"command_id":"edit_a","offer_id":offer.offer_id,"revision":0,"position":12,"price":321})).ok,"move/reprice through explicit native adapter")
	check(world.market_endpoint.state.offers[0].position==12 and world.market_endpoint.state.offers[0].price==321,"exact persisted layout/price snapshot")
	check((await command("market.configure",{"command_id":"name_a","revision":0,"name":"Bread Shop","status":"paused"})).ok,"name and pause server transaction")
	check(world.market_endpoint.state.name=="Bread Shop" and world.market_endpoint.state.status=="paused","presentation follows authoritative configuration")
	# Reload recreates transport while server state and receipt outcomes survive.
	web.host.navigation_started.emit()
	web.bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
	check(world.market_endpoint.state.offers.size()==1,"reload keeps client market snapshot")
	check((await command("market.edit",{"command_id":"edit_a","offer_id":offer.offer_id,"revision":0,"position":12,"price":321})).ok,"old command retry after reload returns receipt")
	check((await command("market.cancel",{"command_id":"cancel_a","offer_id":offer.offer_id,"revision":1})).ok,"cancel becomes account claim")
	var claim: Dictionary = world.market_endpoint.state.claims[0]
	check((await command("market.claim",{"command_id":"claim_a","uid":claim.uid,"revision":claim.revision})).ok,"claim restores persistent UID to bag")
	check(world.inventory_endpoint.state.items.any(func(i: Dictionary) -> bool: return i.uid==original.uid),"claim preserves original UID")
	web.bridge.receive('{"v":1,"type":"ui.text_focus","payload":{"active":true}}')
	check(ClientState.menu_open,"explicit text field focus captures gameplay keyboard")
	web.bridge.receive('{"v":1,"type":"ui.text_focus","payload":{"active":false}}')
	check(not ClientState.menu_open,"text blur restores gameplay keyboard")
	check((await command("market.close",{})).ok and not web.market.active,"close releases the market view")
	print("MARKET_CLIENT_OK ",client_number)
	finished.rpc_id(1)
	await get_tree().create_timer(.4).timeout
	get_tree().quit(1 if failed else 0)

func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size()==2 and ready_peers.size()==2)
	for dog: MobActor3D in world.mob_system.mobs.values(): dog.ai_enabled=false
	for id: int in world.characters: phase.rpc_id(id,"GO","")
	await wait_until(func() -> bool: return done_peers.size()==2)
	for id: int in world.characters:
		var owner: int = server.connected_players[id].player_id
		var snapshot := server.database.market_snapshot(owner)
		check(snapshot.name=="Bread Shop" and snapshot.status=="paused" and snapshot.offers.is_empty() and snapshot.claims.is_empty(),"durable private shop state")
		check(server.database.item_store.inventory(owner).items.size()==2,"no duplicate/lost items after full flow")
	check(db.query("PRAGMA foreign_key_check;") and db.query_result.is_empty(),"network commands preserve global SQL custody")
	print("MARKET_SERVER_OK native bridge/RPC, private shops, move/price/status, reload receipt, cancel/claim")
	await get_tree().create_timer(.5).timeout
	get_tree().quit()
