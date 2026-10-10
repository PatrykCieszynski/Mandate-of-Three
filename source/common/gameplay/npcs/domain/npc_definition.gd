class_name NpcDefinition
extends Resource
## Shared content is treated as immutable after loading; actors own instance state.
@export var definition_id: StringName
@export var display_name: String
@export var visual_id: StringName
@export var interaction_radius: float = 3.0
@export var services: Array[NpcServiceDefinition] = []

func validation_errors() -> Array[String]:
	var errors: Array[String] = []
	if not GameplayContentId.valid(definition_id) or (display_name.strip_edges().is_empty() or display_name.length() > 128) or not GameplayContentId.valid(visual_id): errors.append("invalid_npc")
	if not is_finite(interaction_radius) or interaction_radius <= 0.0 or interaction_radius > 20.0: errors.append("invalid_radius")
	if services.size() > 16: errors.append("too_many_services")
	var seen: Dictionary = {}
	for service: NpcServiceDefinition in services:
		if service == null:
			errors.append("null_service")
			continue
		if seen.has(service.service_id): errors.append("duplicate_service_id")
		seen[service.service_id] = true
		errors.append_array(service.validation_errors())
	return errors

func get_service(id: StringName) -> NpcServiceDefinition:
	for service: NpcServiceDefinition in services:
		if service != null and service.service_id == id: return service
	return null

func ordered_services() -> Array[NpcServiceDefinition]:
	var ordered: Array[NpcServiceDefinition] = services.duplicate()
	ordered.sort_custom(func(a: NpcServiceDefinition, b: NpcServiceDefinition) -> bool:
		return a.priority < b.priority if a.priority != b.priority else str(a.service_id) < str(b.service_id))
	return ordered
