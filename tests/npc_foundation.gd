extends Node
class MapFixture extends Node3D:
	var characters: Dictionary[int, Node3D] = {}

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var definition: NpcDefinition = NpcDefinitions.get_definition(&"blacksmith")
	assert(definition != null and definition.validation_errors().is_empty())
	assert(NpcDefinitions.get_definition(&"missing") == null)
	var shop: ShopDefinition = ShopDefinitions.get_definition(&"blacksmith_weapon_shop")
	assert(shop != null and shop.validation_errors().is_empty() and shop.offers.size() == 1)
	assert(ShopDefinitions.get_definition(&"missing") == null)
	assert(definition.get_service(&"weapon_shop").content_ref == shop.shop_id)
	var bad: NpcDefinition = definition.duplicate(true)
	bad.services.append(bad.services[0])
	assert("duplicate_service_id" in bad.validation_errors())
	bad = definition.duplicate(true)
	bad.services[1].content_ref = &"missing"
	assert("unknown_shop" in bad.validation_errors())
	var tied: NpcDefinition = definition.duplicate(true)
	tied.services[0].priority = 20
	tied.services.reverse()
	assert(tied.ordered_services()[0].service_id == &"upgrade", "ID breaks equal-priority ties")
	var bad_shop: ShopDefinition = shop.duplicate(true)
	bad_shop.offers[0].item_definition_id = &"missing"
	bad_shop.offers[0].quantity = 0
	bad_shop.offers[0].price = -1
	for error: String in ["unknown_item", "invalid_quantity", "invalid_price"]:
		assert(error in bad_shop.validation_errors())
	assert(shop.offers[0].price == 1000, "Validation fixtures never mutate loaded definitions")
	assert(NeutralNpc3D.valid_instance_id("map1-blacksmith-01"))
	assert(not NeutralNpc3D.valid_instance_id("../Blacksmith"))
	var map := MapFixture.new()
	add_child(map)
	var endpoint := NpcInteraction3D.new()
	map.add_child(endpoint)
	var actor := preload("res://source/common/gameplay/npcs/blacksmith_fixture.tscn").instantiate() as NeutralNpc3D
	map.add_child(actor)
	assert(endpoint.register_actor(actor))
	assert(not endpoint.register_actor(actor), "Duplicate instance ID is rejected")
	var second := NeutralNpc3D.new()
	second.instance_id = "spike-blacksmith-02"
	second.definition = definition
	map.add_child(second)
	assert(endpoint.register_actor(second), "Definitions can be shared by independent world instances")
	var player := Node3D.new()
	map.add_child(player)
	map.characters[7] = player
	assert(endpoint.interact_for_peer(999, actor.instance_id).error == "unknown_player")
	assert(endpoint.interact_for_peer(7, "missing").error == "unknown_npc")
	assert(endpoint.interact_for_peer(7, actor.instance_id).error == "out_of_range")
	player.global_position = actor.global_position + Vector3(0,0,2)
	assert(endpoint.interact_for_peer(7, actor.instance_id).ok)
	assert(endpoint.contexts[7].npc_definition_id == &"blacksmith")
	assert(endpoint.resolve_npc_service(7, second.instance_id, &"weapon_shop", NpcServiceDefinition.Kind.SHOP).error == "no_interaction")
	assert(endpoint.resolve_npc_service(7, actor.instance_id, &"missing", NpcServiceDefinition.Kind.SHOP).error == "unknown_service")
	assert(endpoint.resolve_npc_service(7, actor.instance_id, &"weapon_shop", NpcServiceDefinition.Kind.UPGRADE).error == "wrong_service_kind")
	endpoint.contexts[7].npc_definition_id = &"old_definition"
	assert(endpoint.resolve_npc_service(7, actor.instance_id, &"weapon_shop", NpcServiceDefinition.Kind.SHOP).error == "stale_context")
	endpoint.contexts[7].npc_definition_id = &"blacksmith"
	var authorized: Dictionary = endpoint.resolve_npc_service(7, actor.instance_id, &"weapon_shop", NpcServiceDefinition.Kind.SHOP)
	assert(authorized.ok and authorized.content_ref == shop.shop_id and authorized.service == definition.get_service(&"weapon_shop"))
	var snapshot: Dictionary = endpoint.snapshot_for_peer(7)
	assert(snapshot.services[0].id == "upgrade" and snapshot.services[1].id == "weapon_shop")
	assert(endpoint.select_for_peer(7, actor.instance_id, &"weapon_shop").ok)
	assert(endpoint.snapshot_for_peer(7).selectedServiceId == "weapon_shop")
	actor.disabled_services.append(&"weapon_shop")
	assert(endpoint.resolve_npc_service(7, actor.instance_id, &"weapon_shop", NpcServiceDefinition.Kind.SHOP).error == "service_disabled")
	assert(endpoint.snapshot_for_peer(7).selectedServiceId == "")
	actor.disabled_services.clear()
	player.position += Vector3(20,0,0)
	assert(endpoint.resolve_npc_service(7, actor.instance_id, &"weapon_shop", NpcServiceDefinition.Kind.SHOP).error == "out_of_range")
	assert(not endpoint.snapshot_for_peer(7).active and endpoint.contexts.is_empty())
	player.global_position = actor.global_position
	assert(endpoint.interact_for_peer(7, actor.instance_id).ok)
	var other_map := Node3D.new()
	add_child(other_map)
	player.reparent(other_map)
	assert(endpoint.resolve_npc_service(7, actor.instance_id, &"weapon_shop", NpcServiceDefinition.Kind.SHOP).error == "wrong_world")
	player.reparent(map)
	other_map.free()
	endpoint.close_for_peer(7)
	assert(endpoint.contexts.is_empty())
	assert(endpoint.interact_for_peer(7, actor.instance_id).ok)
	endpoint.remove_peer(7)
	assert(endpoint.contexts.is_empty())
	assert(endpoint.interact_for_peer(7, actor.instance_id).ok)
	map.remove_child(actor)
	assert(endpoint.contexts.is_empty() and not endpoint.actors.has(actor.instance_id), "NPC teardown clears contexts")
	actor.free()
	player.global_position = second.global_position
	assert(endpoint.interact_for_peer(7, second.instance_id).ok)
	map.remove_child(endpoint)
	assert(endpoint.contexts.is_empty() and endpoint.actors.is_empty(), "World teardown clears all contexts")
	endpoint.free()
	map.free()
	print("NPC_FOUNDATION_OK: content, identity, map/range/context/service authority and teardown")
	get_tree().quit()
