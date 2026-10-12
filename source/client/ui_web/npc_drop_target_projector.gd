class_name NpcDropTargetProjector
extends RefCounted
## Presentation only. Caller owns cadence/cache; the server authorizes every action.

static func project(camera: Camera3D, viewport: Vector2, actors: Array) -> Dictionary:
	var targets: Array = []
	if camera != null:
		for actor: NeutralNpc3D in actors:
			if targets.size() >= 64: break
			if not actor.interactable or camera.is_position_behind(actor.global_position): continue
			var rect := Rect2(camera.unproject_position(actor.global_position),Vector2.ZERO)
			for x: float in [-0.4,0.4]:
				for y: float in [0.0,1.8]:
					for z: float in [-0.4,0.4]: rect = rect.expand(camera.unproject_position(actor.global_position + Vector3(x,y,z)))
			if not rect.position.is_finite() or not rect.size.is_finite(): continue
			rect = rect.intersection(Rect2(Vector2.ZERO,viewport))
			if not rect.has_area(): continue
			for target: Dictionary in upgrade_targets(actor,rect):
				if targets.size() >= 64: break
				targets.append(target)
	return {"width":viewport.x,"height":viewport.y,"targets":targets}

static func upgrade_targets(actor: NeutralNpc3D, rect: Rect2) -> Array[Dictionary]:
	var targets: Array[Dictionary] = []
	if not actor.interactable or actor.definition == null: return targets
	for service: NpcServiceDefinition in actor.definition.ordered_services():
		if service.kind != NpcServiceDefinition.Kind.UPGRADE or not actor.service_enabled(service.service_id): continue
		var recipe: UpgradeDefinition = UpgradeDefinitions.get_definition(service.content_ref)
		if recipe == null or not recipe.validation_errors().is_empty(): continue
		targets.append({"npcInstanceId":actor.instance_id,"serviceId":str(service.service_id),"itemDefinitionId":str(recipe.item_definition_id),"fromLevel":recipe.from_level,"x":rect.position.x,"y":rect.position.y,"w":rect.size.x,"h":rect.size.y})
	return targets
