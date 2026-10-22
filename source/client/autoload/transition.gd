extends CanvasLayer
## Transition — a fullscreen overlay covering scene/world transitions (client only).
##
## Today it covers the gateway → world hand-off: the gateway calls
## `Transition.start_world_load(...)` and frees itself; this overlay hard-cuts in to
## hide the grey gap, then fades out when the world is actually playable
## (`ClientState.local_player_ready`). On a failed / auth-rejected connect it shows
## Retry / Back-to-login instead of the old black-screen hang.
##
## Built in code (like Toaster) so it stays one self-contained file — intended to
## fold into a single UI autoload (with Toaster) later.

const _CREAM: Color = Color(0.929, 0.894, 0.820)
# "Entering the world" payoff cue — a soft magical swell, played once as the cover
# begins. Lives here (not the gateway) so every enter path triggers it identically.
const _SFX_ENTER: String = "res://assets/audio/sfx/ui/ui_enter.wav"

var _root: Control
var _background: TextureRect
var _spinner: ProgressBar
var _label: Label
var _buttons: HBoxContainer
var _back_button: Button
var _bloom: ColorRect
var _fade_tween: Tween
var _channel_controls: VBoxContainer
var _choosing_channel: bool = false

var _active: bool = false
var _address: String
var _port: int
var _token: String


func _ready() -> void:
	if not GameMode.is_client():
		queue_free()
		return
	layer = 200  # above Toaster (128), the HUD, everything
	process_mode = Node.PROCESS_MODE_ALWAYS  # buttons stay live even if the tree pauses
	_build_ui()
	visible = false
	ClientState.local_player_ready.connect(_on_world_ready)
	ClientState.world_ready.connect(_on_world_ready)
	Client.connection_changed.connect(_on_connection_changed)
	Client.instance_manager.channels_changed.connect(_show_channels)
	Client.instance_manager.channel_selection_finished.connect(_channel_selected)


## Connect to a world and cover the load. Call from the gateway, then free it.
## Dismisses on local_player_ready; shows the error panel on a failed connect.
func start_world_load(address: String, port: int, token: String, background: Texture2D = null) -> void:
	_address = address
	_port = port
	_token = token
	_active = true
	_background.texture = background
	_show_loading()
	Client.instance_manager.auto_select_channel = false
	# Enter cue plays now (audio runs off the main thread, so the world load can't
	# freeze it). The visual bloom waits for the reveal — see _fade_out.
	if is_instance_valid(Client) and Client.audio_manager:
		Client.audio_manager.play_ui_sound(_SFX_ENTER)  # the "you're going in" moment
	Client.connect_to_server(address, port, token)


func _on_world_ready(_local_player: Node) -> void:
	if not _active:
		return
	_active = false
	_fade_out()


func _on_connection_changed(connected: bool) -> void:
	# Only during a load. connected == true → socket up, world still loading (wait for
	# local_player_ready). false → the connect failed or auth was rejected.
	if not _active or connected:
		return
	_show_error()


# --- UI states -------------------------------------------------------------

func _show_loading() -> void:
	_choosing_channel = false
	if _fade_tween and _fade_tween.is_valid():
		_fade_tween.kill()
	visible = true
	_root.modulate.a = 1.0
	_bloom.modulate.a = 0.0  # bloom only appears on the reveal
	_label.text = "Entering the world…"
	_spinner.visible = true
	_buttons.visible = false
	_channel_controls.visible = false


func _show_channels(catalogue: Dictionary) -> void:
	if not _active or _choosing_channel: return
	for child: Node in _channel_controls.get_children():
		_channel_controls.remove_child(child)
		child.queue_free()
	_spinner.visible = false
	_buttons.visible = true
	_channel_controls.visible = true
	_label.text = "Choose a channel\nTime limit: 30 s from connection; refresh does not extend it."
	if not catalogue.get("ok", false):
		_label.text = "Channel list unavailable: " + str(catalogue.get("error", "unknown"))
	else:
		for channel: Dictionary in catalogue.get("channels", []):
			var button := Button.new()
			button.text = "CH %d — %s (%d / %d)" % [channel.channel_id, channel.state, channel.population, channel.capacity]
			button.disabled = channel.state not in ["available", "loading"]
			button.pressed.connect(_choose_channel.bind(int(channel.channel_id)))
			_channel_controls.add_child(button)
		var automatic := Button.new()
		automatic.text = "Automatic channel"
		automatic.pressed.connect(_choose_channel.bind(0))
		_channel_controls.add_child(automatic)
	var refresh := Button.new()
	refresh.text = "Refresh channels"
	refresh.pressed.connect(Client.instance_manager.refresh_channels)
	_channel_controls.add_child(refresh)


func _choose_channel(channel_id: int) -> void:
	_choosing_channel = true
	_channel_controls.visible = false
	_label.text = "Joining channel…"
	_spinner.visible = true
	Client.instance_manager.select_initial_channel(channel_id)


func _channel_selected(result: Dictionary) -> void:
	if not _active or result.get("ok", false): return
	_choosing_channel = false
	_show_channels(Client.instance_manager.channels)
	_label.text = "Channel unavailable: " + str(result.get("error", "unknown")) + ". Refresh or choose another."


