@tool
extends EditorPlugin

const MAIN_PANEL = preload("res://addons/mandate_tools/main_screen/main_panel.tscn")

var export_plugin: EditorExportPlugin
var main_panel_instance: Control

func _enter_tree() -> void:
	main_panel_instance = MAIN_PANEL.instantiate()
	EditorInterface.get_editor_main_screen().add_child(main_panel_instance)
	main_panel_instance.hide()

	export_plugin = preload("res://addons/mandate_tools/export_plugin/export_plugin.gd").new()
	add_export_plugin(export_plugin)

func _exit_tree() -> void:
	if main_panel_instance:
		main_panel_instance.queue_free()
	if export_plugin:
		remove_export_plugin(export_plugin)

func _has_main_screen() -> bool:
	return true

func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("MultiplayerSpawner", "EditorIcons")

func _get_plugin_name() -> String:
	return "Mandate Tools"

func _make_visible(visible: bool) -> void:
	if main_panel_instance:
		main_panel_instance.visible = visible
