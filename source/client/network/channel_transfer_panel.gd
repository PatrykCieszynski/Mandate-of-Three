extends PanelContainer
## Native connection controls, alongside the existing native Options menu.
## The manager survives map recreation; this panel never decides admission.
var manager: InstanceManagerClient
var _content: VBoxContainer
var _status: Label
var _channels: VBoxContainer
var _cancel: Button
var _received_at := 0
var _remaining := 0

func setup(network: InstanceManagerClient) -> void:
	manager=network
	set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	position=Vector2(-180,-120)
	custom_minimum_size=Vector2(360,0)
	_content=VBoxContainer.new()
	add_child(_content)
	_status=Label.new()
	_content.add_child(_status)
	_channels=VBoxContainer.new()
	_content.add_child(_channels)
	var refresh:=Button.new()
	refresh.text="Refresh / recover status"
	refresh.focus_mode=Control.FOCUS_NONE
	refresh.pressed.connect(_refresh)
	_content.add_child(refresh)
	_cancel=Button.new()
	_cancel.text="Cancel channel change"
	_cancel.focus_mode=Control.FOCUS_NONE
	_cancel.pressed.connect(func()->void:manager.channel_transfer("cancel"))
	_content.add_child(_cancel)
	var close:=Button.new()
	close.text="Close"
	close.focus_mode=Control.FOCUS_NONE
	close.pressed.connect(hide)
	_content.add_child(close)
	manager.channels_changed.connect(_catalogue)
	manager.transfer_changed.connect(_transfer)
	hide()

func open() -> void:
	show()
	_refresh()

func _refresh() -> void:
	manager.refresh_channels()
	manager.channel_transfer("status")

func _catalogue(catalogue: Dictionary) -> void:
	for child: Node in _channels.get_children():
		_channels.remove_child(child)
		child.queue_free()
	var current := int(manager.current_instance.identity.get("channel_id",0)) if is_instance_valid(manager.current_instance) else 0
	for row: Dictionary in catalogue.get("channels",[]):
		var button:=Button.new()
		button.text="CH %d — %s (%d/%d)%s" % [row.channel_id,row.state,row.population,row.capacity," · current" if row.channel_id==current else ""]
		button.focus_mode=Control.FOCUS_NONE
		button.disabled=row.channel_id==current or row.state!="available"
		button.pressed.connect(func()->void:manager.channel_transfer("start",int(row.channel_id)))
		_channels.add_child(button)
	if not catalogue.get("ok",false): _status.text="Channels: "+str(catalogue.get("error","unavailable"))

func _transfer(result: Dictionary) -> void:
	_received_at=Time.get_ticks_msec()
	_remaining=int(manager.transfer.get("remaining_ms",0))
	var phase:=str(manager.transfer.get("phase","idle"))
	_cancel.disabled=phase!="countdown"
	if not result.get("ok",false):
		_status.text="Channel change: "+str(result.get("error","unavailable"))
	else:
		_status.text="Channel change: "+phase
		if not str(manager.transfer.get("error","")).is_empty(): _status.text+=" · "+str(manager.transfer.error)
	if phase=="loading": _status.text="Loading channel…"

func _process(_delta: float) -> void:
	if manager!=null and manager.transfer.get("phase")=="countdown":
		var remaining:=maxi(0,_remaining-(Time.get_ticks_msec()-_received_at))
		_status.text="CH %d in %.1f s · move/attack to cancel" % [manager.transfer.channel_id,remaining/1000.0]

func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and event.keycode==KEY_ESCAPE:
		hide()
		get_viewport().set_input_as_handled()
