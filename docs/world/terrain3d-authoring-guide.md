# Terrain3D map authoring — Mandate quick guide

Verified against the current repository and installed Terrain3D 1.0.2-stable /
Godot 4.7.2 setup. Documentation only: no terrain was regenerated, sculpted or
migrated, and no startup map was switched while preparing this guide.

## Map boundaries: recommendation, not a new accepted ADR

Prefer **several connected geographic maps, each continuous within itself**.
A starter valley can contain its hub, roads, several mob areas, shortcuts, shore
and Metin sites without scene transitions between those local areas. A mountain
pass/gate/portal can connect it to another map. Dungeons can have separate map
templates and public/private admission. A loading/transfer boundary is acceptable;
seamless cross-map simulation is not required for the first implementation.

This fits the accepted [MapInstance architecture](../architecture/world-instance-architecture.md).
It does not decide the final number, dimensions or geography of maps, nor does it
implement a new cross-map transfer. Existing local channel transfer moves between
copies of the same map; do not assume it already handles a new geographic map.

| Term | Meaning |
| --- | --- |
| Terrain3D region | A tile of saved height/control/colour data; adjacent tiles can form one continuous terrain |
| Map template | Authored geography, colliders, navigation and gameplay markers |
| MapInstance / CH copy | A live simulation of that map with its own actors and lifecycle |
| World Process | Hosts instances; neither a terrain tile nor necessarily one map/channel |

