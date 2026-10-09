# Historical Inventory integration validation — 2026-10-09

Evidence from the initial browser matrix and retired native fixture. Use
[current Inventory](../inventory-ui-prototype.md) and [testing policy](../testing.md)
for current setup and checks.

The prototype policy now keeps only durable headless contracts by default.
The browser matrix/native fixtures described below were executed during the
initial integration and then retired on 2026-10-09. Their results are historical;
repeat the [UI contract matrix](../ui-contract.md) manually at a layout milestone
using the root client. See [testing policy](../testing.md).

Items/grid tests pass: all heights, covered-cell overlap, page boundary, stale
revision, transaction rollback, v14 migration rollback/repack, cross-page move
and DB reopen. Two real clients pass private-state/UID/revision movement and
rejection checks. Existing movement, PvE, combat, progression, XP and Yang
regressions pass, including full-bag pickup and currency independence.

Headless Edge/Chromium passes **all ten contract matrix cases**: fixed geometry,
all three footprint renderings and drag, valid/invalid previews, accepted/rejected
state, click-to-carry across tabs, wallet updates, pointer capture, window clamp,
resize, tooltip flip/clamp, close region release and `ui.ready` reload recovery.
A very small viewport at 150% uses vertical scrolling without changing slots.

The final Windows Vulkan Mobile CEF run passes actual bundled DOM → CEF IPC →
World Server moves, periodic-update carry retention, reload/full snapshot,
region-based ownership, repeated close/open and clean shutdown with **zero owned
process survivors** two seconds after exit. The transparent 3D capture was
visually inspected; accelerated OSR was reported on RTX 4070. Synthetic DOM
input in that fixture does not prove physical input-to-photon behavior.

Web protocol tests pass (five JS cases plus headless Godot dispatcher/host
checks). Root and staged headless imports pass. The existing four ObjectDB exit
leaks/three resource warnings remain. Physical CEF mouse/keyboard, OS DPI/IME,
long-session soak and release packaging remain manual/release gates. Other
platforms are untested; Compatibility remains unsupported/best-effort.
