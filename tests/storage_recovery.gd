extends "res://tests/pve_network.gd"
## Real RPC/SQLite with two distinct characters of one fixture account. This does
## not change or claim simultaneous-login support in the production session flow.
class HeadlessUiHost extends WebUiHost:
	func open() -> bool: return true
var web: CoreUiController
var started := false
var results: Dictionary = {}
var facts: Dictionary = {}
var journal_directory := ""
var withdrawal_payload: Dictionary = {}

func _ready() -> void:
	var args := OS.get_cmdline_args()
	var probe := args.find("--storage-journal-probe")
	if probe >= 0:
		var journal = preload("res://source/client/ui_web/local_economy_journal.gd").new("storage-",args[probe+1])
		var loaded: Dictionary = journal.configure({"authority_id":args[probe+2],"account_id":int(args[probe+3]),"character_id":int(args[probe+4])})
		var valid: bool = loaded.ok and loaded.entry.get("id","")==args[probe+5] and ItemUiAdapter.valid_storage(loaded.entry.payload)
		if valid: print("STORAGE_JOURNAL_PROCESS_OK")
		get_tree().quit(0 if valid else 1)
		return
	fixture_shared_account = true
	super._ready()

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed > 42: check(false,"Storage recovery deadline")
	if GameMode.is_world_server() or started or world == null or not world.inventory_endpoint.state.get("ok",false) or world.currency_endpoint.state.is_empty(): return
	started = true
	run_client()

func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size()==2 and ready_peers.size()==2)
	var peers: Array = world.characters.keys()
	var a: int = peers[0]
	var b: int = peers[1]
	var owner_a: int = server.connected_players[a].player_id
	var owner_b: int = server.connected_players[b].player_id
	check(owner_a != owner_b and server.connected_players[a].account_name==server.connected_players[b].account_name,"distinct characters share authoritative account")
	world.inventory_endpoint.inventory_changed.connect(func(owner: int) -> void: facts[owner]=int(facts.get(owner,0))+1)
	for dog: MobActor3D in world.mob_system.mobs.values(): dog.ai_enabled=false
	set_phase("DEPOSIT",a)
	await wait_until(func() -> bool: return replies.has(a))
	drop_uid = replies[a].uid
	var storage := AccountStorageSqlite.new(db)
	check(storage.snapshot(owner_a).items.size()==1,"lost response still commits deposit")
	set_phase("MOVE",b)
	await wait_until(func() -> bool: return replies.has(b))
	check(replies[b].ok and storage.snapshot(owner_a).items[0].bag_position==2,"other character moves shared item")
	set_phase("RECOVER",a)
	await wait_until(func() -> bool: return replies.has(a))
	check(replies[a].ok and int(facts[owner_a])==2 and int(facts[owner_b])==2,"deposit discovery repairs both current views without new facts")
	set_phase("PREPARE_WITHDRAW")
	await wait_until(func() -> bool: return replies.size()==2)
	set_phase("WITHDRAW")
	await wait_until(func() -> bool: return replies.size()==2)
	var bag_a := server.database.item_store.inventory(owner_a)
	var bag_b := server.database.item_store.inventory(owner_b)
	var holds_a: bool = bag_a.items.any(func(i: Dictionary) -> bool: return i.uid==drop_uid)
	var holds_b: bool = bag_b.items.any(func(i: Dictionary) -> bool: return i.uid==drop_uid)
	check(holds_a != holds_b and storage.snapshot(owner_a).items.is_empty(),"competing withdrawal gives exactly one character custody")
	set_phase("CONFIRM")
	await wait_until(func() -> bool: return replies.size()==2)
	check(int(replies[a].ok)+int(replies[b].ok)==1,"only winner discovers success; loser gets definitive owner rejection")
	check(server.database.item_store.inventory(owner_a)==bag_a and server.database.item_store.inventory(owner_b)==bag_b,"withdrawal recovery cannot reassign UID")
	check(int(facts[owner_a])==3 and int(facts[owner_b])==3,"race and replays publish one fanout per actual mutation")
	set_phase("UNSENT",a)
	await wait_until(func() -> bool: return replies.has(a))
	check(replies[a].ok and storage.snapshot(owner_a).items.size()==1,"explicit retry admits originally unsent deposit")
	check(int(facts[owner_a])==4 and int(facts[owner_b])==4,"unknown discovery never creates an extra mutation fact")
	check(db.query("SELECT item_uid FROM (SELECT item_uid FROM item_placements UNION ALL SELECT item_uid FROM account_storage) GROUP BY item_uid HAVING COUNT(*)>1;") and db.query_result.is_empty(),"all UIDs have at most one bag/Storage location")
	var before := [storage.snapshot(owner_a),server.database.item_store.inventory(owner_a),server.database.item_store.inventory(owner_b)]
	check(db.close_db() and db.open_db(),"reopen persisted custody and receipts")
	check([storage.snapshot(owner_a),server.database.item_store.inventory(owner_a),server.database.item_store.inventory(owner_b)]==before,"reopen preserves latest shared Storage and recipient inventory")
	set_phase("FINISH")
	await wait_until(func() -> bool: return done_peers.size()==2)
	if not failed: print("STORAGE_RECOVERY_SERVER_OK: account race, fanout, receipts, reopen")
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(1 if failed else 0)

