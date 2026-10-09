// Browser preview composition only. No Storage native domain or server command.
import { manager, resolveItemIcon } from '../web/inventory/game.js';
import { mountStorage } from '../web/screens/storage/storage-view.js';
import type { StorageSnapshot } from '../web/screens/storage/storage-types.js';
import { reportInteractiveRegions } from '../web/bridge.js';
import { encode } from '../web/protocol.js';
import {
  decodePreviewAction,
  notify,
  previewInventory,
  updatePreviewInventory,
} from './runtime.js';
import { previewItemTransfer } from './item-transfer.js';
import { transfer } from '../web/screens/storage/transfer.js';
function fixture(): StorageSnapshot {
  return {
    columns: 15,
    rows: 9,
    pages: 2,
    items: [
      {
        id: 'stored-sword',
        revision: 1,
        name: 'Stored iron sword',
        icon_id: 'iron_sword',
        height: 3,
        quantity: 1,
        x: 0,
        y: 0,
        page: 0,
        description: 'A tall item on Storage page I.',
      },
      {
        id: 'stored-potions',
        revision: 1,
        name: 'Stored potions',
        icon_id: 'potion',
        height: 1,
        quantity: 20,
        x: 7,
        y: 4,
        page: 0,
        description: 'A stack in the middle of page I.',
      },
      {
        id: 'stored-edge',
        revision: 1,
        name: 'Corner potion',
        icon_id: 'potion',
        height: 1,
        quantity: 2,
        x: 14,
        y: 8,
        page: 0,
      },
      {
        id: 'stored-page-two',
        revision: 1,
        name: 'Page II sword',
        icon_id: 'short_sword',
        height: 2,
        quantity: 1,
        x: 3,
        y: 2,
        page: 1,
        description: 'A two-cell item on Storage page II.',
      },
      {
        id: 'stored-page-two-stack',
        revision: 1,
        name: 'Page II potions',
        icon_id: 'potion',
        height: 1,
        quantity: 8,
        x: 14,
        y: 8,
        page: 1,
      },
    ],
  };
}
const root = document.createElement('main');
root.id = 'storage';
root.hidden = true;
document.body.append(root);
let storageState = fixture();
let interaction: ReturnType<typeof previewItemTransfer> | undefined;
let reporter: ReturnType<typeof reportInteractiveRegions> | undefined;
function show(visible: boolean) {
  if (!visible) interaction?.cancel();
  const opened = root.hidden && visible;
  root.hidden = !visible;
  storage.refresh();
  if (opened) storage.activate();
  reporter?.refresh();
}
const storage = mountStorage(root, {
  manager,
  resolveItemIcon,
  onClose: () => show(false),
  onRegionsChanged: () => reporter?.refresh(),
  onItemAction: (event, item) =>
    notify({
      message: {
        preview: 'storage.item_action',
        id: item.id,
        revision: item.revision,
        page: item.page,
        button: event.button,
      },
    }),
});
reporter = reportInteractiveRegions(
  {
    event(type, payload) {
      window.sendIpcMessage(encode(type, payload));
    },
  },
  storage.regions,
);
storage.setState(storageState);
interaction = previewItemTransfer({
  manager,
  resolveItemIcon,
  getState(id) {
    if (id === 'storage') return storageState;
    const inventory = previewInventory();
    if (!inventory) throw Error('Missing preview Inventory');
    return inventory;
  },
  move(from, to, item, target) {
    const inventory = previewInventory();
    if (!inventory) return false;
    const source = from === 'storage' ? storageState : inventory;
    const destination = to === 'storage' ? storageState : inventory;
    const result = transfer(
      source,
      destination,
      item.id,
      item.revision,
      target,
    );
    notify({
      message: {
        preview: 'storage.transfer',
        from,
        to,
        id: item.id,
        ok: !!result,
        quick: !target,
      },
    });
    if (!result) {
      capacityStatus('No room for this item.');
      return false;
    }
    const storageItems =
      to === 'storage' ? result.destinationItems : result.sourceItems;
    const inventoryItems =
      to === 'inventory' ? result.destinationItems : result.sourceItems;
    if (from === 'storage' || to === 'storage') {
      storageState = { ...storageState, items: storageItems };
      storage.setState(storageState);
    }
    if (from === 'inventory' || to === 'inventory')
      updatePreviewInventory(inventoryItems);
    capacityStatus('135 slots per page · 2 pages');
    return true;
  },
});
function capacityStatus(text: string) {
  const label = root.querySelector('.storage-capacity');
  if (label) label.textContent = text;
}
show(true);
window.addEventListener('message', (event) => {
  if (event.source !== parent || event.origin !== location.origin) return;
  const request = decodePreviewAction(event.data);
  if (!request) return;
  if (request.action !== 'wallet' && request.action !== 'accept')
    interaction?.cancel();
  if (request.action === 'storage') show(request.value);
  else if (request.action === 'reset') {
    storageState = fixture();
    storage.setState(storageState);
    show(true);
  } else if (request.action === 'empty') {
    storageState = { columns: 15, rows: 9, pages: 2, items: [] };
    storage.setState(storageState);
  }
});
window.addEventListener('pagehide', () => {
  interaction?.dispose();
  storage.dispose();
  reporter?.dispose();
  root.remove();
});
