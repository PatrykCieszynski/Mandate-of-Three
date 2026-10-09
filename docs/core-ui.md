# Internal Core UI

Accepted 2026-10-09. This is Mandate's small CEF presentation layer, extracted
from the production Inventory and Equipment. It is an internal composition tool,
with no frontend framework or public SDK contract.

The production browser logic is maintained in TypeScript and emitted to the
same static `web/` module paths. See [build and test instructions](../source/client/ui_web/README.md).

## Ownership

- `source/client/ui_web/ts/core/`: domain-agnostic window shell, geometry,
  chrome primitives (`core/primitives/`), semantic assets (`core/assets/`)
  and window behavior (`core/window/`).
- `game-ui/`: item grid (`game-ui/items/`), item tooltip/icon/slot and equipment slot presentation.
  These components accept data and dimensions; they make no gameplay decisions.
- `screens/inventory/` and `screens/equipment/`: composition, page/carry/pending state,
  equipment layout, advisory placement and injected domain actions.
- `content/item-icons.ts`: resolver for item content identity.
- `skins/legacy.ts`: adapter for the optional, exact legacy PNG manifest.
  It is the only runtime module that knows its concrete staging paths.
- `inventory/game.ts`: application composition; it chooses the skin, supplies
  resolvers/actions, owns one manager and binds the existing Web bridge.

Ownership, revisions, equip eligibility, free-bag selection, transactions and
combat stats stay in their existing Godot/server domain. CEF emits intentions.
The definition's `icon_id` travels through the private snapshot; it is content
metadata, with no item-instance schema change.

## Window contract

Create a `UiWindow` with an application-owned `WindowManager`, a stable
`id`, title and callbacks. Append screen content to `contentRoot`. It owns the section/chrome/titlebar,
close binding, shared lifecycle and region refresh hooks. A composed
`WindowDragController` owns pointer capture and coalesced dragging. It adds global
move/up listeners only during a drag and removes them on every termination.
`templates/ui-window.html` is compiled to a local static module by the build;
window construction performs no runtime fetch. The content wrapper uses
`display: contents` to preserve existing logical geometry. It composes `UiTitlebar`/`UiButton`; it does not own screen state.
`canDrag` lets Inventory suppress window dragging while carrying an item.
`onCancel` clears screen transients on blur, pointer cancellation, hiding,
resize, scale changes and disposal. `onActivate` is a presentation callback;
activation does not request native keyboard ownership.

`WindowManager` registers IDs, tracks `activeWindowId` and bounded z-order,
owns viewport/scale and browser resize, and invalidates layout. Registration
returns a `WindowHandle` with activate/place/move/resetPosition/dispose methods
and layout/activation hooks; it takes no renderer callbacks.
`WindowLayout` owns measurement, placement, clamping and manual positions.
Placement is either a viewport corner with an offset, or a relative target with
explicit side, alignment, gap and offset. An optional viewport fallback preserves
standalone placement before a relative target has ever been measured.
`setViewport(physicalViewport, scale)` handles snapshot/viewport changes;
`setScale(scale)` updates every registered root and re-clamps. Pointer-down
or focus inside a window raises its root; hidden windows cannot activate.
Registration rejects duplicate/empty IDs. Relative placement uses measured
geometry and detects cycles. Manual positions survive domain updates. Hidden
neighbors retain their last measured size; never-measured neighbors use the
ordinary anchor fallback. Small viewports allow vertical scrolling without
changing slot size or item footprints.

Inventory supplies its right anchor and offset. Equipment supplies its relation
to the Inventory ID and the gap. The manager has no knowledge of their meanings.
Escape retains production policy: cancel carry first, then request Inventory
close while open, then Equipment close. Z-order does not change shortcut policy.

`refresh()` measures visible windows; application visibility changes call
`manager.refreshAll()`. `onRegionsChanged` connects the shell to the existing
interactive-region reporter. Dispose screens/components before disposing their
manager/reporter. `UiWindow.dispose()` cancels capture/frames, removes its event
listeners, unregisters and removes its owned markup; a reporter cancels queued
reports on disposal.

The type contracts are grouped in `protocol/contracts.ts` (wire/snapshots/native
Window declarations), `core/window/window-types.ts` (geometry/registration),
`core/assets/types.ts` plus `skin-keys.ts` (semantic identifiers), and
`game-ui/item-types.ts` (item presentation). Runtime IPC validation remains in
`protocol.ts`; TypeScript types never replace those checks.

## Minimal primitives

`UiTitlebar`, `UiButton`, `UiTab`, `UiSlot`, `UiTooltip` and `UiCurrency` are small
composed primitives. `UiTooltip` accepts arbitrary DOM through `contentRoot` and a logical anchor
through `showAt(point)`. It flips/clamps using the manager's physical viewport
and scale. `game-ui/items/ItemTooltip` supplies the item name/description adapter. Currency takes its label and semantic
icon ID; its value and domain actions stay in the screen. Buttons/tabs/currency
subscriptions have explicit disposal. Shared base/chrome CSS is `core/core.css`.

`UiItemGrid`, `UiItemSlot` and `UiEquipmentSlot` live in `game-ui/` with
`components.css`. ItemGrid takes `{columns, rows, items}` and a factory for positioned items
(`x`, `y`, `height`). It has no page, carry, transfer or domain-state contract;
Inventory filters its own page before rendering. ItemSlot accepts only
`id/name/icon_id/height/quantity`, without revision or inventory coordinates. EquipmentSlot takes its rectangle and enabled state
from the screen. Equipment's silhouette and slot coordinates remain its own
composition. Missing item images fall back to the item label without losing
quantity. There are no hotbar/status widgets until a real screen needs them.

