# Local map walking playtest

Instance `res://tools/map_playtest/map_playtest.tscn` as a child of your authored
map root, save the map and press **F6 / Run Current Scene**. Move the MapPlaytest
marker in the editor to select a starting XZ location. Runtime raycasts place the
actor on the highest scenery surface at that location. Place it away from roofs
if you want to start on the ground. R resets to that location after falling out.

To leave an authored scene completely untouched, use a separate wrapper scene:
an empty Node3D root with the authored map instance and MapPlaytest instance as
siblings. Edit/save the original map, then F6 the wrapper to walk its latest saved
version. No terrain or startup-map change is necessary.

- WASD: walk at production movement speed, relative to camera.
- Hold RMB: orbit; mouse wheel: zoom with the production collision camera.
- R: respawn. Escape: release captured mouse. Losing focus cancels camera orbit.
- The overlay shows position and FPS. It never captures movement/mouse input.

The harness reuses PlayerActor3D, WarriorVisual3D and MandateCamera3D. There is
no login, networking, CEF, persistence, mob simulation or combat. This local
controller is a tool; it does not change server movement authority. Standard
local staged Warrior assets are used if installed; otherwise the normal checked-in
Warrior placeholder works. No legacy asset is added to Git.

Terrain3D receives runtime Full/Game collision on scenery + camera layers (17)
and the playtest camera. Saved height/control data, materials and assets are not
modified. If no WorldEnvironment exists, a temporary production lighting scene
is added. Disable `enable_preview_lighting` if authoring your own lighting.

Keep the map's own geometry/data separate. Remove the MapPlaytest child before
using the map as a production template. The runtime never loads this tool by
default. Use **F6** for the map; F5 still opens the normal game/login.
