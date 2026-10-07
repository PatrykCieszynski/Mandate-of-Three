extends Control
## Temporary character window exposing only stats during the infrastructure spike.

@onready var _tabs: Dictionary[StringName, Button] = {
	&"stats": %StatsTab,
}
@onready var _panels: Dictionary[StringName, Control] = {
	&"stats": %StatsContent,
}

var _current: StringName = &"stats"


func _ready() -> void:
	for tab_name: StringName in _tabs:
		_tabs[tab_name].pressed.connect(_select.bind(tab_name))
	%CloseButton.pressed.connect(_on_close_button_pressed)
	_select(_current)


## Switches the active tab. Toggle state + panel visibility both follow the
## selection so a deselected tab can't visually stick "pressed".
func _select(tab_name: StringName) -> void:
	_current = tab_name
	for key: StringName in _tabs:
		_tabs[key].button_pressed = (key == tab_name)
		_panels[key].visible = (key == tab_name)


func _on_close_button_pressed() -> void:
	hide()
