class_name NpcServiceDefinition
extends Resource
## Declarative service reference. Domains own execution and economy.
enum Kind { SHOP = 0, UPGRADE = 1, STORAGE = 2, QUEST = 3 }
@export var service_id: StringName
@export var kind: Kind = Kind.SHOP
@export var label: String
@export var icon_id: StringName
@export var content_ref: StringName
@export var priority: int = 0

func validation_errors() -> Array[String]:
	var errors: Array[String] = []
	if not GameplayContentId.valid(service_id) or (label.strip_edges().is_empty() or label.length() > 128): errors.append("invalid_service")
	if icon_id != &"" and not GameplayContentId.valid(icon_id): errors.append("invalid_icon_id")
	if not GameplayContentId.valid(content_ref): errors.append("invalid_content_ref")
	# Non-shop references are explicit domain entry points, not purchase/upgrade logic.
	match kind:
		Kind.SHOP:
			var shop: ShopDefinition = ShopDefinitions.get_definition(content_ref)
			if shop == null or not shop.validation_errors().is_empty(): errors.append("unknown_shop")
		Kind.UPGRADE:
			if content_ref != &"basic_upgrade": errors.append("unknown_upgrade_content")
		Kind.STORAGE:
			if content_ref != &"account_storage": errors.append("unknown_storage_content")
		Kind.QUEST:
			errors.append("unknown_quest_content") # No quest content is authored yet.
		_:
			errors.append("invalid_kind")
	return errors
