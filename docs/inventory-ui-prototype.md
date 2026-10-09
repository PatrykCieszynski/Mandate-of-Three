# Equipment and backpack visual prototype

A local HTML/CSS/JS preview of the first Mandate inventory design. The browser preview remains an isolated mock. The same view is now connected
to real Spike 3D inventory in the optional Vulkan/CEF client described below.
The root client retains a native fallback.

## Preview

From the repository root:

```powershell
python -m http.server 18741 --bind 127.0.0.1
```

Open http://127.0.0.1:18741/tools/inventory_preview/ in a browser. Stop the local
server with Ctrl+C. No npm installation, CDN, frontend framework or remote assets.
The preview backdrop is illustrative; the reusable UI has no world background.

## Layout and interaction

- Separate equipment and backpack panels, aged gold borders and dark surfaces.
- CSS placeholder character silhouette and editable local SVG item icons.
- Six-column, seven-row backpack with item heights 1, 2 and 3; no rotation.
- Click-to-carry: one click picks up an item, the next valid click places it.
  A cursor ghost and green/red preview show the held item. Invalid placement
  keeps it held; Escape cancels before closing the inventory. Placement only
  changes after a committed snapshot update. Resize, close and snapshots cancel
  the transient carry state.
- Tooltip on hover/focus, item quantities, occupied-cell count and Yang balance.
- Close/reopen; Escape closes and I toggles the preview. Narrow layouts wrap panels.

Equipment slots are display-only. Equip/unequip, page tabs, sorting, destruction,
3D character preview and rich item art are not implemented. All sample values are
fixture data. Nothing is written to the database.

## Boundary

`source/client/ui_web/web/inventory/inventory-view.js` exports
`mountInventory(root, {moveItem, onClose})`, returning `setState(snapshot)` and
`dispose()`. It has no CEF API calls. Snapshot shape:

```javascript
{
  inventory: {columns: 6, rows: 7, revision: 1,
    items: [{id: 'blade', name: 'Bronze Sword +0', icon: 'blade',
      x: 2, y: 1, height: 2, quantity: 1}]},
  equipment: {slots: [{slot: 'weapon', label: 'Weapon', icon: 'blade'}]},
  wallet: {balance: 100090}
}
```

Optional item display fields: category, description, attack. Text is inserted via
textContent; icon paths are selected from a fixed local set. The injected
moveItem callback accepts `{id, x, y, revision}` and resolves `{ok, error?}`.
Results display status only. The caller publishes committed/reconciled state
via setState. A timeout does not infer success or cancel an already sent action.

`tools/inventory_preview/preview.js` is the only sample-data/validation host.
Its in-memory validator imitates the interaction boundary and is not server
validation. Live integration must register the actual inventory command, consume
server updates, map real item/equipment/wallet data and report both panel regions
through the existing bridge. Browser recreation must receive a full snapshot.
Do not connect this preview validator to persistence or authoritative gameplay.

## Verification — 2026-10-08

Headless Chromium (installed Edge) checked desktop rendering at 1440×900,
600×950 layout, valid placement, overlap rejection and unchanged rejected placement,
close/reopen, Escape/I and absence of JavaScript errors. Both screenshots were
visually inspected. Existing Web UI protocol/application tests passed (five JS
tests plus Godot headless checks). No CEF game window was opened. Native CEF,
physical input, DPI and live server inventory integration remain unverified for
this new view.

## Gameplay integration

Start master/gateway/world normally from the root, then launch the staged client:

```powershell
& ./tools/cef_client/run.ps1
```

The launcher uses Python 3.11+ and the local Godot 4.7.2 executable, verifies the
pinned CEF v2.0.0 archive and copies the game into `.godot/cef-client/project`.
The default entry is the normal game login, followed by the existing 3D instance.
CEF binaries/profile/import caches remain ignored. Root server projects are not
modified and can still run headless without CEF. `-SetupOnly` prepares/imports the
client without opening a game window. Refresh staging after editing sources.

I opens the equipment/backpack UI in a Vulkan Mobile client. Left click picks up
an item; another click places it. Invalid local placement retains the carried
item. Escape cancels carrying first, then closes. Right click a bag weapon to
equip; right click the equipped weapon to unequip. Close/I releases gameplay
input. The displayed name, level, weapon attack/comparison and Yang come from
current authoritative state, not preview fixture values.

The current real item model has **24 individual bag slots** and only one weapon
slot. The game view therefore displays **6×4, height-one items**; it does not
pretend that the 6×7 mock's larger item shapes are authoritative. Other equipment
slots and multi-cell inventory require an explicit future domain change. The
silhouette and SVG weapon art remain placeholders.

Bag moves use UID + item revision + destination through authenticated RPCs.
Ownership, bag-only placement, revision, bounds and occupied cells are validated
on World Server. Position and revision commit immediately in a single SQLite
transaction. Rejection republishes the committed inventory. Equip/unequip use the
existing atomic transaction and runtime-stat refresh. Wallet income/checkpoints
and combat runtime reads retain their existing policy.

`game.html`, `game.js` and `game.css` are the bundled screen entry; the mock host
is not used in the game. `InventoryWebController` owns mapping/command correlation
and UI visibility. The reusable view contains no CEF calls and commits no local
item mutation. Non-inventory updates do not reset the carried item.

```powershell
& ./tests/run-web-inventory.ps1
# After staging is refreshed/imported; opens one final rendered client:
& ./tests/run-web-inventory.ps1 -WithBrowser
```

The two-client test covers real move/equip/unequip RPCs, stale/occupied rejection,
private snapshots, runtime attack and SQLite reopen. The browser mode additionally
uses test-only DOM events through actual CEF IPC, periodic-update carry retention,
reload/snapshot, modal ownership, hide/show, transparent rendering and process
shutdown. Synthetic DOM events do not prove physical mouse/keyboard input or DPI.

Verified on 2026-10-08: item SQLite tests (including move ownership, stale revision,
occupied/bounds rejection, injected revision-write rollback and reopen), the
headless two-client Web inventory scenario, and the Vulkan CEF gameplay scenario
all pass. The rendered run verified DOM → IPC → World Server move/equip/unequip,
reload/modal state, an inspected transparent 3D capture and zero owned process
survivors two seconds after exit. A separate headless browser check covered carry
retention on player/wallet updates and cancellation on programmatic close.

Existing items, movement, PvE, combat, progression, XP, Yang and Web bridge tests
pass. The pre-existing four ObjectDB exit leaks/three resource warnings remain.
During integration the fixture's non-element click target and readiness race
were corrected; the adapter's focus release now safely handles scene teardown.
Physical mouse/keyboard, IME/DPI and release packaging remain manual/release gates.
