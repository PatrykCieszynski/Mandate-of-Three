extends "res://tests/web_inventory.gd"
## Existing real bridge/session harness, new marketplace ownership/reload contracts.
var rpc_answers: Dictionary={}

func verify_query_retries() -> void:
	await wait_until(func()->bool:return phase_name=="RPC_RETRY")
	world.market_endpoint.query_finished.connect(func(id: String, answer: Dictionary)->void:
		if not id.begins_with("review_"): return
		if not rpc_answers.has(id): rpc_answers[id]=[]
		rpc_answers[id].append(answer))
	var p: Dictionary={"definition_id":"iron_sword","upgrade_min":0,"upgrade_max":9,"price_min":0,"price_max":9000000000000000,"affix_filters":[],"sort":"price_asc","cursor":"","limit":50}
	world.market_endpoint.request_query.rpc_id(1,"search",p,"review_pending")
	var malformed:=p.duplicate(true);malformed.cursor="broken"
	for attempt: int in 20:
		world.market_endpoint.request_query.rpc_id(1,"search" if attempt%3!=0 else "catalog",malformed if attempt%2==0 else {},"review_pending")
	# Pending duplicates must not consume the endpoint's eight distinct turns.
	for number: int in 7: world.market_endpoint.request_query.rpc_id(1,"catalog",{"query":"sword"},"review_budget%d" % number)
	world.market_endpoint.request_query.rpc_id(1,"catalog",{"query":"sword"},"review_over")
	world.market_endpoint.request_query.rpc_id(1,"search",{},"review_over")
	# Flood recent-history capacity, then retry the original accepted pending ID.
	for number: int in 80: world.market_endpoint.request_query.rpc_id(1,"search",{},"review_noise%d" % number)
	world.market_endpoint.request_query.rpc_id(1,"search",p,"review_pending")
	world.market_endpoint.request_query.rpc_id(1,"search",malformed,"review_pending")
	await wait_until(func()->bool:return rpc_answers.size()==88)
	check(not rpc_answers.has("review_pending"),"held original receives no limiter or malformed-retry reply")
	for number: int in 7: check(rpc_answers["review_budget%d" % number].size()==1 and rpc_answers["review_budget%d" % number][0].ok,"duplicate IDs do not consume peer budget")
	check(rpc_answers.review_over.size()==1 and rpc_answers.review_over[0].error=="rate_limited","same rejected ID settles once while retained")
	report.rpc_id(1,{"duplicates_waiting":true})
	await wait_until(func()->bool:return rpc_answers.has("review_pending"))
	await get_tree().create_timer(.05).timeout
	check(rpc_answers.review_pending.size()==1 and rpc_answers.review_pending[0].ok,"accepted ID survives history pressure and receives one original success")
	await get_tree().create_timer(1.1).timeout
	world.market_endpoint.request_query.rpc_id(1,"search",{},"review_invalid_first")
	world.market_endpoint.request_query.rpc_id(1,"search",p,"review_invalid_first")
	world.market_endpoint.request_query.rpc_id(1,"search",malformed,"review_cursor_first")
	world.market_endpoint.request_query.rpc_id(1,"search",p,"review_cursor_first")
	await wait_until(func()->bool:return rpc_answers.has("review_invalid_first") and rpc_answers.has("review_cursor_first"))
	await get_tree().create_timer(.05).timeout
	check(rpc_answers.review_invalid_first.size()==1 and rpc_answers.review_invalid_first[0].error=="request","invalid-first ID cannot later start a valid search")
	check(rpc_answers.review_cursor_first.size()==1 and rpc_answers.review_cursor_first[0].error=="cursor","service cursor rejection uses the same single-response boundary")
	report.rpc_id(1,{"duplicates_ok":true})

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
	await verify_query_retries()
	await wait_until(func() -> bool: return phase_name=="GO")
	await web.market_browser.open()
	var params: Dictionary={"definition_id":"iron_sword","upgrade_min":0,"upgrade_max":9,"price_min":0,"price_max":9000000000000000,"affix_filters":[],"sort":"price_asc","cursor":"","limit":50}
	check((await command("market.browser.search",params)).ok,"real bridge/RPC uses asynchronous readonly auction reader")
	params.cursor="broken"
	check((await command("market.browser.search",params)).error=="cursor","invalid cursor rejected before SQL")
	web.market_browser.close()
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
	check(db.query("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;"),"network fixture uses production WAL/FULL configuration")
	check(await server.database.start_auction_queries(),"native reader startup after account migration")
	for dog: MobActor3D in world.mob_system.mobs.values(): dog.ai_enabled=false
	# Hold only service polling so the accepted request stays pending while RPC
	# duplicates, malformed payloads and the real peer limiter are exercised.
	server.database.auction_queries.set_process(false)
	for id: int in world.characters: phase.rpc_id(id,"RPC_RETRY","")
	await wait_until(func()->bool:return replies.size()==2 and replies.values().all(func(r: Dictionary)->bool:return r.get("duplicates_waiting",false)))
	server.database.auction_queries.set_process(true)
	await wait_until(func()->bool:return replies.size()==2 and replies.values().all(func(r: Dictionary)->bool:return r.get("duplicates_ok",false)))
	for id: int in world.characters: phase.rpc_id(id,"GO","")
	await wait_until(func() -> bool: return done_peers.size()==2)
	for id: int in world.characters:
		var owner: int = server.connected_players[id].player_id
		var snapshot := server.database.market_snapshot(owner)
		check(snapshot.name=="Bread Shop" and snapshot.status=="paused" and snapshot.offers.is_empty() and snapshot.claims.is_empty(),"durable private shop state")
		check(server.database.item_store.inventory(owner).items.size()==2,"no duplicate/lost items after full flow")
	check(db.query("PRAGMA foreign_key_check;") and db.query_result.is_empty(),"network commands preserve global SQL custody")
	print("MARKET_SERVER_OK RPC duplicate/malformed/overload correlation, native bridge, private shops, move/price/status, reload receipt, cancel/claim")
	check(await server.database.auction_queries.pause(),"network fixture drains native reader before quit")
	await get_tree().create_timer(.5).timeout
	get_tree().quit()
