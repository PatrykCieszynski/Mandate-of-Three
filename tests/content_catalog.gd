extends Node
## Retiring content must not leave broken registry entries or remove the default
## creation identity. No fixed catalog sizes, art, scene layout or balance checks.

func _ready() -> void:
	for filename: String in ResourceLoader.list_directory("res://source/common/registry/indexes/"):
		if not filename.ends_with("_index.tres"):
			continue
		var index := load("res://source/common/registry/indexes/" + filename) as ContentIndex
		assert(index != null)
		var ids: Dictionary = {}
		var slugs: Dictionary = {}
		for entry: Dictionary in index.entries:
			assert(not ids.has(entry.id), "duplicate content ID in " + filename)
			assert(not slugs.has(entry.slug), "duplicate content slug in " + filename)
			ids[entry.id] = true
			slugs[entry.slug] = true
			assert(ResourceLoader.exists(entry.path), "missing registered content: " + str(entry.path))
			assert(ResourceLoader.load(entry.path) != null, "unloadable registered content: " + str(entry.path))
	assert(PlayerSkins.is_valid(PlayerResource.new().skin_id), "default character appearance must remain selectable")
	print("CONTENT_CATALOG_OK registered resources and default appearance")
	get_tree().quit()
