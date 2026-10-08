class_name VisualResolver
extends RefCounted
## Optional resources are never preloaded. Only stray_dog is supported for now.
const STRAY_DOG := &"stray_dog"
const FINAL_DOG := "res://assets/final/mobs/stray_dog.tscn"
const DEV_DOG := "res://dev_assets/metin2/mobs/stray_dog/stray_dog.glb"
const PLACEHOLDER_DOG := "res://assets/placeholders/mobs/stray_dog_placeholder.tscn"

static func local_development_enabled() -> bool:
	return OS.has_feature("editor") and not OS.has_feature("dedicated_server") \
		and not OS.get_cmdline_user_args().has("--no-dev-visuals") \
		and OS.get_environment("MANDATE_NO_DEV_VISUALS") != "1"

static func resolve(visual_id: StringName) -> PackedScene:
	if visual_id != STRAY_DOG: return null
	if ResourceLoader.exists(FINAL_DOG, "PackedScene") and (not OS.has_feature("editor") or FileAccess.file_exists(FINAL_DOG)):
		var final_scene := load(FINAL_DOG) as PackedScene
		if final_scene != null: return final_scene
	# Stale import artifacts must not resurrect a deleted local source file.
	if local_development_enabled() and FileAccess.file_exists(DEV_DOG) \
			and ResourceLoader.exists(DEV_DOG, "PackedScene"):
		var dev_scene := load(DEV_DOG) as PackedScene
		if dev_scene != null: return dev_scene
	return load(PLACEHOLDER_DOG) as PackedScene
