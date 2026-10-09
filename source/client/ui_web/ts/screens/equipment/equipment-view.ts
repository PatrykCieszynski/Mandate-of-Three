import { ITEM_SLOT_SIZE } from '../../game-ui/items/item-geometry.js';
import type { ItemDragRuntime } from '../../game-ui/drag/item-drag-runtime.js';
import type { DragRegistration } from '../../game-ui/drag/item-drag-types.js';
import type { ItemPresentation } from '../../game-ui/item-types.js';
import {
  OwnedItemDragSubject,
  ownedItemPayload,
  itemWindowControls,
} from '../../game-ui/items/item-drag-policy.js';
import type {
  DomainSnapshot,
  EquipmentItem,
  ItemCommand,
  CommandResult,
} from '../../protocol/contracts.js';
import type { ResolveItemIcon } from '../../game-ui/item-types.js';
import type { WindowManager } from '../../core/window/window-manager.js';
import { element as findElement } from '../../core/dom.js';
import { errorMessage } from '../../protocol.js';
interface EquipmentOptions {
  manager: WindowManager;
  drag?: ItemDragRuntime;
  equipItem?: (command: ItemCommand) => Promise<CommandResult>;
  resolveItemIcon?: ResolveItemIcon;
  unequipItem: (command: ItemCommand) => Promise<CommandResult>;
  onClose?: () => void;
  onRegionsChanged?: () => void;
}
import { UiEquipmentSlot } from '../../game-ui/equipment/ui-equipment-slot.js';
import { ItemTooltip } from '../../game-ui/items/item-tooltip.js';
import { UiWindow } from '../../core/window/ui-window.js';
// Layout of the 156×188 reference equipment panel. Coordinates include the
// original slot container's (3,3) inset; these are screen geometry, not skin data.
const slots: [
  slot: string,
  label: string,
  x: number,
  y: number,
  height: number,
][] = [
  ['weapon', 'Weapon', 6, 6, 96],
  ['head', 'Helmet', 42, 5, 32],
  ['neck', 'Necklace', 117, 87, 32],
  ['armor', 'Armor', 42, 40, 64],
  ['earrings', 'Earrings', 117, 55, 32],
  ['bracelet', 'Bracelet', 78, 70, 32],
  ['shield', 'Shield', 78, 38, 32],
  ['feet', 'Shoes', 42, 148, 32],
  ['arrows', 'Arrows', 117, 4, 32],
  ['special1', 'Special slot I', 5, 116, 32],
  ['special2', 'Special slot II', 78, 116, 32],
];
export function mountEquipment(
  root: HTMLElement,
  {
    manager,
    drag,
    equipItem,
    resolveItemIcon = () => null,
    unequipItem,
    onClose = () => {},
    onRegionsChanged = () => {},
  }: EquipmentOptions,
) {
  const shell = new UiWindow(root, {
    id: 'equipment',
    title: 'Equipment',
    className: 'equipment-window',
    manager,
    placement: {
      kind: 'relative',
      target: 'inventory',
      side: 'left',
      align: 'start',
      gap: 12,
      fallback: {
        kind: 'viewport',
        anchor: 'top-right',
        offset: { x: -16, y: 240 },
      },
    },
    onClose,
    onRegionsChanged,
    onCancel: () => {
      tooltip.hidden = true;
      drag?.cancel();
    },
    canDrag: () => !drag?.active,
  });
  shell.contentRoot.innerHTML = `<div class="equipment-body"><div class="equipment-silhouette" aria-hidden="true">♟</div></div>
    <p class="equipment-stats"></p><p class="equipment-hint">Right-click bag items to equip.<br>Click weapon to unequip.</p>
    <p class="inventory-status" role="status"></p>`;
  const panel = findElement(root, '.equipment-window', 'section'),
    body = findElement(root, '.equipment-body', 'div'),
    status = findElement(root, '[role=status]', 'p');
  const tip = ItemTooltip(root, { geometry: () => manager }),
    tooltip = tip.element;
  let pending = false,
    disposed = false;
  let items: EquipmentItem[] = [];
  const bindings = itemWindowControls(drag, root);
  const sourceBindings: DragRegistration[] = [];
  const buttons = new Map<string, ReturnType<typeof UiEquipmentSlot>>();
  for (const [slot, label, x, y, height] of slots) {
    const tile = UiEquipmentSlot({
        slot,
        label,
        x,
        y,
        height,
        resolveItemIcon,
        title: slot === 'weapon' ? label : label + ' · not available yet',
      }),
      button = tile.element;
    shell.listen(button, 'pointermove', (event) => showTooltip(event, slot));
    shell.listen(button, 'pointerleave', () => (tooltip.hidden = true));
    shell.listen(button, 'click', (event) => {
      if (drag && event.detail !== 0) return;
      const item = items.find((item) => item.slot === slot);
      if (item) void unequip(item);
    });
    shell.listen(button, 'pointerdown', (event) => {
      if (event.button !== 2 || drag?.active) return;
      const item = items.find((item) => item.slot === slot);
      if (item) {
        event.preventDefault();
        void unequip(item);
      }
    });
    if (drag)
      bindings.push(
        drag.registerTarget({
          element: button,
          preview: (payload) => {
            const subject =
              payload.subject instanceof OwnedItemDragSubject
                ? payload.subject
                : null;
            // Only the currently implemented weapon slot accepts bag drops. The World
            // remains responsible for definition/slot compatibility and revision checks.
            const valid =
              !!subject &&
              subject.container === 'inventory' &&
              slot === 'weapon' &&
              !!equipItem &&
              !pending;
            const highlight = document.createElement('div');
            highlight.className =
              'item-drop-highlight' + (valid ? '' : ' invalid');
            return {
              valid,
              data: subject,
              visual: { element: highlight, parent: button },
            };
          },
          drop: async (_payload, preview) => {
            if (preview.data) await equip(preview.data.item);
          },
        }),
      );
    buttons.set(slot, tile);
    body.append(button);
  }
  function showTooltip(event: PointerEvent, slot: string) {
    const item = items.find((item) => item.slot === slot);
    if (!item || pending || shell.drag || drag?.active) return;
    tip.show(event, item);
  }
  async function action(
    item: ItemPresentation,
    command: (command: ItemCommand) => Promise<CommandResult>,
    label: string,
    pendingText: string,
  ) {
    if (pending || disposed) return;
    pending = true;
    tooltip.hidden = true;
    render();
    status.textContent = pendingText;
    try {
      const result = await command({ id: item.id, revision: item.revision });
      if (!disposed)
        status.textContent = result.ok
          ? ''
          : `${label} rejected: ${result.error || 'request'}`;
    } catch (error) {
      if (!disposed)
        status.textContent = `${label} failed: ${errorMessage(error)}`;
    } finally {
      pending = false;
      if (!disposed) render();
    }
  }
  function unequip(item: ItemPresentation) {
    return action(item, unequipItem, 'Unequip', 'Unequipping…');
  }
  async function equip(item: ItemPresentation) {
    if (equipItem) await action(item, equipItem, 'Equip', 'Equipping…');
  }
  function render() {
    sourceBindings.forEach((binding) => binding.dispose());
    sourceBindings.length = 0;
    for (const [slot, tile] of buttons) {
      const item = items.find((item) => item.slot === slot);
      tile.setItem(item, { enabled: slot === 'weapon' && !!item && !pending });
      if (drag && item && slot === 'weapon' && !pending)
        sourceBindings.push(
          drag.registerSource({
            element: tile.element,
            payload: () => {
              shell.handle.activate();
              tip.hide();
              return ownedItemPayload(
                'equipment',
                item,
                ITEM_SLOT_SIZE,
                resolveItemIcon,
              );
            },
            onClick: () => {
              void unequip(item);
            },
          }),
        );
    }
  }

  return {
    regions: [panel],
    close: onClose,
    unequip,
    refresh: () => shell.refresh(),
    activate: () => shell.handle.activate(),
    setState(state: DomainSnapshot) {
      drag?.cancel();
      tooltip.hidden = true;
      items = state.equipment?.items || [];
      render();
      findElement(root, '.equipment-stats', 'p').textContent =
        'Attack ' + Number(state.equipment?.stats?.attack || 0);
      shell.refresh();
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      sourceBindings.forEach((binding) => binding.dispose());
      bindings.forEach((binding) => binding.dispose());
      shell.dispose();
      tip.dispose();
    },
  };
}
