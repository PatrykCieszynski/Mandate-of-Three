class_name ThemePalettes
## Single source of truth for the UI palettes — the slug list + each palette's styling theme, login
## backdrop, and accent. The gateway (gateway.gd) and the in-game UI (ui.gd) both pull their styling
## Theme from here, and the Settings picker (setting_palette.gd) lists from here. Add a palette: add a
## row below + run generate_ingame_themes.gd (File ▸ Run) to bake its theme_<slug>.tres.

const THEME_DIR: String = "res://source/client/ui/themes/"
const DEFAULT: StringName = &"horizon"

## slug -> { accent = focus/active accent }. The styling for each slug
## lives in theme_<slug>.tres (generated from theme_horizon by generate_ingame_themes.gd).
const PALETTES: Dictionary = {
	&"horizon": {"accent": Color(0.58, 0.82, 0.98)},
	&"gold": {"accent": Color(0.95, 0.74, 0.44)},
	&"forest": {"accent": Color(0.66, 0.85, 0.5)},
	&"fireforge": {"accent": Color(0.97, 0.56, 0.32)},
}


## Palette slugs, sorted — the canonical set for the Settings picker + the gateway.
static func list() -> Array[StringName]:
	var out: Array[StringName] = []
	for slug: StringName in PALETTES:
		out.append(slug)
	out.sort()
	return out


static func has(slug: StringName) -> bool:
	return PALETTES.has(slug)


## The shared styling Theme for [slug] (gateway + in-game). Falls back to the default.
static func theme(slug: StringName) -> Theme:
	var key: StringName = slug if PALETTES.has(slug) else DEFAULT
	return load(THEME_DIR + "theme_%s.tres" % key) as Theme


## Asset-free login backdrop; legacy TinyMMO backgrounds are retired.
static func backdrop(slug: StringName) -> Texture2D:
	var key: StringName = slug if PALETTES.has(slug) else DEFAULT
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray([Color(0.025, 0.035, 0.05), accent(key).darkened(0.85)])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = 960
	texture.height = 540
	texture.fill_to = Vector2(0, 1)
	return texture


## The accent colour for [slug] (focus ring, etc.).
static func accent(slug: StringName) -> Color:
	var key: StringName = slug if PALETTES.has(slug) else DEFAULT
	return PALETTES[key]["accent"]
