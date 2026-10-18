# TinyMMO legacy remanent — first pass

## Verified findings

| Area | Evidence | Decision |
|---|---|---|
| `addons/mandate_tools/plugin.gd` | Active `[editor_plugins]` registration in `project.godot`; commented-out inspector and old debug-instance bootstrap | Removed commented bootstrap and unused inspector registration; then removed the disconnected inspector/property-editor popup subgraph (11 files, including .uid) |
| `addons/mandate_tools/export_plugin/export_plugin.gd` | Called from active editor plugin; replaces `source/server/*.gd` scripts with reflection-based stubs on client export, excludes SQLite addon and includes raw CEF UI images | **Keep. Production export dependency.** Not safe to remove the addon wholesale |
| `addons/mandate_tools/main_screen/main_panel.gd` | Instantiated and exposed by active plugin, generates content indices and warns about quest prereq cycles | Keep until content-index workflow is separately migrated or retired |
| `project.godot` user dir | `config/custom_user_dir_name="slayhorizon"` | Do not rename casually: migration of existing user data must be planned |
| `source/common/gameplay/maps/terrain3d_spike/` and `tools/terrain3d/*spike*` | Explicitly named spike/test terrain | Candidate for later cleanup, but do not delete without reference scan and map/editor verification |
| `assets/sprites/characters/fungus_old/`, old 2D resources and `tests/legacy_batch_visual*` | Historical naming / 2D resources | Candidates for dependency inventory, not proof of being unused |
| `source/client/ui_web/web/skins/legacy.js` | The **live** CEF UI imports the legacy skin loader | Keep. Despite name, active UI |
| `docs/ui/legacy-ui-cache.md` | Documents a deliberate local-only, excluded asset export tool | Keep. Not a runtime dependency, but documents reproducible workflow |

## Next cleanup passes, separately reviewed

1. Enumerate all runtime, scene, autoload, export preset and test references before removing content-index authoring files or old 2D assets. The disconnected inspector editor/popup chain was removed; `TinyNodePath` remains active via `source/common/network/sync/nodepath_helper.gd` because `property_cache.gd` calls it.
2. Relocate export stubbing and raw CEF asset rules into a first-party export plugin if removing TinyMMO branding is desired. Test **real exported client/server artifacts**, not only headless Godot unit tests.
3. Consider removing confirmed-unused legacy assets in small groups, including paired `.import` and resource UID files, and test resources/scenes that reference them.

## This PR's verified scope

The cleanup retires the former `addons/tinymmo` plugin path, keeps the live editor export stubbing and content panel under `addons/mandate_tools`, and relocates `TinyNodePath` without changing its script UID. It also removes confirmed unused editor/popup utilities, selected 2D-only admin commands and callbacks, and blocks authored 2D instance configurations in production client/server routing. The 3D-first admission and map lifecycle cleanup does not replace the legacy host classes.

The core 3D server still inherits `ServerInstance`, and the client still uses `InstanceClient` as its typed host. Their legacy Player, Map, warper, sync and RPC dependencies remain for a separately tested host migration. `PlayerResource`, database/storage, economy, and active export tooling are deliberately preserved.

**Verification completed:** GitHub CI clean checkout Godot 4.7.2 import, architecture boundaries, UI consistency checks and prototype smoke have passed on this PR. **Not equivalent to complete verification:** packaged exported client and server startup and dedicated multi-peer local-map regression have not been shown to pass after addon relocation. Do not claim those are complete or mark the PR merge-ready on that basis alone.

## Current follow-up

The former `addons/tinymmo` addon path has been retired. Active ContentIndex editor UI and the required client/server export-stubbing plugin now live under `addons/mandate_tools`, with source content and script UID identities preserved. `project.godot` now registers the new editor plugin path. Packaged client/server exports still require separate validation beyond import/smoke CI.