## Skin and icons

`skinKeys` and `uiIconDomains` are readonly literal catalogs; their TypeScript
identifier unions are derived from those arrays. There is no parallel type list.
A skin supplies only `assets` keyed by semantics: `window.frame`,
`window.frame.corner.tl` (tr/br/bl), `window.frame.edge.top` (bottom/left/right),
`window.title`, `button.close.normal/hover/pressed`, `slot.normal`,
`tab.normal/active`, `currency.yang`, and `equipment.background`.
The latter is a decoration, not the Equipment slot layout. Components use
semantic CSS variables. No component/view contains legacy asset paths or atlas
coordinates. `applySkin(document.documentElement, skin, {baseUrl})` probes images,
uses CSS fallback on missing/broken files and clears stale assets during replacement.
Missing close hover/pressed assets fall back to the normal image; a missing normal
image retains the text close button. Geometry keys are ignored.

`uiIcons` is the global `UiIconRegistry`. It resolves IDs such as
`currencies.yang`, `skills.<id>`, `actions.<id>`, `buffs.<id>`, `debuffs.<id>`,
`status.<id>`, `quests.<id>` and `glyphs.<id>`. Only these namespaces are accepted.
`uiIcons.replace({currencies: {yang: 'coin.png'}, skills: {}}, baseUrl)` replaces
presentation assets; subscribers such as Currency refresh without view changes.
The current implementation registers the real Yang icon. Other namespaces are
available for real content, without invented placeholder libraries.

`ItemIconResolver` separately resolves `ItemDefinition.icon_id`. Pass
`resolveItemIcon` to item screens/components. Item icons never enter the global
UI registry. At startup the legacy adapter supplies three separate values:
skin assets, UI icon groups and item icon content. New staging manifests export
`skin`, `uiIcons` and `itemIcons`; the adapter also supports existing ignored
manifests. Exact legacy PNGs remain ignored and byte-identical when staged.

Skin replacement occurs in application composition: apply the new semantic skin,
replace UI icon groups and select item content as appropriate. Inventory and
Equipment require no edits. CSS fallback works in a clean checkout.

## Adding a simple Storage window

The application loads `core/core.css` and `game-ui/components.css`, owns the
manager/bridge/resolvers, sets viewport/scale and reports the returned regions.
A screen can then be almost entirely composition (domain actions are injected):

```js
import {UiWindow} from '../core/window/ui-window.js';
import {ItemTooltip} from '../game-ui/items/item-tooltip.js';
import {UiItemGrid} from '../game-ui/items/ui-item-grid.js';
import {UiItemSlot} from '../game-ui/items/ui-item-slot.js';

export function mountStorage(root, {manager, resolveItemIcon, onClose,
  onItemPointer, onRegionsChanged}) {
  let tooltip;
  const shell = new UiWindow(root, {
    id: 'storage', title: 'Storage', manager,
    placement: {kind: 'viewport', anchor: 'top-right', offset: {x: -16, y: 80}},
    onClose, onRegionsChanged, onCancel: () => tooltip?.hide()
  });
  tooltip = ItemTooltip(root, {geometry: () => manager});
  const element = document.createElement('div');
  element.className = 'inventory-grid';
  shell.contentRoot.append(element);
  const slotSize = () => parseFloat(getComputedStyle(element)
    .getPropertyValue('--slot-size'));
  const grid = UiItemGrid(element, {slotSize});
  return {
    regions: [shell.panel],
    setItems(model) {
      grid.render(model, item => {
        const node = UiItemSlot({item, slotSize: slotSize(), resolveItemIcon});
        node.addEventListener('pointerdown', event => onItemPointer(event, item));
        node.addEventListener('pointermove', event => tooltip.show(event, item));
        node.addEventListener('pointerleave', () => tooltip.hide());
        return node;
      });
      shell.refresh();
    },
    dispose() {shell.dispose();tooltip.dispose();grid.dispose();}
  };
}
```

This example declares a window, composes presentation and binds injected actions.
It adds no Storage gameplay/backend implementation and duplicates no window,
tooltip or skin mechanics. Carry/transfer eligibility would belong to Storage.

## Verification

Each implementation step ran `git diff --check` and `tests/run-smoke.ps1` before
its local topic merge. Default smoke includes durable window lifecycle,
activation/registration, scale/resize, tooltip bounds, skin fallback/replacement,
icon namespace separation, item fallback and region-reporter disposal contracts.
It requires no browser, server, account, port or downloaded package.

`tests/run-web-inventory.ps1` also passed after icon metadata crossed the existing
snapshot boundary: real server and two clients exercised move/equip/unequip,
revision/ownership rejections, stats and persistence.

The opt-in `tests/run-core-ui-browser.ps1` takes `-PlaywrightModule` (an installed
module directory), `-BrowserExecutable` and optionally `-NodeExecutable`. It
uses a temporary loopback server and an installed headless Chromium browser,
without downloading dependencies or creating accounts. It loads the actual
production page with a controlled IPC fixture, checks legacy and unavailable-skin
fallback, command payloads, rejected-result behavior, click carry across pages,
tall-item drag/drop, capture/z-order, bounds across the UI Contract matrix,
skin replacement and a composed third window. It asserts no pixels, exact DOM
tree, animation timing or combat balance and is outside default smoke.

Headless Edge passed this milestone check. These results do not establish native
CEF transparency/input routing, Vulkan rendering or authenticated live-session
visual behavior; use the root client for that manual milestone check.