Do not split every mob clearing into its own map, or create a server instance for
every Terrain3D tile. Conversely, GPU terrain LOD does not implement world/object
streaming, AOI, navigation partitioning or seamless server handoff. A giant single
terrain does not remove those costs. See upstream [architecture](https://terrain3d.readthedocs.io/en/stable/docs/system_architecture.html).

## 1. Open the working editor example

From the project root, open the existing project in its pinned editor:

```powershell
& ./.godot/Godot_v4.7.2-stable_win64_console.exe --editor --path .
```

If Terrain3D is missing, close Godot and run `python tools/terrain3d/setup.py`,
then reopen. Use the pinned installer rather than upgrading from AssetLib.
Check **Project → Project Settings → Plugins → Terrain3D** is enabled.

Open `source/common/gameplay/maps/terrain3d_spike/terrain_spike.tscn`.
Select **Navigation/Terrain** in the scene tree to show Terrain3D tools and the
asset dock. Despite the folder's historical name, this is our persisted working
authoring/compatibility example. It is **not** the multiplayer First Region.
Do not run `generate_spike.gd` to open/edit it: that regenerates saved terrain
and can overwrite manual work.

The example has one 64×64-sample region at 1 m spacing, approximately 64×64 m,
four temporary texture layers and a saved navigation mesh. Use it to understand
scale and editing before creating a much larger map. Commit/back up existing
scene/resources/data before experimenting, including any prior manual edits.

## 2. Sculpt a small playable area

Start with low brush strength and a broad brush for landforms, then smaller
brushes for adjustments. Select tools by their tooltip; installed shortcuts are:

| Tool | Use |
| --- | --- |
| Add Region (`E`) | Allocate terrain where none exists; neighbouring tiles stay part of the same terrain |
| Raise / Lower (`R`) | Build hills or depressions |
| Smooth (`Shift`) | Soften uneven slopes and brush edges |
| Height (`H`) | Establish a level height, useful for hub/building pads |
| Slope (`S`) | Form a controlled ramp between heights |
| Paint Texture (`B`) | Establish grass, dirt, path or rock areas |
| Spray Texture (`V`) | Blend the selected texture at edges |

With Raise selected, hold Ctrl to temporarily lower instead; Shift temporarily
smooths. Ctrl also inverts other tools, including Add Region → Remove Region,
so check the active tooltip before clicking.

For a first exercise, make one flat hub pad, a 4–6 m main path, a low hill,
a wider combat clearing and a side route. Those widths are starting design
suggestions, not engine limits. Walk the result before adding fine noise.
Use ramps on traversal routes rather than many small ledges: our example nav
agent has only 0.2 m climb allowance. Test camera clearance against a few simple
building/rock meshes as well as the terrain.

Undo/redo small edits and save frequently. Region removal deletes authored
ground; it is not a visibility toggle. See upstream [editor UI](https://terrain3d.readthedocs.io/en/stable/docs/user_interface.html).

## 3. Paint surfaces after the main shapes work

Use the asset dock's Grass / Dirt / Path / Rock entries in the example. Paint a
path/core surface with Paint Texture, then blend its edges with Spray Texture.
Autoshading can provide a broad grass/rock base, with manual painting for routes
and special areas. Do not reorder texture IDs after painting without deliberate
control-map migration: painted data refers to those IDs.

Keep the first pass to a few materials. They are presentation, not walkability
or biome/gameplay definitions. The current painted path does not automatically
create a road collider, spawn zone or navigation route. See upstream
[texture painting](https://terrain3d.readthedocs.io/en/stable/docs/texture_painting.html).

## 4. Save terrain data as well as the scene

In the example inspect:

- `Data Directory`: `res://source/common/gameplay/maps/terrain3d_spike/data`;
- external `terrain_material.tres` and `terrain_assets.tres`;
- saved `data/terrain3d_00_00.res` and `navigation.res`.

Save with Ctrl+S, close/reopen the scene/editor and verify both height and paint
survived. A `.tscn` alone is not a terrain backup: include native region files,
material/assets, texture sources and navigation when relevant. Check Git changes
for the region resources too. Never save generated region data under `.godot`.

Do not manually insert `region_size = ...` into a Terrain3D `.tscn`. That
editor-only migration property previously caused native load failures in our
hand-written scene. The corrected persisted regions carry their size; normal
editor saves handle this. Leave the existing example's size unchanged.

## 5. Collision, navigation and walking preview

Press **F6** with the example scene open: its existing script supplies a player,
camera, dog and local water preview. WASD moves, RMB orbits and the wheel zooms.
This exercises local production actor/camera code, not network gameplay.

The prepared scene uses **Full / Game** collision on layers **1 and 5** (numeric
mask 17). Layer 1 is scenery/player/camera support; layer 5 is also seen by mob
movement. Keep those settings when testing this example. Terrain3D's default
camera-centred dynamic collision is not a demonstrated solution for a headless
server simulating players spread across a map. Full collision has memory/startup
costs, so measure before making a very large map. See upstream
[collision](https://terrain3d.readthedocs.io/en/stable/docs/collision.html).

After changing terrain/routes or blocking props:

1. Select Terrain and paint **Navigable** areas where agents should walk.
2. Check the `NavigationRegion3D` and its external `NavigationMesh` resource.
3. Select Terrain, then use **Terrain3D → Bake NavMesh**. The ordinary Godot
   NavigationRegion bake button alone does not supply Terrain3D height geometry.
4. Save the mesh/scene; enable visible navigation to inspect the result.
5. Test a route up a gentle slope, around a collider and away from steep/wet ground.

Current example settings: radius 0.5 m, height 1.2 m, climb 0.2 m, slope 45°,
cell size 0.125 m and cell height 0.1 m. Its preview configures matching navigation
map precision. Reuse these as a compatibility baseline, not universal mob sizes.
Geometry is parsed as Static Colliders with layer-1 mask; native terrain faces
still come from the Terrain3D baker.
`tools/terrain3d/bake_spike_navigation.gd` writes the existing example's files;
do not run it expecting it to bake a differently named map. See upstream
[navigation](https://terrain3d.readthedocs.io/en/stable/docs/navigation.html).

Water is a separate surface/material. Sculpting a depression does not create
water or swimming rules. The example adds its local water plane at y = -0.5.
Keep navigable routes and spawn points on actual terrain, away from holes and
unallocated tiles.

## 6. Create your own authoring map

Once the small exercise is comfortable, create a new Node3D scene, add a
NavigationRegion3D with a fresh NavigationMesh and a Terrain3D child. Give Terrain
its **own empty Data Directory**, then allocate a region with Add Region. Save
material/assets to explicit external resources and add the temporary textures
through the asset dock. A proposed folder, not created by this guide:

```text
source/common/gameplay/maps/starter_valley/
  starter_valley_authoring.tscn
  terrain_material.tres
  terrain_assets.tres
  navigation.res
  data/
```

One region around 128–256 samples at 1 m spacing is a reasonable first authoring
budget, not a fixed game-map limit or performance guarantee. Decide the empty
terrain's region size in the editor before painting; later changes are data
migrations. Add adjacent regions when the playable layout justifies them. Keep
terrain/parent transforms at identity while establishing scale.

**Save As does not isolate external resources.** A copied scene can still edit
the old Data Directory, material, assets or navigation. If using the example as
a starting point, explicitly copy its terrain data and save independent mutable
resources, then inspect every reference before sculpting. Shared read-only
texture images are fine. Do not duplicate `.tscn` UIDs by editing scene text.
Upstream [scene setup](https://terrain3d.readthedocs.io/en/stable/docs/installation.html)
describes Data Directory and external resources.

A newly created bare terrain scene has no player/camera or gameplay simply
because Terrain3D was added. F6 walking above is specific to the prepared preview.
Connecting a new map to our production world/preview controller is a separate
small integration task; this guide does not silently attach the spike script
with its hardcoded spawn, dog route and shoreline to arbitrary maps.

## 7. Bring the authored map into gameplay after preview approval

Today `instance_collection/first_region.tres` still points to
`maps/graybox/first_region_3d.tscn`. Do not replace that with the standalone
authoring preview path and expect multiplayer to work.

The integration needs a gameplay map that preserves GameWorld3D lifecycle,
instance identity, endpoints and existing NPC/mob/Metin behavior. Replace the
graybox floor deliberately, load identical terrain data/collision on World and
client, place entry/respawn/NPC/pack/Metin markers at valid heights and adapt the
navigation bake to include native Terrain3D faces plus blocking scenery. The
current production bake parses static colliders; V4's saved native nav pipeline
is verified separately, not automatically wired into every new map.

After that, verify player movement, NPC approach, mob routes/return, camera
collision, loot placement and two-client/World consistency. Only then switch
the map resource. This is a future integration checklist, not work performed
by this documentation task.
