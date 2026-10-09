extends SettingWidget
## UI preference only; Web layout follows the client's settings signal.
func _ready() -> void:
	var options: OptionButton = controller
	options.add_item("Auto", 0)
	options.set_item_metadata(0, 0)
	for scale: float in InventoryWebController.UI_SCALES:
		var percent: int = roundi(scale * 100)
		options.add_item("%d%%" % percent)
		options.set_item_metadata(options.item_count - 1, percent)
	options.item_selected.connect(func(index: int) -> void:
		ClientState.settings.set_value(setting_section, setting_property, options.get_item_metadata(index)))
	_load_defaults()
	_update_label()

func _load_defaults() -> void:
	var saved: Variant = ClientState.settings.get_value(setting_section, setting_property)
	var options: OptionButton = controller
	options.select(0)
	for index: int in options.item_count:
		if options.get_item_metadata(index) == saved:
			options.select(index)
			return
