# Production CEF Inventory

The first real Inventory window follows [UI Contract v1](ui-contract.md).
The actual Metin screenshot guides density and proportions; the Mandate concept
is a future art-direction reference. This slice implements Inventory only.
Equipment, Shop, character sheet and the rest of the HUD are outside this screen.

## Layout and interaction

The window is 266 logical pixels wide, right-anchored by default, with a draggable
title, close button, I–IV tabs and Yang footer. Each page is 5×9 at 40 px per
slot. The slot size is a CSS variable. Items occupy 1×1, 1×2 or 1×3, without
rotation. The current real Iron Sword occupies three vertical cells; the local
preview includes all three sizes without adding mock item definitions to gameplay.

Drag with pointer capture, or click once to carry and click to place. Green/red
previews are advisory. A drag may submit an invalid placement and get rejected;
an invalid click-to-place retains the held item. Escape first cancels carrying,
then closes. Click-carried items can move between page tabs. Wallet updates do
not cancel carrying. Authoritative inventory updates, close, resize, scale changes,
blur and pointer cancellation release transient capture/ghost state. Compact
hover tooltips flip and clamp to the viewport.

Opening is **not globally modal**. The window reports its physical rectangle.
A click-carried item temporarily reports a full-screen pointer region, then
releases it on placement/cancel. Normal button drags retain native host capture.
Clicks outside UI return keyboard ownership to gameplay. Closing clears focus
and removes Inventory's regions while leaving the global browser alive, allowing
future unrelated regions to continue working.

## Authority and persistence

`InventoryWebController` maps private server state; the view has no CEF APIs.
It renders `ui.snapshot` and `inventory.updated`; `wallet.updated` and
`hud.updated` refresh information/layout without replacing item state.
`ui.ready` after reload/recreation receives the current full snapshot. Commands
reuse request correlation and await the actual World Server operation reply.

```json
{"type":"inventory.move_item","payload":{"id":"<uid>","revision":3,"x":2,"y":4,"page":1}}
```

The protocol wrapper adds `v: 1` and a correlated request ID. The only other
screen command is `inventory.close`. Neither exposes arbitrary method calls.

World Server validates coordinates, ownership, revision, bag placement,
page boundaries and every occupied cell. Placement and revision commit in one
immediate SQLite transaction. Rejections republish authoritative state; JS never
commits a local item move. Native equip/unequip and runtime combat-stat refresh
retain their existing atomic flow.

Schema **v15** expands bag anchor positions to 0–179 (four 45-cell pages).
An atomic migration retains UID, owner, stats, affixes and sockets. Old anchors
are kept when valid; collisions are repacked into the first available footprint,
with a revision increment. A failed migration rolls back placement/schema/version
changes. No items are deleted. Pickup/free-slot search and equipment swaps now
respect footprints. This is a small explicit grid model, not a stat or crafting
framework. XP and wallet checkpoint policy is unchanged.

## Local skin

`tools/dev_assets/stage_ui_skin.py` copies selected individual PNGs from ignored
`dev_assets/legacy/ui_cache` into ignored
`source/client/ui_web/web/inventory/legacy_skin`. It verifies byte-identical
SHA-256 hashes; there is no resampling. Semantic names include corners, edges,
fill, title, close states, slot, Yang and item icons. `skin.js` is the replaceable
asset boundary. Edges tile; icon rasters keep native dimensions. Text is real
font rendering. No CSS atlas coordinates, CDN, internet asset loading or frontend
framework is involved. A checkout without local skin uses CSS/text fallbacks; the browser test also
checks a deliberately unavailable skin module.

Stage the existing extracted cache:

```powershell
python tools/dev_assets/stage_ui_skin.py
```

The gameplay launcher also stages the skin automatically. If item icon exports
are missing, the exact PNG exporter can generate them from the local reference:

```powershell
python tools/dev_assets/export_ui.py --source-root 'N:/Mandate local/metin2/bin/pack/icon/icon' item/00010.tga item/00020.tga item/27001.tga
```

Legacy skin remains visibly limited at large scales. Replace it with Mandate
assets meeting the 2×/150% quality target later; do not enhance legacy graphics.

## Launch and scale

Keep gateway/master/world running from the root CEF-free project, then:

```powershell
& ./tools/cef_client/run.ps1
# Prepare/import without opening a game window:
& ./tools/cef_client/run.ps1 -SetupOnly
```

This copies source/config/assets/tests into `.godot/cef-client/project`, with
pinned godot-cef v2.0.0, Godot 4.7.2 and Vulkan Mobile. CEF binaries, profiles,
reference PNGs and runtime stores remain ignored. The staged client defaults to
a 1280×720 window with a 1920×1080 design baseline and **disabled canvas stretch**.
The browser tracks actual window pixels. Root servers/headless builds have no
CEF dependency; unsupported clients retain native inventory.

Godot's `InventoryWebController.set_ui_scale()` accepts the contract's scale list.
For development set project setting `mandate/ui_scale` or launch the staged
client with `--ui-scale=125`. Scale is selected once and stays independent of
subsequent window resolution. No settings screen is included in this slice.

Local fixture preview:

```powershell
python -m http.server 18741 --bind 127.0.0.1
```

Open [inventory preview](http://127.0.0.1:18741/tools/inventory_preview/).
`?scale=0.9` changes preview scale. Its mock host is never used by the game.

## Verification — 2026-10-09

```powershell
& ./tests/run-smoke.ps1
# Optional when changing inventory RPC/session behavior:
& ./tests/run-web-inventory.ps1
```

The prototype policy now keeps only durable headless contracts by default.
The browser matrix/native fixtures described below were executed during the
initial integration and then retired on 2026-10-09. Their results are historical;
repeat the [UI contract matrix](ui-contract.md) manually at a layout milestone
using the real staged client. See [testing policy](testing.md).

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
