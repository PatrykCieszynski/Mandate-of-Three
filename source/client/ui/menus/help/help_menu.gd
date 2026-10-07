extends MenuShell
## In-game help / onboarding reference. Static content, no server calls. Opened from the Help tile in the
## menu overlay, and pointed to by the first-run welcome modal. Edit HELP_TEXT to change the copy.


const HELP_TEXT: String = """[b]Mandate of Three — technical spike[/b]

This build contains a shared test map for checking movement, chat and multiplayer connectivity.

The 3D world and the new combat/item systems are under development.

[b]Controls[/b]
Move with WASD. Use the menu for settings and character stats."""


func _ready() -> void:
	build_shell("Help", null, true)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(scroll)

	var label: RichTextLabel = RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_constant_override(&"line_separation", 5)
	label.text = HELP_TEXT
	# Clickable [url=...] links (Discord / website) open in the player's browser.
	label.meta_clicked.connect(func(meta: Variant) -> void: OS.shell_open(str(meta)))
	scroll.add_child(label)

	# Drag the help text to scroll on touch/mouse; the label still receives link taps.
	DragScroll.enable(scroll)