func _show_error() -> void:
	_channel_controls.visible = false
	_label.text = "Couldn't reach the world."
	_spinner.visible = false
	_buttons.visible = true


## Mid-game server drop (Client.server_disconnected): replace the old silent freeze
## with a clear overlay + a single "Back to login" action — it reloads the scene,
## which re-runs the gateway's version handshake (showing the update gate if the
## build moved on) and auto-logs back in; on web it does a full page reload to pull
## the new build. Called while the tree is paused; this layer is PROCESS_MODE_ALWAYS
## so the button stays live, and _back_to_login unpauses.
func show_disconnected() -> void:
	_channel_controls.visible = false
	_active = false  # not a load — keep _on_world_ready / the load path from firing here
	if _fade_tween and _fade_tween.is_valid():
		_fade_tween.kill()
	visible = true
	_root.modulate.a = 1.0
	_bloom.modulate.a = 0.0
	_background.texture = null
	# Honest for BOTH causes — a server update/restart OR the player's own network
	# dropping — since server_disconnected fires for any established-connection loss.
	_label.text = "Connection lost.\nThe server may be updating, or your connection dropped."
	_spinner.visible = false
	_buttons.visible = true


## The reveal. Runs on local_player_ready — the world's loaded, so the main thread is
## free and these tweens actually animate (a bloom at the START is frozen by the
## synchronous world load, hence the static "white filter" look). The cover fades
## while a warm-white bloom dissolves over it, so the world appears through a soft
## flash of light rather than a plain wipe.
func _fade_out() -> void:
	if _fade_tween and _fade_tween.is_valid():
		_fade_tween.kill()
	_bloom.modulate.a = 0.55
	_fade_tween = create_tween()
	_fade_tween.set_parallel(true)
	_fade_tween.tween_property(_root, "modulate:a", 0.0, 0.45).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_fade_tween.tween_property(_bloom, "modulate:a", 0.0, 0.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_fade_tween.chain().tween_callback(func() -> void: visible = false)


func _back_to_login() -> void:
	_active = false
	Client.close_connection()
	get_tree().paused = false
	# On web, reload_current_scene keeps the already-loaded (now stale) wasm build, so
	# an update would never reach the player. A full page reload re-fetches index.html +
	# the new build from the host. JavaScriptBridge only exists on the web export.
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.location.reload();", true)
		return
	# The live world + HUD live under persistent parents (the instance under the Client
	# autoload, the UI under root), so reload_current_scene rebuilds the gateway but
	# does NOT free them — leaving the old world showing under the login menu. Tear
	# them down explicitly first.
	if is_instance_valid(Client) and Client.instance_manager:
		Client.instance_manager.teardown()
	visible = false
	# Deferred: this runs from a Button.pressed callback, and reloading the scene
	# mid-signal can throw "can't be used during in/out signal".
	get_tree().reload_current_scene.call_deferred()


# --- Build (code, Toaster-style) -------------------------------------------

func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP  # swallow clicks behind the overlay
	add_child(_root)

	# Solid obsidian base so it's opaque even without a backdrop texture.
	var base: ColorRect = ColorRect.new()
	base.color = Color(0.04, 0.047, 0.066, 1.0)
	base.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(base)

	# The palette backdrop the gateway passed (cover-scaled), if any.
	_background = TextureRect.new()
	_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_background)

	# Veil to keep the spinner / text readable over busy art.
	var veil: ColorRect = ColorRect.new()
	veil.color = Color(0.0, 0.0, 0.0, 0.4)
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(veil)

	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override(&"separation", 20)
	center.add_child(vbox)

	_spinner = ProgressBar.new()
	_spinner.custom_minimum_size = Vector2(120, 10)
	_spinner.indeterminate = true
	_spinner.show_percentage = false
	_spinner.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(_spinner)

	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_color_override(&"font_color", _CREAM)
	_label.add_theme_font_size_override(&"font_size", 20)
	vbox.add_child(_label)
	_channel_controls = VBoxContainer.new()
	_channel_controls.visible = false
	vbox.add_child(_channel_controls)

	_buttons = HBoxContainer.new()
	_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	_buttons.add_theme_constant_override(&"separation", 12)
	# Single action: "Back to login". There's no Retry — auth tokens are one-shot
	# (consumed at login), so an in-place reconnect can never work; recovery always
	# goes back through the gateway for a fresh token (auto-login makes it one tap).
	_back_button = Button.new()
	# On web, this reloads the page (fetches a fresh build); elsewhere it returns to
	# the gateway. Label it for what it actually does on this platform.
	_back_button.text = "Reload" if OS.has_feature("web") else "Back to login"
	_back_button.pressed.connect(_back_to_login)
	_buttons.add_child(_back_button)
	vbox.add_child(_buttons)

	# The enter-world bloom (warm white, softer than stark white). Parented to the
	# LAYER, not _root — so when _root (the cover) fades out on reveal, the bloom
	# survives to dissolve over the unveiled world on its own timeline.
	_bloom = ColorRect.new()
	_bloom.color = Color(1.0, 0.98, 0.92)
	_bloom.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bloom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bloom.modulate.a = 0.0
	add_child(_bloom)