func compose() -> void:
	web = CoreUiController.new()
	web.host = HeadlessUiHost.new()
	world.add_child(web)
	web.storage.journal.directory = journal_directory
	web.setup(world)
	web.bridge.outgoing.connect(func(json: String) -> void:
		var message: Dictionary = JSON.parse_string(json)
		if message.type=="command.result": results[str(message.id)]=message.payload)
	web.bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')

func command(type: String,payload: Dictionary) -> Dictionary:
	var id := "storage-fixture-"+str(results.size()+1)
	web.bridge.receive(JSON.stringify({"v":1,"type":type,"id":id,"payload":payload}))
	await wait_until(func() -> bool: return results.has(id))
	await get_tree().create_timer(0.12).timeout
	return results.get(id,{"ok":false})

func transfer_payload(item: Dictionary,source: String,destination: String,position: int=0,quick: bool=false) -> Dictionary:
	return {"id":item.uid,"revision":item.revision,"from":source,"to":destination,"x":position,"y":0,"page":0,"quick":quick}

func lose_response(payload: Dictionary) -> Dictionary:
	var endpoint := world.inventory_endpoint
	endpoint.operation_finished.disconnect(web.session.finish)
	var result := await command("storage.transfer",payload)
	endpoint.operation_finished.connect(web.session.finish)
	check(not result.ok and result.error=="storage_pending","lost response preserves original Storage intent")
	var pending: Dictionary = web.storage.journal.load_pending()
	check(pending.ok and not pending.entry.is_empty(),"Storage intent exists on disk after timeout")
	var changed := payload.duplicate(true)
	changed.revision += 1
	check((await command("storage.transfer",changed)).error=="storage_pending","unresolved transfer cannot be replaced")
	return result

func recreate() -> void:
	web._stop("teardown")
	web.queue_free()
	await get_tree().process_frame
	compose()

