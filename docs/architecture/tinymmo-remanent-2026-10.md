# TinyMMO legacy remanent — first pass

## Verified findings

| Area | Evidence | Decision |
|---|---|---|
| `addons/tinymmo/plugin.gd` | Active `[editor_plugins]` registration in `project.godot`; commented-out inspector and old debug-instance bootstrap | Removed commented dead bootstrap and unused inspector registration variable only |
| `addons/tinymmo/export_plugin/export_plugin.gd` | Called from active editor plugin; replaces `source/server/*.gd` scripts with reflection-based stubs on client export, excludes SQLite addon and includes raw CEF UI images | **Keep. Production export dependency.** Not safe to remove the addon wholesale |
| `addons/tinymmo/main_screen/main_panel.gd` | Instantiated and exposed by active plugin, generates content indices and warns about quest prereq cycles | Keep until content-index workflow is separately migrated or retired |
| `project.godot` user dir | `config/custom_user_dir_name="slayhorizon"` | Do not rename casually: migration of existing user data must be planned |
| `source/common/gameplay/maps/terrain3d_spike/` and `tools/terrain3d/*spike*` | Explicitly named spike/test terrain | Candidate for later cleanup, but do not delete without reference scan and map/editor verification |
| `assets/sprites/characters/fungus_old/`, old 2D resources and `tests/legacy_batch_visual*` | Historical naming / 2D resources | Candidates for dependency inventory, not proof of being unused |
| `source/client/ui_web/web/skins/legacy.js` | The **live** CEF UI imports the legacy skin loader | Keep. Despite name, active UI |
| `docs/ui/legacy-ui-cache.md` | Documents a deliberate local-only, excluded asset export tool | Keep. Not a runtime dependency, but documents reproducible workflow |

## Next cleanup passes, separately reviewed

1. Enumerate all runtime, scene, autoload, export preset and test references before removing `TinyNodePath`, inspector helpers, content-index authoring files or old 2D assets.
2. Relocate export stubbing and raw CEF asset rules into a first-party export plugin if removing TinyMMO branding is desired. Test **real exported client/server artifacts**, not only headless Godot unit tests.
3. Consider removing confirmed-unused legacy assets in small groups, including paired `.import` and resource UID files, and test resources/scenes that reference them.

## This PR's scope

Only removes disabled/commented editor bootstrap code and corrects addon documentation. No gameplay logic, export behavior, config/user-data location or assets were changed. Godot editor startup/export smoke must still be run before merge.
