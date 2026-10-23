extends Node
const Adapter = preload("res://source/client/ui_web/vendor_ui_adapter.gd")
class VendorProjection extends UiCommandDispatcher:
	var value: Dictionary={}
	func set_domain(_domain: String,snapshot: Dictionary) -> void: value=snapshot
class ClientAdapter extends Adapter:
	var calls: Array=[]
	var responses: Array=[]
	var hold_quote:=false
	signal quote_released
	func _request(action: String,payload: Dictionary,npc: Dictionary) -> Dictionary:
		calls.append({"action":action,"payload":payload.duplicate(true),"npc":npc.duplicate(true)})
		var result: Dictionary=responses.pop_front() if not responses.is_empty() else {"ok":false,"error":"storage"}
		if action=="quote" and hold_quote: await quote_released
		return result

func refresh_async(client: RefCounted, answers: Array) -> void: answers.append(await client.refresh())

func _ready() -> void:
	var endpoint:=Shop3D.new()
	endpoint.state={"active":true,"npcInstanceId":"blacksmith","serviceId":"weapon_shop"}
	var projection:=VendorProjection.new();projection.bridge=WebUiBridge.new()
	var session:=UiCommandSession.new()
	var client:=ClientAdapter.new()
	client.journal.directory="res://.godot/verification/vendor-ui-"+Crypto.new().generate_random_bytes(8).hex_encode()
	var directory: String=client.journal.directory
	client.attach(endpoint,projection,session,get_tree())
	var uid: String=Crypto.new().generate_random_bytes(16).hex_encode()
	var context: Dictionary={"authority_id":uid,"account_id":3,"character_id":30}
	var raw: Dictionary={"uid":uid,"definition_id":"upgrade_ore","item_name":"Ore","amount":10,"revision":4,"inventory_height":1,"upgrade_level":0,"location":"bag"}
	var inventory: Dictionary={"ok":true,"economic_context":context,"items":[raw]}
	client.accept_inventory(inventory);assert(client.open().ok)
	var before:=inventory.duplicate(true)
	assert(client.edit({"id":uid,"amount":3}).ok)
	assert(inventory==before and projection.value.items[0].quantity==3)
	var other:=raw.duplicate(true)
	other.uid=Crypto.new().generate_random_bytes(16).hex_encode()
	inventory.items.append(other);client.accept_inventory(inventory)
	assert(client.edit({"id":other.uid,"amount":1}).ok)
	assert(client.edit({"id":uid,"amount":4}).ok)
	assert(projection.value.items[0].id==uid and projection.value.items[1].id==other.uid,"editing an existing offer preserves order")
	assert(client.edit({"id":other.uid,"amount":0}).ok)
	client.hold_quote=true
	client.responses=[{"ok":true,"quote_id":uid,"yang":"6","rewards":[],"expires_at":int(Time.get_unix_time_from_system())+30}]
	var late: Array=[]
	refresh_async.call_deferred(client,late);await get_tree().process_frame
	assert(client.edit({"id":uid,"amount":2}).ok)
	client.quote_released.emit();await get_tree().process_frame
	assert(late.size()==1 and projection.value.quote.is_empty() and projection.value.items[0].quantity==2,"late quote cannot overwrite an edited basket")
	client.hold_quote=false
	client.responses=[{"ok":true,"quote_id":uid,"yang":"6","rewards":[],"expires_at":int(Time.get_unix_time_from_system())+30}]
	assert((await client.refresh()).ok)
	client.responses=[{"ok":false,"error":"timeout"}]
	assert(not (await client.confirm()).ok and projection.value.pending)
	var command: String=client.calls.back().payload.command_id
	assert(client.journal.load_pending().entry.id==command,"intent is durable before an uncertain send")
	# Inventory can arrive ahead of the lost response. The recovery button must
	# work even though the original offered quantity/revision no longer exists.
	raw.amount=7;raw.revision=5;client.accept_inventory(inventory)
	assert(not client.edit({"id":uid,"amount":1}).ok)
	assert(not projection.value.items[0].available)
	client.dispose()
	var restored:=ClientAdapter.new();restored.journal.directory=directory
	var next:=VendorProjection.new();next.bridge=WebUiBridge.new()
	restored.responses=[{"ok":false,"error":"storage"}]
	restored.attach(endpoint,next,session,get_tree());restored.accept_inventory(inventory)
	await get_tree().process_frame
	assert(next.value.pending and restored.calls[0].action=="receipt" and restored.calls[0].payload.command_id==command,"recreated adapter discovers only the original receipt")
	restored.responses=[{"ok":true,"yang":"6","rewards":[]}]
	assert((await restored.recover()).ok and not next.value.pending and restored.journal.load_pending().entry.is_empty())
	assert(restored.calls.all(func(call: Dictionary)->bool:return call.action=="receipt"),"restart never blindly reissues a sale")
	# Missing receipt releases intent, but requires a new explicit quote and
	# confirmation instead of replaying an expired ephemeral quote ID.
	assert(restored.open().ok and restored.edit({"id":uid,"amount":2}).ok)
	restored.responses=[{"ok":true,"quote_id":uid,"yang":"4","rewards":[],"expires_at":int(Time.get_unix_time_from_system())+30}]
	assert((await restored.refresh()).ok)
	restored.responses=[{"ok":false,"error":"ui_reload"}];assert(not (await restored.confirm()).ok)
	restored.responses=[{"ok":false,"error":"unknown_command"}];assert(not (await restored.recover()).ok and not next.value.pending)
	assert(next.value.quote.is_empty() and next.value.error=="not_committed")
	restored.dispose();endpoint.free();projection.bridge.free();projection.free();next.bridge.free();next.free()
	print("VENDOR_UI_OK reference-only basket, durable intent, Inventory-ahead timeout, restore/receipt-only recovery and unknown outcome")
	get_tree().quit()