func run_client() -> void:
	var endpoint := world.inventory_endpoint
	var context: Dictionary = endpoint.state.economic_context
	journal_directory = "res://.godot/verification/storage-journal-network-"+str(context.authority_id)+"-"+str(context.character_id)
	compose()
	register_ready.rpc_id(1)
	while not failed:
		await wait_until(func() -> bool: return phase_name!="WAIT")
		var current := phase_name
		phase_name="WAIT"
		web.storage_opened=true
		var result: Dictionary = {"ok":true}
		if current=="DEPOSIT":
			var item: Dictionary = endpoint.state.items[0]
			await lose_response(transfer_payload(item,"inventory","storage"))
			result.uid=item.uid
		elif current=="MOVE":
			await wait_until(func() -> bool: return endpoint.state.storage.items.size()==1)
			check(endpoint.state.storage.items[0].uid==drop_uid,"account fanout supplies deposited UID")
			result = await command("storage.transfer",transfer_payload(endpoint.state.storage.items[0],"storage","storage",2))
			check(result.ok,"second character moves shared Storage item")
		elif current=="RECOVER":
			var pending: Dictionary = web.storage.journal.load_pending()
			var output: Array=[]
			var status := OS.execute(OS.get_executable_path(),["--headless","--path",ProjectSettings.globalize_path("res://"),"--mode=client","res://tests/storage_recovery.tscn","--storage-journal-probe",journal_directory,str(context.authority_id),str(context.account_id),str(context.character_id),pending.entry.id],output)
			check(status==0 and str(output).contains("STORAGE_JOURNAL_PROCESS_OK"),"independent process restores issuing-character Storage intention")
			await recreate()
			await wait_until(func() -> bool: return web.storage.journal.load_pending().entry.is_empty())
			check(endpoint.state.storage.items[0].bag_position==2 and endpoint.state.storage.items[0].revision==2,"recovery uses latest account state, not original deposit placement")
		elif current=="PREPARE_WITHDRAW":
			await wait_until(func() -> bool: return endpoint.state.storage.items.size()==1 and endpoint.state.storage.items[0].revision==2)
			withdrawal_payload = transfer_payload(endpoint.state.storage.items[0],"storage","inventory",0,true)
		elif current=="WITHDRAW":
			# Both clients already captured the same authoritative UID/revision. A
			# faster winner may publish removal before the other receives this phase.
			await lose_response(withdrawal_payload)
		elif current=="CONFIRM":
			# Winner's UID is no longer in Storage. Retry must bypass current drag validation.
			web.bridge.reset_transport()
			web.bridge.receive('{"v":1,"type":"ui.ready","payload":{}}')
			result = await command("storage.retry",{})
			check(result.ok or result.get("error","")=="owner","retry resolves either winning receipt or failed competing withdrawal")
			check(web.storage.journal.load_pending().entry.is_empty(),"resolved withdrawal clears journal")
		elif current=="UNSENT":
			var payload := transfer_payload(endpoint.state.items[0],"inventory","storage",0,true)
			var operation_id := "storage-"+Crypto.new().generate_random_bytes(16).hex_encode()
			check(web.storage.journal.save_pending(operation_id,payload),"seed crash-before-send Storage entry")
			var before: Dictionary = endpoint.state.duplicate(true)
			var discoveries: Array[Dictionary]=[]
			var observe := func(_id: String,value: Dictionary) -> void: discoveries.append(value)
			endpoint.operation_finished.connect(observe)
			await recreate()
			await wait_until(func() -> bool: return not discoveries.is_empty())
			await get_tree().create_timer(0.25).timeout
			check(discoveries.size()==1 and discoveries[0].get("error","")=="unknown_command" and endpoint.state.items==before.items and endpoint.state.storage==before.storage,"restart performs only read-only unknown discovery")
			endpoint.operation_finished.disconnect(observe)
			check(web.storage_opened and web.storage.journal.load_pending().entry.id==operation_id,"pending recovery reopens Storage without discarding saved intention")
			result = await command("storage.retry",{})
			check(result.ok,"explicit retry executes saved unsent Storage transfer")
		elif current=="FINISH":
			check(endpoint.state.storage.items.size()==1,"both account clients converge after recovery")
			var folder := ProjectSettings.globalize_path(journal_directory).path_join(("%s:%d:%d" % [context.authority_id,context.account_id,context.character_id]).sha256_text())
			DirAccess.remove_absolute(folder)
			DirAccess.remove_absolute(ProjectSettings.globalize_path(journal_directory))
			if not failed: print("STORAGE_RECOVERY_CLIENT_OK: ",client_number)
			finished.rpc_id(1)
			await get_tree().create_timer(0.3).timeout
			get_tree().quit(1 if failed else 0)
			return
		report.rpc_id(1,result)
