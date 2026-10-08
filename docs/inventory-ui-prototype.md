# Equipment and backpack visual prototype

A local HTML/CSS/JS preview of the first Mandate inventory design. This is an
isolated presentation slice, not a migration of the live gameplay inventory.
The production CEF shell and the native inventory screen remain unchanged.

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
- Pointer capture, green/red placement preview, overlap/bounds rejection and
  committed-state restoration. Placement only changes after a snapshot update.
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
600×950 layout, valid drag, overlap rejection and unchanged rejected placement,
close/reopen, Escape/I and absence of JavaScript errors. Both screenshots were
visually inspected. Existing Web UI protocol/application tests passed (five JS
tests plus Godot headless checks). No CEF game window was opened. Native CEF,
physical input, DPI and live server inventory integration remain unverified for
this new view.
