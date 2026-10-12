# V4 — Terrain3D workflow spike: compatibility gate failed

The spike stops at the required server/headless compatibility gate. A saved
Terrain3D scene crashes on Windows world-server/headless with an access violation
in native Terrain3D code. This report does not claim the full V4 acceptance list
passed. No First Region migration, server collision substitute, vendor patch,
Godot upgrade or client/server terrain split has been implemented.

## Baseline and branch

- Starting local `main`: `495d8f3f9ebcc020806cc1cca693565c0387d18b` (V3 merge).
- Topic: `codex/visual-v4-terrain3d-spike`.
- Tracked working tree was clean. The pre-existing untracked
  `docs/item-drag-runtime-system.pdf` was preserved.
- Global plugin enablement and initial CI provisioning changes were rolled back
  after the failure. Existing rendering, gameplay and First Region sources are
  unchanged. The failed spike remains on its topic branch, not merged into main.

## Version

Godot remains **4.7.2-stable**, official Windows x86_64 console executable,
`ed1daf0bf001b61586d9930840f2f1394092c079`. Project renderer/backend remain
Forward+/Vulkan. **Terrain3D 1.0.2-stable** is the official stable release,
[release page](https://github.com/TokisanGames/Terrain3D/releases/tag/v1.0.2-stable).
Upstream declares Godot 4.4–4.6+ support; this declaration is not proof of our
4.7.2/headless resource-loading path.

## Integration

`tools/terrain3d/setup.py` installs the official `Terrain3D_v1.0.2-stable.zip`
under ignored `addons/terrain_3d`, retaining the original editor scripts,
extension descriptor, notices and Windows/Linux x86_64 debug/release binaries.
It verifies SHA256
`a071850250ec5e596aa54da61c01d75768774eb379ee997584d426a45f4884a2`, matching
the release asset's published GitHub digest. No native binaries or upstream demo
are committed. The addon license is MIT, copyright 2023–2026 Cory Petkovsek,
Roope Palmroos and contributors; the installed `LICENSE.txt` must accompany
distribution. See [official installation](https://terrain3d.readthedocs.io/en/stable/docs/installation.html).

Required native libraries are `libterrain.windows.{debug,release}.x86_64.dll`
and `libterrain.linux.{debug,release}.x86_64.so`. Other platform binaries are not
installed by this repository's helper. The GDExtension registers when installed;
the editor plugin is deliberately **not enabled globally** after the failed gate.

## Prototype

The isolated candidate is
`source/common/gameplay/maps/terrain3d_spike/terrain_spike.tscn`. It is not
registered as a startup map. Its committed resources and generator are diagnostic
inputs for resolving the compatibility problem, not an accepted production map.

The deterministic generator `tools/terrain3d/generate_spike.gd` produces one
256×256-sample native region at 1 m spacing (approximately 256×256 m), with a
flat combat area, 12 m gentle Gaussian hill, 28 m steep ridge, 3.5 m shallow
depression, winding painted road and a graded eastern shore. It uses source
formulas, not a manual sculpt session. Native data are saved to
`data/terrain3d_00_00.res`; regeneration explicitly overwrites the baseline and
must not be run over manual editor edits that should be retained.

Four 256×256 temporary seamless PBR layers are prepared: grass, dirt, path and
rock. Each has RGB albedo / alpha height and RGB normal / alpha roughness packed
into saved ImageTexture resources. The fixed analytic grain is generated locally;
there is no third-party texture pack or legacy dependency. Terrain assets use
UV scale 0.22, normal depth 0.35, detiling rotation 0.12 and shift 0.15. Manual
grass/dirt blend and road controls coexist with autoshader areas using grass/rock;
the autoshader slope parameter is 4.0 and blend sharpness 0.75. A low-amplitude
0.88–1.0 color map supplies macro variation. These settings are prepared, not
visually accepted. [Texture packing reference](https://terrain3d.readthedocs.io/en/stable/api/class_terrain3dtextureasset.html),
[control map reference](https://terrain3d.readthedocs.io/en/stable/docs/controlmap_format.html).

The scene keeps the production `PlayerActor3D.simulate`, `MobActor3D.simulate_mob`
and `MandateCamera3D` rig for its local workflow preview. The small dog path driver
is confined to the prototype; current production pack AI is not redesigned.
The prepared eastern water plane reuses the unmodified V3 ShaderMaterial at
y=-0.5 and lets the terrain supply submerged depth. It adds no artificial bed.
Runtime movement, water appearance and slope handling have **not** been accepted.

## Collision and navigation

Collision is configured as native **Full / Game**, layer 17 (scenery 1 + mob
floor 16), rather than camera-centered dynamic collision. In programmatic setup,
collision aliases set before native subsystem creation can be ignored; configure
the collision object after the node enters the tree. This explains an initial
failed flat collision probe that was rerun with the documented full mode.
[Collision reference](https://terrain3d.readthedocs.io/en/stable/docs/collision.html).

A minimal in-memory headless terrain passes a raycast at y=5. Separately, native
saved data loaded programmatically after initialization pass a raycast at
`(52, 0.145971, 55)`, agreeing with the source height. This confirms a working
collision/data path, not safe loading of the serialized map scene. The latter
fails before gameplay acceptance can run.

The generator bakes **2928 navigation polygons** through the existing Godot
NavigationServer3D pipeline, adding native
`generate_nav_mesh_source_geometry` faces. Static collider parsing alone does
not supply Terrain3D faces. Settings match the current gameplay bake: radius 0.5,
height 1.2, climb 0.2, cells 0.125×0.1, slope limit 45 degrees. Navigable control
bits exclude the submerged shore and outer border; the bake AABB covers 236×236 m.
The result is saved as `navigation.res`. Flat/hill/steep/water path endpoints and
runtime mob following remain unverified because the scene compatibility gate
failed. [Upstream navigation workflow](https://terrain3d.readthedocs.io/en/stable/docs/navigation.html).

## Runtime failure and reproduction

The full saved prototype crashes under `--headless --mode=world-server`.
Removing serialized collision settings does not prevent the crash. The smaller
`tools/terrain3d/repro_scene.tscn` removes all project gameplay/preview scripts and
still crashes when loading a Terrain3D node with the saved material, assets and
data directory. The bounded diagnostic reports exit **3221225477 / 0xC0000005**,
and the engine logs **signal 11** with native frames at
`libterrain.windows.debug.x86_64.dll+41cb9`, `+2744ae`, `+afda1`.

```powershell
python ./tools/terrain3d/setup.py
& ./.godot/Godot_v4.7.2-stable_win64_console.exe --headless --path . --mode=world-server --script tools/terrain3d/generate_spike.gd
python ./tools/terrain3d/probe_saved_scene.py
```

The probe intentionally returns failure for the crash and stops its own process
after a bounded timeout. It is an opt-in reproducer, not a new default test suite.
Ignored logs are `.godot/verification/visual-v4-saved-scene-repro.log`,
`visual-v4-scene-headless.log`, `visual-v4-order-repro.log`, `visual-v4-gate.log`
and `visual-v4-saved-gate.log`. The precise native root cause is unresolved;
the stack does not establish which library/engine defect is responsible.

The successful programmatic path also logs missing active camera (it stops
render snapping) and null material parameter diagnostics from the dummy renderer.
No fake server camera, stripped server material scene or alternate collider
has been added to hide those differences.

Windows native Forward+ rendering and a saved-scene server export boot are not
claimed as passing. The existing Windows resource-pack export also crashes while
processing the saved terrain scene, with the same native offsets. Its log is
`.godot/verification/Windows.export.log`; the runner stops before ServerWindows
and ServerUbuntu. This is a second affected headless path, not a successful
packaging check. Linux x86_64 binaries are included in the pinned distribution,
but actual Ubuntu execution is unavailable: installed WSL Ubuntu fails with
`HCS_E_HYPERV_NOT_INSTALLED` because local virtualization is disabled. No system
configuration changes were made. A ServerUbuntu resource-pack check does not
prove Linux extension execution.

## Editor workflow

The prepared candidate has the native Terrain node under `Navigation`, a dedicated
data directory and separate material/assets resources. After the compatibility
failure is resolved, enable Terrain3D in Project Settings → Plugins, open the
candidate, select `Navigation/Terrain`, and use Raise/Lower, Smooth, Paint Texture
or Spray Texture. Choose grass/dirt/path/rock in the asset dock; painting an
authored path disables the autoshader locally. Save both scene and native region
data. Select the Terrain3D menu's Bake NavMesh after editing, not the ordinary
NavigationRegion3D bake button. Change layers through the asset dock and preserve
the required packed channels/equal texture dimensions. See
[painting](https://terrain3d.readthedocs.io/en/stable/docs/texture_painting.html)
and [navigation](https://terrain3d.readthedocs.io/en/stable/docs/navigation.html).

This is a prospective checklist, **not** an assertion that subjective editing,
undo/redo or runtime preview passed. Initial headless editor enablement in a
restricted AppData environment additionally raised an upstream DoubleSlider
Nil-to-int EditorSettings error. Global plugin enablement was reverted; no vendor
UI patch was made. Manual editor testing and optional instancing were stopped.

## Performance and acceptance

GPU median/p95 are **not measured**: visual/performance work was stopped after
the mandatory server gate failed. Mesh settings prepared for later evaluation
are mesh size 32 and six LODs; no instancing was added. V3 timing is not presented
as Terrain3D timing.

Only deterministic data/PBR preparation, native collision probes and navigation
generation are demonstrated. Safe saved-map loading, actual terrain movement,
runtime pathing, shoreline visuals, native Forward+ acceptance, manual authoring
and GPU cost remain unproven. V4 is **stopped**, not a completed accepted workflow.

## Regression verification

After reverting global plugin enablement:

- Editor import/parse with writable verification AppData: PASS, no script/parse
  or failed-resource errors. This import does not instantiate the failed scene.
- `git diff --check`: PASS.
- Default smoke and 74 Web UI contracts: PASS.
- Existing First Region navigation/spawns/shore-blocking fixture: PASS.
- Existing three-process movement/authority/collision/disconnect suite
  `run-spike3d.ps1`: server and both clients PASS.
- Existing camera collision/picking fixture `run-camera.ps1`: PASS.
- Saved Terrain3D world-server/headless scene: FAIL (native access violation).
- Windows resource-pack export with the spike present: FAIL (same native crash);
  subsequent server export checks did not run.

No accounts, runtime databases or user servers were changed. Crash probes are
bounded and terminate only their own processes. Existing user-owned gateway,
master and world processes were identified and left running. Logs, downloaded
archives, binaries and inspection sources remain ignored.

## Adoption recommendation

Do not adopt this pinned Terrain3D release/configuration as the production map
authoring solution while the required saved-scene headless path can terminate the
World Server. The next decision requires a confirmed native fix or supported
release that loads the same authored terrain/resources safely on Windows and
Linux, followed by the deferred workflow/visual/performance checks. The evidence
does not reject every Terrain3D version, but it rejects adoption on today's
verified configuration. First Region and V0–V3 remain the integrated baseline.

DO NOT ADOPT
