# Whole-repository legacy inventory — 2026-10-17

## Coverage and limits

Enumerated **3,412 tracked blobs** in the cleanup branch's recursive Git tree (not merely `addons/mandate_tools`). Reviewed the root configuration, README, CI workflow, role dispatcher, export plugin, world-test scripts, terrain preview, legacy currency command and representative resource files. No standalone diagnostic script is included. This GitHub-only review cannot prove absence of dynamic `load()`, UID, generated or string-composed references.

### Cross-project triage

| Area | Evidence from inspected sources / tree | Action |
|---|---|---|
| Editor addons | TinyMMO editor export plugin actively generates server-class stubs; Godot SQLite, Terrain3D and sky plugins configured | **Retain**; rename/restructure only with client export regression |
| Old editor inspector | Not registered by active TinyMMO plugin; private popup, helper and property editor chain | **Removed** on this PR; 11 files including UID sidecars |
| Legacy 2D gameplay/content | 2D sprite trees, hundreds of sprite frames and 2D-style item Resources coexist with new 3D item domain | **Audit next**: likely significant savings but indexed content / older game roles may load dynamically |
| Terrain3D spike | `terrain_spike.gd` is an isolated preview of production actors, nav terrain, movement and water; `tools/terrain3d/*spike*` author/validate it | **Retain pending mapping-workflow replacement**: currently useful for terrain editor experiments |
| Old network tests | `tests/run-spike3d.ps1` launches headless server and two clients, asserting network success markers | **Retain**: a network regression despite its name |
| Tests and CI | `verify.yml` checks cold Godot import, formatting, boundary rules, headless gameplay smoke, Web UI generated assets | **Retain** and use to validate removals; test-name age is not obsolescence |
| Web UI | `skins/legacy.js` is imported by live `inventory/game.js` | **Retain**; it is the active CEF skin adapter |
| Economy | `gold_command.gd` uses legacy `Inventory.add_item` / `Economy.gold_id()`, whereas current world uses Yang wallet; `gold.tres` is old resource | **Investigate** command registration and migration before removing; it could be an intentional admin/dev tool |
| Client/server entrypoints | `source/common/main.gd` dispatches all four roles via flags | **Retain**; no blind removal of any role |
| Persistence | `project.godot` retains `custom_user_dir_name="slayhorizon"` | **Migration required** before rename to avoid losing local saved-data lookup |
| Placeholder scenes | `assets/placeholders/**` contains old warriors, wolves etc. | **Candidate**, but first run literal/UID lookup and inspect dynamic constructors |
| Translation/themes/icons | Many historical assets retained and some referenced through registries/skins | **Candidate inventory only**, not bulk delete |
| Docs | Older prototype documents coexist with current source-of-truth notes | **Keep** or label archived; documentation has no runtime footprint |

## Cleanup sequencing

1. Inspect candidate references in code/scenes and run a Godot cold import; verify scene/resource UID references.
2. Map the whole old 2D inventory/economy registry against the new `ItemDefinition` / `ItemInstance` domain, including commands; only then remove confirmed orphan assets and matching `.import`/UID sidecars.
3. Map all 2D scene dependencies, animations and content indexes. Delete small groups behind smoke + exported client/server checks.
4. Keep preview and multi-client integration scenes until replacements exist.
5. Relocate TinyMMO's **active** export stubbing to first-party naming in a separate migration with packaged-build verification, rather than deactivating the plugin.

## Deletion boundary confirmed during follow-up

- `source/common/gameplay/characters/entity.gd` is the base of the still-present 2D `Character` -> `Player` inheritance hierarchy. Dead commented synchronization implementation was removed, but the class remains active within the legacy server model.
- `source/common/gameplay/characters/player/player_resource.gd` contains persisted data fields retained for SQLite compatibility; deleting it or rewriting the save shape is **not** asset cleanup.
- `source/common/gameplay/combat/ability/ability.gd` is a concrete `AbilityResource` hierarchy, not a standalone unused prototype.
- The tracked Git tree did not reveal a separately named TinyMMO `review/` directory. Reference source kept outside this checkout must not be deleted or inferred from runtime reachability.
- GitHub code search returned incomplete results; lack of search hits must not be treated as proof of no callers.

No bulk legacy 2D assets or tests were deleted in this pass; evidence at this stage does not justify that risk.


## Current follow-up

The former `addons/tinymmo` addon path has been retired. Active ContentIndex editor UI and the required client/server export-stubbing plugin now live under `addons/mandate_tools`, with source content and script UID identities preserved. `project.godot` now registers the new editor plugin path. Packaged client/server exports still require separate validation beyond import/smoke CI.

## Production 3D-only boundary (follow-up)

The only checked-in authored instance resource in `source/common/gameplay/maps/instance/instance_collection/` is `first_region.tres`, explicitly `use_3d = true`. `InstanceManagerServer.prepare_instance()` selects `WorldInstance3D` for that resource; `WorldInstance3D` overrides legacy `load_map`, `_ready`, and the old ready-to-enter RPC so it does not instantiate the 2D Player scene. The `GameWorld3D` service still shares `PlayerResource` data.

The content-registry loader now **rejects authored `use_3d = false` instances** rather than silently entering the old 2D path. This does not yet remove `ServerInstance`, `Player`, `Character`, or `Entity`: 3D instances subclass `ServerInstance`, and old types still appear in the shared instance manager and ancillary services. Eliminating those classes requires separating the shared lifecycle/session host from the old Map/Player implementation, not deleting a folder. The existing in-memory compatibility fixtures are retained.

## Neutral instance host extraction

`source/server/world/components/instance_host.gd` is a new 2D-independent `InstanceHost : SubViewport` base for connected/pending peers, authored instance metadata, access policy, admission state, lifetime/budget counters, and admission checks. `ServerInstance` now inherits that base and retains its legacy 2D-specific scene, NPC/warper logic and synchronization. `WorldInstance3D` still extends `ServerInstance` for compatibility with existing manager/transfer/RPC types; moving it directly to `InstanceHost` is a further migration, not part of this extraction. Do not delete `ServerInstance` or the `Player`/2D classes until manager interfaces, transport RPC paths and test fixtures have been moved.
