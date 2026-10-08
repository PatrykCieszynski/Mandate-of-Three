extends SceneTree
func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if not ProjectSettings.load_resource_pack(args[0]):
		push_error("Cannot mount export")
		quit(1)
		return
	var paths: Array[String] = []
	collect("res://",paths)
	for path: String in paths:
		if path.begins_with("res://dev_assets/") or path.begins_with("res://.local/") or path.ends_with("local.json") or path.contains("stray_dog.glb") or path.contains("stray_dog_glb") or path.contains("stray_dog_stray_dog") or path.contains("warrior.glb") or path.contains("warrior_armor.glb") or path.contains("iron_sword.glb") or path.contains("warrior_warrior") or path.contains("warrior_armor_") or path.contains("iron_sword_weapon"):
			push_error("Local asset leaked into export: " + path)
			quit(1)
			return
	if not paths.has("res://assets/placeholders/mobs/stray_dog_placeholder.tscn.remap") and not paths.has("res://assets/placeholders/mobs/stray_dog_placeholder.tscn"):
		push_error("Placeholder missing")
		quit(1)
		return
	for required: String in ["res://assets/placeholders/players/warrior.tscn","res://assets/placeholders/weapons/iron_sword.tscn"]:
		if not paths.has(required) and not paths.has(required+".remap"):
			push_error("Missing humanoid placeholder: "+required)
			quit(1)
			return
	print("VISUAL_EXPORT_OK ",paths.size()," packed files; no local legacy model, texture or configuration")
	quit(0)
func collect(directory: String, paths: Array[String]) -> void:
	for name: String in DirAccess.get_files_at(directory): paths.append(directory.path_join(name))
	for name: String in DirAccess.get_directories_at(directory): collect(directory.path_join(name),paths)
