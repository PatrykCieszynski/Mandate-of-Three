# Whole-repository legacy inventory — 2026-10-17

## Coverage and limits

Enumerated **3,412 tracked blobs** in the cleanup branch's recursive Git tree (not merely `addons/tinymmo`). Reviewed the root configuration, README, CI workflow, role dispatcher, export plugin, world-test scripts, terrain preview, legacy currency command and representative resource files. Added `tools/audit-legacy-references.py` for an exhaustive **local literal-reference scan** across text code/resources, which must be run in a full checkout; this GitHub-only review cannot prove absence of dynamic `load()`, UID, generated or string-composed references.

### Cross-project triage

| Area | Evidence from inspected sources / tree | Action |
|---|---|---|
| Editor addons | TinyMMO editor export plugin actively generates server-class stubs; Godot SQLite, Terrain3D and sky plugins configured | **Retain**; rename/restructure only with client export regression |
| Old editor inspector | Not registered by active TinyMMO plugin; private popup, helper and property editor chain | **Removed** on this PR; 13 files including UID sidecars |
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

### How to run the repeatable inventory

```powershell
python tools/audit-legacy-references.py --limit 250
```

`0` means **zero matching literal `res://path` references in scanned text files**, **not** proof of unreachability. Inspect class-name usages, UID-based resource references, indexed resource paths, generated exports and runtime loads before deletion. The scanner makes no filesystem changes.

## Cleanup sequencing

1. Run the new local scanner and a Godot cold import. Sort zero-reference candidates by areas and verify via scene/resource UID lookup.
2. Map the whole old 2D inventory/economy registry against the new `ItemDefinition` / `ItemInstance` domain, including commands; only then remove confirmed orphan assets and matching `.import`/UID sidecars.
3. Map all 2D scene dependencies, animations and content indexes. Delete small groups behind smoke + exported client/server checks.
4. Keep preview and multi-client integration scenes until replacements exist.
5. Relocate TinyMMO's **active** export stubbing to first-party naming in a separate migration with packaged-build verification, rather than deactivating the plugin.

No bulk legacy 2D assets or tests were deleted in this pass; evidence at this stage does not justify that risk.
