class_name NpcInteractionContext
extends RefCounted
var npc_instance_id: String
var npc_definition_id: StringName
var selected_service_id: StringName
func _init(instance_id: String, definition_id: StringName) -> void:
	npc_instance_id = instance_id
	npc_definition_id = definition_id
