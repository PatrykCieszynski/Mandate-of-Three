class_name PlayerSkins
## Registered character appearance identities. The inherited `sprites` registry
## name remains a wire/profile compatibility key; entries no longer require
## TinyMMO SpriteFrames. First Region renders the Warrior through its 3D presenter.


static func ids() -> Array[int]:
	var registry: ContentRegistry = ContentRegistryHub.registry_of(&"sprites")
	if registry == null:
		return []
	var out: Array[int] = registry.all_ids()
	out.sort()
	return out


## Only registered appearance IDs may be selected by the client.
static func is_valid(skin_id: int) -> bool:
	var registry: ContentRegistry = ContentRegistryHub.registry_of(&"sprites")
	return registry != null and registry.has_id(skin_id)


## Readable display name for a skin id, from its file slug ("royal_guard" -> "Royal Guard");
## empty string if the id isn't in the registry.
static func display_name(skin_id: int) -> String:
	var registry: ContentRegistry = ContentRegistryHub.registry_of(&"sprites")
	if registry == null:
		return ""
	return String(registry.slug_from_id(skin_id)).capitalize()
